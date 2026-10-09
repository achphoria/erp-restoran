// Uji migrasi SQL secara lokal dengan PGlite (PostgreSQL di Node.js).
// Mensimulasikan lingkungan Supabase: schema auth, role authenticated, RLS.
// Jalankan: npm run test:db
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// tanggal tes konsisten seperti CI (UTC), walau dijalankan jam 00-07 WIB
process.env.TZ = 'UTC';
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
  create table auth.users (id uuid primary key, email text, created_at timestamptz default now(), email_confirmed_at timestamptz, last_sign_in_at timestamptz);
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
  assert(r.production_number.startsWith('SM/') && r.production_number.endsWith(' - 1') && Number(r.extra_cost) === 10000, JSON.stringify(r));
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

console.log('\nPurpose stok & opname baru:');
const purposeId = async (type, name) => val(`select id from inv_adjustment_purposes where company_id = $1 and adjustment_type = $2 and name = $3`, [company1, type, name]);
const accCode = async (id) => val(`select code from fin_accounts where id = $1`, [id]);
const newAdj = async (type, purpose, lines) => {
  const doc = (await one(`insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type, purpose_id) values ($1, $2, $3, $4) returning id`,
    [company1, await mainWh(), type, purpose])).id;
  for (const l of lines) {
    await db.query(`insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity, purpose_id) values ($1, $2, $3, $4, $5)`,
      [company1, doc, await itemId(l.code), l.qty, l.purpose ?? null]);
  }
  return doc;
};
const journalAccounts = async (docId) => Object.fromEntries((await db.query(
  `select a.code, sum(l.debit) d, sum(l.credit) c from fin_journal_lines l join fin_journals j on j.id = l.journal_id
   join fin_accounts a on a.id = l.account_id where j.source_id = $1 group by a.code`, [docId])).rows.map((r) => [r.code, { d: Number(r.d), c: Number(r.c) }]));

await check('purpose bawaan & akun pemakaian/penyusutan dibuat untuk perusahaan lama', async () => {
  await loginAs(U1);
  const r = await one(`select (select count(*)::int from inv_adjustment_purposes where company_id = $1) purposes,
    (select count(*)::int from fin_accounts where company_id = $1 and system_key in ('usage_expense', 'shrinkage_expense')) accounts`, [company1]);
  assert(r.purposes === 15 && r.accounts === 2, JSON.stringify(r));
  assert((await accCode(await val(`select account_id from inv_adjustment_purposes where name = 'Makan Karyawan' and company_id = $1`, [company1]))) === '6-1100', 'akun makan karyawan');
});
await check('waste: qty selalu mengurangi stok & dijurnal ke akun purpose', async () => {
  const before = await stockOf('BHN06');
  const doc = await newAdj('waste', await purposeId('waste', 'Kedaluwarsa'), [{ code: 'BHN06', qty: 3 }]);
  await db.query(`select inv_post_stock_adjustment($1)`, [doc]);
  assert(before - (await stockOf('BHN06')) === 3, 'stok tidak berkurang 3');
  assert((await val(`select adjustment_number from inv_stock_adjustments where id = $1`, [doc])).startsWith('WST/'), 'nomor');
  const j = await journalAccounts(doc);
  // telur = kategori Protein yang memakai akun persediaan khusus 1-1410
  assert(j['5-1200']?.d > 0 && Math.abs(j['5-1200'].d - (j['1-1410']?.c ?? 0)) < 0.01, JSON.stringify(j));
});
await check('pemakaian: purpose per baris boleh berbeda (dua akun beban)', async () => {
  const doc = await newAdj('usage', await purposeId('usage', 'Makan Karyawan'), [
    { code: 'BHN01', qty: 500 },
    { code: 'BHN14', qty: 5, purpose: await purposeId('usage', 'Tester / Sampling') },
  ]);
  await db.query(`select inv_post_stock_adjustment($1)`, [doc]);
  assert((await val(`select adjustment_number from inv_stock_adjustments where id = $1`, [doc])).startsWith('USG/'), 'nomor');
  const j = await journalAccounts(doc);
  assert(j['6-1100']?.d > 0 && j['6-1500']?.d > 0, JSON.stringify(j));
});
await check('penyusutan tanpa purpose ditolak; dengan purpose ke akun penyusutan', async () => {
  const bad = await newAdj('shrinkage', null, [{ code: 'BHN08', qty: 100 }]);
  await expectError(`select inv_post_stock_adjustment($1)`, [bad], /purpose/);
  await db.query(`update inv_stock_adjustments set purpose_id = $1 where id = $2`, [await purposeId('shrinkage', 'Penyusutan Bahan Baku'), bad]);
  await db.query(`select inv_post_stock_adjustment($1)`, [bad]);
  assert((await journalAccounts(bad))['5-1500']?.d > 0, 'akun penyusutan');
});
await check('akun purpose bisa diganti & dipakai di jurnal berikutnya', async () => {
  const p = await purposeId('waste', 'Human Error');
  const acc = (await one(`insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance)
    values ($1, (select id from fin_accounts where code = '5-0000' and company_id = $1), '5-1210', 'Waste Human Error', 'cogs', 'debit') returning id`, [company1])).id;
  await db.query(`update inv_adjustment_purposes set account_id = $1 where id = $2`, [acc, p]);
  const doc = await newAdj('waste', p, [{ code: 'BHN04', qty: 50 }]);
  await db.query(`select inv_post_stock_adjustment($1)`, [doc]);
  assert((await journalAccounts(doc))['5-1210']?.d > 0, 'akun purpose baru tidak dipakai');
});
await check('penyesuaian plus tanpa purpose: lawan = akun selisih stok kategori', async () => {
  const doc = await newAdj('adjustment', null, [{ code: 'BHN04', qty: 100 }]);
  await db.query(`select inv_post_stock_adjustment($1)`, [doc]);
  const j = await journalAccounts(doc);
  assert(j['1-1400']?.d > 0 && j['5-1300']?.c > 0, JSON.stringify(j));
});
await check('opname: selisih dihitung terhadap POTRET, penjualan setelah hitung tidak mengacaukan', async () => {
  const cat = await val(`select id from inv_item_categories where name = 'Bumbu' and company_id = $1`, [company1]);
  const op = (await one(`insert into inv_stock_opnames (company_id, warehouse_id, item_category_id) values ($1, $2, $3) returning id`, [company1, await mainWh(), cat])).id;
  const n = await val(`select inv_generate_opname_items($1)`, [op]);
  assert(n >= 3, `item opname ${n}`);
  const snap = Number(await val(`select system_qty from inv_stock_opname_items where stock_opname_id = $1 and item_id = $2`, [op, await itemId('BHN11')]));
  assert(snap === (await stockOf('BHN11')), 'potret tidak sama dengan stok saat itu');
  // hasil hitung: kurang 10 dari potret; lalu ada pemakaian 5 g setelah penghitungan
  await db.query(`update inv_stock_opname_items set counted_qty = $1 where stock_opname_id = $2 and item_id = $3`, [snap - 10, op, await itemId('BHN11')]);
  const use = await newAdj('usage', await purposeId('usage', 'Peralatan Dapur'), [{ code: 'BHN11', qty: 5 }]);
  await db.query(`select inv_post_stock_adjustment($1)`, [use]);
  const otherBefore = await stockOf('BHN12');
  await db.query(`select inv_post_stock_opname($1)`, [op]);
  assert((await stockOf('BHN11')) === snap - 5 - 10, `stok akhir ${await stockOf('BHN11')}, harusnya ${snap - 15}`);
  assert((await stockOf('BHN12')) === otherBefore, 'produk yang belum dihitung ikut berubah');
});
await check('opname: potret ulang & tanpa hasil hitung ditolak', async () => {
  const op = (await one(`insert into inv_stock_opnames (company_id, warehouse_id) values ($1, $2) returning id`, [company1, await mainWh()])).id;
  await db.query(`select inv_generate_opname_items($1)`, [op]);
  await expectError(`select inv_post_stock_opname($1)`, [op], /Belum ada produk yang dihitung/);
  await db.query(`update inv_stock_opname_items set system_qty = 0 where stock_opname_id = $1`, [op]);
  await db.query(`select inv_refresh_opname_snapshot($1)`, [op]);
  assert(Number(await val(`select system_qty from inv_stock_opname_items where stock_opname_id = $1 and item_id = $2`, [op, await itemId('BHN01')])) === (await stockOf('BHN01')), 'potret ulang');
  await journalBalanced();
});

console.log('\nBatch, FIFO/FEFO & koli:');
const days = (n) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
const newGr = async (code, qty, price, extra = {}) => {
  const gr = (await one(`insert into pur_goods_receipts (company_id, supplier_id, warehouse_id)
    values ($1, (select id from pur_suppliers where code = 'SUP01' and company_id = $1), $2) returning id`, [company1, await mainWh()])).id;
  await db.query(`insert into pur_goods_receipt_items (company_id, goods_receipt_id, item_id, unit_id, conversion_qty, quantity, unit_price, lot_number, expiry_date)
    values ($1, $2, $3, (select base_unit_id from inv_items where id = $3), 1, $4, $5, $6, $7)`,
    [company1, gr, await itemId(code), qty, price, extra.lot ?? null, extra.expiry ?? null]);
  return gr;
};
const grIn = async (code, qty, price, extra) => {
  const gr = await newGr(code, qty, price, extra);
  await db.query(`select pur_post_goods_receipt($1)`, [gr]);
};
const batchesOf = async (code, wh) => (await db.query(
  `select id, batch_code, lot_number, expiry_date::text expiry, qty_remaining::float8 qty, unit_cost::float8 cost from inv_stock_batches
   where item_id = $1 and warehouse_id = $2 order by received_at, created_at`, [await itemId(code), wh ?? await mainWh()])).rows;
const wasteOf = async (code, qty, batchId = null) => {
  const doc = await newAdj('waste', await purposeId('waste', 'Kedaluwarsa'), [{ code, qty }]);
  if (batchId) await db.query(`update inv_stock_adjustment_items set batch_id = $1 where stock_adjustment_id = $2`, [batchId, doc]);
  await db.query(`select inv_post_stock_adjustment($1)`, [doc]);
  return one(`select unit_cost::float8 cost, unbatched_qty::float8 unbatched from inv_stock_movements where reference_id = $1`, [doc]);
};
const batchInvariant = async () => {
  const bad = await db.query(`select s.item_id, s.quantity, coalesce(sum(b.qty_remaining), 0) remaining
    from inv_stocks s left join inv_stock_batches b on b.warehouse_id = s.warehouse_id and b.item_id = s.item_id
    group by s.id, s.item_id, s.quantity having greatest(s.quantity, 0) <> coalesce(sum(b.qty_remaining), 0)`);
  assert(!bad.rows.length, `sisa batch != saldo: ${JSON.stringify(bad.rows.slice(0, 3))}`);
};

await check('saldo lama otomatis jadi batch saldo awal (sisa batch = saldo stok)', async () => {
  await loginAs(U1);
  assert((await val(`select count(*)::int from inv_stock_batches where reference_type = 'opening' and company_id = $1`, [company1])) > 0, 'tidak ada batch saldo awal');
  await batchInvariant();
});
await check('FIFO cost: keluar mengambil batch tertua, HPP = harga batch', async () => {
  await newItem('BTC01', 'Susu UHT', 'pcs', 1000);
  await grIn('BTC01', 10, 1000);
  await grIn('BTC01', 10, 1500);
  const m = await wasteOf('BTC01', 15);
  assert(Math.abs(m.cost - (10 * 1000 + 5 * 1500) / 15) < 0.001, `cost ${m.cost}`);
  const b = await batchesOf('BTC01');
  assert(b.length === 2 && b[0].qty === 0 && b[1].qty === 5, JSON.stringify(b));
  assert(Number(await val(`select average_cost from inv_stocks where item_id = $1 and warehouse_id = $2`, [await itemId('BTC01'), await mainWh()])) === 1500, 'nilai sisa');
  assert(/^L\d{10}$/.test(b[0].batch_code), `kode batch ${b[0].batch_code}`);
});
await check('FEFO: batch yang kedaluwarsa duluan diambil dulu; produk lacak batch wajib kedaluwarsa', async () => {
  await newItem('BTC02', 'Susu Segar', 'pcs', 1000);
  await db.query(`update inv_items set track_batch = true where id = $1`, [await itemId('BTC02')]);
  const bad = await newGr('BTC02', 5, 1000);
  await expectError(`select pur_post_goods_receipt($1)`, [bad], /kedaluwarsa/);
  await db.query(`delete from pur_goods_receipts where id = $1`, [bad]);
  await grIn('BTC02', 10, 1000, { lot: 'LOT-A', expiry: days(10) });
  await grIn('BTC02', 10, 1200, { lot: 'LOT-B', expiry: days(3) });
  const m = await wasteOf('BTC02', 4);
  assert(m.cost === 1200, `harus dari LOT-B (kedaluwarsa duluan), cost ${m.cost}`);
  const b = await batchesOf('BTC02');
  assert(b[0].lot_number === 'LOT-A' && b[0].qty === 10 && b[1].qty === 6 && b[1].expiry === days(3), JSON.stringify(b));
  await db.query(`update inv_items set shelf_life_days = 7 where id = $1`, [await itemId('BTC02')]);
  await grIn('BTC02', 2, 1100);
  assert((await batchesOf('BTC02'))[2].expiry === days(7), 'kedaluwarsa otomatis dari umur simpan');
});
await check('scan label batch: waste mengambil batch yang dipilih', async () => {
  const [a] = await batchesOf('BTC02');
  const m = await wasteOf('BTC02', 2, a.id);
  assert(m.cost === 1000 && (await batchesOf('BTC02'))[0].qty === 8, 'batch pilihan tidak terpakai');
});
await check('stok minus: dicatat tanpa batch, lalu ditutup batch berikutnya', async () => {
  await newItem('BTC03', 'Keju Slice', 'pcs', 2000);
  const m = await wasteOf('BTC03', 5);
  assert(m.unbatched === 5 && m.cost === 2000, JSON.stringify(m));
  await grIn('BTC03', 8, 2200);
  const b = await batchesOf('BTC03');
  assert(b.length === 1 && b[0].qty === 3 && (await stockOf('BTC03')) === 3, JSON.stringify(b));
  assert((await val(`select count(*)::int from inv_stock_movement_batches where batch_id = $1 and is_backfill`, [b[0].id])) === 1, 'backfill');
});
await check('penjualan POS memotong batch & refund mengembalikan ke batch asal', async () => {
  const before = await batchesOf('BHN01');
  await withShift(async () => {
    const order = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MKN01') }] })]);
    await payCash(order.id);
    const mv = await one(`select m.id, m.quantity::float8 q, round(m.quantity * m.unit_cost, 2)::float8 v from inv_stock_movements m
      where m.reference_id = $1 and m.item_id = $2`, [order.id, await itemId('BHN01')]);
    const al = await one(`select sum(quantity)::float8 q, sum(quantity * unit_cost)::float8 v from inv_stock_movement_batches where movement_id = $1`, [mv.id]);
    assert(al.q === mv.q && Math.abs(al.v - mv.v) < 0.01, `alokasi ${JSON.stringify({ mv, al })}`);
    await db.query(`select pos_refund_order($1, 'Batch test', true)`, [order.id]);
  });
  const after = await batchesOf('BHN01');
  assert(JSON.stringify(after.map((b) => [b.id, b.qty])) === JSON.stringify(before.map((b) => [b.id, b.qty])), 'batch tidak kembali seperti semula');
  await journalBalanced();
});
await check('transfer per koli: dikirim (dalam perjalanan) -> diterima per koli, kekurangan dijurnal', async () => {
  const wh2 = (await one(`insert into inv_warehouses (company_id, code, name) values ($1, 'WH-B2', 'Gudang Cabang') returning id`, [company1])).id;
  const tr = (await one(`insert into inv_stock_transfers (company_id, from_warehouse_id, to_warehouse_id) values ($1, $2, $3) returning id`, [company1, await mainWh(), wh2])).id;
  const k1 = (await one(`insert into inv_transfer_packages (company_id, stock_transfer_id, package_no) values ($1, $2, 1) returning id`, [company1, tr])).id;
  const k2 = (await one(`insert into inv_transfer_packages (company_id, stock_transfer_id, package_no) values ($1, $2, 2) returning id`, [company1, tr])).id;
  const [lotA] = await batchesOf('BTC02');
  await db.query(`insert into inv_stock_transfer_items (company_id, stock_transfer_id, item_id, quantity, package_id, batch_id) values ($1, $2, $3, 3, $4, $5)`,
    [company1, tr, await itemId('BTC02'), k1, lotA.id]);
  await db.query(`insert into inv_stock_transfer_items (company_id, stock_transfer_id, item_id, quantity, package_id) values ($1, $2, $3, 5, $4)`,
    [company1, tr, await itemId('BTC01'), k2]);
  const src = await stockOf('BTC01');
  await db.query(`select inv_ship_stock_transfer($1)`, [tr]);
  assert((await val(`select status from inv_stock_transfers where id = $1`, [tr])) === 'in_transit', 'status');
  assert(src - (await stockOf('BTC01')) === 5 && (await batchesOf('BTC01', wh2)).length === 0, 'stok dalam perjalanan');
  const code1 = await val(`select package_code from inv_transfer_packages where id = $1`, [k1]);
  const r = await val(`select inv_resolve_barcode($1, $2)`, [code1.toLowerCase(), wh2]);
  assert(r.kind === 'package' && r.package_id === k1, JSON.stringify(r));

  await db.query(`select inv_receive_transfer_package($1, null)`, [k1]);
  const d = await batchesOf('BTC02', wh2);
  assert(d.length === 1 && d[0].batch_code === lotA.batch_code && d[0].lot_number === 'LOT-A' && d[0].expiry === lotA.expiry && d[0].cost === 1000 && d[0].qty === 3, JSON.stringify(d));
  assert((await val(`select status from inv_stock_transfers where id = $1`, [tr])) === 'in_transit', 'belum semua koli');

  const line2 = await val(`select id from inv_stock_transfer_items where package_id = $1`, [k2]);
  const res = await val(`select inv_receive_transfer_package($1, $2::jsonb)`, [k2, JSON.stringify([{ id: line2, received_qty: 3 }])]);
  assert(Number(res.loss_value) === 3000 && res.transfer_status === 'posted', JSON.stringify(res));
  assert((await journalAccounts(k2))['5-1200']?.d === 3000, JSON.stringify(await journalAccounts(k2)));
  assert((await batchesOf('BTC01', wh2))[0].qty === 3, 'qty diterima');
  await expectError(`select inv_receive_transfer_package($1, null)`, [k2], /sudah diterima/);
  await journalBalanced();
});
await check('scan barcode: label batch & kode produk dikenali', async () => {
  const [a] = await batchesOf('BTC02');
  const b = await val(`select inv_resolve_barcode($1, $2)`, [a.batch_code, await mainWh()]);
  assert(b.kind === 'batch' && b.batch_id === a.id, JSON.stringify(b));
  const i = await val(`select inv_resolve_barcode('btc01', null)`);
  assert(i.kind === 'item' && i.item_code === 'BTC01', JSON.stringify(i));
  assert((await val(`select inv_resolve_barcode('TIDAK-ADA', null)`)) === null, 'kode asing');
});
await check('batch hanya bisa diubah lewat dokumen (RLS) & koreksi kedaluwarsa via fungsi', async () => {
  const [a] = await batchesOf('BTC02');
  await db.query(`update inv_stock_batches set qty_remaining = 999 where id = $1`, [a.id]);
  assert((await batchesOf('BTC02'))[0].qty === a.qty, 'batch bisa diubah langsung');
  await db.query(`select inv_update_batch($1, 'LOT-A2', $2)`, [a.id, days(20)]);
  const n = await val(`select count(*)::int from inv_stock_batches where batch_code = $1 and lot_number = 'LOT-A2' and expiry_date = $2`, [a.batch_code, days(20)]);
  assert(n === 2, `semua gudang ikut terkoreksi (${n})`);
  await batchInvariant();
});

console.log('\nSales order antar cabang & B2B:');
const outletBal = async (outlet, key) => Number(await val(
  `select coalesce(sum(l.debit - l.credit), 0) from fin_journal_lines l join fin_accounts a on a.id = l.account_id
   where a.system_key = $1 and l.company_id = $2 and l.outlet_id is not distinct from $3`, [key, company1, outlet]));
const grTo = async (wh, code, qty, price, lot = null, expiry = null) => {
  const gr = (await one(`insert into pur_goods_receipts (company_id, supplier_id, warehouse_id)
    values ($1, (select id from pur_suppliers where code = 'SUP01' and company_id = $1), $2) returning id`, [company1, wh])).id;
  await db.query(`insert into pur_goods_receipt_items (company_id, goods_receipt_id, item_id, unit_id, conversion_qty, quantity, unit_price, lot_number, expiry_date)
    values ($1, $2, $3, (select base_unit_id from inv_items where id = $3), 1, $4, $5, $6, $7)`, [company1, gr, await itemId(code), qty, price, lot, expiry]);
  await db.query(`select pur_post_goods_receipt($1)`, [gr]);
};
let sc, ck, intSupplier, icPo, icSo, icDelivery;

