// Uji migrasi SQL secara lokal dengan PGlite (PostgreSQL di Node.js).
// Mensimulasikan lingkungan Supabase: schema auth, role authenticated, RLS.
// Jalankan: npm run test:db
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const migrationsDir = join(dirname(fileURLToPath(import.meta.url)), '../../supabase/migrations');
const db = new PGlite();

let passed = 0;
let failed = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`  ✔ ${name}`);
    passed++;
  } catch (e) {
    console.log(`  ✘ ${name}\n      ${e.message}`);
    failed++;
  }
}
function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}
async function expectError(sql, params, pattern) {
  try {
    await db.query(sql, params);
  } catch (e) {
    if (pattern && !pattern.test(e.message)) throw new Error(`Error tak terduga: ${e.message}`);
    return;
  }
  throw new Error('Seharusnya gagal, tapi berhasil');
}
const one = async (sql, params) => (await db.query(sql, params)).rows[0];
const val = async (sql, params) => Object.values(await one(sql, params))[0];

async function loginAs(userId) {
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '${userId}', false); set role authenticated;`);
}

// ---------- stub lingkungan Supabase ----------
await db.exec(`
  create role anon nologin;
  create role authenticated nologin;
  create schema auth;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated;
  grant execute on function auth.uid() to anon, authenticated;
  create publication supabase_realtime;
  create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
  alter table storage.objects enable row level security;
  create function storage.foldername(name text) returns text[] language sql immutable as
    $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
  grant usage on schema storage to anon, authenticated;
  grant all on storage.objects to authenticated;
  grant select on storage.buckets to anon, authenticated;
  create function storage.filename(name text) returns text language sql immutable as
    $$ select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'), 1)] $$;
  create role service_role nologin;
  grant usage on schema public, auth to service_role;
  alter default privileges in schema public grant all on tables to service_role;
  grant usage on schema public to anon, authenticated;
  alter default privileges in schema public grant all on tables to anon, authenticated;
  alter default privileges in schema public grant all on sequences to anon, authenticated;
  alter default privileges in schema public grant execute on functions to anon, authenticated;
`);

// Migrasi dijalankan bertahap seperti di produksi: 001-005 dulu (fase 1-2),
// lalu 006+ dijalankan di atas database yang sudah berisi transaksi.
const allMigrations = readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
async function runMigrations(files) {
  await db.exec('reset role');
  for (const file of files) {
    await check(file, () => db.exec(readFileSync(join(migrationsDir, file), 'utf8')));
  }
  if (failed) process.exit(1);
}

console.log('\nMenjalankan migrasi fase 1-2:');
await runMigrations(allMigrations.filter((f) => f < '006'));

const U1 = '11111111-1111-1111-1111-111111111111';
const U2 = '22222222-2222-2222-2222-222222222222';
const U6 = '66666666-6666-6666-6666-666666666666';
await db.exec(`insert into auth.users values ('${U1}', 'owner1@test.com'), ('${U2}', 'owner2@test.com')`);

console.log('\nOnboarding:');
let outletId;
await check('owner 1 membuat perusahaan + data demo', async () => {
  await loginAs(U1);
  const r = await val(`select sys_onboard_company('Warung Nusantara', 'Cabang Kemang', 'Andi')`);
  outletId = r.outlet_id;
  assert(outletId, 'outlet_id kosong');
});
await check('tidak bisa onboarding dua kali', () =>
  expectError(`select sys_onboard_company('X', 'Y', 'Z')`, [], /sudah terdaftar/));
await check('profil berisi role & outlet', async () => {
  const p = await val(`select sys_get_my_profile()`);
  assert(p.role_code === 'owner' && p.outlets.length === 1, JSON.stringify(p));
});
await check('data demo terisi (9 menu, 10 meja, 17 bahan, stok awal)', async () => {
  const r = await one(`select
    (select count(*) from mst_menu_items)::int menus,
    (select count(*) from mst_tables)::int tables,
    (select count(*) from inv_items)::int items,
    (select count(*) from inv_stocks where quantity > 0)::int stocks`);
  assert(r.menus === 9 && r.tables === 10 && r.items === 17 && r.stocks === 17, JSON.stringify(r));
});

console.log('\nPOS:');
let orderId;
await check('simpan order (dine-in, meja A1, dengan modifier)', async () => {
  const menu = await one(`select id from mst_menu_items where code = 'MKN01'`);
  const tea = await one(`select id from mst_menu_items where code = 'MNM01'`);
  const egg = await one(`select id from mst_modifiers where name = 'Telur'`);
  const table = await one(`select id from mst_tables where code = 'A1'`);
  const order = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, table_id: table.id, sales_channel: 'dine_in', guest_count: 2,
    items: [
      { menu_item_id: menu.id, quantity: 2, modifier_ids: [egg.id] },
      { menu_item_id: tea.id, quantity: 2 },
    ],
  })]);
  orderId = order.id;
  // (35000+5000)*2 + 8000*2 = 96000 ; service 5% = 4800 ; pajak 10% = 10080 ; total 110880 -> 110900
  assert(Number(order.subtotal) === 96000, `subtotal ${order.subtotal}`);
  assert(Number(order.grand_total) === 110900, `grand_total ${order.grand_total}`);
  assert(/^INV\/OUT01\/\d{8}\/0001$/.test(order.order_number), order.order_number);
  assert((await val(`select status from mst_tables where id = $1`, [table.id])) === 'occupied', 'meja belum occupied');
});
await check('tambah item ke open bill', async () => {
  const fries = await one(`select id from mst_menu_items where code = 'SNK01'`);
  const order = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    order_id: orderId, items: [{ menu_item_id: fries.id, quantity: 1 }],
  })]);
  assert(Number(order.subtotal) === 116000, `subtotal ${order.subtotal}`);
});
await check('diskon dihitung sebelum service & pajak', async () => {
  const o = await val(`select pos_set_order_discount($1, 16000)`, [orderId]);
  // (116000-16000)=100000 ; service 5000 ; pajak 10500 ; total 115500
  assert(Number(o.grand_total) === 115500, `total ${o.grand_total}`);
  await db.query(`select pos_set_order_discount($1, 0)`, [orderId]);
});
await check('kasir tidak bisa ubah total order langsung', async () => {
  await db.query(`update pos_orders set grand_total = 1 where id = $1`, [orderId]);
  assert(Number(await val(`select grand_total from pos_orders where id = $1`, [orderId])) !== 1, 'total berubah!');
});
await check('dapur bisa ubah kitchen_status', async () => {
  await db.query(`update pos_order_items set kitchen_status = 'cooking' where order_id = $1`, [orderId]);
  assert((await val(`select count(*)::int from pos_order_items where kitchen_status = 'cooking'`)) === 3, 'gagal update');
});
await check('dapur TIDAK bisa ubah harga item', () =>
  expectError(`update pos_order_items set unit_price = 1 where order_id = $1`, [orderId], /permission denied/));
await check('bayar tanpa shift ditolak', async () => {
  const cash = await one(`select id from mst_payment_methods where code = 'cash'`);
  await expectError(`select pos_pay_order($1, $2::jsonb)`,
    [orderId, JSON.stringify([{ payment_method_id: cash.id, amount: 200000 }])], /shift/);
});
let shiftId;
await check('buka shift', async () => {
  shiftId = (await val(`select pos_open_shift($1, 500000)`, [outletId])).id;
});
await check('bayar kurang ditolak', async () => {
  const cash = await one(`select id from mst_payment_methods where code = 'cash'`);
  await expectError(`select pos_pay_order($1, $2::jsonb)`,
    [orderId, JSON.stringify([{ payment_method_id: cash.id, amount: 1000 }])], /kurang/);
});
await check('bayar tunai + kembalian, stok terpotong otomatis', async () => {
  const before = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN01'`));
  const cash = await one(`select id from mst_payment_methods where code = 'cash'`);
  const r = await val(`select pos_pay_order($1, $2::jsonb)`,
    [orderId, JSON.stringify([{ payment_method_id: cash.id, amount: 150000 }])]);
  // 116000 + 5800 + 12180 = 133980 -> 134000
  assert(Number(r.grand_total) === 134000, `total ${r.grand_total}`);
  assert(Number(r.change_amount) === 16000, `kembalian ${r.change_amount}`);
  const after = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN01'`));
  assert(before - after === 400, `beras berkurang ${before - after}, harusnya 400`);
  assert((await val(`select status from mst_tables where code = 'A1'`)) === 'available', 'meja belum kosong');
});
await check('void order yang belum dibayar', async () => {
  const menu = await one(`select id from mst_menu_items where code = 'MNM02'`);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: menu.id }],
  })]);
  await db.query(`select pos_void_order($1, 'salah input')`, [o.id]);
  assert((await val(`select status from pos_orders where id = $1`, [o.id])) === 'void', 'belum void');
});
await check('harga GoFood (+20%) dipakai otomatis', async () => {
  const menu = await one(`select id from mst_menu_items where code = 'MKN01'`);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'gofood', items: [{ menu_item_id: menu.id }],
  })]);
  assert(Number(o.subtotal) === 42000, `subtotal ${o.subtotal}`);
  await db.query(`select pos_void_order($1, 'tes')`, [o.id]);
});
await check('tutup shift, kas sesuai', async () => {
  const r = await val(`select pos_close_shift($1, 634000)`, [shiftId]);
  assert(Number(r.expected_cash) === 634000 && Number(r.difference) === 0, JSON.stringify(r));
});

