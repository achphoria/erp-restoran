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
await runMigrations(allMigrations.filter((f) => f >= '010'));

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
  const U6 = '66666666-6666-6666-6666-666666666666';
  const company = await val(`select sys_current_company_id()`);
  const waiter = await val(`select id from sys_roles where code = 'waiter'`);
  await db.query(`insert into sys_user_invitations (company_id, email, role_id, outlet_ids) values ($1, 'pelayan@test.com', $2, array[$3::uuid])`, [company, waiter, outletId]);
  await db.exec(`reset role; insert into auth.users values ('${U6}', 'pelayan@test.com')`);
  await loginAs(U6);
  await db.query(`select sys_accept_invitation((select (sys_get_my_invitations()->0->>'id')::uuid), 'Rudi')`);
  await expectError(`select pos_refund_order($1, 'x')`, [splitOrder.id], /izin/);
});

console.log(`\n${passed} lulus, ${failed} gagal\n`);
process.exit(failed ? 1 : 0);