await check('outlet baru otomatis jadi supplier internal; 1 toko bisa punya beberapa gudang', async () => {
  await loginAs(U1);
  sc = (await val(`select sys_create_outlet('SC01', 'Supply Chain')`)).id;
  intSupplier = await one(`select id, supplier_type, linked_outlet_id from pur_suppliers where linked_outlet_id = $1`, [sc]);
  assert(intSupplier?.supplier_type === 'internal', 'supplier internal tidak dibuat');
  ck = (await one(`insert into inv_warehouses (company_id, outlet_id, code, name, warehouse_type) values ($1, $2, 'WH-CK1', 'Central Kitchen', 'central_kitchen') returning id`, [company1, sc])).id;
  assert((await val(`select count(*)::int from inv_warehouses where outlet_id = $1`, [sc])) === 2, '2 gudang');
  assert((await val(`select count(*)::int from fin_accounts where company_id = $1 and system_key in ('ic_receivable','ic_payable','ic_grni','ic_revenue','ic_cogs','so_revenue')`, [company1])) === 6, 'akun antar cabang');
});
await check('PO ke cabang internal: harga wajib & dikunci dari Pricelist Jual penjual', async () => {
  icPo = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, intSupplier.id, await mainWh()])).id;
  const unit = await val(`select base_unit_id from inv_items where id = $1`, [await itemId('BTC01')]);
  const addLine = async () => db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, $4, 10, 999)`,
    [company1, icPo, await itemId('BTC01'), unit]);
  await expectError(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, $4, 10, 999)`,
    [company1, icPo, await itemId('BTC01'), unit], /Pricelist Jual/);
  const pl = (await one(`insert into sal_pricelists (company_id, name, seller_outlet_id) values ($1, 'Harga SC', $2) returning id`, [company1, sc])).id;
  await db.query(`insert into sal_pricelist_items (company_id, pricelist_id, item_id, unit_id, price) values ($1, $2, $3, $4, 2000)`, [company1, pl, await itemId('BTC01'), unit]);
  await addLine();
  assert(Number(await val(`select unit_price from pur_purchase_order_items where purchase_order_id = $1`, [icPo])) === 2000, 'harga tidak dari pricelist');
  const own = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, intSupplier.id, ck])).id;
  await expectError(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity) values ($1, $2, $3, $4, 1)`,
    [company1, own, await itemId('BTC01'), unit], /outlet sendiri/);
});
await check('PO disetujui -> Sales Order muncul di penjual; PO internal tidak bisa diterima manual', async () => {
  await db.query(`select pur_approve_purchase_order($1)`, [icPo]);
  const so = await one(`select * from sal_sales_orders where purchase_order_id = $1`, [icPo]);
  assert(so && so.status === 'new' && so.outlet_id === sc && so.buyer_outlet_id === outletId && Number(so.grand_total) === 20000, JSON.stringify(so));
  icSo = so.id;
  await expectError(`select pur_create_goods_receipt_from_po($1)`, [icPo], /Pengiriman penjual/);
});
await check('penjual konfirmasi & kirim sebagian dari Central Kitchen (batch FEFO, HPP antar cabang)', async () => {
  await grTo(ck, 'BTC01', 20, 1200, 'LOT-SC', days(30));
  await db.query(`select sal_confirm_sales_order($1)`, [icSo]);
  icDelivery = await val(`select sal_create_delivery($1, $2)`, [icSo, ck]);
  await db.query(`update sal_delivery_items set quantity = 6 where delivery_id = $1`, [icDelivery]);
  const ckBefore = Number(await val(`select quantity from inv_stocks where warehouse_id = $1 and item_id = $2`, [ck, await itemId('BTC01')]));
  const r = await val(`select sal_ship_delivery($1)`, [icDelivery]);
  assert(r.delivery_number.startsWith('DO/') && r.goods_receipt_id, JSON.stringify(r));
  assert(ckBefore - Number(await val(`select quantity from inv_stocks where warehouse_id = $1 and item_id = $2`, [ck, await itemId('BTC01')])) === 6, 'stok CK');
  assert((await val(`select status from sal_sales_orders where id = $1`, [icSo])) === 'partially_delivered', 'status SO');
  assert((await outletBal(sc, 'ic_cogs')) === 7200, `HPP antar cabang ${await outletBal(sc, 'ic_cogs')}`);
  assert((await val(`select count(*)::int from sal_delivery_packages where delivery_id = $1`, [icDelivery])) === 1, 'koli');
});
await check('pembeli terima kurang 1: batch & kedaluwarsa ikut, harga = harga beli, selisih dijurnal', async () => {
  const gr = await val(`select goods_receipt_id from sal_deliveries where id = $1`, [icDelivery]);
  const code = await val(`select package_code from sal_delivery_packages where delivery_id = $1`, [icDelivery]);
  const scan = await val(`select inv_resolve_barcode($1)`, [code]);
  assert(scan.kind === 'delivery_package' && scan.goods_receipt_id === gr, JSON.stringify(scan));
  await db.query(`update pur_goods_receipt_items set quantity = 5, unit_price = 1 where goods_receipt_id = $1`, [gr]);
  await db.query(`select pur_post_goods_receipt($1)`, [gr]);
  const b = (await batchesOf('BTC01')).find((x) => x.lot_number === 'LOT-SC');
  assert(b && b.qty === 5 && b.cost === 2000 && b.expiry === days(30), JSON.stringify(b));
  assert((await val(`select status from sal_deliveries where id = $1`, [icDelivery])) === 'received', 'status DO');
  assert((await outletBal(outletId, 'ic_grni')) === -12000 && (await outletBal(outletId, 'ic_shipping_diff')) === 2000, 'jurnal penerimaan');
  await expectError(`insert into fin_supplier_payment_items (company_id, supplier_payment_id, goods_receipt_id, amount)
    values ($1, gen_random_uuid(), $2, 1)`, [company1, gr], /Sales Invoice/);
  assert((await val(`select count(*)::int from rpt_payables where goods_receipt_id = $1`, [gr])) === 0, 'muncul di hutang supplier');
});
let icInvoice;
await check('invoice dari qty DIKIRIM + jurnal cermin di pembeli; nota kredit kekurangan', async () => {
  icInvoice = await val(`select sal_create_invoice($1)`, [icSo]);
  assert(Number(icInvoice.grand_total) === 12000 && icInvoice.invoice_number.startsWith('SINV/'), JSON.stringify(icInvoice));
  assert((await outletBal(sc, 'ic_receivable')) === 12000 && (await outletBal(sc, 'ic_revenue')) === -12000, 'jurnal penjual');
  assert((await outletBal(outletId, 'ic_grni')) === 0 && (await outletBal(outletId, 'ic_payable')) === -12000, 'jurnal pembeli');
  await expectError(`select sal_create_invoice($1)`, [icSo], /belum ditagih/);
  await db.query(`select sal_create_credit_note($1, 2000, 'shortage', 'kurang 1 pcs')`, [icInvoice.id]);
  assert((await outletBal(outletId, 'ic_shipping_diff')) === 0 && (await outletBal(outletId, 'ic_payable')) === -10000, 'nota kredit pembeli');
});
await check('pembayaran oleh pembeli melunasi piutang penjual; tutup SO -> PO selesai', async () => {
  const bank = await val(`select id from fin_accounts where system_key = 'bank' and company_id = $1`, [company1]);
  await expectError(`select sal_record_payment($1::jsonb, $2, $2)`, [JSON.stringify([{ invoice_id: icInvoice.id, amount: 10001 }]), bank], /melebihi/);
  const p = await val(`select sal_record_payment($1::jsonb, $2, $2, current_date, 'TRF-1')`, [JSON.stringify([{ invoice_id: icInvoice.id, amount: 10000 }]), bank]);
  assert(p.payment_number.startsWith('RCV/'), JSON.stringify(p));
  assert((await val(`select status from sal_invoices where id = $1`, [icInvoice.id])) === 'paid', 'invoice belum lunas');
  assert((await outletBal(sc, 'ic_receivable')) === 0 && (await outletBal(outletId, 'ic_payable')) === 0, 'saldo antar cabang belum nol');
  await db.query(`select sal_close_sales_order($1, 'stok habis')`, [icSo]);
  assert((await val(`select status from pur_purchase_orders where id = $1`, [icPo])) === 'received', 'status PO');
  await journalBalanced();
});
await check('SO B2B: harga pelanggan, PPN, limit kredit, pengiriman, invoice & bayar sebagian', async () => {
  const cust = (await one(`insert into sal_customers (company_id, code, name, payment_term_days, credit_limit) values ($1, 'CUST1', 'PT Katering Jaya', 14, 50000) returning id`, [company1])).id;
  const unit = await val(`select base_unit_id from inv_items where id = $1`, [await itemId('BTC01')]);
  const pl = (await one(`insert into sal_pricelists (company_id, name, customer_id) values ($1, 'Harga Katering', $2) returning id`, [company1, cust])).id;
  await db.query(`insert into sal_pricelist_items (company_id, pricelist_id, item_id, unit_id, price) values ($1, $2, $3, $4, 3000)`, [company1, pl, await itemId('BTC01'), unit]);
  const so = (await one(`insert into sal_sales_orders (company_id, outlet_id, warehouse_id, customer_type, customer_id, tax_pct) values ($1, $2, $3, 'external', $4, 11) returning id`,
    [company1, outletId, await mainWh(), cust])).id;
  await db.query(`insert into sal_sales_order_items (company_id, sales_order_id, item_id, unit_id, quantity) values ($1, $2, $3, $4, 20)`, [company1, so, await itemId('BTC01'), unit]);
  await expectError(`select sal_confirm_sales_order($1)`, [so], /limit kredit/);
  await db.query(`update sal_sales_order_items set quantity = 4 where sales_order_id = $1`, [so]);
  const c = await val(`select sal_confirm_sales_order($1)`, [so]);
  assert(Number(c.subtotal) === 12000 && Number(c.tax_amount) === 1320 && Number(c.grand_total) === 13320, JSON.stringify(c));
  const d = await val(`select sal_create_delivery($1)`, [so]);
  await db.query(`select sal_ship_delivery($1)`, [d]);
  assert((await val(`select goods_receipt_id from sal_deliveries where id = $1`, [d])) === null, 'B2B tidak punya penerimaan');
  const inv = await val(`select sal_create_invoice($1)`, [so]);
  assert(Number(inv.grand_total) === 13320 && inv.due_date === days(14), JSON.stringify(inv));
  const j = await journalAccounts(inv.id);
  assert(j['1-1300']?.d === 13320 && j['4-1600']?.c === 12000 && j['2-1220']?.c === 1320, JSON.stringify(j));
  const bank = await val(`select id from fin_accounts where system_key = 'bank' and company_id = $1`, [company1]);
  await db.query(`select sal_record_payment($1::jsonb, $2)`, [JSON.stringify([{ invoice_id: inv.id, amount: 5000 }]), bank]);
  const r = await one(`select status, outstanding_amount::float8 o, customer_name from rpt_sales_invoices where id = $1`, [inv.id]);
  assert(r.status === 'partial' && r.o === 8320 && r.customer_name === 'PT Katering Jaya', JSON.stringify(r));
  assert((await val(`select count(*)::int from rpt_revenue_by_source where source = 'sales_order_b2b'`)) > 0, 'pendapatan SO');
  await journalBalanced();
});
await check('SO cabang bisa ditolak penjual -> PO pembeli batal', async () => {
  const po = (await one(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, intSupplier.id, await mainWh()])).id;
  await db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity) values ($1, $2, $3, (select base_unit_id from inv_items where id = $3), 1)`,
    [company1, po, await itemId('BTC01')]);
  await db.query(`select pur_approve_purchase_order($1)`, [po]);
  const so = await val(`select id from sal_sales_orders where purchase_order_id = $1`, [po]);
  await expectError(`select sal_reject_sales_order($1, '')`, [so], /Alasan/);
  await db.query(`select sal_reject_sales_order($1, 'stok kosong')`, [so]);
  const r = await one(`select status, sales_note from pur_purchase_orders where id = $1`, [po]);
  assert(r.status === 'cancelled' && r.sales_note.includes('stok kosong'), JSON.stringify(r));
});

console.log('\nSettlement POS:');
await check('metode non tunai diarahkan ke akun penampung settlement', async () => {
  const m = await one(`select a.system_key from mst_payment_methods m join fin_accounts a on a.id = m.account_id where m.code = 'qris' and m.company_id = $1`, [company1]);
  assert(m.system_key === 'settlement_clearing', JSON.stringify(m));
});
await check('QRIS cair dipotong MDR: bank + beban MDR | penampung; tanggal tidak bisa di-settle dua kali', async () => {
  const qris = await val(`select id from mst_payment_methods where code = 'qris' and company_id = $1`, [company1]);
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM01') }] })]);
    await db.query(`select pos_pay_order($1, $2::jsonb)`, [o.id, JSON.stringify([{ payment_method_id: qris, amount: o.grand_total }])]);
  });
  const day = await one(`select business_date::text d, net_amount::float8 net, needs_settlement, settlement_id from rpt_pos_settlement_days
    where outlet_id = $1 and payment_method_id = $2 order by business_date desc limit 1`, [outletId, qris]);
  assert(day.needs_settlement && !day.settlement_id && day.net > 0, JSON.stringify(day));
  const before = await balanceOf('settlement_clearing');
  const fee = Math.round(day.net * 0.007);
  const s = await val(`select pos_create_settlement($1, $2, array[$3]::date[], $4, $5)`, [outletId, qris, day.d, day.net - fee, fee]);
  assert(Number(s.difference_amount) === 0 && s.settlement_number.startsWith('STL/'), JSON.stringify(s));
  assert(Math.abs((await balanceOf('settlement_clearing')) - (before - day.net)) < 0.01, 'penampung tidak berkurang');
  assert((await journalAccounts(s.id))['6-1800']?.d === fee, JSON.stringify(await journalAccounts(s.id)));
  await expectError(`select pos_create_settlement($1, $2, array[$3]::date[], 1)`, [outletId, qris, day.d], /sudah pernah/);
});
await check('setoran tunai kurang: selisih dicatat ke Selisih Kas & Settlement', async () => {
  const cash = await val(`select id from mst_payment_methods where code = 'cash' and company_id = $1`, [company1]);
  const day = await one(`select business_date::text d, net_amount::float8 net from rpt_pos_settlement_days
    where outlet_id = $1 and payment_method_id = $2 and settlement_id is null and net_amount > 0 order by business_date desc limit 1`, [outletId, cash]);
  const s = await val(`select pos_create_settlement($1, $2, array[$3]::date[], $4)`, [outletId, cash, day.d, day.net - 500]);
  assert(Number(s.difference_amount) === 500, JSON.stringify(s));
  const j = await journalAccounts(s.id);
  assert(j['6-2100']?.d === 500 && j['1-1100']?.c === day.net, JSON.stringify(j));
  await journalBalanced();
});

console.log('\nApproval semua transaksi (1 tingkat):');
const U8 = '88888888-8888-8888-8888-888888888888';
const approveLatest = async (type, approve = true) => {
  const req = await val(`select id from sys_approval_requests where document_type = $1 and status = 'pending' order by requested_at desc limit 1`, [type]);
  assert(req, `tidak ada permintaan ${type}`);
  return val(`select sys_decide_approval($1, $2, 'tes')`, [req, approve]);
};
await check('jenis transaksi baru tersedia di aturan approval (default nonaktif)', async () => {
  await loginAs(U1);
  const n = await val(`select count(*)::int from sys_approval_rules where company_id = $1 and not is_enabled and document_type in
    ('sales_order','credit_note','sales_payment','supplier_payment','pos_settlement','manual_journal','stock_transfer')`, [company1]);
  assert(n === 7, `aturan baru ${n}`);
  const role = (await one(`insert into sys_roles (company_id, code, name, permissions) values ($1, 'approver', 'Penyetuju', $2::jsonb) returning id`,
    [company1, JSON.stringify(['approval.sales_order', 'approval.credit_note', 'approval.sales_payment', 'approval.supplier_payment',
      'approval.pos_settlement', 'approval.manual_journal', 'approval.stock_transfer'])])).id;
  await db.query(`insert into sys_user_invitations (company_id, email, role_id, outlet_ids) values ($1, 'penyetuju@test.com', $2, array[$3::uuid])`, [company1, role, outletId]);
  await db.exec(`reset role; insert into auth.users values ('${U8}', 'penyetuju@test.com')`);
  await loginAs(U8);
  await db.query(`select sys_accept_invitation((sys_get_my_invitations()->0->>'id')::uuid, 'Pak Penyetuju')`);
  await loginAs(U1);
  await db.query(`update sys_approval_rules set is_enabled = true, min_amount = 0 where company_id = $1 and document_type in
    ('sales_order','credit_note','sales_payment','supplier_payment','pos_settlement','manual_journal','stock_transfer')`, [company1]);
});
await check('SO: manajer konfirmasi -> menunggu; penyetuju (tanpa akses penjualan) menyetujui; tolak -> kembali draft', async () => {
  await loginAs(U7);
  const cust = await val(`select id from sal_customers where code = 'CUST1'`);
  const mk = async () => {
    const so = (await one(`insert into sal_sales_orders (company_id, outlet_id, customer_type, customer_id) values ($1, $2, 'external', $3) returning id`, [company1, outletId, cust])).id;
    await db.query(`insert into sal_sales_order_items (company_id, sales_order_id, item_id, unit_id, quantity) values ($1, $2, $3, (select base_unit_id from inv_items where id = $3), 1)`,
      [company1, so, await itemId('BTC01')]);
    return so;
  };
  const a = await mk();
  const r = await val(`select sal_confirm_sales_order($1)`, [a]);
  assert(r.pending_approval === true && r.status === 'pending_approval', JSON.stringify(r));
  await loginAs(U8);
  await approveLatest('sales_order');
  assert((await val(`select status from sal_sales_orders where id = $1`, [a])) === 'confirmed', 'SO tidak terkonfirmasi');
  await loginAs(U7);
  const b = await mk();
  await db.query(`select sal_confirm_sales_order($1)`, [b]);
  await loginAs(U8);
  await approveLatest('sales_order', false);
  assert((await val(`select status from sal_sales_orders where id = $1`, [b])) === 'draft', 'SO ditolak harus kembali draft');
});
await check('nota kredit & pembayaran invoice menunggu persetujuan lalu dieksekusi', async () => {
  await loginAs(U7);
  const inv = await one(`select id, outstanding_amount::float8 o from rpt_sales_invoices where customer_name = 'PT Katering Jaya' and status <> 'paid' limit 1`);
  const cn = await val(`select sal_create_credit_note($1, 320, 'discount', 'pembulatan')`, [inv.id]);
  assert(cn.pending_approval === true, JSON.stringify(cn));
  assert(Number(await val(`select credited_amount from sal_invoices where id = $1`, [inv.id])) === 0, 'nota kredit langsung jalan');
  await loginAs(U8);
  await approveLatest('credit_note');
  assert(Number(await val(`select credited_amount from sal_invoices where id = $1`, [inv.id])) === 320, 'nota kredit tidak dibuat');
  await loginAs(U7);
  const bank = await val(`select id from fin_accounts where system_key = 'bank' and company_id = $1`, [company1]);
  const p = await val(`select sal_record_payment($1::jsonb, $2)`, [JSON.stringify([{ invoice_id: inv.id, amount: inv.o - 320 }]), bank]);
  assert(p.pending_approval === true, JSON.stringify(p));
  await loginAs(U8);
  await approveLatest('sales_payment');
  assert((await val(`select status from sal_invoices where id = $1`, [inv.id])) === 'paid', 'invoice belum lunas');
});
await check('bayar supplier & jurnal manual menunggu persetujuan', async () => {
  await loginAs(U7);
  const ap = await one(`select goods_receipt_id, supplier_id, outstanding_amount::float8 o from rpt_payables where outstanding_amount > 0 limit 1`);
  const bank = await val(`select id from fin_accounts where system_key = 'bank' and company_id = $1`, [company1]);
  const before = await val(`select count(*)::int from fin_supplier_payments`);
  const r = await val(`select fin_pay_supplier($1, $2, current_date, $3::jsonb)`, [ap.supplier_id, bank, JSON.stringify([{ goods_receipt_id: ap.goods_receipt_id, amount: 1000 }])]);
  assert(r.pending_approval === true && (await val(`select count(*)::int from fin_supplier_payments`)) === before, JSON.stringify(r));
  const cash = await val(`select id from fin_accounts where system_key = 'cash' and company_id = $1`, [company1]);
  const j = await val(`select fin_post_manual_journal(current_date, 'Koreksi kas', $1::jsonb)`, [JSON.stringify([{ account_id: bank, debit: 500 }, { account_id: cash, credit: 500 }])]);
  assert(j === null, 'jurnal manual langsung jalan');
  await loginAs(U8);
  await approveLatest('supplier_payment');
  await approveLatest('manual_journal');
  await loginAs(U1);
  assert((await val(`select count(*)::int from fin_supplier_payments`)) === before + 1, 'pembayaran supplier tidak dibuat');
  assert((await val(`select count(*)::int from fin_journals where source_type = 'manual' and description = 'Koreksi kas'`)) === 1, 'jurnal manual tidak dibuat');
  await journalBalanced();
});
await check('transfer gudang menunggu persetujuan, disetujui -> stok pindah', async () => {
  await loginAs(U7);
  const wh2 = await val(`select id from inv_warehouses where code = 'WH-B2'`);
  const tr = (await one(`insert into inv_stock_transfers (company_id, from_warehouse_id, to_warehouse_id) values ($1, $2, $3) returning id`, [company1, await mainWh(), wh2])).id;
  await db.query(`insert into inv_stock_transfer_items (company_id, stock_transfer_id, item_id, quantity) values ($1, $2, $3, 1)`, [company1, tr, await itemId('BTC01')]);
  await db.query(`select inv_post_stock_transfer($1)`, [tr]);
  assert((await val(`select status from inv_stock_transfers where id = $1`, [tr])) === 'pending_approval', 'harus menunggu');
  await expectError(`select inv_post_stock_transfer($1)`, [tr], /menunggu persetujuan/);
  await loginAs(U8);
  await approveLatest('stock_transfer');
  assert((await val(`select status from inv_stock_transfers where id = $1`, [tr])) === 'posted', 'transfer tidak jalan');
});
await check('settlement dengan selisih menunggu persetujuan; tanggal terkunci selama menunggu', async () => {
  const debit = await val(`select id from mst_payment_methods where code = 'debit' and company_id = $1`, [company1]);
  await loginAs(U1);
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM01') }] })]);
    await db.query(`select pos_pay_order($1, $2::jsonb)`, [o.id, JSON.stringify([{ payment_method_id: debit, amount: o.grand_total }])]);
  });
  await loginAs(U7);
  const day = await one(`select business_date::text d, net_amount::float8 net from rpt_pos_settlement_days where outlet_id = $1 and payment_method_id = $2 and settlement_id is null`, [outletId, debit]);
  const r = await val(`select pos_create_settlement($1, $2, array[$3]::date[], $4)`, [outletId, debit, day.d, day.net - 100]);
  assert(r.pending_approval === true, JSON.stringify(r));
  await expectError(`select pos_create_settlement($1, $2, array[$3]::date[], $4)`, [outletId, debit, day.d, day.net], /menunggu persetujuan/);
  await loginAs(U8);
  const res = await approveLatest('pos_settlement');
  assert(Number(res.result.difference_amount) === 100, JSON.stringify(res.result));
  await loginAs(U1);
  await db.query(`update sys_approval_rules set is_enabled = false where company_id = $1`, [company1]);
  await journalBalanced();
});

console.log('\nUser staf dibuat owner (username):');
await check('validasi username, role owner ditolak, user staf tersimpan & tampil dengan username', async () => {
  await loginAs(U1);
  const cashier = await val(`select id from sys_roles where code = 'cashier' and company_id = $1`, [company1]);
  const owner = await val(`select id from sys_roles where code = 'owner' and company_id = $1`, [company1]);
  await expectError(`select sys_prepare_staff_user('Andi Kasir', 'Andi', $1, array[$2]::uuid[])`, [cashier, outletId], /Username/);
  await expectError(`select sys_prepare_staff_user('andi.pluit', 'Andi', $1, array[$2]::uuid[])`, [owner, outletId], /Owner/);
  const prep = await val(`select sys_prepare_staff_user(' Andi.Pluit ', 'Andi', $1, array[$2]::uuid[])`, [cashier, outletId]);
  assert(prep.username === 'andi.pluit' && prep.email === 'andi.pluit@staff.santap.local', JSON.stringify(prep));
  // simulasi Edge Function: akun login dibuat lalu didaftarkan dengan service role
  const U9 = '99999999-9999-9999-9999-999999999999';
  await db.exec(`reset role; insert into auth.users values ('${U9}', 'andi.pluit@staff.santap.local')`);
  await db.exec(`set role authenticated`);
  await expectError(`select sys_register_staff_user($1, $2, 'andi.pluit', 'Andi', $3, array[$4]::uuid[], $5)`, [U9, company1, cashier, outletId, U1], /permission denied/);
  await db.exec(`reset role`);
  await db.query(`select sys_register_staff_user($1, $2, 'andi.pluit', 'Andi', $3, array[$4]::uuid[], $5)`, [U9, company1, cashier, outletId, U1]);
  await loginAs(U1);
  await expectError(`select sys_prepare_staff_user('andi.pluit', 'Andi 2', $1, array[$2]::uuid[])`, [cashier, outletId], /sudah dipakai/);
  const u = (await val(`select sys_list_users()`)).find((x) => x.id === U9);
  assert(u && u.username === 'andi.pluit' && u.email === null && u.role_code === 'cashier', JSON.stringify(u));
  assert((await val(`select sys_check_staff_reset($1)`, [U9])).username === 'andi.pluit', 'reset staf');
  await expectError(`select sys_check_staff_reset($1)`, [U1], /login dengan email/);
  await loginAs(U9);
  const me = await val(`select sys_get_my_profile()`);
  assert(me && me.role_code === 'cashier', JSON.stringify(me));
  await expectError(`select sys_prepare_staff_user('budi.pluit', 'Budi', $1, array[$2]::uuid[])`, [cashier, outletId], /izin/);
});