console.log('\nPurchasing & Inventory:');
await check('PO -> approve -> terima barang -> stok naik', async () => {
  const sup = await one(`select id from pur_suppliers where code = 'SUP01'`);
  const wh = await one(`select id from inv_warehouses limit 1`);
  const item = await one(`select id from inv_items where code = 'BHN05'`);
  const kg = await one(`select id from inv_units where code = 'kg'`);
  const company = await val(`select sys_current_company_id()`);
  const po = await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id)
    values ($1, $2, $3) returning id`, [company, sup.id, wh.id]);
  await db.query(`insert into pur_purchase_order_items
    (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price)
    values ($1, $2, $3, $4, 1000, 10, 45000)`, [company, po.id, item.id, kg.id]);
  const approved = await val(`select pur_approve_purchase_order($1)`, [po.id]);
  assert(Number(approved.grand_total) === 450000 && approved.po_number.startsWith('PO/'), JSON.stringify(approved));

  const before = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN05'`));
  const grId = await val(`select pur_create_goods_receipt_from_po($1)`, [po.id]);
  await db.query(`update pur_goods_receipt_items set quantity = 6 where goods_receipt_id = $1`, [grId]);
  await db.query(`select pur_post_goods_receipt($1)`, [grId]);
  const after = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN05'`));
  assert(after - before === 6000, `stok ayam naik ${after - before}, harusnya 6000 g`);
  assert((await val(`select status from pur_purchase_orders where id = $1`, [po.id])) === 'partially_received', 'status PO salah');
  assert(Number(await val(`select last_purchase_cost from inv_items where id = $1`, [item.id])) === 45, 'harga beli terakhir salah');
});
await check('stock opname menyesuaikan stok', async () => {
  const company = await val(`select sys_current_company_id()`);
  const wh = await one(`select id from inv_warehouses limit 1`);
  const item = await one(`select id from inv_items where code = 'BHN06'`);
  const op = await one(`insert into inv_stock_opnames (company_id, warehouse_id) values ($1, $2) returning id`, [company, wh.id]);
  await db.query(`insert into inv_stock_opname_items (company_id, stock_opname_id, item_id, counted_qty)
    values ($1, $2, $3, 50)`, [company, op.id, item.id]);
  await db.query(`select inv_post_stock_opname($1)`, [op.id]);
  assert(Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN06'`)) === 50, 'stok telur bukan 50');
});
await check('waste mengurangi stok', async () => {
  const company = await val(`select sys_current_company_id()`);
  const wh = await one(`select id from inv_warehouses limit 1`);
  const item = await one(`select id from inv_items where code = 'BHN06'`);
  const adj = await one(`insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type)
    values ($1, $2, 'waste') returning id`, [company, wh.id]);
  await db.query(`insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity)
    values ($1, $2, $3, 5)`, [company, adj.id, item.id]);
  await db.query(`select inv_post_stock_adjustment($1)`, [adj.id]);
  assert(Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN06'`)) === 45, 'stok telur bukan 45');
});
await check('transfer antar gudang', async () => {
  const company = await val(`select sys_current_company_id()`);
  const wh = await one(`select id from inv_warehouses limit 1`);
  const ck = await one(`insert into inv_warehouses (company_id, code, name) values ($1, 'WH-CK', 'Central Kitchen') returning id`, [company]);
  const item = await one(`select id from inv_items where code = 'BHN06'`);
  const tr = await one(`insert into inv_stock_transfers (company_id, from_warehouse_id, to_warehouse_id)
    values ($1, $2, $3) returning id`, [company, wh.id, ck.id]);
  await db.query(`insert into inv_stock_transfer_items (company_id, stock_transfer_id, item_id, quantity)
    values ($1, $2, $3, 10)`, [company, tr.id, item.id]);
  await db.query(`select inv_post_stock_transfer($1)`, [tr.id]);
  const r = await db.query(`select warehouse_name, quantity from rpt_stock_balances where item_code = 'BHN06' order by warehouse_name`);
  assert(Number(r.rows[0].quantity) === 10 && Number(r.rows[1].quantity) === 35, JSON.stringify(r.rows));
});
await check('user tidak bisa insert kartu stok langsung', async () => {
  const company = await val(`select sys_current_company_id()`);
  const wh = await one(`select id from inv_warehouses limit 1`);
  const item = await one(`select id from inv_items limit 1`);
  await expectError(`insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity)
    values ($1, $2, $3, 'adjustment', 999)`, [company, wh.id, item.id], /row-level security/);
});

console.log('\nLaporan:');
await check('rpt_daily_sales', async () => {
  const r = await one(`select * from rpt_daily_sales`);
  assert(Number(r.grand_total) === 134000 && Number(r.order_count) === 1, JSON.stringify(r));
});
await check('rpt_menu_food_costs (HPP Nasi Goreng)', async () => {
  const r = await one(`select * from rpt_menu_food_costs where code = 'MKN01'`);
  assert(Number(r.food_cost) > 0 && r.has_recipe, JSON.stringify(r));
});

console.log('\nKeamanan antar perusahaan:');
await check('owner 2 tidak melihat data perusahaan 1', async () => {
  await loginAs(U2);
  await db.query(`select sys_onboard_company('Kedai Lain', 'Pusat', 'Budi', false)`);
  assert((await val(`select count(*)::int from pos_orders`)) === 0, 'bisa lihat order perusahaan lain!');
  assert((await val(`select count(*)::int from mst_menu_items`)) === 0, 'bisa lihat menu perusahaan lain!');
  assert((await val(`select count(*)::int from sys_companies`)) === 1, 'bisa lihat perusahaan lain!');
});
await check('owner 2 tidak bisa bayar order perusahaan 1', () =>
  expectError(`select pos_void_order($1, 'hack')`, [orderId], /tidak ditemukan/));
await check('fungsi internal tidak bisa dipanggil langsung', () =>
  expectError(`select sys_next_sequence(gen_random_uuid(), 'X')`, [], /permission denied/));
await check('user tanpa login tidak bisa baca apa pun', async () => {
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;`);
  assert((await val(`select count(*)::int from mst_menu_items`)) === 0, 'anon bisa baca menu!');
});

// =====================================================================
// FASE 3: dijalankan di atas database yang sudah berisi transaksi
// =====================================================================
console.log('\nMenjalankan migrasi fase 3 (di atas data yang sudah ada):');
await runMigrations(allMigrations.filter((f) => f >= '006' && f < '008'));

const balanceOf = async (key, from = '2000-01-01', to = '2100-01-01') =>
  Number(await val(`select closing_balance from fin_get_account_balances($1, $2) where system_key = $3`, [from, to, key]));

console.log('\nKeuangan - backfill data lama:');
await check('COA dibuat untuk perusahaan lama', async () => {
  await loginAs(U1);
  assert((await val(`select count(*)::int from fin_accounts`)) > 30, 'COA belum ada');
  assert((await val(`select count(*)::int from mst_payment_methods where account_id is null`)) === 0, 'metode bayar belum dipetakan');
});
await check('jurnal dibuat untuk transaksi lama (penjualan, pembelian, stok)', async () => {
  const types = (await db.query(`select distinct source_type from fin_journals order by 1`)).rows.map((r) => r.source_type);
  for (const t of ['opening_stock', 'purchase_receipt', 'sales', 'stock_adjustment', 'stock_opname']) {
    assert(types.includes(t), `jurnal ${t} tidak ada (ada: ${types})`);
  }
});
await check('jurnal penjualan benar (kas 134.000, penjualan 116.000, HPP > 0)', async () => {
  const r = await one(`select
      (select sum(l.debit)  from fin_journal_lines l join fin_journals j on j.id = l.journal_id join fin_accounts a on a.id = l.account_id where j.source_type = 'sales' and a.system_key = 'cash')::numeric cash,
      (select sum(l.credit) from fin_journal_lines l join fin_journals j on j.id = l.journal_id join fin_accounts a on a.id = l.account_id where j.source_type = 'sales' and a.system_key = 'sales_revenue')::numeric revenue,
      (select sum(l.debit)  from fin_journal_lines l join fin_journals j on j.id = l.journal_id join fin_accounts a on a.id = l.account_id where j.source_type = 'sales' and a.system_key = 'cogs')::numeric cogs`);
  assert(Number(r.cash) === 134000 && Number(r.revenue) === 116000 && Number(r.cogs) > 0, JSON.stringify(r));
});
await check('hutang usaha = nilai penerimaan barang (270.000)', async () => {
  assert((await balanceOf('ap')) === 270000, `AP ${await balanceOf('ap')}`);
});
await check('persediaan di neraca = nilai stok di gudang', async () => {
  const stockValue = Number(await val(`select sum(quantity * average_cost) from inv_stocks`));
  const diff = Math.abs((await balanceOf('inventory')) - stockValue);
  assert(diff < 1, `selisih ${diff}`);
});

console.log('\nKeuangan - transaksi baru:');
await check('order baru langsung terjurnal', async () => {
  const shift = await val(`select pos_open_shift($1, 0)`, [outletId]);
  const menu = await one(`select id from mst_menu_items where code = 'MNM03'`);
  const qris = await one(`select id from mst_payment_methods where code = 'qris'`);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: menu.id }] })]);
  const bankBefore = await balanceOf('bank');
  await db.query(`select pos_pay_order($1, $2::jsonb)`, [o.id, JSON.stringify([{ payment_method_id: qris.id, amount: o.grand_total }])]);
  assert((await balanceOf('bank')) - bankBefore === Number(o.grand_total), 'bank tidak bertambah');
  await db.query(`select pos_close_shift($1, 0)`, [shift.id]);
});
await check('bayar hutang supplier', async () => {
  const gr = await one(`select goods_receipt_id, supplier_id from rpt_payables limit 1`);
  const cash = await val(`select id from fin_accounts where system_key = 'cash'`);
  await db.query(`select fin_pay_supplier($1, $2, current_date, $3::jsonb)`,
    [gr.supplier_id, cash, JSON.stringify([{ goods_receipt_id: gr.goods_receipt_id, amount: 100000 }])]);
  assert((await balanceOf('ap')) === 170000, `AP ${await balanceOf('ap')}`);
  assert(Number(await val(`select outstanding_amount from rpt_payables`)) === 170000, 'sisa hutang salah');
});
await check('bayar melebihi hutang ditolak', async () => {
  const gr = await one(`select goods_receipt_id, supplier_id from rpt_payables limit 1`);
  const cash = await val(`select id from fin_accounts where system_key = 'cash'`);
  await expectError(`select fin_pay_supplier($1, $2, current_date, $3::jsonb)`,
    [gr.supplier_id, cash, JSON.stringify([{ goods_receipt_id: gr.goods_receipt_id, amount: 999999 }])], /melebihi/);
});
await check('catat biaya listrik', async () => {
  const exp = await val(`select id from fin_accounts where code = '6-1300'`);
  const cash = await val(`select id from fin_accounts where system_key = 'cash'`);
  await db.query(`select fin_record_expense(current_date, $1, $2, 750000, 'Token listrik')`, [exp, cash]);
  const r = await one(`select closing_balance from fin_get_account_balances('2000-01-01', '2100-01-01') where code = '6-1300'`);
  assert(Number(r.closing_balance) === 750000, JSON.stringify(r));
});
await check('jurnal manual tidak seimbang ditolak', async () => {
  const cash = await val(`select id from fin_accounts where system_key = 'cash'`);
  const equity = await val(`select id from fin_accounts where system_key = 'owner_equity'`);
  await expectError(`select fin_post_manual_journal(current_date, 'Setor modal', $1::jsonb)`,
    [JSON.stringify([{ account_id: cash, debit: 1000 }, { account_id: equity, credit: 900 }])], /tidak seimbang/);
  await db.query(`select fin_post_manual_journal(current_date, 'Setor modal', $1::jsonb)`,
    [JSON.stringify([{ account_id: cash, debit: 5000000 }, { account_id: equity, credit: 5000000 }])]);
});
await check('neraca saldo seimbang (total debit = total kredit)', async () => {
  const r = await one(`select sum(debit) d, sum(credit) c from fin_journal_lines`);
  assert(Number(r.d) === Number(r.c), JSON.stringify(r));
});
await check('neraca seimbang: aset = kewajiban + ekuitas + laba berjalan', async () => {
  const rows = (await db.query(`select * from fin_get_account_balances('2000-01-01', '2100-01-01') where not is_header`)).rows;
  // akun kontra (mis. Diskon Penjualan: tipe pendapatan, saldo normal debit) mengurangi kelompoknya
  const natural = (type) => (["asset", "cogs", "expense"].includes(type) ? "debit" : "credit");
  const total = (type) => rows.filter((r) => r.account_type === type)
    .reduce((s, r) => s + (r.normal_balance === natural(type) ? 1 : -1) * Number(r.closing_balance), 0);
  const profit = total('revenue') - total('cogs') - total('expense');
  const diff = total('asset') - (total('liability') + total('equity') + profit);
  assert(Math.abs(diff) < 0.01, `selisih ${diff}`);
});

console.log('\nUser & undangan:');
const U3 = '33333333-3333-3333-3333-333333333333';
await check('owner mengundang kasir', async () => {
  const company = await val(`select sys_current_company_id()`);
  const role = await val(`select id from sys_roles where code = 'cashier'`);
  await db.query(`insert into sys_user_invitations (company_id, email, role_id, outlet_ids) values ($1, 'kasir@test.com', $2, array[$3::uuid])`,
    [company, role, outletId]);
});
await check('kasir daftar & menerima undangan', async () => {
  await db.exec(`reset role; insert into auth.users values ('${U3}', 'Kasir@Test.com')`);
  await loginAs(U3);
  const invites = await val(`select sys_get_my_invitations()`);
  assert(invites.length === 1, JSON.stringify(invites));
  await db.query(`select sys_accept_invitation($1, 'Siti')`, [invites[0].id]);
  const p = await val(`select sys_get_my_profile()`);
  assert(p.role_code === 'cashier' && p.outlets.length === 1, JSON.stringify(p));
});
await check('kasir tidak bisa melihat data keuangan', async () => {
  assert((await val(`select count(*)::int from fin_journals`)) === 0, 'kasir bisa lihat jurnal!');
});
await check('kasir tidak bisa void / ubah role sendiri', async () => {
  const o = await one(`select id from pos_orders limit 1`);
  await expectError(`select pos_void_order($1, 'x')`, [o.id], /izin/);
  const owner = await val(`select id from sys_roles where code = 'owner'`);
  await db.query(`update sys_users set role_id = $1 where id = $2`, [owner, U3]);
  assert((await val(`select sys_get_my_profile()`)).role_code === 'cashier', 'kasir bisa jadi owner!');
});
await check('owner lain tidak bisa melihat undangan perusahaan 1', async () => {
  await loginAs(U2);
  assert((await val(`select count(*)::int from sys_user_invitations`)) === 0, 'bocor');
  assert((await val(`select jsonb_array_length(sys_list_users())`)) === 1, 'bisa lihat user lain');
});
await check('owner menonaktifkan kasir', async () => {
  await loginAs(U1);
  const role = await val(`select id from sys_roles where code = 'cashier'`);
  await db.query(`select sys_update_user($1, $2, array[]::uuid[], false)`, [U3, role]);
  await loginAs(U3);
  assert((await val(`select sys_get_my_profile()`)) === null, 'kasir nonaktif masih bisa masuk');
});
await check('owner menambah outlet baru (otomatis punya gudang)', async () => {
  await loginAs(U1);
  const o = await val(`select sys_create_outlet('OUT02', 'Cabang Senopati')`);
  const wh = await val(`select default_warehouse_id from sys_outlets where id = $1`, [o.id]);
  assert(wh, 'gudang belum dibuat');
  assert((await val(`select sys_get_my_profile()`)).outlets.length === 2, 'outlet tidak muncul');
});
await check('perusahaan baru langsung punya COA & jurnal stok awal', async () => {
  const U4 = '44444444-4444-4444-4444-444444444444';
  await db.exec(`reset role; insert into auth.users values ('${U4}', 'baru@test.com')`);
  await loginAs(U4);
  await db.query(`select sys_onboard_company('Kopi Baru', 'Pusat', 'Rina')`);
  assert((await val(`select count(*)::int from fin_accounts`)) > 30, 'COA kosong');
  assert((await balanceOf('inventory')) > 0, 'jurnal stok awal tidak ada');
});

// =====================================================================
// FASE 4: CRM, promo, QR order
// =====================================================================
console.log('\nMenjalankan migrasi fase 4 (di atas data fase 1-3):');
await runMigrations(allMigrations.filter((f) => f >= '008' && f < '010'));

const menuId = async (code) => val(`select id from mst_menu_items where code = $1`, [code]);
const payCash = async (orderId) => {
  const cash = await val(`select id from mst_payment_methods where code = 'cash'`);
  const total = await val(`select grand_total from pos_orders where id = $1`, [orderId]);
  return val(`select pos_pay_order($1, $2::jsonb)`, [orderId, JSON.stringify([{ payment_method_id: cash, amount: total }])]);
};
let customerId;
let shift4;

console.log('\nMember & poin:');
await check('tier & pengaturan poin dibuat untuk perusahaan lama', async () => {
  await loginAs(U1);
  assert((await val(`select count(*)::int from crm_membership_tiers`)) === 3, 'tier belum ada');
  await db.query(`update crm_settings set earn_amount = 1000, min_redeem_points = 1`);
  shift4 = await val(`select pos_open_shift($1, 0)`, [outletId]);
});
await check('daftar member, nomor HP dinormalisasi (08.. -> 628..)', async () => {
  const c = await val(`select crm_register_customer('Budi', '0812-3456-7890')`);
  customerId = c.id;
  assert(c.phone === '6281234567890' && c.code === 'MBR-000001', JSON.stringify(c));
});
await check('nomor HP ganda ditolak', () =>
  expectError(`select crm_register_customer('Budi 2', '+62 812 3456 7890')`, [], /sudah terdaftar/));
await check('cari member dari POS', async () => {
  const r = await val(`select crm_search_customers('3456')`);
  assert(r.length === 1 && r[0].name === 'Budi', JSON.stringify(r));
});
await check('saldo poin tidak bisa diubah langsung', () =>
  expectError(`update crm_customers set points_balance = 99999 where id = $1`, [customerId], /permission denied/));

console.log('\nPromo & voucher:');
let order4;
await check('promo otomatis terbaik dipilih (10% semua vs 50% minuman)', async () => {
  const company = await val(`select sys_current_company_id()`);
  const drinks = await val(`select id from mst_menu_categories where name = 'Minuman'`);
  await db.query(`insert into crm_promotions (company_id, name, discount_type, discount_value) values ($1, 'Diskon 10%', 'percent', 10)`, [company]);
  await db.query(`insert into crm_promotions (company_id, name, discount_type, discount_value, menu_category_ids)
                  values ($1, 'Minuman 50%', 'percent', 50, array[$2::uuid])`, [company, drinks]);
  order4 = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'takeaway', customer_id: customerId,
    items: [{ menu_item_id: await menuId('MKN01') }, { menu_item_id: await menuId('MNM01') }],
  })]);
  // 10% x 43.000 = 4.300  >  50% x 8.000 = 4.000
  assert(Number(order4.promotion_amount) === 4300, `promo ${order4.promotion_amount}`);
  assert(order4.customer_id === customerId && order4.customer_name === 'Budi', 'member tidak terpasang');
});
await check('voucher member: ditolak tanpa member, diterima dengan member', async () => {
  const company = await val(`select sys_current_company_id()`);
  await db.query(`insert into crm_promotions (company_id, name, voucher_code, discount_type, discount_value, min_subtotal, requires_member, per_customer_limit)
                  values ($1, 'Hemat 10rb', 'HEMAT10', 'amount', 10000, 30000, true, 1)`, [company]);
  await db.query(`select pos_set_order_customer($1, null)`, [order4.id]);
  await expectError(`select pos_apply_voucher($1, 'hemat10')`, [order4.id], /tidak memenuhi syarat/);
  await db.query(`select pos_set_order_customer($1, $2)`, [order4.id, customerId]);
  const o = await val(`select pos_apply_voucher($1, 'hemat10')`, [order4.id]);
  assert(Number(o.promotion_amount) === 10000, `promo ${o.promotion_amount}`);
});
await check('voucher salah ditolak', () => expectError(`select pos_apply_voucher($1, 'NGASAL')`, [order4.id], /tidak ditemukan/));
await check('bayar: poin bertambah, statistik member & kuota promo terupdate', async () => {
  await payCash(order4.id);
  // (43.000 - 10.000) / 1.000 = 33 poin
  const c = await one(`select points_balance, visit_count, total_spent from crm_customers where id = $1`, [customerId]);
  const o = await one(`select points_earned, grand_total from pos_orders where id = $1`, [order4.id]);
  assert(c.points_balance === 33 && o.points_earned === 33 && c.visit_count === 1, JSON.stringify({ c, o }));
  assert(Number(c.total_spent) === Number(o.grand_total), 'total_spent salah');
  assert((await val(`select usage_count from crm_promotions where voucher_code = 'HEMAT10'`)) === 1, 'kuota tidak bertambah');
});
await check('jurnal: potongan promo masuk Diskon Penjualan', async () => {
  const d = await val(`select l.debit from fin_journal_lines l join fin_journals j on j.id = l.journal_id
    join fin_accounts a on a.id = l.account_id where j.source_id = $1 and a.system_key = 'sales_discount'`, [order4.id]);
  assert(Number(d) === 10000, `diskon ${d}`);
});
let order5;
await check('voucher sekali per member tidak bisa dipakai lagi', async () => {
  order5 = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'takeaway', customer_id: customerId,
    items: [{ menu_item_id: await menuId('MKN03') }],
  })]);
  await expectError(`select pos_apply_voucher($1, 'HEMAT10')`, [order5.id], /tidak memenuhi syarat/);
});
await check('tukar poin: tidak boleh melebihi saldo', () =>
  expectError(`select pos_redeem_points($1, 999)`, [order5.id], /tidak cukup/));
await check('tukar 20 poin = potongan Rp 2.000, saldo terpotong saat bayar', async () => {
  const o = await val(`select pos_redeem_points($1, 20)`, [order5.id]);
  assert(Number(o.points_amount) === 2000, `poin ${o.points_amount}`);
  await payCash(order5.id);
  const c = await one(`select points_balance from crm_customers where id = $1`, [customerId]);
  const earned = await val(`select points_earned from pos_orders where id = $1`, [order5.id]);
  assert(c.points_balance === 33 - 20 + earned, `saldo ${c.points_balance}`);
  const tx = await val(`select count(*)::int from crm_point_transactions where customer_id = $1`, [customerId]);
  assert(tx === 3, `transaksi poin ${tx}`);
});
await check('koreksi poin manual tercatat & tidak boleh minus', async () => {
  const before = await val(`select points_balance from crm_customers where id = $1`, [customerId]);
  const after = await val(`select crm_adjust_points($1, 50, 'Bonus ulang tahun')`, [customerId]);
  assert(after === before + 50, `${before} -> ${after}`);
  await expectError(`select crm_adjust_points($1, -99999, 'x')`, [customerId], /minus/);
});
await check('neraca tetap seimbang setelah promo & poin', async () => {
  const r = await one(`select sum(debit) d, sum(credit) c from fin_journal_lines`);
  assert(Number(r.d) === Number(r.c), JSON.stringify(r));
});
await db.query(`update crm_promotions set is_active = false`);

console.log('\nQR self-order:');
let token;
await check('setiap meja punya token QR', async () => {
  token = await val(`select qr_token from mst_tables where code = 'A2'`);
  assert(token && token.length === 32, token);
});
await check('tamu (tanpa login) bisa lihat menu', async () => {
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;`);
  const m = await val(`select public_get_table_menu($1)`, [token]);
  assert(m.table.code === 'A2' && m.items.length === 9, JSON.stringify(m).slice(0, 200));
  const nasgor = m.items.find((i) => i.name === 'Nasi Goreng Spesial');
  assert(nasgor.modifier_groups.length === 2 && Number(nasgor.price) === 35000, JSON.stringify(nasgor));
});
await check('QR palsu ditolak', () => expectError(`select public_get_table_menu('palsu')`, [], /tidak valid/));
await check('tamu tetap tidak bisa membaca tabel langsung', async () => {
  assert((await val(`select count(*)::int from pos_orders`)) === 0, 'anon bisa baca order');
});
let qrOrderNumber;
await check('tamu memesan -> item menunggu konfirmasi kasir', async () => {
  const m = await val(`select public_get_table_menu($1)`, [token]);
  const nasgor = m.items.find((i) => i.name === 'Nasi Goreng Spesial');
  const egg = nasgor.modifier_groups.flatMap((g) => g.modifiers).find((x) => x.name === 'Telur');
  const r = await val(`select public_submit_table_order($1, 'Meja Dua', $2::jsonb)`, [token, JSON.stringify([
    { menu_item_id: nasgor.id, quantity: 2, modifier_ids: [egg.id], note: 'pedas' },
    { menu_item_id: m.items.find((i) => i.name === 'Es Jeruk').id, quantity: 1, modifier_ids: [egg.id] },  // modifier tidak berlaku utk es jeruk
  ])]);
  qrOrderNumber = r.order_number;
  assert(Number(r.subtotal) === (35000 + 5000) * 2 + 12000, `subtotal ${r.subtotal}`);
  assert(r.items.every((i) => i.kitchen_status === 'waiting'), JSON.stringify(r.items));
});
await check('pesanan kedua dari meja yang sama digabung ke order yang sama', async () => {
  const m = await val(`select public_get_table_menu($1)`, [token]);
  const r = await val(`select public_submit_table_order($1, 'Meja Dua', $2::jsonb)`,
    [token, JSON.stringify([{ menu_item_id: m.items.find((i) => i.name === 'Es Teh Manis').id, quantity: 2 }])]);
  assert(r.order_number === qrOrderNumber && r.items.length === 3, JSON.stringify(r));
});
await check('anti-spam: terlalu banyak item ditolak', async () => {
  const m = await val(`select public_get_table_menu($1)`, [token]);
  const items = Array.from({ length: 40 }, () => ({ menu_item_id: m.items[0].id }));
  await expectError(`select public_submit_table_order($1, 'x', $2::jsonb)`, [token, JSON.stringify(items)], /Terlalu banyak/);
});
await check('order QR belum dikonfirmasi tidak bisa dibayar', async () => {
  await loginAs(U1);
  const o = await one(`select id, order_source from pos_orders where order_number = $1`, [qrOrderNumber]);
  assert(o.order_source === 'qr', o.order_source);
  await expectError(`select pos_pay_order($1, $2::jsonb)`,
    [o.id, JSON.stringify([{ payment_method_id: await val(`select id from mst_payment_methods where code = 'cash'`), amount: 999999 }])],
    /belum dikonfirmasi/);
});
await check('kasir konfirmasi -> masuk dapur -> bisa dibayar', async () => {
  const id = await val(`select id from pos_orders where order_number = $1`, [qrOrderNumber]);
  await db.query(`select pos_confirm_qr_items($1)`, [id]);
  assert((await val(`select count(*)::int from pos_order_items where order_id = $1 and kitchen_status = 'pending'`, [id])) === 3, 'belum pending');
  await payCash(id);
  assert((await val(`select status from pos_orders where id = $1`, [id])) === 'paid', 'belum lunas');
});
await check('token QR bisa diganti (QR lama tidak berlaku)', async () => {
  const tableId = await val(`select id from mst_tables where code = 'A2'`);
  await db.query(`select pos_regenerate_table_qr($1)`, [tableId]);
  await expectError(`select public_get_table_menu($1)`, [token], /tidak valid/);
});
await check('QR bisa dimatikan per outlet', async () => {
  await db.query(`update sys_outlets set is_qr_order_enabled = false where id = $1`, [outletId]);
  const t = await val(`select qr_token from mst_tables where code = 'A3'`);
  await expectError(`select public_get_table_menu($1)`, [t], /tidak tersedia/);
  await db.query(`update sys_outlets set is_qr_order_enabled = true where id = $1`, [outletId]);
});
await check('perusahaan baru dapat promo demo (happy hour + voucher)', async () => {
  const U5 = '55555555-5555-5555-5555-555555555555';
  await db.exec(`reset role; insert into auth.users values ('${U5}', 'demo4@test.com')`);
  await loginAs(U5);
  await db.query(`select sys_onboard_company('Resto Empat', 'Pusat', 'Dewi')`);
  assert((await val(`select count(*)::int from crm_promotions`)) === 2, 'promo demo tidak ada');
  assert((await val(`select count(*)::int from fin_accounts`)) > 30, 'COA hilang');
});
await check('fase 1-3 tetap jalan: order biasa POS', async () => {
  await loginAs(U1);
  await db.query(`select pos_close_shift($1, 0)`, [shift4.id]);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'dine_in', table_id: await val(`select id from mst_tables where code = 'A5'`),
    items: [{ menu_item_id: await menuId('SNK02'), quantity: 1 }],
  })]);
  assert(Number(o.subtotal) === 18000 && o.status === 'open', JSON.stringify(o));
});

