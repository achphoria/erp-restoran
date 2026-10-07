-- =====================================================================
-- SANTAP ERP - DATA CONTOH BOM & PRODUKSI (lewat SQL Editor)
-- Membuat (aman dijalankan ulang, data yang sudah ada dilewati):
--   * Bahan baku DMP01-DMP06 + stok awal lewat Penerimaan Barang (ada batch & jurnal)
--   * Produk setengah jadi DMP11-DMP14
--   * BOM ASSEMBLY  "BOM-SAMBAL" : cabai, bawang, garam, minyak -> Sambal Bawang 1 kg
--                                  (+ waste 5% cabai, biaya gas & tenaga masak)
--   * BOM DISASSEMBLY "BOM-AYAM" : 1 Ayam Utuh -> Dada, Paha, Tulang & Ceker (nilai dibagi per bobot)
-- Setelah itu coba di aplikasi: Persediaan -> Produksi -> + Produksi.
-- Cara pakai: ganti EMAIL_OWNER_ANDA, lalu Run. Opsional: ganti KATA_NAMA_OUTLET dengan sebagian nama OUTLET
--   (mis. 'pluit'); bila tidak cocok, dipakai outlet pertama yang punya gudang POS.
-- =====================================================================

-- 1) jalankan sebagai owner
select set_config('request.jwt.claim.sub', id::text, false),
       set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, false)
from auth.users where email = 'EMAIL_OWNER_ANDA';

-- 2) data contoh
do $$
declare
  c        uuid := sys_current_company_id();
  v_outlet uuid;
  v_wh     uuid;
  v_sup    uuid;
  v_gr     uuid;
  v_rec    uuid;