console.log('\nData contoh, backup, reset & restore:');
const snapshot = async () => one(`select
  (select count(*)::int from pos_orders where company_id = $1) orders,
  (select count(*)::int from fin_journals where company_id = $1) journals,
  (select count(*)::int from inv_items where company_id = $1) items,
  (select count(*)::int from mst_menu_items where company_id = $1) menus,
  (select count(*)::int from inv_stock_batches where company_id = $1) batches,
  (select coalesce(sum(quantity), 0)::float8 from inv_stocks where company_id = $1) stock_qty,
  (select coalesce(sum(debit), 0)::float8 from fin_journal_lines where company_id = $1) debit,
  (select count(*)::int from sal_invoices where company_id = $1) invoices,
  (select count(*)::int from pos_orders where company_id <> $1) other_orders`, [company1]);
let backup;
let beforeReset;
await check('data contoh: pembelian, penjualan harian, waste, SO B2B & settlement; jurnal seimbang', async () => {
  await loginAs(U1);
  const before = await snapshot();
  const r = await val(`select sys_seed_demo_transactions($1, 5, 6)`, [outletId]);
  const after = await snapshot();
  assert(r.orders > 10 && after.orders - before.orders === r.orders && r.sales_order === true, JSON.stringify(r));
  assert((await val(`select count(*)::int from pos_orders where company_id = $1 and business_date = current_date - 4`, [company1])) > 0, 'tanggal mundur');
  assert((await val(`select count(*)::int from pur_goods_receipts where company_id = $1 and note is null and supplier_invoice_number like 'INV-DEMO-%'`, [company1])) >= 2, 'pembelian contoh');
  await journalBalanced();
  await batchInvariant();
  await expectError(`select sys_seed_demo_transactions($1, 2, 2)`, [outletId], null).catch(() => undefined);
});
await check('backup & reset transaksi: master tetap, transaksi & stok kosong, perusahaan lain aman', async () => {
  await loginAs(U7);
  await expectError(`select sys_export_company_data()`, [], /owner/);
  await loginAs(U1);
  backup = await val(`select sys_export_company_data()`);
  assert(backup.format === 'santap-backup' && backup.tables.pos_orders.length > 0 && !backup.tables.sys_payment_gateway_secrets, 'isi backup');
  beforeReset = await snapshot();
  const name = await val(`select name from sys_companies where id = $1`, [company1]);
  await expectError(`select sys_reset_company_data('transactions', 'salah')`, [], /konfirmasi/);
  await db.query(`select sys_reset_company_data('transactions', $1)`, [name]);
  const s = await snapshot();
  assert(s.orders === 0 && s.journals === 0 && s.batches === 0 && s.stock_qty === 0 && s.invoices === 0, JSON.stringify(s));
  assert(s.items === beforeReset.items && s.menus === beforeReset.menus, 'master ikut terhapus');
  assert(s.other_orders === beforeReset.other_orders, 'data perusahaan lain tersentuh');
  assert((await val(`select count(*)::int from fin_accounts where company_id = $1`, [company1])) > 30, 'COA hilang');
});
await check('restore mengembalikan semua data persis seperti saat backup', async () => {
  const name = await val(`select name from sys_companies where id = $1`, [company1]);
  await expectError(`select sys_import_company_data($1::jsonb, $2)`, [JSON.stringify({ ...backup, company_id: '00000000-0000-0000-0000-000000000000' }), name], /perusahaan lain/);
  const r = await val(`select sys_import_company_data($1::jsonb, $2)`, [JSON.stringify(backup), name]);
  assert(r.restored.pos_orders === beforeReset.orders, JSON.stringify(r.restored.pos_orders));
  const s = await snapshot();
  assert(JSON.stringify({ ...s }) === JSON.stringify({ ...beforeReset }), `${JSON.stringify(s)} vs ${JSON.stringify(beforeReset)}`);
  await journalBalanced();
  await batchInvariant();
  // transaksi baru setelah restore tetap jalan (urutan nomor & identity lanjut)
  await withShift(async () => {
    const o = await val(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM01') }] })]);
    await payCash(o.id);
  });
  await batchInvariant();
});
await check('reset total menghapus master juga; outlet, user, COA & supplier internal tetap; restore lagi berhasil', async () => {
  const name = await val(`select name from sys_companies where id = $1`, [company1]);
  backup = await val(`select sys_export_company_data()`);
  beforeReset = await snapshot();
  await db.query(`select sys_reset_company_data('all', $1)`, [name]);
  const s = await snapshot();
  assert(s.items === 0 && s.menus === 0 && s.orders === 0, JSON.stringify(s));
  const kept = await one(`select (select count(*)::int from sys_outlets where company_id = $1) outlets, (select count(*)::int from sys_users where company_id = $1) users,
    (select count(*)::int from pur_suppliers where company_id = $1 and supplier_type = 'internal') internal,
    (select count(*)::int from pur_suppliers where company_id = $1 and supplier_type = 'external') external`, [company1]);
  assert(kept.outlets >= 3 && kept.users >= 3 && kept.internal >= 3 && kept.external === 0, JSON.stringify(kept));
  await db.query(`select sys_import_company_data($1::jsonb, $2)`, [JSON.stringify(backup), name]);
  const s2 = await snapshot();
  assert(JSON.stringify(s2) === JSON.stringify(beforeReset), `${JSON.stringify(s2)} vs ${JSON.stringify(beforeReset)}`);
  await journalBalanced();
});

console.log('\nSkrip data contoh BOM & produksi:');
await check('demo_production.sql: BOM assembly & disassembly siap diproduksi; aman dijalankan ulang', async () => {
  await loginAs(U1);
  const outletName = await val(`select name from sys_outlets where id = $1`, [outletId]);
  const sql = readFileSync(new URL('../../supabase/demo_production.sql', import.meta.url), 'utf8')
    .replaceAll('EMAIL_OWNER_ANDA', 'owner1@test.com').replaceAll('KATA_NAMA_OUTLET', outletName);
  await db.exec(`reset role`);   // SQL Editor Supabase berjalan sebagai postgres
  await db.exec(sql);
  await db.exec(sql);   // jalankan ulang: tidak dobel
  await loginAs(U1);
  const r = await one(`select (select count(*)::int from inv_recipes where company_id = $1 and code in ('BOM-SAMBAL', 'BOM-AYAM')) recipes,
    (select count(*)::int from pur_goods_receipts where company_id = $1 and supplier_invoice_number = 'INV-DEMO-BOM') grs`, [company1]);
  assert(r.recipes === 2 && r.grs === 1, JSON.stringify(r));
  const wh = await mainWh();
  for (const [code, qty] of [['BOM-SAMBAL', 2000], ['BOM-AYAM', 3]]) {
    const p = (await one(`insert into inv_productions (company_id, warehouse_id, recipe_id, quantity) values ($1, $2, (select id from inv_recipes where code = $3 and company_id = $1), $4) returning id`,
      [company1, wh, code, qty])).id;
    await db.query(`select inv_post_production($1)`, [p]);
  }
  const sambal = await one(`select quantity::float8 q, average_cost::float8 c from inv_stocks where warehouse_id = $1 and item_id = (select id from inv_items where code = 'DMP11' and company_id = $2)`, [wh, company1]);
  assert(sambal.q === 2000 && sambal.c > 0, JSON.stringify(sambal));
  const dada = Number(await val(`select quantity from inv_stocks where warehouse_id = $1 and item_id = (select id from inv_items where code = 'DMP12' and company_id = $2)`, [wh, company1]));
  assert(dada === 1350, `dada ${dada}`);
  await journalBalanced();
});

console.log('\nSimple manufacturing (ala ESB):');
await check('assembly: asal CK -> tujuan gudang lain, satuan kg, qty bahan & hasil AKTUAL, kedaluwarsa hasil', async () => {
  await loginAs(U1);
  const wh = await mainWh();
  const wh2 = await val(`select id from inv_warehouses where code = 'WH-B2' and company_id = $1`, [company1]);
  const sambal = await itemId('DMP11');
  const kg = await val(`select id from inv_units where code = 'kg' and company_id = $1`, [company1]);
  await db.query(`insert into inv_item_units (company_id, item_id, unit_id, conversion_qty) values ($1, $2, $3, 1000) on conflict do nothing`, [company1, sambal, kg]);
  const recipe = await val(`select id from inv_recipes where code = 'BOM-SAMBAL' and company_id = $1`, [company1]);
  const group = '0a0a0a0a-0000-0000-0000-000000000001';
  const p = (await one(`insert into inv_productions (company_id, warehouse_id, dest_warehouse_id, recipe_id, quantity, unit_id, result_qty, expiry_date, group_id, line_no)
    values ($1, $2, $3, $4, 2, $5, 1.9, current_date + 5, $6, 1) returning id`, [company1, wh, wh2, recipe, kg, group])).id;
  await db.query(`select inv_prepare_production($1)`, [p]);
  const cabai = await one(`select id, bom_qty::float8 bom, system_qty::float8 sys from inv_production_lines where production_id = $1 and item_id = $2`, [p, await itemId('DMP01')]);
  assert(cabai.bom === 630 && cabai.sys === 1260, JSON.stringify(cabai));   // 600 g/kg x 1.05 waste x 2 kg
  await db.query(`update inv_production_lines set actual_qty = 1300 where id = $1`, [cabai.id]);
  const cabaiBefore = await stockOf('DMP01');
  const r = await val(`select inv_post_production($1)`, [p]);
  assert(cabaiBefore - (await stockOf('DMP01')) === 1300, 'cabai aktual');
  const dest = await one(`select quantity::float8 q from inv_stocks where warehouse_id = $1 and item_id = $2`, [wh2, sambal]);
  assert(dest.q === 1900, JSON.stringify(dest));
  const batch = await one(`select expiry_date::text e, unit_cost::float8 c from inv_stock_batches where warehouse_id = $1 and item_id = $2 order by created_at desc limit 1`, [wh2, sambal]);
  assert(batch.e === days(5) && Math.abs(batch.c * 1900 - (Number(r.input_value) + Number(r.extra_cost))) < 1, JSON.stringify({ batch, r }));
  const v = await one(`select variance_qty::float8 v from rpt_production_variances where production_id = $1 and item_code = 'DMP01'`, [p]);
  assert(v.v === 40, JSON.stringify(v));
  // BOM kedua di dokumen yang sama -> nomor dasar sama, akhiran - 2
  const p2 = (await one(`insert into inv_productions (company_id, warehouse_id, recipe_id, quantity, group_id, line_no)
    values ($1, $2, $3, 1000, $4, 2) returning id`, [company1, wh, recipe, group])).id;
  const r2 = await val(`select inv_post_production($1)`, [p2]);
  assert(r2.production_number === r.production_number.replace(/ - 1$/, ' - 2'), `${r.production_number} / ${r2.production_number}`);
  await journalBalanced();
  await batchInvariant();
});
await check('disassembly: qty hasil & weight factor aktual; nilai hasil = nilai bahan', async () => {
  const wh = await mainWh();
  const recipe = await val(`select id from inv_recipes where code = 'BOM-AYAM' and company_id = $1`, [company1]);
  const p = (await one(`insert into inv_productions (company_id, warehouse_id, recipe_id, quantity) values ($1, $2, $3, 2) returning id`, [company1, wh, recipe])).id;
  await db.query(`select inv_prepare_production($1)`, [p]);
  await db.query(`update inv_production_lines set actual_qty = 820, weight_factor = 2.5 where production_id = $1 and item_id = $2`, [p, await itemId('DMP12')]);
  await db.query(`update inv_production_lines set actual_qty = 0 where production_id = $1 and item_id = $2`, [p, await itemId('DMP14')]);
  const r = await val(`select inv_post_production($1)`, [p]);
  const out = await db.query(`select item_id, quantity::float8 q, round(quantity * unit_cost, 2)::float8 v from inv_stock_movements where reference_id = $1 and quantity > 0`, [p]);
  assert(out.rows.length === 2, 'tulang qty 0 tidak masuk stok');
  const dada = out.rows.find((x) => x.item_id === null) ?? out.rows.find((x) => x.q === 820);
  const total = out.rows.reduce((t, x) => t + x.v, 0);
  assert(dada && Math.abs(total - Number(r.input_value)) < 1 && Math.abs(dada.v - Number(r.input_value) * 2.5 / 4) < 1, JSON.stringify({ rows: out.rows, r }));
  await journalBalanced();
});
await check('produksi bisa wajib approval: manajer -> menunggu; penyetuju (tanpa akses persediaan) menyetujui', async () => {
  await loginAs(U1);
  await db.query(`update sys_approval_rules set is_enabled = true, min_amount = 0 where company_id = $1 and document_type = 'production'`, [company1]);
  await db.query(`update sys_roles set permissions = permissions || '["approval.production"]'::jsonb where code = 'approver' and company_id = $1`, [company1]);
  await loginAs(U7);
  const recipe = await val(`select id from inv_recipes where code = 'BOM-SAMBAL' and company_id = $1`, [company1]);
  const p = (await one(`insert into inv_productions (company_id, warehouse_id, recipe_id, quantity) values ($1, $2, $3, 500) returning id`, [company1, await mainWh(), recipe])).id;
  const r = await val(`select inv_post_production($1)`, [p]);
  assert(r.pending_approval === true && (await val(`select status from inv_productions where id = $1`, [p])) === 'pending_approval', JSON.stringify(r));
  await expectError(`select inv_post_production($1)`, [p], /menunggu persetujuan/);
  await loginAs(U8);
  await approveLatest('production');
  assert((await val(`select status from inv_productions where id = $1`, [p])) === 'posted', 'belum diposting');
  await loginAs(U1);
  await db.query(`update sys_approval_rules set is_enabled = false where company_id = $1 and document_type = 'production'`, [company1]);
  await journalBalanced();
});

console.log('\nAkses branch & role template:');
const U10 = '10101010-1010-1010-1010-101010101010';
await check('role template dibuat sekali (tidak dobel); HO default semua branch', async () => {
  await loginAs(U1);
  const n = await val(`select sys_create_role_templates()`);
  assert(n === 11, `template ${n}`);
  assert((await val(`select sys_create_role_templates()`)) === 0, 'dobel');
  assert((await val(`select default_outlet_scope from sys_roles where code = 'finance' and company_id = $1`, [company1])) === 'all', 'scope finance');
});
await check('user terkunci di 1 branch hanya melihat & mengubah data branch itu', async () => {
  const role = await val(`select id from sys_roles where code = 'store_manager' and company_id = $1`, [company1]);
  await db.exec(`reset role; insert into auth.users values ('${U10}', 'sm.sc@staff.santap.local')`);
  await db.query(`select sys_register_staff_user($1, $2, 'sm.sc', 'Store Manager SC', $3, array[$4]::uuid[], $5)`, [U10, company1, role, sc, U1]);
  await loginAs(U10);
  const me = await val(`select sys_get_my_profile()`);
  assert(me.outlets.length === 1 && me.outlets[0].id === sc && me.outlet_scope === 'selected', JSON.stringify(me.outlets));
  const seen = await one(`select
    (select count(*)::int from pos_orders where outlet_id = $1) main_orders,
    (select count(*)::int from inv_stocks s join inv_warehouses w on w.id = s.warehouse_id where w.outlet_id = $1) main_stocks,
    (select count(*)::int from inv_stocks s join inv_warehouses w on w.id = s.warehouse_id where w.outlet_id = $2) sc_stocks,
    (select count(*)::int from sal_sales_orders where outlet_id = $2 or buyer_outlet_id = $2) sc_so,
    (select count(*)::int from rpt_stock_balances where warehouse_id = $3) main_report`, [outletId, sc, await mainWh()]);
  assert(seen.main_orders === 0 && seen.main_stocks === 0 && seen.main_report === 0 && seen.sc_stocks > 0 && seen.sc_so > 0, JSON.stringify(seen));
  // tidak bisa membuat dokumen stok untuk gudang branch lain
  await expectError(`insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type) values ($1, $2, 'adjustment')`, [company1, await mainWh()], /row-level security/);
  await db.query(`insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type) values ($1, $2, 'adjustment')`, [company1, ck]);
  // POS juga terkunci
  await expectError(`select pos_save_order($1::jsonb)`, [JSON.stringify({ outlet_id: outletId, sales_channel: 'takeaway', items: [{ menu_item_id: await menuId('MNM01') }] })], /akses ke outlet/);
});
await check('akses semua branch: lihat semua outlet termasuk branch baru', async () => {
  await loginAs(U1);
  const role = await val(`select id from sys_roles where code = 'store_manager' and company_id = $1`, [company1]);
  await expectError(`select sys_set_user_access($1, $2, 'selected', array[]::uuid[])`, [U10, role], /minimal 1 branch/);
  await db.query(`select sys_set_user_access($1, $2, 'all', array[]::uuid[])`, [U10, role]);
  const n = await val(`select sys_create_outlet('OUT09', 'Cabang Baru')`);
  await loginAs(U10);
  const me = await val(`select sys_get_my_profile()`);
  assert(me.outlet_scope === 'all' && me.outlets.some((o) => o.id === n.id) && me.outlets.some((o) => o.id === outletId), JSON.stringify(me.outlets.length));
  assert((await val(`select count(*)::int from pos_orders where outlet_id = $1`, [outletId])) > 0, 'order outlet utama tidak terlihat');
  await loginAs(U1);
  assert((await val(`select sys_list_users()`)).find((u) => u.id === U10).outlet_scope === 'all', 'daftar user');
});

console.log('\nNama aplikasi:');
await check('nama aplikasi bisa diatur & muncul di profil (kosong = default)', async () => {
  await loginAs(U1);
  assert((await val(`select sys_get_my_profile()`)).company_app_name === null, 'default harus null');
  await db.query(`update sys_companies set app_name = 'Achphoria POS' where id = $1`, [company1]);
  assert((await val(`select sys_get_my_profile()`)).company_app_name === 'Achphoria POS', 'tidak tersimpan');
  await expectError(`update sys_companies set app_name = '   ' where id = $1`, [company1], /check/);
});

console.log('\nPlatform admin, grup usaha & brand:');
const U4b = '44444444-4444-4444-4444-444444444444';
let company2, company4;
await check('owner/staf biasa tidak bisa console platform, pindah PT, atau jadi platform admin', async () => {
  await db.exec('reset role');
  company2 = await val(`select company_id from sys_users where id = $1`, [U2]);
  company4 = await val(`select company_id from sys_users where id = $1`, [U4b]);
  for (const u of [U1, U7]) {
    await loginAs(u);
    await expectError(`select sys_platform_companies()`, [], /Platform Admin/);
    await expectError(`select sys_switch_company($1)`, [company2], /tidak punya akses/);
  }
  await expectError(`insert into sys_platform_admins (user_id) values ($1)`, [U7], /row-level security/);
  await loginAs(U1);
  await expectError(`insert into sys_platform_admins (user_id) values ($1)`, [U1], /row-level security/);
  assert((await val(`select sys_get_my_profile()`)).is_platform_admin === false, 'bukan platform admin');
});
await check('platform admin (diberi lewat SQL) masuk PT lain mode support, akses penuh & tercatat', async () => {
  await db.exec('reset role');
  await db.query(`insert into sys_platform_admins (user_id, note) values ($1, 'developer')`, [U2]);
  await loginAs(U2);
  const list = await val(`select sys_platform_companies()`);
  assert(list.length >= 3 && list.some((c) => c.id === company1 && c.owners.includes('owner1@test.com') && c.outlets > 1), JSON.stringify(list[0]));
  const me0 = await val(`select sys_get_my_profile()`);
  assert(me0.is_platform_admin && me0.company_id === company2 && me0.acting_mode === null, JSON.stringify(me0.acting_mode));
  assert((await val(`select sys_switch_company($1)`, [company1])).mode === 'support', 'mode');
  const me = await val(`select sys_get_my_profile()`);
  assert(me.company_id === company1 && me.role_name === 'Platform support' && me.permissions[0] === '*'
    && me.outlets.length > 1 && me.home_company_id === company2, JSON.stringify({ c: me.company_name, r: me.role_name }));
  assert((await val(`select count(*)::int from pos_orders`)) > 0, 'order PT tujuan tidak terlihat');
  await db.query(`update sys_companies set phone = '0800111' where id = $1`, [company1]);
  const log = await one(`select user_name from sys_activity_logs where company_id = $1 and entity_type = 'sys_companies' and action = 'update' order by id desc limit 1`, [company1]);
  assert(log.user_name.endsWith('(Platform support)'), log.user_name);
  assert((await val(`select count(*)::int from sys_activity_logs where company_id = $1 and action = 'support_enter'`, [company1])) === 1, 'masuk tidak tercatat');
  await db.query(`select sys_switch_company(null)`);
  const back = await val(`select sys_get_my_profile()`);
  assert(back.company_id === company2 && back.acting_mode === null, 'tidak kembali');
  assert((await val(`select count(*)::int from pos_orders`)) === 0, 'masih melihat data PT lain');
});
await check('grup usaha: pemilik grup pindah antar PT di grupnya saja', async () => {
  await loginAs(U2);
  const g = await val(`select sys_platform_save_group(null, 'grp1', 'Achphoria Group')`);
  await db.query(`select sys_platform_set_company_group($1, $2)`, [company1, g]);
  await db.query(`select sys_platform_set_company_group($1, $2)`, [company2, g]);
  await db.query(`select sys_platform_add_group_member($1, 'OWNER1@test.com')`, [g]);
  await expectError(`select sys_platform_add_group_member($1, 'tidakada@test.com')`, [g], /belum terdaftar/);
  const grp = (await val(`select sys_platform_groups()`)).find((x) => x.id === g);
  assert(grp.code === 'GRP1' && grp.companies.length === 2 && grp.members.length === 1, JSON.stringify(grp));
  await loginAs(U1);
  const me = await val(`select sys_get_my_profile()`);
  assert(me.companies.length === 2 && me.group_name === 'Achphoria Group', JSON.stringify(me.companies));
  assert((await val(`select sys_switch_company($1)`, [company2])).mode === 'group', 'mode grup');
  const me2 = await val(`select sys_get_my_profile()`);
  assert(me2.company_id === company2 && me2.role_name === 'Pemilik grup', me2.role_name);
  assert((await val(`select name from sys_companies`)) === 'Kedai Lain', 'bukan PT tujuan');
  await db.query(`insert into sys_brands (company_id, code, name) values ($1, 'GRPX', 'Brand Dari Grup')`, [company2]);
  assert((await val(`select user_name from sys_activity_logs where company_id = $1 and entity_type = 'sys_brands' order by id desc limit 1`, [company2])).endsWith('(Pemilik grup)'), 'log grup');
  await expectError(`select sys_switch_company($1)`, [company4], /tidak punya akses/);
  // dikeluarkan dari grup = otomatis kembali ke PT sendiri
  await loginAs(U2);
  await db.query(`select sys_platform_remove_group_member($1, $2)`, [g, U1]);
  await loginAs(U1);
  assert((await val(`select sys_get_my_profile()`)).company_id === company1, 'masih di PT grup');
  await expectError(`select sys_switch_company($1)`, [company2], /tidak punya akses/);
});
await check('PT dinonaktifkan platform: user-nya tidak bisa masuk', async () => {
  await loginAs(U2);
  await db.query(`select sys_platform_set_company_active($1, false)`, [company4]);
  await loginAs(U4b);
  assert((await val(`select sys_get_my_profile()`)) === null, 'masih bisa masuk');
  assert((await val(`select count(*)::int from fin_accounts`)) === 0, 'masih bisa lihat data');
  await loginAs(U2);
  await db.query(`select sys_platform_set_company_active($1, true)`, [company4]);
  await loginAs(U4b);
  assert((await val(`select sys_get_my_profile()`)) !== null, 'tidak aktif lagi');
});
await check('akses per brand: user melihat outlet brand-nya, termasuk outlet baru brand itu', async () => {
  await loginAs(U1);
  const b2 = await val(`insert into sys_brands (company_id, code, name) values ($1, 'BR02', 'Brand Kedua') returning id`, [company1]);
  const o1 = await val(`select sys_create_outlet('BRD01', 'Outlet Brand Kedua', null, $1)`, [b2]);
  assert(o1.brand_id === b2, 'brand outlet');
  const role = await val(`select id from sys_roles where code = 'store_manager' and company_id = $1`, [company1]);
  await expectError(`select sys_set_user_access($1, $2, 'brands', array[]::uuid[], true, array[]::uuid[])`, [U10, role], /minimal 1 brand/);
  await db.query(`select sys_set_user_access($1, $2, 'brands', array[]::uuid[], true, array[$3]::uuid[])`, [U10, role, b2]);
  const o2 = await val(`select sys_create_outlet('BRD02', 'Outlet Brand Kedua Baru', null, $1)`, [b2]);
  assert((await val(`select sys_list_users()`)).find((u) => u.id === U10).brand_ids[0] === b2, 'daftar user');
  await loginAs(U10);
  const me = await val(`select sys_get_my_profile()`);
  assert(me.outlet_scope === 'brands' && me.outlets.length === 2 && me.outlets.some((o) => o.id === o2.id), JSON.stringify(me.outlets));
  assert(await val(`select sys_can_access_outlet($1)`, [o2.id]), 'outlet baru brand tidak bisa diakses');
  assert(!(await val(`select sys_can_access_outlet($1)`, [outletId])), 'outlet brand lain bisa diakses');
  assert((await val(`select count(*)::int from pos_orders where outlet_id = $1`, [outletId])) === 0, 'order brand lain terlihat');
});

console.log('\nPendaftar baru (console platform):');
await check('pendaftar: daftar akun, status setup, badge & tandai sudah dilihat', async () => {
  const U11 = '11111111-0000-0000-0000-000000000011';
  await loginAs(U1);
  await expectError(`select sys_platform_signups()`, [], /Platform Admin/);
  assert((await val(`select sys_platform_new_signups()`)) === 0, 'non-admin harus 0');
  await db.exec(`reset role; insert into auth.users (id, email) values ('${U11}', 'calon@warung.com')`);
  await loginAs(U2);
  const list = await val(`select sys_platform_signups()`);
  const by = (e) => list.find((x) => x.email === e);
  assert(by('calon@warung.com')?.status === 'pending' && by('calon@warung.com').is_new, 'pendaftar belum setup');
  assert(by('owner1@test.com')?.status === 'owner' && by('owner1@test.com').company_name, 'owner');
  assert(by('pelayan@test.com')?.status === 'staff', 'staf undangan email');
  assert(!list.some((x) => x.email.endsWith('@staff.santap.local')), 'staf username ikut tampil');
  assert((await val(`select sys_platform_new_signups()`)) >= 1, 'badge kosong');
  await db.query(`select sys_platform_mark_signups_seen()`);
  assert((await val(`select sys_platform_new_signups()`)) === 0, 'badge tidak hilang');
  await db.exec(`reset role; insert into auth.users (id, email, created_at) values (gen_random_uuid(), 'baru2@warung.com', now() + interval '1 second')`);
  await loginAs(U2);
  assert((await val(`select sys_platform_new_signups()`)) === 1, 'pendaftar berikutnya tidak terhitung');
  assert((await val(`select sys_platform_companies()`)).every((c) => typeof c.is_new === 'boolean'), 'tanda PT baru');
});

console.log('\nDaftar usaha baru (setelah semua migrasi):');
await check('pendaftar baru bisa membuat usaha + data contoh (log aktivitas tidak menolak)', async () => {
  const U12 = '12121212-1212-1212-1212-121212121212';
  await db.exec(`reset role; insert into auth.users (id, email) values ('${U12}', 'ops.kopitiam@test.com')`);
  await loginAs(U12);
  const r = await val(`select sys_onboard_company('Bites and Sips Kopitiam', 'BTS Cengkareng', 'Ali', true)`);
  assert(r.outlet_id, 'outlet tidak dibuat');
  const me = await val(`select sys_get_my_profile()`);
  assert(me && me.company_name === 'Bites and Sips Kopitiam' && me.outlets.length === 1, JSON.stringify(me));
  const logs = await db.query(`select user_id, user_name from sys_activity_logs where company_id = $1 order by id`, [me.company_id]);
  assert(logs.rows.length > 0, 'tidak ada log');
  assert(logs.rows[0].user_id === null && logs.rows[0].user_name === 'ops.kopitiam@test.com', JSON.stringify(logs.rows[0]));
  assert(logs.rows.some((l) => l.user_id === U12 && l.user_name === 'Ali'), 'log setelah terdaftar tidak memakai user');
});

await check('PT baru tidak melihat satu baris pun data PT lain (semua tabel, tabel anak & laporan)', async () => {
  const U12 = '12121212-1212-1212-1212-121212121212';
  await db.exec('reset role');
  const mine = await val(`select company_id from sys_users where id = $1`, [U12]);
  // daftar tabel ber-company_id, view ber-company_id, dan tabel anak (FK ke tabel ber-company_id)
  const withCompany = (await db.query(`select c.table_name, t.table_type from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and c.column_name = 'company_id' order by 1`)).rows;
  const children = (await db.query(`select distinct cl.relname as child, a.attname as col, pl.relname as parent
    from pg_constraint k join pg_class cl on cl.oid = k.conrelid join pg_class pl on pl.oid = k.confrelid
    join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
    join pg_namespace n on n.oid = cl.relnamespace
    where k.contype = 'f' and n.nspname = 'public' and array_length(k.conkey, 1) = 1
      and not exists (select 1 from information_schema.columns x where x.table_schema = 'public' and x.table_name = cl.relname and x.column_name = 'company_id')
      and exists (select 1 from information_schema.columns x where x.table_schema = 'public' and x.table_name = pl.relname and x.column_name = 'company_id')`)).rows;
  // pastikan PT lain memang punya data (supaya tes ini bermakna)
  const others = await val(`select count(*)::int from inv_items where company_id <> $1`, [mine]);
  assert(others > 0, 'tidak ada data PT lain untuk diuji');

  await loginAs(U12);
  const leaks = [];
  for (const { table_name, table_type } of withCompany) {
    const n = await val(`select count(*)::int from "${table_name}" where company_id is distinct from $1`, [mine]);
    if (n > 0) leaks.push(`${table_type === 'VIEW' ? 'view' : 'tabel'} ${table_name}: ${n}`);
  }
  for (const { child, col, parent } of children) {
    const n = await val(`select count(*)::int from "${child}" c left join "${parent}" p on p.id = c."${col}"
      where c."${col}" is not null and (p.id is null or p.company_id <> $1)`, [mine]);
    if (n > 0) leaks.push(`anak ${child}.${col} -> ${parent}: ${n}`);
  }
  assert(!leaks.length, 'BOCOR: ' + leaks.join(' | '));
  // master produk PT baru hanya miliknya sendiri (data contoh = salinan, bukan data PT lain)
  const items = await val(`select count(*)::int from inv_items`);
  assert(items > 0 && items === await val(`select count(*)::int from inv_items where company_id = $1`, [mine]), 'master produk tercampur');
  console.log(`      (${withCompany.length} tabel/view ber-company_id & ${children.length} relasi tabel anak diperiksa)`);
});

console.log('\nAgent Semar (database):');
await check('obrolan Semar khusus owner & pribadi; struktur tabel menyembunyikan tabel rahasia', async () => {
  const conv = '99999999-0000-0000-0000-000000000001';
  await loginAs(U1);
  await db.query(`insert into ai_chat_messages (company_id, user_id, conversation_id, role, content) values ($1, $2, $3, 'user', '[{"type":"text","text":"halo"}]')`, [company1, U1, conv]);
  assert((await val(`select count(*)::int from ai_chat_messages`)) === 1, 'owner tidak melihat obrolannya');
  const info = await val(`select ai_table_info()`);
  const names = info.map((t) => t.table);
  assert(names.includes('pur_suppliers') && names.includes('rpt_daily_sales'), 'tabel/laporan utama tidak ada');
  assert(!names.some((n) => ['sys_payment_gateway_secrets', 'sys_platform_admins', 'ai_chat_messages'].includes(n)), 'tabel rahasia terlihat');
  assert(info.find((t) => t.table === 'pur_suppliers').writable && !info.find((t) => t.table === 'pos_orders').writable, 'flag writable');
  const sup = (await val(`select ai_table_info(array['pur_suppliers'])`))[0];
  assert(sup.columns.some((c) => c.name === 'name' && c.required) && sup.has_company_id, JSON.stringify(sup.columns?.slice(0, 3)));
  assert((await val(`select ai_recent_usage()`)).messages_last_hour === 1, 'pemakaian');
  // staf (bukan owner): tidak bisa membaca struktur & tidak bisa menulis/membaca obrolan
  await loginAs(U7);
  await expectError(`select ai_table_info()`, [], /Khusus owner/);
  await expectError(`insert into ai_chat_messages (company_id, user_id, conversation_id, role, content) values ($1, $2, $3, 'user', '[]')`, [company1, U7, conv], /row-level security/);
  assert((await val(`select count(*)::int from ai_chat_messages`)) === 0, 'staf melihat obrolan owner');
  // owner PT lain tidak melihat obrolan owner ini
  await loginAs('12121212-1212-1212-1212-121212121212');
  assert((await val(`select count(*)::int from ai_chat_messages`)) === 0, 'owner lain melihat obrolan');
});

console.log('\nLogo brand & landing page:');
await check('landing page hanya menampilkan brand berlogo yang mengizinkan (bisa tanpa login)', async () => {
  await loginAs(U1);
  const brand = await val(`select id from sys_brands where company_id = $1 order by created_at limit 1`, [company1]);
  await db.query(`update sys_brands set logo_url = 'https://x.test/logo-a.webp' where id = $1`, [brand]);
  await db.query(`insert into sys_brands (company_id, code, name, logo_url, show_on_landing) values ($1, 'PRIV', 'Brand Rahasia', 'https://x.test/b.webp', false)`, [company1]);
  await db.query(`insert into sys_brands (company_id, code, name) values ($1, 'NOLOGO', 'Tanpa Logo')`, [company1]);
  // tanpa login
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;`);
  const list = await val(`select sys_public_brands()`);
  const names = list.map((b) => b.name);
  assert(list.some((b) => b.logo_url === 'https://x.test/logo-a.webp'), JSON.stringify(list));
  assert(!names.includes('Brand Rahasia') && !names.includes('Tanpa Logo'), 'brand yang tidak mengizinkan / tanpa logo tampil');
  assert(list.every((b) => Object.keys(b).sort().join() === 'logo_url,name'), 'data lain ikut terbuka');
  // perusahaan nonaktif tidak tampil
  await db.exec('reset role');
  await db.query(`update sys_companies set is_active = false where id = $1`, [company1]);
  assert(!(await val(`select sys_public_brands()`)).some((b) => b.logo_url === 'https://x.test/logo-a.webp'), 'PT nonaktif tampil');
  await db.query(`update sys_companies set is_active = true where id = $1`, [company1]);
});

console.log('\nSemar: forecasting & membuat PO:');
await check('forecast kebutuhan beli: stok, pemakaian per hari, saran beli & opsi supplier', async () => {
  await loginAs(U1);
  const f = await val(`select ai_purchase_forecast(null, 30, 7)`);
  assert(f.items.length > 0 && f.gudang.length > 0, JSON.stringify(f).slice(0, 200));
  const used = f.items.find((i) => Number(i.pemakaian_per_hari) > 0);
  assert(used && used.cukup_untuk_hari !== undefined && used.saran_beli >= 0 && used.satuan_beli && used.unit_id_beli, JSON.stringify(used));
  assert(f.items.every((i) => Array.isArray(i.opsi_supplier)), 'opsi supplier');
  await loginAs(U6);
  await expectError(`select ai_purchase_forecast()`, [], /izin/);
});
await check('PO dari Semar: pratinjau tidak menyimpan, draft & diajukan tersimpan dengan harga otomatis', async () => {
  await loginAs(U1);
  const sup = await val(`select id from pur_suppliers where code = 'SUP01' and company_id = $1`, [company1]);
  const wh = await mainWh();
  const item = await itemId('BHN05');
  const before = await val(`select count(*)::int from pur_purchase_orders`);
  const payload = { supplier_id: sup, warehouse_id: wh, items: [{ item_id: item, qty: 2 }] };
  const prev = await val(`select ai_create_purchase_order($1::jsonb, true)`, [JSON.stringify(payload)]);
  assert(prev.items.length === 1 && Number(prev.items[0].harga) > 0 && prev.items[0].sumber_harga && Number(prev.total) > 0, JSON.stringify(prev));
  assert((await val(`select count(*)::int from pur_purchase_orders`)) === before, 'pratinjau menyimpan PO');
  const draft = await val(`select ai_create_purchase_order($1::jsonb, false)`, [JSON.stringify(payload)]);
  assert(draft.status === 'draft', JSON.stringify(draft));
  const po = await one(`select status, note, (select count(*)::int from pur_purchase_order_items where purchase_order_id = p.id) n from pur_purchase_orders p where id = $1`, [draft.id]);
  assert(po.status === 'draft' && po.n === 1 && /Semar/.test(po.note), JSON.stringify(po));
  const sent = await val(`select ai_create_purchase_order($1::jsonb, false)`, [JSON.stringify({ ...payload, submit: true })]);
  assert(['disetujui', 'menunggu persetujuan'].includes(sent.status) && (sent.po_number ?? '').startsWith('PO/'), JSON.stringify(sent));
  // supplier perusahaan lain & qty 0 ditolak
  await db.exec('reset role');
  const other = (await one(`select id from pur_suppliers where company_id <> $1 limit 1`, [company1]))?.id;
  await loginAs(U1);
  if (other) await expectError(`select ai_create_purchase_order($1::jsonb, true)`, [JSON.stringify({ ...payload, supplier_id: other })], /Supplier tidak ditemukan/);
  await expectError(`select ai_create_purchase_order($1::jsonb, true)`, [JSON.stringify({ ...payload, items: [{ item_id: item, qty: 0 }] })], /lebih dari 0/);
  // kasir/pelayan tidak boleh membuat PO
  await loginAs(U6);
  await expectError(`select ai_create_purchase_order($1::jsonb, true)`, [JSON.stringify(payload)], /izin/);
});

console.log('\nSDM / HR (fase A):');
const KASIR = '99999999-9999-9999-9999-999999999999';   // andi.pluit (kasir)
let empAndi;
await check('HR: struktur, karyawan dengan nomor otomatis, tautkan akun login', async () => {
  await loginAs(U1);
  const dep = await val(`insert into hr_departments (company_id, code, name) values ($1, 'OPS', 'Operasional') returning id`, [company1]);
  const pos = await val(`insert into hr_positions (company_id, department_id, code, name) values ($1, $2, 'KSR', 'Kasir') returning id`, [company1, dep]);
  const e1 = await one(`insert into hr_employees (company_id, full_name, nickname, gender, national_id, phone, department_id, position_id, outlet_id,
      employment_status, join_date, contract_end_date, birth_date)
    values ($1, 'Andi Saputra', 'Andi', 'L', '3171000000000001', '0811', $2, $3, $4, 'contract', current_date - 200, current_date + 10, make_date(1999, extract(month from current_date)::int, 1))
    returning id, employee_number`, [company1, dep, pos, outletId]);
  const e2 = await one(`insert into hr_employees (company_id, full_name) values ($1, 'Siti Aminah') returning employee_number`, [company1]);
  assert(/^EMP-\d{4}$/.test(e1.employee_number) && e2.employee_number !== e1.employee_number, JSON.stringify([e1, e2]));
  empAndi = e1.id;
  await db.query(`select hr_link_user($1, $2)`, [empAndi, KASIR]);
  await expectError(`select hr_link_user((select id from hr_employees where full_name = 'Siti Aminah'), $1)`, [KASIR], /sudah tertaut/);
  const rem = await val(`select hr_reminders()`);
  assert(rem.contracts.some((c) => c.full_name === 'Andi Saputra') && rem.birthdays.some((b) => b.full_name === 'Andi Saputra'), JSON.stringify(rem));
  // log aktivitas tidak menyimpan No. KTP
  assert(!(await val(`select count(*)::int from sys_activity_logs where entity_type = 'hr_employees' and coalesce(changes::text, '') like '%3171000000000001%'`)), 'KTP masuk log');
});
await check('HR: kasir hanya melihat datanya sendiri & hanya bisa ubah kontak; direktori tanpa data sensitif', async () => {
  await loginAs(KASIR);
  assert((await val(`select count(*)::int from hr_employees`)) === 1, 'kasir melihat karyawan lain');
  const me = await val(`select hr_my_employee()`);
  assert(me.full_name === 'Andi Saputra' && me.position === 'Kasir' && me.national_id === '3171000000000001', JSON.stringify(me).slice(0, 200));
  const upd = await val(`select hr_update_my_profile($1::jsonb)`, [JSON.stringify({ phone: '0812999', national_id: 'PALSU', full_name: 'Ganti Nama' })]);
  assert(upd.phone === '0812999' && upd.national_id === '3171000000000001' && upd.full_name === 'Andi Saputra', JSON.stringify(upd).slice(0, 200));
  await db.query(`update hr_employees set national_id = 'X' where id = $1`, [empAndi]);
  assert((await val(`select national_id from hr_employees where id = $1`, [empAndi])) === '3171000000000001', 'kasir bisa ubah KTP langsung');
  await expectError(`insert into hr_employees (company_id, full_name) values ($1, 'Orang Asing')`, [company1], /row-level security/);
  const dir = await val(`select hr_directory()`);
  assert(dir.length >= 2 && dir.every((d) => !('national_id' in d) && !('address_ktp' in d)), JSON.stringify(dir[0]));
  // perusahaan lain tidak melihat karyawan ini
  await loginAs('44444444-4444-4444-4444-444444444444');
  assert((await val(`select count(*)::int from hr_employees`)) === 0 && (await val(`select hr_directory()`)).length === 0, 'bocor ke PT lain');
});
await check('HR: pengumuman sesuai sasaran (semua / outlet / role) & tanda sudah dibaca', async () => {
  await loginAs(U1);
  const cashierRole = await val(`select role_id from sys_users where id = $1`, [KASIR]);
  const otherOutlet = await val(`select id from sys_outlets where company_id = $1 and id <> $2 order by created_at desc limit 1`, [company1, outletId]);
  const all = await val(`insert into hr_announcements (company_id, title, body) values ($1, 'Libur Lebaran', 'Toko tutup 2 hari') returning id`, [company1]);
  await db.query(`insert into hr_announcements (company_id, title, audience, outlet_ids) values ($1, 'Khusus outlet lain', 'outlet', array[$2]::uuid[])`, [company1, otherOutlet]);
  await db.query(`insert into hr_announcements (company_id, title, audience, role_ids) values ($1, 'Info kasir', 'role', array[$2]::uuid[])`, [company1, cashierRole]);
  await db.query(`insert into hr_announcements (company_id, title, audience, outlet_ids) values ($1, 'Info outlet utama', 'outlet', array[$2]::uuid[])`, [company1, outletId]);
  await loginAs(KASIR);
  const list = await val(`select hr_my_announcements()`);
  const titles = list.map((a) => a.title);
  assert(titles.includes('Libur Lebaran') && titles.includes('Info kasir') && titles.includes('Info outlet utama') && !titles.includes('Khusus outlet lain'), JSON.stringify(titles));
  await expectError(`insert into hr_announcements (company_id, title) values ($1, 'kasir bikin')`, [company1], /row-level security/);
  await db.query(`select hr_mark_announcement_read($1)`, [all]);
  assert((await val(`select hr_my_announcements()`)).find((a) => a.id === all).read === true, 'tanda baca');
  await loginAs(U1);
  assert(Number((await val(`select hr_announcement_stats()`))[all]) === 1, 'statistik baca');
});

console.log('\nSDM / HR (fase B - absensi):');
const PLUIT = { lat: -6.117, lng: 106.79 };
let shiftPagi, todayLocal, attAndi;
await check('Absensi: jarak GPS dihitung server (haversine)', async () => {
  const d = await val(`select hr_distance_m(-6.2, 106.8, -6.2, 106.81)`);
  assert(d > 1090 && d < 1120, `jarak ${d}`);
  assert((await val(`select hr_distance_m(null, 106.8, -6.2, 106.81)`)) === null, 'null');
});
await check('Absensi: owner atur titik outlet, template shift & jadwal; kasir tidak bisa', async () => {
  await loginAs(U1);
  await db.query(`update sys_outlets set geo_lat = $2, geo_lng = $3, geo_radius_m = 100 where id = $1`, [outletId, PLUIT.lat, PLUIT.lng]);
  shiftPagi = await val(`insert into hr_shifts (company_id, code, name, start_time, end_time) values ($1, 'PAGI', 'Pagi', '07:00', '15:00') returning id`, [company1]);
  await db.query(`insert into hr_shifts (company_id, code, name, start_time, end_time) values ($1, 'MALAM', 'Malam', '22:00', '06:00')`, [company1]);
  todayLocal = await val(`select to_char((now() at time zone 'Asia/Jakarta')::date, 'YYYY-MM-DD')`);
  const siti = await val(`select id from hr_employees where full_name = 'Siti Aminah'`);
  await db.query(`update hr_employees set outlet_id = $2 where id = $1`, [siti, outletId]);
  const n = await val(`select hr_roster_save($1::jsonb)`, [JSON.stringify([
    { employee_id: empAndi, work_date: todayLocal, shift_id: shiftPagi },
    { employee_id: siti, work_date: todayLocal, is_off: true },
  ])]);
  assert(n === 2, `simpan ${n}`);
  // jadwal Siti 3 hari lalu tanpa absen = alpa
  await db.query(`insert into hr_rosters (company_id, employee_id, work_date, outlet_id, shift_id) values ($1, $2, $3::date - 3, $4, $5)`, [company1, siti, todayLocal, outletId, shiftPagi]);
  const board = await val(`select hr_roster_board($1::date - 1, $1::date + 6, $2)`, [todayLocal, outletId]);
  assert(board.employees.some((e) => e.full_name === 'Andi Saputra') && board.rows.length >= 2 && board.shifts.length === 2, JSON.stringify(board).slice(0, 300));
  // salin minggu ini ke minggu depan
  const copied = await val(`select hr_roster_copy_week($1::date, $1::date + 7, null, false)`, [todayLocal]);
  assert(copied >= 2, `salin ${copied}`);
  // malam: jadwal lewat tengah malam -> selesai besok
  const s = await val(`select hr_schedule_for($1, $2::date)`, [empAndi, todayLocal]);
  assert(s.shift === 'Pagi' && s.geo_radius_m === 100 && new Date(s.scheduled_end) - new Date(s.scheduled_start) === 8 * 3600e3, JSON.stringify(s));
  await loginAs(KASIR);
  await expectError(`select hr_roster_board(current_date, current_date + 6)`, [], /izin/);
  await expectError(`select hr_roster_save('[]'::jsonb)`, [], /izin/);
  await expectError(`insert into hr_shifts (company_id, code, name, start_time, end_time) values ($1, 'X', 'X', '07:00', '08:00')`, [company1], /row-level security/);
  const mine = await val(`select hr_my_roster($1::date, $1::date + 1)`, [todayLocal]);
  assert(mine.length === 2 && mine[0].shift === 'Pagi', JSON.stringify(mine));
});
await check('Absensi: selfie hanya ke folder absensi sendiri; wajib foto + GPS', async () => {
  await loginAs(KASIR);
  const ok = `${company1}/${empAndi}/attendance/${todayLocal}-in.webp`;
  await db.query(`insert into storage.objects (bucket_id, name) values ('hr-files', $1)`, [ok]);
  await expectError(`insert into storage.objects (bucket_id, name) values ('hr-files', $1)`, [`${company1}/${empAndi}/kontrak.pdf`], /row-level security/);
  const siti = await val(`select id from hr_employees where full_name = 'Siti Aminah'`).catch(() => null);
  assert(siti === undefined || siti === null, 'kasir melihat data Siti');
  await expectError(`insert into storage.objects (bucket_id, name) values ('hr-files', $1)`, [`${company1}/00000000-0000-0000-0000-000000000000/attendance/x.webp`], /row-level security/);
  await expectError(`select hr_clock('in', $1, $2, 10, null)`, [PLUIT.lat, PLUIT.lng], /Foto selfie wajib/);
  await expectError(`select hr_clock('in', null, null, null, $1)`, [ok], /GPS wajib/);
  await expectError(`select hr_clock('in', $1, $2, 10, $3)`, [PLUIT.lat, PLUIT.lng, `${company1}/${empAndi}/attendance/palsu.webp`], /belum terunggah/);
  await expectError(`select hr_clock('in', $1, $2, 10, $3)`, [PLUIT.lat, PLUIT.lng, `${company1}/lain/attendance/x.webp`], /tidak valid/);
  await expectError(`select hr_clock('out', $1, $2, 10, $3)`, [PLUIT.lat, PLUIT.lng, ok], /Belum ada absen masuk/);
});
await check('Absensi: masuk di outlet = normal; pulang 2 km dari outlet = ditandai untuk review', async () => {
  await loginAs(KASIR);
  const pin = `${company1}/${empAndi}/attendance/${todayLocal}-in.webp`;
  const a = await val(`select hr_clock('in', $1, $2, 12, $3)`, [PLUIT.lat + 0.0003, PLUIT.lng, pin]);
  assert(a.work_date === todayLocal && a.shift_id === shiftPagi && a.check_in_distance_m < 50 && a.flags.length === 0 && a.review_status === 'none', JSON.stringify(a));
  attAndi = a.id;
  await expectError(`select hr_clock('in', $1, $2, 12, $3)`, [PLUIT.lat, PLUIT.lng, pin], /sudah absen masuk/);
  const today = await val(`select hr_attendance_today()`);
  assert(today.attendance.id === attAndi && today.schedule.shift === 'Pagi' && today.settings.require_photo === true, JSON.stringify(today).slice(0, 300));
  const pout = `${company1}/${empAndi}/attendance/${todayLocal}-out.webp`;
  await db.query(`insert into storage.objects (bucket_id, name) values ('hr-files', $1)`, [pout]);
  const b = await val(`select hr_clock('out', $1, $2, 400, $3)`, [PLUIT.lat + 0.018, PLUIT.lng, pout]);
  assert(b.check_out_distance_m > 1900 && b.flags.includes('outside_radius') && b.flags.includes('low_accuracy') && b.review_status === 'pending', JSON.stringify(b));
  // karyawan tidak bisa mengubah absen langsung
  await db.query(`update hr_attendances set check_in_at = now() - interval '9 hours', flags = '{}' where id = $1`, [attAndi]);
  assert((await val(`select array_length(flags, 1) from hr_attendances where id = $1`, [attAndi])) === 2, 'kasir ubah absen');
  await expectError(`insert into hr_attendances (company_id, employee_id, work_date) values ($1, $2, current_date - 5)`, [company1, empAndi], /row-level security/);
  await expectError(`select hr_review_attendance($1, true)`, [attAndi], /izin/);
});
await check('Absensi: hitung telat dari jadwal, rekap (hadir/telat/libur/alpa), review & isolasi PT', async () => {
  await loginAs(U1);
  // pakai jadwal mundur 30 menit dari jam masuk -> telat 30 menit (toleransi 10)
  await db.query(`update hr_attendances set scheduled_start = check_in_at - interval '30 minutes' where id = $1`, [attAndi]);
  assert((await val(`select late_minutes from hr_attendances where id = $1`, [attAndi])) === 30, 'telat 30');
  await db.query(`insert into hr_settings (company_id, late_tolerance_minutes) values ($1, 45)`, [company1]);
  await db.query(`update hr_attendances set scheduled_start = scheduled_start where id = $1`, [attAndi]);
  assert((await val(`select late_minutes from hr_attendances where id = $1`, [attAndi])) === 0, 'masih dalam toleransi 45');
  await db.query(`update hr_settings set late_tolerance_minutes = 10 where company_id = $1`, [company1]);
  await db.query(`update hr_attendances set scheduled_start = scheduled_start where id = $1`, [attAndi]);
  const rec = await val(`select hr_attendance_recap($1::date - 7, $1::date, null)`, [todayLocal]);
  const andi = rec.find((r) => r.full_name === 'Andi Saputra' && r.work_date === todayLocal);
  assert(andi && andi.status === 'late' && andi.late_minutes === 30 && andi.check_in_photo, JSON.stringify(andi));
  assert(rec.some((r) => r.full_name === 'Siti Aminah' && r.status === 'off') && rec.some((r) => r.full_name === 'Siti Aminah' && r.status === 'absent'), JSON.stringify(rec.map((r) => [r.full_name, r.work_date, r.status])));
  assert((await val(`select hr_attendance_pending_count()`)) >= 1, 'badge');
  await db.query(`select hr_review_attendance($1, true, 'Antar barang ke gudang')`, [attAndi]);
  assert((await val(`select review_status from hr_attendances where id = $1`, [attAndi])) === 'approved', 'review');
  await loginAs('44444444-4444-4444-4444-444444444444');
  assert((await val(`select hr_attendance_recap(current_date - 7, current_date, null)`)).length === 0, 'bocor ke PT lain');
  assert((await val(`select count(*)::int from hr_attendances`)) === 0, 'tabel bocor');
});
await check('Absensi: koreksi absen diajukan karyawan, disetujui HR, tidak bisa setujui sendiri', async () => {
  await loginAs(KASIR);
  const yesterday = await val(`select to_char($1::date - 1, 'YYYY-MM-DD')`, [todayLocal]);
  const id = await val(`select hr_request_correction($1::date, ($1 || ' 07:02+07')::timestamptz, ($1 || ' 15:05+07')::timestamptz, 'HP mati')`, [yesterday]);
  await expectError(`select hr_request_correction($1::date, ($1 || ' 07:00+07')::timestamptz, null, 'lagi')`, [yesterday], /Masih ada pengajuan/);
  await expectError(`select hr_request_correction(current_date - 2, null, null, 'x')`, [], /Isi jam/);
  await expectError(`select hr_review_correction($1, true)`, [id], /sendiri/);
  assert((await val(`select hr_my_attendance(current_date - 7, current_date + 1)`)).corrections[0].status === 'pending', 'riwayat');
  await loginAs(U1);
  const inbox = await val(`select hr_correction_inbox('pending')`);
  assert(inbox.length === 1 && inbox[0].full_name === 'Andi Saputra', JSON.stringify(inbox));
  await db.query(`select hr_review_correction($1, true, 'ok')`, [id]);
  const a = await one(`select check_in_at, check_out_at, flags, review_status from hr_attendances where employee_id = $1 and work_date = $2::date`, [empAndi, yesterday]);
  assert(a && a.flags.includes('corrected') && a.review_status === 'approved' && a.check_out_at > a.check_in_at, JSON.stringify(a));
  await expectError(`select hr_review_correction($1, false)`, [id], /sudah diproses/);
});

console.log('\nSDM / HR (fase C - cuti & izin):');
const dOff = (n) => val(`select to_char(current_date + $1::int, 'YYYY-MM-DD')`, [n]);
const typeId = (code) => val(`select id from hr_leave_types where company_id = $1 and code = $2`, [company1, code]);
let cutiReq, supervisorEmp;
await check('Cuti: jenis cuti standar otomatis (perusahaan lama & baru)', async () => {
  await loginAs(U1);
  assert((await val(`select count(*)::int from hr_leave_types where company_id = $1`, [company1])) === 6, 'jenis cuti PT 1');
  await db.exec('reset role');
  assert((await val(`select count(*)::int from hr_leave_types where company_id = $1`, [company2])) === 6, 'jenis cuti PT 2');
  const c = await val(`insert into sys_companies (code, name) values ('CUTI-BARU', 'PT Cuti Baru') returning id`);
  assert((await val(`select count(*)::int from hr_leave_types where company_id = $1`, [c])) === 6, 'PT baru');
});
await check('Cuti: saldo 12 hari berlaku setelah 12 bulan kerja; penyesuaian saldo; prorata', async () => {
  await loginAs(KASIR);
  const cuti = await typeId('CUTI');
  const [s, e] = [await dOff(20), await dOff(21)];
  // Andi baru 200 hari kerja -> belum berhak
  await expectError(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: cuti, start_date: s, end_date: e, reason: 'Pulang kampung' })], /Sisa cuti tidak cukup.*berhak cuti mulai/);
  await loginAs(U1);
  await db.query(`insert into hr_leave_adjustments (company_id, employee_id, year, days, note) values ($1, $2, extract(year from $3::date), 3, 'Saldo awal')`, [company1, empAndi, s]);
  await loginAs(KASIR);
  const r = await val(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: cuti, start_date: s, end_date: e, reason: 'Pulang kampung' })]);
  assert(r.status === 'pending' && Number(r.days) === 2 && r.approval_request_id, JSON.stringify(r));
  cutiReq = r.id;
  const my = await val(`select hr_my_leave()`);
  assert(Number(my.balance.remaining) === 1 && Number(my.balance.pending) === 2 && my.types.length === 6, JSON.stringify(my.balance));
  await expectError(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: await typeId('IZIN'), start_date: e, end_date: e, reason: 'x' })], /bertabrakan/);
  // prorata: tahun masuk dihitung sebanding bulan kerja
  await loginAs(U1);
  await db.query(`insert into hr_settings (company_id, leave_policy) values ($1, 'prorata') on conflict (company_id) do update set leave_policy = 'prorata'`, [company1]);
  const b = await val(`select hr_leave_balance($1, extract(year from current_date)::int)`, [empAndi]);
  const joinYear = Number(await val(`select extract(year from join_date)::int from hr_employees where id = $1`, [empAndi]));
  const expect = joinYear < new Date().getUTCFullYear() ? 12 : Math.floor(12 * (13 - Number(await val(`select extract(month from join_date)::int from hr_employees where id = $1`, [empAndi]))) / 12);
  assert(Number(b.entitlement) === expect && b.policy === 'prorata', JSON.stringify(b));
  await db.query(`update hr_settings set leave_policy = 'after_12_months' where company_id = $1`, [company1]);
});
await check('Cuti: sakit 2 hari wajib surat dokter; hari libur tidak dihitung; batas hari per jenis', async () => {
  await loginAs(KASIR);
  const sakit = await typeId('SAKIT');
  const [s, e] = [await dOff(40), await dOff(41)];
  await expectError(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: sakit, start_date: s, end_date: e, reason: 'Demam' })], /wajib melampirkan/);
  const doc = `${company1}/${empAndi}/leave/surat-dokter.jpg`;
  await db.query(`insert into storage.objects (bucket_id, name) values ('hr-files', $1)`, [doc]);
  await expectError(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: sakit, start_date: s, end_date: e, reason: 'Demam', attachment_path: `${company1}/${empAndi}/kontrak.pdf` })], /Lampiran tidak valid/);
  const r = await val(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: sakit, start_date: s, end_date: e, reason: 'Demam', attachment_path: doc })]);
  assert(r.attachment_path === doc && Number(r.days) === 2, JSON.stringify(r));
  // libur terjadwal di tengah rentang tidak dihitung
  await loginAs(U1);
  await db.query(`select hr_roster_save($1::jsonb)`, [JSON.stringify([{ employee_id: empAndi, work_date: await dOff(30), is_off: true }])]);
  await loginAs(KASIR);
  const iz = await val(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: await typeId('IZIN'), start_date: await dOff(29), end_date: await dOff(31), reason: 'Urusan keluarga' })]);
  assert(Number(iz.days) === 2, `hari izin ${iz.days}`);
  const half = await val(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: await typeId('IZIN'), start_date: await dOff(33), half_day: true, reason: 'Ke bank' })]);
  assert(Number(half.days) === 0.5, `setengah hari ${half.days}`);
  await expectError(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: await typeId('MENIKAH'), start_date: await dOff(50), end_date: await dOff(53), reason: 'Nikah' })], /maksimal 3 hari/);
  await expectError(`select hr_decide_leave($1, true)`, [iz.id], /sendiri/);
  await expectError(`select sys_decide_approval($1, true)`, [iz.approval_request_id], /berwenang|sendiri/);
});
await check('Cuti: disetujui lewat menu Persetujuan / HR / atasan langsung; ditolak wajib alasan', async () => {
  await loginAs(U1);
  // menu Persetujuan (sys_decide_approval) -> pengajuan cuti ikut disetujui
  const ar = await val(`select approval_request_id from hr_leave_requests where id = $1`, [cutiReq]);
  await db.query(`select sys_decide_approval($1, true, 'Selamat liburan')`, [ar]);
  assert((await val(`select status from hr_leave_requests where id = $1`, [cutiReq])) === 'approved', 'sinkron approval');
  const b = await val(`select hr_leave_balance($1, extract(year from $2::date)::int)`, [empAndi, await dOff(20)]);
  assert(Number(b.used) === 2 && Number(b.remaining) === 1, JSON.stringify(b));
  // tolak dari HR wajib alasan
  const iz = await val(`select id from hr_leave_requests where employee_id = $1 and days = 2 and leave_type_id = $2`, [empAndi, await typeId('IZIN')]);
  await expectError(`select hr_decide_leave($1, false)`, [iz], /Alasan penolakan/);
  await db.query(`select hr_decide_leave($1, false, 'Sedang ramai, mohon geser tanggal')`, [iz]);
  assert((await val(`select status from sys_approval_requests where document_type = 'leave' and document_id = $1`, [iz])) === 'rejected', 'approval ikut ditolak');
  // atasan langsung (pelayan tanpa izin HR) bisa memutuskan bawahannya
  supervisorEmp = await val(`insert into hr_employees (company_id, full_name, user_id, outlet_id) values ($1, 'Sari Supervisor', $2, $3) returning id`, [company1, U6, outletId]);
  await db.query(`update hr_employees set manager_id = $2 where id = $1`, [empAndi, supervisorEmp]);
  await loginAs(KASIR);
  const nikah = await val(`select hr_request_leave($1::jsonb)`, [JSON.stringify({ leave_type_id: await typeId('MENIKAH'), start_date: await dOff(55), end_date: await dOff(57), reason: 'Menikah' })]);
  await loginAs(U6);
  assert((await val(`select hr_leave_pending_count()`)) >= 1, 'badge atasan');
  const board = await val(`select hr_leave_board(current_date, current_date + 60, null)`);
  assert(board.requests.some((r) => r.id === nikah.id && r.can_decide === true) && board.requests.every((r) => r.full_name === 'Andi Saputra'), JSON.stringify(board.requests.map((r) => [r.full_name, r.can_decide])));
  await db.query(`select hr_decide_leave($1, true, 'Selamat!')`, [nikah.id]);
  assert((await val(`select status from hr_leave_requests where id = $1`, [nikah.id])) === 'approved', 'atasan setujui');
  // tampil di jadwal & rekap absensi
  await loginAs(KASIR);
  const sch = await val(`select hr_schedule_for($1, current_date + 56)`, [empAndi]);
  assert(sch.leave?.leave_type === 'Cuti menikah', JSON.stringify(sch.leave));
  await loginAs(U1);
  const rec = await val(`select hr_attendance_recap(current_date + 55, current_date + 57, null)`);
  assert(rec.filter((r) => r.full_name === 'Andi Saputra' && r.status === 'leave').length === 3, JSON.stringify(rec.map((r) => [r.full_name, r.status])));
  // rekan satu outlet melihat siapa yang cuti (tanpa alasan)
  await loginAs(U6);
  const team = (await val(`select hr_my_leave()`)).team;
  assert(Array.isArray(team) && team.every((t) => !('reason' in t)), JSON.stringify(team));
});
await check('Cuti: batal (menunggu / disetujui belum mulai) mengembalikan saldo; isolasi PT', async () => {
  await loginAs(KASIR);
  await db.query(`select hr_cancel_leave($1)`, [cutiReq]);
  const my = await val(`select hr_my_leave()`);
  assert(my.requests.find((r) => r.id === cutiReq).status === 'cancelled', 'batal');
  const b = await val(`select hr_leave_balance($1, extract(year from $2::date)::int)`, [empAndi, await dOff(20)]);
  assert(Number(b.used) === 0 && Number(b.remaining) >= 3, JSON.stringify(b));
  const sick = my.requests.find((r) => r.leave_type === 'Sakit');
  await db.query(`select hr_cancel_leave($1)`, [sick.id]);
  assert((await val(`select status from sys_approval_requests where id = $1`, [sick.approval_request_id])).toString() === 'cancelled', 'approval batal');
  await expectError(`select hr_cancel_leave($1)`, [sick.id], /tidak bisa dibatalkan/);
  await loginAs(U4b);
  assert((await val(`select hr_leave_board(current_date - 30, current_date + 90, null)`)).requests.length === 0, 'bocor ke PT lain');
  assert((await val(`select count(*)::int from hr_leave_requests`)) === 0, 'tabel bocor');
  // owner PT lain punya izin, tapi tidak melihat karyawan PT 1
  assert((await val(`select hr_leave_balances(null, null)`)).every((x) => x.full_name !== 'Andi Saputra'), 'saldo bocor');
  await loginAs(KASIR);
  await expectError(`select hr_leave_balances(null, null)`, [], /izin/);
});

console.log('\nSDM / HR (fase D - tugas & SOP):');
let taskA, cashierRoleId;
await check('Tugas: owner memberi tugas ke kasir; terlihat penerima & atasannya, tidak oleh PT lain', async () => {
  await loginAs(U1);
  cashierRoleId = await val(`select role_id from sys_users where id = $1`, [KASIR]);
  const t = await val(`select hr_task_save($1::jsonb)`, [JSON.stringify({ title: 'Bersihkan mesin espresso', assignee_id: KASIR, priority: 'high', due_date: await dOff(0),
    outlet_id: outletId, labels: ['kebersihan'], requires_photo: true, checklist: [{ text: 'Backflush', done: false }, { text: 'Lap steam wand', done: false }] })]);
  assert(/^TSK-\d{4}$/.test(t.task_number) && t.status === 'new', JSON.stringify(t));
  taskA = t.id;
  await loginAs(KASIR);
  const mine = await val(`select hr_task_board('mine', null, false)`);
  assert(mine.some((x) => x.id === taskA && x.roles.doer && !x.roles.manager), JSON.stringify(mine.map((x) => [x.title, x.roles])));
  assert(Number((await val(`select hr_task_counts()`)).new) >= 1, 'badge tugas baru');
  await loginAs(U6);   // atasan langsung Andi
  assert((await val(`select hr_task_board('all', null, false)`)).some((x) => x.id === taskA), 'atasan melihat tugas bawahan');
  await loginAs(U4b);
  assert((await val(`select hr_task_board('all', null, true)`)).length === 0 && (await val(`select count(*)::int from hr_tasks`)) === 0, 'bocor ke PT lain');
  assert((await val(`select hr_task_detail($1)`, [taskA])) === null, 'detail bocor');
});
await check('Tugas: alur kerja - checklist & foto bukti wajib sebelum review; dikembalikan wajib catatan; selesai oleh pembuat', async () => {
  await loginAs(KASIR);
  await db.query(`select hr_task_move($1, 'in_progress')`, [taskA]);
  await expectError(`select hr_task_move($1, 'done')`, [taskA], /Review dulu/);
  await expectError(`select hr_task_move($1, 'review')`, [taskA], /Checklist/);
  // penerima hanya bisa mencentang checklist (judul tidak berubah)
  const upd = await val(`select hr_task_save($1::jsonb)`, [JSON.stringify({ id: taskA, title: 'Diganti kasir', checklist: [{ text: 'Backflush', done: true }, { text: 'Lap steam wand', done: true }] })]);
  assert(upd.title === 'Bersihkan mesin espresso' && upd.checklist.every((c) => c.done), JSON.stringify(upd));
  await expectError(`select hr_task_move($1, 'review')`, [taskA], /foto bukti/);
  const photo = `${company1}/tasks/${taskA}/bukti.jpg`;
  await db.query(`insert into storage.objects (bucket_id, name) values ('task-files', $1)`, [photo]);
  await expectError(`select hr_task_photo($1, $2)`, [taskA, `${company1}/tasks/${taskA}/belum-ada.jpg`], /belum terunggah/);
  await db.query(`select hr_task_photo($1, $2)`, [taskA, photo]);
  await db.query(`select hr_task_move($1, 'review')`, [taskA]);
  await expectError(`select hr_task_move($1, 'archived')`, [taskA], /pembuat tugas|direview/);
  await db.query(`select hr_task_comment($1, 'Sudah bersih, cek ya')`, [taskA]);
  await loginAs(U1);
  await expectError(`select hr_task_move($1, 'in_progress')`, [taskA], /catatan/);
  await db.query(`select hr_task_move($1, 'in_progress', 'Drip tray belum dicuci')`, [taskA]);
  await loginAs(KASIR);
  await db.query(`select hr_task_move($1, 'review')`, [taskA]);
  await loginAs(U1);
  assert(Number((await val(`select hr_task_counts()`)).review) >= 1, 'badge review');
  const done = await val(`select hr_task_move($1, 'done')`, [taskA]);
  assert(done.status === 'done' && done.done_by === U1 && done.started_at, JSON.stringify(done));
  const d = await val(`select hr_task_detail($1)`, [taskA]);
  assert(d.comments.filter((c) => c.kind === 'event').length >= 6 && d.comments.some((c) => c.kind === 'comment' && c.body === 'Sudah bersih, cek ya'),
    JSON.stringify(d.comments.map((c) => [c.kind, c.body])));
  assert(d.comments.some((c) => c.body.includes('Drip tray belum dicuci')), 'catatan pengembalian tercatat');
});
await check('Tugas: tugas tim diambil anggota pertama; tugas pribadi bisa langsung selesai; foto ke tugas orang lain ditolak', async () => {
  await loginAs(U1);
  const team = await val(`select hr_task_save($1::jsonb)`, [JSON.stringify({ title: 'Cek stok gelas', assignee_role_id: cashierRoleId, outlet_id: outletId })]);
  const secret = await val(`select hr_task_save($1::jsonb)`, [JSON.stringify({ title: 'Rahasia owner' })]);
  await loginAs(U6);
  assert(!(await val(`select hr_task_board('all', null, false)`)).some((x) => x.id === team.id), 'pelayan melihat tugas tim kasir');
  await loginAs(KASIR);
  assert((await val(`select hr_task_board('mine', null, false)`)).some((x) => x.id === team.id), 'kasir melihat tugas tim');
  const taken = await val(`select hr_task_move($1, 'in_progress')`, [team.id]);
  assert(taken.assignee_id === KASIR, 'diambil');
  await expectError(`insert into storage.objects (bucket_id, name) values ('task-files', $1)`, [`${company1}/tasks/${secret.id}/x.jpg`], /row-level security/);
  const own = await val(`select hr_task_save($1::jsonb)`, [JSON.stringify({ title: 'Isi ulang tisu' })]);
  assert((await val(`select hr_task_move($1, 'done')`, [own.id])).status === 'done', 'tugas pribadi selesai');
  await loginAs(U6);
  assert((await val(`select hr_task_board('all', null, false)`)).some((x) => x.id === team.id), 'setelah diambil kasir, atasan melihat');
});
await check('SOP harian: dibuat otomatis per hari untuk role-nya; item foto wajib; rekap kepatuhan', async () => {
  await loginAs(U1);
  await db.query(`insert into hr_sop_templates (company_id, name, role_id, items) values ($1, 'Buka toko', $2, $3::jsonb)`,
    [company1, cashierRoleId, JSON.stringify([{ text: 'Nyalakan mesin kasir' }, { text: 'Foto etalase', photo: true }])]);
  await loginAs(KASIR);
  const runs = await val(`select hr_my_sops()`);
  assert(runs.length === 1 && runs[0].items.length === 2 && runs[0].outlet === (await val(`select name from sys_outlets where id = $1`, [outletId])), JSON.stringify(runs));
  assert((await val(`select hr_my_sops()`)).length === 1 && (await val(`select count(*)::int from hr_sop_runs`)) === 1, 'tidak dobel');
  const run = runs[0].id;
  await db.query(`select hr_sop_check($1, 0, true)`, [run]);
  await expectError(`select hr_sop_check($1, 1, true)`, [run], /wajib foto/);
  const pic = `${company1}/sop/${run}/etalase.jpg`;
  await db.query(`insert into storage.objects (bucket_id, name) values ('task-files', $1)`, [pic]);
  const r = await val(`select hr_sop_check($1, 1, true, $2)`, [run, pic]);
  assert(r.completed_at && r.items[1].by === KASIR && r.items[1].by_name, JSON.stringify(r));
  await expectError(`insert into hr_sop_templates (company_id, name) values ($1, 'x')`, [company1], /row-level security/);
  await loginAs(U6);
  assert((await val(`select hr_my_sops()`)).length === 0, 'pelayan dapat SOP kasir');
  await expectError(`select hr_sop_check($1, 0, false)`, [run], /bukan untuk role/);
  await loginAs(U1);
  const rep = await val(`select hr_sop_report(current_date - 1, current_date + 1, null)`);
  assert(rep.runs.length === 1 && Number(rep.runs[0].done) === 2 && rep.templates[0].role === (await val(`select name from sys_roles where id = $1`, [cashierRoleId])), JSON.stringify(rep).slice(0, 300));
});

console.log('\nSDM / HR (fase E - penilaian kinerja):');
let periodId, apprAndi;
await check('Penilaian: nilai akhir berbobot & grade; kriteria otomatis tanpa data diabaikan', async () => {
  const crit = JSON.stringify([{ key: 'a', kind: 'rating', weight: 50 }, { key: 'b', kind: 'rating', weight: 50 }, { key: 'c', kind: 'auto', metric: 'tasks', weight: 40 }]);
  const r = await val(`select hr_appraisal_score($1::jsonb, $2::jsonb, $3::jsonb)`, [crit, JSON.stringify({ a: { score: 5 }, b: { score: 3 } }), JSON.stringify({ tasks: { score: null } })]);
  assert(Number(r.score) === 4 && r.grade === 'B', JSON.stringify(r));
  const r2 = await val(`select hr_appraisal_score($1::jsonb, $2::jsonb, $3::jsonb)`, [crit, JSON.stringify({ a: { score: 5 }, b: { score: 5 } }), JSON.stringify({ tasks: { score: 1 } })]);
  assert(Number(r2.score) === 3.86 && r2.grade === 'B', JSON.stringify(r2));
  assert((await val(`select hr_rate_to_score(0.97)`)) === 4 && (await val(`select hr_rate_to_score(0.5)`)) === 1, 'skala');
});
await check('Penilaian: template per role, periode, mulai penilaian (karyawan berakun mulai dari penilaian diri)', async () => {
  await loginAs(U1);
  await db.query(`insert into hr_appraisal_templates (company_id, name, criteria) values ($1, 'Umum', $2::jsonb)`, [company1, JSON.stringify([
    { key: 'hadir', name: 'Kehadiran', kind: 'auto', metric: 'attendance', weight: 20 }, { key: 'kualitas', name: 'Kualitas kerja', kind: 'rating', weight: 80 }])]);
  await db.query(`insert into hr_appraisal_templates (company_id, name, role_id, criteria) values ($1, 'Kasir', $2, $3::jsonb)`, [company1, cashierRoleId, JSON.stringify([
    { key: 'hadir', name: 'Kehadiran', kind: 'auto', metric: 'attendance', weight: 15 }, { key: 'tepat', name: 'Tepat waktu', kind: 'auto', metric: 'punctuality', weight: 15 },
    { key: 'tugas', name: 'Tugas', kind: 'auto', metric: 'tasks', weight: 20 }, { key: 'layan', name: 'Pelayanan', kind: 'rating', weight: 30 },
    { key: 'tim', name: 'Kerja sama', kind: 'rating', weight: 20 }])]);
  periodId = await val(`insert into hr_appraisal_periods (company_id, name, start_date, end_date) values ($1, 'Q4', current_date - 30, current_date + 30) returning id`, [company1]);
  const res = await val(`select hr_appraisal_start($1)`, [periodId]);
  assert(res.created >= 3, JSON.stringify(res));
  const andi = await one(`select id, template_name, status, reviewer_id from hr_appraisals where period_id = $1 and employee_id = $2`, [periodId, empAndi]);
  assert(andi.template_name === 'Kasir' && andi.status === 'self' && andi.reviewer_id === U6, JSON.stringify(andi));
  apprAndi = andi.id;
  assert((await val(`select status from hr_appraisals where period_id = $1 and employee_id = (select id from hr_employees where full_name = 'Siti Aminah')`, [periodId])) === 'manager', 'tanpa akun langsung ke atasan');
  assert((await val(`select hr_appraisal_start($1)`, [periodId])).created === 0, 'tidak dobel');
  await loginAs(KASIR);
  await expectError(`select hr_appraisal_start($1)`, [periodId], /izin/);
  await expectError(`insert into hr_appraisal_templates (company_id, name) values ($1, 'x')`, [company1], /row-level security/);
});
await check('Penilaian: diri sendiri -> atasan langsung (metrik otomatis) -> karyawan konfirmasi; nilai atasan tersembunyi sebelum dikirim', async () => {
  await loginAs(KASIR);
  const mine = await val(`select hr_my_appraisals()`);
  assert(mine.some((m) => m.id === apprAndi && m.access === 'self') && (await val(`select hr_appraisal_todo_count()`)) >= 1, JSON.stringify(mine));
  assert((await val(`select count(*)::int from hr_appraisals`)) === 0, 'kasir membaca tabel langsung');
  await expectError(`select hr_appraisal_submit_manager($1, '{}'::jsonb, null, null, null)`, [apprAndi], /bukan penilai/);
  await db.query(`select hr_appraisal_submit_self($1, $2::jsonb, 'Saya sudah berusaha')`, [apprAndi, JSON.stringify({ layan: { score: 5 }, tim: { score: 4 } })]);
  await expectError(`select hr_appraisal_submit_self($1, '{}'::jsonb)`, [apprAndi], /sudah dikirim/);
  await loginAs(U6);   // atasan langsung
  assert((await val(`select hr_my_appraisals()`)).some((m) => m.id === apprAndi && m.access === 'reviewer'), 'atasan melihat');
  const d = await val(`select hr_appraisal_detail($1)`, [apprAndi]);
  assert(d.self_scores.layan.score === 5 && d.live_metrics.attendance.scheduled >= 1, JSON.stringify(d.live_metrics));
  await expectError(`select hr_appraisal_submit_manager($1, $2::jsonb, null, null, null)`, [apprAndi, JSON.stringify({ layan: { score: 4 } })], /wajib dinilai/);
  const r = await val(`select hr_appraisal_submit_manager($1, $2::jsonb, 'Ramah', 'Datang lebih pagi', 'Belajar latte art')`, [apprAndi, JSON.stringify({ layan: { score: 4 }, tim: { score: 4 } })]);
  assert(r.grade && Number(r.score) > 0, JSON.stringify(r));
  await loginAs(KASIR);
  const mineDone = await val(`select hr_appraisal_detail($1)`, [apprAndi]);
  assert(mineDone.status === 'acknowledge' && mineDone.grade === r.grade && mineDone.goals === 'Belajar latte art' && mineDone.metrics.attendance, JSON.stringify(mineDone).slice(0, 300));
  await db.query(`select hr_appraisal_acknowledge($1, 'Terima kasih, siap')`, [apprAndi]);
  await loginAs(U1);
  const ov = await val(`select hr_appraisal_overview($1)`, [periodId]);
  assert(ov.find((x) => x.id === apprAndi).status === 'done', JSON.stringify(ov));
  await db.query(`select hr_appraisal_reopen($1)`, [apprAndi]);
  assert((await val(`select status from hr_appraisals where id = $1`, [apprAndi])) === 'manager', 'buka lagi');
  await loginAs(U4b);
  assert((await val(`select hr_appraisal_detail($1)`, [apprAndi])) === null && (await val(`select hr_my_appraisals()`)).length === 0, 'bocor ke PT lain');
});
await check('Penilaian: karyawan tidak melihat nilai atasan sebelum dikirim', async () => {
  // dibuka lagi -> status manager: nilai atasan disembunyikan dari karyawan
  await loginAs(KASIR);
  const d = await val(`select hr_appraisal_detail($1)`, [apprAndi]);
  assert(d.status === 'manager' && !('manager_scores' in d) && !('grade' in d) && !('live_metrics' in d && d.live_metrics), JSON.stringify(Object.keys(d)));
});

console.log('\nUser Management <-> data karyawan:');
await check('Akun tanpa data karyawan bisa dibuatkan datanya; tanpa data pribadi; tidak lintas PT; email sintetis tidak disalin', async () => {
  await db.exec('reset role');
  const orphan = await val(`select u.id from sys_users u where u.company_id = $1 and u.id <> $2
    and not exists (select 1 from hr_employees e where e.user_id = u.id) order by u.created_at limit 1`, [company1, U1]);
  assert(orphan, 'tidak ada user tanpa data karyawan');
  await db.query(`update auth.users set email = 'kasir2@staff.santap.local' where id = $1`, [orphan]);
  await loginAs(KASIR);
  await expectError(`select hr_create_employee_for_user($1)`, [orphan], /izin/);
  assert((await val(`select hr_user_links()`)).length === 0, 'kasir melihat tautan akun');
  await loginAs(U1);
  const links = await val(`select hr_user_links()`);
  assert(links.some((l) => l.user_id === KASIR) && !links.some((l) => l.user_id === orphan) && links.every((l) => Object.keys(l).sort().join() === 'employee_id,employee_number,is_active,user_id'), JSON.stringify(links));
  const e = await val(`select hr_create_employee_for_user($1)`, [orphan]);
  assert(/^EMP-/.test(e.employee_number), JSON.stringify(e));
  const row = await one(`select full_name, email, user_id from hr_employees where id = $1`, [e.id]);
  assert(row.user_id === orphan && row.email === null && row.full_name, JSON.stringify(row));
  await expectError(`select hr_create_employee_for_user($1)`, [orphan], /sudah punya/);
  await expectError(`select hr_create_employee_for_user($1)`, [U2], /tidak ditemukan/);
});

console.log('\nStruk & ulasan pelanggan:');
const asAnon = () => db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;`);
let fbToken, fbOrder;
await check('Struk: data lengkap dalam satu panggilan, token ulasan acak & tetap; PT lain ditolak', async () => {
  await loginAs(U1);
  const orders = (await db.query(`select id from pos_orders where company_id = $1 and status = 'paid' order by paid_at desc limit 2`, [company1])).rows;
  fbOrder = orders[0].id;
  const r = await val(`select pos_receipt_data($1)`, [fbOrder]);
  assert(r.order.order_number && r.items.length > 0 && r.outlet.name && r.payments.length > 0 && /^[0-9a-f]{32}$/.test(r.feedback_token), JSON.stringify(r).slice(0, 300));
  fbToken = r.feedback_token;
  assert((await val(`select pos_receipt_data($1)`, [fbOrder])).feedback_token === fbToken, 'token berubah');
  await expectError(`select pos_receipt_payload($1)`, [fbOrder], /permission denied/);
  await loginAs(U4b);
  await expectError(`select pos_receipt_data($1)`, [fbOrder], /tidak ditemukan/);
  // struk kedua dibuat kedaluwarsa
  await loginAs(U1);
  const old = await val(`select pos_receipt_data($1)`, [orders[1].id]);
  await db.exec('reset role');
  await db.query(`update pos_orders set paid_at = now() - interval '30 days' where id = $1`, [orders[1].id]);
  await asAnon();
  assert((await val(`select public_feedback_form($1)`, [old.feedback_token])).state === 'expired', 'kedaluwarsa');
});
await check('Ulasan publik (tanpa login): form tanpa harga/isi pesanan, validasi jawaban, sekali per struk', async () => {
  await asAnon();
  assert((await val(`select public_feedback_form('abc')`)).state === 'invalid', 'token asal');
  assert((await val(`select public_feedback_form($1)`, ['0'.repeat(32)])).state === 'invalid', 'token tebakan');
  const f = await val(`select public_feedback_form($1)`, [fbToken]);
  assert(f.state === 'open' && f.questions.length === 5 && f.outlet && !JSON.stringify(f).includes('grand_total') && !('items' in f), JSON.stringify(f).slice(0, 300));
  const q = Object.fromEntries(f.questions.map((x) => [x.kind, x.id]));
  const sub = (a, c = {}) => db.query(`select public_submit_feedback($1, $2::jsonb, $3::jsonb)`, [fbToken, JSON.stringify(a), JSON.stringify(c)]);
  await expectError(`select public_submit_feedback($1, $2::jsonb)`, [fbToken, JSON.stringify({ [q.nps]: 9 })], /wajib/);
  await expectError(`select public_submit_feedback($1, $2::jsonb)`, [fbToken, JSON.stringify({ [q.stars]: 7 })], /bintang/);
  await expectError(`select public_submit_feedback($1, $2::jsonb)`, [fbToken, JSON.stringify({ [q.stars]: 4, [q.aspects]: { Hacker: 5 } })], /aspek/);
  await expectError(`select public_submit_feedback($1, $2::jsonb)`, [fbToken, JSON.stringify({ [q.stars]: 4, [q.choice]: ['Gratis'] })], /Pilihan/);
  const r = (await sub({ [q.stars]: 2, [q.aspects]: { 'Rasa makanan & minuman': 3, 'Kecepatan penyajian': 1 }, [q.nps]: 6, [q.choice]: ['Rasa'], [q.text]: 'Nasi kurang hangat', 'bukan-pertanyaan': 'x' },
    { name: 'Budi', phone: '0812-333 444', ok: true })).rows[0].public_submit_feedback;
  assert(r.ok && r.google_review_url == null, JSON.stringify(r));
  await expectError(`select public_submit_feedback($1, $2::jsonb)`, [fbToken, JSON.stringify({ [q.stars]: 5 })], /sudah dikirim/);
  assert((await val(`select count(*)::int from crm_feedback_responses`).catch(() => 0)) === 0, 'anon membaca ulasan');
  await expectError(`select crm_feedback_summary(current_date - 7, current_date)`, [], /izin/);
});
await check('Ulasan: analisa (rata-rata, NPS, aspek, pilihan), tindak lanjut ulasan buruk, hanya untuk yang berizin', async () => {
  await loginAs(U1);
  const s = await val(`select crm_feedback_summary(current_date - 40, current_date + 1, null)`);
  assert(s.responses === 1 && Number(s.avg_overall) === 2 && Number(s.nps) === -100 && s.negative_open === 1, JSON.stringify(s).slice(0, 300));
  const choice = s.questions.find((x) => x.kind === 'choice');
  const aspects = s.questions.find((x) => x.kind === 'aspects');
  assert(choice.stats.Rasa === 1 && Number(aspects.stats['Kecepatan penyajian'].avg) === 1, JSON.stringify(s.questions));
  const list = await val(`select crm_feedback_list(current_date - 40, current_date + 1, null, 'negative')`);
  assert(list.length === 1 && list[0].comment === 'Nasi kurang hangat' && list[0].contact_phone === '0812333444' && list[0].contact_ok, JSON.stringify(list[0]));
  await db.query(`select crm_feedback_update($1, 'followed_up', 'Sudah ditelepon, diberi voucher')`, [list[0].id]);
  assert((await val(`select crm_feedback_open_count()`)) === 0, 'badge');
  await loginAs(KASIR);
  await expectError(`select crm_feedback_summary(current_date - 7, current_date)`, [], /izin/);
  assert((await val(`select count(*)::int from crm_feedback_responses`)) === 0, 'kasir membaca ulasan');
  await expectError(`insert into crm_feedback_questions (company_id, kind, label) values ($1, 'text', 'x')`, [company1], /row-level security/);
  await loginAs(U4b);
  assert((await val(`select crm_feedback_summary(current_date - 40, current_date + 1, null)`)).responses === 0, 'bocor ke PT lain');
});

console.log('\nSelf-order kiosk:');
let kioskToken, kioskId, kioskOrder;
await check('Kiosk: dibuat & diatur oleh yang berizin; menu publik dengan harga per kanal, unggulan & stok habis', async () => {
  await loginAs(U1);
  const k = await one(`insert into pos_kiosks (company_id, outlet_id, name, allow_takeaway) values ($1, $2, 'Kiosk depan', false) returning id, token`, [company1, outletId]);
  kioskId = k.id; kioskToken = k.token;
  assert(/^[0-9a-f]{32}$/.test(kioskToken), kioskToken);
  const item = await val(`select i.id from mst_menu_items i join sys_outlets o on o.brand_id = i.brand_id where o.id = $1 and i.is_active
    and not exists (select 1 from mst_menu_item_modifier_groups l where l.menu_item_id = i.id) order by i.name limit 1`, [outletId]);
  await db.query(`select pos_kiosk_set_highlight($1, true, 'Favorit')`, [item]);
  await loginAs(KASIR);
  assert((await val(`select count(*)::int from pos_kiosks`)) === 0, 'kasir melihat kiosk');
  await expectError(`select pos_kiosk_set_highlight($1, true, 'x')`, [item], /izin/);
  await asAnon();
  await expectError(`select public_kiosk_menu('salah')`, [], /tidak dikenal/);
  const m = await val(`select public_kiosk_menu($1)`, [kioskToken]);
  assert(m.items.length > 0 && m.categories.length > 0 && m.kiosk.allow_takeaway === false && m.items.find((i) => i.id === item).featured === true
    && m.items.find((i) => i.id === item).badge === 'Favorit' && m.items.every((i) => i.price_dine_in != null), JSON.stringify(m).slice(0, 300));
  assert((await val(`select count(*)::int from pos_kiosks`).catch(() => 0)) === 0, 'anon membaca kiosk');
});
await check('Kiosk: pesanan divalidasi (kanal, habis, pilihan), nomor antrean, belum masuk dapur sebelum dibayar', async () => {
  await db.exec('reset role');
  const items = (await db.query(`select i.id from mst_menu_items i join sys_outlets o on o.brand_id = i.brand_id where o.id = $1 and i.is_active
    and not exists (select 1 from mst_menu_item_modifier_groups l where l.menu_item_id = i.id) order by i.name limit 3`, [outletId])).rows.map((r) => r.id);
  await db.query(`insert into mst_menu_sold_outs (company_id, outlet_id, menu_item_id, business_date) values ($1, $2, $3, sys_outlet_business_date($2))`, [company1, outletId, items[2]]);
  const otherMod = await val(`select id from mst_modifiers limit 1`);
  await asAnon();
  const submit = (p) => db.query(`select public_kiosk_submit($1, $2::jsonb)`, [kioskToken, JSON.stringify(p)]);
  await expectError(`select public_kiosk_submit($1, $2::jsonb)`, [kioskToken, JSON.stringify({ channel: 'dine_in', items: [] })], /kosong/);
  await expectError(`select public_kiosk_submit($1, $2::jsonb)`, [kioskToken, JSON.stringify({ channel: 'takeaway', items: [{ menu_item_id: items[0], quantity: 1 }] })], /tidak tersedia/);
  await expectError(`select public_kiosk_submit($1, $2::jsonb)`, [kioskToken, JSON.stringify({ channel: 'dine_in', items: [{ menu_item_id: items[2], quantity: 1 }] })], /habis/);
  if (otherMod) await expectError(`select public_kiosk_submit($1, $2::jsonb)`, [kioskToken, JSON.stringify({ channel: 'dine_in', items: [{ menu_item_id: items[0], quantity: 1, modifier_ids: [otherMod] }] })], /tidak valid/);
  const r = (await submit({ channel: 'dine_in', customer_name: 'Rara', items: [{ menu_item_id: items[0], quantity: 2 }, { menu_item_id: items[1], quantity: 1, note: 'tanpa es' }] })).rows[0].public_kiosk_submit;
  assert(r.queue_number === 'K001' && r.receipt.order.queue_number === 'K001' && r.receipt.items.length === 2 && r.receipt.order.status === 'open', JSON.stringify(r).slice(0, 300));
  kioskOrder = r.order_id;
  const r2 = (await submit({ channel: 'dine_in', items: [{ menu_item_id: items[0], quantity: 1 }] })).rows[0].public_kiosk_submit;
  assert(r2.queue_number === 'K002', r2.queue_number);
  await db.exec('reset role');
  const o = await one(`select order_source, kiosk_id, sales_channel, customer_name from pos_orders where id = $1`, [kioskOrder]);
  assert(o.order_source === 'kiosk' && o.kiosk_id === kioskId && o.customer_name === 'Rara', JSON.stringify(o));
  assert((await val(`select count(*)::int from pos_order_items where order_id = $1 and kitchen_status = 'waiting'`, [kioskOrder])) === 2, 'belum masuk dapur');
});
await check('Kiosk: dibayar di kasir -> otomatis masuk dapur; token diganti -> link lama mati', async () => {
  await loginAs(U1);
  const total = Number(await val(`select grand_total from pos_orders where id = $1`, [kioskOrder]));
  const method = await val(`select id from mst_payment_methods where company_id = $1 order by created_at limit 1`, [company1]);
  if (!(await val(`select count(*)::int from pos_shifts where outlet_id = $1 and user_id = $2 and status = 'open'`, [outletId, U1]))) await db.query(`select pos_open_shift($1, 0)`, [outletId]);
  await db.query(`select pos_pay_order($1, $2::jsonb)`, [kioskOrder, JSON.stringify([{ payment_method_id: method, amount: total }])]);
  assert((await val(`select count(*)::int from pos_order_items where order_id = $1 and kitchen_status = 'pending'`, [kioskOrder])) === 2, 'masuk dapur setelah bayar');
  const list = await val(`select pos_kiosk_list()`);
  assert(list[0].online === true && list[0].orders_today >= 2, JSON.stringify(list));
  const newToken = await val(`select pos_kiosk_regenerate_token($1)`, [kioskId]);
  await asAnon();
  await expectError(`select public_kiosk_menu($1)`, [kioskToken], /tidak dikenal/);
  assert((await val(`select public_kiosk_menu($1)`, [newToken])).items.length > 0, 'token baru');
});

console.log('\nDashboard grup & konsolidasi:');
let grpId;
await check('Grup: hanya pemilik grup yang melihat; ringkasan semua PT sesuai data penjualan', async () => {
  await db.exec('reset role');
  grpId = await val(`insert into sys_company_groups (code, name) values ('GRP-T', 'Grup Uji') returning id`);
  await db.query(`update sys_companies set group_id = $1 where id in ($2, $3)`, [grpId, company1, company2]);
  await db.query(`insert into sys_group_members (group_id, user_id) values ($1, $2)`, [grpId, U1]);
  const expected = await val(`select coalesce(sum(subtotal - discount_amount - promotion_amount - points_amount), 0)::numeric from pos_orders
    where company_id = $1 and status = 'paid' and business_date between current_date - 30 and current_date`, [company1]);
  await loginAs(U1);
  const groups = await val(`select grp_my_groups()`);
  assert(groups.some((g) => g.id === grpId && g.companies.length === 2), JSON.stringify(groups));
  const d = await val(`select grp_dashboard($1, current_date - 30, current_date)`, [grpId]);
  const c1 = d.companies.find((c) => c.id === company1);
  assert(d.companies.length === 2 && Math.abs(Number(c1.net_sales) - Number(expected)) < 0.01 && c1.outlets >= 1, JSON.stringify(c1));
  assert(Array.isArray(d.daily) && Array.isArray(d.top_menus) && Array.isArray(d.top_outlets), 'struktur');
  await loginAs(U4b);  // user PT lain, bukan pemilik grup (U2 = Platform Admin, boleh melihat)
  await expectError(`select grp_dashboard($1, current_date - 30, current_date)`, [grpId], /bukan pemilik grup/);
  assert((await val(`select grp_my_groups()`)).length === 0, 'grup bocor');
  await loginAs(KASIR);
  await expectError(`select grp_financials($1, current_date - 30, current_date)`, [grpId], /bukan pemilik grup/);
  await expectError(`select * from grp_company_balances($1, current_date - 30, current_date, $2)`, [company1, grpId], /permission denied/);
});
await check('Konsolidasi: laba rugi & neraca per PT digabung per kode akun; transaksi antar-PT dieliminasi', async () => {
  await loginAs(U1);
  const f = await val(`select grp_financials($1, '2000-01-01', current_date + 1)`, [grpId]);
  const sales = f.accounts.find((a) => a.code === '4-1100');
  assert(f.companies.length === 2 && sales && Number(sales.by_company[company1]) > 0 && Number(sales.elimination) === 0
    && Number(sales.consolidated) === Number(sales.total), JSON.stringify(sales));
  // neraca seimbang per PT: aset = kewajiban + ekuitas + laba ditahan
  const sum = (t, cid) => f.accounts.filter((a) => a.account_type === t && !a.is_header).reduce((s, a) => s + Number(a.by_company[cid] ?? 0), 0);
  const gap = sum('asset', company1) - sum('liability', company1) - sum('equity', company1) - Number(f.retained_earnings[company1] ?? 0);
  assert(Math.abs(gap) < 1, `neraca PT1 tidak seimbang: ${gap}`);
  // tandai satu baris pendapatan sebagai transaksi ke PT 2 -> tereliminasi
  await db.exec('reset role');
  const line = await one(`select l.id, l.credit - l.debit as amt from fin_journal_lines l join fin_accounts a on a.id = l.account_id
    where l.company_id = $1 and a.code = '4-1100' and l.credit > 0 order by l.created_at limit 1`, [company1]);
  await db.query(`update fin_journal_lines set counterparty_company_id = $2 where id = $1`, [line.id, company2]);
  await loginAs(U1);
  const f2 = await val(`select grp_financials($1, '2000-01-01', current_date + 1)`, [grpId]);
  const s2 = f2.accounts.find((a) => a.code === '4-1100');
  assert(Math.abs(Number(s2.elimination) - Number(line.amt)) < 0.01 && Math.abs(Number(s2.consolidated) - (Number(s2.total) - Number(line.amt))) < 0.01, JSON.stringify(s2));
  await db.exec('reset role');
  await db.query(`update fin_journal_lines set counterparty_company_id = null where id = $1`, [line.id]);
  await db.query(`update sys_companies set group_id = null where id in ($1, $2)`, [company1, company2]);
});

console.log('\nTransaksi antar-PT dalam grup:');
let icGrp, icSup2, icPo2, icSo2, icCust1, icItem1, icItem2, wh2;
await check('Antar-PT: masuk grup -> supplier & pelanggan antar-PT otomatis; barang dicocokkan lewat kode', async () => {
  await db.exec('reset role');
  icGrp = await val(`insert into sys_company_groups (code, name) values ('GRP-IC', 'Grup Antar PT') returning id`);
  await db.query(`update sys_companies set group_id = $1 where id in ($2, $3)`, [icGrp, company1, company2]);
  await db.query(`insert into sys_group_members (group_id, user_id) values ($1, $2) on conflict do nothing`, [icGrp, U1]);
  icSup2 = await one(`select id, supplier_type, is_active from pur_suppliers where company_id = $1 and linked_company_id = $2`, [company1, company2]);
  icCust1 = await val(`select id from sal_customers where company_id = $1 and linked_company_id = $2 and is_active`, [company2, company1]);
  assert(icSup2?.supplier_type === 'intercompany' && icSup2.is_active && icCust1, JSON.stringify(icSup2));
  assert(await val(`select count(*)::int from pur_suppliers where company_id = $1 and linked_company_id = $2`, [company2, company1]) === 1, 'supplier di PT 2');
  // barang yang sama (kode BHN01) di PT 2
  icItem1 = await one(`select i.id, i.code, i.name, u.code as unit_code, i.base_unit_id from inv_items i join inv_units u on u.id = i.base_unit_id
    where i.company_id = $1 and i.code = 'BHN01'`, [company1]);
  const unit2 = (await val(`select id from inv_units where company_id = $1 and code = $2`, [company2, icItem1.unit_code]))
    ?? await val(`insert into inv_units (company_id, code, name) values ($1, $2, $2) returning id`, [company2, icItem1.unit_code]);
  icItem2 = await val(`insert into inv_items (company_id, code, name, base_unit_id) values ($1, 'BHN01', 'Beras (PT2)', $2) returning id`, [company2, unit2]);
  wh2 = await val(`select default_warehouse_id from sys_outlets where company_id = $1 and default_warehouse_id is not null order by code limit 1`, [company2]);
  assert(wh2, 'gudang PT 2');
  // stok awal PT 2 dari supplier luar
  const ext2 = await val(`insert into pur_suppliers (company_id, code, name) values ($1, 'SUPX', 'Supplier Luar') returning id`, [company2]);
  const gr0 = await val(`insert into pur_goods_receipts (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company2, ext2, wh2]);
  await db.query(`insert into pur_goods_receipt_items (company_id, goods_receipt_id, item_id, unit_id, conversion_qty, quantity, unit_price) values ($1, $2, $3, $4, 1, 50000, 12)`, [company2, gr0, icItem2, unit2]);
  await loginAs(U2);
  await db.query(`select pur_post_goods_receipt($1)`, [gr0]);
});
await check('Antar-PT: PO disetujui di PT pembeli -> SO "Baru" di PT penjual; barang tanpa pasangan & penerimaan manual ditolak', async () => {
  await loginAs(U1);
  icPo2 = await val(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, icSup2.id, await mainWh()]);
  const other = await val(`select id from inv_items where company_id = $1 and code <> 'BHN01' and is_active order by code limit 1`, [company1]);
  await expectError(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, (select base_unit_id from inv_items where id = $3), 1, 10)`,
    [company1, icPo2, other], /belum ada di/);
  await expectError(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, $4, 1000, 0)`,
    [company1, icPo2, icItem1.id, icItem1.base_unit_id], /Harga/);
  await db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, $4, 1000, 15)`,
    [company1, icPo2, icItem1.id, icItem1.base_unit_id]);
  const ap = await val(`select pur_approve_purchase_order($1)`, [icPo2]);
  assert(ap.status === 'approved', JSON.stringify(ap));
  await expectError(`select pur_create_goods_receipt_from_po($1)`, [icPo2], /PT dalam grup/);
  await db.exec('reset role');
  const so = await one(`select * from sal_sales_orders where ic_purchase_order_id = $1`, [icPo2]);
  assert(so && so.company_id === company2 && so.status === 'new' && so.customer_id === icCust1 && Number(so.subtotal) === 15000, JSON.stringify(so));
  icSo2 = so.id;
  assert((await val(`select item_id from sal_sales_order_items where sales_order_id = $1`, [icSo2])) === icItem2, 'barang PT 2');
  assert((await val(`select ic_po_item_id from sal_sales_order_items where sales_order_id = $1`, [icSo2])) === (await val(`select id from pur_purchase_order_items where purchase_order_id = $1`, [icPo2])), 'tautan item PO');
});
await check('Antar-PT: penjual kirim -> draft penerimaan otomatis di pembeli; jurnal kedua PT ditandai & dieliminasi di konsolidasi', async () => {
  await loginAs(U2);
  await db.query(`select sal_confirm_sales_order($1)`, [icSo2]);
  const d = await val(`select sal_create_delivery($1, $2)`, [icSo2, wh2]);
  await db.query(`update sal_delivery_items set quantity = 800 where delivery_id = $1`, [d]);
  await db.query(`select sal_ship_delivery($1)`, [d]);
  await loginAs(U1);
  const gr = await one(`select id, status, ic_delivery_id, delivery_id from pur_goods_receipts where purchase_order_id = $1`, [icPo2]);
  assert(gr && gr.status === 'draft' && gr.ic_delivery_id === d && gr.delivery_id === null, JSON.stringify(gr));
  assert(Number(await val(`select quantity from pur_goods_receipt_items where goods_receipt_id = $1`, [gr.id])) === 800, 'qty kiriman');
  await db.query(`select pur_post_goods_receipt($1)`, [gr.id]);
  await loginAs(U2);
  const inv = await val(`select sal_create_invoice($1)`, [icSo2]);
  assert(Number(inv.grand_total) === 12000, JSON.stringify(inv));
  await db.exec('reset role');
  const untagged = await val(`select count(*)::int from fin_journal_lines l join fin_journals j on j.id = l.journal_id
    where ((j.company_id = $1 and j.source_type = 'purchase_receipt' and j.source_id = $2) or (j.company_id = $3 and j.source_type in ('sales_delivery', 'sales_invoice') and j.source_id in ($4, $5)))
      and l.counterparty_company_id is null`, [company1, gr.id, company2, d, inv.id]);
  const tagged = await val(`select count(*)::int from fin_journal_lines where counterparty_company_id is not null`);
  assert(untagged === 0 && tagged >= 4, `untagged ${untagged}, tagged ${tagged}`);
  await loginAs(U1);
  const ov = await val(`select grp_ic_overview($1)`, [icGrp]);
  const doc = ov.documents.find((x) => x.id === icPo2);
  assert(doc && doc.so_status === 'partially_delivered' && doc.po_status === 'partially_received' && Number(doc.qty_delivered) === 800 && Number(doc.invoiced) === 12000, JSON.stringify(doc));
  const bal = ov.balances.find((b) => b.seller_id === company2 && b.buyer_id === company1);
  assert(bal && Number(bal.receivable) === 12000 && Number(bal.payable) === 12000 && Number(bal.difference) === 0, JSON.stringify(ov.balances));
  const f = await val(`select grp_financials($1, '2000-01-01', current_date + 1)`, [icGrp]);
  const rev = f.accounts.filter((a) => a.account_type === 'revenue').reduce((s, a) => s + Number(a.elimination), 0);
  const ar = f.accounts.find((a) => a.code === '1-1300');
  const apAcc = f.accounts.find((a) => a.code === '2-1100');
  assert(rev === 12000 && Number(ar.elimination) === 12000 && Number(apAcc.elimination) === 12000, JSON.stringify({ rev, ar, apAcc }));
});
await check('Antar-PT: SO ditolak penjual -> PO pembeli batal; keluar grup -> mitra antar-PT nonaktif', async () => {
  await loginAs(U1);
  const po = await val(`insert into pur_purchase_orders (company_id, supplier_id, warehouse_id) values ($1, $2, $3) returning id`, [company1, icSup2.id, await mainWh()]);
  await db.query(`insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, quantity, unit_price) values ($1, $2, $3, $4, 10, 15)`,
    [company1, po, icItem1.id, icItem1.base_unit_id]);
  await db.query(`select pur_approve_purchase_order($1)`, [po]);
  await loginAs(U2);
  const so = await val(`select id from sal_sales_orders where ic_purchase_order_id = $1`, [po]);
  await db.query(`select sal_reject_sales_order($1, 'Stok kosong')`, [so]);
  await loginAs(U1);
  assert((await val(`select status from pur_purchase_orders where id = $1`, [po])) === 'cancelled', 'PO tidak batal');
  await db.exec('reset role');
  await db.query(`update sys_companies set group_id = null where id = $1`, [company2]);
  assert((await val(`select is_active from pur_suppliers where id = $1`, [icSup2.id])) === false, 'supplier antar-PT masih aktif');
  assert((await val(`select is_active from sal_customers where id = $1`, [icCust1])) === false, 'pelanggan antar-PT masih aktif');
  await db.query(`update sys_companies set group_id = null where id = $1`, [company1]);
});

console.log('\nSemar AI: insight bisnis:');
await check('Semar: briefing bisnis sesuai data perusahaan sendiri (penjualan, stok, SDM, tugas, ulasan, keuangan)', async () => {
  await loginAs(U1);
  const b = await val(`select ai_business_brief(7)`);
  for (const k of ['periode', 'penjualan', 'stok', 'sdm', 'tugas', 'ulasan', 'persetujuan_menunggu', 'pembelian', 'keuangan_bulan_ini']) assert(k in b, `kunci ${k} hilang`);
  const expected = await val(`select count(*)::int from pos_orders where company_id = $1 and status = 'paid'
    and business_date between (now() at time zone 'Asia/Jakarta')::date - 6 and (now() at time zone 'Asia/Jakarta')::date`, [company1]);
  assert(Number(b.penjualan.periode.transaksi) === expected, `transaksi ${b.penjualan.periode.transaksi} vs ${expected}`);
  assert(Array.isArray(b.penjualan.menu_terlaris) && typeof b.sdm.karyawan_aktif === 'number' && 'laba_bersih' in b.keuangan_bulan_ini, JSON.stringify(b).slice(0, 300));
  await loginAs(U4b);
  const other = await val(`select ai_business_brief(30)`);
  assert(other.sdm && !JSON.stringify(other).includes('Andi Saputra'), 'data PT lain bocor ke briefing');
});
await check('Semar: insight ulasan tanpa kontak pelanggan; rekap SDM per karyawan; kasir ditolak', async () => {
  await loginAs(U1);
  const f = await val(`select ai_feedback_insights(current_date - 60, current_date + 1)`);
  assert(f.ringkasan && Array.isArray(f.ulasan) && f.ulasan.length >= 1 && !JSON.stringify(f.ulasan).includes('0812333444'), JSON.stringify(f).slice(0, 300));
  const r = await val(`select ai_hr_recap(current_date - 30, current_date)`);
  const andi = r.find((x) => x.nama === 'Andi Saputra');
  assert(andi && 'alpa' in andi && 'sisa_cuti_tahunan' in andi && Number(andi.hadir) >= 1, JSON.stringify(andi));
  await expectError(`select ai_hr_recap(current_date - 200, current_date)`, [], /maksimal 3 bulan/);
  await loginAs(KASIR);
  await expectError(`select ai_hr_recap(current_date - 7, current_date)`, [], /izin/);
  await expectError(`select ai_feedback_insights(current_date - 7, current_date)`, [], /izin/);
  assert((await val(`select 'hr_sop_templates' = any(ai_writable_tables()) and 'crm_feedback_questions' = any(ai_writable_tables())`)) === true, 'tabel boleh diubah Semar');
});

console.log('\nManajemen aset:');
const U11 = 'b6b6b6b6-b6b6-b6b6-b6b6-b6b6b6b6b6b6';
let astKompor, astLaptop, astChiller, astCash, astPeriod;
const astMonth = (offset) => val(`select (date_trunc('month', (now() at time zone 'Asia/Jakarta')::date) + ($1 || ' month')::interval)::date::text`, [String(offset)]);
await check('aset: setup akun & 6 kategori, batas Rp 1 jt, perolehan tunai dijurnal (Dr aset / Cr kas)', async () => {
  await loginAs(U1);
  const st = await val(`select ast_setup()`);
  assert(Number(st.capitalization_threshold) === 1000000, JSON.stringify(st));
  assert((await val(`select count(*)::int from ast_categories where company_id = $1`, [company1])) === 6, 'kategori default');
  assert((await val(`select count(*)::int from fin_accounts where company_id = $1 and system_key in ('fa_equipment', 'fa_accum_depreciation', 'depreciation_expense', 'asset_payable', 'asset_disposal_gain', 'asset_disposal_loss')`, [company1])) === 6, JSON.stringify((await db.query(`select code, name, system_key from fin_accounts where company_id = $1 and (code like '1-2%' or code like '6-%' or code like '2-14%' or code like '4-18%')`, [company1])).rows));
  const dpr = await val(`select id from ast_categories where company_id = $1 and code = 'DPR'`, [company1]);
  astCash = await val(`select id from fin_accounts where company_id = $1 and system_key = 'cash'`, [company1]);
  const acq = await val(`select ($1::date + 9)::text`, [await astMonth(-3)]);
  await expectError(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'Blender kecil', category_id: dpr, outlet_id: outletId, acquisition_date: acq, acquisition_cost: 750000, funding: 'cash', paid_from_account_id: astCash })], /batas aset/);
  const a = await val(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'Kompor 4 tungku', category_id: dpr, outlet_id: outletId, location: 'Dapur panas',
    acquisition_date: acq, acquisition_cost: 12000000, funding: 'cash', paid_from_account_id: astCash, serial_number: 'KMP-778', warranty_until: await astMonth(1) })]);
  astKompor = a.id;
  assert(/^AST-DPR-\d{4}$/.test(a.asset_number) && a.useful_life_months === 48 && a.depreciation_start === await astMonth(-3), JSON.stringify(a));
  const j = await one(`select j.total_amount, (select credit from fin_journal_lines l where l.journal_id = j.id and l.account_id = $2)::float8 cash
    from fin_journals j where j.source_type = 'asset_acquisition' and j.source_id = $1`, [astKompor, astCash]);
  assert(Number(j.total_amount) === 12000000 && j.cash === 12000000, JSON.stringify(j));
  await journalBalanced();
});
await check('aset: aset lama (saldo awal, akumulasi otomatis) & beli dengan hutang + pembayaran', async () => {
  const elk = await val(`select id from ast_categories where company_id = $1 and code = 'ELK'`, [company1]);
  const msn = await val(`select id from ast_categories where company_id = $1 and code = 'MSN'`, [company1]);
  const old = await val(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'Laptop kasir', category_id: elk, outlet_id: outletId,
    acquisition_date: await astMonth(-24), acquisition_cost: 4800000, funding: 'opening' })]);
  astLaptop = old.id;
  assert(old.opening_months === 24 && Number(old.opening_accumulated) === 2400000 && old.depreciation_start === await astMonth(0), JSON.stringify(old));
  const eq = await val(`select l.credit::float8 from fin_journal_lines l join fin_journals j on j.id = l.journal_id join fin_accounts f on f.id = l.account_id
    where j.source_id = $1 and f.system_key = 'opening_equity'`, [astLaptop]);
  assert(eq === 2400000, `ekuitas ${eq}`);
  const ch = await val(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'Chiller 2 pintu', category_id: msn, outlet_id: sc,
    acquisition_date: await astMonth(-1), acquisition_cost: 9600000, funding: 'payable' })]);
  astChiller = ch.id;
  assert(ch.useful_life_months === 96, 'umur MSN');
  await db.query(`select ast_record_payment($1, $2, 5000000, current_date, 'DP')`, [astChiller, astCash]);
  await expectError(`select ast_record_payment($1, $2, 5000000, current_date)`, [astChiller, astCash], /sisa hutang/);
  const d = await val(`select ast_asset_detail($1)`, [astChiller]);
  assert(Number(d.paid_amount) === 5000000 && d.payments.length === 1 && Number(d.monthly_depreciation) === 100000, JSON.stringify(d).slice(0, 300));
  // data keuangan terkunci setelah ada pembayaran
  await expectError(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ id: astChiller, name: 'Chiller', acquisition_cost: 9000000 })], /tidak bisa diubah/);
  await journalBalanced();
});
await check('penyusutan: pratinjau, kejar bulan tertinggal, jurnal per outlet, tidak dobel, batal periode terakhir', async () => {
  astPeriod = await astMonth(-1);
  const pv = await val(`select ast_depreciation_preview($1)`, [astPeriod]);
  const k = pv.items.find((x) => x.asset_id === astKompor), c = pv.items.find((x) => x.asset_id === astChiller);
  assert(pv.items.length === 2 && k.months === 3 && Number(k.amount) === 750000 && Number(c.amount) === 100000, JSON.stringify(pv));
  await expectError(`select ast_run_depreciation($1)`, [await astMonth(1)], /belum berjalan/);
  const r = await val(`select ast_run_depreciation($1)`, [astPeriod]);
  assert(Number(r.total) === 850000 && r.assets === 2, JSON.stringify(r));
  assert((await val(`select count(*)::int from ast_depreciation_runs where company_id = $1 and period = $2`, [company1, astPeriod])) === 2, 'per outlet');
  const a = await one(`select accumulated_depreciation::float8 acc, months_depreciated m from ast_assets where id = $1`, [astKompor]);
  assert(a.acc === 750000 && a.m === 3, JSON.stringify(a));
  await expectError(`select ast_run_depreciation($1)`, [astPeriod], /sudah dijalankan/);
  await journalBalanced();
  await db.query(`select ast_void_depreciation($1)`, [astPeriod]);
  assert((await val(`select accumulated_depreciation::float8 from ast_assets where id = $1`, [astKompor])) === 0, 'batal tidak mengembalikan akumulasi');
  assert((await val(`select count(*)::int from fin_journals where company_id = $1 and source_type = 'asset_depreciation'`, [company1])) === 0, 'jurnal penyusutan masih ada');
  await db.query(`select ast_run_depreciation($1)`, [astPeriod]);
  const s = await val(`select ast_summary()`);
  assert(s.aktif === 3 && Number(s.akumulasi) === 750000 + 2400000 + 100000 && Number(s.hutang_aset) === 4600000 && s.garansi_habis_30_hari.length === 1, JSON.stringify(s));
  await journalBalanced();
});
await check('mutasi & pelepasan: staf butuh approval, owner langsung; laba pelepasan dijurnal; tidak bisa batal penyusutan setelahnya', async () => {
  await db.exec(`reset role; insert into auth.users values ('${U11}', 'aset.staff@staff.santap.local')`);
  const role = await val(`insert into sys_roles (company_id, code, name, permissions) values ($1, 'aset_staff', 'Staf Aset', '["asset.manage"]') returning id`, [company1]);
  await db.query(`select sys_register_staff_user($1, $2, 'aset.staff', 'Staf Aset', $3, array[$4, $5]::uuid[], $6)`, [U11, company1, role, outletId, sc, U1]);
  await db.query(`update sys_approval_rules set is_enabled = true, min_amount = 0 where company_id = $1 and document_type in ('asset_transfer', 'asset_disposal')`, [company1]);
  await loginAs(U11);
  const t = await val(`select ast_request_transfer($1::jsonb)`, [JSON.stringify({ asset_id: astKompor, to_outlet_id: sc, to_location: 'Dapur pusat', reason: 'Pindah produksi' })]);
  assert(t.status === 'pending_approval' && t.approval_request_id, JSON.stringify(t));
  await expectError(`select ast_request_transfer($1::jsonb)`, [JSON.stringify({ asset_id: astKompor, to_outlet_id: sc })], /menunggu persetujuan/);
  await expectError(`select ast_run_depreciation($1)`, [await astMonth(0)], /semua outlet/);
  await loginAs(U1);
  await db.query(`select sys_decide_approval($1, true, 'ok')`, [t.approval_request_id]);
  const moved = await one(`select outlet_id, location from ast_assets where id = $1`, [astKompor]);
  assert(moved.outlet_id === sc && moved.location === 'Dapur pusat', JSON.stringify(moved));
  assert((await val(`select status from ast_transfers where id = $1`, [t.id])) === 'completed', 'mutasi belum selesai');
  await loginAs(U11);
  const x = await val(`select ast_request_disposal($1::jsonb)`, [JSON.stringify({ asset_id: astKompor, disposal_type: 'sold', proceeds: 10000000, cash_account_id: astCash, reason: 'Ganti model' })]);
  assert(x.status === 'pending_approval', JSON.stringify(x));
  await loginAs(U1);
  await db.query(`select sys_decide_approval($1, false, 'Masih dipakai')`, [x.approval_request_id]);
  assert((await val(`select status from ast_disposals where id = $1`, [x.id])) === 'rejected' && (await val(`select status from ast_assets where id = $1`, [astKompor])) === 'active', 'tolak');
  const d = await val(`select ast_request_disposal($1::jsonb)`, [JSON.stringify({ asset_id: astKompor, disposal_type: 'sold', proceeds: 11500000, cash_account_id: astCash, reason: 'Dijual ke cabang mitra' })]);
  assert(d.status === 'completed' && Number(d.book_value) === 11250000 && Number(d.gain_loss) === 250000, JSON.stringify(d));
  const gain = await val(`select l.credit::float8 from fin_journal_lines l join fin_journals j on j.id = l.journal_id join fin_accounts f on f.id = l.account_id
    where j.source_type = 'asset_disposal' and j.source_id = $1 and f.system_key = 'asset_disposal_gain'`, [d.id]);
  assert(gain === 250000, `laba ${gain}`);
  assert((await val(`select status from ast_assets where id = $1`, [astKompor])) === 'disposed', 'status aset');
  await expectError(`select ast_void_depreciation($1)`, [astPeriod], /dilepas/);
  await expectError(`select ast_request_transfer($1::jsonb)`, [JSON.stringify({ asset_id: astKompor, to_outlet_id: outletId })], /dilepas/);
  const det = await val(`select ast_asset_detail($1)`, [astKompor]);
  assert(det.events.some((e) => e.type === 'transferred') && det.events.some((e) => e.type === 'disposed') && det.schedule.length === 0, JSON.stringify(det.events));
  await journalBalanced();
});
await check('akses aset: kasir ditolak, user branch hanya melihat aset branch-nya, PT lain tidak melihat; scan kode', async () => {
  await loginAs(KASIR);
  await expectError(`select ast_list('all')`, [], /izin/);
  assert((await val(`select count(*)::int from ast_assets`)) === 0, 'kasir melihat tabel aset');
  const U13 = 'c7c7c7c7-c7c7-c7c7-c7c7-c7c7c7c7c7c7';
  await db.exec(`reset role; insert into auth.users values ('${U13}', 'aset.sc@staff.santap.local')`);
  const viewer = await val(`insert into sys_roles (company_id, code, name, permissions) values ($1, 'aset_viewer', 'Lihat Aset', '["asset.view"]') returning id`, [company1]);
  await db.query(`select sys_register_staff_user($1, $2, 'aset.sc', 'Aset SC', $3, array[$4]::uuid[], $5)`, [U13, company1, viewer, sc, U1]);
  await loginAs(U13);
  const seen = await val(`select ast_list('all')`);
  assert(seen.length >= 2 && seen.every((a) => a.outlet_id === sc), JSON.stringify(seen.map((a) => a.outlet)));
  const op = await val(`select ast_options()`);
  assert(op.outlets.length === 1 && op.can_manage === false && op.can_depreciate === false && op.categories.length === 6 && op.cash_accounts.some((x) => x.key === 'cash'), JSON.stringify(op).slice(0, 300));
  await expectError(`select ast_asset_detail($1)`, [astLaptop], /tidak ditemukan/);
  await expectError(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'X' })], /izin kelola/);
  await loginAs(U4b);
  assert((await val(`select jsonb_array_length(ast_list('all'))`)) === 0, 'PT lain melihat aset');
  await expectError(`select ast_asset_detail($1)`, [astLaptop], /tidak ditemukan/);
  await loginAs(U1);
  const code = await val(`select asset_number from ast_assets where id = $1`, [astLaptop]);
  assert((await val(`select ast_find_by_code($1)`, [code.toLowerCase()])) === astLaptop, 'scan kode');
  await expectError(`select ast_delete_asset($1)`, [astChiller], /tidak bisa dihapus/);
  await db.exec('reset role');
  assert((await val(`select count(*)::int from sys_approval_rules where company_id = $1 and document_type in ('asset_transfer', 'asset_disposal') and is_enabled`, [company4])) === 2, 'aturan approval default aktif');
});

