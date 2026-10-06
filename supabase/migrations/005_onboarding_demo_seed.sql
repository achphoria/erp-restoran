-- =====================================================================
-- ERP RESTORAN - 005: ONBOARDING PERUSAHAAN BARU (+ DATA DEMO)
-- Dipanggil aplikasi setelah user pertama kali daftar:
--   supabase.rpc('sys_onboard_company', { p_company_name, p_outlet_name, p_full_name, p_with_demo_data })
-- =====================================================================

create or replace function sys_onboard_company(
  p_company_name   text,
  p_outlet_name    text,
  p_full_name      text,
  p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c          uuid;   -- company_id
  v_brand    uuid;
  v_outlet   uuid;
  v_wh       uuid;
  v_owner    uuid;
  v_area_in  uuid;
  v_area_out uuid;
begin
  if auth.uid() is null then raise exception 'Anda belum login'; end if;
  if exists (select 1 from sys_users where id = auth.uid()) then
    raise exception 'Akun ini sudah terdaftar di sebuah perusahaan';
  end if;
  if coalesce(trim(p_company_name), '') = '' or coalesce(trim(p_outlet_name), '') = '' then
    raise exception 'Nama perusahaan dan outlet wajib diisi';
  end if;

  -- ---------- perusahaan, brand, outlet, gudang ----------
  insert into sys_companies (code, name)
  values ('CMP-' || upper(substr(md5(gen_random_uuid()::text), 1, 8)), trim(p_company_name))
  returning id into c;

  insert into sys_brands (company_id, code, name) values (c, 'BR01', trim(p_company_name))
  returning id into v_brand;

  insert into sys_outlets (company_id, brand_id, code, name, tax_rate, service_charge_rate)
  values (c, v_brand, 'OUT01', trim(p_outlet_name), 10, 5)
  returning id into v_outlet;

  insert into inv_warehouses (company_id, outlet_id, code, name)
  values (c, v_outlet, 'WH-OUT01', 'Gudang ' || trim(p_outlet_name))
  returning id into v_wh;

  update sys_outlets set default_warehouse_id = v_wh where id = v_outlet;

  -- ---------- role & user ----------
  insert into sys_roles (company_id, code, name, permissions) values
    (c, 'owner',   'Owner',   '["*"]'),
    (c, 'manager', 'Manager', '["master.manage","pos.order","pos.pay","pos.discount","pos.void","kds.update","inventory.manage","purchasing.manage","report.view"]'),
    (c, 'cashier', 'Kasir',   '["pos.order","pos.pay","kds.update"]'),
    (c, 'waiter',  'Pelayan', '["pos.order","kds.update"]'),
    (c, 'kitchen', 'Dapur',   '["kds.update"]');

  select id into v_owner from sys_roles where company_id = c and code = 'owner';

  insert into sys_users (id, company_id, role_id, full_name)
  values (auth.uid(), c, v_owner, coalesce(nullif(trim(p_full_name), ''), 'Owner'));
  insert into sys_user_outlets (user_id, outlet_id) values (auth.uid(), v_outlet);

  -- ---------- metode bayar ----------
  insert into mst_payment_methods (company_id, code, name, type, sort_order) values
    (c, 'cash',  'Tunai',       'cash',    1),
    (c, 'qris',  'QRIS',        'ewallet', 2),
    (c, 'debit', 'Kartu Debit', 'card',    3),
    (c, 'credit','Kartu Kredit','card',    4);

  -- ---------- satuan dasar ----------
  insert into inv_units (company_id, code, name) values
    (c, 'g', 'Gram'), (c, 'kg', 'Kilogram'), (c, 'ml', 'Mililiter'),
    (c, 'l', 'Liter'), (c, 'pcs', 'Pcs'), (c, 'pack', 'Pack');

  if not p_with_demo_data then
    return jsonb_build_object('company_id', c, 'outlet_id', v_outlet);
  end if;

  -- =================== DATA DEMO ===================

  -- meja
  insert into mst_table_areas (company_id, outlet_id, name) values (c, v_outlet, 'Indoor')  returning id into v_area_in;
  insert into mst_table_areas (company_id, outlet_id, name) values (c, v_outlet, 'Outdoor') returning id into v_area_out;
  insert into mst_tables (company_id, outlet_id, table_area_id, code, capacity)
  select c, v_outlet, v_area_in, 'A' || n, 4 from generate_series(1, 6) n
  union all
  select c, v_outlet, v_area_out, 'B' || n, 2 from generate_series(1, 4) n;

  -- kategori & menu
  insert into mst_menu_categories (company_id, brand_id, name, sort_order) values
    (c, v_brand, 'Makanan', 1), (c, v_brand, 'Minuman', 2), (c, v_brand, 'Snack', 3);

  insert into mst_menu_items (company_id, brand_id, menu_category_id, code, name, base_price, station)
  select c, v_brand, mc.id, m.code, m.name, m.price, m.station
  from (values
    ('Makanan', 'MKN01', 'Nasi Goreng Spesial',    35000, 'kitchen'),
    ('Makanan', 'MKN02', 'Mie Goreng Jawa',        32000, 'kitchen'),
    ('Makanan', 'MKN03', 'Ayam Bakar Madu',        45000, 'kitchen'),
    ('Makanan', 'MKN04', 'Soto Ayam',              28000, 'kitchen'),
    ('Minuman', 'MNM01', 'Es Teh Manis',            8000, 'bar'),
    ('Minuman', 'MNM02', 'Es Jeruk',               12000, 'bar'),
    ('Minuman', 'MNM03', 'Kopi Susu Gula Aren',    22000, 'bar'),
    ('Snack',   'SNK01', 'Kentang Goreng',         20000, 'kitchen'),
    ('Snack',   'SNK02', 'Pisang Goreng Keju',     18000, 'kitchen')
  ) as m(category, code, name, price, station)
  join mst_menu_categories mc on mc.company_id = c and mc.name = m.category;

  -- harga khusus ojol (+20%)
  insert into mst_menu_prices (company_id, menu_item_id, sales_channel, price)
  select c, id, ch, round(base_price * 1.2 / 500) * 500
  from mst_menu_items, unnest(array['gofood', 'grabfood']) ch
  where company_id = c;

  -- modifier
  insert into mst_modifier_groups (company_id, name, min_select, max_select) values
    (c, 'Level Pedas', 0, 1), (c, 'Extra Topping', 0, 3);

  insert into mst_modifiers (company_id, modifier_group_id, name, extra_price, sort_order)
  select c, g.id, m.name, m.price, m.sort
  from (values
    ('Level Pedas',   'Tidak Pedas', 0,    1),
    ('Level Pedas',   'Sedang',      0,    2),
    ('Level Pedas',   'Pedas',       0,    3),
    ('Extra Topping', 'Telur',       5000, 1),
    ('Extra Topping', 'Keju',        6000, 2),
    ('Extra Topping', 'Kerupuk',     3000, 3)
  ) as m(grp, name, price, sort)
  join mst_modifier_groups g on g.company_id = c and g.name = m.grp;

  insert into mst_menu_item_modifier_groups (company_id, menu_item_id, modifier_group_id)
  select c, mi.id, g.id
  from mst_menu_items mi, mst_modifier_groups g
  where mi.company_id = c and g.company_id = c
    and mi.code in ('MKN01', 'MKN02', 'MKN04');

  -- bahan baku (harga per base unit)
  insert into inv_item_categories (company_id, name) values
    (c, 'Bahan Pokok'), (c, 'Protein'), (c, 'Sayur & Buah'), (c, 'Bumbu'), (c, 'Minuman');

  insert into inv_items (company_id, item_category_id, code, name, base_unit_id, min_stock, last_purchase_cost)
  select c, ic.id, b.code, b.name, u.id, b.min_stock, b.cost
  from (values
    ('Bahan Pokok',  'BHN01', 'Beras',            'g',   5000,  14),
    ('Bahan Pokok',  'BHN02', 'Mie Telur',        'g',   2000,  30),
    ('Bahan Pokok',  'BHN03', 'Minyak Goreng',    'ml',  3000,  18),
    ('Bahan Pokok',  'BHN04', 'Gula Pasir',       'g',   2000,  17),
    ('Protein',      'BHN05', 'Daging Ayam',      'g',   3000,  40),
    ('Protein',      'BHN06', 'Telur Ayam',       'pcs',   30, 2000),
    ('Protein',      'BHN07', 'Keju Cheddar',     'g',    500, 120),
    ('Sayur & Buah', 'BHN08', 'Kentang',          'g',   3000,  20),
    ('Sayur & Buah', 'BHN09', 'Pisang Kepok',     'pcs',   20, 1500),
    ('Sayur & Buah', 'BHN10', 'Jeruk Peras',      'pcs',   30, 1200),
    ('Bumbu',        'BHN11', 'Bawang Merah',     'g',   1000,  45),
    ('Bumbu',        'BHN12', 'Kecap Manis',      'ml',  1000,  30),
    ('Bumbu',        'BHN13', 'Madu',             'ml',   500, 120),
    ('Minuman',      'BHN14', 'Teh Celup',        'pcs',   50,  250),
    ('Minuman',      'BHN15', 'Biji Kopi',        'g',    500, 200),
    ('Minuman',      'BHN16', 'Susu Segar',       'ml',  2000,  22),
    ('Minuman',      'BHN17', 'Gula Aren Cair',   'ml',   500,  50)
  ) as b(category, code, name, unit, min_stock, cost)
  join inv_item_categories ic on ic.company_id = c and ic.name = b.category
  join inv_units u on u.company_id = c and u.code = b.unit;

  -- konversi satuan beli: kg -> g, l -> ml
  insert into inv_item_units (company_id, item_id, unit_id, conversion_qty)
  select c, it.id, u.id, 1000
  from inv_items it
  join inv_units bu on bu.id = it.base_unit_id
  join inv_units u  on u.company_id = c and u.code = case bu.code when 'g' then 'kg' when 'ml' then 'l' end
  where it.company_id = c;

  -- resep per porsi
  insert into inv_recipes (company_id, menu_item_id)
  select c, id from mst_menu_items where company_id = c;

  insert into inv_recipe_items (company_id, recipe_id, item_id, quantity)
  select c, r.id, it.id, x.qty
  from (values
    ('MKN01', 'BHN01', 200), ('MKN01', 'BHN05',  80), ('MKN01', 'BHN06', 1), ('MKN01', 'BHN03', 20), ('MKN01', 'BHN11', 15), ('MKN01', 'BHN12', 15),
    ('MKN02', 'BHN02', 150), ('MKN02', 'BHN05',  50), ('MKN02', 'BHN06', 1), ('MKN02', 'BHN03', 20), ('MKN02', 'BHN12', 20),
    ('MKN03', 'BHN05', 250), ('MKN03', 'BHN13',  20), ('MKN03', 'BHN12', 15), ('MKN03', 'BHN01', 150),
    ('MKN04', 'BHN05', 100), ('MKN04', 'BHN01', 150), ('MKN04', 'BHN06', 1), ('MKN04', 'BHN11', 10),
    ('MNM01', 'BHN14',   1), ('MNM01', 'BHN04',  25),
    ('MNM02', 'BHN10',   2), ('MNM02', 'BHN04',  20),
    ('MNM03', 'BHN15',  18), ('MNM03', 'BHN16', 150), ('MNM03', 'BHN17', 25),
    ('SNK01', 'BHN08', 200), ('SNK01', 'BHN03',  50),
    ('SNK02', 'BHN09',   2), ('SNK02', 'BHN07',  20), ('SNK02', 'BHN03', 40)
  ) as x(menu_code, item_code, qty)
  join mst_menu_items mi on mi.company_id = c and mi.code = x.menu_code
  join inv_recipes r     on r.menu_item_id = mi.id
  join inv_items it      on it.company_id = c and it.code = x.item_code;

  -- stok awal (= 4x stok minimum)
  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    unit_cost, reference_number, note, created_by)
  select c, v_wh, id, 'adjustment', min_stock * 4, last_purchase_cost, 'STOK-AWAL', 'Stok awal demo', auth.uid()
  from inv_items where company_id = c;

  -- supplier
  insert into pur_suppliers (company_id, code, name, contact_name, phone, payment_term_days) values
    (c, 'SUP01', 'Pasar Induk Segar',   'Pak Joko', '081200000001', 0),
    (c, 'SUP02', 'Toko Sembako Makmur', 'Bu Sari',  '081200000002', 14),
    (c, 'SUP03', 'Kopi Nusantara',      'Mas Dimas','081200000003', 30);

  return jsonb_build_object('company_id', c, 'outlet_id', v_outlet);
end $$;