begin
  if c is null or not sys_has_permission('*') then raise exception 'Jalankan sebagai owner (cek email di langkah 1)'; end if;
  -- outlet yang namanya cocok; kalau tidak ada, outlet pertama yang punya gudang POS
  select id, default_warehouse_id into v_outlet, v_wh from sys_outlets
  where company_id = c and default_warehouse_id is not null
  order by (name ilike '%KATA_NAMA_OUTLET%') desc, created_at limit 1;
  if v_wh is null then raise exception 'Belum ada outlet yang punya gudang POS (atur di Persediaan -> Gudang & Lokasi)'; end if;
  raise notice 'Dipakai outlet: %', (select name from sys_outlets where id = v_outlet);

  -- produk: bahan baku & setengah jadi
  insert into inv_items (company_id, item_category_id, code, name, item_type, base_unit_id, last_purchase_cost, min_stock, is_purchasable)
  select c, (select id from inv_item_categories where company_id = c and name = x.cat limit 1), x.code, x.name, x.type,
         (select id from inv_units where company_id = c and code = x.unit), x.cost, x.min, x.type = 'raw'
  from (values
    ('DMP01', 'Cabai Merah Keriting', 'raw',           'g',   'Sayur & Buah',    60, 1000),
    ('DMP02', 'Bawang Merah',         'raw',           'g',   'Bumbu',           40, 1000),
    ('DMP03', 'Bawang Putih',         'raw',           'g',   'Bumbu',           35,  500),
    ('DMP04', 'Garam',                'raw',           'g',   'Bumbu',           10,  500),
    ('DMP05', 'Minyak Goreng (Demo)', 'raw',           'ml',  'Bahan Pokok',     18, 1000),
    ('DMP06', 'Ayam Utuh',            'raw',           'pcs', 'Protein',      38000,    4),
    ('DMP11', 'Sambal Bawang',        'semi_finished', 'g',   'Bumbu',            0,  500),
    ('DMP12', 'Dada Ayam Fillet',     'semi_finished', 'g',   'Protein',          0, 1000),
    ('DMP13', 'Paha Ayam',            'semi_finished', 'g',   'Protein',          0, 1000),
    ('DMP14', 'Tulang & Ceker Ayam',  'semi_finished', 'g',   'Protein',          0,    0)
  ) as x(code, name, type, unit, cat, cost, min)
  on conflict (company_id, code) do nothing;

  -- BOM assembly: Sambal Bawang 1 kg
  if not exists (select 1 from inv_recipes where company_id = c and code = 'BOM-SAMBAL') then
    insert into inv_recipes (company_id, item_id, recipe_type, code, name, yield_qty, note)
    values (c, (select id from inv_items where company_id = c and code = 'DMP11'), 'assembly', 'BOM-SAMBAL', 'Sambal Bawang 1 kg', 1000,
            'Contoh assembly: banyak bahan -> 1 hasil')
    returning id into v_rec;
    insert into inv_recipe_items (company_id, recipe_id, item_id, quantity, waste_pct)
    select c, v_rec, (select id from inv_items where company_id = c and code = x.code), x.qty, x.waste
    from (values ('DMP01', 600, 5), ('DMP02', 250, 0), ('DMP03', 80, 0), ('DMP04', 20, 0), ('DMP05', 150, 0)) as x(code, qty, waste);
    insert into inv_recipe_costs (company_id, recipe_id, description, account_id, amount)
    select c, v_rec, x.descr, a.id, x.amount
    from (values ('Gas masak', '6-1300', 3000), ('Tenaga masak', '6-1100', 5000)) as x(descr, code, amount)
    join fin_accounts a on a.company_id = c and a.code = x.code;
  end if;

  -- BOM disassembly: 1 Ayam Utuh -> potongan
  if not exists (select 1 from inv_recipes where company_id = c and code = 'BOM-AYAM') then
    insert into inv_recipes (company_id, item_id, recipe_type, code, name, yield_qty, note)
    values (c, (select id from inv_items where company_id = c and code = 'DMP06'), 'disassembly', 'BOM-AYAM', 'Potong Ayam Utuh', 1,
            'Contoh disassembly: 1 bahan -> beberapa hasil, nilai dibagi sesuai bobot')
    returning id into v_rec;
    insert into inv_recipe_items (company_id, recipe_id, item_id, quantity, weight_factor)
    select c, v_rec, (select id from inv_items where company_id = c and code = x.code), x.qty, x.wf
    from (values ('DMP12', 450, 2.0), ('DMP13', 500, 1.5), ('DMP14', 250, 0.3)) as x(code, qty, wf);
  end if;

  -- stok bahan baku lewat penerimaan barang (sekali saja)
  if not exists (select 1 from pur_goods_receipts where company_id = c and supplier_invoice_number = 'INV-DEMO-BOM') then
    select id into v_sup from pur_suppliers where company_id = c and supplier_type = 'external' and is_active order by code limit 1;
    if v_sup is null then
      insert into pur_suppliers (company_id, code, name, payment_term_days) values (c, 'DEMO-SUP', 'CV Demo Pangan Segar', 14) returning id into v_sup;
    end if;
    insert into pur_goods_receipts (company_id, supplier_id, warehouse_id, supplier_invoice_number, note)
    values (c, v_sup, v_wh, 'INV-DEMO-BOM', 'Stok contoh untuk trial produksi') returning id into v_gr;
    insert into pur_goods_receipt_items (company_id, goods_receipt_id, item_id, unit_id, conversion_qty, quantity, unit_price)
    select c, v_gr, it.id, it.base_unit_id, 1, x.qty, it.last_purchase_cost
    from (values ('DMP01', 5000), ('DMP02', 3000), ('DMP03', 1000), ('DMP04', 2000), ('DMP05', 3000), ('DMP06', 12)) as x(code, qty)
    join inv_items it on it.company_id = c and it.code = x.code;
    perform pur_post_goods_receipt(v_gr);
  end if;

  raise notice 'Selesai. Coba: Persediaan -> Produksi -> + Produksi -> pilih "Sambal Bawang 1 kg" atau "Potong Ayam Utuh".';
end $$;

-- 3) cek hasil
select r.code, r.name, r.recipe_type, it.name as produk, r.yield_qty,
       (select count(*) from inv_recipe_items ri where ri.recipe_id = r.id) as jumlah_bahan
from inv_recipes r join inv_items it on it.id = r.item_id
where r.company_id = sys_current_company_id() and r.code in ('BOM-SAMBAL', 'BOM-AYAM');