console.log('\nAset tahap 2: perawatan, kerusakan, opname:');
let astAc, astRak, kasirOutlet, acPlan, acRepair, astAudit;
const msnCat = () => val(`select id from ast_categories where company_id = $1 and code = 'MSN'`, [company1]);
const frnCat = () => val(`select id from ast_categories where company_id = $1 and code = 'FRN'`, [company1]);
await check('perawatan: jadwal → tugas otomatis H-3 untuk kasir; selesai → riwayat & jadwal maju; biaya dijurnal', async () => {
  await db.exec('reset role');
  kasirOutlet = await val(`select outlet_id from sys_user_outlets where user_id = $1 limit 1`, [KASIR]) ?? outletId;
  await loginAs(U1);
  astAc = (await val(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'AC split 1 PK', category_id: await msnCat(), outlet_id: kasirOutlet,
    acquisition_date: await astMonth(-1), acquisition_cost: 3500000, funding: 'none', location: 'Ruang makan' })])).id;
  const due = await val(`select ((now() at time zone 'Asia/Jakarta')::date + 2)::text`);
  acPlan = await val(`select ast_save_plan($1::jsonb)`, [JSON.stringify({ asset_id: astAc, title: 'Service AC', interval_value: 3, interval_unit: 'month',
    next_due_date: due, lead_days: 3, assignee_user_id: KASIR, checklist: ['Cuci filter', 'Cek freon'], vendor: 'CV Sejuk' })]);
  assert(acPlan.open_task_id, 'tugas belum dibuat: ' + JSON.stringify(acPlan));
  const t = await one(`select assignee_id, due_date::text due, created_by, labels, link_url, jsonb_array_length(checklist) n from hr_tasks where id = $1`, [acPlan.open_task_id]);
  assert(t.assignee_id === KASIR && t.due === due && t.created_by === U1 && t.labels[0] === 'perawatan' && /^\/aset\/AST-MSN-/.test(t.link_url) && t.n === 2, JSON.stringify(t));
  assert((await val(`select ast_sync_maintenance()`)) === 0, 'tugas dobel');
  // centang checklist (di aplikasi lewat hr_task_save oleh penerima)
  await db.exec('reset role');
  await db.query(`update hr_tasks set checklist = (select jsonb_agg(c || '{"done": true}') from jsonb_array_elements(checklist) c) where id = $1`, [acPlan.open_task_id]);
  await loginAs(KASIR);
  await db.query(`select hr_task_move($1, 'in_progress')`, [acPlan.open_task_id]);
  await db.query(`select hr_task_move($1, 'review')`, [acPlan.open_task_id]);
  await loginAs(U1);
  await db.query(`select hr_task_move($1, 'done')`, [acPlan.open_task_id]);
  const pl = await one(`select open_task_id, next_due_date::text nd, last_done_on is not null done from ast_maintenance_plans where id = $1`, [acPlan.id]);
  const expectNext = await val(`select ($1::date + interval '3 months')::date::text`, [due]);
  assert(pl.open_task_id === null && pl.nd === expectNext && pl.done, JSON.stringify(pl));
  const log = await one(`select id, kind, performed_by from ast_maintenance_logs where plan_id = $1`, [acPlan.id]);
  assert(log.kind === 'scheduled' && log.performed_by === KASIR, JSON.stringify(log));
  const l = await val(`select ast_save_log($1::jsonb)`, [JSON.stringify({ id: log.id, cost: 350000, vendor: 'CV Sejuk', record_journal: true, paid_from_account_id: astCash })]);
  const dr = await val(`select l.debit::float8 from fin_journal_lines l join fin_accounts f on f.id = l.account_id where l.journal_id = $1 and f.system_key = 'maintenance_expense'`, [l.journal_id]);
  assert(dr === 350000, `jurnal biaya ${dr}`);
  // ubah biaya yang sudah dijurnal: jurnal lama diganti, tetap satu jurnal
  const l2 = await val(`select ast_save_log($1::jsonb)`, [JSON.stringify({ id: log.id, cost: 400000, vendor: 'CV Sejuk', record_journal: true, paid_from_account_id: astCash })]);
  assert((await val(`select count(*)::int from fin_journals where source_type = 'asset_maintenance' and source_id = $1`, [log.id])) === 1 && l2.journal_id !== l.journal_id, 'jurnal biaya dobel');
  assert((await val(`select total_amount::float8 from fin_journals where id = $1`, [l2.journal_id])) === 400000, 'nominal jurnal baru');
  const l3 = await val(`select ast_save_log($1::jsonb)`, [JSON.stringify({ id: log.id, cost: 350000, vendor: 'CV Sejuk', record_journal: false })]);
  assert(l3.journal_id === null && (await val(`select count(*)::int from fin_journals where source_type = 'asset_maintenance' and source_id = $1`, [log.id])) === 0, 'jurnal tidak terhapus');
  await db.query(`select ast_save_log($1::jsonb)`, [JSON.stringify({ id: log.id, cost: 350000, vendor: 'CV Sejuk', record_journal: true, paid_from_account_id: astCash })]);
  await journalBalanced();
});
await check('kerusakan: kasir lapor dari scan QR (tanpa angka keuangan) → tiket + tugas perbaikan; manajer tutup & biaya dijurnal', async () => {
  const code = await val(`select asset_number from ast_assets where id = $1`, [astAc]);
  await loginAs(KASIR);
  const info = await val(`select ast_scan_info($1)`, [code.toLowerCase()]);
  assert(info.id === astAc && info.can_view === false && !('acquisition_cost' in info) && info.next_maintenance?.title === 'Service AC', JSON.stringify(info));
  acRepair = await val(`select ast_report_damage($1::jsonb)`, [JSON.stringify({ asset_id: astAc, severity: 'down', description: 'AC mati, bocor air' })]);
  assert(acRepair.status === 'open' && acRepair.task_id && /^KRS\//.test(acRepair.repair_number), JSON.stringify(acRepair));
  await expectError(`select ast_report_damage($1::jsonb)`, [JSON.stringify({ asset_id: astAc, severity: 'down', description: 'lagi' })], /baru saja/);
  await expectError(`select ast_update_repair($1::jsonb)`, [JSON.stringify({ id: acRepair.id, status: 'done' })], /izin kelola/);
  // foto kerusakan boleh diunggah pelapor, foto aset tidak
  await db.query(`insert into storage.objects (bucket_id, name) values ('asset-files', $1)`, [`${company1}/${astAc}/repairs/a.webp`]);
  await expectError(`insert into storage.objects (bucket_id, name) values ('asset-files', $1)`, [`${company1}/${astAc}/b.webp`], /row-level security/);
  await loginAs(U1);
  assert((await val(`select priority from hr_tasks where id = $1`, [acRepair.task_id])) === 'urgent', 'prioritas');
  const r = await val(`select ast_update_repair($1::jsonb)`, [JSON.stringify({ id: acRepair.id, status: 'done', cost: 500000, vendor: 'CV Sejuk',
    resolution: 'Ganti kapasitor', record_journal: true, paid_from_account_id: astCash })]);
  assert(r.status === 'done' && r.journal_id && r.resolved_at, JSON.stringify(r));
  assert((await val(`select status from hr_tasks where id = $1`, [acRepair.task_id])) === 'done', 'tugas perbaikan belum selesai');
  const r2 = await val(`select ast_update_repair($1::jsonb)`, [JSON.stringify({ id: acRepair.id, status: 'done', cost: 500000, vendor: 'CV Sejuk', resolution: 'Ganti kapasitor', record_journal: true, paid_from_account_id: astCash })]);
  assert(r2.journal_id !== r.journal_id && (await val(`select count(*)::int from fin_journals where source_type = 'asset_repair' and source_id = $1`, [acRepair.id])) === 1, 'jurnal perbaikan dobel');
  const md = await val(`select ast_maintenance_detail($1)`, [astAc]);
  assert(Number(md.total_cost) === 850000 && md.repairs.length === 1 && md.logs.length === 1 && md.plans.length === 1, JSON.stringify(md).slice(0, 300));
  await expectError(`select ast_delete_asset($1)`, [astAc], /tidak bisa dihapus/);
  const ov = await val(`select ast_maintenance_overview()`);
  assert(ov.top_cost[0].asset_id === astAc && Number(ov.top_cost[0].total) === 850000, JSON.stringify(ov.top_cost));
  await journalBalanced();
});
await check('opname: scan ditemukan, salah lokasi, rusak → tiket; tutup → yang tidak ter-scan hilang', async () => {
  await loginAs(U1);
  astRak = (await val(`select ast_save_asset($1::jsonb)`, [JSON.stringify({ name: 'Rak stainless 4 susun', category_id: await frnCat(), outlet_id: sc,
    acquisition_date: await astMonth(-2), acquisition_cost: 2500000, funding: 'none' })])).id;
  astAudit = await val(`select ast_audit_start($1, 'Opname kuartal')`, [sc]);
  assert(Number(astAudit.items) === 2, JSON.stringify(astAudit));
  await expectError(`select ast_audit_start($1)`, [sc], /Masih ada opname/);
  await loginAs(KASIR);
  await expectError(`select ast_audit_scan($1, 'X')`, [astAudit.id], /izin opname/);
  await loginAs(U1);
  const laptop = await val(`select asset_number from ast_assets where id = $1`, [astLaptop]);
  const chiller = await val(`select asset_number from ast_assets where id = $1`, [astChiller]);
  const u = await val(`select ast_audit_scan($1, $2)`, [astAudit.id, laptop]);
  assert(u.result === 'unexpected' && u.expected === false, JSON.stringify(u));
  const f = await val(`select ast_audit_scan($1, $2, 'damaged', 'Dapur pusat', 'Pintu tidak rapat')`, [astAudit.id, chiller]);
  assert(f.result === 'found' && f.condition === 'damaged', JSON.stringify(f));
  assert((await val(`select count(*)::int from ast_repairs where asset_id = $1 and status = 'open'`, [astChiller])) === 1, 'tiket rusak dari opname');
  await expectError(`select ast_audit_scan($1, 'AST-XXX-9999')`, [astAudit.id], /tidak dikenal/);
  const closed = await val(`select ast_audit_close($1)`, [astAudit.id]);
  assert(closed.status === 'closed' && closed.summary.found === 1 && closed.summary.missing === 1 && closed.summary.unexpected === 1 && closed.summary.damaged === 1, JSON.stringify(closed.summary));
  assert(closed.items.find((i) => i.asset_id === astRak).result === 'missing', 'rak harus hilang');
  await expectError(`select ast_audit_scan($1, $2)`, [astAudit.id, chiller], /sudah ditutup/);
  const counts = await val(`select ast_maintenance_counts()`);
  assert(counts.kerusakan_terbuka >= 1 && counts.opname_terbuka === 0, JSON.stringify(counts));
});
await check('aset dilepas → jadwal perawatan nonaktif & tugas perawatan terbuka diarsipkan', async () => {
  await loginAs(U1);
  const today = await val(`select ((now() at time zone 'Asia/Jakarta')::date)::text`);
  const plan = await val(`select ast_save_plan($1::jsonb)`, [JSON.stringify({ asset_id: astRak, title: 'Cek baut rak', interval_value: 1, interval_unit: 'month', next_due_date: today })]);
  assert(plan.open_task_id, 'tugas rak belum dibuat');
  await db.query(`select ast_request_disposal($1::jsonb)`, [JSON.stringify({ asset_id: astRak, disposal_type: 'lost', reason: 'Hilang saat opname' })]);
  const p = await one(`select is_active, open_task_id from ast_maintenance_plans where id = $1`, [plan.id]);
  assert(p.is_active === false && p.open_task_id === null, JSON.stringify(p));
  assert((await val(`select status from hr_tasks where id = $1`, [plan.open_task_id])) === 'archived', 'tugas belum diarsipkan');
  const sk = (await db.query(`select kind from ast_maintenance_logs where plan_id = $1`, [plan.id])).rows[0]?.kind;
  assert(sk === undefined || sk === 'skipped', `log ${sk}`);
  await journalBalanced();
});

console.log('\nSemar AI x aset:');
await check('briefing harian berisi bagian aset (kerusakan terbuka, perawatan, garansi); PT lain kosong', async () => {
  await loginAs(U1);
  const b = await val(`select ai_business_brief(7)`);
  assert(b.penjualan && b.aset && b.aset.jumlah_aset >= 3, JSON.stringify(b.aset));
  assert(b.aset.kerusakan_terbuka.some((r) => /Chiller/.test(r.aset)), JSON.stringify(b.aset.kerusakan_terbuka));
  assert('perawatan_terlambat' in b.aset && 'garansi_habis_30_hari' in b.aset && 'perlu_disusutkan_sampai_bulan_lalu' in b.aset, 'kunci aset');
  await expectError(`select ai_business_brief_v1(7)`, [], /permission denied|izin/);
  await loginAs(U4b);
  const o = await val(`select ai_business_brief(7)`);
  assert(o.aset.jumlah_aset === 0, JSON.stringify(o.aset));
});
await check('ai_asset_insights: umur, % tersusut, biaya perawatan 12 bulan, jadwal; kasir ditolak', async () => {
  await loginAs(U1);
  const r = await val(`select ai_asset_insights()`);
  const ac = r.aset.find((a) => a.id === astAc);
  assert(ac && Number(ac.biaya_perawatan_12_bulan) === 850000 && ac.kerusakan_12_bulan === 1 && ac.jadwal_perawatan.length === 1 && 'persen_tersusut' in ac, JSON.stringify(ac));
  assert(r.ringkasan.aktif >= 3 && 'kerusakan_terbuka' in r.ringkasan && r.kerusakan_60_hari.length >= 2, JSON.stringify(r.ringkasan));
  assert(!r.aset.some((a) => a.id === astKompor), 'aset dilepas ikut');
  await loginAs(KASIR);
  await expectError(`select ai_asset_insights()`, [], /izin/);
});

console.log('\nModul perusahaan & panduan memulai:');
await check('perusahaan lama: semua modul aktif & tidak diminta wizard; profil membawa info modul', async () => {
  await loginAs(U1);
  const p = await val(`select sys_get_my_profile()`);
  assert(p.company_id === company1 && p.modules && p.modules.enabled === null && p.modules.setup_completed_at, JSON.stringify(p.modules));
  await expectError(`select sys_get_my_profile_base()`, [], /permission denied/);
});
await check('owner memilih modul: modul pendukung ikut aktif, wizard selesai; kunci asing & kasir ditolak', async () => {
  const U14 = 'd8d8d8d8-d8d8-d8d8-d8d8-d8d8d8d8d8d8';
  await db.exec(`reset role; insert into auth.users values ('${U14}', 'owner.baru@test.com')`);
  await loginAs(U14);
  await db.query(`select sys_onboard_company('Kedai Baru', 'Outlet Pertama', 'Rina', false)`);
  const before = await val(`select sys_get_my_profile()`);
  assert(before.modules.setup_completed_at === null, 'PT baru seharusnya belum selesai setup: ' + JSON.stringify(before.modules));
  const m = await val(`select sys_save_modules(array['purchasing', 'kds', 'ai'], 'resto', true)`);
  assert(JSON.stringify(m.enabled) === JSON.stringify(['ai', 'inventory', 'kds', 'pos', 'purchasing']) && m.business_type === 'resto' && m.setup_completed_at, JSON.stringify(m));
  await expectError(`select sys_save_modules(array['pos', 'judi'])`, [], /tidak dikenal/);
  await expectError(`select sys_save_modules(array['pos'], 'pabrik')`, [], /Tipe usaha/);
  assert((await val(`select sys_get_my_profile()`)).modules.enabled.includes('kds'), 'profil belum ikut berubah');
  const all = await val(`select sys_save_modules(null)`);
  assert(all.enabled === null && all.business_type === 'resto', JSON.stringify(all));
  await loginAs(KASIR);
  await expectError(`select sys_save_modules(array['pos'])`, [], /owner/);
});
await check('panduan memulai: langkah tercentang dari data; khusus owner; bisa disembunyikan', async () => {
  await loginAs(U1);
  const g = await val(`select sys_setup_progress()`);
  assert(g.menu === true && g.staff === true && g.first_order === true && g.asset === true && 'semar' in g, JSON.stringify(g));
  await db.query(`select sys_dismiss_setup_guide(false)`);
  assert((await val(`select sys_get_my_profile()`)).modules.guide_dismissed_at === null, 'panduan belum muncul lagi');
  await db.query(`select sys_dismiss_setup_guide(true)`);
  assert((await val(`select sys_get_my_profile()`)).modules.guide_dismissed_at, 'panduan belum tersembunyi');
  await loginAs(KASIR);
  await expectError(`select sys_setup_progress()`, [], /owner/);
});

console.log(`\n${passed} lulus, ${failed} gagal\n`);
process.exit(failed ? 1 : 0);