// =====================================================================
// FASE 5: foto menu, sold out, pindah/gabung/split bill, refund
// =====================================================================
console.log('\nMenjalankan migrasi fase 5 (di atas data fase 1-4):');
await runMigrations(allMigrations.filter((f) => f >= '010' && f < '011'));

const tableId = async (code) => val(`select id from mst_tables where code = $1 and outlet_id = $2`, [code, outletId]);
const openOrderOn = async (code) => val(`select id from pos_orders where table_id = $1 and status = 'open'`, [await tableId(code)]);

console.log('\nFoto menu:');
await check('upload foto hanya ke folder perusahaan sendiri', async () => {
  await loginAs(U1);
  const company = await val(`select sys_current_company_id()`);
  await db.query(`insert into storage.objects (bucket_id, name) values ('menu-images', $1)`, [`${company}/nasgor.jpg`]);
  await expectError(`insert into storage.objects (bucket_id, name) values ('menu-images', $1)`,
    [`00000000-0000-0000-0000-000000000000/hack.jpg`], /row-level security/);
});

console.log('\nMenu habis:');
await check('menu ditandai habis tidak bisa dipesan di POS', async () => {
  await db.query(`select pos_set_menu_sold_out($1, $2, true)`, [outletId, await menuId('MNM02')]);
  await expectError(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM02') }],
  })], /sedang habis/);
});
await check('menu habis tampil di QR & tidak bisa dipesan tamu', async () => {
  const t = await val(`select qr_token from mst_tables where code = 'A3'`);
  const esJeruk = await menuId('MNM02');
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;`);
  const soldOut = await val(`select public_get_sold_out_items($1)`, [t]);
  assert(soldOut.includes(esJeruk), JSON.stringify(soldOut));
  await expectError(`select public_submit_table_order($1, 'x', $2::jsonb)`, [t, JSON.stringify([{ menu_item_id: esJeruk }])], /sedang habis/);
});
await check('tersedia lagi setelah status habis dicabut', async () => {
  await loginAs(U1);
  await db.query(`select pos_set_menu_sold_out($1, $2, false)`, [outletId, await menuId('MNM02')]);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM02') }],
  })]);
  await db.query(`select pos_void_order($1, 'tes')`, [o.id]);
});

console.log('\nPindah / gabung / split bill:');
await check('pindah meja A5 -> A6', async () => {
  const id = await openOrderOn('A5');
  await db.query(`select pos_move_order_table($1, $2)`, [id, await tableId('A6')]);
  const r = await one(`select (select status from mst_tables where code = 'A5') a5, (select status from mst_tables where code = 'A6') a6`);
  assert(r.a5 === 'available' && r.a6 === 'occupied', JSON.stringify(r));
});
await check('gabung bill meja B1 ke meja A6', async () => {
  const b1 = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, table_id: await tableId('B1'), sales_channel: 'dine_in', guest_count: 2,
    items: [{ menu_item_id: await menuId('MKN01'), quantity: 2 }],
  })]);
  const target = await val(`select pos_merge_orders($1, $2)`, [await openOrderOn('A6'), b1.id]);
  assert(Number(target.subtotal) === 18000 + 70000, `subtotal ${target.subtotal}`);
  const src = await one(`select status, subtotal from pos_orders where id = $1`, [b1.id]);
  assert(src.status === 'merged' && Number(src.subtotal) === 0, JSON.stringify(src));
  assert((await val(`select status from mst_tables where code = 'B1'`)) === 'available', 'B1 masih terisi');
});
let splitOrder;
await check('split 1 dari 2 porsi nasi goreng ke bill baru', async () => {
  const id = await openOrderOn('A6');
  const line = await one(`select id from pos_order_items where order_id = $1 and menu_item_name = 'Nasi Goreng Spesial'`, [id]);
  splitOrder = await val(`select pos_split_order($1, $2::jsonb)`, [id, JSON.stringify([{ order_item_id: line.id, quantity: 1 }])]);
  assert(Number(splitOrder.subtotal) === 35000, `split ${splitOrder.subtotal}`);
  assert(Number(await val(`select subtotal from pos_orders where id = $1`, [id])) === 53000, 'sisa bill salah');
});
await check('split semua item ditolak (bill asal tidak boleh kosong)', async () => {
  const id = await openOrderOn('A6');
  const lines = (await db.query(`select id from pos_order_items where order_id = $1`, [id])).rows;
  await expectError(`select pos_split_order($1, $2::jsonb)`, [id, JSON.stringify(lines.map((l) => ({ order_item_id: l.id })))], /minimal satu/);
});

console.log('\nRefund:');
let shift5;
await check('refund + kembalikan stok: poin, stok, status kembali', async () => {
  shift5 = await val(`select pos_open_shift($1, 100000)`, [outletId]);
  await db.query(`select pos_set_order_customer($1, $2)`, [splitOrder.id, customerId]);
  const pointsBefore = await val(`select points_balance from crm_customers where id = $1`, [customerId]);
  const riceBefore = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN01' and warehouse_name like 'Gudang%'`));
  await payCash(splitOrder.id);
  assert((await val(`select points_balance from crm_customers where id = $1`, [customerId])) > pointsBefore, 'poin tidak bertambah');
  const r = await val(`select pos_refund_order($1, 'Salah input menu', true)`, [splitOrder.id]);
  assert(r.refund_number.startsWith('RFD/'), r.refund_number);
  assert((await val(`select points_balance from crm_customers where id = $1`, [customerId])) === pointsBefore, 'poin tidak kembali');
  const riceAfter = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN01' and warehouse_name like 'Gudang%'`));
  assert(riceAfter === riceBefore, `beras ${riceBefore} -> ${riceAfter}`);
  assert((await val(`select status from pos_orders where id = $1`, [splitOrder.id])) === 'refunded', 'status');
});
await check('refund dua kali ditolak', () =>
  expectError(`select pos_refund_order($1, 'lagi')`, [splitOrder.id], /Hanya order lunas/));
await check('refund tanpa kembalikan stok: HPP tetap tercatat', async () => {
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({
    outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MKN04') }],
  })]);
  await payCash(o.id);
  const cogsBefore = await balanceOf('cogs');
  await db.query(`select pos_refund_order($1, 'Pelanggan komplain', false)`, [o.id]);
  assert((await balanceOf('cogs')) === cogsBefore, 'HPP ikut dibalik');
});
await check('neraca tetap seimbang setelah refund', async () => {
  const r = await one(`select sum(debit) d, sum(credit) c from fin_journal_lines`);
  assert(Number(r.d) === Number(r.c), JSON.stringify(r));
  const rows = (await db.query(`select * from fin_get_account_balances('2000-01-01', '2100-01-01') where not is_header`)).rows;
  const natural = (type) => (["asset", "cogs", "expense"].includes(type) ? "debit" : "credit");
  const total = (type) => rows.filter((x) => x.account_type === type)
    .reduce((s, x) => s + (x.normal_balance === natural(type) ? 1 : -1) * Number(x.closing_balance), 0);
  const diff = total('asset') - (total('liability') + total('equity') + total('revenue') - total('cogs') - total('expense'));
  assert(Math.abs(diff) < 0.01, `selisih ${diff}`);
});
await check('kas shift: tunai masuk dikurangi refund tunai', async () => {
  const r = await val(`select pos_close_shift($1, 100000)`, [shift5.id]);
  assert(Number(r.expected_cash) === 100000 && Number(r.difference) === 0, JSON.stringify(r));
});
await check('laporan refund & void terisi', async () => {
  assert((await val(`select count(*)::int from rpt_refunds`)) === 2, 'refund');
  assert((await val(`select count(*)::int from rpt_voids`)) >= 3, 'void');
});
await check('pelayan (tanpa izin refund) tidak bisa refund', async () => {

  const company = await val(`select sys_current_company_id()`);
  const waiter = await val(`select id from sys_roles where code = 'waiter'`);
  await db.query(`insert into sys_user_invitations (company_id, email, role_id, outlet_ids) values ($1, 'pelayan@test.com', $2, array[$3::uuid])`, [company, waiter, outletId]);
  await db.exec(`reset role; insert into auth.users values ('${U6}', 'pelayan@test.com')`);
  await loginAs(U6);
  await db.query(`select sys_accept_invitation((select (sys_get_my_invitations()->0->>'id')::uuid), 'Rudi')`);
  await expectError(`select pos_refund_order($1, 'x')`, [splitOrder.id], /izin/);
});

// =====================================================================
// FASE 6: logo & profil, log aktivitas, approval, payment gateway
// =====================================================================
console.log('\nMenjalankan migrasi fase 6 (di atas data fase 1-5):');
await runMigrations(allMigrations.filter((f) => f >= '011' && f < '014'));

const asServiceRole = () => db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role service_role;`);
let company1;

console.log('\nLogo & profil:');
await check('owner ubah profil (nama, HP, foto) & logo perusahaan', async () => {
  await loginAs(U1);
  company1 = await val(`select sys_current_company_id()`);
  await db.query(`select sys_update_my_profile('Andi Owner', '0812-1111-2222', 'https://x/avatar.webp')`);
  await db.query(`update sys_companies set logo_url = 'https://x/logo.webp' where id = $1`, [company1]);
  const p = await val(`select sys_get_my_profile()`);
  assert(p.full_name === 'Andi Owner' && p.phone === '081211112222' && p.avatar_url && p.company_logo_url, JSON.stringify(p));
});
await check('upload logo hanya untuk yang berizin, foto profil hanya milik sendiri', async () => {
  await db.query(`insert into storage.objects (bucket_id, name) values ('company-assets', $1)`, [`${company1}/logo/logo.webp`]);
  await loginAs(U6);   // pelayan
  await expectError(`insert into storage.objects (bucket_id, name) values ('company-assets', $1)`, [`${company1}/logo/hack.webp`], /row-level security/);
  await db.query(`insert into storage.objects (bucket_id, name) values ('company-assets', $1)`, [`${company1}/avatars/${U6}-1.webp`]);
  await expectError(`insert into storage.objects (bucket_id, name) values ('company-assets', $1)`, [`${company1}/avatars/${U1}-1.webp`], /row-level security/);
});
await check('pelayan tidak bisa ubah profil user lain', () =>
  expectError(`select sys_update_user_profile($1, 'Hack', null, null)`, [U1], /izin/));

console.log('\nLog aktivitas:');
await check('login tercatat sekali (tidak dobel saat reload)', async () => {
  await loginAs(U1);
  await db.query(`select sys_log_login()`);
  await db.query(`select sys_log_login()`);
  assert((await val(`select count(*)::int from sys_activity_logs where user_id = $1 and action = 'login'`, [U1])) === 1, 'login dobel');
});
await check('perubahan harga menu tercatat (lama -> baru, siapa)', async () => {
  await db.query(`update mst_menu_items set base_price = 37000 where code = 'MKN01'`);
  const log = await one(`select * from sys_activity_logs where entity_type = 'mst_menu_items' and action = 'update' order by id desc limit 1`);
  assert(log.entity_label === 'Nasi Goreng Spesial' && log.user_name === 'Andi Owner', JSON.stringify(log));
  assert(JSON.stringify(log.changes.base_price) === JSON.stringify([35000, 37000]), JSON.stringify(log.changes));
  await db.query(`update mst_menu_items set base_price = 35000 where code = 'MKN01'`);
});
await check('order lunas / refund tercatat sebagai aksi', async () => {
  const actions = (await db.query(`select distinct action from sys_activity_logs where entity_type = 'pos_orders'`)).rows.map((r) => r.action);
  assert(actions.length === 0 || actions.every((a) => ['paid', 'void', 'refunded', 'merged'].includes(a)), JSON.stringify(actions));
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM01') }] })]);
  await db.query(`select pos_void_order($1, 'tes log')`, [o.id]);
  assert((await val(`select count(*)::int from sys_activity_logs where entity_id = $1 and action = 'void'`, [o.id])) === 1, 'void tidak tercatat');
});
await check('daftar user menampilkan login terakhir', async () => {
  const users = await val(`select sys_list_users()`);
  assert(users.find((u) => u.id === U1).last_login_at, 'last_login_at kosong');
});
await check('pelayan tidak bisa membaca log', async () => {
  await loginAs(U6);
  assert((await val(`select count(*)::int from sys_activity_logs`)) === 0, 'pelayan bisa baca log');
});

console.log('\nApproval:');
const U7 = '77777777-7777-7777-7777-777777777777';
await check('siapkan manajer & aktifkan aturan approval', async () => {
  await loginAs(U1);
  assert((await val(`select count(*)::int from sys_approval_rules where not is_enabled`)) === 5, 'aturan default harus nonaktif');
  await db.query(`update sys_approval_rules set is_enabled = true`);
  await db.query(`update sys_roles set permissions = permissions || '["finance.manage"]'::jsonb where code = 'manager'`);
  const role = await val(`select id from sys_roles where code = 'manager'`);
  await db.query(`insert into sys_user_invitations (company_id, email, role_id, outlet_ids) values ($1, 'manajer@test.com', $2, array[$3::uuid])`, [company1, role, outletId]);
  await db.exec(`reset role; insert into auth.users values ('${U7}', 'manajer@test.com')`);
  await loginAs(U7);
  await db.query(`select sys_accept_invitation((sys_get_my_invitations()->0->>'id')::uuid, 'Maya Manajer')`);
});
let bigPo;
await check('PO besar oleh manajer -> menunggu persetujuan', async () => {
  const sup = await val(`select id from pur_suppliers where code = 'SUP01'`);
  const wh = await val(`select id from inv_warehouses where outlet_id = $1`, [outletId]);
  const item = await val(`select id from inv_items where code = 'BHN05'`);
  const kg = await val(`select id from inv_units where code = 'kg'`);
  bigPo = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, sup, wh])).id;
  await db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price)
                  values ($1, $2, $3, $4, 1000, 200, 45000)`, [company1, bigPo, item, kg]);
  const r = await val(`select pur_approve_purchase_order($1)`, [bigPo]);
  assert(r.pending_approval === true && r.status === 'pending_approval', JSON.stringify(r));
  await expectError(`select pur_create_goods_receipt_from_po($1)`, [bigPo], /approved/);
});
await check('PO kecil oleh manajer langsung disetujui', async () => {
  const sup = await val(`select id from pur_suppliers where code = 'SUP02'`);
  const wh = await val(`select id from inv_warehouses where outlet_id = $1`, [outletId]);
  const item = await val(`select id from inv_items where code = 'BHN04'`);
  const g = await val(`select id from inv_units where code = 'g'`);
  const po = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, sup, wh])).id;
  await db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, $4, 1000, 17)`, [company1, po, item, g]);
  assert((await val(`select pur_approve_purchase_order($1)`, [po])).status === 'approved', 'tidak langsung approved');
});
await check('owner melihat badge & menyetujui PO besar', async () => {
  await loginAs(U1);
  assert((await val(`select sys_count_my_pending_approvals()`)) >= 1, 'badge 0');
  const req = await val(`select id from sys_approval_requests where document_id = $1`, [bigPo]);
  await db.query(`select sys_decide_approval($1, true, 'OK')`, [req]);
  const po = await one(`select status, po_number from pur_purchase_orders where id = $1`, [bigPo]);
  assert(po.status === 'approved' && po.po_number, JSON.stringify(po));
});
await check('biaya besar: ditolak -> tidak ada jurnal; disetujui -> jurnal dibuat', async () => {
  await loginAs(U7);
  const exp = await val(`select id from fin_accounts where code = '6-1200'`);
  const cash = await val(`select id from fin_accounts where system_key = 'cash'`);
  assert((await val(`select fin_record_expense(current_date, $1, $2, 3000000, 'Sewa Oktober')`, [exp, cash])) === null, 'harusnya pending');
  assert((await val(`select fin_record_expense(current_date, $1, $2, 3000000, 'Sewa Oktober (2)')`, [exp, cash])) === null, 'harusnya pending');
  await loginAs(U1);
  const reqs = (await db.query(`select id from sys_approval_requests where document_type = 'expense' and status = 'pending' order by requested_at`)).rows;
  await db.query(`select sys_decide_approval($1, false, 'Dobel')`, [reqs[1].id]);
  await db.query(`select sys_decide_approval($1, true)`, [reqs[0].id]);
  const n = await val(`select count(*)::int from fin_journals where source_type = 'expense' and description like 'Sewa Oktober%'`);
  assert(n === 1, `jurnal sewa ${n}`);
});
await check('waste besar perlu persetujuan; yang kecil langsung', async () => {
  await loginAs(U7);
  const wh = await val(`select id from inv_warehouses where outlet_id = $1`, [outletId]);
  const small = (await one(`insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type) values ($1, $2, 'waste') returning id`, [company1, wh])).id;
  await db.query(`insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity) values ($1, $2, (select id from inv_items where code = 'BHN06'), 2)`, [company1, small]);
  await db.query(`select inv_post_stock_adjustment($1)`, [small]);
  assert((await val(`select status from inv_stock_adjustments where id = $1`, [small])) === 'posted', 'kecil harus langsung');
  const big = (await one(`insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type) values ($1, $2, 'waste') returning id`, [company1, wh])).id;
  await db.query(`insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity) values ($1, $2, (select id from inv_items where code = 'BHN05'), 20000)`, [company1, big]);
  await db.query(`select inv_post_stock_adjustment($1)`, [big]);
  assert((await val(`select status from inv_stock_adjustments where id = $1`, [big])) === 'pending_approval', 'besar harus pending');
  // manajer diberi hak approval stok, tapi tetap tidak boleh menyetujui permintaannya sendiri
  await loginAs(U1);
  await db.query(`update sys_roles set permissions = permissions || '["approval.stock_adjustment"]'::jsonb where code = 'manager'`);
  await loginAs(U7);
  const req = await val(`select id from sys_approval_requests where document_id = $1`, [big]);
  await expectError(`select sys_decide_approval($1, true)`, [req], /sendiri/);
  await db.query(`select sys_cancel_approval($1)`, [req]);
  assert((await val(`select status from inv_stock_adjustments where id = $1`, [big])) === 'draft', 'batal harus kembali draft');
});
let qrisOrder;
await check('pelayan mengajukan refund, owner menyetujui', async () => {
  await loginAs(U1);
  const shift = await val(`select pos_open_shift($1, 0)`, [outletId]);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM03') }] })]);
  await db.query(`select pos_pay_order($1, $2::jsonb)`, [o.id, JSON.stringify([{ payment_method_id: await val(`select id from mst_payment_methods where code = 'qris'`), amount: o.grand_total }])]);
  qrisOrder = o.id;
  await loginAs(U6);
  const r = await val(`select pos_refund_order($1, 'Kopi tumpah')`, [o.id]);
  assert(r.pending_approval === true, JSON.stringify(r));
  assert((await val(`select status from pos_orders where id = $1`, [o.id])) === 'paid', 'belum boleh refund');
  await loginAs(U1);
  await db.query(`select sys_decide_approval((select id from sys_approval_requests where document_id = $1), true)`, [o.id]);
  const after = await one(`select o.status, r.refunded_by from pos_orders o join pos_refunds r on r.order_id = o.id where o.id = $1`, [o.id]);
  assert(after.status === 'refunded' && after.refunded_by === U6, JSON.stringify(after));
  await db.query(`select pos_close_shift($1, 0)`, [shift.id]);
});
await check('keputusan approval tercatat di log', async () => {
  const n = await val(`select count(*)::int from sys_activity_logs where entity_type = 'sys_approval_requests' and action in ('approved', 'rejected')`);
  assert(n >= 3, `log approval ${n}`);
});

console.log('\nPayment gateway (iPay88):');
let gatewayId;
let gwOrder;
let gwShift;
await check('aktifkan gateway -> metode "Online (iPay88)" muncul', async () => {
  await loginAs(U1);
  gatewayId = (await one(`insert into sys_payment_gateways (company_id, merchant_code, is_active) values ($1, 'ID00001', true) returning id`, [company1])).id;
  const m = await one(`select type, is_active, account_id from mst_payment_methods where code = 'ipay88'`);
  assert(m.type === 'gateway' && m.is_active && m.account_id, JSON.stringify(m));
});
await check('merchant key: bisa disimpan, tidak bisa dibaca dari aplikasi', async () => {
  await db.query(`select sys_set_payment_gateway_secret($1, 'RAHASIA123')`, [gatewayId]);
  assert((await val(`select has_merchant_key from sys_payment_gateways where id = $1`, [gatewayId])) === true, 'flag');
  assert((await val(`select count(*)::int from sys_payment_gateway_secrets`)) === 0, 'secret terbaca!');
  await expectError(`update sys_payment_gateways set has_merchant_key = false`, [], /permission denied/);
});
await check('kasir buat permintaan bayar online; tidak bisa "lunas manual"', async () => {
  gwShift = await val(`select pos_open_shift($1, 0)`, [outletId]);
  gwOrder = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MKN03') }] })]);
  const r = await val(`select pos_create_gateway_payment($1)`, [gwOrder.id]);
  assert(r.status === 'pending' && r.ref_no.endsWith('-1') && Number(r.amount) === Number(gwOrder.grand_total), JSON.stringify(r));
  await expectError(`select pos_pay_order($1, $2::jsonb)`,
    [gwOrder.id, JSON.stringify([{ payment_method_id: await val(`select id from mst_payment_methods where code = 'ipay88'`), amount: gwOrder.grand_total }])],
    /otomatis/);
  await expectError(`select pos_complete_gateway_payment('x', true, 1, null, null, null, null)`, [], /permission denied/);
});
await check('callback iPay88: nominal salah ditolak, nominal benar -> lunas & terjurnal', async () => {
  await loginAs(U1);
  const ref1 = await val(`select ref_no from pos_payment_requests where order_id = $1`, [gwOrder.id]);
  await asServiceRole();
  const bad = await val(`select pos_complete_gateway_payment($1, true, 1, 'T1', 'A1', null, '{}')`, [ref1]);
  assert(bad.status === 'failed', JSON.stringify(bad));
  await loginAs(U1);
  const ref2 = (await val(`select pos_create_gateway_payment($1)`, [gwOrder.id])).ref_no;
  await asServiceRole();
  const ok = await val(`select pos_complete_gateway_payment($1, true, $2, 'T2', 'A2', null, '{}')`, [ref2, gwOrder.grand_total]);
  assert(ok.status === 'success', JSON.stringify(ok));
  await val(`select pos_complete_gateway_payment($1, true, $2, 'T2', 'A2', null, '{}')`, [ref2, gwOrder.grand_total]);   // callback dobel
  await loginAs(U1);
  const o = await one(`select status, (select count(*)::int from pos_payments where order_id = $1) payments,
                              (select count(*)::int from fin_journals where source_type = 'sales' and source_id = $1) journals
                       from pos_orders where id = $1`, [gwOrder.id]);
  assert(o.status === 'paid' && o.payments === 1 && o.journals === 1, JSON.stringify(o));
  await db.query(`select pos_close_shift($1, 0)`, [gwShift.id]);
});
await check('neraca tetap seimbang di akhir semua skenario', async () => {
  const r = await one(`select sum(debit) d, sum(credit) c from fin_journal_lines`);
  assert(Number(r.d) === Number(r.c), JSON.stringify(r));
});

console.log('\nMenjalankan migrasi fase 7 (master produk):');
await runMigrations(allMigrations.filter((f) => f >= '014'));

const itemId = async (code) => val(`select id from inv_items where code = $1 and company_id = $2`, [code, company1]);
const mainWh = async () => val(`select id from inv_warehouses where outlet_id = $1`, [outletId]);

console.log('\nMaster produk - data lama:');
await check('satuan diberi metrik (g = berat, ml = volume)', async () => {
  await loginAs(U1);
  const r = await one(`select (select metric from inv_units where code = 'g' and company_id = $1) g,
                              (select metric from inv_units where code = 'ml' and company_id = $1) ml,
                              (select metric from inv_units where code = 'pcs' and company_id = $1) pcs`, [company1]);
  assert(r.g === 'weight' && r.ml === 'volume' && r.pcs === 'unit', JSON.stringify(r));
});
await check('setiap produk lama punya baris satuan dasar + unit beli/transfer/jual', async () => {
  const r = await one(`select
      (select count(*)::int from inv_items) items,
      (select count(*)::int from inv_item_units u join inv_items i on i.id = u.item_id where u.unit_id = i.base_unit_id and u.conversion_qty = 1) base_rows,
      (select count(*)::int from inv_item_units where is_purchase_unit) purchase,
      (select count(*)::int from inv_item_units where is_sales_unit) sales`);
  assert(r.items === r.base_rows && r.items === r.purchase && r.items === r.sales, JSON.stringify(r));
  const beras = await one(`select un.code from inv_item_units u join inv_units un on un.id = u.unit_id
                           where u.item_id = $1 and u.is_purchase_unit`, [await itemId('BHN01')]);
  assert(beras.code === 'kg', `unit beli beras ${beras.code}`);
});

console.log('\nMaster produk - kategori, satuan, produk:');
let catProtein;
await check('kategori bertipe + sub kategori, produk baru otomatis punya satuan dasar', async () => {
  catProtein = await val(`select id from inv_item_categories where name = 'Protein' and company_id = $1`, [company1]);
  assert((await val(`select category_type from inv_item_categories where id = $1`, [catProtein])) === 'inventory', 'tipe default');
  const sub = (await one(`insert into inv_item_sub_categories (company_id, name) values ($1, 'Unggas') returning id`, [company1])).id;
  const pcs = await val(`select id from inv_units where code = 'pcs' and company_id = $1`, [company1]);
  const it = (await one(`insert into inv_items (company_id, item_category_id, sub_category_id, code, name, base_unit_id, item_type, is_saleable)
                         values ($1, $2, $3, 'BHN90', 'Telur Bebek', $4, 'raw', false) returning id`, [company1, catProtein, sub, pcs])).id;
  const u = await one(`select conversion_qty, is_purchase_unit, is_transfer_unit, is_sales_unit from inv_item_units where item_id = $1`, [it]);
  assert(Number(u.conversion_qty) === 1 && u.is_purchase_unit && u.is_transfer_unit && u.is_sales_unit, JSON.stringify(u));
});
await check('satuan dasar: konversi wajib 1 & tidak bisa dihapus', async () => {
  const it = await itemId('BHN90');
  await expectError(`update inv_item_units set conversion_qty = 2 where item_id = $1`, [it], /harus 1/);
  await expectError(`delete from inv_item_units where item_id = $1`, [it], /tidak bisa dihapus/);
});
await check('barcode unik per perusahaan & hanya satu unit beli per produk', async () => {
  await db.query(`update inv_item_units set barcode = '8991234567890' where item_id = $1`, [await itemId('BHN90')]);
  await expectError(`update inv_item_units set barcode = '8991234567890' where item_id = $1 and is_sales_unit`, [await itemId('BHN06')], /duplicate|unique/);
  await expectError(`update inv_item_units set is_purchase_unit = true where item_id = $1`, [await itemId('BHN01')], /duplicate|unique/);
});
await check('produk "tidak bisa dibeli" ditolak di PO', async () => {
  await db.query(`update inv_items set is_purchasable = false where code = 'BHN90'`);
  const po = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, (select id from pur_suppliers where code = 'SUP01'), $2) returning id`, [company1, await mainWh()])).id;
  await expectError(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price)
                     values ($1, $2, $3, (select base_unit_id from inv_items where code = 'BHN90'), 1, 1000)`,
    [company1, po, await itemId('BHN90')], /tidak bisa dibeli/);
  await db.query(`delete from pur_purchase_orders where id = $1`, [po]);
});

console.log('\nMaster produk - min/max per gudang:');
await check('min/max per gudang menggantikan stok minimum global & memberi saran beli', async () => {
  const wh = await mainWh();
  const qty = Number(await val(`select quantity from rpt_stock_balances where item_code = 'BHN04' and warehouse_id = $1`, [wh]));
  await db.query(`insert into inv_item_stock_levels (company_id, warehouse_id, item_id, min_qty, max_qty) values ($1, $2, $3, $4, $5)`,
    [company1, wh, await itemId('BHN04'), qty + 100, qty + 500]);
  const r = await one(`select is_low_stock, suggested_order_qty, max_qty from rpt_stock_balances where item_code = 'BHN04' and warehouse_id = $1`, [wh]);
  assert(r.is_low_stock && Number(r.suggested_order_qty) === 500, JSON.stringify(r));
  await expectError(`insert into inv_item_stock_levels (company_id, warehouse_id, item_id, min_qty, max_qty) values ($1, $2, $3, 10, 5)`,
    [company1, wh, await itemId('BHN05')], /check/);
});
await check('salin min/max ke gudang lain', async () => {
  const ck = await val(`select id from inv_warehouses where code = 'WH-CK' and company_id = $1`, [company1]);
  assert((await val(`select inv_copy_stock_levels($1, $2)`, [await mainWh(), ck])) === 1, 'jumlah salin');
  assert((await val(`select count(*)::int from inv_item_stock_levels where warehouse_id = $1`, [ck])) === 1, 'tidak tersalin');
});

console.log('\nMaster produk - import Excel:');
await check('import dengan error: tidak ada yang disimpan, error per baris', async () => {
  const before = await val(`select count(*)::int from inv_items`);
  const r = await val(`select inv_import_items($1::jsonb, false)`, [JSON.stringify([
    { kode: 'IMP01', nama: 'Gula Merah', kategori: 'Bumbu', satuan: 'g', harga_beli: '25' },
    { kode: 'BHN01', nama: 'Dobel', kategori: 'Bumbu', satuan: 'g' },
    { kode: 'IMP02', nama: 'Kategori Baru', kategori: 'Frozen', satuan: 'g' },
    { kode: 'IMP03', nama: 'Harga Salah', kategori: 'Bumbu', satuan: 'g', harga_beli: 'abc' },
    { kode: 'IMP04', nama: 'Flag Salah', kategori: 'Bumbu', satuan: 'g', dapat_dijual: 'mungkin' },
  ])]);
  assert(r.inserted === 0 && r.errors.length === 4, JSON.stringify(r));
  assert(r.errors.map((e) => e.row).join(',') === '2,3,4,5', JSON.stringify(r.errors));
  assert((await val(`select count(*)::int from inv_items`)) === before, 'ada yang tersimpan');
});
await check('import valid + buat kategori/satuan baru otomatis', async () => {
  const r = await val(`select inv_import_items($1::jsonb, true)`, [JSON.stringify([
    { kode: 'imp10', nama: 'Nugget Ayam', tipe: 'barang jadi', kategori: 'Frozen', sub_kategori: 'Olahan Ayam', satuan: 'pcs',
      satuan_beli: 'dus', konversi_beli: '24', harga_beli: '1500', stok_minimum: '48', dapat_dijual: 'ya', kena_pajak: 'TIDAK',
      toleransi_terima: '5', barcode: '8990000000010', info_1: 'Halal' },
    { kode: 'IMP11', nama: 'Saus Sambal', kategori: 'Bumbu', satuan: 'ml', harga_beli: '30,5' },
  ])]);
  assert(r.inserted === 2 && r.errors.length === 0, JSON.stringify(r));
  const it = await one(`select i.code, i.item_type, i.is_saleable, i.receipt_tolerance_pct, i.custom_fields, c.name cat, s.name sub
                        from inv_items i join inv_item_categories c on c.id = i.item_category_id
                        left join inv_item_sub_categories s on s.id = i.sub_category_id where i.code = 'IMP10'`);
  assert(it.item_type === 'finished' && it.is_saleable && Number(it.receipt_tolerance_pct) === 5 && it.cat === 'Frozen'
    && it.sub === 'Olahan Ayam' && it.custom_fields['1'] === 'Halal', JSON.stringify(it));
  const pu = await one(`select un.code, u.conversion_qty from inv_item_units u join inv_units un on un.id = u.unit_id
                        where u.item_id = $1 and u.is_purchase_unit`, [await itemId('IMP10')]);
  assert(pu.code === 'dus' && Number(pu.conversion_qty) === 24, JSON.stringify(pu));
  assert(Number(await val(`select last_purchase_cost from inv_items where code = 'IMP11'`)) === 30.5, 'angka koma');
});
await check('import menu + harga ojol', async () => {
  const r = await val(`select mst_import_menu_items($1::jsonb, true)`, [JSON.stringify([
    { kode: 'MNU50', nama: 'Es Kopi Susu', kategori: 'Kopi', harga: '25000', harga_gofood: '30000', station: 'bar' },
    { kode: 'MNU51', nama: 'Croissant', kategori: 'Pastry', harga: '28000', station: 'pastry', aktif: 'tidak' },
  ])]);
  assert(r.inserted === 2, JSON.stringify(r));
  const m = await one(`select m.station, (select price from mst_menu_prices where menu_item_id = m.id and sales_channel = 'gofood') gofood
                       from mst_menu_items m where code = 'MNU50'`);
  assert(m.station === 'bar' && Number(m.gofood) === 30000, JSON.stringify(m));
  const dup = await val(`select mst_import_menu_items($1::jsonb, true)`, [JSON.stringify([{ kode: 'mnu50', nama: 'x', kategori: 'Kopi', harga: '1' }])]);
  assert(dup.inserted === 0 && /sudah terdaftar/.test(dup.errors[0].message), JSON.stringify(dup));
});

console.log('\nMaster produk - akun per kategori:');
await check('HPP & persediaan dijurnal ke akun kategori', async () => {
  const hppProtein = (await one(`insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance)
    values ($1, (select id from fin_accounts where code = '5-0000' and company_id = $1), '5-1150', 'HPP Protein', 'cogs', 'debit') returning id`, [company1])).id;
  const invProtein = (await one(`insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance)
    values ($1, (select id from fin_accounts where code = '1-0000' and company_id = $1), '1-1410', 'Persediaan Protein', 'asset', 'debit') returning id`, [company1])).id;
  await db.query(`update inv_item_categories set cogs_account_id = $1, inventory_account_id = $2 where id = $3`, [hppProtein, invProtein, catProtein]);

  const shift = await val(`select pos_open_shift($1, 0)`, [outletId]);
  const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MKN03') }] })]);
  await payCash(o.id);
  await db.query(`select pos_close_shift($1, (select opening_cash + 0 from pos_shifts where id = $1))`, [shift.id]);
  const lines = (await db.query(`select a.code, l.debit, l.credit from fin_journal_lines l join fin_journals j on j.id = l.journal_id
    join fin_accounts a on a.id = l.account_id where j.source_id = $1 and a.code in ('5-1150', '1-1410', '5-1100', '1-1400')`, [o.id])).rows;
  const byCode = Object.fromEntries(lines.map((l) => [l.code, l]));
  assert(Number(byCode['5-1150']?.debit) > 0 && Number(byCode['1-1410']?.credit) > 0, JSON.stringify(lines));
  assert(Number(byCode['5-1100']?.debit) > 0, 'HPP bahan non-protein harus tetap di akun default');
  const r = await one(`select sum(debit) d, sum(credit) c from fin_journal_lines`);
  assert(Number(r.d) === Number(r.c), JSON.stringify(r));
});

// helper: buka shift owner, jalankan fn, tutup shift
const withShift = async (fn) => {
  const shift = await val(`select pos_open_shift($1, 0)`, [outletId]);
  try { return await fn(); } finally { await db.query(`select pos_close_shift($1, 0)`, [shift.id]); }
};
const stockOf = async (code) => Number(await val(`select quantity from rpt_stock_balances where item_code = $1 and warehouse_id = $2`, [code, await mainWh()]));
const newItem = async (code, name, unitCode, cost, type = 'raw', category = 'Bumbu') => (await one(
  `insert into inv_items (company_id, item_category_id, code, name, base_unit_id, item_type, last_purchase_cost)
   values ($1, (select id from inv_item_categories where name = $6 and company_id = $1), $2, $3,
           (select id from inv_units where code = $4 and company_id = $1), $5, $7) returning id`,
  [company1, code, name, unitCode, type, category, cost])).id;
const journalBalanced = async () => {
  const r = await one(`select sum(debit) d, sum(credit) c from fin_journal_lines`);
  assert(Number(r.d) === Number(r.c), `jurnal tidak seimbang ${JSON.stringify(r)}`);
};

console.log('\nBOM & produksi:');
await check('produksi assembly: bahan (+waste) terpotong, hasil masuk dengan HPP termasuk biaya gas', async () => {
  const bumbu = await newItem('BHN95', 'Bumbu Dasar Merah', 'g', 0, 'semi_finished');
  const recipe = (await one(`insert into inv_recipes (company_id, item_id, recipe_type, code, name, yield_qty)
                             values ($1, $2, 'assembly', 'BOM-BUMBU', 'Bumbu Dasar 1 kg', 1000) returning id`, [company1, bumbu])).id;
  await db.query(`insert into inv_recipe_items (company_id, recipe_id, item_id, quantity, waste_pct) values
                  ($1, $2, $3, 600, 10), ($1, $2, $4, 200, 0)`, [company1, recipe, await itemId('BHN11'), await itemId('BHN03')]);
  await db.query(`insert into inv_recipe_costs (company_id, recipe_id, description, account_id, amount)
                  values ($1, $2, 'Gas', (select id from fin_accounts where code = '6-1300' and company_id = $1), 5000)`, [company1, recipe]);
  const bawangBefore = await stockOf('BHN11');
  const prod = (await one(`insert into inv_productions (company_id, warehouse_id, recipe_id, quantity) values ($1, $2, $3, 2000) returning id`,
    [company1, await mainWh(), recipe])).id;
  const r = await val(`select inv_post_production($1)`, [prod]);
  assert(r.production_number.startsWith('PRD/') && Number(r.extra_cost) === 10000, JSON.stringify(r));
  assert(bawangBefore - (await stockOf('BHN11')) === 1320, `bawang terpakai ${bawangBefore - (await stockOf('BHN11'))}`);
  assert((await stockOf('BHN95')) === 2000, 'hasil produksi');
  const value = Number(await val(`select stock_value from rpt_stock_balances where item_code = 'BHN95'`));
  assert(Math.abs(value - (Number(r.input_value) + 10000)) < 1, `nilai hasil ${value}`);
  await journalBalanced();
});
await check('produksi disassembly: ayam utuh -> dada & paha, nilai dibagi sesuai bobot', async () => {
  const utuh = await newItem('BHN96', 'Ayam Utuh', 'pcs', 40000, 'raw', 'Protein');
  const dada = await newItem('BHN97', 'Dada Ayam', 'g', 0, 'semi_finished', 'Protein');
  const paha = await newItem('BHN98', 'Paha Ayam', 'g', 0, 'semi_finished', 'Protein');
  const adj = (await one(`insert into inv_stock_adjustments (company_id, warehouse_id) values ($1, $2) returning id`, [company1, await mainWh()])).id;
  await db.query(`insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity) values ($1, $2, $3, 10)`, [company1, adj, utuh]);
  await db.query(`select inv_post_stock_adjustment($1)`, [adj]);
  const recipe = (await one(`insert into inv_recipes (company_id, item_id, recipe_type, name, yield_qty) values ($1, $2, 'disassembly', 'Potong ayam', 1) returning id`, [company1, utuh])).id;
  await db.query(`insert into inv_recipe_items (company_id, recipe_id, item_id, quantity, weight_factor) values ($1, $2, $3, 400, 2), ($1, $2, $4, 600, 1)`,
    [company1, recipe, dada, paha]);
  const prod = (await one(`insert into inv_productions (company_id, warehouse_id, recipe_id, quantity) values ($1, $2, $3, 2) returning id`, [company1, await mainWh(), recipe])).id;
  await db.query(`select inv_post_production($1)`, [prod]);
  const v = await one(`select (select stock_value from rpt_stock_balances where item_code = 'BHN97') dada,
                              (select stock_value from rpt_stock_balances where item_code = 'BHN98') paha,
                              (select quantity from rpt_stock_balances where item_code = 'BHN96') utuh`);
  assert(Number(v.utuh) === 8 && Math.abs(Number(v.dada) - 53333.33) < 1 && Math.abs(Number(v.paha) - 26666.67) < 1, JSON.stringify(v));
  await journalBalanced();
});
await check('waste % ikut terpotong saat menu terjual & masuk HPP menu', async () => {
  const nasgorRecipe = await val(`select id from inv_recipes where menu_item_id = $1`, [await menuId('MKN01')]);
  const costBefore = Number(await val(`select food_cost from rpt_menu_food_costs where code = 'MKN01'`));
  await db.query(`update inv_recipe_items set waste_pct = 10 where recipe_id = $1 and item_id = $2`, [nasgorRecipe, await itemId('BHN01')]);
  await db.query(`insert into inv_recipe_costs (company_id, recipe_id, description, account_id, amount)
                  values ($1, $2, 'Kemasan', (select id from fin_accounts where code = '6-1600' and company_id = $1), 1000)`, [company1, nasgorRecipe]);
  const costAfter = Number(await val(`select food_cost from rpt_menu_food_costs where code = 'MKN01'`));
  assert(Math.abs(costAfter - costBefore - (200 * 0.1 * 14 + 1000)) < 1, `${costBefore} -> ${costAfter}`);
  const before = await stockOf('BHN01');
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MKN01') }] })]);
    await payCash(o.id);
  });
  assert(before - (await stockOf('BHN01')) === 220, `beras terpakai ${before - (await stockOf('BHN01'))}`);
  await journalBalanced();
});
await check('resep rahasia hanya terlihat oleh user yang diberi akses', async () => {
  const recipe = await val(`select id from inv_recipes where menu_item_id = $1`, [await menuId('MKN03')]);
  await db.query(`update inv_recipes set access_level = 'restricted' where id = $1`, [recipe]);
  await loginAs(U7);
  assert((await val(`select count(*)::int from inv_recipe_items where recipe_id = $1`, [recipe])) === 0, 'manajer bisa lihat resep rahasia');
  await loginAs(U1);
  await db.query(`insert into inv_recipe_access (recipe_id, user_id, company_id) values ($1, $2, $3)`, [recipe, U7, company1]);
  await loginAs(U7);
  assert((await val(`select count(*)::int from inv_recipe_items where recipe_id = $1`, [recipe])) > 0, 'akses tidak berlaku');
  await loginAs(U1);
});

console.log('\nPricelist & penerimaan:');
await check('pricelist: harga berlaku vs harga beli terakhir, kedaluwarsa tidak dipakai', async () => {
  const sup = await val(`select id from pur_suppliers where code = 'SUP01'`);
  const kg = await val(`select id from inv_units where code = 'kg' and company_id = $1`, [company1]);
  const pl = (await one(`insert into pur_pricelists (company_id, supplier_id, effective_date, expiry_date)
                         values ($1, $2, current_date, current_date + 30) returning id`, [company1, sup])).id;
  await db.query(`insert into pur_pricelist_items (company_id, pricelist_id, item_id, unit_id, conversion_qty, price) values ($1, $2, $3, $4, 1000, 42000)`,
    [company1, pl, await itemId('BHN05'), kg]);
  const a = await val(`select pur_approve_pricelist($1)`, [pl]);
  assert(a.status === 'approved' && a.pricelist_number.startsWith('PL/'), JSON.stringify(a));
  const p = await val(`select pur_get_item_price($1, $2, $3, $4)`, [sup, await itemId('BHN05'), kg, outletId]);
  assert(Number(p.pricelist.price) === 42000 && Number(p.last.price) === 45000, JSON.stringify(p));
  const later = await val(`select pur_get_item_price($1, $2, $3, $4, current_date + 60)`, [sup, await itemId('BHN05'), kg, outletId]);
  assert(later.pricelist === null, 'pricelist kedaluwarsa masih dipakai');
});
await check('toleransi terima: lebih dari sisa PO + toleransi ditolak', async () => {
  await db.query(`update inv_items set receipt_tolerance_pct = 10 where code = 'BHN05'`);
  const kg = await val(`select id from inv_units where code = 'kg' and company_id = $1`, [company1]);
  const po = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, (select id from pur_suppliers where code = 'SUP01'), $2) returning id`, [company1, await mainWh()])).id;
  await db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price) values ($1, $2, $3, $4, 1000, 10, 42000)`,
    [company1, po, await itemId('BHN05'), kg]);
  await db.query(`select pur_approve_purchase_order($1)`, [po]);
  const gr = await val(`select pur_create_goods_receipt_from_po($1)`, [po]);
  await db.query(`update pur_goods_receipt_items set quantity = 11 where goods_receipt_id = $1`, [gr]);
  await expectError(`update pur_goods_receipt_items set quantity = 11.5 where goods_receipt_id = $1`, [gr], /melebihi sisa PO/);
  await db.query(`select pur_post_goods_receipt($1)`, [gr]);
  await journalBalanced();
});

console.log('\nApproval produk & pricelist:');
await check('produk baru dari manajer menunggu persetujuan & belum bisa dipakai', async () => {
  await db.query(`update sys_approval_rules set is_enabled = true where document_type in ('product', 'pricelist')`);
  await loginAs(U7);
  const it = await newItem('BHN99', 'Keju Mozarella', 'g', 150, 'raw', 'Protein');
  assert((await val(`select approval_status from inv_items where id = $1`, [it])) === 'pending', 'harus pending');
  await expectError(`update inv_items set approval_status = 'approved' where id = $1`, [it], /Persetujuan/);
  const recipe = await val(`select id from inv_recipes where menu_item_id = $1`, [await menuId('SNK02')]);
  await expectError(`insert into inv_recipe_items (company_id, recipe_id, item_id, quantity) values ($1, $2, $3, 10)`, [company1, recipe, it], /belum disetujui/);
});
await check('owner menyetujui produk -> bisa dipakai; menolak produk lain', async () => {
  await loginAs(U7);
  const other = await newItem('BHN89', 'Produk Iseng', 'g', 1, 'raw', 'Protein');
  await loginAs(U1);
  await db.query(`select sys_decide_approval((select id from sys_approval_requests where document_id = $1), true)`, [await itemId('BHN99')]);
  await db.query(`select sys_decide_approval((select id from sys_approval_requests where document_id = $1), false, 'Tidak perlu')`, [other]);
  const r = await one(`select (select approval_status from inv_items where code = 'BHN99') a, (select approval_status from inv_items where code = 'BHN89') b`);
  assert(r.a === 'approved' && r.b === 'rejected', JSON.stringify(r));
});
await check('pricelist dari manajer menunggu persetujuan', async () => {
  await loginAs(U7);
  const pl = (await one(`insert into pur_pricelists (company_id, supplier_id) values ($1, (select id from pur_suppliers where code = 'SUP02')) returning id`, [company1])).id;
  await db.query(`insert into pur_pricelist_items (company_id, pricelist_id, item_id, unit_id, price) values ($1, $2, $3, (select base_unit_id from inv_items where code = 'BHN04'), 16)`,
    [company1, pl, await itemId('BHN04')]);
  assert((await val(`select pur_approve_pricelist($1)`, [pl])).pending_approval === true, 'harus pending');
  await loginAs(U1);
  await db.query(`select sys_decide_approval((select id from sys_approval_requests where document_id = $1), true)`, [pl]);
  assert((await val(`select status from pur_pricelists where id = $1`, [pl])) === 'approved', 'belum approved');
});

console.log('\nMenu paket & jadwal harga:');
await check('menu paket: harga tambahan isi & stok isi paket ikut terpotong', async () => {
  const brand = await val(`select id from sys_brands where company_id = $1 limit 1`, [company1]);
  const paket = (await one(`insert into mst_menu_items (company_id, brand_id, menu_category_id, code, name, base_price)
                            values ($1, $2, (select id from mst_menu_categories where name = 'Makanan' and company_id = $1), 'PKT01', 'Paket Hemat', 40000) returning id`, [company1, brand])).id;
  const grp = (await one(`insert into mst_modifier_groups (company_id, name, group_type, min_select, max_select) values ($1, 'Pilih Minuman', 'package', 1, 1) returning id`, [company1])).id;
  await db.query(`insert into mst_modifiers (company_id, modifier_group_id, name, extra_price, menu_item_id, is_default) values
                  ($1, $2, 'Es Teh', 0, $3, true), ($1, $2, 'Es Jeruk', 3000, $4, false)`, [company1, grp, await menuId('MNM01'), await menuId('MNM02')]);
  await db.query(`insert into mst_menu_item_modifier_groups (company_id, menu_item_id, modifier_group_id) values ($1, $2, $3)`, [company1, paket, grp]);
  const jeruk = await val(`select id from mst_modifiers where modifier_group_id = $1 and name = 'Es Jeruk'`, [grp]);
  const before = await stockOf('BHN10');
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: paket, modifier_ids: [jeruk] }] })]);
    assert(Number(o.subtotal) === 43000, `subtotal ${o.subtotal}`);
    await payCash(o.id);
  });
  assert(before - (await stockOf('BHN10')) === 2, 'jeruk isi paket tidak terpotong');
  await journalBalanced();
});
await check('modifier "Extra Telur" memotong bahan telur', async () => {
  const telur = await val(`select id from mst_modifiers where name = 'Telur' and company_id = $1`, [company1]);
  await db.query(`update mst_modifiers set item_id = $1, item_qty = 1 where id = $2`, [await itemId('BHN06'), telur]);
  const before = await stockOf('BHN06');
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MKN01'), modifier_ids: [telur] }] })]);
    await payCash(o.id);
  });
  assert(before - (await stockOf('BHN06')) === 2, `telur terpakai ${before - (await stockOf('BHN06'))}`);
});
await check('jadwal harga mengganti harga menu otomatis (sesuai kanal)', async () => {
  const esTeh = await menuId('MNM01');
  const sch = (await one(`insert into mst_price_schedules (company_id, name, sales_channels) values ($1, 'Promo Teh Dine-in', array['dine_in']) returning id`, [company1])).id;
  await db.query(`insert into mst_price_schedule_items (company_id, schedule_id, menu_item_id, price) values ($1, $2, $3, 5000)`, [company1, sch, esTeh]);
  assert(Number(await val(`select mst_get_menu_price($1, $2, 'dine_in')`, [esTeh, outletId])) === 5000, 'jadwal tidak berlaku');
  assert(Number(await val(`select mst_get_menu_price($1, $2, 'takeaway')`, [esTeh, outletId])) === 8000, 'kanal lain ikut berubah');
  const prices = await val(`select mst_get_current_menu_prices($1, 'dine_in')`, [outletId]);
  assert(Number(prices[esTeh]) === 5000, 'harga POS');
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'dine_in', table_id: await val(`select id from mst_tables where code = 'B4'`), items: [{ menu_item_id: esTeh }] })]);
    assert(Number(o.subtotal) === 5000, `subtotal ${o.subtotal}`);
    await payCash(o.id);
  });
  const t = await val(`select qr_token from mst_tables where code = 'A3'`);
  const m = await val(`select public_get_table_menu($1)`, [t]);
  assert(Number(m.items.find((i) => i.id === esTeh).price) === 5000, 'harga QR');
  await db.query(`update mst_price_schedules set is_active = false where id = $1`, [sch]);
  assert(Number(await val(`select mst_get_menu_price($1, $2, 'dine_in')`, [esTeh, outletId])) === 8000, 'jadwal nonaktif masih berlaku');
});
await check('neraca tetap seimbang setelah semua skenario master produk', async () => {
  const rows = (await db.query(`select * from fin_get_account_balances('2000-01-01', '2100-01-01') where not is_header`)).rows;
  const natural = (type) => (['asset', 'cogs', 'expense'].includes(type) ? 'debit' : 'credit');
  const total = (type) => rows.filter((x) => x.account_type === type)
    .reduce((s, x) => s + (x.normal_balance === natural(type) ? 1 : -1) * Number(x.closing_balance), 0);
  const diff = total('asset') - (total('liability') + total('equity') + total('revenue') - total('cogs') - total('expense'));
  assert(Math.abs(diff) < 0.01, `selisih ${diff}`);
});

console.log('\nNama aplikasi:');
await check('nama aplikasi bisa diatur & muncul di profil (kosong = default)', async () => {
  await loginAs(U1);
  assert((await val(`select sys_get_my_profile()`)).company_app_name === null, 'default harus null');
  await db.query(`update sys_companies set app_name = 'Achphoria POS' where id = $1`, [company1]);
  assert((await val(`select sys_get_my_profile()`)).company_app_name === 'Achphoria POS', 'tidak tersimpan');
  await expectError(`update sys_companies set app_name = '   ' where id = $1`, [company1], /check/);
});

console.log(`\n${passed} lulus, ${failed} gagal\n`);
process.exit(failed ? 1 : 0);
