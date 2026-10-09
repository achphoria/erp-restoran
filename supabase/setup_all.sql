-- =====================================================================
-- SANTAP ERP - SETUP LENGKAP (gabungan migrations/001 s/d 043)
-- Untuk database BARU. Jalankan SEKALI di Supabase SQL Editor.
-- =====================================================================

-- >>>>>>>>>> migrations/001_phase1_master_pos.sql
-- =====================================================================
-- ERP RESTORAN - 001: MASTER DATA + POS (TABEL)
--
-- KONVENSI PENAMAAN
--   * Tabel   : snake_case, jamak, berprefix modul
--               sys_ = sistem/pengaturan     mst_ = master data
--               pos_ = kasir/penjualan       inv_ = inventory
--               pur_ = purchasing            fin_ = finance (fase 3)
--               crm_ = pelanggan (fase 4)    hr_  = SDM (fase 5)
--               rpt_ = view laporan
--   * Kolom   : snake_case, tunggal
--   * PK      : id (uuid)
--   * FK      : <tabel_tunggal>_id  -> outlet_id, menu_item_id
--   * Boolean : is_ / has_            -> is_active
--   * Waktu   : *_at (timestamptz)    -> created_at, paid_at
--   * Tanggal : *_date (date)         -> business_date
--   * Uang    : numeric(15,2)
--   * Detail dokumen : <dokumen>_items -> pos_order_items
--   * Fungsi  : <prefix>_<kata_kerja>_<objek> -> pos_pay_order
-- =====================================================================

create or replace function sys_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- =====================================================================
-- SYS: PERUSAHAAN, BRAND, OUTLET, ROLE, USER
-- =====================================================================
create table sys_companies (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  tax_number  text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table sys_brands (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text not null,
  name        text not null,
  logo_url    text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);

create table sys_outlets (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  brand_id             uuid not null references sys_brands(id),
  code                 text not null,
  name                 text not null,
  address              text,
  phone                text,
  timezone             text not null default 'Asia/Jakarta',
  tax_rate             numeric(5,2) not null default 10,   -- PB1 %
  service_charge_rate  numeric(5,2) not null default 0,    -- %
  rounding_unit        int not null default 100,           -- pembulatan Rp
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, code)
);

create table sys_roles (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text not null,            -- owner, manager, cashier, kitchen
  name        text not null,
  permissions jsonb not null default '[]',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);

create table sys_users (
  id          uuid primary key references auth.users(id) on delete cascade,
  company_id  uuid not null references sys_companies(id),
  role_id     uuid not null references sys_roles(id),
  full_name   text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table sys_user_outlets (
  user_id     uuid not null references sys_users(id) on delete cascade,
  outlet_id   uuid not null references sys_outlets(id) on delete cascade,
  primary key (user_id, outlet_id)
);

-- Penomoran dokumen otomatis (INV/OUT01/20261006/0001, PO/..., dst)
create table sys_document_sequences (
  company_id   uuid not null references sys_companies(id),
  sequence_key text not null,
  last_number  int not null default 0,
  primary key (company_id, sequence_key)
);

-- =====================================================================
-- MST: MENU, MODIFIER, PEMBAYARAN, MEJA
-- =====================================================================
create table mst_menu_categories (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  brand_id    uuid not null references sys_brands(id),
  name        text not null,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table mst_menu_items (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  brand_id          uuid not null references sys_brands(id),
  menu_category_id  uuid not null references mst_menu_categories(id),
  code              text not null,
  name              text not null,
  description       text,
  image_url         text,
  base_price        numeric(15,2) not null default 0,
  station           text not null default 'kitchen',  -- kitchen / bar / pastry
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, code)
);

-- Harga khusus per outlet / kanal (dine_in, takeaway, gofood, grabfood)
create table mst_menu_prices (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  menu_item_id  uuid not null references mst_menu_items(id) on delete cascade,
  outlet_id     uuid references sys_outlets(id),      -- null = semua outlet
  sales_channel text not null default 'dine_in',
  price         numeric(15,2) not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique nulls not distinct (menu_item_id, outlet_id, sales_channel)
);

create table mst_modifier_groups (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  name        text not null,            -- "Level Pedas", "Extra Topping"
  min_select  int not null default 0,
  max_select  int not null default 1,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table mst_modifiers (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  modifier_group_id  uuid not null references mst_modifier_groups(id) on delete cascade,
  name               text not null,
  extra_price        numeric(15,2) not null default 0,
  sort_order         int not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table mst_menu_item_modifier_groups (
  menu_item_id       uuid not null references mst_menu_items(id) on delete cascade,
  modifier_group_id  uuid not null references mst_modifier_groups(id) on delete cascade,
  company_id         uuid not null references sys_companies(id),
  primary key (menu_item_id, modifier_group_id)
);

create table mst_payment_methods (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text not null,            -- cash, qris, debit, gopay
  name        text not null,
  type        text not null default 'cash',  -- cash / card / ewallet / other
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);

create table mst_table_areas (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  outlet_id   uuid not null references sys_outlets(id),
  name        text not null,            -- Indoor, Outdoor, Lantai 2
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table mst_tables (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid not null references sys_outlets(id),
  table_area_id  uuid references mst_table_areas(id),
  code           text not null,         -- A1, A2
  capacity       int not null default 4,
  status         text not null default 'available', -- available / occupied
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (outlet_id, code)
);

-- =====================================================================
-- POS: SHIFT, ORDER, ITEM, PEMBAYARAN
-- =====================================================================
create table pos_shifts (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  outlet_id       uuid not null references sys_outlets(id),
  user_id         uuid not null references sys_users(id),
  business_date   date not null,
  opening_cash    numeric(15,2) not null default 0,
  closing_cash    numeric(15,2),
  expected_cash   numeric(15,2),
  opened_at       timestamptz not null default now(),
  closed_at       timestamptz,
  status          text not null default 'open',   -- open / closed
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table pos_orders (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  outlet_id        uuid not null references sys_outlets(id),
  shift_id         uuid references pos_shifts(id),
  table_id         uuid references mst_tables(id),
  order_number     text not null,
  business_date    date not null,
  sales_channel    text not null default 'dine_in',
  customer_name    text,
  guest_count      int not null default 1,
  status           text not null default 'open', -- open / paid / void
  subtotal         numeric(15,2) not null default 0,
  discount_amount  numeric(15,2) not null default 0,
  service_amount   numeric(15,2) not null default 0,
  tax_amount       numeric(15,2) not null default 0,
  rounding_amount  numeric(15,2) not null default 0,
  grand_total      numeric(15,2) not null default 0,
  note             text,
  created_by       uuid references sys_users(id),
  paid_at          timestamptz,
  voided_at        timestamptz,
  void_reason      text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (outlet_id, order_number)
);

create table pos_order_items (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  order_id         uuid not null references pos_orders(id) on delete cascade,
  menu_item_id     uuid not null references mst_menu_items(id),
  menu_item_name   text not null,          -- snapshot nama saat dijual
  station          text not null default 'kitchen',
  quantity         numeric(10,2) not null default 1,
  unit_price       numeric(15,2) not null,
  modifier_amount  numeric(15,2) not null default 0,
  discount_amount  numeric(15,2) not null default 0,
  line_total       numeric(15,2) not null,
  note             text,
  kitchen_status   text not null default 'pending', -- pending / cooking / ready / served
  is_void          boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table pos_order_item_modifiers (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  order_item_id   uuid not null references pos_order_items(id) on delete cascade,
  modifier_id     uuid references mst_modifiers(id),
  modifier_name   text not null,           -- snapshot
  extra_price     numeric(15,2) not null default 0,
  created_at      timestamptz not null default now()
);

create table pos_payments (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  order_id           uuid not null references pos_orders(id) on delete cascade,
  payment_method_id  uuid not null references mst_payment_methods(id),
  amount             numeric(15,2) not null,
  change_amount      numeric(15,2) not null default 0,
  reference_number   text,
  paid_at            timestamptz not null default now(),
  created_at         timestamptz not null default now()
);

-- =====================================================================
-- INDEX
-- =====================================================================
create index idx_mst_menu_items_category  on mst_menu_items(menu_category_id);
create index idx_pos_orders_outlet_date   on pos_orders(outlet_id, business_date);
create index idx_pos_orders_status        on pos_orders(status);
create index idx_pos_order_items_order    on pos_order_items(order_id);
create index idx_pos_order_items_kitchen  on pos_order_items(kitchen_status);
create index idx_pos_payments_order       on pos_payments(order_id);

-- =====================================================================
-- TRIGGER updated_at (otomatis untuk semua tabel yang punya kolomnya)
-- =====================================================================
create or replace function sys_attach_updated_at_triggers()
returns void language plpgsql as $$
declare t text;
begin
  for t in
    select c.table_name from information_schema.columns c
    where c.table_schema = 'public' and c.column_name = 'updated_at'
      and not exists (
        select 1 from information_schema.triggers tr
        where tr.event_object_table = c.table_name
          and tr.trigger_name = 'trg_' || c.table_name || '_updated_at')
  loop
    execute format(
      'create trigger %I before update on %I
       for each row execute function sys_set_updated_at()',
      'trg_' || t || '_updated_at', t);
  end loop;
end $$;

select sys_attach_updated_at_triggers();

-- =====================================================================
-- HAK AKSES & ROW LEVEL SECURITY
--   Daftar permission:
--     *                 semua akses (owner)
--     settings.manage   perusahaan, brand, outlet
--     user.manage       user & role
--     master.manage     menu, harga, modifier, meja, metode bayar
--     pos.order         membuat order
--     pos.pay           menerima pembayaran
--     pos.discount      memberi diskon
--     pos.void          membatalkan order / item
--     kds.update        mengubah status masak
--     inventory.manage  bahan baku, resep, stok
--     purchasing.manage supplier, PO, penerimaan barang
--     report.view       melihat laporan
-- =====================================================================
create or replace function sys_current_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select company_id from sys_users where id = auth.uid() and is_active
$$;

create or replace function sys_has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select r.permissions ? '*' or r.permissions ? p_permission
    from sys_users u join sys_roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active
  ), false)
$$;

create or replace function sys_can_access_outlet(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('*') and exists (
           select 1 from sys_outlets
           where id = p_outlet_id and company_id = sys_current_company_id())
      or exists (
           select 1 from sys_user_outlets
           where user_id = auth.uid() and outlet_id = p_outlet_id)
$$;

-- Pasang policy standar: baca = satu company, tulis = butuh permission
create or replace function sys_apply_company_policies(p_table text, p_write_permission text default null)
returns void language plpgsql as $$
begin
  execute format('alter table %I enable row level security', p_table);
  execute format(
    'create policy %I on %I for select to authenticated
     using (company_id = sys_current_company_id())',
    p_table || '_select', p_table);
  if p_write_permission is not null then
    execute format(
      'create policy %I on %I for insert to authenticated
       with check (company_id = sys_current_company_id() and sys_has_permission(%L))',
      p_table || '_insert', p_table, p_write_permission);
    execute format(
      'create policy %I on %I for update to authenticated
       using (company_id = sys_current_company_id() and sys_has_permission(%L))
       with check (company_id = sys_current_company_id())',
      p_table || '_update', p_table, p_write_permission);
    execute format(
      'create policy %I on %I for delete to authenticated
       using (company_id = sys_current_company_id() and sys_has_permission(%L))',
      p_table || '_delete', p_table, p_write_permission);
  end if;
end $$;

-- SYS
alter table sys_companies enable row level security;
create policy sys_companies_select on sys_companies for select to authenticated
  using (id = sys_current_company_id());
create policy sys_companies_update on sys_companies for update to authenticated
  using (id = sys_current_company_id() and sys_has_permission('settings.manage'));

select sys_apply_company_policies('sys_brands', 'settings.manage');
select sys_apply_company_policies('sys_outlets', 'settings.manage');
select sys_apply_company_policies('sys_roles', 'user.manage');
select sys_apply_company_policies('sys_users', 'user.manage');
select sys_apply_company_policies('sys_document_sequences');  -- hanya lewat fungsi

alter table sys_user_outlets enable row level security;
create policy sys_user_outlets_select on sys_user_outlets for select to authenticated
  using (user_id in (select id from sys_users where company_id = sys_current_company_id()));
create policy sys_user_outlets_write on sys_user_outlets for all to authenticated
  using (sys_has_permission('user.manage')
         and user_id in (select id from sys_users where company_id = sys_current_company_id()))
  with check (sys_has_permission('user.manage')
         and user_id in (select id from sys_users where company_id = sys_current_company_id()));

-- MST
select sys_apply_company_policies('mst_menu_categories', 'master.manage');
select sys_apply_company_policies('mst_menu_items', 'master.manage');
select sys_apply_company_policies('mst_menu_prices', 'master.manage');
select sys_apply_company_policies('mst_modifier_groups', 'master.manage');
select sys_apply_company_policies('mst_modifiers', 'master.manage');
select sys_apply_company_policies('mst_menu_item_modifier_groups', 'master.manage');
select sys_apply_company_policies('mst_payment_methods', 'master.manage');
select sys_apply_company_policies('mst_table_areas', 'master.manage');
select sys_apply_company_policies('mst_tables', 'master.manage');

-- POS: hanya baca. Semua perubahan lewat fungsi pos_* (supaya total tidak bisa dimanipulasi)
select sys_apply_company_policies('pos_shifts');
select sys_apply_company_policies('pos_orders');
select sys_apply_company_policies('pos_order_items');
select sys_apply_company_policies('pos_order_item_modifiers');
select sys_apply_company_policies('pos_payments');

-- Pengecualian: dapur boleh mengubah kitchen_status saja
create policy pos_order_items_kitchen_update on pos_order_items for update to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('kds.update'))
  with check (company_id = sys_current_company_id());
revoke update on pos_order_items from authenticated, anon;
grant update (kitchen_status) on pos_order_items to authenticated;

-- Realtime untuk Kitchen Display & daftar order
alter publication supabase_realtime add table pos_order_items;
alter publication supabase_realtime add table pos_orders;

-- >>>>>>>>>> migrations/002_phase2_inventory_purchasing.sql
-- =====================================================================
-- ERP RESTORAN - 002: INVENTORY, RESEP, PURCHASING (TABEL)
-- =====================================================================

-- =====================================================================
-- INV: SATUAN, BAHAN BAKU, GUDANG
-- =====================================================================
create table inv_units (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text not null,            -- g, kg, ml, l, pcs, pack
  name        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);

create table inv_item_categories (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  name        text not null,            -- Daging, Sayur, Bumbu, Minuman
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table inv_items (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references sys_companies(id),
  item_category_id      uuid references inv_item_categories(id),
  code                  text not null,
  name                  text not null,
  item_type             text not null default 'raw',  -- raw / semi_finished
  base_unit_id          uuid not null references inv_units(id),  -- satuan stok
  min_stock             numeric(15,4) not null default 0,
  last_purchase_cost    numeric(15,4) not null default 0,       -- per base unit
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, code)
);

-- Konversi satuan beli: 1 <unit> = conversion_qty <base_unit>
--   contoh: 1 kg = 1000 g, 1 dus = 24 pcs
create table inv_item_units (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  item_id         uuid not null references inv_items(id) on delete cascade,
  unit_id         uuid not null references inv_units(id),
  conversion_qty  numeric(15,4) not null check (conversion_qty > 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (item_id, unit_id)
);

create table inv_warehouses (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  outlet_id   uuid references sys_outlets(id),   -- null = gudang pusat / central kitchen
  code        text not null,
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);

-- Gudang yang dipotong stoknya saat outlet berjualan
alter table sys_outlets add column default_warehouse_id uuid references inv_warehouses(id);

-- =====================================================================
-- INV: STOK & KARTU STOK
-- =====================================================================
create table inv_stocks (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  warehouse_id  uuid not null references inv_warehouses(id),
  item_id       uuid not null references inv_items(id),
  quantity      numeric(15,4) not null default 0,      -- dalam base unit
  average_cost  numeric(15,4) not null default 0,      -- per base unit
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (warehouse_id, item_id)
);

-- Kartu stok: setiap perubahan stok WAJIB lewat tabel ini
create table inv_stock_movements (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  warehouse_id    uuid not null references inv_warehouses(id),
  item_id         uuid not null references inv_items(id),
  movement_type   text not null,
    -- purchase_receipt / sales / adjustment / waste / opname
    -- transfer_in / transfer_out / production_in / production_out
  quantity        numeric(15,4) not null,   -- + masuk, - keluar (base unit)
  unit_cost       numeric(15,4),
  balance_after   numeric(15,4),
  reference_type  text,                     -- pos_orders, pur_goods_receipts, ...
  reference_id    uuid,
  reference_number text,
  note            text,
  created_by      uuid references sys_users(id),
  movement_at     timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

create index idx_inv_stock_movements_item on inv_stock_movements(warehouse_id, item_id, movement_at);
create index idx_inv_stock_movements_ref  on inv_stock_movements(reference_type, reference_id);

-- Setiap movement otomatis meng-update inv_stocks (moving average cost)
create or replace function inv_apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_stock inv_stocks%rowtype;
begin
  insert into inv_stocks (company_id, warehouse_id, item_id)
  values (new.company_id, new.warehouse_id, new.item_id)
  on conflict (warehouse_id, item_id) do nothing;

  select * into v_stock from inv_stocks
  where warehouse_id = new.warehouse_id and item_id = new.item_id
  for update;

  if new.unit_cost is null then
    new.unit_cost := v_stock.average_cost;
  end if;

  if new.quantity > 0 and greatest(v_stock.quantity, 0) + new.quantity > 0 then
    v_stock.average_cost :=
      (greatest(v_stock.quantity, 0) * v_stock.average_cost + new.quantity * new.unit_cost)
      / (greatest(v_stock.quantity, 0) + new.quantity);
  end if;

  v_stock.quantity := v_stock.quantity + new.quantity;
  new.balance_after := v_stock.quantity;

  update inv_stocks
     set quantity = v_stock.quantity, average_cost = v_stock.average_cost
   where id = v_stock.id;

  return new;
end $$;

create trigger trg_inv_stock_movements_apply
  before insert on inv_stock_movements
  for each row execute function inv_apply_stock_movement();

-- =====================================================================
-- INV: RESEP (BOM)
--   Resep untuk menu (menu_item_id) atau bahan setengah jadi (item_id)
-- =====================================================================
create table inv_recipes (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  menu_item_id  uuid unique references mst_menu_items(id) on delete cascade,
  item_id       uuid unique references inv_items(id) on delete cascade,
  yield_qty     numeric(15,4) not null default 1,   -- hasil 1 resep (base unit)
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((menu_item_id is null) <> (item_id is null))
);

create table inv_recipe_items (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  recipe_id   uuid not null references inv_recipes(id) on delete cascade,
  item_id     uuid not null references inv_items(id),
  quantity    numeric(15,4) not null check (quantity > 0),   -- base unit
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (recipe_id, item_id)
);

-- =====================================================================
-- INV: DOKUMEN STOK (penyesuaian, opname, transfer)
-- =====================================================================
create table inv_stock_adjustments (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  warehouse_id      uuid not null references inv_warehouses(id),
  adjustment_number text,
  adjustment_date   date not null default current_date,
  adjustment_type   text not null default 'adjustment',  -- adjustment / waste
  status            text not null default 'draft',       -- draft / posted
  note              text,
  created_by        uuid references sys_users(id),
  posted_at         timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table inv_stock_adjustment_items (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  stock_adjustment_id  uuid not null references inv_stock_adjustments(id) on delete cascade,
  item_id              uuid not null references inv_items(id),
  quantity             numeric(15,4) not null,   -- + tambah, - kurang (base unit)
  note                 text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table inv_stock_opnames (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  warehouse_id    uuid not null references inv_warehouses(id),
  opname_number   text,
  opname_date     date not null default current_date,
  status          text not null default 'draft',   -- draft / posted
  note            text,
  created_by      uuid references sys_users(id),
  posted_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table inv_stock_opname_items (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  stock_opname_id  uuid not null references inv_stock_opnames(id) on delete cascade,
  item_id          uuid not null references inv_items(id),
  system_qty       numeric(15,4),             -- diisi saat posting
  counted_qty      numeric(15,4) not null,
  difference_qty   numeric(15,4),             -- counted - system
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (stock_opname_id, item_id)
);

create table inv_stock_transfers (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  from_warehouse_id  uuid not null references inv_warehouses(id),
  to_warehouse_id    uuid not null references inv_warehouses(id),
  transfer_number    text,
  transfer_date      date not null default current_date,
  status             text not null default 'draft',   -- draft / posted
  note               text,
  created_by         uuid references sys_users(id),
  posted_at          timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (from_warehouse_id <> to_warehouse_id)
);

create table inv_stock_transfer_items (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  stock_transfer_id  uuid not null references inv_stock_transfers(id) on delete cascade,
  item_id            uuid not null references inv_items(id),
  quantity           numeric(15,4) not null check (quantity > 0),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- =====================================================================
-- PUR: SUPPLIER, PURCHASE ORDER, PENERIMAAN BARANG
-- =====================================================================
create table pur_suppliers (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  code            text not null,
  name            text not null,
  contact_name    text,
  phone           text,
  email           text,
  address         text,
  payment_term_days int not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code)
);

create table pur_purchase_orders (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  supplier_id     uuid not null references pur_suppliers(id),
  warehouse_id    uuid not null references inv_warehouses(id),
  po_number       text,
  po_date         date not null default current_date,
  expected_date   date,
  status          text not null default 'draft',
    -- draft / approved / partially_received / received / cancelled
  subtotal        numeric(15,2) not null default 0,
  tax_amount      numeric(15,2) not null default 0,
  grand_total     numeric(15,2) not null default 0,
  note            text,
  created_by      uuid references sys_users(id),
  approved_by     uuid references sys_users(id),
  approved_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table pur_purchase_order_items (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  purchase_order_id  uuid not null references pur_purchase_orders(id) on delete cascade,
  item_id            uuid not null references inv_items(id),
  unit_id            uuid not null references inv_units(id),
  conversion_qty     numeric(15,4) not null default 1,  -- ke base unit
  quantity           numeric(15,4) not null check (quantity > 0),
  received_qty       numeric(15,4) not null default 0,
  unit_price         numeric(15,2) not null default 0,
  line_total         numeric(15,2) not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table pur_goods_receipts (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  purchase_order_id  uuid references pur_purchase_orders(id),
  supplier_id        uuid not null references pur_suppliers(id),
  warehouse_id       uuid not null references inv_warehouses(id),
  receipt_number     text,
  receipt_date       date not null default current_date,
  supplier_invoice_number text,
  status             text not null default 'draft',   -- draft / posted
  grand_total        numeric(15,2) not null default 0,
  note               text,
  created_by         uuid references sys_users(id),
  posted_at          timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table pur_goods_receipt_items (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid not null references sys_companies(id),
  goods_receipt_id        uuid not null references pur_goods_receipts(id) on delete cascade,
  purchase_order_item_id  uuid references pur_purchase_order_items(id),
  item_id                 uuid not null references inv_items(id),
  unit_id                 uuid not null references inv_units(id),
  conversion_qty          numeric(15,4) not null default 1,
  quantity                numeric(15,4) not null check (quantity > 0),
  unit_price              numeric(15,2) not null default 0,
  line_total              numeric(15,2) not null default 0,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create index idx_pur_purchase_orders_status on pur_purchase_orders(status);
create index idx_pur_goods_receipts_po      on pur_goods_receipts(purchase_order_id);

-- =====================================================================
-- TRIGGER & RLS
-- =====================================================================
select sys_attach_updated_at_triggers();

select sys_apply_company_policies('inv_units', 'inventory.manage');
select sys_apply_company_policies('inv_item_categories', 'inventory.manage');
select sys_apply_company_policies('inv_items', 'inventory.manage');
select sys_apply_company_policies('inv_item_units', 'inventory.manage');
select sys_apply_company_policies('inv_warehouses', 'inventory.manage');
select sys_apply_company_policies('inv_recipes', 'inventory.manage');
select sys_apply_company_policies('inv_recipe_items', 'inventory.manage');
select sys_apply_company_policies('inv_stock_adjustments', 'inventory.manage');
select sys_apply_company_policies('inv_stock_adjustment_items', 'inventory.manage');
select sys_apply_company_policies('inv_stock_opnames', 'inventory.manage');
select sys_apply_company_policies('inv_stock_opname_items', 'inventory.manage');
select sys_apply_company_policies('inv_stock_transfers', 'inventory.manage');
select sys_apply_company_policies('inv_stock_transfer_items', 'inventory.manage');
-- stok & kartu stok hanya bisa diubah lewat fungsi posting
select sys_apply_company_policies('inv_stocks');
select sys_apply_company_policies('inv_stock_movements');

select sys_apply_company_policies('pur_suppliers', 'purchasing.manage');
select sys_apply_company_policies('pur_purchase_orders', 'purchasing.manage');
select sys_apply_company_policies('pur_purchase_order_items', 'purchasing.manage');
select sys_apply_company_policies('pur_goods_receipts', 'purchasing.manage');
select sys_apply_company_policies('pur_goods_receipt_items', 'purchasing.manage');

-- >>>>>>>>>> migrations/003_functions_pos.sql
-- =====================================================================
-- ERP RESTORAN - 003: FUNGSI POS (dipanggil dari aplikasi via supabase.rpc)
-- =====================================================================

-- Nomor urut dokumen, aman dari tabrakan (atomic) ----------------------
create or replace function sys_next_sequence(p_company_id uuid, p_key text)
returns int language plpgsql security definer set search_path = public as $$
declare v_next int;
begin
  insert into sys_document_sequences (company_id, sequence_key, last_number)
  values (p_company_id, p_key, 1)
  on conflict (company_id, sequence_key)
  do update set last_number = sys_document_sequences.last_number + 1
  returning last_number into v_next;
  return v_next;
end $$;

-- Contoh hasil: PO/20261006/0001
create or replace function sys_next_document_number(p_company_id uuid, p_prefix text, p_date date default current_date)
returns text language plpgsql security definer set search_path = public as $$
declare v_key text := p_prefix || '/' || to_char(p_date, 'YYYYMMDD');
begin
  return v_key || '/' || lpad(sys_next_sequence(p_company_id, v_key)::text, 4, '0');
end $$;

create or replace function sys_outlet_business_date(p_outlet_id uuid)
returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone timezone)::date from sys_outlets where id = p_outlet_id
$$;

-- Info user login (dipakai aplikasi setelah login) ----------------------
create or replace function sys_get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', u.id,
    'full_name', u.full_name,
    'company_id', c.id,
    'company_name', c.name,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

-- =====================================================================
-- HITUNG ULANG TOTAL ORDER
--   subtotal - diskon -> + service -> + pajak (PB1) -> pembulatan
-- =====================================================================
create or replace function pos_recalculate_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order   pos_orders%rowtype;
  v_outlet  sys_outlets%rowtype;
  v_sub     numeric(15,2);
  v_base    numeric(15,2);
  v_service numeric(15,2);
  v_tax     numeric(15,2);
  v_raw     numeric(15,2);
  v_total   numeric(15,2);
begin
  select * into v_order from pos_orders where id = p_order_id;
  select * into v_outlet from sys_outlets where id = v_order.outlet_id;

  select coalesce(sum(line_total), 0) into v_sub
  from pos_order_items where order_id = p_order_id and not is_void;

  v_base    := greatest(v_sub - v_order.discount_amount, 0);
  v_service := round(v_base * v_outlet.service_charge_rate / 100);
  v_tax     := round((v_base + v_service) * v_outlet.tax_rate / 100);
  v_raw     := v_base + v_service + v_tax;
  v_total   := case when v_outlet.rounding_unit > 1
                    then round(v_raw / v_outlet.rounding_unit) * v_outlet.rounding_unit
                    else v_raw end;

  update pos_orders set
    subtotal        = v_sub,
    service_amount  = v_service,
    tax_amount      = v_tax,
    rounding_amount = v_total - v_raw,
    grand_total     = v_total
  where id = p_order_id;
end $$;

-- =====================================================================
-- SIMPAN ORDER (buat baru, atau tambah item ke open bill)
-- payload:
-- {
--   "order_id": null | uuid,          -- isi untuk menambah item
--   "outlet_id": uuid,
--   "table_id": uuid | null,
--   "sales_channel": "dine_in",
--   "customer_name": "Budi",
--   "guest_count": 2,
--   "note": "",
--   "items": [
--     { "menu_item_id": uuid, "quantity": 2, "note": "tanpa bawang",
--       "modifier_ids": [uuid, ...] }
--   ]
-- }
-- =====================================================================
create or replace function pos_save_order(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company   uuid := sys_current_company_id();
  v_order_id  uuid := nullif(p_payload->>'order_id', '')::uuid;
  v_outlet_id uuid;
  v_order     pos_orders%rowtype;
  v_outlet    sys_outlets%rowtype;
  v_channel   text;
  v_date      date;
  v_item      jsonb;
  v_menu      mst_menu_items%rowtype;
  v_price     numeric(15,2);
  v_mod_total numeric(15,2);
  v_qty       numeric(10,2);
  v_line_id   uuid;
begin
  if v_company is null then raise exception 'Anda belum login'; end if;
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin membuat order'; end if;
  if jsonb_array_length(coalesce(p_payload->'items', '[]')) = 0 then
    raise exception 'Order tidak punya item';
  end if;

  if v_order_id is null then
    v_outlet_id := (p_payload->>'outlet_id')::uuid;
    if not sys_can_access_outlet(v_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
    select * into v_outlet from sys_outlets where id = v_outlet_id;
    v_channel := coalesce(nullif(p_payload->>'sales_channel', ''), 'dine_in');
    v_date := sys_outlet_business_date(v_outlet_id);

    insert into pos_orders (
      company_id, outlet_id, table_id, order_number, business_date, sales_channel,
      customer_name, guest_count, note, created_by, shift_id
    ) values (
      v_company, v_outlet_id, nullif(p_payload->>'table_id', '')::uuid,
      'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD') || '/' ||
        lpad(sys_next_sequence(v_company, 'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD'))::text, 4, '0'),
      v_date, v_channel,
      nullif(p_payload->>'customer_name', ''),
      coalesce((p_payload->>'guest_count')::int, 1),
      nullif(p_payload->>'note', ''),
      auth.uid(),
      (select id from pos_shifts where outlet_id = v_outlet_id and user_id = auth.uid() and status = 'open' limit 1)
    ) returning * into v_order;

    if v_order.table_id is not null then
      update mst_tables set status = 'occupied' where id = v_order.table_id and company_id = v_company;
    end if;
  else
    select * into v_order from pos_orders where id = v_order_id and company_id = v_company for update;
    if not found then raise exception 'Order tidak ditemukan'; end if;
    if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
    v_outlet_id := v_order.outlet_id;
    v_channel := v_order.sales_channel;
  end if;

  for v_item in select * from jsonb_array_elements(p_payload->'items') loop
    select * into v_menu from mst_menu_items
    where id = (v_item->>'menu_item_id')::uuid and company_id = v_company and is_active;
    if not found then raise exception 'Menu tidak ditemukan / tidak aktif'; end if;

    v_qty := coalesce((v_item->>'quantity')::numeric, 1);
    if v_qty <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;

    v_price := coalesce(
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id = v_outlet_id and sales_channel = v_channel),
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id is null and sales_channel = v_channel),
      v_menu.base_price);

    select coalesce(sum(m.extra_price), 0) into v_mod_total
    from mst_modifiers m
    where m.company_id = v_company
      and m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);

    insert into pos_order_items (
      company_id, order_id, menu_item_id, menu_item_name, station,
      quantity, unit_price, modifier_amount, line_total, note
    ) values (
      v_company, v_order.id, v_menu.id, v_menu.name, v_menu.station,
      v_qty, v_price, v_mod_total, v_qty * (v_price + v_mod_total),
      nullif(v_item->>'note', '')
    ) returning id into v_line_id;

    insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
    select v_company, v_line_id, m.id, m.name, m.extra_price
    from mst_modifiers m
    where m.company_id = v_company
      and m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);
  end loop;

  perform pos_recalculate_order(v_order.id);

  select * into v_order from pos_orders where id = v_order.id;
  return to_jsonb(v_order);
end $$;

-- =====================================================================
-- DISKON ORDER (nominal Rp, sebelum service & pajak)
-- =====================================================================
create or replace function pos_set_order_discount(p_order_id uuid, p_discount_amount numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_order pos_orders%rowtype;
begin
  if not sys_has_permission('pos.discount') then raise exception 'Tidak punya izin memberi diskon'; end if;
  select * into v_order from pos_orders
  where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  if p_discount_amount < 0 or p_discount_amount > v_order.subtotal then
    raise exception 'Diskon harus antara 0 dan subtotal';
  end if;

  update pos_orders set discount_amount = p_discount_amount where id = p_order_id;
  perform pos_recalculate_order(p_order_id);
  select * into v_order from pos_orders where id = p_order_id;
  return to_jsonb(v_order);
end $$;

-- =====================================================================
-- BAYAR ORDER
-- payments: [ { "payment_method_id": uuid, "amount": 100000, "reference_number": "" } ]
-- =====================================================================
create or replace function pos_pay_order(
  p_order_id uuid,
  p_payments jsonb,
  p_discount_amount numeric default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_order    pos_orders%rowtype;
  v_shift_id uuid;
  v_paid     numeric(15,2);
  v_change   numeric(15,2);
  v_cash_id  uuid;
  v_pay      jsonb;
  v_method   mst_payment_methods%rowtype;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin menerima pembayaran'; end if;

  select * into v_order from pos_orders where id = p_order_id and company_id = v_company for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v_order.status <> 'open' then raise exception 'Order sudah dibayar / dibatalkan'; end if;

  select id into v_shift_id from pos_shifts
  where outlet_id = v_order.outlet_id and user_id = auth.uid() and status = 'open' limit 1;
  if v_shift_id is null then raise exception 'Buka shift kasir terlebih dahulu'; end if;

  if p_discount_amount is not null and p_discount_amount <> v_order.discount_amount then
    if p_discount_amount > 0 and not sys_has_permission('pos.discount') then
      raise exception 'Tidak punya izin memberi diskon';
    end if;
    update pos_orders set discount_amount = greatest(p_discount_amount, 0) where id = p_order_id;
    perform pos_recalculate_order(p_order_id);
    select * into v_order from pos_orders where id = p_order_id;
  end if;

  select coalesce(sum((p->>'amount')::numeric), 0) into v_paid
  from jsonb_array_elements(coalesce(p_payments, '[]')) p;

  if v_paid < v_order.grand_total then
    raise exception 'Pembayaran kurang: total %, dibayar %', v_order.grand_total, v_paid;
  end if;
  v_change := v_paid - v_order.grand_total;

  for v_pay in select * from jsonb_array_elements(p_payments) loop
    select * into v_method from mst_payment_methods
    where id = (v_pay->>'payment_method_id')::uuid and company_id = v_company and is_active;
    if not found then raise exception 'Metode pembayaran tidak valid'; end if;
    if (v_pay->>'amount')::numeric <= 0 then continue; end if;

    insert into pos_payments (company_id, order_id, payment_method_id, amount, reference_number)
    values (v_company, p_order_id, v_method.id, (v_pay->>'amount')::numeric, nullif(v_pay->>'reference_number', ''));
  end loop;

  if v_change > 0 then
    select pp.id into v_cash_id from pos_payments pp
    join mst_payment_methods m on m.id = pp.payment_method_id
    where pp.order_id = p_order_id and m.type = 'cash' limit 1;
    if v_cash_id is null then raise exception 'Kembalian hanya untuk pembayaran tunai'; end if;
    update pos_payments set change_amount = v_change where id = v_cash_id;
  end if;

  update pos_orders
     set status = 'paid', paid_at = now(), shift_id = v_shift_id
   where id = p_order_id;

  if v_order.table_id is not null and not exists (
      select 1 from pos_orders where table_id = v_order.table_id and status = 'open') then
    update mst_tables set status = 'available' where id = v_order.table_id;
  end if;

  return jsonb_build_object(
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'grand_total', v_order.grand_total,
    'paid_amount', v_paid,
    'change_amount', v_change);
end $$;

-- =====================================================================
-- VOID
-- =====================================================================
create or replace function pos_void_order(p_order_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_order pos_orders%rowtype;
begin
  if not sys_has_permission('pos.void') then raise exception 'Tidak punya izin void'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan void wajib diisi'; end if;

  select * into v_order from pos_orders
  where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v_order.status <> 'open' then raise exception 'Hanya order yang belum dibayar yang bisa di-void'; end if;

  update pos_orders set status = 'void', voided_at = now(), void_reason = p_reason where id = p_order_id;
  update pos_order_items set is_void = true where order_id = p_order_id;

  if v_order.table_id is not null and not exists (
      select 1 from pos_orders where table_id = v_order.table_id and status = 'open') then
    update mst_tables set status = 'available' where id = v_order.table_id;
  end if;
end $$;

create or replace function pos_void_order_item(p_order_item_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_order_id uuid;
begin
  if not sys_has_permission('pos.void') then raise exception 'Tidak punya izin void'; end if;

  select i.order_id into v_order_id
  from pos_order_items i join pos_orders o on o.id = i.order_id
  where i.id = p_order_item_id and o.company_id = sys_current_company_id() and o.status = 'open';
  if v_order_id is null then raise exception 'Item tidak ditemukan / order sudah ditutup'; end if;

  update pos_order_items
     set is_void = true, note = trim(coalesce(note, '') || ' [VOID: ' || coalesce(p_reason, '-') || ']')
   where id = p_order_item_id;
  perform pos_recalculate_order(v_order_id);
end $$;

-- =====================================================================
-- SHIFT KASIR
-- =====================================================================
create or replace function pos_open_shift(p_outlet_id uuid, p_opening_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shift pos_shifts%rowtype;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin membuka shift'; end if;
  if not sys_can_access_outlet(p_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if exists (select 1 from pos_shifts where outlet_id = p_outlet_id and user_id = auth.uid() and status = 'open') then
    raise exception 'Anda masih punya shift yang terbuka';
  end if;

  insert into pos_shifts (company_id, outlet_id, user_id, business_date, opening_cash)
  values (sys_current_company_id(), p_outlet_id, auth.uid(),
          sys_outlet_business_date(p_outlet_id), coalesce(p_opening_cash, 0))
  returning * into v_shift;
  return to_jsonb(v_shift);
end $$;

create or replace function pos_close_shift(p_shift_id uuid, p_closing_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shift    pos_shifts%rowtype;
  v_cash_in  numeric(15,2);
begin
  select * into v_shift from pos_shifts
  where id = p_shift_id and user_id = auth.uid() and status = 'open' for update;
  if not found then raise exception 'Shift tidak ditemukan / sudah ditutup'; end if;

  select coalesce(sum(p.amount - p.change_amount), 0) into v_cash_in
  from pos_payments p
  join pos_orders o on o.id = p.order_id
  join mst_payment_methods m on m.id = p.payment_method_id
  where o.shift_id = p_shift_id and o.status = 'paid' and m.type = 'cash';

  update pos_shifts set
    status        = 'closed',
    closed_at     = now(),
    closing_cash  = p_closing_cash,
    expected_cash = v_shift.opening_cash + v_cash_in
  where id = p_shift_id
  returning * into v_shift;

  return to_jsonb(v_shift) || jsonb_build_object('difference', v_shift.closing_cash - v_shift.expected_cash);
end $$;

-- >>>>>>>>>> migrations/004_functions_inventory_purchasing.sql
-- =====================================================================
-- ERP RESTORAN - 004: FUNGSI INVENTORY, PURCHASING & VIEW LAPORAN
-- =====================================================================

-- =====================================================================
-- POTONG STOK OTOMATIS SAAT ORDER DIBAYAR (berdasarkan resep)
-- =====================================================================
create or replace function inv_post_order_consumption(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order        pos_orders%rowtype;
  v_warehouse_id uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  select default_warehouse_id into v_warehouse_id from sys_outlets where id = v_order.outlet_id;
  if v_warehouse_id is null then return; end if;

  insert into inv_stock_movements (
    company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by
  )
  select v_order.company_id, v_warehouse_id, ri.item_id, 'sales',
         -sum(oi.quantity * ri.quantity / r.yield_qty),
         'pos_orders', v_order.id, v_order.order_number, auth.uid()
  from pos_order_items oi
  join inv_recipes r       on r.menu_item_id = oi.menu_item_id
  join inv_recipe_items ri on ri.recipe_id = r.id
  where oi.order_id = p_order_id and not oi.is_void
  group by ri.item_id;
end $$;

create or replace function pos_on_order_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform inv_post_order_consumption(new.id);
  return new;
end $$;

create trigger trg_pos_orders_paid
  after update of status on pos_orders
  for each row
  when (new.status = 'paid' and old.status is distinct from 'paid')
  execute function pos_on_order_paid();

-- =====================================================================
-- POSTING DOKUMEN STOK
-- =====================================================================
create or replace function inv_post_stock_adjustment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_doc inv_stock_adjustments%rowtype;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_adjustments
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  v_doc.adjustment_number := coalesce(v_doc.adjustment_number,
    sys_next_document_number(v_doc.company_id, case when v_doc.adjustment_type = 'waste' then 'WST' else 'ADJ' end, v_doc.adjustment_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, note, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, v_doc.adjustment_type,
         case when v_doc.adjustment_type = 'waste' then -abs(i.quantity) else i.quantity end,
         'inv_stock_adjustments', v_doc.id, v_doc.adjustment_number, i.note, auth.uid()
  from inv_stock_adjustment_items i
  where i.stock_adjustment_id = p_id and i.quantity <> 0;

  update inv_stock_adjustments
     set status = 'posted', posted_at = now(), adjustment_number = v_doc.adjustment_number
   where id = p_id;
end $$;

create or replace function inv_post_stock_opname(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_doc inv_stock_opnames%rowtype;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_opnames
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  v_doc.opname_number := coalesce(v_doc.opname_number,
    sys_next_document_number(v_doc.company_id, 'OPN', v_doc.opname_date));

  update inv_stock_opname_items i set
    system_qty = coalesce((select s.quantity from inv_stocks s
                           where s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id), 0)
  where i.stock_opname_id = p_id;

  update inv_stock_opname_items set difference_qty = counted_qty - system_qty
  where stock_opname_id = p_id;

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'opname', i.difference_qty,
         'inv_stock_opnames', v_doc.id, v_doc.opname_number, auth.uid()
  from inv_stock_opname_items i
  where i.stock_opname_id = p_id and i.difference_qty <> 0;

  update inv_stock_opnames
     set status = 'posted', posted_at = now(), opname_number = v_doc.opname_number
   where id = p_id;
end $$;

create or replace function inv_post_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc  inv_stock_transfers%rowtype;
  v_line record;
  v_cost numeric(15,4);
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_transfers
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  v_doc.transfer_number := coalesce(v_doc.transfer_number,
    sys_next_document_number(v_doc.company_id, 'TRF', v_doc.transfer_date));

  for v_line in select * from inv_stock_transfer_items where stock_transfer_id = p_id loop
    select average_cost into v_cost from inv_stocks
    where warehouse_id = v_doc.from_warehouse_id and item_id = v_line.item_id;

    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, created_by)
    values
      (v_doc.company_id, v_doc.from_warehouse_id, v_line.item_id, 'transfer_out', -v_line.quantity, v_cost,
       'inv_stock_transfers', v_doc.id, v_doc.transfer_number, auth.uid()),
      (v_doc.company_id, v_doc.to_warehouse_id, v_line.item_id, 'transfer_in', v_line.quantity, coalesce(v_cost, 0),
       'inv_stock_transfers', v_doc.id, v_doc.transfer_number, auth.uid());
  end loop;

  update inv_stock_transfers
     set status = 'posted', posted_at = now(), transfer_number = v_doc.transfer_number
   where id = p_id;
end $$;

-- =====================================================================
-- PURCHASING
-- =====================================================================
create or replace function pur_approve_purchase_order(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_doc pur_purchase_orders%rowtype;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_purchase_orders
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'PO tidak ditemukan / bukan draft'; end if;
  if not exists (select 1 from pur_purchase_order_items where purchase_order_id = p_id) then
    raise exception 'PO belum punya item';
  end if;

  update pur_purchase_order_items set line_total = quantity * unit_price where purchase_order_id = p_id;

  update pur_purchase_orders set
    po_number   = coalesce(po_number, sys_next_document_number(company_id, 'PO', po_date)),
    subtotal    = (select coalesce(sum(line_total), 0) from pur_purchase_order_items where purchase_order_id = p_id),
    grand_total = (select coalesce(sum(line_total), 0) from pur_purchase_order_items where purchase_order_id = p_id) + tax_amount,
    status      = 'approved',
    approved_by = auth.uid(),
    approved_at = now()
  where id = p_id
  returning * into v_doc;

  return to_jsonb(v_doc);
end $$;

-- Buat draft penerimaan barang dari sisa PO yang belum diterima
create or replace function pur_create_goods_receipt_from_po(p_po_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_po    pur_purchase_orders%rowtype;
  v_gr_id uuid;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_po from pur_purchase_orders
  where id = p_po_id and company_id = sys_current_company_id();
  if not found or v_po.status not in ('approved', 'partially_received') then
    raise exception 'PO harus berstatus approved';
  end if;

  insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, created_by)
  values (v_po.company_id, v_po.id, v_po.supplier_id, v_po.warehouse_id, auth.uid())
  returning id into v_gr_id;

  insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id,
    item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
  select company_id, v_gr_id, id, item_id, unit_id, conversion_qty,
         quantity - received_qty, unit_price, (quantity - received_qty) * unit_price
  from pur_purchase_order_items
  where purchase_order_id = p_po_id and quantity > received_qty;

  return v_gr_id;
end $$;

create or replace function pur_post_goods_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_doc pur_goods_receipts%rowtype;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_goods_receipts
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id) then
    raise exception 'Penerimaan belum punya item';
  end if;

  update pur_goods_receipt_items set line_total = quantity * unit_price where goods_receipt_id = p_id;

  v_doc.receipt_number := coalesce(v_doc.receipt_number,
    sys_next_document_number(v_doc.company_id, 'GR', v_doc.receipt_date));

  -- stok masuk (dikonversi ke base unit)
  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
    reference_type, reference_id, reference_number, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'purchase_receipt',
         i.quantity * i.conversion_qty, i.unit_price / i.conversion_qty,
         'pur_goods_receipts', v_doc.id, v_doc.receipt_number, auth.uid()
  from pur_goods_receipt_items i where i.goods_receipt_id = p_id;

  -- harga beli terakhir per base unit
  update inv_items it set last_purchase_cost = i.unit_price / i.conversion_qty
  from pur_goods_receipt_items i
  where i.goods_receipt_id = p_id and it.id = i.item_id;

  -- update qty diterima di PO
  update pur_purchase_order_items poi
     set received_qty = poi.received_qty + gri.total_qty
  from (select purchase_order_item_id, sum(quantity) total_qty
        from pur_goods_receipt_items
        where goods_receipt_id = p_id and purchase_order_item_id is not null
        group by purchase_order_item_id) gri
  where poi.id = gri.purchase_order_item_id;

  if v_doc.purchase_order_id is not null then
    update pur_purchase_orders po set status =
      case when exists (select 1 from pur_purchase_order_items
                        where purchase_order_id = po.id and received_qty < quantity)
           then 'partially_received' else 'received' end
    where id = v_doc.purchase_order_id;
  end if;

  update pur_goods_receipts set
    status = 'posted', posted_at = now(), receipt_number = v_doc.receipt_number,
    grand_total = (select coalesce(sum(line_total), 0) from pur_goods_receipt_items where goods_receipt_id = p_id)
  where id = p_id
  returning * into v_doc;

  return to_jsonb(v_doc);
end $$;

-- =====================================================================
-- VIEW LAPORAN (rpt_)  -- security_invoker: tetap tunduk pada RLS
-- =====================================================================
create view rpt_daily_sales with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date,
       count(*)               as order_count,
       sum(o.guest_count)     as guest_count,
       sum(o.subtotal)        as subtotal,
       sum(o.discount_amount) as discount_amount,
       sum(o.service_amount)  as service_amount,
       sum(o.tax_amount)      as tax_amount,
       sum(o.grand_total)     as grand_total
from pos_orders o
where o.status = 'paid'
group by o.company_id, o.outlet_id, o.business_date;

create view rpt_menu_sales with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date,
       oi.menu_item_id, oi.menu_item_name,
       sum(oi.quantity)   as quantity,
       sum(oi.line_total) as revenue
from pos_order_items oi
join pos_orders o on o.id = oi.order_id
where o.status = 'paid' and not oi.is_void
group by o.company_id, o.outlet_id, o.business_date, oi.menu_item_id, oi.menu_item_name;

create view rpt_payment_summary with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date,
       m.id as payment_method_id, m.name as payment_method_name,
       count(*) as transaction_count,
       sum(p.amount - p.change_amount) as amount
from pos_payments p
join pos_orders o on o.id = p.order_id
join mst_payment_methods m on m.id = p.payment_method_id
where o.status = 'paid'
group by o.company_id, o.outlet_id, o.business_date, m.id, m.name;

-- HPP standar per menu (pakai harga beli terakhir)
create view rpt_menu_food_costs with (security_invoker = true) as
select mi.company_id, mi.id as menu_item_id, mi.code, mi.name, mi.base_price,
       coalesce(sum(ri.quantity / r.yield_qty * it.last_purchase_cost), 0)::numeric(15,2) as food_cost,
       case when mi.base_price > 0
            then round(coalesce(sum(ri.quantity / r.yield_qty * it.last_purchase_cost), 0) / mi.base_price * 100, 1)
       end as food_cost_pct,
       count(ri.id) > 0 as has_recipe
from mst_menu_items mi
left join inv_recipes r       on r.menu_item_id = mi.id
left join inv_recipe_items ri on ri.recipe_id = r.id
left join inv_items it        on it.id = ri.item_id
where mi.is_active
group by mi.company_id, mi.id, mi.code, mi.name, mi.base_price;

create view rpt_stock_balances with (security_invoker = true) as
select s.company_id, s.warehouse_id, w.name as warehouse_name,
       s.item_id, it.code as item_code, it.name as item_name,
       u.code as unit_code, s.quantity, s.average_cost,
       (s.quantity * s.average_cost)::numeric(15,2) as stock_value,
       it.min_stock, s.quantity <= it.min_stock as is_low_stock
from inv_stocks s
join inv_warehouses w on w.id = s.warehouse_id
join inv_items it     on it.id = s.item_id
join inv_units u      on u.id = it.base_unit_id;

-- =====================================================================
-- KUNCI FUNGSI INTERNAL (tidak boleh dipanggil langsung dari aplikasi)
-- =====================================================================
revoke execute on function sys_next_sequence(uuid, text)                 from public, anon, authenticated;
revoke execute on function sys_next_document_number(uuid, text, date)   from public, anon, authenticated;
revoke execute on function pos_recalculate_order(uuid)                  from public, anon, authenticated;
revoke execute on function inv_post_order_consumption(uuid)             from public, anon, authenticated;
revoke execute on function sys_apply_company_policies(text, text)       from public, anon, authenticated;
revoke execute on function sys_attach_updated_at_triggers()             from public, anon, authenticated;

-- >>>>>>>>>> migrations/005_onboarding_demo_seed.sql
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

-- >>>>>>>>>> migrations/006_users_settings.sql
-- =====================================================================
-- ERP RESTORAN - 006: USER, UNDANGAN, OUTLET
--   Alur: owner mengundang email + role + outlet -> staf daftar akun
--         dengan email tsb -> di halaman awal muncul undangan -> terima.
-- =====================================================================

create table sys_user_invitations (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  email        text not null check (email = lower(trim(email))),
  role_id      uuid not null references sys_roles(id),
  outlet_ids   uuid[] not null default '{}',
  status       text not null default 'pending',   -- pending / accepted / cancelled
  invited_by   uuid references sys_users(id),
  accepted_by  uuid references sys_users(id),
  accepted_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create unique index uq_sys_user_invitations_pending
  on sys_user_invitations(company_id, email) where status = 'pending';

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('sys_user_invitations', 'user.manage');

-- Email user yang sedang login
create or replace function sys_current_user_email()
returns text language sql stable security definer set search_path = public as $$
  select lower(email) from auth.users where id = auth.uid()
$$;

-- Undangan untuk email saya (dipanggil di halaman onboarding)
create or replace function sys_get_my_invitations()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'company_name', c.name, 'role_name', r.name, 'created_at', i.created_at)
         order by i.created_at desc), '[]'::jsonb)
  from sys_user_invitations i
  join sys_companies c on c.id = i.company_id
  join sys_roles r on r.id = i.role_id
  where i.status = 'pending' and i.email = sys_current_user_email()
$$;

create or replace function sys_accept_invitation(p_invitation_id uuid, p_full_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v_inv sys_user_invitations%rowtype;
begin
  if auth.uid() is null then raise exception 'Anda belum login'; end if;
  if exists (select 1 from sys_users where id = auth.uid()) then
    raise exception 'Akun ini sudah terdaftar di sebuah perusahaan';
  end if;

  select * into v_inv from sys_user_invitations
  where id = p_invitation_id and status = 'pending' and email = sys_current_user_email()
  for update;
  if not found then raise exception 'Undangan tidak ditemukan atau sudah tidak berlaku'; end if;

  insert into sys_users (id, company_id, role_id, full_name)
  values (auth.uid(), v_inv.company_id, v_inv.role_id, coalesce(nullif(trim(p_full_name), ''), split_part(v_inv.email, '@', 1)));

  insert into sys_user_outlets (user_id, outlet_id)
  select auth.uid(), o.id from sys_outlets o
  where o.company_id = v_inv.company_id and o.id = any(v_inv.outlet_ids);

  update sys_user_invitations
     set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
   where id = v_inv.id;
end $$;

-- Daftar user + email (email ada di auth.users, tidak bisa dibaca langsung dari aplikasi)
create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'email', au.email, 'is_active', u.is_active,
           'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

-- Ubah role, outlet, status aktif user lain
create or replace function sys_update_user(p_user_id uuid, p_role_id uuid, p_outlet_ids uuid[], p_is_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if p_user_id = auth.uid() then raise exception 'Tidak bisa mengubah akun sendiri'; end if;
  if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then
    raise exception 'User tidak ditemukan';
  end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then
    raise exception 'Role tidak valid';
  end if;

  update sys_users set role_id = p_role_id, is_active = p_is_active where id = p_user_id;
  delete from sys_user_outlets where user_id = p_user_id;
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o where o.company_id = v_company and o.id = any(p_outlet_ids);
end $$;

-- Tambah outlet baru beserta gudangnya
create or replace function sys_create_outlet(p_code text, p_name text, p_address text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_outlet  sys_outlets%rowtype;
  v_wh      uuid;
begin
  if not sys_has_permission('settings.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then
    raise exception 'Kode dan nama outlet wajib diisi';
  end if;

  insert into sys_outlets (company_id, brand_id, code, name, address)
  values (v_company, (select id from sys_brands where company_id = v_company order by created_at limit 1),
          upper(trim(p_code)), trim(p_name), p_address)
  returning * into v_outlet;

  insert into inv_warehouses (company_id, outlet_id, code, name)
  values (v_company, v_outlet.id, 'WH-' || v_outlet.code, 'Gudang ' || v_outlet.name)
  returning id into v_wh;

  update sys_outlets set default_warehouse_id = v_wh where id = v_outlet.id;
  insert into sys_user_outlets (user_id, outlet_id) values (auth.uid(), v_outlet.id) on conflict do nothing;

  return to_jsonb(v_outlet);
end $$;

revoke execute on function sys_current_user_email() from public, anon, authenticated;

-- >>>>>>>>>> migrations/007_finance.sql
-- =====================================================================
-- ERP RESTORAN - 007: KEUANGAN (AKUNTANSI)
--   * Bagan akun (COA) standar restoran
--   * Jurnal OTOMATIS dari: penjualan (+HPP), penerimaan barang,
--     penyesuaian/waste/opname stok, pembayaran supplier, biaya
--   * Jurnal manual, laporan Laba Rugi / Neraca / Buku Besar
--   Permission baru: finance.manage (input), finance.view (laporan)
-- =====================================================================

-- =====================================================================
-- TABEL
-- =====================================================================
create table fin_accounts (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  parent_id       uuid references fin_accounts(id),
  code            text not null,
  name            text not null,
  account_type    text not null,      -- asset / liability / equity / revenue / cogs / expense
  normal_balance  text not null,      -- debit / credit
  is_header       boolean not null default false,   -- header = pengelompokan, tidak bisa dijurnal
  system_key      text,               -- dipakai jurnal otomatis: cash, bank, inventory, ap, ...
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code),
  unique (company_id, system_key),
  check (account_type in ('asset', 'liability', 'equity', 'revenue', 'cogs', 'expense')),
  check (normal_balance in ('debit', 'credit'))
);

create table fin_journals (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  outlet_id       uuid references sys_outlets(id),
  journal_number  text not null,
  journal_date    date not null,
  source_type     text not null,
    -- sales / purchase_receipt / stock_adjustment / stock_opname / supplier_payment
    -- expense / manual / opening_stock
  source_id       uuid,
  description     text,
  total_amount    numeric(15,2) not null default 0,
  created_by      uuid references sys_users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, journal_number)
);

create unique index uq_fin_journals_source on fin_journals(source_type, source_id)
  where source_id is not null and source_type not in ('manual', 'expense');
create index idx_fin_journals_date on fin_journals(company_id, journal_date);

create table fin_journal_lines (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  journal_id  uuid not null references fin_journals(id) on delete cascade,
  account_id  uuid not null references fin_accounts(id),
  outlet_id   uuid references sys_outlets(id),
  debit       numeric(15,2) not null default 0 check (debit >= 0),
  credit      numeric(15,2) not null default 0 check (credit >= 0),
  note        text,
  created_at  timestamptz not null default now(),
  check (debit = 0 or credit = 0)
);

create index idx_fin_journal_lines_account on fin_journal_lines(account_id);
create index idx_fin_journal_lines_journal on fin_journal_lines(journal_id);

-- Akun kas/bank tujuan untuk setiap metode bayar
alter table mst_payment_methods add column account_id uuid references fin_accounts(id);

-- Hutang supplier
alter table pur_goods_receipts add column paid_amount numeric(15,2) not null default 0;
alter table pur_goods_receipts add column due_date date;

create table fin_supplier_payments (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  supplier_id     uuid not null references pur_suppliers(id),
  account_id      uuid not null references fin_accounts(id),   -- dibayar dari kas/bank
  payment_number  text not null,
  payment_date    date not null default current_date,
  amount          numeric(15,2) not null check (amount > 0),
  reference_number text,
  note            text,
  created_by      uuid references sys_users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table fin_supplier_payment_items (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  supplier_payment_id  uuid not null references fin_supplier_payments(id) on delete cascade,
  goods_receipt_id     uuid not null references pur_goods_receipts(id),
  amount               numeric(15,2) not null check (amount > 0),
  created_at           timestamptz not null default now()
);

select sys_attach_updated_at_triggers();

select sys_apply_company_policies('fin_accounts', 'finance.manage');
select sys_apply_company_policies('fin_journals');              -- hanya lewat fungsi
select sys_apply_company_policies('fin_journal_lines');
select sys_apply_company_policies('fin_supplier_payments');
select sys_apply_company_policies('fin_supplier_payment_items');

-- Data keuangan hanya bisa dibaca role yang punya finance.view / finance.manage
do $$
declare t text;
begin
  foreach t in array array['fin_accounts', 'fin_journals', 'fin_journal_lines',
                           'fin_supplier_payments', 'fin_supplier_payment_items'] loop
    execute format('drop policy %I on %I', t || '_select', t);
    execute format(
      'create policy %I on %I for select to authenticated
       using (company_id = sys_current_company_id()
              and (sys_has_permission(''finance.view'') or sys_has_permission(''finance.manage'')))',
      t || '_select', t);
  end loop;
end $$;

-- =====================================================================
-- COA STANDAR RESTORAN
-- =====================================================================
create or replace function fin_setup_default_accounts(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;

  insert into fin_accounts (company_id, code, name, account_type, normal_balance, is_header, system_key)
  select p_company_id, a.code, a.name, a.type,
         coalesce(a.normal, case when a.type in ('asset', 'cogs', 'expense') then 'debit' else 'credit' end),
         a.header, a.skey
  from (values
    ('1-0000', 'ASET',                              'asset',     null::text, true,  null::text),
    ('1-1100', 'Kas',                               'asset',     null, false, 'cash'),
    ('1-1200', 'Bank',                              'asset',     null, false, 'bank'),
    ('1-1300', 'Piutang Usaha',                     'asset',     null, false, 'ar'),
    ('1-1400', 'Persediaan Bahan Baku',             'asset',     null, false, 'inventory'),
    ('1-1500', 'Biaya Dibayar di Muka',             'asset',     null, false, null),
    ('1-2100', 'Peralatan Dapur & Restoran',        'asset',     null, false, null),
    ('1-2200', 'Akumulasi Penyusutan',              'asset',     'credit', false, null),
    ('2-0000', 'KEWAJIBAN',                         'liability', null, true,  null),
    ('2-1100', 'Hutang Usaha',                      'liability', null, false, 'ap'),
    ('2-1200', 'Hutang Pajak Restoran (PB1)',       'liability', null, false, 'tax_payable'),
    ('2-1300', 'Hutang Gaji',                       'liability', null, false, null),
    ('3-0000', 'EKUITAS',                           'equity',    null, true,  null),
    ('3-1100', 'Modal Pemilik',                     'equity',    null, false, 'owner_equity'),
    ('3-1200', 'Ekuitas Saldo Awal',                'equity',    null, false, 'opening_equity'),
    ('3-1300', 'Prive / Penarikan Pemilik',         'equity',    'debit', false, null),
    ('4-0000', 'PENDAPATAN',                        'revenue',   null, true,  null),
    ('4-1100', 'Penjualan Makanan & Minuman',       'revenue',   null, false, 'sales_revenue'),
    ('4-1200', 'Pendapatan Service Charge',         'revenue',   null, false, 'service_revenue'),
    ('4-1300', 'Diskon Penjualan',                  'revenue',   'debit', false, 'sales_discount'),
    ('4-1400', 'Selisih Pembulatan',                'revenue',   null, false, 'rounding'),
    ('4-1500', 'Pendapatan Lain-lain',              'revenue',   null, false, null),
    ('5-0000', 'HARGA POKOK PENJUALAN',             'cogs',      null, true,  null),
    ('5-1100', 'HPP Bahan Baku',                    'cogs',      null, false, 'cogs'),
    ('5-1200', 'Bahan Terbuang (Waste)',            'cogs',      null, false, 'waste_expense'),
    ('5-1300', 'Selisih Stok',                      'cogs',      null, false, 'inventory_adjustment'),
    ('6-0000', 'BEBAN OPERASIONAL',                 'expense',   null, true,  null),
    ('6-1100', 'Beban Gaji & Upah',                 'expense',   null, false, null),
    ('6-1200', 'Beban Sewa Tempat',                 'expense',   null, false, null),
    ('6-1300', 'Beban Listrik, Air & Gas',          'expense',   null, false, null),
    ('6-1400', 'Beban Internet & Telepon',          'expense',   null, false, null),
    ('6-1500', 'Beban Pemasaran & Promosi',         'expense',   null, false, null),
    ('6-1600', 'Beban Perlengkapan & Kemasan',      'expense',   null, false, null),
    ('6-1700', 'Beban Komisi Ojek Online',          'expense',   null, false, null),
    ('6-1800', 'Beban Admin Bank & MDR',            'expense',   null, false, null),
    ('6-1900', 'Beban Perbaikan & Perawatan',       'expense',   null, false, null),
    ('6-2000', 'Beban Penyusutan',                  'expense',   null, false, null),
    ('6-9900', 'Beban Lain-lain',                   'expense',   null, false, null)
  ) as a(code, name, type, normal, header, skey);

  -- induk = header dengan digit pertama yang sama
  update fin_accounts a set parent_id = h.id
  from fin_accounts h
  where a.company_id = p_company_id and h.company_id = p_company_id
    and h.is_header and not a.is_header and left(a.code, 1) = left(h.code, 1);

  -- metode bayar: tunai -> Kas, lainnya -> Bank
  update mst_payment_methods m set account_id = (
    select id from fin_accounts
    where company_id = p_company_id and system_key = case when m.type = 'cash' then 'cash' else 'bank' end)
  where m.company_id = p_company_id and m.account_id is null;
end $$;

create or replace function fin_account_id(p_company_id uuid, p_key text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from fin_accounts where company_id = p_company_id and system_key = p_key;
  if v_id is null then raise exception 'Akun sistem "%" belum ada. Jalankan setup akun.', p_key; end if;
  return v_id;
end $$;

-- =====================================================================
-- MESIN JURNAL
-- p_lines: [{ "account_id": uuid, "debit": 0, "credit": 0, "note": "" }]
-- Baris bernilai 0 dilewati. Debit harus = kredit.
-- =====================================================================
create or replace function fin_create_journal(
  p_company_id uuid, p_outlet_id uuid, p_date date, p_source_type text, p_source_id uuid,
  p_description text, p_lines jsonb
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_debit  numeric(15,2);
  v_credit numeric(15,2);
begin
  select coalesce(sum(round(coalesce((l->>'debit')::numeric, 0), 2)), 0),
         coalesce(sum(round(coalesce((l->>'credit')::numeric, 0), 2)), 0)
    into v_debit, v_credit
  from jsonb_array_elements(p_lines) l;

  if v_debit <> v_credit then
    raise exception 'Jurnal tidak seimbang: debit % <> kredit %', v_debit, v_credit;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(p_lines) l
    where round(coalesce((l->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((l->>'credit')::numeric, 0), 2) <> 0) then
    return null;
  end if;

  insert into fin_journals (company_id, outlet_id, journal_number, journal_date, source_type, source_id,
                            description, created_by)
  values (p_company_id, p_outlet_id, sys_next_document_number(p_company_id, 'JRN', p_date), p_date,
          p_source_type, p_source_id, p_description, auth.uid())
  returning id into v_id;

  insert into fin_journal_lines (company_id, journal_id, account_id, outlet_id, debit, credit, note)
  select p_company_id, v_id, (l->>'account_id')::uuid, p_outlet_id,
         -- angka negatif dipindah ke sisi seberangnya
         greatest(round(coalesce((l->>'debit')::numeric, 0), 2), 0) + greatest(-round(coalesce((l->>'credit')::numeric, 0), 2), 0),
         greatest(round(coalesce((l->>'credit')::numeric, 0), 2), 0) + greatest(-round(coalesce((l->>'debit')::numeric, 0), 2), 0),
         nullif(l->>'note', '')
  from jsonb_array_elements(p_lines) l
  where round(coalesce((l->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((l->>'credit')::numeric, 0), 2) <> 0;

  update fin_journals set total_amount = (select sum(debit) from fin_journal_lines where journal_id = v_id)
  where id = v_id;

  return v_id;
end $$;

-- Nilai persediaan dari kartu stok sebuah dokumen (negatif = keluar)
create or replace function fin_stock_value(p_reference_type text, p_reference_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(round(sum(quantity * coalesce(unit_cost, 0)), 2), 0)
  from inv_stock_movements where reference_type = p_reference_type and reference_id = p_reference_id
$$;

-- =====================================================================
-- JURNAL OTOMATIS
-- =====================================================================

-- Penjualan:  Dr Kas/Bank, Dr Diskon | Cr Penjualan, Cr Service, Cr PB1, +/- Pembulatan
-- HPP:        Dr HPP | Cr Persediaan
create or replace function fin_post_sales_journal(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o       pos_orders%rowtype;
  c       uuid;
  v_lines jsonb;
  v_cogs  numeric;
begin
  select * into o from pos_orders where id = p_order_id and status = 'paid';
  if not found then return; end if;
  if exists (select 1 from fin_journals where source_type = 'sales' and source_id = o.id) then return; end if;
  c := o.company_id;
  if not exists (select 1 from fin_accounts where company_id = c) then return; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'account_id', coalesce(m.account_id, fin_account_id(c, 'cash')),
           'debit', p.amount - p.change_amount, 'note', m.name)), '[]'::jsonb)
    into v_lines
  from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
  where p.order_id = o.id;

  v_cogs := -fin_stock_value('pos_orders', o.id);

  v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id', fin_account_id(c, 'sales_discount'),  'debit',  o.discount_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'sales_revenue'),   'credit', o.subtotal),
    jsonb_build_object('account_id', fin_account_id(c, 'service_revenue'), 'credit', o.service_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'tax_payable'),     'credit', o.tax_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'rounding'),        'credit', o.rounding_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'cogs'),            'debit',  v_cogs),
    jsonb_build_object('account_id', fin_account_id(c, 'inventory'),       'credit', v_cogs)
  );

  perform fin_create_journal(c, o.outlet_id, o.business_date, 'sales', o.id,
                             'Penjualan ' || o.order_number, v_lines);
end $$;

-- Penerimaan barang: Dr Persediaan | Cr Hutang Usaha
create or replace function fin_post_goods_receipt_journal(p_receipt_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g pur_goods_receipts%rowtype;
  v_supplier text;
begin
  select * into g from pur_goods_receipts where id = p_receipt_id and status = 'posted';
  if not found or not exists (select 1 from fin_accounts where company_id = g.company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = 'purchase_receipt' and source_id = g.id) then return; end if;
  select name into v_supplier from pur_suppliers where id = g.supplier_id;

  perform fin_create_journal(g.company_id, null, g.receipt_date, 'purchase_receipt', g.id,
    'Pembelian ' || g.receipt_number || ' - ' || v_supplier,
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(g.company_id, 'inventory'), 'debit', g.grand_total),
      jsonb_build_object('account_id', fin_account_id(g.company_id, 'ap'), 'credit', g.grand_total)));
end $$;

-- Penyesuaian / waste / opname:  selisih nilai stok vs akun Selisih Stok / Waste
create or replace function fin_post_stock_document_journal(
  p_company_id uuid, p_reference_type text, p_reference_id uuid, p_date date,
  p_number text, p_counter_key text, p_source_type text
)
returns void language plpgsql security definer set search_path = public as $$
declare v_value numeric;
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = p_source_type and source_id = p_reference_id) then return; end if;
  v_value := fin_stock_value(p_reference_type, p_reference_id);

  perform fin_create_journal(p_company_id, null, p_date, p_source_type, p_reference_id,
    'Stok ' || p_number,
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(p_company_id, 'inventory'),  'debit',  v_value),
      jsonb_build_object('account_id', fin_account_id(p_company_id, p_counter_key), 'credit', v_value)));
end $$;

-- Trigger: dipanggil setelah dokumen berstatus posted
create or replace function fin_on_document_posted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'pur_goods_receipts' then
    perform fin_post_goods_receipt_journal(new.id);
  elsif tg_table_name = 'inv_stock_adjustments' then
    perform fin_post_stock_document_journal(new.company_id, 'inv_stock_adjustments', new.id, new.adjustment_date,
      new.adjustment_number,
      case when new.adjustment_type = 'waste' then 'waste_expense' else 'inventory_adjustment' end,
      'stock_adjustment');
  elsif tg_table_name = 'inv_stock_opnames' then
    perform fin_post_stock_document_journal(new.company_id, 'inv_stock_opnames', new.id, new.opname_date,
      new.opname_number, 'inventory_adjustment', 'stock_opname');
  end if;
  return new;
end $$;

create trigger trg_pur_goods_receipts_journal after update of status on pur_goods_receipts
  for each row when (new.status = 'posted' and old.status is distinct from 'posted')
  execute function fin_on_document_posted();
create trigger trg_inv_stock_adjustments_journal after update of status on inv_stock_adjustments
  for each row when (new.status = 'posted' and old.status is distinct from 'posted')
  execute function fin_on_document_posted();
create trigger trg_inv_stock_opnames_journal after update of status on inv_stock_opnames
  for each row when (new.status = 'posted' and old.status is distinct from 'posted')
  execute function fin_on_document_posted();

-- Order lunas: potong stok DULU, baru jurnal (supaya HPP terhitung)
create or replace function pos_on_order_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform inv_post_order_consumption(new.id);
  perform fin_post_sales_journal(new.id);
  return new;
end $$;

-- Jatuh tempo hutang = tanggal terima + termin supplier
create or replace function pur_set_receipt_due_date()
returns trigger language plpgsql as $$
begin
  if new.status = 'posted' and new.due_date is null then
    new.due_date := new.receipt_date + coalesce(
      (select payment_term_days from pur_suppliers where id = new.supplier_id), 0);
  end if;
  return new;
end $$;

create trigger trg_pur_goods_receipts_due_date before update of status on pur_goods_receipts
  for each row execute function pur_set_receipt_due_date();

-- Stok awal (movement tanpa dokumen): Dr Persediaan | Cr Ekuitas Saldo Awal
create or replace function fin_post_opening_stock_journal(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_value numeric;
begin
  if exists (select 1 from fin_journals where company_id = p_company_id and source_type = 'opening_stock') then return; end if;
  select coalesce(round(sum(quantity * coalesce(unit_cost, 0)), 2), 0) into v_value
  from inv_stock_movements where company_id = p_company_id and reference_id is null;

  perform fin_create_journal(p_company_id, null, current_date, 'opening_stock', p_company_id,
    'Saldo awal persediaan',
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(p_company_id, 'inventory'), 'debit', v_value),
      jsonb_build_object('account_id', fin_account_id(p_company_id, 'opening_equity'), 'credit', v_value)));
end $$;

-- =====================================================================
-- FUNGSI UNTUK APLIKASI
-- =====================================================================

-- Catat biaya operasional: Dr Beban | Cr Kas/Bank
create or replace function fin_record_expense(
  p_date date, p_expense_account_id uuid, p_paid_from_account_id uuid,
  p_amount numeric, p_description text, p_outlet_id uuid default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Nominal harus lebih dari 0'; end if;
  if not exists (select 1 from fin_accounts where id = p_expense_account_id and company_id = v_company and not is_header)
     or not exists (select 1 from fin_accounts where id = p_paid_from_account_id and company_id = v_company and not is_header) then
    raise exception 'Akun tidak valid';
  end if;

  return fin_create_journal(v_company, p_outlet_id, coalesce(p_date, current_date), 'expense', null,
    coalesce(nullif(trim(p_description), ''), 'Biaya operasional'),
    jsonb_build_array(
      jsonb_build_object('account_id', p_expense_account_id, 'debit', p_amount),
      jsonb_build_object('account_id', p_paid_from_account_id, 'credit', p_amount)));
end $$;

-- Jurnal manual (bebas, harus seimbang)
create or replace function fin_post_manual_journal(p_date date, p_description text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    where not exists (select 1 from fin_accounts a
                      where a.id = (l->>'account_id')::uuid and a.company_id = v_company and not a.is_header)) then
    raise exception 'Ada akun yang tidak valid / akun header';
  end if;
  return fin_create_journal(v_company, null, coalesce(p_date, current_date), 'manual', null, p_description, p_lines);
end $$;

-- Bayar hutang supplier
-- p_allocations: [{ "goods_receipt_id": uuid, "amount": 100000 }]
create or replace function fin_pay_supplier(
  p_supplier_id uuid, p_account_id uuid, p_payment_date date, p_allocations jsonb, p_reference_number text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_total   numeric(15,2);
  v_pay     fin_supplier_payments%rowtype;
  v_alloc   jsonb;
  v_gr      pur_goods_receipts%rowtype;
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  if not exists (select 1 from fin_accounts
                 where id = p_account_id and company_id = v_company and account_type = 'asset' and not is_header) then
    raise exception 'Akun pembayaran tidak valid';
  end if;

  select coalesce(sum((a->>'amount')::numeric), 0) into v_total from jsonb_array_elements(p_allocations) a;
  if v_total <= 0 then raise exception 'Nominal pembayaran harus lebih dari 0'; end if;

  insert into fin_supplier_payments (company_id, supplier_id, account_id, payment_number, payment_date,
                                     amount, reference_number, created_by)
  values (v_company, p_supplier_id, p_account_id,
          sys_next_document_number(v_company, 'PAY', coalesce(p_payment_date, current_date)),
          coalesce(p_payment_date, current_date), v_total, p_reference_number, auth.uid())
  returning * into v_pay;

  for v_alloc in select * from jsonb_array_elements(p_allocations) loop
    if (v_alloc->>'amount')::numeric <= 0 then continue; end if;
    select * into v_gr from pur_goods_receipts
    where id = (v_alloc->>'goods_receipt_id')::uuid and company_id = v_company
      and supplier_id = p_supplier_id and status = 'posted'
    for update;
    if not found then raise exception 'Penerimaan barang tidak valid untuk supplier ini'; end if;
    if v_gr.paid_amount + (v_alloc->>'amount')::numeric > v_gr.grand_total then
      raise exception 'Pembayaran % melebihi sisa hutang', v_gr.receipt_number;
    end if;

    insert into fin_supplier_payment_items (company_id, supplier_payment_id, goods_receipt_id, amount)
    values (v_company, v_pay.id, v_gr.id, (v_alloc->>'amount')::numeric);
    update pur_goods_receipts set paid_amount = paid_amount + (v_alloc->>'amount')::numeric where id = v_gr.id;
  end loop;

  perform fin_create_journal(v_company, null, v_pay.payment_date, 'supplier_payment', v_pay.id,
    'Pembayaran supplier ' || v_pay.payment_number,
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(v_company, 'ap'), 'debit', v_total),
      jsonb_build_object('account_id', p_account_id, 'credit', v_total)));

  return to_jsonb(v_pay);
end $$;

-- Saldo akun untuk Neraca Saldo / Laba Rugi / Neraca
--   opening = saldo sebelum p_from, period = mutasi p_from..p_to, closing = opening + period
--   Saldo bertanda sesuai normal balance (positif = saldo normal)
create or replace function fin_get_account_balances(p_from date, p_to date, p_outlet_id uuid default null)
returns table (
  account_id uuid, code text, name text, account_type text, normal_balance text, is_header boolean,
  system_key text, opening_balance numeric, period_debit numeric, period_credit numeric,
  period_balance numeric, closing_balance numeric
)
language sql stable security invoker set search_path = public as $$
  with mv as (
    select l.account_id,
           sum(case when j.journal_date <  p_from then l.debit - l.credit else 0 end) as opening_dc,
           sum(case when j.journal_date >= p_from then l.debit  else 0 end)          as period_debit,
           sum(case when j.journal_date >= p_from then l.credit else 0 end)          as period_credit
    from fin_journal_lines l
    join fin_journals j on j.id = l.journal_id
    where j.journal_date <= p_to and (p_outlet_id is null or l.outlet_id = p_outlet_id)
    group by l.account_id
  )
  select a.id, a.code, a.name, a.account_type, a.normal_balance, a.is_header, a.system_key,
         s.sign * coalesce(mv.opening_dc, 0),
         coalesce(mv.period_debit, 0), coalesce(mv.period_credit, 0),
         s.sign * (coalesce(mv.period_debit, 0) - coalesce(mv.period_credit, 0)),
         s.sign * (coalesce(mv.opening_dc, 0) + coalesce(mv.period_debit, 0) - coalesce(mv.period_credit, 0))
  from fin_accounts a
  cross join lateral (select case when a.normal_balance = 'debit' then 1 else -1 end as sign) s
  left join mv on mv.account_id = a.id
  order by a.code
$$;

-- Daftar hutang per penerimaan barang
create view rpt_payables with (security_invoker = true) as
select g.company_id, g.id as goods_receipt_id, g.receipt_number, g.receipt_date, g.due_date,
       g.supplier_id, s.name as supplier_name, g.supplier_invoice_number,
       g.grand_total, g.paid_amount, g.grand_total - g.paid_amount as outstanding_amount,
       coalesce(g.due_date < current_date, false) and g.grand_total > g.paid_amount as is_overdue
from pur_goods_receipts g
join pur_suppliers s on s.id = g.supplier_id
where g.status = 'posted';

-- =====================================================================
-- ONBOARDING: tambah COA + jurnal stok awal untuk perusahaan baru
-- =====================================================================
-- Metode bayar baru otomatis diarahkan ke akun Kas / Bank
create or replace function mst_on_payment_method_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.account_id is null and exists (select 1 from fin_accounts where company_id = new.company_id) then
    new.account_id := fin_account_id(new.company_id, case when new.type = 'cash' then 'cash' else 'bank' end);
  end if;
  return new;
end $$;

create trigger trg_mst_payment_methods_account before insert on mst_payment_methods
  for each row execute function mst_on_payment_method_created();

-- Bungkus fungsi onboarding lama: setelah selesai, siapkan keuangan
alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_base;
revoke execute on function sys_onboard_company_base(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_base(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform fin_setup_default_accounts((v_result->>'company_id')::uuid);
  perform fin_post_opening_stock_journal((v_result->>'company_id')::uuid);
  return v_result;
end $$;

-- =====================================================================
-- PERMISSION & DATA LAMA
-- =====================================================================
-- Manager boleh melihat laporan keuangan
update sys_roles set permissions = permissions || '["finance.view"]'::jsonb
where code = 'manager' and not permissions ? 'finance.view';

-- Siapkan COA & jurnal untuk perusahaan yang sudah ada (idempotent)
do $$
declare r record;
begin
  for r in select id from sys_companies loop
    perform fin_setup_default_accounts(r.id);
    perform fin_post_opening_stock_journal(r.id);
  end loop;
  for r in select id from pur_goods_receipts where status = 'posted' order by posted_at loop
    perform fin_post_goods_receipt_journal(r.id);
  end loop;
  for r in select id, company_id, adjustment_date, adjustment_number, adjustment_type
           from inv_stock_adjustments where status = 'posted' loop
    perform fin_post_stock_document_journal(r.company_id, 'inv_stock_adjustments', r.id, r.adjustment_date,
      r.adjustment_number, case when r.adjustment_type = 'waste' then 'waste_expense' else 'inventory_adjustment' end,
      'stock_adjustment');
  end loop;
  for r in select id, company_id, opname_date, opname_number from inv_stock_opnames where status = 'posted' loop
    perform fin_post_stock_document_journal(r.company_id, 'inv_stock_opnames', r.id, r.opname_date,
      r.opname_number, 'inventory_adjustment', 'stock_opname');
  end loop;
  for r in select id from pos_orders where status = 'paid' order by paid_at loop
    perform fin_post_sales_journal(r.id);
  end loop;
  update pur_goods_receipts g set due_date = g.receipt_date + s.payment_term_days
  from pur_suppliers s where s.id = g.supplier_id and g.status = 'posted' and g.due_date is null;
end $$;

-- =====================================================================
-- KUNCI FUNGSI INTERNAL
-- =====================================================================
revoke execute on function fin_setup_default_accounts(uuid)                                         from public, anon, authenticated;
revoke execute on function fin_account_id(uuid, text)                                               from public, anon, authenticated;
revoke execute on function fin_create_journal(uuid, uuid, date, text, uuid, text, jsonb)            from public, anon, authenticated;
revoke execute on function fin_stock_value(text, uuid)                                              from public, anon, authenticated;
revoke execute on function fin_post_sales_journal(uuid)                                             from public, anon, authenticated;
revoke execute on function fin_post_goods_receipt_journal(uuid)                                     from public, anon, authenticated;
revoke execute on function fin_post_stock_document_journal(uuid, text, uuid, date, text, text, text) from public, anon, authenticated;
revoke execute on function fin_post_opening_stock_journal(uuid)                                     from public, anon, authenticated;

-- >>>>>>>>>> migrations/008_crm_promotions.sql
-- =====================================================================
-- ERP RESTORAN - 008: PELANGGAN (MEMBER & POIN) + PROMO / VOUCHER
--   Permission baru: crm.manage (kelola pelanggan, promo, pengaturan poin)
-- =====================================================================

-- =====================================================================
-- TABEL
-- =====================================================================
create table crm_settings (
  company_id           uuid primary key references sys_companies(id),
  is_points_enabled    boolean not null default true,
  earn_amount          numeric(15,2) not null default 10000,  -- belanja Rp X = 1 poin
  redeem_value         numeric(15,2) not null default 100,    -- 1 poin = Rp Y
  min_redeem_points    int not null default 100,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (earn_amount > 0 and redeem_value >= 0 and min_redeem_points >= 0)
);

create table crm_membership_tiers (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  name               text not null,                 -- Regular, Silver, Gold
  min_total_spent    numeric(15,2) not null default 0,
  point_multiplier   numeric(5,2) not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_id, name)
);

create table crm_customers (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  code            text not null,
  name            text not null,
  phone           text not null check (phone ~ '^[0-9]{8,15}$'),   -- hanya angka, mis. 6281234567890
  email           text,
  birth_date      date,
  note            text,
  tier_id         uuid references crm_membership_tiers(id),
  points_balance  int not null default 0,
  total_spent     numeric(15,2) not null default 0,
  visit_count     int not null default 0,
  last_visit_at   timestamptz,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code),
  unique (company_id, phone)
);

create table crm_point_transactions (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  customer_id       uuid not null references crm_customers(id) on delete cascade,
  order_id          uuid references pos_orders(id),
  transaction_type  text not null,     -- earn / redeem / adjust
  points            int not null,      -- + masuk, - keluar
  balance_after     int not null,
  note              text,
  created_by        uuid references sys_users(id),
  created_at        timestamptz not null default now()
);

create index idx_crm_point_transactions_customer on crm_point_transactions(customer_id, created_at);

create table crm_promotions (
  id                        uuid primary key default gen_random_uuid(),
  company_id                uuid not null references sys_companies(id),
  name                      text not null,
  voucher_code              text,             -- null = promo otomatis
  discount_type             text not null default 'percent',   -- percent / amount
  discount_value            numeric(15,2) not null check (discount_value > 0),
  max_discount              numeric(15,2),    -- batas maksimal potongan (untuk persen)
  min_subtotal              numeric(15,2) not null default 0,
  start_date                date,
  end_date                  date,
  days_of_week              int[],            -- 1=Senin ... 7=Minggu, null = setiap hari
  start_time                time,             -- happy hour, null = sepanjang hari
  end_time                  time,
  outlet_ids                uuid[],           -- null = semua outlet
  sales_channels            text[],           -- null = semua kanal
  menu_item_ids             uuid[],           -- null & category null = semua menu
  menu_category_ids         uuid[],
  requires_member           boolean not null default false,
  usage_limit               int,              -- kuota total, null = tanpa batas
  usage_count               int not null default 0,
  per_customer_limit        int,
  is_active                 boolean not null default true,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  check (discount_type in ('percent', 'amount')),
  check (discount_type <> 'percent' or discount_value <= 100)
);

create unique index uq_crm_promotions_voucher on crm_promotions(company_id, upper(voucher_code)) where voucher_code is not null;

-- Kolom baru di order
alter table pos_orders add column customer_id      uuid references crm_customers(id);
alter table pos_orders add column promotion_id     uuid references crm_promotions(id);
alter table pos_orders add column promotion_amount numeric(15,2) not null default 0;
alter table pos_orders add column points_redeemed  int not null default 0;
alter table pos_orders add column points_amount    numeric(15,2) not null default 0;
alter table pos_orders add column points_earned    int not null default 0;
create index idx_pos_orders_customer on pos_orders(customer_id);

select sys_attach_updated_at_triggers();

select sys_apply_company_policies('crm_settings', 'crm.manage');
select sys_apply_company_policies('crm_membership_tiers', 'crm.manage');
select sys_apply_company_policies('crm_promotions', 'crm.manage');
select sys_apply_company_policies('crm_point_transactions');   -- hanya lewat fungsi
select sys_apply_company_policies('crm_customers', 'crm.manage');

-- Saldo poin & statistik tidak boleh diubah langsung
revoke update on crm_customers from authenticated, anon;
grant update (name, phone, email, birth_date, note, is_active) on crm_customers to authenticated;

-- =====================================================================
-- HELPER
-- =====================================================================
create or replace function crm_get_settings(p_company_id uuid)
returns crm_settings language plpgsql security definer set search_path = public as $$
declare v crm_settings%rowtype;
begin
  insert into crm_settings (company_id) values (p_company_id) on conflict do nothing;
  select * into v from crm_settings where company_id = p_company_id;
  return v;
end $$;

-- Daftarkan member (boleh dilakukan kasir dari POS)
create or replace function crm_register_customer(p_name text, p_phone text, p_email text default null, p_birth_date date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_phone   text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_cust    crm_customers%rowtype;
begin
  if not (sys_has_permission('pos.order') or sys_has_permission('crm.manage')) then
    raise exception 'Tidak punya izin mendaftarkan pelanggan';
  end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  if v_phone like '0%' then v_phone := '62' || substr(v_phone, 2); end if;
  if v_phone !~ '^[0-9]{8,15}$' then raise exception 'Nomor HP tidak valid'; end if;
  if exists (select 1 from crm_customers where company_id = v_company and phone = v_phone) then
    raise exception 'Nomor HP % sudah terdaftar', v_phone;
  end if;

  insert into crm_customers (company_id, code, name, phone, email, birth_date, tier_id)
  values (v_company, 'MBR-' || lpad(sys_next_sequence(v_company, 'MBR')::text, 6, '0'),
          trim(p_name), v_phone, nullif(trim(p_email), ''), p_birth_date,
          (select id from crm_membership_tiers where company_id = v_company order by min_total_spent limit 1))
  returning * into v_cust;
  return to_jsonb(v_cust);
end $$;

-- Cari member dari POS (kasir tidak perlu crm.manage)
create or replace function crm_search_customers(p_query text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'phone', c.phone,
                              'points_balance', c.points_balance, 'tier_name', t.name) x
    from crm_customers c left join crm_membership_tiers t on t.id = c.tier_id
    where c.company_id = sys_current_company_id() and c.is_active
      and (sys_has_permission('pos.order') or sys_has_permission('crm.manage'))
      and length(trim(coalesce(p_query, ''))) >= 2
      and (c.name ilike '%' || trim(p_query) || '%' or c.phone like '%' || regexp_replace(p_query, '[^0-9]', '', 'g') || '%'
           or c.code ilike '%' || trim(p_query) || '%')
    limit 20
  ) s
$$;

-- Hitung potongan sebuah promo untuk sebuah order. null = tidak memenuhi syarat.
create or replace function crm_calculate_promotion(p_order_id uuid, p_promotion_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare
  p          crm_promotions%rowtype;
  o          pos_orders%rowtype;
  v_local    timestamp;
  v_eligible numeric(15,2);
  v_disc     numeric(15,2);
begin
  select * into p from crm_promotions where id = p_promotion_id and is_active;
  if not found then return null; end if;
  select * into o from pos_orders where id = p_order_id and company_id = p.company_id;
  if not found then return null; end if;

  select now() at time zone timezone into v_local from sys_outlets where id = o.outlet_id;

  if p.start_date is not null and v_local::date < p.start_date then return null; end if;
  if p.end_date   is not null and v_local::date > p.end_date   then return null; end if;
  if p.days_of_week is not null and not (extract(isodow from v_local)::int = any(p.days_of_week)) then return null; end if;
  if p.start_time is not null and v_local::time < p.start_time then return null; end if;
  if p.end_time   is not null and v_local::time > p.end_time   then return null; end if;
  if p.outlet_ids is not null and not (o.outlet_id = any(p.outlet_ids)) then return null; end if;
  if p.sales_channels is not null and not (o.sales_channel = any(p.sales_channels)) then return null; end if;
  if p.usage_limit is not null and p.usage_count >= p.usage_limit then return null; end if;
  if p.requires_member and o.customer_id is null then return null; end if;
  if p.per_customer_limit is not null and o.customer_id is not null and (
       select count(*) from pos_orders
       where customer_id = o.customer_id and promotion_id = p.id and status = 'paid') >= p.per_customer_limit then
    return null;
  end if;

  select coalesce(sum(oi.line_total), 0) into v_eligible
  from pos_order_items oi join mst_menu_items mi on mi.id = oi.menu_item_id
  where oi.order_id = o.id and not oi.is_void
    and ((p.menu_item_ids is null and p.menu_category_ids is null)
         or mi.id = any(coalesce(p.menu_item_ids, '{}'))
         or mi.menu_category_id = any(coalesce(p.menu_category_ids, '{}')));

  if v_eligible <= 0 or v_eligible < p.min_subtotal then return null; end if;

  v_disc := case when p.discount_type = 'percent' then round(v_eligible * p.discount_value / 100)
                 else least(p.discount_value, v_eligible) end;
  if p.max_discount is not null then v_disc := least(v_disc, p.max_discount); end if;
  return v_disc;
end $$;

-- =====================================================================
-- HITUNG ULANG ORDER (versi baru: + promo + tukar poin)
--   subtotal - diskon manual - promo - poin -> + service -> + pajak -> pembulatan
--   Tanpa voucher, promo otomatis terbaik dipilih sendiri (mis. happy hour).
-- =====================================================================
create or replace function pos_recalculate_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order    pos_orders%rowtype;
  v_outlet   sys_outlets%rowtype;
  v_settings crm_settings%rowtype;
  v_sub      numeric(15,2);
  v_promo_id uuid;
  v_promo    numeric(15,2) := 0;
  v_points   numeric(15,2) := 0;
  v_base     numeric(15,2);
  v_service  numeric(15,2);
  v_tax      numeric(15,2);
  v_raw      numeric(15,2);
  v_total    numeric(15,2);
begin
  select * into v_order from pos_orders where id = p_order_id;
  select * into v_outlet from sys_outlets where id = v_order.outlet_id;
  v_settings := crm_get_settings(v_order.company_id);

  select coalesce(sum(line_total), 0) into v_sub
  from pos_order_items where order_id = p_order_id and not is_void;

  -- voucher yang dipilih kasir
  v_promo_id := v_order.promotion_id;
  if v_promo_id is not null and exists (select 1 from crm_promotions where id = v_promo_id and voucher_code is not null) then
    v_promo := crm_calculate_promotion(p_order_id, v_promo_id);
    if v_promo is null then v_promo_id := null; v_promo := 0; end if;   -- tidak lagi memenuhi syarat
  else
    v_promo_id := null;
  end if;

  -- promo otomatis terbaik
  if v_promo_id is null then
    select id, d into v_promo_id, v_promo from (
      select p.id, crm_calculate_promotion(p_order_id, p.id) d
      from crm_promotions p
      where p.company_id = v_order.company_id and p.is_active and p.voucher_code is null
    ) x where d is not null order by d desc limit 1;
    v_promo := coalesce(v_promo, 0);
  end if;

  v_promo := least(v_promo, greatest(v_sub - v_order.discount_amount, 0));

  if v_order.points_redeemed > 0 then
    v_points := least(v_order.points_redeemed * v_settings.redeem_value,
                      greatest(v_sub - v_order.discount_amount - v_promo, 0));
  end if;

  v_base    := greatest(v_sub - v_order.discount_amount - v_promo - v_points, 0);
  v_service := round(v_base * v_outlet.service_charge_rate / 100);
  v_tax     := round((v_base + v_service) * v_outlet.tax_rate / 100);
  v_raw     := v_base + v_service + v_tax;
  v_total   := case when v_outlet.rounding_unit > 1
                    then round(v_raw / v_outlet.rounding_unit) * v_outlet.rounding_unit
                    else v_raw end;

  update pos_orders set
    subtotal         = v_sub,
    promotion_id     = v_promo_id,
    promotion_amount = v_promo,
    points_amount    = v_points,
    service_amount   = v_service,
    tax_amount       = v_tax,
    rounding_amount  = v_total - v_raw,
    grand_total      = v_total
  where id = p_order_id;
end $$;

-- =====================================================================
-- FUNGSI POS UNTUK MEMBER / VOUCHER / POIN
-- =====================================================================
create or replace function pos_lock_open_order(p_order_id uuid)
returns pos_orders language plpgsql security definer set search_path = public as $$
declare v pos_orders%rowtype;
begin
  select * into v from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  return v;
end $$;

create or replace function pos_set_order_customer(p_order_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v pos_orders%rowtype;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);
  if p_customer_id is not null and not exists (
      select 1 from crm_customers where id = p_customer_id and company_id = v.company_id and is_active) then
    raise exception 'Pelanggan tidak ditemukan';
  end if;
  update pos_orders set customer_id = p_customer_id,
    points_redeemed = case when p_customer_id is distinct from v.customer_id then 0 else points_redeemed end,
    customer_name = coalesce((select name from crm_customers where id = p_customer_id), customer_name)
  where id = p_order_id;
  perform pos_recalculate_order(p_order_id);
  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

-- p_code null = hapus voucher
create or replace function pos_apply_voucher(p_order_id uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  v_promo crm_promotions%rowtype;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);

  if coalesce(trim(p_code), '') = '' then
    update pos_orders set promotion_id = null where id = p_order_id;
  else
    select * into v_promo from crm_promotions
    where company_id = v.company_id and upper(voucher_code) = upper(trim(p_code));
    if not found then raise exception 'Kode voucher tidak ditemukan'; end if;
    if crm_calculate_promotion(p_order_id, v_promo.id) is null then
      raise exception 'Voucher % tidak memenuhi syarat (cek periode, minimal belanja, member, atau kuota)', v_promo.voucher_code;
    end if;
    update pos_orders set promotion_id = v_promo.id where id = p_order_id;
  end if;

  perform pos_recalculate_order(p_order_id);
  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

create or replace function pos_redeem_points(p_order_id uuid, p_points int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  v_cust  crm_customers%rowtype;
  v_set   crm_settings%rowtype;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);
  v_set := crm_get_settings(v.company_id);
  p_points := coalesce(p_points, 0);

  if p_points > 0 then
    if not v_set.is_points_enabled then raise exception 'Program poin tidak aktif'; end if;
    if v.customer_id is null then raise exception 'Pilih member terlebih dahulu'; end if;
    select * into v_cust from crm_customers where id = v.customer_id;
    if p_points > v_cust.points_balance then raise exception 'Poin tidak cukup (saldo %)', v_cust.points_balance; end if;
    if p_points < v_set.min_redeem_points then raise exception 'Minimal tukar % poin', v_set.min_redeem_points; end if;
  end if;

  update pos_orders set points_redeemed = greatest(p_points, 0) where id = p_order_id;
  perform pos_recalculate_order(p_order_id);
  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

-- Koreksi / bonus poin manual
create or replace function crm_adjust_points(p_customer_id uuid, p_points int, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_cust crm_customers%rowtype;
begin
  if not sys_has_permission('crm.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(p_points, 0) = 0 then raise exception 'Jumlah poin tidak boleh 0'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Alasan wajib diisi'; end if;
  select * into v_cust from crm_customers
  where id = p_customer_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Pelanggan tidak ditemukan'; end if;
  if v_cust.points_balance + p_points < 0 then raise exception 'Saldo poin tidak boleh minus'; end if;

  update crm_customers set points_balance = points_balance + p_points where id = p_customer_id;
  insert into crm_point_transactions (company_id, customer_id, transaction_type, points, balance_after, note, created_by)
  values (v_cust.company_id, p_customer_id, 'adjust', p_points, v_cust.points_balance + p_points, trim(p_note), auth.uid());
  return v_cust.points_balance + p_points;
end $$;

-- =====================================================================
-- SAAT ORDER LUNAS: poin, statistik member, kuota promo
-- =====================================================================
create or replace function crm_post_order_paid(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o        pos_orders%rowtype;
  v_cust   crm_customers%rowtype;
  v_set    crm_settings%rowtype;
  v_mult   numeric;
  v_earned int := 0;
  v_balance int;
begin
  select * into o from pos_orders where id = p_order_id;

  if o.promotion_id is not null then
    update crm_promotions set usage_count = usage_count + 1 where id = o.promotion_id;
  end if;

  if o.customer_id is null then return; end if;
  select * into v_cust from crm_customers where id = o.customer_id for update;
  v_set := crm_get_settings(o.company_id);
  v_balance := v_cust.points_balance;

  if o.points_redeemed > 0 then
    if o.points_redeemed > v_balance then
      raise exception 'Poin member tidak cukup (saldo %, ditukar %)', v_balance, o.points_redeemed;
    end if;
    v_balance := v_balance - o.points_redeemed;
    insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
    values (o.company_id, o.customer_id, o.id, 'redeem', -o.points_redeemed, v_balance, 'Tukar poin ' || o.order_number, auth.uid());
  end if;

  if v_set.is_points_enabled then
    select coalesce(point_multiplier, 1) into v_mult from crm_membership_tiers where id = v_cust.tier_id;
    v_earned := floor((o.subtotal - o.discount_amount - o.promotion_amount - o.points_amount)
                      / v_set.earn_amount * coalesce(v_mult, 1));
    if v_earned > 0 then
      v_balance := v_balance + v_earned;
      insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
      values (o.company_id, o.customer_id, o.id, 'earn', v_earned, v_balance, 'Belanja ' || o.order_number, auth.uid());
    end if;
  end if;

  update pos_orders set points_earned = v_earned where id = o.id;

  update crm_customers c set
    points_balance = v_balance,
    total_spent    = c.total_spent + o.grand_total,
    visit_count    = c.visit_count + 1,
    last_visit_at  = now(),
    tier_id        = coalesce((select t.id from crm_membership_tiers t
                               where t.company_id = c.company_id and t.min_total_spent <= c.total_spent + o.grand_total
                               order by t.min_total_spent desc limit 1), c.tier_id)
  where c.id = o.customer_id;
end $$;

-- Jurnal penjualan: semua potongan (manual + promo + poin) masuk akun Diskon Penjualan
create or replace function fin_post_sales_journal(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o       pos_orders%rowtype;
  c       uuid;
  v_lines jsonb;
  v_cogs  numeric;
begin
  select * into o from pos_orders where id = p_order_id and status = 'paid';
  if not found then return; end if;
  if exists (select 1 from fin_journals where source_type = 'sales' and source_id = o.id) then return; end if;
  c := o.company_id;
  if not exists (select 1 from fin_accounts where company_id = c) then return; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'account_id', coalesce(m.account_id, fin_account_id(c, 'cash')),
           'debit', p.amount - p.change_amount, 'note', m.name)), '[]'::jsonb)
    into v_lines
  from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
  where p.order_id = o.id;

  v_cogs := -fin_stock_value('pos_orders', o.id);

  v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id', fin_account_id(c, 'sales_discount'),  'debit',  o.discount_amount + o.promotion_amount + o.points_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'sales_revenue'),   'credit', o.subtotal),
    jsonb_build_object('account_id', fin_account_id(c, 'service_revenue'), 'credit', o.service_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'tax_payable'),     'credit', o.tax_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'rounding'),        'credit', o.rounding_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'cogs'),            'debit',  v_cogs),
    jsonb_build_object('account_id', fin_account_id(c, 'inventory'),       'credit', v_cogs)
  );

  perform fin_create_journal(c, o.outlet_id, o.business_date, 'sales', o.id,
                             'Penjualan ' || o.order_number, v_lines);
end $$;

create or replace function pos_on_order_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform inv_post_order_consumption(new.id);
  perform crm_post_order_paid(new.id);
  perform fin_post_sales_journal(new.id);
  return new;
end $$;

-- =====================================================================
-- DATA AWAL & PERMISSION
-- =====================================================================
create or replace function crm_setup_defaults(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform crm_get_settings(p_company_id);
  insert into crm_membership_tiers (company_id, name, min_total_spent, point_multiplier) values
    (p_company_id, 'Regular', 0, 1),
    (p_company_id, 'Silver',  1000000, 1.25),
    (p_company_id, 'Gold',    5000000, 1.5)
  on conflict do nothing;
end $$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop
    perform crm_setup_defaults(r.id);
  end loop;
end $$;

-- Perusahaan baru: bungkus lagi fungsi onboarding
alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v2;
revoke execute on function sys_onboard_company_v2(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v2(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform crm_setup_defaults((v_result->>'company_id')::uuid);
  if p_with_demo_data then
    insert into crm_promotions (company_id, name, discount_type, discount_value, days_of_week, start_time, end_time, sales_channels)
    values ((v_result->>'company_id')::uuid, 'Happy Hour 14:00-17:00', 'percent', 15, '{1,2,3,4,5}', '14:00', '17:00', '{dine_in,takeaway}');
    insert into crm_promotions (company_id, name, voucher_code, discount_type, discount_value, min_subtotal, requires_member, per_customer_limit)
    values ((v_result->>'company_id')::uuid, 'Member Baru Rp 20.000', 'WELCOME20', 'amount', 20000, 75000, true, 1);
  end if;
  return v_result;
end $$;

update sys_roles set permissions = permissions || '["crm.manage"]'::jsonb
where code = 'manager' and not permissions ? 'crm.manage';

revoke execute on function crm_get_settings(uuid)                    from public, anon, authenticated;
revoke execute on function crm_calculate_promotion(uuid, uuid)       from public, anon, authenticated;
revoke execute on function crm_post_order_paid(uuid)                 from public, anon, authenticated;
revoke execute on function crm_setup_defaults(uuid)                  from public, anon, authenticated;
revoke execute on function pos_lock_open_order(uuid)                 from public, anon, authenticated;
revoke execute on function fin_post_sales_journal(uuid)              from public, anon, authenticated;

-- >>>>>>>>>> migrations/009_qr_order.sql
-- =====================================================================
-- ERP RESTORAN - 009: QR SELF-ORDER
--   Tamu scan QR meja -> lihat menu -> pesan. Tanpa login.
--   Item dari QR berstatus 'waiting' sampai kasir konfirmasi
--   (bisa dimatikan per outlet: qr_requires_confirmation = false).
-- =====================================================================

alter table mst_tables add column qr_token text not null default replace(gen_random_uuid()::text, '-', '');
create unique index uq_mst_tables_qr_token on mst_tables(qr_token);

alter table sys_outlets add column is_qr_order_enabled      boolean not null default true;
alter table sys_outlets add column qr_requires_confirmation boolean not null default true;

alter table pos_orders add column order_source text not null default 'pos';   -- pos / qr

-- =====================================================================
-- INTERNAL: buat header order & tambah item (dipakai POS dan QR)
-- =====================================================================
create or replace function pos_create_order_header(
  p_outlet_id uuid, p_table_id uuid, p_sales_channel text, p_customer_name text, p_guest_count int,
  p_note text, p_customer_id uuid, p_order_source text, p_created_by uuid
)
returns pos_orders language plpgsql security definer set search_path = public as $$
declare
  v_outlet sys_outlets%rowtype;
  v_date   date;
  v_key    text;
  v_order  pos_orders%rowtype;
begin
  select * into v_outlet from sys_outlets where id = p_outlet_id;
  v_date := sys_outlet_business_date(p_outlet_id);
  v_key := 'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD');

  insert into pos_orders (
    company_id, outlet_id, table_id, order_number, business_date, sales_channel,
    customer_name, guest_count, note, created_by, customer_id, order_source, shift_id
  ) values (
    v_outlet.company_id, p_outlet_id, p_table_id,
    v_key || '/' || lpad(sys_next_sequence(v_outlet.company_id, v_key)::text, 4, '0'),
    v_date, coalesce(nullif(p_sales_channel, ''), 'dine_in'),
    nullif(trim(p_customer_name), ''), coalesce(p_guest_count, 1), nullif(p_note, ''), p_created_by,
    p_customer_id, p_order_source,
    (select id from pos_shifts where outlet_id = p_outlet_id and user_id = p_created_by and status = 'open' limit 1)
  ) returning * into v_order;

  if p_table_id is not null then
    update mst_tables set status = 'occupied' where id = p_table_id and outlet_id = p_outlet_id;
  end if;
  return v_order;
end $$;

-- items: [{ "menu_item_id", "quantity", "note", "modifier_ids": [] }]
create or replace function pos_add_order_items(p_order_id uuid, p_items jsonb, p_kitchen_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order     pos_orders%rowtype;
  v_item      jsonb;
  v_menu      mst_menu_items%rowtype;
  v_price     numeric(15,2);
  v_mod_total numeric(15,2);
  v_qty       numeric(10,2);
  v_line_id   uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  if jsonb_array_length(coalesce(p_items, '[]')) = 0 then raise exception 'Order tidak punya item'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Terlalu banyak item dalam satu pesanan'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_menu from mst_menu_items
    where id = (v_item->>'menu_item_id')::uuid and company_id = v_order.company_id and is_active;
    if not found then raise exception 'Menu tidak ditemukan / tidak aktif'; end if;

    v_qty := coalesce((v_item->>'quantity')::numeric, 1);
    if v_qty <= 0 or v_qty > 99 then raise exception 'Jumlah tidak valid'; end if;

    v_price := coalesce(
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id = v_order.outlet_id and sales_channel = v_order.sales_channel),
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id is null and sales_channel = v_order.sales_channel),
      v_menu.base_price);

    -- hanya modifier yang memang terhubung ke menu ini
    select coalesce(sum(m.extra_price), 0) into v_mod_total
    from mst_modifiers m
    join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id and l.menu_item_id = v_menu.id
    where m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);

    insert into pos_order_items (
      company_id, order_id, menu_item_id, menu_item_name, station,
      quantity, unit_price, modifier_amount, line_total, note, kitchen_status
    ) values (
      v_order.company_id, v_order.id, v_menu.id, v_menu.name, v_menu.station,
      v_qty, v_price, v_mod_total, v_qty * (v_price + v_mod_total),
      left(nullif(trim(v_item->>'note'), ''), 200), p_kitchen_status
    ) returning id into v_line_id;

    insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
    select v_order.company_id, v_line_id, m.id, m.name, m.extra_price
    from mst_modifiers m
    join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id and l.menu_item_id = v_menu.id
    where m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);
  end loop;

  perform pos_recalculate_order(v_order.id);
end $$;

-- =====================================================================
-- POS: simpan order (versi baru, mendukung customer_id)
-- =====================================================================
create or replace function pos_save_order(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company     uuid := sys_current_company_id();
  v_order_id    uuid := nullif(p_payload->>'order_id', '')::uuid;
  v_outlet_id   uuid;
  v_customer_id uuid := nullif(p_payload->>'customer_id', '')::uuid;
  v_order       pos_orders%rowtype;
begin
  if v_company is null then raise exception 'Anda belum login'; end if;
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin membuat order'; end if;

  if v_customer_id is not null and not exists (
      select 1 from crm_customers where id = v_customer_id and company_id = v_company and is_active) then
    raise exception 'Pelanggan tidak ditemukan';
  end if;

  if v_order_id is null then
    v_outlet_id := (p_payload->>'outlet_id')::uuid;
    if not sys_can_access_outlet(v_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
    v_order := pos_create_order_header(
      v_outlet_id, nullif(p_payload->>'table_id', '')::uuid, p_payload->>'sales_channel',
      coalesce(nullif(p_payload->>'customer_name', ''), (select name from crm_customers where id = v_customer_id)),
      (p_payload->>'guest_count')::int, p_payload->>'note', v_customer_id, 'pos', auth.uid());
  else
    select * into v_order from pos_orders where id = v_order_id and company_id = v_company for update;
    if not found then raise exception 'Order tidak ditemukan'; end if;
    if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  end if;

  perform pos_add_order_items(v_order.id, p_payload->'items', 'pending');

  select * into v_order from pos_orders where id = v_order.id;
  return to_jsonb(v_order);
end $$;

-- Kasir mengonfirmasi item dari QR -> diteruskan ke dapur
create or replace function pos_confirm_qr_items(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  update pos_order_items set kitchen_status = 'pending'
  where order_id = p_order_id and kitchen_status = 'waiting' and company_id = sys_current_company_id();
end $$;

create or replace function pos_regenerate_table_qr(p_table_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text := replace(gen_random_uuid()::text, '-', '');
begin
  if not sys_has_permission('master.manage') then raise exception 'Tidak punya izin'; end if;
  update mst_tables set qr_token = v_token where id = p_table_id and company_id = sys_current_company_id();
  if not found then raise exception 'Meja tidak ditemukan'; end if;
  return v_token;
end $$;

-- =====================================================================
-- PUBLIK (tanpa login) - diakses dengan token QR meja
-- =====================================================================
create or replace function public_get_table_menu(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_table  mst_tables%rowtype;
  v_outlet sys_outlets%rowtype;
begin
  select * into v_table from mst_tables where qr_token = p_token;
  if not found then raise exception 'QR tidak valid. Silakan minta bantuan pelayan.'; end if;
  select * into v_outlet from sys_outlets where id = v_table.outlet_id;
  if not v_outlet.is_active or not v_outlet.is_qr_order_enabled then
    raise exception 'Pemesanan lewat QR sedang tidak tersedia.';
  end if;

  return jsonb_build_object(
    'outlet', jsonb_build_object('name', v_outlet.name, 'tax_rate', v_outlet.tax_rate,
                                 'service_charge_rate', v_outlet.service_charge_rate,
                                 'requires_confirmation', v_outlet.qr_requires_confirmation),
    'company_name', (select name from sys_companies where id = v_outlet.company_id),
    'table', jsonb_build_object('code', v_table.code),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name)
      from mst_menu_categories c
      where c.company_id = v_outlet.company_id and c.brand_id = v_outlet.brand_id and c.is_active
        and exists (select 1 from mst_menu_items i where i.menu_category_id = c.id and i.is_active)), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'description', i.description, 'image_url', i.image_url,
        'menu_category_id', i.menu_category_id,
        'price', coalesce(
          (select price from mst_menu_prices where menu_item_id = i.id and outlet_id = v_outlet.id and sales_channel = 'dine_in'),
          (select price from mst_menu_prices where menu_item_id = i.id and outlet_id is null and sales_channel = 'dine_in'),
          i.base_price),
        'modifier_groups', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select,
            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'extra_price', m.extra_price)
                                                    order by m.sort_order) from mst_modifiers m where m.modifier_group_id = g.id), '[]'::jsonb)))
          from mst_menu_item_modifier_groups l join mst_modifier_groups g on g.id = l.modifier_group_id
          where l.menu_item_id = i.id), '[]'::jsonb)
      ) order by i.name)
      from mst_menu_items i
      where i.company_id = v_outlet.company_id and i.brand_id = v_outlet.brand_id and i.is_active), '[]'::jsonb)
  );
end $$;

-- Status pesanan yang sedang berjalan di meja ini
create or replace function public_get_table_order(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'grand_total', o.grand_total, 'subtotal', o.subtotal,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.menu_item_name, 'quantity', i.quantity, 'line_total', i.line_total, 'note', i.note,
        'kitchen_status', i.kitchen_status,
        'modifiers', (select coalesce(jsonb_agg(m.modifier_name), '[]'::jsonb) from pos_order_item_modifiers m where m.order_item_id = i.id))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb))
  from mst_tables t
  join pos_orders o on o.table_id = t.id and o.status = 'open'
  where t.qr_token = p_token
  order by o.created_at desc
  limit 1
$$;

-- p_items: [{ "menu_item_id", "quantity", "note", "modifier_ids": [] }]
create or replace function public_submit_table_order(p_token text, p_customer_name text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_table  mst_tables%rowtype;
  v_outlet sys_outlets%rowtype;
  v_order  pos_orders%rowtype;
  v_recent int;
begin
  select * into v_table from mst_tables where qr_token = p_token for update;
  if not found then raise exception 'QR tidak valid. Silakan minta bantuan pelayan.'; end if;
  select * into v_outlet from sys_outlets where id = v_table.outlet_id;
  if not v_outlet.is_active or not v_outlet.is_qr_order_enabled then
    raise exception 'Pemesanan lewat QR sedang tidak tersedia.';
  end if;

  -- batas anti-spam: maks 40 item dari QR per meja dalam 10 menit
  select count(*) into v_recent
  from pos_order_items i join pos_orders o on o.id = i.order_id
  where o.table_id = v_table.id and o.order_source = 'qr' and i.created_at > now() - interval '10 minutes';
  if v_recent + jsonb_array_length(coalesce(p_items, '[]')) > 40 then
    raise exception 'Terlalu banyak pesanan dalam waktu singkat. Silakan panggil pelayan.';
  end if;

  -- gabung ke order yang masih terbuka di meja ini, atau buat baru
  select * into v_order from pos_orders
  where table_id = v_table.id and status = 'open'
  order by created_at desc limit 1 for update;

  if not found then
    v_order := pos_create_order_header(v_outlet.id, v_table.id, 'dine_in', left(p_customer_name, 60), 1,
                                       null, null, 'qr', null);
  end if;

  perform pos_add_order_items(v_order.id, p_items,
    case when v_outlet.qr_requires_confirmation then 'waiting' else 'pending' end);

  return public_get_table_order(p_token);
end $$;

-- Order dengan item QR yang belum dikonfirmasi tidak boleh dibayar
create or replace function pos_check_unconfirmed_items()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from pos_order_items where order_id = new.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi. Konfirmasi atau void dulu sebelum bayar.';
  end if;
  return new;
end $$;

create trigger trg_pos_orders_check_unconfirmed
  before update of status on pos_orders
  for each row when (new.status = 'paid' and old.status is distinct from 'paid')
  execute function pos_check_unconfirmed_items();

-- =====================================================================
-- HAK EKSEKUSI
-- =====================================================================
revoke execute on function pos_create_order_header(uuid, uuid, text, text, int, text, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function pos_add_order_items(uuid, jsonb, text) from public, anon, authenticated;

grant execute on function public_get_table_menu(text)                  to anon, authenticated;
grant execute on function public_get_table_order(text)                 to anon, authenticated;
grant execute on function public_submit_table_order(text, text, jsonb) to anon, authenticated;

-- realtime untuk notifikasi pesanan QR (pos_order_items sudah terdaftar)

-- >>>>>>>>>> migrations/010_pos_extras.sql
-- =====================================================================
-- ERP RESTORAN - 010: FOTO MENU + KELENGKAPAN POS
--   * Foto menu (Supabase Storage, bucket publik "menu-images")
--   * Menu habis / sold out per outlet (reset otomatis hari berikutnya)
--   * Pindah meja, gabung bill, split bill
--   * Refund order lunas (balik stok opsional, poin member, jurnal)
--   Permission baru: pos.refund
-- =====================================================================

-- =====================================================================
-- FOTO MENU
-- File disimpan di menu-images/<company_id>/<nama-file>
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menu-images', 'menu-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy menu_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'menu-images'
              and (storage.foldername(name))[1] = sys_current_company_id()::text
              and sys_has_permission('master.manage'));
create policy menu_images_update on storage.objects for update to authenticated
  using (bucket_id = 'menu-images'
         and (storage.foldername(name))[1] = sys_current_company_id()::text
         and sys_has_permission('master.manage'));
create policy menu_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'menu-images'
         and (storage.foldername(name))[1] = sys_current_company_id()::text
         and sys_has_permission('master.manage'));

-- =====================================================================
-- MENU HABIS (SOLD OUT)
-- =====================================================================
create table mst_menu_sold_outs (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid not null references sys_outlets(id),
  menu_item_id   uuid not null references mst_menu_items(id) on delete cascade,
  business_date  date not null,
  created_by     uuid references sys_users(id),
  created_at     timestamptz not null default now(),
  unique (outlet_id, menu_item_id, business_date)
);

select sys_apply_company_policies('mst_menu_sold_outs');   -- ubah lewat fungsi
alter publication supabase_realtime add table mst_menu_sold_outs;

create or replace function pos_set_menu_sold_out(p_outlet_id uuid, p_menu_item_id uuid, p_is_sold_out boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_date date := sys_outlet_business_date(p_outlet_id);
begin
  if not (sys_has_permission('pos.order') or sys_has_permission('kds.update') or sys_has_permission('master.manage')) then
    raise exception 'Tidak punya izin';
  end if;
  if not sys_can_access_outlet(p_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if not exists (select 1 from mst_menu_items where id = p_menu_item_id and company_id = sys_current_company_id()) then
    raise exception 'Menu tidak ditemukan';
  end if;

  if p_is_sold_out then
    insert into mst_menu_sold_outs (company_id, outlet_id, menu_item_id, business_date, created_by)
    values (sys_current_company_id(), p_outlet_id, p_menu_item_id, v_date, auth.uid())
    on conflict do nothing;
  else
    delete from mst_menu_sold_outs
    where outlet_id = p_outlet_id and menu_item_id = p_menu_item_id and business_date = v_date;
  end if;
end $$;

-- Menu habis tidak bisa dipesan (POS maupun QR)
create or replace function pos_check_menu_available()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('erp.skip_availability_check', true), '') = 'on' then return new; end if;
  if exists (
    select 1 from mst_menu_sold_outs s join pos_orders o on o.id = new.order_id
    where s.menu_item_id = new.menu_item_id and s.outlet_id = o.outlet_id
      and s.business_date = sys_outlet_business_date(o.outlet_id)) then
    raise exception '% sedang habis', new.menu_item_name;
  end if;
  return new;
end $$;

create trigger trg_pos_order_items_available before insert on pos_order_items
  for each row execute function pos_check_menu_available();

-- Untuk halaman QR tamu
create or replace function public_get_sold_out_items(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s.menu_item_id), '[]'::jsonb)
  from mst_tables t
  join mst_menu_sold_outs s on s.outlet_id = t.outlet_id and s.business_date = sys_outlet_business_date(t.outlet_id)
  where t.qr_token = p_token
$$;
grant execute on function public_get_sold_out_items(text) to anon, authenticated;

-- =====================================================================
-- PINDAH MEJA
-- =====================================================================
create or replace function pos_free_table_if_empty(p_table_id uuid)
returns void language sql security definer set search_path = public as $$
  update mst_tables set status = 'available'
  where id = p_table_id and not exists (select 1 from pos_orders where table_id = p_table_id and status = 'open')
$$;

create or replace function pos_move_order_table(p_order_id uuid, p_table_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  v_old   uuid;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);
  if not exists (select 1 from mst_tables where id = p_table_id and outlet_id = v.outlet_id) then
    raise exception 'Meja tidak ditemukan di outlet ini';
  end if;
  v_old := v.table_id;

  update pos_orders set table_id = p_table_id, sales_channel = 'dine_in' where id = p_order_id;
  update mst_tables set status = 'occupied' where id = p_table_id;
  if v_old is not null and v_old <> p_table_id then perform pos_free_table_if_empty(v_old); end if;

  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

-- =====================================================================
-- GABUNG BILL: semua item order sumber pindah ke order tujuan
-- =====================================================================
create or replace function pos_merge_orders(p_target_order_id uuid, p_source_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t pos_orders%rowtype;
  s pos_orders%rowtype;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  if p_target_order_id = p_source_order_id then raise exception 'Pilih dua order yang berbeda'; end if;
  t := pos_lock_open_order(p_target_order_id);
  s := pos_lock_open_order(p_source_order_id);
  if t.outlet_id <> s.outlet_id then raise exception 'Order harus dari outlet yang sama'; end if;

  update pos_order_items set order_id = t.id where order_id = s.id;
  update pos_orders set guest_count = t.guest_count + s.guest_count where id = t.id;
  update pos_orders set status = 'merged', voided_at = now(), void_reason = 'Digabung ke ' || t.order_number
  where id = s.id;
  if s.table_id is not null then perform pos_free_table_if_empty(s.table_id); end if;

  perform pos_recalculate_order(t.id);
  perform pos_recalculate_order(s.id);
  select * into t from pos_orders where id = t.id;
  return to_jsonb(t);
end $$;

-- =====================================================================
-- SPLIT BILL: pindahkan sebagian item (boleh sebagian qty) ke order baru
-- p_items: [{ "order_item_id": uuid, "quantity": 1 }]
-- =====================================================================
create or replace function pos_split_order(p_order_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  n       pos_orders%rowtype;
  v_req   jsonb;
  v_line  pos_order_items%rowtype;
  v_qty   numeric(10,2);
  v_new   uuid;
  v_moved int := 0;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);

  n := pos_create_order_header(v.outlet_id, v.table_id, v.sales_channel, v.customer_name, 1,
                               'Split dari ' || v.order_number, null, v.order_source, auth.uid());
  -- item yang dipindah sudah dipesan sebelumnya, jadi tidak dicek ulang status habisnya
  perform set_config('erp.skip_availability_check', 'on', true);

  for v_req in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    select * into v_line from pos_order_items
    where id = (v_req->>'order_item_id')::uuid and order_id = p_order_id and not is_void
    for update;
    if not found then continue; end if;
    v_qty := least(coalesce((v_req->>'quantity')::numeric, v_line.quantity), v_line.quantity);
    if v_qty <= 0 then continue; end if;

    if v_qty = v_line.quantity then
      update pos_order_items set order_id = n.id where id = v_line.id;
    else
      update pos_order_items
         set quantity = quantity - v_qty, line_total = (quantity - v_qty) * (unit_price + modifier_amount)
       where id = v_line.id;
      insert into pos_order_items (company_id, order_id, menu_item_id, menu_item_name, station, quantity,
        unit_price, modifier_amount, line_total, note, kitchen_status, created_at)
      values (v_line.company_id, n.id, v_line.menu_item_id, v_line.menu_item_name, v_line.station, v_qty,
        v_line.unit_price, v_line.modifier_amount, v_qty * (v_line.unit_price + v_line.modifier_amount),
        v_line.note, v_line.kitchen_status, v_line.created_at)
      returning id into v_new;
      insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
      select company_id, v_new, modifier_id, modifier_name, extra_price
      from pos_order_item_modifiers where order_item_id = v_line.id;
    end if;
    v_moved := v_moved + 1;
  end loop;

  perform set_config('erp.skip_availability_check', 'off', true);

  if v_moved = 0 then raise exception 'Pilih item yang mau dipisah'; end if;
  if not exists (select 1 from pos_order_items where order_id = p_order_id and not is_void) then
    raise exception 'Sisakan minimal satu item di bill asal';
  end if;

  perform pos_recalculate_order(p_order_id);
  perform pos_recalculate_order(n.id);
  select * into n from pos_orders where id = n.id;
  return to_jsonb(n);
end $$;

-- =====================================================================
-- REFUND ORDER LUNAS (penuh)
-- =====================================================================
create table pos_refunds (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid not null references sys_outlets(id),
  order_id       uuid not null unique references pos_orders(id),
  shift_id       uuid references pos_shifts(id),
  refund_number  text not null,
  business_date  date not null,
  amount         numeric(15,2) not null,
  reason         text not null,
  is_stock_returned boolean not null default false,
  refunded_by    uuid references sys_users(id),
  refunded_at    timestamptz not null default now(),
  created_at     timestamptz not null default now()
);

create table pos_refund_payments (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  refund_id          uuid not null references pos_refunds(id) on delete cascade,
  payment_method_id  uuid not null references mst_payment_methods(id),
  amount             numeric(15,2) not null,
  created_at         timestamptz not null default now()
);

alter table pos_orders add column refunded_at timestamptz;

select sys_apply_company_policies('pos_refunds');
select sys_apply_company_policies('pos_refund_payments');

create or replace function pos_refund_order(p_order_id uuid, p_reason text, p_return_stock boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o         pos_orders%rowtype;
  r         pos_refunds%rowtype;
  v_shift   uuid;
  v_date    date;
  v_cust    crm_customers%rowtype;
  v_deduct  int;
  v_balance int;
  v_journal uuid;
  v_lines   jsonb;
begin
  if not sys_has_permission('pos.refund') then raise exception 'Tidak punya izin refund'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan refund wajib diisi'; end if;

  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if o.status <> 'paid' then raise exception 'Hanya order lunas yang bisa direfund'; end if;

  select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = auth.uid() and status = 'open' limit 1;
  if v_shift is null and exists (
      select 1 from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
      where p.order_id = o.id and m.type = 'cash') then
    raise exception 'Buka shift kasir dulu (uang tunai dikembalikan dari laci)';
  end if;
  v_date := sys_outlet_business_date(o.outlet_id);

  insert into pos_refunds (company_id, outlet_id, order_id, shift_id, refund_number, business_date, amount,
                           reason, is_stock_returned, refunded_by)
  values (o.company_id, o.outlet_id, o.id, v_shift, sys_next_document_number(o.company_id, 'RFD', v_date), v_date,
          o.grand_total, trim(p_reason), coalesce(p_return_stock, false), auth.uid())
  returning * into r;

  -- uang kembali lewat metode bayar semula
  insert into pos_refund_payments (company_id, refund_id, payment_method_id, amount)
  select o.company_id, r.id, payment_method_id, amount - change_amount
  from pos_payments where order_id = o.id;

  update pos_orders set status = 'refunded', refunded_at = now() where id = o.id;

  -- stok dikembalikan (mis. salah input, makanan belum dibuat)
  if p_return_stock then
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, note, created_by)
    select company_id, warehouse_id, item_id, 'sales_return', -quantity, unit_cost,
           'pos_refunds', r.id, r.refund_number, 'Refund ' || o.order_number, auth.uid()
    from inv_stock_movements where reference_type = 'pos_orders' and reference_id = o.id;
  end if;

  -- member: tarik poin yang didapat, kembalikan poin yang ditukar
  if o.customer_id is not null then
    select * into v_cust from crm_customers where id = o.customer_id for update;
    v_deduct := least(o.points_earned, v_cust.points_balance + o.points_redeemed);
    v_balance := v_cust.points_balance + o.points_redeemed - v_deduct;
    if o.points_redeemed - v_deduct <> 0 then
      insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
      values (o.company_id, o.customer_id, o.id, 'refund', o.points_redeemed - v_deduct, v_balance,
              'Refund ' || o.order_number, auth.uid());
    end if;
    update crm_customers set
      points_balance = v_balance,
      total_spent    = greatest(total_spent - o.grand_total, 0),
      visit_count    = greatest(visit_count - 1, 0)
    where id = o.customer_id;
  end if;

  if o.promotion_id is not null then
    update crm_promotions set usage_count = greatest(usage_count - 1, 0) where id = o.promotion_id;
  end if;

  -- jurnal balik dari jurnal penjualan (HPP ikut dibalik hanya bila stok dikembalikan)
  select id into v_journal from fin_journals where source_type = 'sales' and source_id = o.id;
  if v_journal is not null then
    select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'note', l.note))
      into v_lines
    from fin_journal_lines l join fin_accounts a on a.id = l.account_id
    where l.journal_id = v_journal
      and (p_return_stock or coalesce(a.system_key, '') not in ('cogs', 'inventory'));
    perform fin_create_journal(o.company_id, o.outlet_id, v_date, 'sales_refund', o.id,
                               'Refund ' || o.order_number || ' - ' || trim(p_reason), v_lines);
  end if;

  return to_jsonb(r);
end $$;

-- Tutup shift: kas = modal + tunai masuk - refund tunai
create or replace function pos_close_shift(p_shift_id uuid, p_closing_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shift    pos_shifts%rowtype;
  v_cash_in  numeric(15,2);
  v_cash_out numeric(15,2);
begin
  select * into v_shift from pos_shifts
  where id = p_shift_id and user_id = auth.uid() and status = 'open' for update;
  if not found then raise exception 'Shift tidak ditemukan / sudah ditutup'; end if;

  select coalesce(sum(p.amount - p.change_amount), 0) into v_cash_in
  from pos_payments p
  join pos_orders o on o.id = p.order_id
  join mst_payment_methods m on m.id = p.payment_method_id
  where o.shift_id = p_shift_id and o.status in ('paid', 'refunded') and m.type = 'cash';

  select coalesce(sum(rp.amount), 0) into v_cash_out
  from pos_refund_payments rp
  join pos_refunds r on r.id = rp.refund_id
  join mst_payment_methods m on m.id = rp.payment_method_id
  where r.shift_id = p_shift_id and m.type = 'cash';

  update pos_shifts set
    status        = 'closed',
    closed_at     = now(),
    closing_cash  = p_closing_cash,
    expected_cash = v_shift.opening_cash + v_cash_in - v_cash_out
  where id = p_shift_id
  returning * into v_shift;

  return to_jsonb(v_shift) || jsonb_build_object('difference', v_shift.closing_cash - v_shift.expected_cash);
end $$;

-- Laporan refund & void (audit kasir)
create view rpt_refunds with (security_invoker = true) as
select r.company_id, r.outlet_id, r.business_date, r.refund_number, o.order_number, r.amount, r.reason,
       r.is_stock_returned, r.refunded_at, u.full_name as refunded_by_name
from pos_refunds r
join pos_orders o on o.id = r.order_id
left join sys_users u on u.id = r.refunded_by;

create view rpt_voids with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date, o.order_number, 'order' as void_type,
       o.subtotal as amount, o.void_reason as reason, o.voided_at
from pos_orders o where o.status = 'void'
union all
select o.company_id, o.outlet_id, o.business_date, o.order_number, 'item',
       i.line_total, substring(i.note from '\[VOID: (.*)\]'), i.updated_at
from pos_order_items i join pos_orders o on o.id = i.order_id
where i.is_void and o.status <> 'void';

update sys_roles set permissions = permissions || '["pos.refund"]'::jsonb
where code = 'manager' and not permissions ? 'pos.refund';

revoke execute on function pos_free_table_if_empty(uuid) from public, anon, authenticated;

-- >>>>>>>>>> migrations/011_branding_profiles_activity.sql
-- =====================================================================
-- ERP RESTORAN - 011: LOGO PERUSAHAAN, PROFIL USER, LOG AKTIVITAS
--   Permission baru: audit.view (melihat log aktivitas)
-- =====================================================================

-- =====================================================================
-- LOGO & DATA PERUSAHAAN
-- =====================================================================
alter table sys_companies add column logo_url text;
alter table sys_companies add column phone    text;
alter table sys_companies add column email    text;
alter table sys_companies add column address  text;

-- =====================================================================
-- PROFIL USER: foto & nomor HP
-- =====================================================================
alter table sys_users add column phone      text;
alter table sys_users add column avatar_url text;

-- Bucket aset perusahaan:
--   <company_id>/logo/...            -> butuh settings.manage
--   <company_id>/avatars/<user_id>-* -> user sendiri, atau user.manage
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('company-assets', 'company-assets', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function sys_can_write_company_asset(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (
       ((storage.foldername(p_name))[2] = 'logo' and sys_has_permission('settings.manage'))
       or ((storage.foldername(p_name))[2] = 'avatars'
           and (left(storage.filename(p_name), 36) = auth.uid()::text or sys_has_permission('user.manage')))
     )
$$;

create policy company_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'company-assets' and sys_can_write_company_asset(name));
create policy company_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'company-assets' and sys_can_write_company_asset(name));
create policy company_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'company-assets' and sys_can_write_company_asset(name));

-- Ubah profil sendiri
create or replace function sys_update_my_profile(p_full_name text, p_phone text, p_avatar_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Anda belum login'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  update sys_users set
    full_name  = trim(p_full_name),
    phone      = nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), ''),
    avatar_url = nullif(trim(p_avatar_url), '')
  where id = auth.uid();
end $$;

-- Owner / admin mengubah profil user lain
create or replace function sys_update_user_profile(p_user_id uuid, p_full_name text, p_phone text, p_avatar_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  update sys_users set
    full_name  = trim(p_full_name),
    phone      = nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), ''),
    avatar_url = nullif(trim(p_avatar_url), '')
  where id = p_user_id and company_id = sys_current_company_id();
  if not found then raise exception 'User tidak ditemukan'; end if;
end $$;

-- Profil login (versi baru: + foto, HP, logo perusahaan)
create or replace function sys_get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', u.id,
    'full_name', u.full_name,
    'phone', u.phone,
    'avatar_url', u.avatar_url,
    'email', (select email from auth.users where id = u.id),
    'company_id', c.id,
    'company_name', c.name,
    'company_logo_url', c.logo_url,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

-- =====================================================================
-- LOG AKTIVITAS
-- =====================================================================
create table sys_activity_logs (
  id            bigint generated always as identity primary key,
  company_id    uuid not null references sys_companies(id),
  user_id       uuid references sys_users(id) on delete set null,
  user_name     text,          -- snapshot nama saat kejadian
  action        text not null, -- login / create / update / delete / paid / void / refunded / approve / ...
  entity_type   text not null, -- nama tabel, mis. mst_menu_items
  entity_id     uuid,
  entity_label  text,          -- mis. "Nasi Goreng Spesial", "INV/OUT01/..."
  changes       jsonb,         -- { kolom: [lama, baru] }
  created_at    timestamptz not null default now()
);

create index idx_sys_activity_logs_company on sys_activity_logs(company_id, created_at desc);
create index idx_sys_activity_logs_entity  on sys_activity_logs(entity_type, entity_id);
create index idx_sys_activity_logs_user    on sys_activity_logs(user_id, created_at desc);

alter table sys_activity_logs enable row level security;
create policy sys_activity_logs_select on sys_activity_logs for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('audit.view') or sys_has_permission('user.manage')));

create or replace function sys_log_activity(
  p_company_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_label text, p_changes jsonb default null
)
returns void language sql security definer set search_path = public as $$
  insert into sys_activity_logs (company_id, user_id, user_name, action, entity_type, entity_id, entity_label, changes)
  values (p_company_id, auth.uid(), (select full_name from sys_users where id = auth.uid()),
          p_action, p_entity_type, p_entity_id, left(p_label, 200), p_changes)
$$;

-- Dipanggil aplikasi sekali setiap login
create or replace function sys_log_login()
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if v_company is null then return; end if;
  -- tidak dobel bila halaman dimuat ulang dalam 30 menit
  if exists (select 1 from sys_activity_logs where user_id = auth.uid() and action = 'login'
             and created_at > now() - interval '30 minutes') then return; end if;
  perform sys_log_activity(v_company, 'login', 'sys_users', auth.uid(), (select full_name from sys_users where id = auth.uid()));
end $$;

create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'email', au.email, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

-- Trigger audit umum. TG_ARGV[0] = kolom yang diabaikan (dipisah koma)
create or replace function sys_audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_ignore  text[] := array['updated_at', 'created_at'] || string_to_array(coalesce(tg_argv[0], ''), ',');
  v_changes jsonb;
  v_action  text := lower(tg_op);
  v_company uuid;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(k, jsonb_build_array(v_old->k, v_new->k)) into v_changes
    from jsonb_object_keys(v_new) k
    where not (k = any(v_ignore)) and (v_old->k) is distinct from (v_new->k);
    if v_changes is null then return null; end if;
    -- perubahan status dicatat sebagai aksinya (paid, void, posted, approved, ...)
    if v_changes ? 'status' then v_action := v_new->>'status'; end if;
  elsif tg_op = 'INSERT' then
    v_changes := null;
  end if;

  v_company := coalesce((v_row->>'company_id')::uuid,
                        case when tg_table_name = 'sys_companies' then (v_row->>'id')::uuid end);
  if v_company is null then return null; end if;

  perform sys_log_activity(
    v_company, v_action, tg_table_name, (v_row->>'id')::uuid,
    coalesce(v_row->>'order_number', v_row->>'po_number', v_row->>'receipt_number', v_row->>'adjustment_number',
             v_row->>'opname_number', v_row->>'transfer_number', v_row->>'full_name', v_row->>'name',
             v_row->>'code', v_row->>'menu_item_name', v_row->>'email'),
    v_changes);
  return null;
end $$;

-- Pasang audit ke tabel-tabel penting
do $$
declare r record;
begin
  for r in select * from (values
    ('sys_companies', ''), ('sys_outlets', ''), ('sys_users', ''), ('sys_roles', ''), ('sys_user_invitations', ''),
    ('mst_menu_categories', ''), ('mst_menu_items', ''), ('mst_menu_prices', ''), ('mst_modifiers', ''),
    ('mst_payment_methods', ''), ('mst_tables', 'status'),
    ('inv_items', 'last_purchase_cost'), ('inv_recipe_items', ''), ('inv_warehouses', ''),
    ('inv_stock_adjustments', ''), ('inv_stock_opnames', ''), ('inv_stock_transfers', ''),
    ('pur_suppliers', ''), ('pur_purchase_orders', 'subtotal,grand_total'), ('pur_goods_receipts', 'grand_total,paid_amount'),
    ('crm_promotions', 'usage_count'), ('crm_settings', ''), ('crm_membership_tiers', ''),
    ('fin_accounts', ''), ('pos_shifts', '')
  ) as t(tbl, ignored) loop
    execute format(
      'create trigger %I after insert or update or delete on %I
       for each row execute function sys_audit_trigger(%L)',
      'trg_' || r.tbl || '_audit', r.tbl, r.ignored);
  end loop;
end $$;

-- Order: hanya perubahan status (lunas, void, refund, digabung)
create trigger trg_pos_orders_audit after update of status on pos_orders
  for each row when (old.status is distinct from new.status)
  execute function sys_audit_trigger('subtotal,discount_amount,service_amount,tax_amount,rounding_amount,grand_total,promotion_id,promotion_amount,points_amount,points_earned,paid_at,voided_at,refunded_at,shift_id');

-- Item void
create trigger trg_pos_order_items_audit after update of is_void on pos_order_items
  for each row when (new.is_void and not old.is_void)
  execute function sys_audit_trigger('note,updated_at');

update sys_roles set permissions = permissions || '["audit.view"]'::jsonb
where code = 'manager' and not permissions ? 'audit.view';

revoke execute on function sys_log_activity(uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function sys_can_write_company_asset(text) from public, anon;

-- >>>>>>>>>> migrations/012_approvals.sql
-- =====================================================================
-- ERP RESTORAN - 012: SISTEM PERSETUJUAN (APPROVAL)
--   Jenis dokumen & permission penyetuju:
--     purchase_order   -> approval.purchase_order   (setujui PO)
--     expense          -> approval.expense          (catat biaya)
--     stock_adjustment -> approval.stock_adjustment (penyesuaian / waste)
--     stock_opname     -> approval.stock_opname     (hasil opname)
--     refund           -> approval.refund           (refund order)
--   Aturan per perusahaan: aktif/nonaktif + nominal minimal.
--   Bila butuh persetujuan, fungsi biasa membuat permintaan; aksi baru
--   dijalankan saat penyetuju menyetujui (sys_decide_approval).
-- =====================================================================

create table sys_approval_rules (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  document_type  text not null,
  min_amount     numeric(15,2) not null default 0,
  is_enabled     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, document_type),
  check (document_type in ('purchase_order', 'expense', 'stock_adjustment', 'stock_opname', 'refund'))
);

create table sys_approval_requests (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid references sys_outlets(id),
  document_type  text not null,
  document_id    uuid,
  title          text not null,
  amount         numeric(15,2) not null default 0,
  payload        jsonb not null default '{}',
  status         text not null default 'pending',   -- pending / approved / rejected / cancelled
  requested_by   uuid references sys_users(id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references sys_users(id),
  decided_at     timestamptz,
  decision_note  text,
  result         jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index idx_sys_approval_requests_pending on sys_approval_requests(company_id, status, requested_at desc);
create unique index uq_sys_approval_requests_open_doc on sys_approval_requests(document_type, document_id)
  where status = 'pending' and document_id is not null;

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('sys_approval_rules', 'settings.manage');

alter table sys_approval_requests enable row level security;
create policy sys_approval_requests_select on sys_approval_requests for select to authenticated
  using (company_id = sys_current_company_id()
         and (requested_by = auth.uid() or sys_has_permission('approval.' || document_type)));

alter publication supabase_realtime add table sys_approval_requests;

create trigger trg_sys_approval_requests_audit after update of status on sys_approval_requests
  for each row when (old.status is distinct from new.status)
  execute function sys_audit_trigger('decided_by,decided_at,result');

-- =====================================================================
-- HELPER
-- =====================================================================
create or replace function sys_approval_rule_applies(p_document_type text, p_amount numeric)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from sys_approval_rules
    where company_id = sys_current_company_id() and document_type = p_document_type
      and is_enabled and coalesce(p_amount, 0) >= min_amount)
$$;

-- true bila aksi ini perlu disetujui orang lain
create or replace function sys_approval_required(p_document_type text, p_amount numeric)
returns boolean language sql stable security definer set search_path = public as $$
  select sys_approval_rule_applies(p_document_type, p_amount)
     and not sys_has_permission('approval.' || p_document_type)
$$;

create or replace function sys_request_approval(
  p_document_type text, p_document_id uuid, p_outlet_id uuid, p_amount numeric, p_title text, p_payload jsonb default '{}'
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v sys_approval_requests%rowtype;
begin
  select * into v from sys_approval_requests
  where document_type = p_document_type and document_id = p_document_id and status = 'pending';
  if not found then
    insert into sys_approval_requests (company_id, outlet_id, document_type, document_id, title, amount, payload, requested_by)
    values (sys_current_company_id(), p_outlet_id, p_document_type, p_document_id, p_title, coalesce(p_amount, 0),
            coalesce(p_payload, '{}'), auth.uid())
    returning * into v;
    perform sys_log_activity(v.company_id, 'request_approval', 'sys_approval_requests', v.id, p_title, null);
  end if;
  return jsonb_build_object('pending_approval', true, 'approval_request_id', v.id, 'title', v.title, 'amount', v.amount);
end $$;

-- Tutup permintaan yang masih terbuka ketika dokumen disetujui langsung oleh penyetuju
create or replace function sys_close_approval(p_document_type text, p_document_id uuid)
returns void language sql security definer set search_path = public as $$
  update sys_approval_requests
     set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_note = 'Disetujui langsung dari dokumen'
   where document_type = p_document_type and document_id = p_document_id and status = 'pending'
$$;

-- =====================================================================
-- PURCHASE ORDER
-- =====================================================================
create or replace function pur_approve_purchase_order(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc   pur_purchase_orders%rowtype;
  v_total numeric(15,2);
begin
  if not (sys_has_permission('purchasing.manage') or sys_has_permission('approval.purchase_order')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from pur_purchase_orders
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'PO tidak ditemukan / bukan draft'; end if;
  if not exists (select 1 from pur_purchase_order_items where purchase_order_id = p_id) then
    raise exception 'PO belum punya item';
  end if;

  update pur_purchase_order_items set line_total = quantity * unit_price where purchase_order_id = p_id;
  v_total := (select coalesce(sum(line_total), 0) from pur_purchase_order_items where purchase_order_id = p_id) + v_doc.tax_amount;

  if sys_approval_required('purchase_order', v_total) then
    if v_doc.status = 'pending_approval' then raise exception 'PO ini masih menunggu persetujuan'; end if;
    update pur_purchase_orders set status = 'pending_approval', subtotal = v_total - tax_amount, grand_total = v_total
    where id = p_id returning * into v_doc;
    return to_jsonb(v_doc) || sys_request_approval('purchase_order', p_id, null, v_total,
      'PO ' || (select name from pur_suppliers where id = v_doc.supplier_id) || ' ' || to_char(v_total, 'FM999G999G999'), '{}');
  end if;

  update pur_purchase_orders set
    po_number   = coalesce(po_number, sys_next_document_number(company_id, 'PO', po_date)),
    subtotal    = v_total - tax_amount,
    grand_total = v_total,
    status      = 'approved',
    approved_by = auth.uid(),
    approved_at = now()
  where id = p_id
  returning * into v_doc;

  perform sys_close_approval('purchase_order', p_id);
  return to_jsonb(v_doc);
end $$;

-- =====================================================================
-- BIAYA OPERASIONAL
-- =====================================================================
create or replace function fin_record_expense(
  p_date date, p_expense_account_id uuid, p_paid_from_account_id uuid,
  p_amount numeric, p_description text, p_outlet_id uuid default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.expense')) then raise exception 'Tidak punya izin'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Nominal harus lebih dari 0'; end if;
  if not exists (select 1 from fin_accounts where id = p_expense_account_id and company_id = v_company and not is_header)
     or not exists (select 1 from fin_accounts where id = p_paid_from_account_id and company_id = v_company and not is_header) then
    raise exception 'Akun tidak valid';
  end if;

  -- butuh persetujuan: simpan permintaan, jurnal dibuat saat disetujui (fungsi ini mengembalikan null)
  if sys_approval_required('expense', p_amount) then
    perform sys_request_approval('expense', null, p_outlet_id, p_amount,
      coalesce(nullif(trim(p_description), ''), 'Biaya operasional'),
      jsonb_build_object('date', coalesce(p_date, current_date), 'expense_account_id', p_expense_account_id,
                         'paid_from_account_id', p_paid_from_account_id, 'amount', p_amount,
                         'description', p_description, 'outlet_id', p_outlet_id));
    return null;
  end if;

  return fin_create_journal(v_company, p_outlet_id, coalesce(p_date, current_date), 'expense', null,
    coalesce(nullif(trim(p_description), ''), 'Biaya operasional'),
    jsonb_build_array(
      jsonb_build_object('account_id', p_expense_account_id, 'debit', p_amount),
      jsonb_build_object('account_id', p_paid_from_account_id, 'credit', p_amount)));
end $$;

-- =====================================================================
-- PENYESUAIAN STOK / WASTE / OPNAME
-- Nilai untuk aturan approval = |qty| x HPP rata-rata
-- =====================================================================
create or replace function inv_post_stock_adjustment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_adjustments%rowtype;
  v_value numeric(15,2);
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_adjustment')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from inv_stock_adjustments
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  select coalesce(sum(abs(i.quantity) * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
  from inv_stock_adjustment_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id
  where i.stock_adjustment_id = p_id;

  if sys_approval_required('stock_adjustment', v_value) then
    if v_doc.status = 'pending_approval' then raise exception 'Dokumen ini masih menunggu persetujuan'; end if;
    update inv_stock_adjustments set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_adjustment', p_id,
      (select outlet_id from inv_warehouses where id = v_doc.warehouse_id), v_value,
      (case when v_doc.adjustment_type = 'waste' then 'Waste' else 'Penyesuaian stok' end) || ' ' ||
        (select name from inv_warehouses where id = v_doc.warehouse_id), '{}');
    return;
  end if;

  v_doc.adjustment_number := coalesce(v_doc.adjustment_number,
    sys_next_document_number(v_doc.company_id, case when v_doc.adjustment_type = 'waste' then 'WST' else 'ADJ' end, v_doc.adjustment_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, note, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, v_doc.adjustment_type,
         case when v_doc.adjustment_type = 'waste' then -abs(i.quantity) else i.quantity end,
         'inv_stock_adjustments', v_doc.id, v_doc.adjustment_number, i.note, auth.uid()
  from inv_stock_adjustment_items i
  where i.stock_adjustment_id = p_id and i.quantity <> 0;

  update inv_stock_adjustments
     set status = 'posted', posted_at = now(), adjustment_number = v_doc.adjustment_number
   where id = p_id;
  perform sys_close_approval('stock_adjustment', p_id);
end $$;

create or replace function inv_post_stock_opname(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_opnames%rowtype;
  v_value numeric(15,2);
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_opname')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from inv_stock_opnames
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  select coalesce(sum(abs(i.counted_qty - coalesce(s.quantity, 0)) * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost)), 0)
    into v_value
  from inv_stock_opname_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id
  where i.stock_opname_id = p_id;

  if sys_approval_required('stock_opname', v_value) then
    if v_doc.status = 'pending_approval' then raise exception 'Dokumen ini masih menunggu persetujuan'; end if;
    update inv_stock_opnames set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_opname', p_id,
      (select outlet_id from inv_warehouses where id = v_doc.warehouse_id), v_value,
      'Stock opname ' || (select name from inv_warehouses where id = v_doc.warehouse_id), '{}');
    return;
  end if;

  v_doc.opname_number := coalesce(v_doc.opname_number,
    sys_next_document_number(v_doc.company_id, 'OPN', v_doc.opname_date));

  update inv_stock_opname_items i set
    system_qty = coalesce((select s.quantity from inv_stocks s
                           where s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id), 0)
  where i.stock_opname_id = p_id;

  update inv_stock_opname_items set difference_qty = counted_qty - system_qty
  where stock_opname_id = p_id;

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'opname', i.difference_qty,
         'inv_stock_opnames', v_doc.id, v_doc.opname_number, auth.uid()
  from inv_stock_opname_items i
  where i.stock_opname_id = p_id and i.difference_qty <> 0;

  update inv_stock_opnames
     set status = 'posted', posted_at = now(), opname_number = v_doc.opname_number
   where id = p_id;
  perform sys_close_approval('stock_opname', p_id);
end $$;

-- =====================================================================
-- REFUND
--   pos_refund_order_execute = proses refund (kas keluar dari shift p_cashier_id)
--   pos_refund_order         = pintu masuk: langsung, atau minta persetujuan
-- =====================================================================
create or replace function pos_refund_order_execute(p_order_id uuid, p_reason text, p_return_stock boolean, p_cashier_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o         pos_orders%rowtype;
  r         pos_refunds%rowtype;
  v_shift   uuid;
  v_date    date;
  v_cust    crm_customers%rowtype;
  v_deduct  int;
  v_balance int;
  v_journal uuid;
  v_lines   jsonb;
begin
  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if o.status <> 'paid' then raise exception 'Hanya order lunas yang bisa direfund'; end if;

  select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = p_cashier_id and status = 'open' limit 1;
  if v_shift is null and exists (
      select 1 from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
      where p.order_id = o.id and m.type = 'cash') then
    raise exception 'Kasir harus membuka shift dulu (uang tunai dikembalikan dari laci)';
  end if;
  v_date := sys_outlet_business_date(o.outlet_id);

  insert into pos_refunds (company_id, outlet_id, order_id, shift_id, refund_number, business_date, amount,
                           reason, is_stock_returned, refunded_by)
  values (o.company_id, o.outlet_id, o.id, v_shift, sys_next_document_number(o.company_id, 'RFD', v_date), v_date,
          o.grand_total, trim(p_reason), coalesce(p_return_stock, false), p_cashier_id)
  returning * into r;

  insert into pos_refund_payments (company_id, refund_id, payment_method_id, amount)
  select o.company_id, r.id, payment_method_id, amount - change_amount
  from pos_payments where order_id = o.id;

  update pos_orders set status = 'refunded', refunded_at = now() where id = o.id;

  if p_return_stock then
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, note, created_by)
    select company_id, warehouse_id, item_id, 'sales_return', -quantity, unit_cost,
           'pos_refunds', r.id, r.refund_number, 'Refund ' || o.order_number, auth.uid()
    from inv_stock_movements where reference_type = 'pos_orders' and reference_id = o.id;
  end if;

  if o.customer_id is not null then
    select * into v_cust from crm_customers where id = o.customer_id for update;
    v_deduct := least(o.points_earned, v_cust.points_balance + o.points_redeemed);
    v_balance := v_cust.points_balance + o.points_redeemed - v_deduct;
    if o.points_redeemed - v_deduct <> 0 then
      insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
      values (o.company_id, o.customer_id, o.id, 'refund', o.points_redeemed - v_deduct, v_balance,
              'Refund ' || o.order_number, auth.uid());
    end if;
    update crm_customers set
      points_balance = v_balance,
      total_spent    = greatest(total_spent - o.grand_total, 0),
      visit_count    = greatest(visit_count - 1, 0)
    where id = o.customer_id;
  end if;

  if o.promotion_id is not null then
    update crm_promotions set usage_count = greatest(usage_count - 1, 0) where id = o.promotion_id;
  end if;

  select id into v_journal from fin_journals where source_type = 'sales' and source_id = o.id;
  if v_journal is not null then
    select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'note', l.note))
      into v_lines
    from fin_journal_lines l join fin_accounts a on a.id = l.account_id
    where l.journal_id = v_journal
      and (p_return_stock or coalesce(a.system_key, '') not in ('cogs', 'inventory'));
    perform fin_create_journal(o.company_id, o.outlet_id, v_date, 'sales_refund', o.id,
                               'Refund ' || o.order_number || ' - ' || trim(p_reason), v_lines);
  end if;

  return to_jsonb(r);
end $$;

create or replace function pos_refund_order(p_order_id uuid, p_reason text, p_return_stock boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o pos_orders%rowtype;
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan refund wajib diisi'; end if;
  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id();
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if o.status <> 'paid' then raise exception 'Hanya order lunas yang bisa direfund'; end if;

  -- penyetuju refund, atau pemegang izin refund di bawah batas -> langsung
  if sys_has_permission('approval.refund')
     or (sys_has_permission('pos.refund') and not sys_approval_rule_applies('refund', o.grand_total)) then
    return pos_refund_order_execute(p_order_id, p_reason, p_return_stock, auth.uid());
  end if;

  -- selain itu boleh mengajukan bila aturan refund aktif
  if sys_has_permission('pos.order') and exists (
      select 1 from sys_approval_rules where company_id = o.company_id and document_type = 'refund' and is_enabled) then
    return sys_request_approval('refund', p_order_id, o.outlet_id, o.grand_total,
      'Refund ' || o.order_number || ' - ' || trim(p_reason),
      jsonb_build_object('reason', trim(p_reason), 'return_stock', coalesce(p_return_stock, false)));
  end if;

  raise exception 'Tidak punya izin refund';
end $$;

-- =====================================================================
-- KEPUTUSAN PENYETUJU
-- =====================================================================
create or replace function sys_revert_pending_document(p_document_type text, p_document_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_document_type = 'purchase_order' then
    update pur_purchase_orders set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_adjustment' then
    update inv_stock_adjustments set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_opname' then
    update inv_stock_opnames set status = 'draft' where id = p_document_id and status = 'pending_approval';
  end if;
end $$;

create or replace function sys_decide_approval(p_request_id uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        sys_approval_requests%rowtype;
  v_result jsonb;
begin
  select * into v from sys_approval_requests
  where id = p_request_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Permintaan tidak ditemukan'; end if;
  if v.status <> 'pending' then raise exception 'Permintaan sudah diputuskan'; end if;
  if not sys_has_permission('approval.' || v.document_type) then raise exception 'Anda tidak berwenang menyetujui ini'; end if;
  if v.requested_by = auth.uid() and not sys_has_permission('*') then
    raise exception 'Tidak bisa menyetujui permintaan sendiri';
  end if;

  if p_approve then
    if v.document_type = 'purchase_order' then
      v_result := pur_approve_purchase_order(v.document_id);
    elsif v.document_type = 'expense' then
      v_result := jsonb_build_object('journal_id', fin_record_expense(
        (v.payload->>'date')::date, (v.payload->>'expense_account_id')::uuid, (v.payload->>'paid_from_account_id')::uuid,
        (v.payload->>'amount')::numeric, v.payload->>'description', nullif(v.payload->>'outlet_id', '')::uuid));
    elsif v.document_type = 'stock_adjustment' then
      perform inv_post_stock_adjustment(v.document_id);
    elsif v.document_type = 'stock_opname' then
      perform inv_post_stock_opname(v.document_id);
    elsif v.document_type = 'refund' then
      v_result := pos_refund_order_execute(v.document_id, v.payload->>'reason',
                                           coalesce((v.payload->>'return_stock')::boolean, false), v.requested_by);
    end if;
  else
    perform sys_revert_pending_document(v.document_type, v.document_id);
  end if;

  update sys_approval_requests set
    status        = case when p_approve then 'approved' else 'rejected' end,
    decided_by    = auth.uid(),
    decided_at    = now(),
    decision_note = nullif(trim(p_note), ''),
    result        = v_result
  where id = p_request_id
  returning * into v;
  return to_jsonb(v);
end $$;

create or replace function sys_cancel_approval(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v sys_approval_requests%rowtype;
begin
  select * into v from sys_approval_requests
  where id = p_request_id and company_id = sys_current_company_id() and status = 'pending' for update;
  if not found then raise exception 'Permintaan tidak ditemukan / sudah diputuskan'; end if;
  if v.requested_by <> auth.uid() and not sys_has_permission('*') then raise exception 'Hanya pengaju yang bisa membatalkan'; end if;
  perform sys_revert_pending_document(v.document_type, v.document_id);
  update sys_approval_requests set status = 'cancelled', decided_by = auth.uid(), decided_at = now() where id = p_request_id;
end $$;

-- Jumlah permintaan yang menunggu keputusan saya (badge sidebar)
create or replace function sys_count_my_pending_approvals()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from sys_approval_requests
  where company_id = sys_current_company_id() and status = 'pending'
    and sys_has_permission('approval.' || document_type)
    and (requested_by is distinct from auth.uid() or sys_has_permission('*'))
$$;

-- =====================================================================
-- ATURAN DEFAULT (NONAKTIF) UNTUK SEMUA PERUSAHAAN
-- =====================================================================
create or replace function sys_setup_approval_rules(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into sys_approval_rules (company_id, document_type, min_amount, is_enabled) values
    (p_company_id, 'purchase_order',   5000000, false),
    (p_company_id, 'expense',          1000000, false),
    (p_company_id, 'stock_adjustment',  500000, false),
    (p_company_id, 'stock_opname',     1000000, false),
    (p_company_id, 'refund',                 0, false)
  on conflict do nothing
$$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform sys_setup_approval_rules(r.id); end loop;
end $$;

-- Perusahaan baru: aturan dibuat saat onboarding (trigger di sys_companies)
create or replace function sys_on_company_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform sys_setup_approval_rules(new.id);
  return new;
end $$;

create trigger trg_sys_companies_setup_approval after insert on sys_companies
  for each row execute function sys_on_company_insert();

-- Status PO baru
comment on column pur_purchase_orders.status is 'draft / pending_approval / approved / partially_received / received / cancelled';

revoke execute on function sys_approval_rule_applies(text, numeric)                      from public, anon, authenticated;
revoke execute on function sys_request_approval(text, uuid, uuid, numeric, text, jsonb)   from public, anon, authenticated;
revoke execute on function sys_close_approval(text, uuid)                                from public, anon, authenticated;
revoke execute on function sys_revert_pending_document(text, uuid)                       from public, anon, authenticated;
revoke execute on function sys_setup_approval_rules(uuid)                                from public, anon, authenticated;
revoke execute on function pos_refund_order_execute(uuid, text, boolean, uuid)           from public, anon, authenticated;

-- >>>>>>>>>> migrations/013_payment_gateway.sql
-- =====================================================================
-- ERP RESTORAN - 013: PAYMENT GATEWAY (disiapkan untuk iPay88)
--   Alur:
--   1. Kasir pilih "Bayar Online" -> pos_create_gateway_payment()  (buat RefNo)
--   2. Edge Function ipay88-checkout menandatangani request & mengembalikan
--      form ke halaman pembayaran iPay88
--   3. iPay88 memanggil Edge Function ipay88-callback (BackendURL)
--      -> verifikasi tanda tangan -> pos_complete_gateway_payment()
--      (hanya bisa dipanggil service_role)
--   Merchant key TIDAK pernah bisa dibaca dari aplikasi.
-- =====================================================================

create table sys_payment_gateways (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  provider          text not null default 'ipay88',
  environment       text not null default 'sandbox',        -- sandbox / production
  merchant_code     text,
  signature_method  text not null default 'hmac_sha512',    -- hmac_sha512 / sha256 (lihat dokumen iPay88 Anda)
  payment_ids       jsonb not null default '[]',            -- metode yang ditampilkan, mis. [{"id":"...","name":"QRIS"}]
  is_active         boolean not null default false,
  has_merchant_key  boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, provider),
  check (environment in ('sandbox', 'production')),
  check (signature_method in ('hmac_sha512', 'sha256'))
);

-- Rahasia: RLS aktif TANPA policy -> hanya service_role (Edge Function) yang bisa membaca
create table sys_payment_gateway_secrets (
  gateway_id    uuid primary key references sys_payment_gateways(id) on delete cascade,
  merchant_key  text not null,
  updated_at    timestamptz not null default now()
);
alter table sys_payment_gateway_secrets enable row level security;

create table pos_payment_requests (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  outlet_id       uuid not null references sys_outlets(id),
  order_id        uuid not null references pos_orders(id),
  gateway_id      uuid not null references sys_payment_gateways(id),
  ref_no          text not null unique,          -- dikirim ke iPay88 sebagai RefNo
  amount          numeric(15,2) not null,
  currency        text not null default 'IDR',
  payment_id      text,                          -- metode pilihan (kode iPay88)
  status          text not null default 'pending',   -- pending / success / failed / cancelled
  trans_id        text,                          -- TransId dari iPay88
  auth_code       text,
  error_desc      text,
  requested_by    uuid references sys_users(id),
  raw_response    jsonb,
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index idx_pos_payment_requests_order on pos_payment_requests(order_id);

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('sys_payment_gateways', 'settings.manage');
select sys_apply_company_policies('pos_payment_requests');   -- hanya lewat fungsi

-- flag has_merchant_key hanya diubah lewat sys_set_payment_gateway_secret
revoke update on sys_payment_gateways from authenticated, anon;
grant update (environment, merchant_code, signature_method, payment_ids, is_active) on sys_payment_gateways to authenticated;

-- Pembayaran metode gateway hanya boleh dicatat oleh callback (service_role, tanpa user login)
create or replace function pos_check_gateway_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and exists (
      select 1 from mst_payment_methods where id = new.payment_method_id and type = 'gateway') then
    raise exception 'Pembayaran online hanya bisa dicatat otomatis oleh iPay88';
  end if;
  return new;
end $$;

create trigger trg_pos_payments_gateway before insert on pos_payments
  for each row execute function pos_check_gateway_payment();

alter publication supabase_realtime add table pos_payment_requests;

create trigger trg_sys_payment_gateways_audit after insert or update on sys_payment_gateways
  for each row execute function sys_audit_trigger('');

-- Simpan / ganti merchant key (tulis saja, tidak bisa dibaca kembali)
create or replace function sys_set_payment_gateway_secret(p_gateway_id uuid, p_merchant_key text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('settings.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_merchant_key), '') = '' then raise exception 'Merchant key kosong'; end if;
  if not exists (select 1 from sys_payment_gateways where id = p_gateway_id and company_id = sys_current_company_id()) then
    raise exception 'Gateway tidak ditemukan';
  end if;
  insert into sys_payment_gateway_secrets (gateway_id, merchant_key) values (p_gateway_id, trim(p_merchant_key))
  on conflict (gateway_id) do update set merchant_key = excluded.merchant_key, updated_at = now();
  update sys_payment_gateways set has_merchant_key = true where id = p_gateway_id;
  perform sys_log_activity(sys_current_company_id(), 'update_secret', 'sys_payment_gateways', p_gateway_id, 'Merchant key iPay88', null);
end $$;

-- Metode bayar "Online (iPay88)" di POS dibuat otomatis saat gateway aktif
create or replace function sys_on_gateway_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_active then
    insert into mst_payment_methods (company_id, code, name, type, sort_order)
    values (new.company_id, new.provider, 'Online (iPay88)', 'gateway', 90)
    on conflict (company_id, code) do update set is_active = true;
  else
    update mst_payment_methods set is_active = false where company_id = new.company_id and code = new.provider;
  end if;
  return new;
end $$;

create trigger trg_sys_payment_gateways_method after insert or update of is_active on sys_payment_gateways
  for each row execute function sys_on_gateway_change();

-- =====================================================================
-- LANGKAH 1: kasir membuat permintaan pembayaran online
-- =====================================================================
create or replace function pos_create_gateway_payment(p_order_id uuid, p_payment_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o   pos_orders%rowtype;
  g   sys_payment_gateways%rowtype;
  r   pos_payment_requests%rowtype;
  n   int;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin menerima pembayaran'; end if;
  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found or o.status <> 'open' then raise exception 'Order tidak ditemukan / sudah ditutup'; end if;
  if o.grand_total <= 0 then raise exception 'Total order 0'; end if;
  if exists (select 1 from pos_order_items where order_id = o.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi';
  end if;
  if not exists (select 1 from pos_shifts where outlet_id = o.outlet_id and user_id = auth.uid() and status = 'open') then
    raise exception 'Buka shift kasir terlebih dahulu';
  end if;

  select * into g from sys_payment_gateways
  where company_id = o.company_id and provider = 'ipay88' and is_active and has_merchant_key and merchant_code is not null;
  if not found then raise exception 'Pembayaran online belum diaktifkan. Atur di Pengaturan > Pembayaran Online.'; end if;

  -- request lama yang masih pending untuk order ini dibatalkan (nominal bisa berubah)
  update pos_payment_requests set status = 'cancelled' where order_id = o.id and status = 'pending';

  select count(*) + 1 into n from pos_payment_requests where order_id = o.id;
  insert into pos_payment_requests (company_id, outlet_id, order_id, gateway_id, ref_no, amount, payment_id, requested_by)
  values (o.company_id, o.outlet_id, o.id, g.id,
          replace(o.order_number, '/', '') || '-' || n, o.grand_total, p_payment_id, auth.uid())
  returning * into r;
  return to_jsonb(r);
end $$;

-- =====================================================================
-- LANGKAH 3: dipanggil Edge Function setelah tanda tangan iPay88 valid
-- =====================================================================
create or replace function pos_complete_gateway_payment(
  p_ref_no text, p_success boolean, p_amount numeric, p_trans_id text, p_auth_code text,
  p_error_desc text, p_raw jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r        pos_payment_requests%rowtype;
  o        pos_orders%rowtype;
  v_method uuid;
  v_shift  uuid;
begin
  select * into r from pos_payment_requests where ref_no = p_ref_no for update;
  if not found then raise exception 'RefNo tidak dikenal: %', p_ref_no; end if;
  if r.status = 'success' then return to_jsonb(r); end if;   -- callback dobel: abaikan

  if not p_success then
    update pos_payment_requests set status = 'failed', error_desc = p_error_desc, raw_response = p_raw
    where id = r.id returning * into r;
    return to_jsonb(r);
  end if;

  if p_amount is distinct from r.amount then
    update pos_payment_requests set status = 'failed', error_desc = 'Nominal tidak cocok: ' || p_amount, raw_response = p_raw
    where id = r.id returning * into r;
    return to_jsonb(r);
  end if;

  select * into o from pos_orders where id = r.order_id for update;
  update pos_payment_requests set status = 'success', trans_id = p_trans_id, auth_code = p_auth_code,
         raw_response = p_raw, paid_at = now()
  where id = r.id returning * into r;

  -- uang sudah diterima gateway; tandai lunas meski order sempat berubah (dicatat untuk dicek)
  if o.status = 'open' then
    select id into v_method from mst_payment_methods where company_id = o.company_id and code = 'ipay88';
    select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = r.requested_by and status = 'open' limit 1;

    insert into pos_payments (company_id, order_id, payment_method_id, amount, reference_number)
    values (o.company_id, o.id, v_method, r.amount, coalesce(p_trans_id, r.ref_no));
    update pos_orders set status = 'paid', paid_at = now(), shift_id = coalesce(v_shift, shift_id) where id = o.id;
    if o.table_id is not null then
      update mst_tables set status = 'available'
      where id = o.table_id and not exists (select 1 from pos_orders where table_id = o.table_id and status = 'open');
    end if;
  end if;
  return to_jsonb(r);
end $$;

revoke execute on function pos_complete_gateway_payment(text, boolean, numeric, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function pos_complete_gateway_payment(text, boolean, numeric, text, text, text, jsonb) to service_role;

-- >>>>>>>>>> migrations/014_product_master.sql
-- =====================================================================
-- SANTAP ERP - 014: MASTER PRODUCT LENGKAP
--   * Satuan dengan metrik (unit / berat / volume)
--   * Kategori bertipe (Inventory / Non Inventory / Asset / Non Depreciated Asset)
--     + akun COA per kategori (persediaan, HPP, penjualan, selisih stok)
--   * Sub kategori
--   * Produk: flag beli/jual/request/PPN, toleransi terima, catatan, custom field
--   * Multi-unit: SKU, barcode, berat, volume, peran unit beli/transfer/jual
--   * Min/max stok per gudang/outlet (Branch Product) + salin antar gudang
--   * Approval produk baru
--   * Import produk & menu dari Excel (semua-atau-tidak, error per baris)
--   * Jurnal otomatis memakai akun per kategori
-- =====================================================================

-- =====================================================================
-- SATUAN
-- =====================================================================
alter table inv_units add column metric text not null default 'unit';
alter table inv_units add column notes text;
alter table inv_units add constraint inv_units_metric_check check (metric in ('unit', 'weight', 'volume'));
update inv_units set metric = 'weight' where lower(code) in ('g', 'gr', 'kg', 'mg', 'ons');
update inv_units set metric = 'volume' where lower(code) in ('ml', 'l', 'lt', 'liter', 'cc');

-- =====================================================================
-- KATEGORI & SUB KATEGORI
-- =====================================================================
alter table inv_item_categories add column code text;
alter table inv_item_categories add column category_type text not null default 'inventory';
alter table inv_item_categories add column inventory_account_id  uuid references fin_accounts(id);
alter table inv_item_categories add column cogs_account_id       uuid references fin_accounts(id);
alter table inv_item_categories add column sales_account_id      uuid references fin_accounts(id);
alter table inv_item_categories add column adjustment_account_id uuid references fin_accounts(id);
alter table inv_item_categories add column notes text;
alter table inv_item_categories add column is_active boolean not null default true;
alter table inv_item_categories add constraint inv_item_categories_type_check
  check (category_type in ('inventory', 'non_inventory', 'asset', 'non_depreciated_asset'));
create unique index uq_inv_item_categories_name on inv_item_categories(company_id, lower(name));
create unique index uq_inv_item_categories_code on inv_item_categories(company_id, lower(code)) where code is not null;

create table inv_item_sub_categories (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text,
  name        text not null,
  notes       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index uq_inv_item_sub_categories_name on inv_item_sub_categories(company_id, lower(name));

-- Label custom field produk (maks 5 slot)
create table inv_item_custom_fields (
  company_id  uuid not null references sys_companies(id),
  slot        int not null check (slot between 1 and 5),
  label       text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (company_id, slot)
);

-- =====================================================================
-- PRODUK
--   item_type: raw (bahan baku) / semi_finished (setengah jadi) /
--              finished (barang jadi, siap jual) / packaging (kemasan) / consumable
-- =====================================================================
alter table inv_items add column sub_category_id       uuid references inv_item_sub_categories(id);
alter table inv_items add column is_purchasable        boolean not null default true;
alter table inv_items add column is_saleable           boolean not null default false;
alter table inv_items add column is_requestable        boolean not null default true;
alter table inv_items add column is_taxable            boolean not null default false;
alter table inv_items add column receipt_tolerance_pct numeric(5,2) not null default 0;
alter table inv_items add column notes                 text;
alter table inv_items add column custom_fields         jsonb not null default '{}';
alter table inv_items add column approval_status       text not null default 'approved';
alter table inv_items add constraint inv_items_tolerance_check check (receipt_tolerance_pct between 0 and 100);
alter table inv_items add constraint inv_items_approval_check check (approval_status in ('approved', 'pending', 'rejected'));
alter table inv_items add constraint inv_items_type_check
  check (item_type in ('raw', 'semi_finished', 'finished', 'packaging', 'consumable'));

-- =====================================================================
-- SATUAN PER PRODUK (termasuk satuan dasar, konversi = 1)
-- =====================================================================
alter table inv_item_units add column sku              text;
alter table inv_item_units add column barcode          text;
alter table inv_item_units add column weight_kg        numeric(12,4);
alter table inv_item_units add column volume_cm3       numeric(12,2);
alter table inv_item_units add column is_purchase_unit boolean not null default false;
alter table inv_item_units add column is_transfer_unit boolean not null default false;
alter table inv_item_units add column is_sales_unit    boolean not null default false;

-- satuan dasar ikut tercatat sebagai baris unit
insert into inv_item_units (company_id, item_id, unit_id, conversion_qty)
select company_id, id, base_unit_id, 1 from inv_items
on conflict (item_id, unit_id) do nothing;

-- default: unit beli = konversi terbesar, unit transfer & jual = satuan dasar
with ranked as (
  select id, row_number() over (partition by item_id order by conversion_qty desc) rn from inv_item_units
)
update inv_item_units u set is_purchase_unit = (r.rn = 1) from ranked r where r.id = u.id;
update inv_item_units u set is_transfer_unit = true, is_sales_unit = true
from inv_items i where i.id = u.item_id and u.unit_id = i.base_unit_id;

create unique index uq_inv_item_units_purchase on inv_item_units(item_id) where is_purchase_unit;
create unique index uq_inv_item_units_transfer on inv_item_units(item_id) where is_transfer_unit;
create unique index uq_inv_item_units_sales    on inv_item_units(item_id) where is_sales_unit;
create unique index uq_inv_item_units_barcode  on inv_item_units(company_id, barcode) where barcode is not null;
create unique index uq_inv_item_units_sku      on inv_item_units(company_id, lower(sku)) where sku is not null;

-- produk baru otomatis punya baris satuan dasar
create or replace function inv_on_item_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into inv_item_units (company_id, item_id, unit_id, conversion_qty, is_purchase_unit, is_transfer_unit, is_sales_unit)
  values (new.company_id, new.id, new.base_unit_id, 1,
          not exists (select 1 from inv_item_units where item_id = new.id and is_purchase_unit), true, true)
  on conflict (item_id, unit_id) do nothing;
  return null;
end $$;

create trigger trg_inv_items_base_unit after insert on inv_items
  for each row execute function inv_on_item_created();

-- satuan dasar tidak boleh dihapus / konversinya harus 1
create or replace function inv_check_item_unit()
returns trigger language plpgsql as $$
declare v_base uuid;
begin
  select base_unit_id into v_base from inv_items where id = coalesce(new.item_id, old.item_id);
  if tg_op = 'DELETE' then
    if old.unit_id = v_base and exists (select 1 from inv_items where id = old.item_id) then
      raise exception 'Satuan dasar tidak bisa dihapus';
    end if;
    return old;
  end if;
  if new.unit_id = v_base and new.conversion_qty <> 1 then
    raise exception 'Konversi satuan dasar harus 1';
  end if;
  return new;
end $$;

create trigger trg_inv_item_units_check before insert or update or delete on inv_item_units
  for each row execute function inv_check_item_unit();

-- =====================================================================
-- MIN / MAX STOK PER GUDANG (Branch Product)
-- =====================================================================
create table inv_item_stock_levels (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  warehouse_id  uuid not null references inv_warehouses(id) on delete cascade,
  item_id       uuid not null references inv_items(id) on delete cascade,
  min_qty       numeric(15,4) not null default 0 check (min_qty >= 0),
  max_qty       numeric(15,4) check (max_qty is null or max_qty >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (warehouse_id, item_id),
  check (max_qty is null or max_qty >= min_qty)
);

create or replace function inv_copy_stock_levels(p_from_warehouse_id uuid, p_to_warehouse_id uuid, p_overwrite boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  if p_from_warehouse_id = p_to_warehouse_id then raise exception 'Gudang asal dan tujuan sama'; end if;
  if (select count(*) from inv_warehouses where id in (p_from_warehouse_id, p_to_warehouse_id)
        and company_id = sys_current_company_id()) <> 2 then
    raise exception 'Gudang tidak ditemukan';
  end if;

  insert into inv_item_stock_levels (company_id, warehouse_id, item_id, min_qty, max_qty)
  select company_id, p_to_warehouse_id, item_id, min_qty, max_qty
  from inv_item_stock_levels where warehouse_id = p_from_warehouse_id
  on conflict (warehouse_id, item_id) do update
    set min_qty = excluded.min_qty, max_qty = excluded.max_qty
    where p_overwrite;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Saldo stok (versi baru: kategori, min/max per gudang, saran pembelian)
drop view rpt_stock_balances;
create view rpt_stock_balances with (security_invoker = true) as
select s.company_id, s.warehouse_id, w.name as warehouse_name, w.outlet_id,
       s.item_id, it.code as item_code, it.name as item_name, it.item_type,
       it.item_category_id, c.name as category_name, sc.name as sub_category_name,
       u.code as unit_code, s.quantity, s.average_cost,
       (s.quantity * s.average_cost)::numeric(15,2) as stock_value,
       coalesce(l.min_qty, it.min_stock) as min_stock,
       l.max_qty,
       s.quantity <= coalesce(l.min_qty, it.min_stock) as is_low_stock,
       case when s.quantity <= coalesce(l.min_qty, it.min_stock)
            then greatest(coalesce(l.max_qty, coalesce(l.min_qty, it.min_stock) * 2) - s.quantity, 0) end as suggested_order_qty
from inv_stocks s
join inv_warehouses w on w.id = s.warehouse_id
join inv_items it     on it.id = s.item_id
join inv_units u      on u.id = it.base_unit_id
left join inv_item_categories c      on c.id = it.item_category_id
left join inv_item_sub_categories sc on sc.id = it.sub_category_id
left join inv_item_stock_levels l    on l.warehouse_id = s.warehouse_id and l.item_id = s.item_id;

-- =====================================================================
-- APPROVAL PRODUK & PRICELIST (jenis dokumen baru)
-- =====================================================================
alter table sys_approval_rules drop constraint sys_approval_rules_document_type_check;
alter table sys_approval_rules add constraint sys_approval_rules_document_type_check
  check (document_type in ('purchase_order', 'expense', 'stock_adjustment', 'stock_opname', 'refund', 'product', 'pricelist'));

create or replace function sys_setup_approval_rules(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into sys_approval_rules (company_id, document_type, min_amount, is_enabled) values
    (p_company_id, 'purchase_order',   5000000, false),
    (p_company_id, 'expense',          1000000, false),
    (p_company_id, 'stock_adjustment',  500000, false),
    (p_company_id, 'stock_opname',     1000000, false),
    (p_company_id, 'refund',                 0, false),
    (p_company_id, 'product',                0, false),
    (p_company_id, 'pricelist',              0, false)
  on conflict do nothing
$$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform sys_setup_approval_rules(r.id); end loop;
end $$;

-- Produk baru oleh user tanpa hak approval.product -> menunggu persetujuan
create or replace function inv_on_item_insert_approval()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and sys_approval_required('product', 0) then
    new.approval_status := 'pending';
    perform sys_request_approval('product', new.id, null, 0, 'Produk baru: ' || new.code || ' - ' || new.name, '{}');
  end if;
  return new;
end $$;

create trigger trg_inv_items_approval before insert on inv_items
  for each row execute function inv_on_item_insert_approval();

-- Produk harus disetujui & aktif sebelum dipakai di PO / resep
create or replace function inv_check_item_usable()
returns trigger language plpgsql security definer set search_path = public as $$
declare v inv_items%rowtype;
begin
  select * into v from inv_items where id = new.item_id;
  if v.approval_status <> 'approved' then raise exception 'Produk % belum disetujui', v.name; end if;
  if not v.is_active then raise exception 'Produk % tidak aktif', v.name; end if;
  if tg_table_name = 'pur_purchase_order_items' and not v.is_purchasable then
    raise exception 'Produk % tidak bisa dibeli (flag "Dapat dibeli" mati)', v.name;
  end if;
  return new;
end $$;

create trigger trg_pur_purchase_order_items_usable before insert or update of item_id on pur_purchase_order_items
  for each row execute function inv_check_item_usable();
create trigger trg_inv_recipe_items_usable before insert or update of item_id on inv_recipe_items
  for each row execute function inv_check_item_usable();

-- =====================================================================
-- AKUN JURNAL PER KATEGORI
--   p_kind: inventory / cogs / sales / adjustment
--   Bila akun kategori kosong -> akun default perusahaan
-- =====================================================================
create or replace function fin_item_account(p_item_id uuid, p_kind text)
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    case p_kind
      when 'inventory'  then c.inventory_account_id
      when 'cogs'       then c.cogs_account_id
      when 'sales'      then c.sales_account_id
      when 'adjustment' then c.adjustment_account_id
    end,
    fin_account_id(i.company_id, case p_kind
      when 'inventory'  then 'inventory'
      when 'cogs'       then 'cogs'
      when 'sales'      then 'sales_revenue'
      when 'adjustment' then 'inventory_adjustment'
    end))
  from inv_items i left join inv_item_categories c on c.id = i.item_category_id
  where i.id = p_item_id
$$;

-- Baris jurnal persediaan dari kartu stok sebuah dokumen, dikelompokkan per akun kategori.
-- p_counter_kind: akun lawan per kategori (cogs / adjustment), atau null = tanpa lawan.
-- p_counter_key : akun lawan tetap (mis. waste_expense) bila p_counter_kind null.
create or replace function fin_stock_journal_lines(
  p_reference_type text, p_reference_id uuid, p_counter_kind text default null, p_counter_key text default null
)
returns jsonb language sql stable security definer set search_path = public as $$
  with v as (
    select m.company_id, fin_item_account(m.item_id, 'inventory') as inv_acc,
           case when p_counter_kind is not null then fin_item_account(m.item_id, p_counter_kind)
                when p_counter_key is not null then fin_account_id(m.company_id, p_counter_key) end as counter_acc,
           round(m.quantity * coalesce(m.unit_cost, 0), 2) as value
    from inv_stock_movements m
    where m.reference_type = p_reference_type and m.reference_id = p_reference_id
  ),
  inv as (select inv_acc acc, sum(value) val from v group by inv_acc),
  ctr as (select counter_acc acc, -sum(value) val from v where counter_acc is not null group by counter_acc)
  select coalesce(jsonb_agg(jsonb_build_object('account_id', acc, 'debit', val)), '[]'::jsonb)
  from (select * from inv union all select * from ctr) x
  where val <> 0
$$;

-- Penjualan: HPP & persediaan per kategori
create or replace function fin_post_sales_journal(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o       pos_orders%rowtype;
  c       uuid;
  v_lines jsonb;
begin
  select * into o from pos_orders where id = p_order_id and status = 'paid';
  if not found then return; end if;
  if exists (select 1 from fin_journals where source_type = 'sales' and source_id = o.id) then return; end if;
  c := o.company_id;
  if not exists (select 1 from fin_accounts where company_id = c) then return; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'account_id', coalesce(m.account_id, fin_account_id(c, 'cash')),
           'debit', p.amount - p.change_amount, 'note', m.name)), '[]'::jsonb)
    into v_lines
  from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
  where p.order_id = o.id;

  v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id', fin_account_id(c, 'sales_discount'),  'debit',  o.discount_amount + o.promotion_amount + o.points_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'sales_revenue'),   'credit', o.subtotal),
    jsonb_build_object('account_id', fin_account_id(c, 'service_revenue'), 'credit', o.service_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'tax_payable'),     'credit', o.tax_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'rounding'),        'credit', o.rounding_amount)
  ) || fin_stock_journal_lines('pos_orders', o.id, 'cogs');

  perform fin_create_journal(c, o.outlet_id, o.business_date, 'sales', o.id, 'Penjualan ' || o.order_number, v_lines);
end $$;

-- Penerimaan barang: persediaan per kategori | hutang usaha
create or replace function fin_post_goods_receipt_journal(p_receipt_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g pur_goods_receipts%rowtype;
  v_supplier text;
begin
  select * into g from pur_goods_receipts where id = p_receipt_id and status = 'posted';
  if not found or not exists (select 1 from fin_accounts where company_id = g.company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = 'purchase_receipt' and source_id = g.id) then return; end if;
  select name into v_supplier from pur_suppliers where id = g.supplier_id;

  perform fin_create_journal(g.company_id, null, g.receipt_date, 'purchase_receipt', g.id,
    'Pembelian ' || g.receipt_number || ' - ' || v_supplier,
    fin_stock_journal_lines('pur_goods_receipts', g.id)
      || jsonb_build_array(jsonb_build_object('account_id', fin_account_id(g.company_id, 'ap'), 'credit', g.grand_total))
      -- selisih pembulatan (harga per satuan dasar) masuk persediaan default
      || jsonb_build_array(jsonb_build_object('account_id', fin_account_id(g.company_id, 'inventory'),
           'debit', g.grand_total - coalesce((select sum(round(quantity * unit_cost, 2)) from inv_stock_movements
                                               where reference_type = 'pur_goods_receipts' and reference_id = g.id), 0))));
end $$;

-- Penyesuaian / waste / opname: persediaan per kategori vs akun selisih per kategori (waste -> akun waste)
create or replace function fin_post_stock_document_journal(
  p_company_id uuid, p_reference_type text, p_reference_id uuid, p_date date,
  p_number text, p_counter_key text, p_source_type text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = p_source_type and source_id = p_reference_id) then return; end if;

  perform fin_create_journal(p_company_id, null, p_date, p_source_type, p_reference_id, 'Stok ' || p_number,
    case when p_counter_key = 'inventory_adjustment'
         then fin_stock_journal_lines(p_reference_type, p_reference_id, 'adjustment')
         else fin_stock_journal_lines(p_reference_type, p_reference_id, null, p_counter_key) end);
end $$;

-- =====================================================================
-- IMPORT EXCEL
-- =====================================================================
create or replace function sys_parse_bool(p text, p_default boolean)
returns boolean language sql immutable as $$
  select case
    when p is null or trim(p) = '' then p_default
    when lower(trim(p)) in ('yes', 'ya', 'y', 'true', '1', 'iya') then true
    when lower(trim(p)) in ('no', 'tidak', 'n', 'false', '0', 'tdk') then false
  end
$$;

create or replace function sys_parse_number(p text)
returns numeric language plpgsql immutable as $$
begin
  if p is null or trim(p) = '' then return null; end if;
  return replace(replace(trim(p), ' ', ''), ',', '.')::numeric;
exception when others then
  return 'NaN'::numeric;
end $$;

-- Import produk.  Kolom (kunci JSON):
--   kode*, nama*, tipe (bahan_baku/setengah_jadi/barang_jadi/kemasan/habis_pakai), kategori*, sub_kategori,
--   satuan* (kode/nama satuan dasar), satuan_beli, konversi_beli, harga_beli (per satuan dasar), stok_minimum,
--   dapat_dibeli, dapat_dijual, dapat_direquest, kena_pajak (YA/TIDAK), toleransi_terima (%), barcode, catatan,
--   info_1 .. info_5
-- Validasi semua baris dulu; bila ada error, TIDAK ada yang disimpan.
create or replace function inv_import_items(p_rows jsonb, p_create_missing boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_errors  jsonb := '[]';
  r         jsonb;
  i         int := 0;
  v_codes   text[] := '{}';
  v_type    text;
  v_n       numeric;
  v_cat     uuid;
  v_sub     uuid;
  v_unit    uuid;
  v_punit   uuid;
  v_item    uuid;
  v_count   int := 0;
  k         text;
  err       text;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'File kosong'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'Maksimal 2000 baris per upload'; end if;

  -- ---------- 1) validasi ----------
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    err := null;
    if coalesce(trim(r->>'kode'), '') = '' then err := 'Kode wajib diisi';
    elsif coalesce(trim(r->>'nama'), '') = '' then err := 'Nama wajib diisi';
    elsif upper(trim(r->>'kode')) = any(v_codes) then err := 'Kode dobel di dalam file';
    elsif exists (select 1 from inv_items where company_id = v_company and lower(code) = lower(trim(r->>'kode'))) then err := 'Kode produk sudah terdaftar';
    elsif coalesce(trim(r->>'kategori'), '') = '' then err := 'Kategori wajib diisi';
    elsif not p_create_missing and not exists (select 1 from inv_item_categories where company_id = v_company and lower(name) = lower(trim(r->>'kategori'))) then err := 'Kategori "' || (r->>'kategori') || '" belum terdaftar';
    elsif coalesce(trim(r->>'sub_kategori'), '') <> '' and not p_create_missing and not exists (select 1 from inv_item_sub_categories where company_id = v_company and lower(name) = lower(trim(r->>'sub_kategori'))) then err := 'Sub kategori "' || (r->>'sub_kategori') || '" belum terdaftar';
    elsif coalesce(trim(r->>'satuan'), '') = '' then err := 'Satuan wajib diisi';
    elsif not p_create_missing and not exists (select 1 from inv_units where company_id = v_company and (lower(code) = lower(trim(r->>'satuan')) or lower(name) = lower(trim(r->>'satuan')))) then err := 'Satuan "' || (r->>'satuan') || '" belum terdaftar';
    elsif coalesce(trim(r->>'satuan_beli'), '') <> '' and not p_create_missing and not exists (select 1 from inv_units where company_id = v_company and (lower(code) = lower(trim(r->>'satuan_beli')) or lower(name) = lower(trim(r->>'satuan_beli')))) then err := 'Satuan beli "' || (r->>'satuan_beli') || '" belum terdaftar';
    elsif coalesce(trim(r->>'satuan_beli'), '') <> '' and coalesce(sys_parse_number(r->>'konversi_beli'), 0) <= 0 then err := 'Konversi beli wajib > 0 bila satuan beli diisi';
    elsif sys_parse_number(r->>'harga_beli') = 'NaN' or sys_parse_number(r->>'harga_beli') < 0 then err := 'Harga beli harus angka positif';
    elsif sys_parse_number(r->>'stok_minimum') = 'NaN' or sys_parse_number(r->>'stok_minimum') < 0 then err := 'Stok minimum harus angka positif';
    elsif sys_parse_number(r->>'toleransi_terima') = 'NaN' or coalesce(sys_parse_number(r->>'toleransi_terima'), 0) not between 0 and 100 then err := 'Toleransi terima harus 0 - 100';
    elsif coalesce(trim(r->>'tipe'), '') <> '' and lower(trim(r->>'tipe')) not in ('bahan_baku', 'bahan baku', 'setengah_jadi', 'setengah jadi', 'barang_jadi', 'barang jadi', 'kemasan', 'habis_pakai', 'habis pakai') then err := 'Tipe tidak dikenal: ' || (r->>'tipe');
    elsif sys_parse_bool(r->>'dapat_dibeli', true) is null or sys_parse_bool(r->>'dapat_dijual', false) is null
       or sys_parse_bool(r->>'dapat_direquest', true) is null or sys_parse_bool(r->>'kena_pajak', false) is null then err := 'Kolom YA/TIDAK berisi nilai tidak dikenal';
    elsif coalesce(trim(r->>'barcode'), '') <> '' and exists (select 1 from inv_item_units where company_id = v_company and barcode = trim(r->>'barcode')) then err := 'Barcode sudah dipakai produk lain';
    end if;
    if err is not null then
      v_errors := v_errors || jsonb_build_object('row', i, 'code', r->>'kode', 'message', err);
    end if;
    v_codes := v_codes || upper(trim(coalesce(r->>'kode', '')));
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('inserted', 0, 'errors', v_errors);
  end if;

  -- ---------- 2) simpan ----------
  for r in select * from jsonb_array_elements(p_rows) loop
    -- kategori, sub kategori, satuan (buat bila belum ada & diizinkan)
    select id into v_cat from inv_item_categories where company_id = v_company and lower(name) = lower(trim(r->>'kategori'));
    if v_cat is null then
      insert into inv_item_categories (company_id, name) values (v_company, trim(r->>'kategori')) returning id into v_cat;
    end if;
    v_sub := null;
    if coalesce(trim(r->>'sub_kategori'), '') <> '' then
      select id into v_sub from inv_item_sub_categories where company_id = v_company and lower(name) = lower(trim(r->>'sub_kategori'));
      if v_sub is null then
        insert into inv_item_sub_categories (company_id, name) values (v_company, trim(r->>'sub_kategori')) returning id into v_sub;
      end if;
    end if;
    select id into v_unit from inv_units where company_id = v_company and (lower(code) = lower(trim(r->>'satuan')) or lower(name) = lower(trim(r->>'satuan'))) limit 1;
    if v_unit is null then
      insert into inv_units (company_id, code, name) values (v_company, lower(trim(r->>'satuan')), trim(r->>'satuan')) returning id into v_unit;
    end if;

    v_type := case replace(lower(coalesce(trim(r->>'tipe'), 'bahan_baku')), ' ', '_')
      when 'setengah_jadi' then 'semi_finished' when 'barang_jadi' then 'finished'
      when 'kemasan' then 'packaging' when 'habis_pakai' then 'consumable' else 'raw' end;

    insert into inv_items (company_id, item_category_id, sub_category_id, code, name, item_type, base_unit_id,
      min_stock, last_purchase_cost, is_purchasable, is_saleable, is_requestable, is_taxable,
      receipt_tolerance_pct, notes, custom_fields)
    values (v_company, v_cat, v_sub, upper(trim(r->>'kode')), trim(r->>'nama'), v_type, v_unit,
      coalesce(sys_parse_number(r->>'stok_minimum'), 0), coalesce(sys_parse_number(r->>'harga_beli'), 0),
      sys_parse_bool(r->>'dapat_dibeli', true), sys_parse_bool(r->>'dapat_dijual', false),
      sys_parse_bool(r->>'dapat_direquest', true), sys_parse_bool(r->>'kena_pajak', false),
      coalesce(sys_parse_number(r->>'toleransi_terima'), 0), nullif(trim(r->>'catatan'), ''),
      (select coalesce(jsonb_object_agg(s::text, r->>('info_' || s)), '{}'::jsonb)
         from generate_series(1, 5) s where coalesce(trim(r->>('info_' || s)), '') <> ''))
    returning id into v_item;

    if coalesce(trim(r->>'barcode'), '') <> '' then
      update inv_item_units set barcode = trim(r->>'barcode') where item_id = v_item and unit_id = v_unit;
    end if;

    if coalesce(trim(r->>'satuan_beli'), '') <> '' then
      select id into v_punit from inv_units where company_id = v_company and (lower(code) = lower(trim(r->>'satuan_beli')) or lower(name) = lower(trim(r->>'satuan_beli'))) limit 1;
      if v_punit is null then
        insert into inv_units (company_id, code, name) values (v_company, lower(trim(r->>'satuan_beli')), trim(r->>'satuan_beli')) returning id into v_punit;
      end if;
      if v_punit <> v_unit then
        update inv_item_units set is_purchase_unit = false where item_id = v_item;
        insert into inv_item_units (company_id, item_id, unit_id, conversion_qty, is_purchase_unit)
        values (v_company, v_item, v_punit, sys_parse_number(r->>'konversi_beli'), true);
      end if;
    end if;
    v_count := v_count + 1;
  end loop;

  perform sys_log_activity(v_company, 'import', 'inv_items', null, v_count || ' produk dari Excel', null);
  return jsonb_build_object('inserted', v_count, 'errors', '[]'::jsonb);
end $$;

-- Import menu.  Kolom: kode*, nama*, kategori*, harga*, harga_gofood, harga_grabfood,
--   station (dapur/bar/pastry), deskripsi, aktif (YA/TIDAK)
create or replace function mst_import_menu_items(p_rows jsonb, p_create_missing boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_brand   uuid := (select id from sys_brands where company_id = sys_current_company_id() order by created_at limit 1);
  v_errors  jsonb := '[]';
  r         jsonb;
  i         int := 0;
  v_codes   text[] := '{}';
  v_cat     uuid;
  v_menu    uuid;
  v_count   int := 0;
  err       text;
  ch        text;
begin
  if not sys_has_permission('master.manage') then raise exception 'Tidak punya izin'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'File kosong'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'Maksimal 2000 baris per upload'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    err := null;
    if coalesce(trim(r->>'kode'), '') = '' then err := 'Kode wajib diisi';
    elsif coalesce(trim(r->>'nama'), '') = '' then err := 'Nama wajib diisi';
    elsif upper(trim(r->>'kode')) = any(v_codes) then err := 'Kode dobel di dalam file';
    elsif exists (select 1 from mst_menu_items where company_id = v_company and lower(code) = lower(trim(r->>'kode'))) then err := 'Kode menu sudah terdaftar';
    elsif coalesce(trim(r->>'kategori'), '') = '' then err := 'Kategori wajib diisi';
    elsif not p_create_missing and not exists (select 1 from mst_menu_categories where company_id = v_company and lower(name) = lower(trim(r->>'kategori'))) then err := 'Kategori "' || (r->>'kategori') || '" belum terdaftar';
    elsif sys_parse_number(r->>'harga') is null or sys_parse_number(r->>'harga') = 'NaN' or sys_parse_number(r->>'harga') < 0 then err := 'Harga wajib angka positif';
    elsif sys_parse_number(r->>'harga_gofood') = 'NaN' or sys_parse_number(r->>'harga_grabfood') = 'NaN' then err := 'Harga ojol harus angka';
    elsif coalesce(trim(r->>'station'), '') <> '' and lower(trim(r->>'station')) not in ('dapur', 'kitchen', 'bar', 'pastry') then err := 'Station harus dapur / bar / pastry';
    elsif sys_parse_bool(r->>'aktif', true) is null then err := 'Kolom aktif harus YA/TIDAK';
    end if;
    if err is not null then v_errors := v_errors || jsonb_build_object('row', i, 'code', r->>'kode', 'message', err); end if;
    v_codes := v_codes || upper(trim(coalesce(r->>'kode', '')));
  end loop;

  if jsonb_array_length(v_errors) > 0 then return jsonb_build_object('inserted', 0, 'errors', v_errors); end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    select id into v_cat from mst_menu_categories where company_id = v_company and lower(name) = lower(trim(r->>'kategori'));
    if v_cat is null then
      insert into mst_menu_categories (company_id, brand_id, name, sort_order)
      values (v_company, v_brand, trim(r->>'kategori'), (select coalesce(max(sort_order), 0) + 1 from mst_menu_categories where company_id = v_company))
      returning id into v_cat;
    end if;
    insert into mst_menu_items (company_id, brand_id, menu_category_id, code, name, description, base_price, station, is_active)
    values (v_company, v_brand, v_cat, upper(trim(r->>'kode')), trim(r->>'nama'), nullif(trim(r->>'deskripsi'), ''),
            sys_parse_number(r->>'harga'),
            case lower(coalesce(trim(r->>'station'), '')) when 'bar' then 'bar' when 'pastry' then 'pastry' else 'kitchen' end,
            sys_parse_bool(r->>'aktif', true))
    returning id into v_menu;
    foreach ch in array array['gofood', 'grabfood'] loop
      if sys_parse_number(r->>('harga_' || ch)) is not null then
        insert into mst_menu_prices (company_id, menu_item_id, sales_channel, price)
        values (v_company, v_menu, ch, sys_parse_number(r->>('harga_' || ch)));
      end if;
    end loop;
    v_count := v_count + 1;
  end loop;

  perform sys_log_activity(v_company, 'import', 'mst_menu_items', null, v_count || ' menu dari Excel', null);
  return jsonb_build_object('inserted', v_count, 'errors', '[]'::jsonb);
end $$;

-- =====================================================================
-- TRIGGER, RLS, AUDIT
-- =====================================================================
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('inv_item_sub_categories', 'inventory.manage');
select sys_apply_company_policies('inv_item_custom_fields', 'inventory.manage');
select sys_apply_company_policies('inv_item_stock_levels', 'inventory.manage');

-- status approval produk hanya boleh berubah lewat keputusan approval (sys_decide_approval)
create or replace function inv_guard_item_approval()
returns trigger language plpgsql as $$
begin
  if new.approval_status is distinct from old.approval_status
     and auth.uid() is not null
     and coalesce(current_setting('erp.approval_decision', true), '') <> 'on' then
    raise exception 'Status persetujuan produk hanya bisa diubah lewat menu Persetujuan';
  end if;
  return new;
end $$;

create trigger trg_inv_items_guard_approval before update of approval_status on inv_items
  for each row execute function inv_guard_item_approval();

do $$
declare t text;
begin
  foreach t in array array['inv_item_sub_categories', 'inv_item_categories', 'inv_units', 'inv_item_units', 'inv_item_stock_levels'] loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function sys_audit_trigger(%L)',
                   'trg_' || t || '_audit', t, '');
  end loop;
end $$;

revoke execute on function fin_item_account(uuid, text)                      from public, anon, authenticated;
revoke execute on function fin_stock_journal_lines(text, uuid, text, text)    from public, anon, authenticated;

-- >>>>>>>>>> migrations/015_bom_production_pricelist.sql
-- =====================================================================
-- SANTAP ERP - 015: BOM LANJUTAN, PRODUKSI, PRICELIST SUPPLIER
--   * BOM tipe Menu / Assembly / Disassembly, kode & nama, aktif
--   * Waste % per bahan, faktor bobot (disassembly), biaya tambahan per BOM
--   * Resep rahasia: akses General / Restricted (user tertentu)
--   * Produksi (assembly & disassembly) -> kartu stok + jurnal
--   * Pricelist supplier dengan masa berlaku, per outlet, approval
--   * Toleransi penerimaan barang terhadap sisa PO
--   * Keputusan approval untuk produk baru & pricelist
-- =====================================================================

-- =====================================================================
-- BOM (inv_recipes)
-- =====================================================================
alter table inv_recipes add column code          text;
alter table inv_recipes add column name          text;
alter table inv_recipes add column recipe_type   text not null default 'menu';
alter table inv_recipes add column access_level  text not null default 'general';
alter table inv_recipes add column is_active     boolean not null default true;
update inv_recipes set recipe_type = case when menu_item_id is not null then 'menu' else 'assembly' end;
alter table inv_recipes add constraint inv_recipes_type_check check (
  (recipe_type = 'menu' and menu_item_id is not null) or (recipe_type in ('assembly', 'disassembly') and item_id is not null));
alter table inv_recipes add constraint inv_recipes_access_check check (access_level in ('general', 'restricted'));

-- satu produk bisa punya BOM assembly sekaligus disassembly
alter table inv_recipes drop constraint inv_recipes_item_id_key;
create unique index uq_inv_recipes_item_type on inv_recipes(item_id, recipe_type) where item_id is not null;
create unique index uq_inv_recipes_code on inv_recipes(company_id, lower(code)) where code is not null;

alter table inv_recipe_items add column waste_pct     numeric(5,2) not null default 0 check (waste_pct between 0 and 100);
alter table inv_recipe_items add column weight_factor numeric(10,4) check (weight_factor is null or weight_factor > 0);

-- biaya tambahan per resep (per hasil yield_qty), mis. gas, tenaga kerja
create table inv_recipe_costs (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  recipe_id    uuid not null references inv_recipes(id) on delete cascade,
  description  text not null,
  account_id   uuid not null references fin_accounts(id),
  amount       numeric(15,2) not null check (amount >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- resep rahasia: hanya user terdaftar (dan owner) yang bisa melihat
create table inv_recipe_access (
  recipe_id   uuid not null references inv_recipes(id) on delete cascade,
  user_id     uuid not null references sys_users(id) on delete cascade,
  company_id  uuid not null references sys_companies(id),
  created_at  timestamptz not null default now(),
  primary key (recipe_id, user_id)
);

create or replace function inv_can_view_recipe(p_recipe_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from inv_recipes r
    where r.id = p_recipe_id and r.company_id = sys_current_company_id()
      and (r.access_level = 'general' or sys_has_permission('*')
           or exists (select 1 from inv_recipe_access a where a.recipe_id = r.id and a.user_id = auth.uid())))
$$;

-- akses resep rahasia untuk user login (dibaca tanpa terhalang RLS tabel akses)
create or replace function inv_has_recipe_access(p_recipe_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from inv_recipe_access where recipe_id = p_recipe_id and user_id = auth.uid())
$$;

-- kolom baris dibaca langsung (bukan lewat query ulang) agar resep yang baru dibuat langsung terlihat
drop policy inv_recipes_select on inv_recipes;
create policy inv_recipes_select on inv_recipes for select to authenticated
  using (company_id = sys_current_company_id()
         and (access_level = 'general' or sys_has_permission('*') or inv_has_recipe_access(id)));
drop policy inv_recipe_items_select on inv_recipe_items;
create policy inv_recipe_items_select on inv_recipe_items for select to authenticated
  using (company_id = sys_current_company_id() and inv_can_view_recipe(recipe_id));

select sys_apply_company_policies('inv_recipe_costs', 'inventory.manage');
drop policy inv_recipe_costs_select on inv_recipe_costs;
create policy inv_recipe_costs_select on inv_recipe_costs for select to authenticated
  using (company_id = sys_current_company_id() and inv_can_view_recipe(recipe_id));

alter table inv_recipe_access enable row level security;
create policy inv_recipe_access_all on inv_recipe_access for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('inventory.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('inventory.manage'));

-- =====================================================================
-- BIAYA RESEP & HPP
-- =====================================================================
-- Harga bahan: harga beli terakhir & rata-rata tertimbang semua gudang
create view rpt_item_costs with (security_invoker = true) as
select i.company_id, i.id as item_id, i.code, i.name, i.item_type, u.code as unit_code,
       i.last_purchase_cost,
       coalesce((select sum(s.quantity * s.average_cost) / nullif(sum(s.quantity), 0)
                 from inv_stocks s where s.item_id = i.id and s.quantity > 0), i.last_purchase_cost)::numeric(15,4) as average_cost
from inv_items i join inv_units u on u.id = i.base_unit_id;

-- Biaya per resep (per 1 satuan hasil): bahan (+waste) + biaya tambahan
create view rpt_recipe_costs with (security_invoker = true) as
select r.company_id, r.id as recipe_id, r.recipe_type, r.code, r.name, r.menu_item_id, r.item_id, r.yield_qty, r.is_active,
       coalesce((select sum(ri.quantity * (1 + ri.waste_pct / 100) * it.last_purchase_cost)
                 from inv_recipe_items ri join inv_items it on it.id = ri.item_id
                 where ri.recipe_id = r.id and r.recipe_type <> 'disassembly'), 0) / r.yield_qty as material_cost,
       coalesce((select sum(c.amount) from inv_recipe_costs c where c.recipe_id = r.id), 0) / r.yield_qty as extra_cost
from inv_recipes r;

drop view rpt_menu_food_costs;
create view rpt_menu_food_costs with (security_invoker = true) as
select mi.company_id, mi.id as menu_item_id, mi.code, mi.name, mi.base_price,
       coalesce(rc.material_cost + rc.extra_cost, 0)::numeric(15,2) as food_cost,
       case when mi.base_price > 0 and rc.recipe_id is not null
            then round((rc.material_cost + rc.extra_cost) / mi.base_price * 100, 1) end as food_cost_pct,
       rc.recipe_id is not null and exists (select 1 from inv_recipe_items where recipe_id = rc.recipe_id) as has_recipe
from mst_menu_items mi
left join rpt_recipe_costs rc on rc.menu_item_id = mi.id and rc.is_active
where mi.is_active;

-- Potong stok saat order lunas: resep aktif + waste
create or replace function inv_post_order_consumption(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order        pos_orders%rowtype;
  v_warehouse_id uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  select default_warehouse_id into v_warehouse_id from sys_outlets where id = v_order.outlet_id;
  if v_warehouse_id is null then return; end if;

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by)
  select v_order.company_id, v_warehouse_id, ri.item_id, 'sales',
         -sum(oi.quantity * ri.quantity * (1 + ri.waste_pct / 100) / r.yield_qty),
         'pos_orders', v_order.id, v_order.order_number, auth.uid()
  from pos_order_items oi
  join inv_recipes r       on r.menu_item_id = oi.menu_item_id and r.is_active
  join inv_recipe_items ri on ri.recipe_id = r.id
  where oi.order_id = p_order_id and not oi.is_void
  group by ri.item_id;
end $$;

-- Kartu stok: bila stok belum punya HPP rata-rata (produk baru / stok 0),
-- barang masuk tanpa harga memakai harga beli terakhir produk (sebelumnya tercatat Rp 0)
create or replace function inv_apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_stock inv_stocks%rowtype;
begin
  insert into inv_stocks (company_id, warehouse_id, item_id)
  values (new.company_id, new.warehouse_id, new.item_id)
  on conflict (warehouse_id, item_id) do nothing;

  select * into v_stock from inv_stocks
  where warehouse_id = new.warehouse_id and item_id = new.item_id
  for update;

  if new.unit_cost is null then
    new.unit_cost := case when v_stock.average_cost > 0 then v_stock.average_cost
                          else (select last_purchase_cost from inv_items where id = new.item_id) end;
  end if;

  if new.quantity > 0 and greatest(v_stock.quantity, 0) + new.quantity > 0 then
    v_stock.average_cost :=
      (greatest(v_stock.quantity, 0) * v_stock.average_cost + new.quantity * new.unit_cost)
      / (greatest(v_stock.quantity, 0) + new.quantity);
  end if;

  v_stock.quantity := v_stock.quantity + new.quantity;
  new.balance_after := v_stock.quantity;

  update inv_stocks
     set quantity = v_stock.quantity, average_cost = v_stock.average_cost
   where id = v_stock.id;

  return new;
end $$;

-- =====================================================================
-- PRODUKSI (Assembly: bahan -> hasil, Disassembly: 1 bahan -> banyak hasil)
--   quantity = jumlah hasil (assembly) / jumlah bahan sumber (disassembly)
-- =====================================================================
create table inv_productions (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  warehouse_id       uuid not null references inv_warehouses(id),
  recipe_id          uuid not null references inv_recipes(id),
  production_number  text,
  production_date    date not null default current_date,
  quantity           numeric(15,4) not null check (quantity > 0),
  status             text not null default 'draft',   -- draft / posted
  notes              text,
  created_by         uuid references sys_users(id),
  posted_at          timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

select sys_apply_company_policies('inv_productions', 'inventory.manage');

create or replace function inv_post_production(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p          inv_productions%rowtype;
  r          inv_recipes%rowtype;
  v_factor   numeric;
  v_input    numeric;
  v_extra    numeric;
  v_total_wf numeric;
  v_inv_net  numeric;
  v_lines    jsonb;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into p from inv_productions where id = p_id and company_id = sys_current_company_id() for update;
  if not found or p.status <> 'draft' then raise exception 'Produksi tidak ditemukan / sudah diposting'; end if;
  select * into r from inv_recipes where id = p.recipe_id;
  if r.recipe_type not in ('assembly', 'disassembly') then raise exception 'Resep harus bertipe Assembly / Disassembly'; end if;
  if not r.is_active then raise exception 'Resep tidak aktif'; end if;
  if not exists (select 1 from inv_recipe_items where recipe_id = r.id) then raise exception 'Resep belum punya bahan'; end if;

  p.production_number := coalesce(p.production_number, sys_next_document_number(p.company_id, 'PRD', p.production_date));
  v_factor := p.quantity / r.yield_qty;
  v_extra := round(coalesce((select sum(amount) from inv_recipe_costs where recipe_id = r.id), 0) * v_factor, 2);

  if r.recipe_type = 'assembly' then
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
      reference_type, reference_id, reference_number, created_by)
    select p.company_id, p.warehouse_id, ri.item_id, 'production_out',
           -(ri.quantity * v_factor * (1 + ri.waste_pct / 100)),
           'inv_productions', p.id, p.production_number, auth.uid()
    from inv_recipe_items ri where ri.recipe_id = r.id;

    select -coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_input
    from inv_stock_movements where reference_type = 'inv_productions' and reference_id = p.id;

    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, created_by)
    values (p.company_id, p.warehouse_id, r.item_id, 'production_in', p.quantity, (v_input + v_extra) / p.quantity,
            'inv_productions', p.id, p.production_number, auth.uid());
  else
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
      reference_type, reference_id, reference_number, created_by)
    values (p.company_id, p.warehouse_id, r.item_id, 'production_out', -p.quantity,
            'inv_productions', p.id, p.production_number, auth.uid());

    select -coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_input
    from inv_stock_movements where reference_type = 'inv_productions' and reference_id = p.id;
    select sum(coalesce(weight_factor, 1)) into v_total_wf from inv_recipe_items where recipe_id = r.id;

    -- nilai bahan sumber (+biaya) dibagi ke hasil sesuai faktor bobot
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, created_by)
    select p.company_id, p.warehouse_id, ri.item_id, 'production_in', ri.quantity * v_factor,
           (v_input + v_extra) * coalesce(ri.weight_factor, 1) / v_total_wf / (ri.quantity * v_factor),
           'inv_productions', p.id, p.production_number, auth.uid()
    from inv_recipe_items ri where ri.recipe_id = r.id;
  end if;

  update inv_productions set status = 'posted', posted_at = now(), production_number = p.production_number where id = p.id;

  -- Jurnal: persediaan per kategori (bersih = biaya tambahan) | akun biaya tambahan
  if exists (select 1 from fin_accounts where company_id = p.company_id) then
    select coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_inv_net
    from inv_stock_movements where reference_type = 'inv_productions' and reference_id = p.id;

    select coalesce(jsonb_agg(jsonb_build_object('account_id', account_id, 'credit', round(amount * v_factor, 2), 'note', description)), '[]'::jsonb)
      into v_lines
    from inv_recipe_costs where recipe_id = r.id;

    v_lines := v_lines || fin_stock_journal_lines('inv_productions', p.id)
      -- selisih pembulatan biaya ke persediaan default
      || jsonb_build_array(jsonb_build_object('account_id', fin_account_id(p.company_id, 'inventory'),
           'debit', (select coalesce(sum(round(amount * v_factor, 2)), 0) from inv_recipe_costs where recipe_id = r.id) - v_inv_net));

    perform fin_create_journal(p.company_id, (select outlet_id from inv_warehouses where id = p.warehouse_id),
      p.production_date, 'production', p.id, 'Produksi ' || p.production_number || ' - ' || coalesce(r.name, ''), v_lines);
  end if;

  return jsonb_build_object('production_number', p.production_number, 'input_value', v_input, 'extra_cost', v_extra);
end $$;

-- =====================================================================
-- PRICELIST SUPPLIER
-- =====================================================================
create table pur_pricelists (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  supplier_id       uuid not null references pur_suppliers(id),
  outlet_id         uuid references sys_outlets(id),     -- null = semua outlet
  pricelist_number  text,
  effective_date    date not null default current_date,
  expiry_date       date,
  currency          text not null default 'IDR',
  status            text not null default 'draft',      -- draft / pending_approval / approved / cancelled
  notes             text,
  created_by        uuid references sys_users(id),
  approved_by       uuid references sys_users(id),
  approved_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (expiry_date is null or expiry_date >= effective_date),
  check (status in ('draft', 'pending_approval', 'approved', 'cancelled'))
);

create table pur_pricelist_items (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  pricelist_id    uuid not null references pur_pricelists(id) on delete cascade,
  item_id         uuid not null references inv_items(id),
  unit_id         uuid not null references inv_units(id),
  conversion_qty  numeric(15,4) not null default 1 check (conversion_qty > 0),
  price           numeric(15,2) not null check (price >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (pricelist_id, item_id, unit_id)
);

select sys_apply_company_policies('pur_pricelists', 'purchasing.manage');
select sys_apply_company_policies('pur_pricelist_items', 'purchasing.manage');

create or replace function pur_approve_pricelist(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v pur_pricelists%rowtype;
begin
  if not (sys_has_permission('purchasing.manage') or sys_has_permission('approval.pricelist')) then raise exception 'Tidak punya izin'; end if;
  select * into v from pur_pricelists where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v.status not in ('draft', 'pending_approval') then raise exception 'Pricelist tidak ditemukan / bukan draft'; end if;
  if not exists (select 1 from pur_pricelist_items where pricelist_id = p_id) then raise exception 'Pricelist belum punya item'; end if;

  if sys_approval_required('pricelist', 0) then
    if v.status = 'pending_approval' then raise exception 'Pricelist masih menunggu persetujuan'; end if;
    update pur_pricelists set status = 'pending_approval' where id = p_id returning * into v;
    return to_jsonb(v) || sys_request_approval('pricelist', p_id, v.outlet_id, 0,
      'Pricelist ' || (select name from pur_suppliers where id = v.supplier_id) || ' mulai ' || to_char(v.effective_date, 'DD/MM/YYYY'), '{}');
  end if;

  update pur_pricelists set
    pricelist_number = coalesce(pricelist_number, sys_next_document_number(company_id, 'PL', effective_date)),
    status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_id returning * into v;
  perform sys_close_approval('pricelist', p_id);
  return to_jsonb(v);
end $$;

-- Harga beli: pricelist yang berlaku (outlet spesifik didahulukan) + harga beli terakhir dari supplier
create or replace function pur_get_item_price(
  p_supplier_id uuid, p_item_id uuid, p_unit_id uuid, p_outlet_id uuid default null, p_date date default current_date
)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'pricelist', (
      select jsonb_build_object('price', pi.price, 'pricelist_number', pl.pricelist_number,
                                'effective_date', pl.effective_date, 'expiry_date', pl.expiry_date)
      from pur_pricelist_items pi join pur_pricelists pl on pl.id = pi.pricelist_id
      where pl.company_id = sys_current_company_id() and pl.status = 'approved'
        and pl.supplier_id = p_supplier_id and pi.item_id = p_item_id and pi.unit_id = p_unit_id
        and pl.effective_date <= p_date and (pl.expiry_date is null or pl.expiry_date >= p_date)
        and (pl.outlet_id is null or pl.outlet_id = p_outlet_id)
      order by (pl.outlet_id is not null) desc, pl.effective_date desc, pl.approved_at desc
      limit 1),
    'last', (
      select jsonb_build_object('price', gi.unit_price, 'receipt_number', g.receipt_number, 'receipt_date', g.receipt_date)
      from pur_goods_receipt_items gi join pur_goods_receipts g on g.id = gi.goods_receipt_id
      where g.company_id = sys_current_company_id() and g.status = 'posted'
        and g.supplier_id = p_supplier_id and gi.item_id = p_item_id and gi.unit_id = p_unit_id
      order by g.receipt_date desc, g.posted_at desc
      limit 1))
$$;

-- =====================================================================
-- TOLERANSI PENERIMAAN BARANG
-- =====================================================================
create or replace function pur_check_receipt_tolerance()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_remaining numeric;
  v_tol       numeric;
  v_name      text;
begin
  if new.purchase_order_item_id is null then return new; end if;
  select poi.quantity - poi.received_qty, i.receipt_tolerance_pct, i.name into v_remaining, v_tol, v_name
  from pur_purchase_order_items poi join inv_items i on i.id = poi.item_id
  where poi.id = new.purchase_order_item_id;
  if new.quantity > v_remaining * (1 + coalesce(v_tol, 0) / 100) + 0.00001 then
    raise exception '% diterima % melebihi sisa PO % (toleransi %%%)',
      v_name, round(new.quantity, 2), round(v_remaining, 2), coalesce(v_tol, 0);
  end if;
  return new;
end $$;

create trigger trg_pur_goods_receipt_items_tolerance before insert or update of quantity on pur_goods_receipt_items
  for each row execute function pur_check_receipt_tolerance();

-- =====================================================================
-- KEPUTUSAN APPROVAL (versi baru: + produk & pricelist)
-- =====================================================================
create or replace function sys_revert_pending_document(p_document_type text, p_document_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('erp.approval_decision', 'on', true);
  if p_document_type = 'purchase_order' then
    update pur_purchase_orders set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_adjustment' then
    update inv_stock_adjustments set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_opname' then
    update inv_stock_opnames set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'product' then
    update inv_items set approval_status = 'rejected' where id = p_document_id and approval_status = 'pending';
  elsif p_document_type = 'pricelist' then
    update pur_pricelists set status = 'draft' where id = p_document_id and status = 'pending_approval';
  end if;
  perform set_config('erp.approval_decision', 'off', true);
end $$;

create or replace function sys_decide_approval(p_request_id uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        sys_approval_requests%rowtype;
  v_result jsonb;
begin
  select * into v from sys_approval_requests
  where id = p_request_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Permintaan tidak ditemukan'; end if;
  if v.status <> 'pending' then raise exception 'Permintaan sudah diputuskan'; end if;
  if not sys_has_permission('approval.' || v.document_type) then raise exception 'Anda tidak berwenang menyetujui ini'; end if;
  if v.requested_by = auth.uid() and not sys_has_permission('*') then
    raise exception 'Tidak bisa menyetujui permintaan sendiri';
  end if;

  if p_approve then
    if v.document_type = 'purchase_order' then
      v_result := pur_approve_purchase_order(v.document_id);
    elsif v.document_type = 'expense' then
      v_result := jsonb_build_object('journal_id', fin_record_expense(
        (v.payload->>'date')::date, (v.payload->>'expense_account_id')::uuid, (v.payload->>'paid_from_account_id')::uuid,
        (v.payload->>'amount')::numeric, v.payload->>'description', nullif(v.payload->>'outlet_id', '')::uuid));
    elsif v.document_type = 'stock_adjustment' then
      perform inv_post_stock_adjustment(v.document_id);
    elsif v.document_type = 'stock_opname' then
      perform inv_post_stock_opname(v.document_id);
    elsif v.document_type = 'refund' then
      v_result := pos_refund_order_execute(v.document_id, v.payload->>'reason',
                                           coalesce((v.payload->>'return_stock')::boolean, false), v.requested_by);
    elsif v.document_type = 'product' then
      perform set_config('erp.approval_decision', 'on', true);
      update inv_items set approval_status = 'approved' where id = v.document_id and approval_status = 'pending';
      perform set_config('erp.approval_decision', 'off', true);
    elsif v.document_type = 'pricelist' then
      v_result := pur_approve_pricelist(v.document_id);
    end if;
  else
    perform sys_revert_pending_document(v.document_type, v.document_id);
  end if;

  update sys_approval_requests set
    status        = case when p_approve then 'approved' else 'rejected' end,
    decided_by    = auth.uid(),
    decided_at    = now(),
    decision_note = nullif(trim(p_note), ''),
    result        = v_result
  where id = p_request_id
  returning * into v;
  return to_jsonb(v);
end $$;

-- =====================================================================
-- TRIGGER, AUDIT, HAK EKSEKUSI
-- =====================================================================
select sys_attach_updated_at_triggers();

do $$
declare t text;
begin
  foreach t in array array['inv_recipes', 'inv_recipe_costs', 'inv_productions', 'pur_pricelists', 'pur_pricelist_items'] loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function sys_audit_trigger(%L)',
                   'trg_' || t || '_audit', t, '');
  end loop;
end $$;

revoke execute on function inv_can_view_recipe(uuid) from public, anon;

-- >>>>>>>>>> migrations/016_menu_packages_schedule.sql
-- =====================================================================
-- SANTAP ERP - 016: MENU PAKET / COMBO & JADWAL HARGA
--   * Grup modifier bertipe 'package': isi paket = menu sungguhan
--     (stok resep isi paket ikut terpotong), harga tambahan, isi default
--   * Modifier bisa memotong bahan langsung (mis. Extra Telur = 1 pcs telur)
--   * Jadwal harga: harga menu berganti otomatis per hari/jam/tanggal/outlet/kanal
-- =====================================================================

alter table mst_modifier_groups add column group_type text not null default 'modifier';
alter table mst_modifier_groups add constraint mst_modifier_groups_type_check check (group_type in ('modifier', 'package'));

alter table mst_modifiers add column menu_item_id uuid references mst_menu_items(id) on delete cascade;  -- isi paket
alter table mst_modifiers add column item_id      uuid references inv_items(id);                          -- bahan langsung
alter table mst_modifiers add column item_qty     numeric(15,4) check (item_qty is null or item_qty > 0);
alter table mst_modifiers add column is_default   boolean not null default false;
alter table mst_modifiers add constraint mst_modifiers_item_pair_check check ((item_id is null) = (item_qty is null));

-- =====================================================================
-- POTONG STOK: resep menu + bahan modifier + resep isi paket
-- =====================================================================
create or replace function inv_post_order_consumption(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order        pos_orders%rowtype;
  v_warehouse_id uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  select default_warehouse_id into v_warehouse_id from sys_outlets where id = v_order.outlet_id;
  if v_warehouse_id is null then return; end if;

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by)
  select v_order.company_id, v_warehouse_id, x.item_id, 'sales', -sum(x.qty),
         'pos_orders', v_order.id, v_order.order_number, auth.uid()
  from (
    -- resep menu yang dipesan
    select ri.item_id, oi.quantity * ri.quantity * (1 + ri.waste_pct / 100) / r.yield_qty as qty
    from pos_order_items oi
    join inv_recipes r       on r.menu_item_id = oi.menu_item_id and r.is_active
    join inv_recipe_items ri on ri.recipe_id = r.id
    where oi.order_id = p_order_id and not oi.is_void
    union all
    -- modifier yang memotong bahan langsung
    select m.item_id, oi.quantity * m.item_qty
    from pos_order_items oi
    join pos_order_item_modifiers om on om.order_item_id = oi.id
    join mst_modifiers m             on m.id = om.modifier_id
    where oi.order_id = p_order_id and not oi.is_void and m.item_id is not null
    union all
    -- isi paket: resep menu isi
    select ri.item_id, oi.quantity * ri.quantity * (1 + ri.waste_pct / 100) / r.yield_qty
    from pos_order_items oi
    join pos_order_item_modifiers om on om.order_item_id = oi.id
    join mst_modifiers m             on m.id = om.modifier_id
    join inv_recipes r               on r.menu_item_id = m.menu_item_id and r.is_active
    join inv_recipe_items ri         on ri.recipe_id = r.id
    where oi.order_id = p_order_id and not oi.is_void
  ) x
  group by x.item_id
  having sum(x.qty) <> 0;
end $$;

-- =====================================================================
-- JADWAL HARGA
-- =====================================================================
create table mst_price_schedules (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  name            text not null,
  outlet_ids      uuid[],          -- null = semua outlet
  sales_channels  text[],          -- null = semua kanal
  days_of_week    int[],           -- 1=Senin..7=Minggu, null = setiap hari
  start_time      time,
  end_time        time,
  start_date      date,
  end_date        date,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);

create table mst_price_schedule_items (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  schedule_id   uuid not null references mst_price_schedules(id) on delete cascade,
  menu_item_id  uuid not null references mst_menu_items(id) on delete cascade,
  price         numeric(15,2) not null check (price >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (schedule_id, menu_item_id)
);

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('mst_price_schedules', 'master.manage');
select sys_apply_company_policies('mst_price_schedule_items', 'master.manage');

do $$
declare t text;
begin
  foreach t in array array['mst_price_schedules', 'mst_price_schedule_items', 'mst_modifier_groups'] loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function sys_audit_trigger(%L)',
                   'trg_' || t || '_audit', t, '');
  end loop;
end $$;

-- Harga menu saat ini: jadwal aktif (terbaru diubah menang) > harga outlet/kanal > harga kanal > harga dasar
create or replace function mst_get_menu_price(p_menu_item_id uuid, p_outlet_id uuid, p_channel text)
returns numeric language sql stable security definer set search_path = public as $$
  with loc as (select (now() at time zone timezone) as t from sys_outlets where id = p_outlet_id)
  select coalesce(
    (select si.price
     from mst_price_schedule_items si
     join mst_price_schedules s on s.id = si.schedule_id
     cross join loc
     where si.menu_item_id = p_menu_item_id and s.is_active
       and (s.outlet_ids is null or p_outlet_id = any(s.outlet_ids))
       and (s.sales_channels is null or p_channel = any(s.sales_channels))
       and (s.days_of_week is null or extract(isodow from loc.t)::int = any(s.days_of_week))
       and (s.start_date is null or loc.t::date >= s.start_date)
       and (s.end_date is null or loc.t::date <= s.end_date)
       and (s.start_time is null or loc.t::time >= s.start_time)
       and (s.end_time is null or loc.t::time <= s.end_time)
     order by s.updated_at desc
     limit 1),
    (select price from mst_menu_prices where menu_item_id = p_menu_item_id and outlet_id = p_outlet_id and sales_channel = p_channel),
    (select price from mst_menu_prices where menu_item_id = p_menu_item_id and outlet_id is null and sales_channel = p_channel),
    (select base_price from mst_menu_items where id = p_menu_item_id))
$$;

-- Untuk POS: harga semua menu aktif saat ini { menu_item_id: harga }
create or replace function mst_get_current_menu_prices(p_outlet_id uuid, p_channel text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(id, mst_get_menu_price(id, p_outlet_id, p_channel)), '{}'::jsonb)
  from mst_menu_items
  where company_id = sys_current_company_id() and is_active
$$;

-- =====================================================================
-- TAMBAH ITEM ORDER (versi baru: harga lewat jadwal)
-- =====================================================================
create or replace function pos_add_order_items(p_order_id uuid, p_items jsonb, p_kitchen_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order     pos_orders%rowtype;
  v_item      jsonb;
  v_menu      mst_menu_items%rowtype;
  v_price     numeric(15,2);
  v_mod_total numeric(15,2);
  v_qty       numeric(10,2);
  v_line_id   uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  if jsonb_array_length(coalesce(p_items, '[]')) = 0 then raise exception 'Order tidak punya item'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Terlalu banyak item dalam satu pesanan'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_menu from mst_menu_items
    where id = (v_item->>'menu_item_id')::uuid and company_id = v_order.company_id and is_active;
    if not found then raise exception 'Menu tidak ditemukan / tidak aktif'; end if;

    v_qty := coalesce((v_item->>'quantity')::numeric, 1);
    if v_qty <= 0 or v_qty > 99 then raise exception 'Jumlah tidak valid'; end if;

    v_price := mst_get_menu_price(v_menu.id, v_order.outlet_id, v_order.sales_channel);

    select coalesce(sum(m.extra_price), 0) into v_mod_total
    from mst_modifiers m
    join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id and l.menu_item_id = v_menu.id
    where m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);

    insert into pos_order_items (
      company_id, order_id, menu_item_id, menu_item_name, station,
      quantity, unit_price, modifier_amount, line_total, note, kitchen_status
    ) values (
      v_order.company_id, v_order.id, v_menu.id, v_menu.name, v_menu.station,
      v_qty, v_price, v_mod_total, v_qty * (v_price + v_mod_total),
      left(nullif(trim(v_item->>'note'), ''), 200), p_kitchen_status
    ) returning id into v_line_id;

    insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
    select v_order.company_id, v_line_id, m.id, m.name, m.extra_price
    from mst_modifiers m
    join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id and l.menu_item_id = v_menu.id
    where m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);
  end loop;

  perform pos_recalculate_order(v_order.id);
end $$;

-- Menu QR tamu (versi baru: harga lewat jadwal, info paket & isi default)
create or replace function public_get_table_menu(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_table  mst_tables%rowtype;
  v_outlet sys_outlets%rowtype;
begin
  select * into v_table from mst_tables where qr_token = p_token;
  if not found then raise exception 'QR tidak valid. Silakan minta bantuan pelayan.'; end if;
  select * into v_outlet from sys_outlets where id = v_table.outlet_id;
  if not v_outlet.is_active or not v_outlet.is_qr_order_enabled then
    raise exception 'Pemesanan lewat QR sedang tidak tersedia.';
  end if;

  return jsonb_build_object(
    'outlet', jsonb_build_object('name', v_outlet.name, 'tax_rate', v_outlet.tax_rate,
                                 'service_charge_rate', v_outlet.service_charge_rate,
                                 'requires_confirmation', v_outlet.qr_requires_confirmation),
    'company_name', (select name from sys_companies where id = v_outlet.company_id),
    'company_logo_url', (select logo_url from sys_companies where id = v_outlet.company_id),
    'table', jsonb_build_object('code', v_table.code),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name)
      from mst_menu_categories c
      where c.company_id = v_outlet.company_id and c.brand_id = v_outlet.brand_id and c.is_active
        and exists (select 1 from mst_menu_items i where i.menu_category_id = c.id and i.is_active)), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'description', i.description, 'image_url', i.image_url,
        'menu_category_id', i.menu_category_id,
        'price', mst_get_menu_price(i.id, v_outlet.id, 'dine_in'),
        'modifier_groups', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select, 'group_type', g.group_type,
            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'extra_price', m.extra_price,
                                                                       'is_default', m.is_default)
                                                    order by m.sort_order) from mst_modifiers m where m.modifier_group_id = g.id), '[]'::jsonb)))
          from mst_menu_item_modifier_groups l join mst_modifier_groups g on g.id = l.modifier_group_id
          where l.menu_item_id = i.id), '[]'::jsonb)
      ) order by i.name)
      from mst_menu_items i
      where i.company_id = v_outlet.company_id and i.brand_id = v_outlet.brand_id and i.is_active), '[]'::jsonb)
  );
end $$;

-- >>>>>>>>>> migrations/017_company_app_name.sql
-- =====================================================================
-- SANTAP ERP - 017: NAMA APLIKASI BISA DIATUR PER PERUSAHAAN
--   Tampil di sidebar & judul tab. Kosong = nama default aplikasi.
-- =====================================================================

alter table sys_companies add column app_name text;
alter table sys_companies add constraint sys_companies_app_name_check check (app_name is null or length(trim(app_name)) between 1 and 40);

-- Profil login (versi baru: + nama aplikasi perusahaan)
create or replace function sys_get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', u.id,
    'full_name', u.full_name,
    'phone', u.phone,
    'avatar_url', u.avatar_url,
    'email', (select email from auth.users where id = u.id),
    'company_id', c.id,
    'company_name', c.name,
    'company_app_name', c.app_name,
    'company_logo_url', c.logo_url,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

-- >>>>>>>>>> migrations/018_stock_purposes_opname.sql
-- =====================================================================
-- SANTAP ERP - 018: PURPOSE STOK + ALUR STOCK OPNAME BARU
--   * Dokumen stok: Penyesuaian (+/-), Waste, Pemakaian (usage), Penyusutan (shrinkage)
--   * Purpose (sub alasan) per jenis dokumen, masing-masing terhubung ke akun COA
--   * Jurnal: lawan persediaan = akun purpose (per baris), default per jenis
--   * Stock opname: qty sistem DIPOTRET saat daftar dibuat; selisih = fisik - potret,
--     sehingga penjualan setelah penghitungan tidak mengacaukan selisih
-- =====================================================================

-- =====================================================================
-- AKUN DEFAULT BARU
-- =====================================================================
create or replace function fin_ensure_stock_accounts(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_parent uuid;
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  select id into v_parent from fin_accounts where company_id = p_company_id and code = '5-0000';
  insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance, system_key)
  select p_company_id, v_parent, x.code, x.name, 'cogs', 'debit', x.skey
  from (values ('5-1400', 'Pemakaian Bahan & Perlengkapan', 'usage_expense'),
               ('5-1500', 'Penyusutan Persediaan',          'shrinkage_expense')) as x(code, name, skey)
  where not exists (select 1 from fin_accounts a where a.company_id = p_company_id and (a.system_key = x.skey or a.code = x.code));
end $$;

-- =====================================================================
-- PURPOSE (sub alasan) PER JENIS DOKUMEN STOK
-- =====================================================================
create table inv_adjustment_purposes (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  adjustment_type  text not null check (adjustment_type in ('adjustment', 'waste', 'usage', 'shrinkage')),
  code             text,
  name             text not null,
  account_id       uuid references fin_accounts(id),   -- null = akun default jenisnya
  notes            text,
  sort_order       int not null default 0,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index uq_inv_adjustment_purposes_name on inv_adjustment_purposes(company_id, adjustment_type, lower(name));

create or replace function inv_setup_adjustment_purposes(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform fin_ensure_stock_accounts(p_company_id);
  insert into inv_adjustment_purposes (company_id, adjustment_type, name, account_id, sort_order)
  select p_company_id, x.t, x.name,
         (select id from fin_accounts a where a.company_id = p_company_id
            and (a.system_key = x.key or a.code = x.code) order by (a.system_key = x.key) desc limit 1),
         x.sort
  from (values
    ('adjustment', 'Koreksi Input',               null,                null,    1),
    ('adjustment', 'Barang Ditemukan',            null,                null,    2),
    ('waste',      'Human Error',                 'waste_expense',     null,    1),
    ('waste',      'Kedaluwarsa',                 'waste_expense',     null,    2),
    ('waste',      'Rusak / Basi',                'waste_expense',     null,    3),
    ('waste',      'Retur / Komplain Pelanggan',  'waste_expense',     null,    4),
    ('usage',      'Peralatan Dapur',             'usage_expense',     null,    1),
    ('usage',      'Perlengkapan & Kebersihan',   null,                '6-1600', 2),
    ('usage',      'Makan Karyawan',              null,                '6-1100', 3),
    ('usage',      'Tester / Sampling',           null,                '6-1500', 4),
    ('usage',      'Entertain / Complimentary',   null,                '6-1500', 5),
    ('shrinkage',  'Penyusutan Bahan Baku',       'shrinkage_expense', null,    1),
    ('shrinkage',  'Penyusutan Produksi (susut masak)', 'shrinkage_expense', null, 2),
    ('shrinkage',  'Penguapan / Penyimpanan',     'shrinkage_expense', null,    3)
  ) as x(t, name, key, code, sort)
  on conflict do nothing;
end $$;

-- =====================================================================
-- DOKUMEN PENYESUAIAN: jenis baru + purpose per dokumen / per baris
-- =====================================================================
alter table inv_stock_adjustments add constraint inv_stock_adjustments_type_check
  check (adjustment_type in ('adjustment', 'waste', 'usage', 'shrinkage'));
alter table inv_stock_adjustments add column purpose_id uuid references inv_adjustment_purposes(id);
alter table inv_stock_adjustment_items add column purpose_id uuid references inv_adjustment_purposes(id);

-- akun lawan persediaan yang dipakai jurnal (diisi saat posting dokumen stok)
alter table inv_stock_movements add column counter_account_id uuid references fin_accounts(id);

create or replace function inv_post_stock_adjustment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_adjustments%rowtype;
  v_value numeric(15,2);
  v_label text;
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_adjustment')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from inv_stock_adjustments
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from inv_stock_adjustment_items where stock_adjustment_id = p_id and quantity <> 0) then
    raise exception 'Dokumen belum punya item';
  end if;
  if v_doc.adjustment_type <> 'adjustment' and exists (
      select 1 from inv_stock_adjustment_items where stock_adjustment_id = p_id and coalesce(purpose_id, v_doc.purpose_id) is null) then
    raise exception 'Pilih purpose / alasan untuk dokumen ini';
  end if;

  select coalesce(sum(abs(i.quantity) * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
  from inv_stock_adjustment_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id
  where i.stock_adjustment_id = p_id;

  v_label := case v_doc.adjustment_type when 'waste' then 'Waste' when 'usage' then 'Pemakaian'
                                        when 'shrinkage' then 'Penyusutan' else 'Penyesuaian stok' end;

  if sys_approval_required('stock_adjustment', v_value) then
    if v_doc.status = 'pending_approval' then raise exception 'Dokumen ini masih menunggu persetujuan'; end if;
    update inv_stock_adjustments set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_adjustment', p_id,
      (select outlet_id from inv_warehouses where id = v_doc.warehouse_id), v_value,
      v_label || ' ' || (select name from inv_warehouses where id = v_doc.warehouse_id), '{}');
    return;
  end if;

  v_doc.adjustment_number := coalesce(v_doc.adjustment_number, sys_next_document_number(v_doc.company_id,
    case v_doc.adjustment_type when 'waste' then 'WST' when 'usage' then 'USG' when 'shrinkage' then 'SHR' else 'ADJ' end,
    v_doc.adjustment_date));

  -- waste / pemakaian / penyusutan selalu mengurangi stok
  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, note, created_by, counter_account_id)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, v_doc.adjustment_type,
         case when v_doc.adjustment_type = 'adjustment' then i.quantity else -abs(i.quantity) end,
         'inv_stock_adjustments', v_doc.id, v_doc.adjustment_number,
         coalesce(i.note, p.name), auth.uid(),
         coalesce(p.account_id,
           case v_doc.adjustment_type
             when 'waste'     then fin_account_id_or_null(v_doc.company_id, 'waste_expense')
             when 'usage'     then fin_account_id_or_null(v_doc.company_id, 'usage_expense')
             when 'shrinkage' then fin_account_id_or_null(v_doc.company_id, 'shrinkage_expense')
           end)
  from inv_stock_adjustment_items i
  left join inv_adjustment_purposes p on p.id = coalesce(i.purpose_id, v_doc.purpose_id)
  where i.stock_adjustment_id = p_id and i.quantity <> 0;

  update inv_stock_adjustments
     set status = 'posted', posted_at = now(), adjustment_number = v_doc.adjustment_number
   where id = p_id;
  perform sys_close_approval('stock_adjustment', p_id);
end $$;

-- versi aman fin_account_id: null bila akun belum ada (perusahaan tanpa modul keuangan)
create or replace function fin_account_id_or_null(p_company_id uuid, p_key text)
returns uuid language sql stable security definer set search_path = public as $$
  select id from fin_accounts where company_id = p_company_id and system_key = p_key
$$;

-- Jurnal dokumen penyesuaian: persediaan per kategori | akun lawan per baris (purpose)
create or replace function fin_post_stock_adjustment_journal(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  d       inv_stock_adjustments%rowtype;
  v_lines jsonb;
begin
  select * into d from inv_stock_adjustments where id = p_id and status = 'posted';
  if not found or not exists (select 1 from fin_accounts where company_id = d.company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = 'stock_adjustment' and source_id = d.id) then return; end if;

  with v as (
    select fin_item_account(m.item_id, 'inventory') as inv_acc,
           coalesce(m.counter_account_id, fin_item_account(m.item_id, 'adjustment')) as ctr_acc,
           round(m.quantity * coalesce(m.unit_cost, 0), 2) as value
    from inv_stock_movements m
    where m.reference_type = 'inv_stock_adjustments' and m.reference_id = d.id
  )
  select coalesce(jsonb_agg(jsonb_build_object('account_id', acc, 'debit', val)), '[]'::jsonb) into v_lines
  from (select inv_acc acc, sum(value) val from v group by inv_acc
        union all
        select ctr_acc, -sum(value) from v group by ctr_acc) x
  where val <> 0;

  perform fin_create_journal(d.company_id, (select outlet_id from inv_warehouses where id = d.warehouse_id),
    d.adjustment_date, 'stock_adjustment', d.id, 'Stok ' || d.adjustment_number, v_lines);
end $$;

create or replace function fin_on_document_posted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'pur_goods_receipts' then
    perform fin_post_goods_receipt_journal(new.id);
  elsif tg_table_name = 'inv_stock_adjustments' then
    perform fin_post_stock_adjustment_journal(new.id);
  elsif tg_table_name = 'inv_stock_opnames' then
    perform fin_post_stock_document_journal(new.company_id, 'inv_stock_opnames', new.id, new.opname_date,
      new.opname_number, 'inventory_adjustment', 'stock_opname');
  end if;
  return new;
end $$;

-- =====================================================================
-- STOCK OPNAME: potret qty sistem saat daftar dibuat
-- =====================================================================
alter table inv_stock_opnames add column snapshot_at timestamptz;
alter table inv_stock_opnames add column item_category_id uuid references inv_item_categories(id);
alter table inv_stock_opname_items alter column counted_qty drop not null;   -- null = belum dihitung
alter table inv_stock_opname_items add column unit_cost numeric(15,4);       -- HPP saat potret (untuk nilai selisih)

-- baris baru otomatis memotret qty & HPP sistem saat itu
create or replace function inv_snapshot_opname_item()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_wh uuid;
begin
  if new.system_qty is null then
    select warehouse_id into v_wh from inv_stock_opnames where id = new.stock_opname_id;
    select coalesce(s.quantity, 0), coalesce(nullif(s.average_cost, 0), i.last_purchase_cost)
      into new.system_qty, new.unit_cost
    from inv_items i left join inv_stocks s on s.item_id = i.id and s.warehouse_id = v_wh
    where i.id = new.item_id;
  end if;
  new.difference_qty := case when new.counted_qty is null then null else new.counted_qty - new.system_qty end;
  return new;
end $$;

create trigger trg_inv_stock_opname_items_snapshot before insert or update of counted_qty, system_qty on inv_stock_opname_items
  for each row execute function inv_snapshot_opname_item();

-- isi daftar opname dengan semua produk stok aktif di gudang (opsional per kategori)
create or replace function inv_generate_opname_items(p_opname_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_opnames%rowtype;
  v_count int;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_opnames where id = p_opname_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Opname tidak ditemukan / bukan draft'; end if;

  insert into inv_stock_opname_items (company_id, stock_opname_id, item_id)
  select v_doc.company_id, v_doc.id, i.id
  from inv_items i
  join inv_item_categories c on c.id = i.item_category_id
  where i.company_id = v_doc.company_id and i.is_active and i.approval_status = 'approved'
    and c.category_type = 'inventory'
    and (v_doc.item_category_id is null or i.item_category_id = v_doc.item_category_id)
    and not exists (select 1 from inv_stock_opname_items x where x.stock_opname_id = v_doc.id and x.item_id = i.id);
  get diagnostics v_count = row_count;

  update inv_stock_opnames set snapshot_at = coalesce(snapshot_at, now()) where id = v_doc.id;
  return v_count;
end $$;

-- potret ulang (mis. penghitungan ditunda ke hari lain)
create or replace function inv_refresh_opname_snapshot(p_opname_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  if not exists (select 1 from inv_stock_opnames where id = p_opname_id and company_id = sys_current_company_id() and status = 'draft') then
    raise exception 'Opname tidak ditemukan / bukan draft';
  end if;
  update inv_stock_opname_items set system_qty = null, unit_cost = null where stock_opname_id = p_opname_id;
  update inv_stock_opnames set snapshot_at = now() where id = p_opname_id;
end $$;

create or replace function inv_post_stock_opname(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_opnames%rowtype;
  v_value numeric(15,2);
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_opname')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from inv_stock_opnames
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from inv_stock_opname_items where stock_opname_id = p_id and counted_qty is not null) then
    raise exception 'Belum ada produk yang dihitung';
  end if;

  -- nilai selisih terhadap POTRET (bukan stok saat ini)
  select coalesce(sum(abs(difference_qty) * coalesce(unit_cost, 0)), 0) into v_value
  from inv_stock_opname_items where stock_opname_id = p_id and counted_qty is not null;

  if sys_approval_required('stock_opname', v_value) then
    if v_doc.status = 'pending_approval' then raise exception 'Dokumen ini masih menunggu persetujuan'; end if;
    update inv_stock_opnames set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_opname', p_id,
      (select outlet_id from inv_warehouses where id = v_doc.warehouse_id), v_value,
      'Stock opname ' || (select name from inv_warehouses where id = v_doc.warehouse_id), '{}');
    return;
  end if;

  v_doc.opname_number := coalesce(v_doc.opname_number, sys_next_document_number(v_doc.company_id, 'OPN', v_doc.opname_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'opname', i.difference_qty,
         'inv_stock_opnames', v_doc.id, v_doc.opname_number, auth.uid()
  from inv_stock_opname_items i
  where i.stock_opname_id = p_id and i.counted_qty is not null and i.difference_qty <> 0;

  update inv_stock_opnames
     set status = 'posted', posted_at = now(), opname_number = v_doc.opname_number
   where id = p_id;
  perform sys_close_approval('stock_opname', p_id);
end $$;

-- =====================================================================
-- TRIGGER, RLS, DATA AWAL
-- =====================================================================
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('inv_adjustment_purposes', 'inventory.manage');
create trigger trg_inv_adjustment_purposes_audit after insert or update or delete on inv_adjustment_purposes
  for each row execute function sys_audit_trigger('');

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform inv_setup_adjustment_purposes(r.id); end loop;
end $$;

-- Perusahaan baru: purpose & akun dibuat setelah onboarding
alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v3;
revoke execute on function sys_onboard_company_v3(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v3(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform inv_setup_adjustment_purposes((v_result->>'company_id')::uuid);
  return v_result;
end $$;

revoke execute on function fin_ensure_stock_accounts(uuid)          from public, anon, authenticated;
revoke execute on function inv_setup_adjustment_purposes(uuid)      from public, anon, authenticated;
revoke execute on function fin_post_stock_adjustment_journal(uuid)  from public, anon, authenticated;
revoke execute on function fin_account_id_or_null(uuid, text)       from public, anon, authenticated;

-- >>>>>>>>>> migrations/019_stock_batches_fifo.sql
-- =====================================================================
-- SANTAP ERP - 019: BATCH / LOT, FIFO COST (FEFO), KOLI TRANSFER, BARCODE
--   * Setiap stok masuk = 1 batch (kode label sendiri, lot supplier, kedaluwarsa, harga)
--   * Stok keluar mengambil batch FEFO (kedaluwarsa duluan), lalu FIFO (masuk duluan)
--   * HPP = harga batch yang terpakai (FIFO cost); inv_stocks.average_cost = nilai sisa / qty
--   * Jejak per batch: inv_stock_movement_batches (movement <-> batch)
--   * Transfer bisa dikirim per KOLI (dalam perjalanan) lalu diterima dengan scan label koli
-- =====================================================================

-- ---------------------------------------------------------------------
-- MASTER PRODUK
-- ---------------------------------------------------------------------
alter table inv_items add column track_batch     boolean not null default false;  -- wajib kedaluwarsa saat terima, label batch
alter table inv_items add column shelf_life_days int;                              -- umur simpan: kedaluwarsa otomatis
alter table inv_items add constraint inv_items_shelf_life_check check (shelf_life_days is null or shelf_life_days > 0);

-- ---------------------------------------------------------------------
-- BATCH & ALOKASI
-- ---------------------------------------------------------------------
create table inv_stock_batches (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  warehouse_id     uuid not null references inv_warehouses(id),
  item_id          uuid not null references inv_items(id),
  batch_code       text not null,                 -- kode label (barcode), ikut pindah gudang
  lot_number       text,                          -- nomor lot dari supplier / pabrik
  expiry_date      date,
  received_at      timestamptz not null default now(),   -- umur batch (urutan FIFO)
  qty_in           numeric(15,4) not null default 0,
  qty_remaining    numeric(15,4) not null default 0 check (qty_remaining >= 0),
  unit_cost        numeric(15,4) not null default 0,
  origin_batch_id  uuid references inv_stock_batches(id),  -- batch asal (hasil transfer)
  reference_type   text,
  reference_id     uuid,
  reference_number text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (warehouse_id, item_id, batch_code)
);
create index idx_inv_stock_batches_fefo on inv_stock_batches(warehouse_id, item_id, expiry_date, received_at) where qty_remaining > 0;
create index idx_inv_stock_batches_code on inv_stock_batches(company_id, batch_code);

-- movement -> batch: + masuk ke batch, - keluar dari batch
create table inv_stock_movement_batches (
  id           uuid primary key default gen_random_uuid(),
  seq          bigint generated always as identity,
  company_id   uuid not null references sys_companies(id),
  movement_id  uuid not null references inv_stock_movements(id) on delete cascade deferrable initially deferred,
  batch_id     uuid not null references inv_stock_batches(id),
  quantity     numeric(15,4) not null,
  unit_cost    numeric(15,4) not null,
  is_backfill  boolean not null default false,   -- menutup stok minus sebelumnya
  created_at   timestamptz not null default now()
);
create index idx_inv_stock_movement_batches_mv    on inv_stock_movement_batches(movement_id);
create index idx_inv_stock_movement_batches_batch on inv_stock_movement_batches(batch_id);

alter table inv_stock_movements add column batch_id           uuid references inv_stock_batches(id);  -- batch dipilih (scan label)
alter table inv_stock_movements add column batch_code         text;     -- kode batch untuk stok masuk (opsional)
alter table inv_stock_movements add column lot_number         text;
alter table inv_stock_movements add column expiry_date        date;
alter table inv_stock_movements add column source_movement_id uuid references inv_stock_movements(id);  -- refund / transfer: ikut batch asal
alter table inv_stock_movements add column unbatched_qty      numeric(15,4);  -- qty keluar saat stok batch kosong (stok minus)

-- Kode label pendek & mudah discan: L + YYMMDD + urut (mis. L2610070001)
create or replace function inv_next_batch_code(p_company_id uuid, p_date date default current_date)
returns text language sql security definer set search_path = public as $$
  select 'L' || to_char(p_date, 'YYMMDD') || lpad(sys_next_sequence(p_company_id, 'LOT/' || to_char(p_date, 'YYYYMMDD'))::text, 4, '0')
$$;

-- Harga cadangan bila tidak ada batch (stok minus / produk baru)
create or replace function inv_fallback_cost(p_warehouse_id uuid, p_item_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(average_cost, 0) from inv_stocks where warehouse_id = p_warehouse_id and item_id = p_item_id),
    (select nullif(unit_cost, 0) from inv_stock_batches where warehouse_id = p_warehouse_id and item_id = p_item_id
      order by received_at desc, created_at desc limit 1),
    (select last_purchase_cost from inv_items where id = p_item_id),
    0)
$$;

-- Ambil qty dari batch: batch pilihan dulu, lalu FEFO (kedaluwarsa terdekat), lalu FIFO
create or replace function inv_consume_batches(
  p_movement_id uuid, p_warehouse_id uuid, p_item_id uuid, p_qty numeric,
  p_prefer_batch_id uuid default null, p_backfill boolean default false,
  out consumed_value numeric, out unallocated_qty numeric)
language plpgsql security definer set search_path = public as $$
declare
  b      record;
  v_take numeric;
begin
  consumed_value := 0;
  unallocated_qty := p_qty;
  for b in
    select id, company_id, qty_remaining, unit_cost from inv_stock_batches
    where warehouse_id = p_warehouse_id and item_id = p_item_id and qty_remaining > 0
    order by coalesce(id = p_prefer_batch_id, false) desc, expiry_date nulls last, received_at, created_at
    for update
  loop
    exit when unallocated_qty <= 0;
    v_take := least(unallocated_qty, b.qty_remaining);
    update inv_stock_batches set qty_remaining = qty_remaining - v_take where id = b.id;
    insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost, is_backfill)
    values (b.company_id, p_movement_id, b.id, -v_take, b.unit_cost, p_backfill);
    consumed_value := consumed_value + v_take * b.unit_cost;
    unallocated_qty := unallocated_qty - v_take;
  end loop;
end $$;

-- Tambah qty ke batch (buat baru, atau gabung bila kode batch sama di gudang yang sama)
create or replace function inv_add_to_batch(
  p_movement_id uuid, p_company_id uuid, p_warehouse_id uuid, p_item_id uuid, p_qty numeric, p_cost numeric,
  p_batch_code text, p_lot text, p_expiry date, p_received_at timestamptz, p_origin uuid,
  p_ref_type text, p_ref_id uuid, p_ref_number text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into inv_stock_batches as b (company_id, warehouse_id, item_id, batch_code, lot_number, expiry_date, received_at,
    qty_in, qty_remaining, unit_cost, origin_batch_id, reference_type, reference_id, reference_number)
  values (p_company_id, p_warehouse_id, p_item_id, p_batch_code, nullif(trim(p_lot), ''), p_expiry, coalesce(p_received_at, now()),
    p_qty, p_qty, p_cost, p_origin, p_ref_type, p_ref_id, p_ref_number)
  on conflict (warehouse_id, item_id, batch_code) do update set
    unit_cost     = case when b.qty_remaining + excluded.qty_remaining > 0
                         then (b.qty_remaining * b.unit_cost + excluded.qty_remaining * excluded.unit_cost) / (b.qty_remaining + excluded.qty_remaining)
                         else excluded.unit_cost end,
    qty_in        = b.qty_in + excluded.qty_in,
    qty_remaining = b.qty_remaining + excluded.qty_remaining,
    lot_number    = coalesce(b.lot_number, excluded.lot_number),
    expiry_date   = coalesce(b.expiry_date, excluded.expiry_date)
  returning id into v_id;

  insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
  values (p_company_id, p_movement_id, v_id, p_qty, p_cost);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- MESIN STOK: setiap movement -> batch (FIFO cost) + saldo inv_stocks
-- ---------------------------------------------------------------------
create or replace function inv_apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_stock  inv_stocks%rowtype;
  v_item   inv_items%rowtype;
  v_value  numeric := 0;
  v_left   numeric;
  v_cost   numeric;
  v_take   numeric;
  v_rec    record;
  v_src    inv_stock_batches%rowtype;
begin
  insert into inv_stocks (company_id, warehouse_id, item_id)
  values (new.company_id, new.warehouse_id, new.item_id)
  on conflict (warehouse_id, item_id) do nothing;

  select * into v_stock from inv_stocks
  where warehouse_id = new.warehouse_id and item_id = new.item_id
  for update;
  select * into v_item from inv_items where id = new.item_id;

  if new.quantity < 0 then
    -- KELUAR: harga = batch yang terambil
    select c.consumed_value, c.unallocated_qty into v_value, v_left
    from inv_consume_batches(new.id, new.warehouse_id, new.item_id, -new.quantity, new.batch_id) c;
    if v_left > 0 then
      new.unbatched_qty := v_left;
      v_value := v_value + v_left * inv_fallback_cost(new.warehouse_id, new.item_id);
    end if;
    new.unit_cost := round(v_value / -new.quantity, 4);

  elsif new.quantity > 0 then
    v_left := new.quantity;

    -- MASUK dari movement lain (refund / transfer): ikut batch & harga asal
    if new.source_movement_id is not null then
      for v_rec in
        select a.batch_id, -a.quantity as qty, a.unit_cost from inv_stock_movement_batches a
        where a.movement_id = new.source_movement_id and a.quantity < 0 and not a.is_backfill
        order by a.seq
      loop
        exit when v_left <= 0;
        v_take := least(v_left, v_rec.qty);
        select * into v_src from inv_stock_batches where id = v_rec.batch_id;
        if v_src.warehouse_id = new.warehouse_id and v_src.item_id = new.item_id then
          update inv_stock_batches set qty_remaining = qty_remaining + v_take where id = v_src.id;
          insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
          values (new.company_id, new.id, v_src.id, v_take, v_rec.unit_cost);
        else
          perform inv_add_to_batch(new.id, new.company_id, new.warehouse_id, new.item_id, v_take, v_rec.unit_cost,
            v_src.batch_code, v_src.lot_number, v_src.expiry_date, v_src.received_at, coalesce(v_src.origin_batch_id, v_src.id),
            new.reference_type, new.reference_id, new.reference_number);
        end if;
        v_value := v_value + v_take * v_rec.unit_cost;
        v_left := v_left - v_take;
      end loop;
      v_cost := coalesce((select unit_cost from inv_stock_movements where id = new.source_movement_id), new.unit_cost);
    end if;

    -- MASUK biasa (penerimaan, produksi, penyesuaian +): batch baru
    if v_left > 0 then
      v_cost := coalesce(v_cost, new.unit_cost, inv_fallback_cost(new.warehouse_id, new.item_id));
      if new.batch_id is not null and exists (
          select 1 from inv_stock_batches where id = new.batch_id and warehouse_id = new.warehouse_id and item_id = new.item_id) then
        update inv_stock_batches set
          unit_cost     = case when qty_remaining + v_left > 0 then (qty_remaining * unit_cost + v_left * v_cost) / (qty_remaining + v_left) else v_cost end,
          qty_in        = qty_in + v_left,
          qty_remaining = qty_remaining + v_left
        where id = new.batch_id;
        insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
        values (new.company_id, new.id, new.batch_id, v_left, v_cost);
      else
        perform inv_add_to_batch(new.id, new.company_id, new.warehouse_id, new.item_id, v_left, v_cost,
          coalesce(nullif(trim(new.batch_code), ''), inv_next_batch_code(new.company_id)),
          new.lot_number,
          coalesce(new.expiry_date, new.movement_at::date + v_item.shelf_life_days),
          new.movement_at, null, new.reference_type, new.reference_id, new.reference_number);
      end if;
      v_value := v_value + v_left * v_cost;
    end if;
    new.unit_cost := round(v_value / new.quantity, 4);

    -- stok sebelumnya minus: batch baru langsung menutup kekurangannya
    if v_stock.quantity < 0 then
      perform inv_consume_batches(new.id, new.warehouse_id, new.item_id, least(new.quantity, -v_stock.quantity), null, true);
    end if;
  end if;

  v_stock.quantity := v_stock.quantity + new.quantity;
  new.balance_after := v_stock.quantity;

  update inv_stocks set
    quantity     = v_stock.quantity,
    average_cost = coalesce(
      (select sum(qty_remaining * unit_cost) / nullif(sum(qty_remaining), 0) from inv_stock_batches
        where warehouse_id = new.warehouse_id and item_id = new.item_id and qty_remaining > 0),
      case when new.quantity > 0 then new.unit_cost else v_stock.average_cost end)
  where id = v_stock.id;

  return new;
end $$;

-- Saldo stok yang sudah ada -> batch saldo awal (harga = HPP rata-rata saat ini)
do $$
declare r record;
begin
  for r in select * from inv_stocks where quantity > 0 loop
    insert into inv_stock_batches (company_id, warehouse_id, item_id, batch_code, received_at, qty_in, qty_remaining,
                                   unit_cost, reference_type, reference_number)
    values (r.company_id, r.warehouse_id, r.item_id, inv_next_batch_code(r.company_id), now() - interval '1 second',
            r.quantity, r.quantity, r.average_cost, 'opening', 'Saldo awal');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- PENERIMAAN BARANG: lot & kedaluwarsa per baris
-- ---------------------------------------------------------------------
alter table pur_goods_receipt_items add column lot_number  text;
alter table pur_goods_receipt_items add column expiry_date date;

create or replace function pur_post_goods_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc     pur_goods_receipts%rowtype;
  v_missing text;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_goods_receipts
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id) then
    raise exception 'Penerimaan belum punya item';
  end if;

  select string_agg(it.name, ', ') into v_missing
  from pur_goods_receipt_items i join inv_items it on it.id = i.item_id
  where i.goods_receipt_id = p_id and it.track_batch and i.expiry_date is null and it.shelf_life_days is null;
  if v_missing is not null then
    raise exception 'Isi tanggal kedaluwarsa untuk produk yang dilacak batch: %', v_missing;
  end if;

  update pur_goods_receipt_items set line_total = quantity * unit_price where goods_receipt_id = p_id;

  v_doc.receipt_number := coalesce(v_doc.receipt_number,
    sys_next_document_number(v_doc.company_id, 'GR', v_doc.receipt_date));

  -- stok masuk (dikonversi ke base unit), 1 baris = 1 batch
  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
    reference_type, reference_id, reference_number, created_by, lot_number, expiry_date)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'purchase_receipt',
         i.quantity * i.conversion_qty, i.unit_price / i.conversion_qty,
         'pur_goods_receipts', v_doc.id, v_doc.receipt_number, auth.uid(), i.lot_number, i.expiry_date
  from pur_goods_receipt_items i where i.goods_receipt_id = p_id and i.quantity > 0
  order by i.created_at, i.id;

  -- harga beli terakhir per base unit
  update inv_items it set last_purchase_cost = i.unit_price / i.conversion_qty
  from pur_goods_receipt_items i
  where i.goods_receipt_id = p_id and it.id = i.item_id;

  update pur_purchase_order_items poi
     set received_qty = poi.received_qty + gri.total_qty
  from (select purchase_order_item_id, sum(quantity) total_qty
        from pur_goods_receipt_items
        where goods_receipt_id = p_id and purchase_order_item_id is not null
        group by purchase_order_item_id) gri
  where poi.id = gri.purchase_order_item_id;

  if v_doc.purchase_order_id is not null then
    update pur_purchase_orders po set status =
      case when exists (select 1 from pur_purchase_order_items
                        where purchase_order_id = po.id and received_qty < quantity)
           then 'partially_received' else 'received' end
    where id = v_doc.purchase_order_id;
  end if;

  update pur_goods_receipts set
    status = 'posted', posted_at = now(), receipt_number = v_doc.receipt_number,
    grand_total = (select coalesce(sum(line_total), 0) from pur_goods_receipt_items where goods_receipt_id = p_id)
  where id = p_id
  returning * into v_doc;

  return to_jsonb(v_doc);
end $$;

-- ---------------------------------------------------------------------
-- DOKUMEN PENYESUAIAN: baris boleh menunjuk batch (hasil scan label)
-- ---------------------------------------------------------------------
alter table inv_stock_adjustment_items add column batch_id uuid references inv_stock_batches(id);

create or replace function inv_post_stock_adjustment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_adjustments%rowtype;
  v_value numeric(15,2);
  v_label text;
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_adjustment')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from inv_stock_adjustments
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from inv_stock_adjustment_items where stock_adjustment_id = p_id and quantity <> 0) then
    raise exception 'Dokumen belum punya item';
  end if;
  if v_doc.adjustment_type <> 'adjustment' and exists (
      select 1 from inv_stock_adjustment_items where stock_adjustment_id = p_id and coalesce(purpose_id, v_doc.purpose_id) is null) then
    raise exception 'Pilih purpose / alasan untuk dokumen ini';
  end if;

  select coalesce(sum(abs(i.quantity) * coalesce(b.unit_cost, nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
  from inv_stock_adjustment_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id
  left join inv_stock_batches b on b.id = i.batch_id
  where i.stock_adjustment_id = p_id;

  v_label := case v_doc.adjustment_type when 'waste' then 'Waste' when 'usage' then 'Pemakaian'
                                        when 'shrinkage' then 'Penyusutan' else 'Penyesuaian stok' end;

  if sys_approval_required('stock_adjustment', v_value) then
    if v_doc.status = 'pending_approval' then raise exception 'Dokumen ini masih menunggu persetujuan'; end if;
    update inv_stock_adjustments set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_adjustment', p_id,
      (select outlet_id from inv_warehouses where id = v_doc.warehouse_id), v_value,
      v_label || ' ' || (select name from inv_warehouses where id = v_doc.warehouse_id), '{}');
    return;
  end if;

  v_doc.adjustment_number := coalesce(v_doc.adjustment_number, sys_next_document_number(v_doc.company_id,
    case v_doc.adjustment_type when 'waste' then 'WST' when 'usage' then 'USG' when 'shrinkage' then 'SHR' else 'ADJ' end,
    v_doc.adjustment_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, note, created_by, counter_account_id, batch_id)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, v_doc.adjustment_type,
         case when v_doc.adjustment_type = 'adjustment' then i.quantity else -abs(i.quantity) end,
         'inv_stock_adjustments', v_doc.id, v_doc.adjustment_number,
         coalesce(i.note, p.name), auth.uid(),
         coalesce(p.account_id,
           case v_doc.adjustment_type
             when 'waste'     then fin_account_id_or_null(v_doc.company_id, 'waste_expense')
             when 'usage'     then fin_account_id_or_null(v_doc.company_id, 'usage_expense')
             when 'shrinkage' then fin_account_id_or_null(v_doc.company_id, 'shrinkage_expense')
           end),
         i.batch_id
  from inv_stock_adjustment_items i
  left join inv_adjustment_purposes p on p.id = coalesce(i.purpose_id, v_doc.purpose_id)
  where i.stock_adjustment_id = p_id and i.quantity <> 0
  order by i.created_at, i.id;

  update inv_stock_adjustments
     set status = 'posted', posted_at = now(), adjustment_number = v_doc.adjustment_number
   where id = p_id;
  perform sys_close_approval('stock_adjustment', p_id);
end $$;

-- ---------------------------------------------------------------------
-- REFUND: stok kembali ke batch asalnya
-- ---------------------------------------------------------------------
create or replace function pos_refund_order_execute(p_order_id uuid, p_reason text, p_return_stock boolean, p_cashier_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o         pos_orders%rowtype;
  r         pos_refunds%rowtype;
  v_shift   uuid;
  v_date    date;
  v_cust    crm_customers%rowtype;
  v_deduct  int;
  v_balance int;
  v_journal uuid;
  v_lines   jsonb;
begin
  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if o.status <> 'paid' then raise exception 'Hanya order lunas yang bisa direfund'; end if;

  select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = p_cashier_id and status = 'open' limit 1;
  if v_shift is null and exists (
      select 1 from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
      where p.order_id = o.id and m.type = 'cash') then
    raise exception 'Kasir harus membuka shift dulu (uang tunai dikembalikan dari laci)';
  end if;
  v_date := sys_outlet_business_date(o.outlet_id);

  insert into pos_refunds (company_id, outlet_id, order_id, shift_id, refund_number, business_date, amount,
                           reason, is_stock_returned, refunded_by)
  values (o.company_id, o.outlet_id, o.id, v_shift, sys_next_document_number(o.company_id, 'RFD', v_date), v_date,
          o.grand_total, trim(p_reason), coalesce(p_return_stock, false), p_cashier_id)
  returning * into r;

  insert into pos_refund_payments (company_id, refund_id, payment_method_id, amount)
  select o.company_id, r.id, payment_method_id, amount - change_amount
  from pos_payments where order_id = o.id;

  update pos_orders set status = 'refunded', refunded_at = now() where id = o.id;

  if p_return_stock then
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, note, created_by, source_movement_id)
    select company_id, warehouse_id, item_id, 'sales_return', -quantity, unit_cost,
           'pos_refunds', r.id, r.refund_number, 'Refund ' || o.order_number, auth.uid(), id
    from inv_stock_movements where reference_type = 'pos_orders' and reference_id = o.id;
  end if;

  if o.customer_id is not null then
    select * into v_cust from crm_customers where id = o.customer_id for update;
    v_deduct := least(o.points_earned, v_cust.points_balance + o.points_redeemed);
    v_balance := v_cust.points_balance + o.points_redeemed - v_deduct;
    if o.points_redeemed - v_deduct <> 0 then
      insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
      values (o.company_id, o.customer_id, o.id, 'refund', o.points_redeemed - v_deduct, v_balance,
              'Refund ' || o.order_number, auth.uid());
    end if;
    update crm_customers set
      points_balance = v_balance,
      total_spent    = greatest(total_spent - o.grand_total, 0),
      visit_count    = greatest(visit_count - 1, 0)
    where id = o.customer_id;
  end if;

  if o.promotion_id is not null then
    update crm_promotions set usage_count = greatest(usage_count - 1, 0) where id = o.promotion_id;
  end if;

  select id into v_journal from fin_journals where source_type = 'sales' and source_id = o.id;
  if v_journal is not null then
    select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'note', l.note))
      into v_lines
    from fin_journal_lines l join fin_accounts a on a.id = l.account_id
    where l.journal_id = v_journal
      and (p_return_stock or coalesce(a.system_key, '') not in ('cogs', 'inventory'));
    perform fin_create_journal(o.company_id, o.outlet_id, v_date, 'sales_refund', o.id,
                               'Refund ' || o.order_number || ' - ' || trim(p_reason), v_lines);
  end if;

  return to_jsonb(r);
end $$;

-- ---------------------------------------------------------------------
-- TRANSFER PER KOLI: draft -> dikirim (dalam perjalanan) -> diterima per koli
-- ---------------------------------------------------------------------
alter table inv_stock_transfers add column shipped_at  timestamptz;
alter table inv_stock_transfers add column shipped_by  uuid references sys_users(id);
alter table inv_stock_transfers add column received_at timestamptz;

create table inv_transfer_packages (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  stock_transfer_id  uuid not null references inv_stock_transfers(id) on delete cascade,
  package_no         int not null check (package_no > 0),
  package_code       text,                 -- label koli (barcode), dibuat saat dikirim
  status             text not null default 'open' check (status in ('open', 'shipped', 'received')),
  note               text,
  received_at        timestamptz,
  received_by        uuid references sys_users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (stock_transfer_id, package_no)
);
create unique index uq_inv_transfer_packages_code on inv_transfer_packages(company_id, package_code) where package_code is not null;

alter table inv_stock_transfer_items add column package_id          uuid references inv_transfer_packages(id) on delete set null;
alter table inv_stock_transfer_items add column batch_id            uuid references inv_stock_batches(id);
alter table inv_stock_transfer_items add column shipped_movement_id uuid references inv_stock_movements(id);
alter table inv_stock_transfer_items add column received_qty        numeric(15,4);

create or replace function inv_ship_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc  inv_stock_transfers%rowtype;
  v_pkg  record;
  v_line record;
  v_mid  uuid;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_transfers
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Transfer tidak ditemukan / sudah dikirim'; end if;
  if not exists (select 1 from inv_stock_transfer_items where stock_transfer_id = p_id) then
    raise exception 'Transfer belum punya item';
  end if;

  -- tanpa koli: semua barang = koli 1
  if not exists (select 1 from inv_transfer_packages where stock_transfer_id = p_id) then
    insert into inv_transfer_packages (company_id, stock_transfer_id, package_no) values (v_doc.company_id, p_id, 1);
    update inv_stock_transfer_items set package_id = (select id from inv_transfer_packages where stock_transfer_id = p_id)
    where stock_transfer_id = p_id;
  end if;
  if exists (select 1 from inv_stock_transfer_items where stock_transfer_id = p_id and package_id is null) then
    raise exception 'Masih ada barang yang belum dimasukkan ke koli';
  end if;
  delete from inv_transfer_packages p where p.stock_transfer_id = p_id
    and not exists (select 1 from inv_stock_transfer_items i where i.package_id = p.id);

  v_doc.transfer_number := coalesce(v_doc.transfer_number,
    sys_next_document_number(v_doc.company_id, 'TRF', v_doc.transfer_date));

  for v_pkg in select id from inv_transfer_packages where stock_transfer_id = p_id order by package_no loop
    update inv_transfer_packages set status = 'shipped',
      package_code = coalesce(package_code, 'K' || to_char(v_doc.transfer_date, 'YYMMDD')
        || lpad(sys_next_sequence(v_doc.company_id, 'KOLI/' || to_char(v_doc.transfer_date, 'YYYYMMDD'))::text, 4, '0'))
    where id = v_pkg.id;
  end loop;

  for v_line in
    select i.*, p.package_code from inv_stock_transfer_items i join inv_transfer_packages p on p.id = i.package_id
    where i.stock_transfer_id = p_id order by p.package_no, i.created_at, i.id
  loop
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, batch_id,
      reference_type, reference_id, reference_number, note, created_by)
    values (v_doc.company_id, v_doc.from_warehouse_id, v_line.item_id, 'transfer_out', -v_line.quantity, v_line.batch_id,
      'inv_stock_transfers', v_doc.id, v_doc.transfer_number, 'Koli ' || v_line.package_code, auth.uid())
    returning id into v_mid;
    update inv_stock_transfer_items set shipped_movement_id = v_mid where id = v_line.id;
  end loop;

  update inv_stock_transfers set status = 'in_transit', transfer_number = v_doc.transfer_number,
    shipped_at = now(), shipped_by = auth.uid()
  where id = p_id;
end $$;

-- Terima satu koli. p_lines = [{id: <transfer item id>, received_qty}] (kosong = diterima lengkap).
-- Kekurangan kiriman dijurnal ke purpose "Hilang / Rusak di Perjalanan".
create or replace function inv_receive_transfer_package(p_package_id uuid, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pkg   inv_transfer_packages%rowtype;
  v_doc   inv_stock_transfers%rowtype;
  v_line  record;
  v_rq    numeric;
  v_in    numeric;
  v_loss  numeric;
  v_total numeric := 0;
  v_acc   uuid;
  v_lines jsonb := '[]';
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_pkg from inv_transfer_packages
  where id = p_package_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Koli tidak ditemukan'; end if;
  if v_pkg.status <> 'shipped' then
    raise exception 'Koli % %', coalesce(v_pkg.package_code, ''), case v_pkg.status when 'received' then 'sudah diterima' else 'belum dikirim' end;
  end if;
  select * into v_doc from inv_stock_transfers where id = v_pkg.stock_transfer_id for update;

  select coalesce(p.account_id, fin_account_id_or_null(v_doc.company_id, 'waste_expense')) into v_acc
  from (select 1) x left join inv_adjustment_purposes p
    on p.company_id = v_doc.company_id and p.adjustment_type = 'waste' and p.name = 'Hilang / Rusak di Perjalanan';

  for v_line in
    select i.*, m.unit_cost as out_cost from inv_stock_transfer_items i
    join inv_stock_movements m on m.id = i.shipped_movement_id
    where i.package_id = p_package_id order by i.created_at, i.id
  loop
    v_rq := coalesce((select (x->>'received_qty')::numeric from jsonb_array_elements(coalesce(p_lines, '[]')) x
                      where x->>'id' = v_line.id::text), v_line.quantity);
    if v_rq < 0 or v_rq > v_line.quantity then
      raise exception 'Qty diterima tidak valid (maksimal %)', v_line.quantity;
    end if;

    v_in := 0;
    if v_rq > 0 then
      insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, source_movement_id,
        reference_type, reference_id, reference_number, note, created_by)
      values (v_doc.company_id, v_doc.to_warehouse_id, v_line.item_id, 'transfer_in', v_rq, v_line.shipped_movement_id,
        'inv_stock_transfers', v_doc.id, v_doc.transfer_number, 'Koli ' || v_pkg.package_code, auth.uid())
      returning round(quantity * unit_cost, 2) into v_in;
    end if;
    update inv_stock_transfer_items set received_qty = v_rq where id = v_line.id;

    v_loss := round(v_line.quantity * v_line.out_cost, 2) - v_in;
    if v_rq < v_line.quantity and v_loss <> 0 then
      v_total := v_total + v_loss;
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('account_id', fin_item_account(v_line.item_id, 'inventory'), 'credit', v_loss),
        jsonb_build_object('account_id', v_acc, 'debit', v_loss,
          'note', 'Kurang ' || (v_line.quantity - v_rq)::text || ' ' || (select name from inv_items where id = v_line.item_id)));
    end if;
  end loop;

  if v_total <> 0 and v_acc is not null and exists (select 1 from fin_accounts where company_id = v_doc.company_id) then
    perform fin_create_journal(v_doc.company_id, (select outlet_id from inv_warehouses where id = v_doc.to_warehouse_id),
      current_date, 'transfer_loss', v_pkg.id, 'Selisih kiriman ' || v_doc.transfer_number || ' koli ' || v_pkg.package_code, v_lines);
  end if;

  update inv_transfer_packages set status = 'received', received_at = now(), received_by = auth.uid() where id = p_package_id;

  if not exists (select 1 from inv_transfer_packages where stock_transfer_id = v_doc.id and status <> 'received') then
    update inv_stock_transfers set status = 'posted', posted_at = now(), received_at = now() where id = v_doc.id;
  end if;

  return jsonb_build_object('package_code', v_pkg.package_code, 'loss_value', v_total,
    'transfer_status', (select status from inv_stock_transfers where id = v_doc.id));
end $$;

-- Transfer langsung (tanpa perjalanan): kirim lalu terima semua koli
create or replace function inv_post_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_pkg uuid;
begin
  perform inv_ship_stock_transfer(p_id);
  for v_pkg in select id from inv_transfer_packages where stock_transfer_id = p_id order by package_no loop
    perform inv_receive_transfer_package(v_pkg, null);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- BARCODE: kode koli / label batch / barcode produk / kode produk
-- ---------------------------------------------------------------------
create or replace function inv_resolve_barcode(p_code text, p_warehouse_id uuid default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v      jsonb;
begin
  if v_code = '' then return null; end if;

  select jsonb_build_object('kind', 'package', 'package_id', p.id, 'package_code', p.package_code, 'package_no', p.package_no,
           'status', p.status, 'stock_transfer_id', p.stock_transfer_id, 'transfer_number', t.transfer_number,
           'to_warehouse_id', t.to_warehouse_id)
    into v
  from inv_transfer_packages p join inv_stock_transfers t on t.id = p.stock_transfer_id
  where upper(p.package_code) = v_code;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'batch', 'batch_id', b.id, 'batch_code', b.batch_code, 'item_id', b.item_id,
           'item_code', it.code, 'item_name', it.name, 'unit_code', u.code, 'qty', 1,
           'warehouse_id', b.warehouse_id, 'qty_remaining', b.qty_remaining, 'expiry_date', b.expiry_date, 'lot_number', b.lot_number)
    into v
  from inv_stock_batches b join inv_items it on it.id = b.item_id join inv_units u on u.id = it.base_unit_id
  where upper(b.batch_code) = v_code
  order by (b.warehouse_id = p_warehouse_id) desc nulls last, b.qty_remaining desc
  limit 1;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'item', 'item_id', it.id, 'item_code', it.code, 'item_name', it.name,
           'unit_code', bu.code, 'qty', iu.conversion_qty, 'scanned_unit', su.code)
    into v
  from inv_item_units iu join inv_items it on it.id = iu.item_id
  join inv_units bu on bu.id = it.base_unit_id join inv_units su on su.id = iu.unit_id
  where upper(iu.barcode) = v_code limit 1;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'item', 'item_id', it.id, 'item_code', it.code, 'item_name', it.name,
           'unit_code', u.code, 'qty', 1, 'scanned_unit', u.code)
    into v
  from inv_items it join inv_units u on u.id = it.base_unit_id
  where upper(it.code) = v_code limit 1;
  return v;
end $$;

-- Koreksi lot / kedaluwarsa batch (berlaku untuk kode batch yang sama di semua gudang)
create or replace function inv_update_batch(p_batch_id uuid, p_lot_number text, p_expiry_date date)
returns void language plpgsql security definer set search_path = public as $$
declare b inv_stock_batches%rowtype;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into b from inv_stock_batches where id = p_batch_id and company_id = sys_current_company_id();
  if not found then raise exception 'Batch tidak ditemukan'; end if;
  update inv_stock_batches set lot_number = nullif(trim(p_lot_number), ''), expiry_date = p_expiry_date
  where company_id = b.company_id and item_id = b.item_id and batch_code = b.batch_code;
end $$;

-- ---------------------------------------------------------------------
-- VIEW
-- ---------------------------------------------------------------------
create view rpt_stock_batches with (security_invoker = true) as
select b.id, b.company_id, b.warehouse_id, w.name as warehouse_name, b.item_id, it.code as item_code, it.name as item_name,
       u.code as unit_code, it.track_batch, b.batch_code, b.lot_number, b.expiry_date, b.received_at,
       b.qty_in, b.qty_remaining, b.unit_cost, (b.qty_remaining * b.unit_cost)::numeric(15,2) as stock_value,
       (b.expiry_date - current_date) as days_to_expiry, b.reference_type, b.reference_number
from inv_stock_batches b
join inv_warehouses w on w.id = b.warehouse_id
join inv_items it     on it.id = b.item_id
join inv_units u      on u.id = it.base_unit_id;

create view rpt_batch_movements with (security_invoker = true) as
select a.id, a.company_id, a.seq, b.batch_code, b.id as batch_id, b.item_id, m.warehouse_id, w.name as warehouse_name,
       m.movement_type, m.movement_at, m.reference_number, m.note, a.quantity, a.unit_cost, a.is_backfill
from inv_stock_movement_batches a
join inv_stock_batches b    on b.id = a.batch_id
join inv_stock_movements m  on m.id = a.movement_id
join inv_warehouses w       on w.id = m.warehouse_id;

-- ---------------------------------------------------------------------
-- PURPOSE kehilangan di perjalanan
-- ---------------------------------------------------------------------
create or replace function inv_setup_transfer_purposes(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into inv_adjustment_purposes (company_id, adjustment_type, name, account_id, sort_order)
  select p_company_id, 'waste', 'Hilang / Rusak di Perjalanan', fin_account_id_or_null(p_company_id, 'waste_expense'), 5
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------
-- TRIGGER, RLS, DATA AWAL
-- ---------------------------------------------------------------------
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('inv_stock_batches');                    -- baca saja; diubah lewat kartu stok
select sys_apply_company_policies('inv_stock_movement_batches');
select sys_apply_company_policies('inv_transfer_packages', 'inventory.manage');

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform inv_setup_transfer_purposes(r.id); end loop;
end $$;

alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v4;
revoke execute on function sys_onboard_company_v4(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v4(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform inv_setup_transfer_purposes((v_result->>'company_id')::uuid);
  return v_result;
end $$;

revoke execute on function inv_next_batch_code(uuid, date)                                      from public, anon, authenticated;
revoke execute on function inv_fallback_cost(uuid, uuid)                                        from public, anon, authenticated;
revoke execute on function inv_consume_batches(uuid, uuid, uuid, numeric, uuid, boolean)        from public, anon, authenticated;
revoke execute on function inv_add_to_batch(uuid, uuid, uuid, uuid, numeric, numeric, text, text, date, timestamptz, uuid, text, uuid, text)
                                                                                                from public, anon, authenticated;
revoke execute on function inv_setup_transfer_purposes(uuid)                                    from public, anon, authenticated;

-- >>>>>>>>>> migrations/020_sales_orders.sql
-- =====================================================================
-- SANTAP ERP - 020: SALES ORDER (ANTAR CABANG + B2B)
--   Pembeli (cabang)            Penjual (cabang / supply chain)
--   PO ke supplier internal --> Sales Order (otomatis, harga dari Pricelist Jual)
--                               Pengiriman (gudang, batch FEFO, koli) -> stok keluar, HPP
--   Penerimaan (draft otomatis) <-- dalam perjalanan
--   scan koli, qty diterima
--                               Sales Invoice (qty DIKIRIM) -> piutang & pendapatan
--   Hutang antar cabang <------ (jurnal cermin otomatis)
--   Pembayaran SO ------------> piutang lunas
--   Pelanggan B2B: SO manual -> Pengiriman -> Invoice -> Pembayaran
--   Satu perusahaan: jurnal dicatat per outlet dengan akun antar cabang
-- =====================================================================

-- ---------------------------------------------------------------------
-- AKUN
-- ---------------------------------------------------------------------
create or replace function fin_ensure_sales_accounts(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance, system_key)
  select p_company_id, (select id from fin_accounts where company_id = p_company_id and code = x.parent),
         x.code, x.name, x.type, x.normal, x.skey
  from (values
    ('1-0000', '1-1310', 'Piutang Antar Cabang',                    'asset',     'debit',  'ic_receivable'),
    ('2-0000', '2-1110', 'Hutang Antar Cabang',                     'liability', 'credit', 'ic_payable'),
    ('2-0000', '2-1120', 'Penerimaan Antar Cabang Belum Ditagih',   'liability', 'credit', 'ic_grni'),
    ('2-0000', '2-1220', 'PPN Keluaran',                            'liability', 'credit', 'sales_tax_payable'),
    ('4-0000', '4-1600', 'Penjualan Sales Order (B2B)',             'revenue',   'credit', 'so_revenue'),
    ('4-0000', '4-1610', 'Penjualan Antar Cabang',                  'revenue',   'credit', 'ic_revenue'),
    ('4-0000', '4-1700', 'Retur & Potongan Penjualan SO',           'revenue',   'debit',  'so_return'),
    ('5-0000', '5-1310', 'Selisih Kiriman Antar Cabang',            'cogs',      'debit',  'ic_shipping_diff'),
    ('5-0000', '5-1600', 'HPP Antar Cabang',                        'cogs',      'debit',  'ic_cogs')
  ) as x(parent, code, name, type, normal, skey)
  where not exists (select 1 from fin_accounts a where a.company_id = p_company_id and (a.system_key = x.skey or a.code = x.code));
end $$;

-- ---------------------------------------------------------------------
-- GUDANG / STORAGE: 1 toko bisa punya beberapa lokasi (mis. Central Kitchen + Warehouse)
-- ---------------------------------------------------------------------
alter table inv_warehouses add column warehouse_type text not null default 'store';
alter table inv_warehouses add constraint inv_warehouses_type_check
  check (warehouse_type in ('store', 'central_kitchen', 'warehouse', 'bar', 'other'));
alter table inv_warehouses add column address text;
alter table inv_warehouses add column notes   text;

-- ---------------------------------------------------------------------
-- SUPPLIER: pihak ke-3 atau cabang internal
-- ---------------------------------------------------------------------
alter table pur_suppliers add column supplier_type    text not null default 'external';
alter table pur_suppliers add column linked_outlet_id uuid references sys_outlets(id);
alter table pur_suppliers add constraint pur_suppliers_type_check check (supplier_type in ('external', 'internal'));
alter table pur_suppliers add constraint pur_suppliers_internal_check check (supplier_type = 'external' or linked_outlet_id is not null);
create unique index uq_pur_suppliers_linked_outlet on pur_suppliers(linked_outlet_id) where linked_outlet_id is not null;

-- setiap outlet otomatis tersedia sebagai supplier internal
create or replace function pur_ensure_internal_supplier(p_outlet_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into pur_suppliers (company_id, code, name, address, supplier_type, linked_outlet_id)
  select o.company_id, 'INT-' || o.code, o.name || ' (internal)', o.address, 'internal', o.id
  from sys_outlets o
  where o.id = p_outlet_id
    and not exists (select 1 from pur_suppliers s where s.linked_outlet_id = o.id)
  on conflict do nothing;
end $$;

create or replace function pur_on_outlet_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform pur_ensure_internal_supplier(new.id);
  return new;
end $$;
create trigger trg_sys_outlets_internal_supplier after insert on sys_outlets
  for each row execute function pur_on_outlet_created();

-- ---------------------------------------------------------------------
-- PELANGGAN B2B
-- ---------------------------------------------------------------------
create table sal_customers (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  code              text not null,
  name              text not null,
  contact_name      text,
  phone             text,
  email             text,
  address           text,
  tax_number        text,                 -- NPWP
  payment_term_days int not null default 0 check (payment_term_days >= 0),
  credit_limit      numeric(15,2) not null default 0 check (credit_limit >= 0),   -- 0 = tanpa limit
  notes             text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, code)
);

-- ---------------------------------------------------------------------
-- PRICELIST JUAL
--   Kosongkan penjual / pembeli / pelanggan = berlaku untuk semua.
--   Yang paling spesifik & paling baru dipakai.
-- ---------------------------------------------------------------------
create table sal_pricelists (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  name              text not null,
  seller_outlet_id  uuid references sys_outlets(id),
  buyer_outlet_id   uuid references sys_outlets(id),
  customer_id       uuid references sal_customers(id),
  valid_from        date not null default current_date,
  valid_to          date,
  notes             text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (buyer_outlet_id is null or customer_id is null)
);

create table sal_pricelist_items (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  pricelist_id  uuid not null references sal_pricelists(id) on delete cascade,
  item_id       uuid not null references inv_items(id),
  unit_id       uuid not null references inv_units(id),
  price         numeric(15,2) not null check (price >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (pricelist_id, item_id, unit_id)
);

-- konversi satuan -> satuan dasar (null = satuan tidak terdaftar di produk)
create or replace function inv_unit_factor(p_item_id uuid, p_unit_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select case when it.base_unit_id = p_unit_id then 1
              else (select conversion_qty from inv_item_units where item_id = p_item_id and unit_id = p_unit_id) end
  from inv_items it where it.id = p_item_id
$$;

create or replace function sal_get_price(
  p_company_id uuid, p_seller_outlet_id uuid, p_buyer_outlet_id uuid, p_customer_id uuid,
  p_item_id uuid, p_unit_id uuid, p_date date default current_date)
returns numeric language sql stable security definer set search_path = public as $$
  select round(pi.price / inv_unit_factor(pi.item_id, pi.unit_id) * inv_unit_factor(p_item_id, p_unit_id), 2)
  from sal_pricelists p
  join sal_pricelist_items pi on pi.pricelist_id = p.id
  where p.company_id = p_company_id and p.is_active and pi.item_id = p_item_id
    and p.valid_from <= p_date and (p.valid_to is null or p.valid_to >= p_date)
    and (p.seller_outlet_id is null or p.seller_outlet_id = p_seller_outlet_id)
    and (p.buyer_outlet_id is null or p.buyer_outlet_id = p_buyer_outlet_id)
    and (p.customer_id is null or p.customer_id = p_customer_id)
    and inv_unit_factor(pi.item_id, pi.unit_id) is not null
    and inv_unit_factor(p_item_id, p_unit_id) is not null
  order by (p.buyer_outlet_id is not null or p.customer_id is not null) desc,
           (p.seller_outlet_id is not null) desc,
           (pi.unit_id = p_unit_id) desc,
           p.valid_from desc, p.created_at desc
  limit 1
$$;

-- ---------------------------------------------------------------------
-- SALES ORDER
-- ---------------------------------------------------------------------
create table sal_sales_orders (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references sys_companies(id),
  outlet_id           uuid not null references sys_outlets(id),          -- penjual
  warehouse_id        uuid references inv_warehouses(id),                -- gudang kirim default
  customer_type       text not null check (customer_type in ('internal', 'external')),
  buyer_outlet_id     uuid references sys_outlets(id),                   -- internal
  buyer_warehouse_id  uuid references inv_warehouses(id),                -- internal: gudang tujuan
  customer_id         uuid references sal_customers(id),                 -- B2B
  purchase_order_id   uuid references pur_purchase_orders(id),
  so_number           text,
  so_date             date not null default current_date,
  expected_date       date,
  status              text not null default 'draft' check (status in
                        ('draft', 'new', 'confirmed', 'partially_delivered', 'delivered', 'closed', 'rejected', 'cancelled')),
  subtotal            numeric(15,2) not null default 0,
  tax_pct             numeric(5,2) not null default 0 check (tax_pct between 0 and 100),
  tax_amount          numeric(15,2) not null default 0,
  grand_total         numeric(15,2) not null default 0,
  shipping_address    text,
  note                text,
  reject_reason       text,
  confirmed_by        uuid references sys_users(id),
  confirmed_at        timestamptz,
  created_by          uuid references sys_users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check ((customer_type = 'internal' and purchase_order_id is not null and buyer_warehouse_id is not null)
      or (customer_type = 'external' and customer_id is not null))
);
create unique index uq_sal_sales_orders_po on sal_sales_orders(purchase_order_id) where purchase_order_id is not null;
create index idx_sal_sales_orders_status on sal_sales_orders(company_id, status);

create table sal_sales_order_items (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid not null references sys_companies(id),
  sales_order_id          uuid not null references sal_sales_orders(id) on delete cascade,
  purchase_order_item_id  uuid references pur_purchase_order_items(id),
  item_id                 uuid not null references inv_items(id),
  unit_id                 uuid not null references inv_units(id),
  conversion_qty          numeric(15,4) not null default 1,
  quantity                numeric(15,4) not null check (quantity > 0),
  delivered_qty           numeric(15,4) not null default 0,
  unit_price              numeric(15,2) not null default 0,
  line_total              numeric(15,2) not null default 0,
  note                    text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- PENGIRIMAN (Delivery Order)
-- ---------------------------------------------------------------------
create table sal_deliveries (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  sales_order_id    uuid not null references sal_sales_orders(id),
  warehouse_id      uuid not null references inv_warehouses(id),   -- gudang asal (CK / Warehouse / dll)
  delivery_number   text,
  delivery_date     date not null default current_date,
  status            text not null default 'draft' check (status in ('draft', 'shipped', 'received', 'cancelled')),
  goods_receipt_id  uuid references pur_goods_receipts(id),        -- penerimaan di pembeli (internal)
  vehicle_note      text,
  note              text,
  shipped_at        timestamptz,
  shipped_by        uuid references sys_users(id),
  created_by        uuid references sys_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table sal_delivery_items (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  delivery_id          uuid not null references sal_deliveries(id) on delete cascade,
  sales_order_item_id  uuid not null references sal_sales_order_items(id),
  item_id              uuid not null references inv_items(id),
  unit_id              uuid not null references inv_units(id),
  conversion_qty       numeric(15,4) not null default 1,
  quantity             numeric(15,4) not null check (quantity >= 0),
  unit_price           numeric(15,2) not null default 0,
  batch_id             uuid references inv_stock_batches(id),
  package_no           int not null default 1 check (package_no > 0),
  shipped_movement_id  uuid references inv_stock_movements(id),
  invoiced_qty         numeric(15,4) not null default 0,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table sal_delivery_packages (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  delivery_id   uuid not null references sal_deliveries(id) on delete cascade,
  package_no    int not null,
  package_code  text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (delivery_id, package_no)
);
create unique index uq_sal_delivery_packages_code on sal_delivery_packages(company_id, package_code);

-- penerimaan pembeli yang berasal dari pengiriman cabang
alter table pur_goods_receipts add column delivery_id uuid references sal_deliveries(id);
alter table pur_goods_receipt_items add column delivery_item_id uuid references sal_delivery_items(id);
alter table pur_goods_receipt_items add column shipped_qty numeric(15,4);
alter table pur_goods_receipt_items drop constraint if exists pur_goods_receipt_items_quantity_check;
alter table pur_goods_receipt_items add constraint pur_goods_receipt_items_quantity_check check (quantity >= 0);

-- terima barang dari kiriman: ikut identitas batch asal (kode, lot, kedaluwarsa) tapi harga = harga beli
alter table inv_stock_movements add column copy_batch_identity boolean not null default false;

-- PO cabang: status ditolak / ditutup penjual
alter table pur_purchase_orders add column sales_note text;

-- ---------------------------------------------------------------------
-- INVOICE, NOTA KREDIT, PEMBAYARAN
-- ---------------------------------------------------------------------
create table sal_invoices (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  outlet_id        uuid not null references sys_outlets(id),     -- penjual
  sales_order_id   uuid not null references sal_sales_orders(id),
  customer_type    text not null,
  buyer_outlet_id  uuid references sys_outlets(id),
  customer_id      uuid references sal_customers(id),
  invoice_number   text not null,
  invoice_date     date not null default current_date,
  due_date         date not null,
  subtotal         numeric(15,2) not null default 0,
  tax_amount       numeric(15,2) not null default 0,
  grand_total      numeric(15,2) not null default 0,
  paid_amount      numeric(15,2) not null default 0,
  credited_amount  numeric(15,2) not null default 0,
  status           text not null default 'unpaid' check (status in ('unpaid', 'partial', 'paid')),
  note             text,
  created_by       uuid references sys_users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table sal_invoice_items (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  invoice_id        uuid not null references sal_invoices(id) on delete cascade,
  delivery_item_id  uuid not null references sal_delivery_items(id),
  item_id           uuid not null references inv_items(id),
  unit_id           uuid not null references inv_units(id),
  quantity          numeric(15,4) not null,
  unit_price        numeric(15,2) not null,
  line_total        numeric(15,2) not null,
  created_at        timestamptz not null default now()
);

create table sal_credit_notes (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  invoice_id     uuid not null references sal_invoices(id),
  credit_number  text not null,
  credit_date    date not null default current_date,
  reason         text not null check (reason in ('shortage', 'return', 'discount', 'other')),
  amount         numeric(15,2) not null check (amount > 0),
  note           text,
  created_by     uuid references sys_users(id),
  created_at     timestamptz not null default now()
);

create table sal_payments (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  outlet_id        uuid not null references sys_outlets(id),     -- penjual
  customer_type    text not null,
  buyer_outlet_id  uuid references sys_outlets(id),
  customer_id      uuid references sal_customers(id),
  payment_number   text not null,
  payment_date     date not null default current_date,
  amount           numeric(15,2) not null check (amount > 0),
  from_account_id  uuid references fin_accounts(id),   -- internal: dibayar dari kas/bank pembeli
  to_account_id    uuid not null references fin_accounts(id),
  reference_number text,
  note             text,
  created_by       uuid references sys_users(id),
  created_at       timestamptz not null default now()
);

create table sal_payment_items (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  payment_id  uuid not null references sal_payments(id) on delete cascade,
  invoice_id  uuid not null references sal_invoices(id),
  amount      numeric(15,2) not null check (amount > 0),
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- FUNGSI
-- =====================================================================
create or replace function sal_outlet_of_warehouse(p_warehouse_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select outlet_id from inv_warehouses where id = p_warehouse_id
$$;

-- PO ke supplier internal: harga dikunci dari Pricelist Jual penjual
create or replace function pur_set_internal_po_price()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_po    pur_purchase_orders%rowtype;
  v_sup   pur_suppliers%rowtype;
  v_buyer uuid;
  v_price numeric;
begin
  select * into v_po from pur_purchase_orders where id = new.purchase_order_id;
  if v_po.status not in ('draft', 'pending_approval') then return new; end if;
  select * into v_sup from pur_suppliers where id = v_po.supplier_id;
  if v_sup.supplier_type <> 'internal' then return new; end if;

  v_buyer := sal_outlet_of_warehouse(v_po.warehouse_id);
  if v_buyer = v_sup.linked_outlet_id then
    raise exception 'Tidak bisa membeli dari outlet sendiri. Gunakan Transfer Gudang.';
  end if;
  v_price := sal_get_price(v_po.company_id, v_sup.linked_outlet_id, v_buyer, null, new.item_id, new.unit_id, v_po.po_date);
  if v_price is null then
    raise exception 'Harga jual "%" belum ada di Pricelist Jual %',
      (select name from inv_items where id = new.item_id), (select name from sys_outlets where id = v_sup.linked_outlet_id);
  end if;
  new.unit_price := v_price;
  new.line_total := round(new.quantity * v_price, 2);
  return new;
end $$;
create trigger trg_pur_po_items_internal_price before insert or update of item_id, unit_id, unit_price, quantity
  on pur_purchase_order_items for each row execute function pur_set_internal_po_price();

-- PO internal disetujui -> Sales Order baru di penjual
create or replace function sal_on_po_approved()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_sup pur_suppliers%rowtype;
  v_so  uuid;
begin
  select * into v_sup from pur_suppliers where id = new.supplier_id;
  if v_sup.supplier_type <> 'internal' or exists (select 1 from sal_sales_orders where purchase_order_id = new.id) then
    return new;
  end if;

  insert into sal_sales_orders (company_id, outlet_id, warehouse_id, customer_type, buyer_outlet_id, buyer_warehouse_id,
    purchase_order_id, so_number, so_date, expected_date, status, subtotal, grand_total, note, created_by)
  values (new.company_id, v_sup.linked_outlet_id,
    (select default_warehouse_id from sys_outlets where id = v_sup.linked_outlet_id),
    'internal', sal_outlet_of_warehouse(new.warehouse_id), new.warehouse_id, new.id,
    sys_next_document_number(new.company_id, 'SO', current_date), current_date, new.expected_date, 'new',
    new.subtotal, new.subtotal, 'Dari ' || new.po_number || coalesce(' - ' || new.note, ''), new.approved_by)
  returning id into v_so;

  insert into sal_sales_order_items (company_id, sales_order_id, purchase_order_item_id, item_id, unit_id,
    conversion_qty, quantity, unit_price, line_total)
  select company_id, v_so, id, item_id, unit_id, conversion_qty, quantity, unit_price, quantity * unit_price
  from pur_purchase_order_items where purchase_order_id = new.id
  order by created_at, id;
  return new;
end $$;
create trigger trg_pur_po_approved_sales_order after update of status on pur_purchase_orders
  for each row when (new.status = 'approved' and old.status is distinct from 'approved')
  execute function sal_on_po_approved();

-- PO internal tidak boleh dibuat penerimaan manual (datang dari pengiriman penjual)
create or replace function pur_create_goods_receipt_from_po(p_po_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_po    pur_purchase_orders%rowtype;
  v_gr_id uuid;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_po from pur_purchase_orders
  where id = p_po_id and company_id = sys_current_company_id();
  if not found or v_po.status not in ('approved', 'partially_received') then
    raise exception 'PO harus berstatus approved';
  end if;
  if (select supplier_type from pur_suppliers where id = v_po.supplier_id) = 'internal' then
    raise exception 'PO ke cabang internal diterima dari dokumen Pengiriman penjual (lihat Penerimaan Barang)';
  end if;

  insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, created_by)
  values (v_po.company_id, v_po.id, v_po.supplier_id, v_po.warehouse_id, auth.uid())
  returning id into v_gr_id;

  insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id,
    item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
  select company_id, v_gr_id, id, item_id, unit_id, conversion_qty,
         quantity - received_qty, unit_price, (quantity - received_qty) * unit_price
  from pur_purchase_order_items
  where purchase_order_id = p_po_id and quantity > received_qty;

  return v_gr_id;
end $$;

-- Hitung ulang total SO
create or replace function sal_recalculate_order(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update sal_sales_order_items set line_total = round(quantity * unit_price, 2) where sales_order_id = p_id;
  update sal_sales_orders so set
    subtotal    = x.subtotal,
    tax_amount  = case when customer_type = 'external' then round(x.subtotal * tax_pct / 100, 2) else 0 end,
    grand_total = x.subtotal + case when customer_type = 'external' then round(x.subtotal * tax_pct / 100, 2) else 0 end
  from (select coalesce(sum(line_total), 0) subtotal from sal_sales_order_items where sales_order_id = p_id) x
  where so.id = p_id;
end $$;

-- Harga baris SO B2B: kosong / 0 diisi dari Pricelist Jual
create or replace function sal_set_so_item_price()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_so sal_sales_orders%rowtype;
begin
  select * into v_so from sal_sales_orders where id = new.sales_order_id;
  if v_so.customer_type = 'external' and v_so.status = 'draft' and coalesce(new.unit_price, 0) = 0 then
    new.unit_price := coalesce(sal_get_price(v_so.company_id, v_so.outlet_id, null, v_so.customer_id, new.item_id, new.unit_id, v_so.so_date), 0);
  end if;
  new.conversion_qty := coalesce(inv_unit_factor(new.item_id, new.unit_id), new.conversion_qty);
  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end $$;
create trigger trg_sal_so_items_price before insert or update of item_id, unit_id, quantity, unit_price
  on sal_sales_order_items for each row execute function sal_set_so_item_price();

-- Konfirmasi SO (SO cabang baru / draft B2B)
create or replace function sal_confirm_sales_order(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  so      sal_sales_orders%rowtype;
  c       sal_customers%rowtype;
  v_open  numeric;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('draft', 'new') then raise exception 'Sales order tidak ditemukan / sudah dikonfirmasi'; end if;
  if not exists (select 1 from sal_sales_order_items where sales_order_id = p_id) then raise exception 'Sales order belum punya item'; end if;
  if exists (select 1 from sal_sales_order_items where sales_order_id = p_id and unit_price <= 0) and so.customer_type = 'external' then
    raise exception 'Ada barang tanpa harga. Isi harga atau tambahkan di Pricelist Jual.';
  end if;
  perform sal_recalculate_order(p_id);
  select * into so from sal_sales_orders where id = p_id;

  -- limit kredit pelanggan B2B: piutang berjalan + SO terbuka + SO ini
  if so.customer_type = 'external' then
    select * into c from sal_customers where id = so.customer_id;
    if c.credit_limit > 0 then
      select coalesce((select sum(grand_total - paid_amount - credited_amount) from sal_invoices where customer_id = c.id), 0)
           + coalesce((select sum(grand_total) from sal_sales_orders where customer_id = c.id and id <> p_id
                       and status in ('confirmed', 'partially_delivered')), 0)
        into v_open;
      if v_open + so.grand_total > c.credit_limit then
        raise exception 'Melebihi limit kredit % (terpakai %, SO ini %)', to_char(c.credit_limit, 'FM999G999G999'),
          to_char(v_open, 'FM999G999G999'), to_char(so.grand_total, 'FM999G999G999');
      end if;
    end if;
  end if;

  update sal_sales_orders set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now(),
    so_number = coalesce(so_number, sys_next_document_number(company_id, 'SO', so_date))
  where id = p_id returning * into so;
  return to_jsonb(so);
end $$;

-- Tolak SO cabang -> PO pembeli dibatalkan
create or replace function sal_reject_sales_order(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare so sal_sales_orders%rowtype;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('draft', 'new', 'confirmed') or exists (select 1 from sal_deliveries where sales_order_id = p_id and status <> 'cancelled') then
    raise exception 'Sales order tidak bisa ditolak (sudah ada pengiriman)';
  end if;
  update sal_sales_orders set status = case when customer_type = 'internal' then 'rejected' else 'cancelled' end,
    reject_reason = trim(p_reason) where id = p_id;
  if so.purchase_order_id is not null then
    update pur_purchase_orders set status = 'cancelled', sales_note = 'Ditolak penjual: ' || trim(p_reason) where id = so.purchase_order_id;
  end if;
end $$;

-- Status PO internal mengikuti SO & penerimaan
create or replace function sal_sync_po_status(p_so_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare so sal_sales_orders%rowtype;
begin
  select * into so from sal_sales_orders where id = p_so_id;
  if so.purchase_order_id is null then return; end if;
  update pur_purchase_orders set status = case
      when exists (select 1 from sal_deliveries d where d.sales_order_id = so.id and d.status = 'shipped') then 'partially_received'
      when so.status in ('delivered', 'closed') and exists (select 1 from sal_deliveries d where d.sales_order_id = so.id and d.status = 'received') then 'received'
      when so.status = 'closed' then 'cancelled'
      when exists (select 1 from sal_deliveries d where d.sales_order_id = so.id and d.status = 'received') then 'partially_received'
      else status end
  where id = so.purchase_order_id;
end $$;

-- Tutup SO (sisa tidak dikirim)
create or replace function sal_close_sales_order(p_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare so sal_sales_orders%rowtype;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('confirmed', 'partially_delivered') then raise exception 'Sales order tidak bisa ditutup'; end if;
  if exists (select 1 from sal_deliveries where sales_order_id = p_id and status = 'draft') then
    raise exception 'Masih ada draft pengiriman. Kirim atau hapus dulu.';
  end if;
  update sal_sales_orders set status = 'closed', note = coalesce(note || E'\n', '') || coalesce('Ditutup: ' || nullif(trim(p_reason), ''), 'Ditutup')
  where id = p_id;
  if so.purchase_order_id is not null then
    update pur_purchase_orders set sales_note = coalesce('Ditutup penjual: ' || nullif(trim(p_reason), ''), 'Ditutup penjual') where id = so.purchase_order_id;
  end if;
  perform sal_sync_po_status(p_id);
end $$;

-- Buat draft pengiriman dari sisa SO
create or replace function sal_create_delivery(p_so_id uuid, p_warehouse_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  so   sal_sales_orders%rowtype;
  v_wh uuid;
  v_id uuid;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  select * into so from sal_sales_orders where id = p_so_id and company_id = sys_current_company_id();
  if not found or so.status not in ('confirmed', 'partially_delivered') then raise exception 'Sales order harus dikonfirmasi dulu'; end if;
  v_wh := coalesce(p_warehouse_id, so.warehouse_id, (select default_warehouse_id from sys_outlets where id = so.outlet_id));
  if v_wh is null or not exists (select 1 from inv_warehouses where id = v_wh and company_id = so.company_id) then
    raise exception 'Pilih gudang pengiriman';
  end if;

  insert into sal_deliveries (company_id, sales_order_id, warehouse_id, created_by)
  values (so.company_id, so.id, v_wh, auth.uid()) returning id into v_id;

  insert into sal_delivery_items (company_id, delivery_id, sales_order_item_id, item_id, unit_id, conversion_qty, quantity, unit_price)
  select i.company_id, v_id, i.id, i.item_id, i.unit_id, i.conversion_qty,
         i.quantity - i.delivered_qty - coalesce((select sum(di.quantity) from sal_delivery_items di join sal_deliveries d on d.id = di.delivery_id
                                                   where di.sales_order_item_id = i.id and d.status = 'draft' and d.id <> v_id), 0),
         i.unit_price
  from sal_sales_order_items i
  where i.sales_order_id = so.id
    and i.quantity - i.delivered_qty - coalesce((select sum(di.quantity) from sal_delivery_items di join sal_deliveries d on d.id = di.delivery_id
                                                   where di.sales_order_item_id = i.id and d.status = 'draft' and d.id <> v_id), 0) > 0
  order by i.created_at, i.id;

  if not exists (select 1 from sal_delivery_items where delivery_id = v_id) then
    raise exception 'Semua barang sudah dikirim / sudah ada di draft pengiriman lain';
  end if;
  return v_id;
end $$;

-- Kirim: stok keluar (batch FEFO / batch pilihan), HPP dijurnal, koli dibuat,
-- untuk cabang internal dibuatkan draft Penerimaan di pembeli
create or replace function sal_ship_delivery(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d     sal_deliveries%rowtype;
  so    sal_sales_orders%rowtype;
  v_ln  record;
  v_mid uuid;
  v_gr  uuid;
  v_no  int;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  select * into d from sal_deliveries where id = p_id and company_id = sys_current_company_id() for update;
  if not found or d.status <> 'draft' then raise exception 'Pengiriman tidak ditemukan / sudah dikirim'; end if;
  select * into so from sal_sales_orders where id = d.sales_order_id for update;
  if so.status not in ('confirmed', 'partially_delivered') then raise exception 'Sales order sudah ditutup'; end if;

  delete from sal_delivery_items where delivery_id = p_id and quantity = 0;
  if not exists (select 1 from sal_delivery_items where delivery_id = p_id) then raise exception 'Isi qty yang dikirim'; end if;
  if exists (
    select 1 from sal_sales_order_items i
    where i.sales_order_id = so.id
      and i.delivered_qty + coalesce((select sum(quantity) from sal_delivery_items where delivery_id = p_id and sales_order_item_id = i.id), 0) > i.quantity) then
    raise exception 'Qty kirim melebihi sisa sales order';
  end if;

  d.delivery_number := coalesce(d.delivery_number, sys_next_document_number(d.company_id, 'DO', d.delivery_date));

  for v_no in select distinct package_no from sal_delivery_items where delivery_id = p_id order by 1 loop
    insert into sal_delivery_packages (company_id, delivery_id, package_no, package_code)
    values (d.company_id, p_id, v_no, 'K' || to_char(d.delivery_date, 'YYMMDD')
      || lpad(sys_next_sequence(d.company_id, 'KOLI/' || to_char(d.delivery_date, 'YYYYMMDD'))::text, 4, '0'))
    on conflict do nothing;
  end loop;

  for v_ln in select * from sal_delivery_items where delivery_id = p_id order by package_no, created_at, id loop
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, batch_id,
      reference_type, reference_id, reference_number, note, created_by)
    values (d.company_id, d.warehouse_id, v_ln.item_id, 'sales_delivery', -(v_ln.quantity * v_ln.conversion_qty), v_ln.batch_id,
      'sal_deliveries', d.id, d.delivery_number, 'Koli ' || v_ln.package_no, auth.uid())
    returning id into v_mid;
    update sal_delivery_items set shipped_movement_id = v_mid where id = v_ln.id;
    update sal_sales_order_items set delivered_qty = delivered_qty + v_ln.quantity where id = v_ln.sales_order_item_id;
  end loop;

  update sal_deliveries set status = 'shipped', delivery_number = d.delivery_number, shipped_at = now(), shipped_by = auth.uid()
  where id = p_id;
  update sal_sales_orders set status = case
      when exists (select 1 from sal_sales_order_items where sales_order_id = so.id and delivered_qty < quantity) then 'partially_delivered'
      else 'delivered' end
  where id = so.id;

  -- jurnal penjual: HPP | persediaan (per kategori)
  if exists (select 1 from fin_accounts where company_id = d.company_id) then
    perform fin_create_journal(d.company_id, so.outlet_id, d.delivery_date, 'sales_delivery', d.id,
      'Pengiriman ' || d.delivery_number || ' / ' || so.so_number,
      case when so.customer_type = 'internal' then fin_stock_journal_lines('sal_deliveries', d.id, null, 'ic_cogs')
           else fin_stock_journal_lines('sal_deliveries', d.id, 'cogs') end);
  end if;

  -- cabang internal: draft penerimaan di pembeli
  if so.customer_type = 'internal' then
    insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, delivery_id, note, created_by)
    select so.company_id, po.id, po.supplier_id, so.buyer_warehouse_id, d.id, 'Kiriman ' || d.delivery_number, auth.uid()
    from pur_purchase_orders po where po.id = so.purchase_order_id
    returning id into v_gr;

    insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id, item_id, unit_id,
      conversion_qty, quantity, shipped_qty, unit_price, line_total, delivery_item_id)
    select di.company_id, v_gr, soi.purchase_order_item_id, di.item_id, di.unit_id, di.conversion_qty,
           di.quantity, di.quantity, di.unit_price, round(di.quantity * di.unit_price, 2), di.id
    from sal_delivery_items di join sal_sales_order_items soi on soi.id = di.sales_order_item_id
    where di.delivery_id = d.id order by di.package_no, di.created_at, di.id;

    update sal_deliveries set goods_receipt_id = v_gr where id = d.id;
    perform sal_sync_po_status(so.id);
  end if;

  return jsonb_build_object('delivery_number', d.delivery_number, 'goods_receipt_id', v_gr);
end $$;

-- ---------------------------------------------------------------------
-- MESIN STOK: dukung copy_batch_identity (kode/lot/kedaluwarsa ikut, harga = harga beli)
-- ---------------------------------------------------------------------
create or replace function inv_apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_stock  inv_stocks%rowtype;
  v_item   inv_items%rowtype;
  v_value  numeric := 0;
  v_left   numeric;
  v_cost   numeric;
  v_take   numeric;
  v_chunk  numeric;
  v_rec    record;
  v_src    inv_stock_batches%rowtype;
begin
  insert into inv_stocks (company_id, warehouse_id, item_id)
  values (new.company_id, new.warehouse_id, new.item_id)
  on conflict (warehouse_id, item_id) do nothing;

  select * into v_stock from inv_stocks
  where warehouse_id = new.warehouse_id and item_id = new.item_id
  for update;
  select * into v_item from inv_items where id = new.item_id;

  if new.quantity < 0 then
    select c.consumed_value, c.unallocated_qty into v_value, v_left
    from inv_consume_batches(new.id, new.warehouse_id, new.item_id, -new.quantity, new.batch_id) c;
    if v_left > 0 then
      new.unbatched_qty := v_left;
      v_value := v_value + v_left * inv_fallback_cost(new.warehouse_id, new.item_id);
    end if;
    new.unit_cost := round(v_value / -new.quantity, 4);

  elsif new.quantity > 0 then
    v_left := new.quantity;

    if new.source_movement_id is not null then
      for v_rec in
        select a.batch_id, -a.quantity as qty, a.unit_cost from inv_stock_movement_batches a
        where a.movement_id = new.source_movement_id and a.quantity < 0 and not a.is_backfill
        order by a.seq
      loop
        exit when v_left <= 0;
        v_take := least(v_left, v_rec.qty);
        v_chunk := case when new.copy_batch_identity then coalesce(new.unit_cost, v_rec.unit_cost) else v_rec.unit_cost end;
        select * into v_src from inv_stock_batches where id = v_rec.batch_id;
        if v_src.warehouse_id = new.warehouse_id and v_src.item_id = new.item_id and not new.copy_batch_identity then
          update inv_stock_batches set qty_remaining = qty_remaining + v_take where id = v_src.id;
          insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
          values (new.company_id, new.id, v_src.id, v_take, v_rec.unit_cost);
        else
          perform inv_add_to_batch(new.id, new.company_id, new.warehouse_id, new.item_id, v_take, v_chunk,
            v_src.batch_code, v_src.lot_number, v_src.expiry_date, v_src.received_at, coalesce(v_src.origin_batch_id, v_src.id),
            new.reference_type, new.reference_id, new.reference_number);
        end if;
        v_value := v_value + v_take * v_chunk;
        v_left := v_left - v_take;
      end loop;
      v_cost := case when new.copy_batch_identity then new.unit_cost
                     else coalesce((select unit_cost from inv_stock_movements where id = new.source_movement_id), new.unit_cost) end;
    end if;

    if v_left > 0 then
      v_cost := coalesce(v_cost, new.unit_cost, inv_fallback_cost(new.warehouse_id, new.item_id));
      if new.batch_id is not null and exists (
          select 1 from inv_stock_batches where id = new.batch_id and warehouse_id = new.warehouse_id and item_id = new.item_id) then
        update inv_stock_batches set
          unit_cost     = case when qty_remaining + v_left > 0 then (qty_remaining * unit_cost + v_left * v_cost) / (qty_remaining + v_left) else v_cost end,
          qty_in        = qty_in + v_left,
          qty_remaining = qty_remaining + v_left
        where id = new.batch_id;
        insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
        values (new.company_id, new.id, new.batch_id, v_left, v_cost);
      else
        perform inv_add_to_batch(new.id, new.company_id, new.warehouse_id, new.item_id, v_left, v_cost,
          coalesce(nullif(trim(new.batch_code), ''), inv_next_batch_code(new.company_id)),
          new.lot_number,
          coalesce(new.expiry_date, new.movement_at::date + v_item.shelf_life_days),
          new.movement_at, null, new.reference_type, new.reference_id, new.reference_number);
      end if;
      v_value := v_value + v_left * v_cost;
    end if;
    new.unit_cost := round(v_value / new.quantity, 4);

    if v_stock.quantity < 0 then
      perform inv_consume_batches(new.id, new.warehouse_id, new.item_id, least(new.quantity, -v_stock.quantity), null, true);
    end if;
  end if;

  v_stock.quantity := v_stock.quantity + new.quantity;
  new.balance_after := v_stock.quantity;

  update inv_stocks set
    quantity     = v_stock.quantity,
    average_cost = coalesce(
      (select sum(qty_remaining * unit_cost) / nullif(sum(qty_remaining), 0) from inv_stock_batches
        where warehouse_id = new.warehouse_id and item_id = new.item_id and qty_remaining > 0),
      case when new.quantity > 0 then new.unit_cost else v_stock.average_cost end)
  where id = v_stock.id;

  return new;
end $$;

-- ---------------------------------------------------------------------
-- PENERIMAAN BARANG: dukung kiriman cabang (qty diterima <= dikirim)
-- ---------------------------------------------------------------------
create or replace function pur_post_goods_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc     pur_goods_receipts%rowtype;
  v_missing text;
  v_so      uuid;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_goods_receipts
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id) then
    raise exception 'Penerimaan belum punya item';
  end if;

  if v_doc.delivery_id is not null then
    -- KIRIMAN CABANG: harga dari pengiriman, qty diterima 0..qty dikirim
    if exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id and (quantity < 0 or quantity > shipped_qty)) then
      raise exception 'Qty diterima tidak boleh melebihi qty dikirim';
    end if;
    update pur_goods_receipt_items gi set unit_price = di.unit_price, line_total = round(gi.quantity * di.unit_price, 2)
    from sal_delivery_items di where di.id = gi.delivery_item_id and gi.goods_receipt_id = p_id;
  else
    if exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id and quantity <= 0) then
      delete from pur_goods_receipt_items where goods_receipt_id = p_id and quantity <= 0;
      if not exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id) then raise exception 'Penerimaan belum punya item'; end if;
    end if;
    select string_agg(it.name, ', ') into v_missing
    from pur_goods_receipt_items i join inv_items it on it.id = i.item_id
    where i.goods_receipt_id = p_id and it.track_batch and i.expiry_date is null and it.shelf_life_days is null;
    if v_missing is not null then
      raise exception 'Isi tanggal kedaluwarsa untuk produk yang dilacak batch: %', v_missing;
    end if;
    update pur_goods_receipt_items set line_total = quantity * unit_price where goods_receipt_id = p_id;
  end if;

  v_doc.receipt_number := coalesce(v_doc.receipt_number,
    sys_next_document_number(v_doc.company_id, 'GR', v_doc.receipt_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
    reference_type, reference_id, reference_number, created_by, lot_number, expiry_date,
    source_movement_id, copy_batch_identity)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'purchase_receipt',
         i.quantity * i.conversion_qty, i.unit_price / i.conversion_qty,
         'pur_goods_receipts', v_doc.id, v_doc.receipt_number, auth.uid(), i.lot_number, i.expiry_date,
         di.shipped_movement_id, di.id is not null
  from pur_goods_receipt_items i
  left join sal_delivery_items di on di.id = i.delivery_item_id
  where i.goods_receipt_id = p_id and i.quantity > 0
  order by i.created_at, i.id;

  update inv_items it set last_purchase_cost = i.unit_price / i.conversion_qty
  from pur_goods_receipt_items i
  where i.goods_receipt_id = p_id and it.id = i.item_id and i.quantity > 0;

  -- qty PO terpenuhi: kiriman cabang dihitung dari qty DIKIRIM (ditagih), selisih = kerugian kiriman
  update pur_purchase_order_items poi
     set received_qty = poi.received_qty + gri.total_qty
  from (select purchase_order_item_id, sum(coalesce(shipped_qty, quantity)) total_qty
        from pur_goods_receipt_items
        where goods_receipt_id = p_id and purchase_order_item_id is not null
        group by purchase_order_item_id) gri
  where poi.id = gri.purchase_order_item_id;

  update pur_goods_receipts set
    status = 'posted', posted_at = now(), receipt_number = v_doc.receipt_number,
    grand_total = (select coalesce(sum(line_total), 0) from pur_goods_receipt_items where goods_receipt_id = p_id)
  where id = p_id
  returning * into v_doc;

  if v_doc.delivery_id is not null then
    update sal_deliveries set status = 'received' where id = v_doc.delivery_id returning sales_order_id into v_so;
    perform sal_sync_po_status(v_so);
  elsif v_doc.purchase_order_id is not null then
    update pur_purchase_orders po set status =
      case when exists (select 1 from pur_purchase_order_items
                        where purchase_order_id = po.id and received_qty < quantity)
           then 'partially_received' else 'received' end
    where id = v_doc.purchase_order_id;
  end if;

  return to_jsonb(v_doc);
end $$;

-- Jurnal penerimaan: kiriman cabang -> persediaan + selisih kiriman | belum ditagih (qty dikirim)
create or replace function fin_post_goods_receipt_journal(p_receipt_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g          pur_goods_receipts%rowtype;
  v_supplier text;
  v_shipped  numeric(15,2);
  v_inv      numeric(15,2);
begin
  select * into g from pur_goods_receipts where id = p_receipt_id and status = 'posted';
  if not found or not exists (select 1 from fin_accounts where company_id = g.company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = 'purchase_receipt' and source_id = g.id) then return; end if;
  select name into v_supplier from pur_suppliers where id = g.supplier_id;

  if g.delivery_id is not null then
    select coalesce(sum(round(shipped_qty * unit_price, 2)), 0) into v_shipped from pur_goods_receipt_items where goods_receipt_id = g.id;
    select coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_inv
    from inv_stock_movements where reference_type = 'pur_goods_receipts' and reference_id = g.id;
    perform fin_create_journal(g.company_id, sal_outlet_of_warehouse(g.warehouse_id), g.receipt_date, 'purchase_receipt', g.id,
      'Terima kiriman cabang ' || g.receipt_number || ' - ' || v_supplier,
      fin_stock_journal_lines('pur_goods_receipts', g.id)
        || jsonb_build_array(
             jsonb_build_object('account_id', fin_account_id(g.company_id, 'ic_shipping_diff'), 'debit', v_shipped - v_inv, 'note', 'Selisih kiriman'),
             jsonb_build_object('account_id', fin_account_id(g.company_id, 'ic_grni'), 'credit', v_shipped)));
    return;
  end if;

  perform fin_create_journal(g.company_id, null, g.receipt_date, 'purchase_receipt', g.id,
    'Pembelian ' || g.receipt_number || ' - ' || v_supplier,
    fin_stock_journal_lines('pur_goods_receipts', g.id)
      || jsonb_build_array(jsonb_build_object('account_id', fin_account_id(g.company_id, 'ap'), 'credit', g.grand_total))
      || jsonb_build_array(jsonb_build_object('account_id', fin_account_id(g.company_id, 'inventory'),
           'debit', g.grand_total - coalesce((select sum(round(quantity * unit_cost, 2)) from inv_stock_movements
                                               where reference_type = 'pur_goods_receipts' and reference_id = g.id), 0))));
end $$;

-- hutang supplier (pihak ke-3) tidak mencakup kiriman cabang (ditagih lewat Sales Invoice)
create or replace view rpt_payables with (security_invoker = true) as
select g.company_id, g.id as goods_receipt_id, g.receipt_number, g.receipt_date, g.due_date,
       g.supplier_id, s.name as supplier_name, g.supplier_invoice_number,
       g.grand_total, g.paid_amount, g.grand_total - g.paid_amount as outstanding_amount,
       coalesce(g.due_date < current_date, false) and g.grand_total > g.paid_amount as is_overdue
from pur_goods_receipts g
join pur_suppliers s on s.id = g.supplier_id
where g.status = 'posted' and g.delivery_id is null;

create or replace function pur_block_internal_supplier_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from pur_goods_receipts where id = new.goods_receipt_id and delivery_id is not null) then
    raise exception 'Kiriman cabang dibayar lewat Pembayaran Sales Invoice, bukan pembayaran supplier';
  end if;
  return new;
end $$;
create trigger trg_fin_supplier_payment_items_internal before insert on fin_supplier_payment_items
  for each row execute function pur_block_internal_supplier_payment();

-- ---------------------------------------------------------------------
-- INVOICE (qty DIKIRIM yang belum ditagih)
-- ---------------------------------------------------------------------
create or replace function sal_refresh_invoice_status(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update sal_invoices set status = case
      when grand_total - paid_amount - credited_amount <= 0 then 'paid'
      when paid_amount + credited_amount > 0 then 'partial'
      else 'unpaid' end
  where id = p_id
$$;

create or replace function sal_create_invoice(p_so_id uuid, p_invoice_date date default current_date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  so      sal_sales_orders%rowtype;
  inv     sal_invoices%rowtype;
  v_term  int;
  v_sub   numeric(15,2);
  v_tax   numeric(15,2);
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  select * into so from sal_sales_orders where id = p_so_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Sales order tidak ditemukan'; end if;
  if not exists (
      select 1 from sal_delivery_items di join sal_deliveries d on d.id = di.delivery_id
      where d.sales_order_id = so.id and d.status in ('shipped', 'received') and di.invoiced_qty < di.quantity) then
    raise exception 'Tidak ada pengiriman yang belum ditagih';
  end if;

  v_term := case when so.customer_type = 'external' then (select payment_term_days from sal_customers where id = so.customer_id)
                 else (select s.payment_term_days from pur_purchase_orders po join pur_suppliers s on s.id = po.supplier_id where po.id = so.purchase_order_id) end;

  insert into sal_invoices (company_id, outlet_id, sales_order_id, customer_type, buyer_outlet_id, customer_id,
    invoice_number, invoice_date, due_date, note, created_by)
  values (so.company_id, so.outlet_id, so.id, so.customer_type, so.buyer_outlet_id, so.customer_id,
    sys_next_document_number(so.company_id, 'SINV', coalesce(p_invoice_date, current_date)), coalesce(p_invoice_date, current_date),
    coalesce(p_invoice_date, current_date) + coalesce(v_term, 0), nullif(trim(p_note), ''), auth.uid())
  returning * into inv;

  insert into sal_invoice_items (company_id, invoice_id, delivery_item_id, item_id, unit_id, quantity, unit_price, line_total)
  select di.company_id, inv.id, di.id, di.item_id, di.unit_id, di.quantity - di.invoiced_qty, di.unit_price,
         round((di.quantity - di.invoiced_qty) * di.unit_price, 2)
  from sal_delivery_items di join sal_deliveries d on d.id = di.delivery_id
  where d.sales_order_id = so.id and d.status in ('shipped', 'received') and di.invoiced_qty < di.quantity
  order by d.delivery_date, d.created_at, di.package_no, di.created_at;

  update sal_delivery_items di set invoiced_qty = di.quantity
  from sal_invoice_items ii where ii.invoice_id = inv.id and ii.delivery_item_id = di.id;

  select coalesce(sum(line_total), 0) into v_sub from sal_invoice_items where invoice_id = inv.id;
  v_tax := case when so.customer_type = 'external' then round(v_sub * so.tax_pct / 100, 2) else 0 end;
  update sal_invoices set subtotal = v_sub, tax_amount = v_tax, grand_total = v_sub + v_tax where id = inv.id returning * into inv;

  if exists (select 1 from fin_accounts where company_id = so.company_id) then
    if so.customer_type = 'internal' then
      perform fin_create_journal(so.company_id, so.outlet_id, inv.invoice_date, 'sales_invoice', inv.id,
        'Invoice ' || inv.invoice_number || ' ke ' || (select name from sys_outlets where id = so.buyer_outlet_id),
        jsonb_build_array(
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'ic_receivable'), 'debit', inv.grand_total),
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'ic_revenue'), 'credit', inv.grand_total)));
      -- cermin di pembeli: penerimaan belum ditagih -> hutang antar cabang
      perform fin_create_journal(so.company_id, so.buyer_outlet_id, inv.invoice_date, 'purchase_invoice_ic', inv.id,
        'Tagihan ' || inv.invoice_number || ' dari ' || (select name from sys_outlets where id = so.outlet_id),
        jsonb_build_array(
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'ic_grni'), 'debit', inv.grand_total),
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'ic_payable'), 'credit', inv.grand_total)));
    else
      perform fin_create_journal(so.company_id, so.outlet_id, inv.invoice_date, 'sales_invoice', inv.id,
        'Invoice ' || inv.invoice_number || ' - ' || (select name from sal_customers where id = so.customer_id),
        jsonb_build_array(
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'ar'), 'debit', inv.grand_total),
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'so_revenue'), 'credit', inv.subtotal),
          jsonb_build_object('account_id', fin_account_id(so.company_id, 'sales_tax_payable'), 'credit', inv.tax_amount)));
    end if;
  end if;

  return to_jsonb(inv);
end $$;

-- Nota kredit: kurang kirim / retur / potongan -> mengurangi piutang (dan hutang pembeli)
create or replace function sal_create_credit_note(p_invoice_id uuid, p_amount numeric, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  inv sal_invoices%rowtype;
  cn  sal_credit_notes%rowtype;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  select * into inv from sal_invoices where id = p_invoice_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Invoice tidak ditemukan'; end if;
  if coalesce(p_amount, 0) <= 0 or p_amount > inv.grand_total - inv.paid_amount - inv.credited_amount then
    raise exception 'Nominal nota kredit maksimal sisa tagihan (%)', inv.grand_total - inv.paid_amount - inv.credited_amount;
  end if;

  insert into sal_credit_notes (company_id, invoice_id, credit_number, credit_date, reason, amount, note, created_by)
  values (inv.company_id, inv.id, sys_next_document_number(inv.company_id, 'CN', current_date), current_date,
          coalesce(p_reason, 'other'), round(p_amount, 2), nullif(trim(p_note), ''), auth.uid())
  returning * into cn;
  update sal_invoices set credited_amount = credited_amount + cn.amount where id = inv.id;
  perform sal_refresh_invoice_status(inv.id);

  if exists (select 1 from fin_accounts where company_id = inv.company_id) then
    perform fin_create_journal(inv.company_id, inv.outlet_id, cn.credit_date, 'sales_credit_note', cn.id,
      'Nota kredit ' || cn.credit_number || ' / ' || inv.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', fin_account_id(inv.company_id, 'so_return'), 'debit', cn.amount),
        jsonb_build_object('account_id', fin_account_id(inv.company_id, case when inv.customer_type = 'internal' then 'ic_receivable' else 'ar' end),
                           'credit', cn.amount)));
    if inv.customer_type = 'internal' then
      perform fin_create_journal(inv.company_id, inv.buyer_outlet_id, cn.credit_date, 'purchase_credit_note_ic', cn.id,
        'Nota kredit ' || cn.credit_number || ' dari ' || (select name from sys_outlets where id = inv.outlet_id),
        jsonb_build_array(
          jsonb_build_object('account_id', fin_account_id(inv.company_id, 'ic_payable'), 'debit', cn.amount),
          jsonb_build_object('account_id', fin_account_id(inv.company_id, 'ic_shipping_diff'), 'credit', cn.amount)));
    end if;
  end if;
  return to_jsonb(cn);
end $$;

-- Pembayaran invoice. Internal: dicatat pembeli (dari akun pembeli -> akun penjual).
-- p_allocations = [{invoice_id, amount}]
create or replace function sal_record_payment(
  p_allocations jsonb, p_to_account_id uuid, p_from_account_id uuid default null,
  p_payment_date date default current_date, p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_first   sal_invoices%rowtype;
  v_inv     sal_invoices%rowtype;
  v_alloc   jsonb;
  v_amt     numeric(15,2);
  v_total   numeric(15,2) := 0;
  p         sal_payments%rowtype;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('finance.manage') or sys_has_permission('purchasing.manage')) then
    raise exception 'Tidak punya izin';
  end if;
  select i.* into v_first from sal_invoices i
  where i.company_id = v_company and i.id = (p_allocations->0->>'invoice_id')::uuid;
  if not found then raise exception 'Pilih invoice yang dibayar'; end if;

  if not exists (select 1 from fin_accounts where id = p_to_account_id and company_id = v_company and account_type = 'asset' and not is_header) then
    raise exception 'Akun penerima tidak valid';
  end if;
  if v_first.customer_type = 'internal' and not exists (
      select 1 from fin_accounts where id = p_from_account_id and company_id = v_company and account_type = 'asset' and not is_header) then
    raise exception 'Pilih akun kas/bank pembayar';
  end if;

  insert into sal_payments (company_id, outlet_id, customer_type, buyer_outlet_id, customer_id, payment_number, payment_date,
    amount, from_account_id, to_account_id, reference_number, note, created_by)
  values (v_company, v_first.outlet_id, v_first.customer_type, v_first.buyer_outlet_id, v_first.customer_id,
    sys_next_document_number(v_company, 'RCV', coalesce(p_payment_date, current_date)), coalesce(p_payment_date, current_date),
    1, case when v_first.customer_type = 'internal' then p_from_account_id end, p_to_account_id,
    nullif(trim(p_reference), ''), nullif(trim(p_note), ''), auth.uid())
  returning * into p;

  for v_alloc in select * from jsonb_array_elements(p_allocations) loop
    v_amt := round((v_alloc->>'amount')::numeric, 2);
    if coalesce(v_amt, 0) <= 0 then continue; end if;
    select * into v_inv from sal_invoices where id = (v_alloc->>'invoice_id')::uuid and company_id = v_company for update;
    if not found or v_inv.outlet_id <> v_first.outlet_id or v_inv.customer_type <> v_first.customer_type
       or v_inv.buyer_outlet_id is distinct from v_first.buyer_outlet_id or v_inv.customer_id is distinct from v_first.customer_id then
      raise exception 'Satu pembayaran hanya untuk invoice dari penjual & pembeli yang sama';
    end if;
    if v_amt > v_inv.grand_total - v_inv.paid_amount - v_inv.credited_amount then
      raise exception 'Pembayaran % melebihi sisa tagihan', v_inv.invoice_number;
    end if;
    insert into sal_payment_items (company_id, payment_id, invoice_id, amount) values (v_company, p.id, v_inv.id, v_amt);
    update sal_invoices set paid_amount = paid_amount + v_amt where id = v_inv.id;
    perform sal_refresh_invoice_status(v_inv.id);
    v_total := v_total + v_amt;
  end loop;
  if v_total <= 0 then raise exception 'Nominal pembayaran harus lebih dari 0'; end if;
  update sal_payments set amount = v_total where id = p.id returning * into p;

  if exists (select 1 from fin_accounts where company_id = v_company) then
    if p.customer_type = 'internal' then
      perform fin_create_journal(v_company, p.buyer_outlet_id, p.payment_date, 'sales_payment_buyer', p.id,
        'Bayar ' || p.payment_number || ' ke ' || (select name from sys_outlets where id = p.outlet_id),
        jsonb_build_array(
          jsonb_build_object('account_id', fin_account_id(v_company, 'ic_payable'), 'debit', v_total),
          jsonb_build_object('account_id', p.from_account_id, 'credit', v_total)));
      perform fin_create_journal(v_company, p.outlet_id, p.payment_date, 'sales_payment', p.id,
        'Terima ' || p.payment_number || ' dari ' || (select name from sys_outlets where id = p.buyer_outlet_id),
        jsonb_build_array(
          jsonb_build_object('account_id', p.to_account_id, 'debit', v_total),
          jsonb_build_object('account_id', fin_account_id(v_company, 'ic_receivable'), 'credit', v_total)));
    else
      perform fin_create_journal(v_company, p.outlet_id, p.payment_date, 'sales_payment', p.id,
        'Terima ' || p.payment_number || ' - ' || (select name from sal_customers where id = p.customer_id),
        jsonb_build_array(
          jsonb_build_object('account_id', p.to_account_id, 'debit', v_total),
          jsonb_build_object('account_id', fin_account_id(v_company, 'ar'), 'credit', v_total)));
    end if;
  end if;
  return to_jsonb(p);
end $$;

-- ---------------------------------------------------------------------
-- BARCODE: label koli pengiriman cabang
-- ---------------------------------------------------------------------
create or replace function inv_resolve_barcode(p_code text, p_warehouse_id uuid default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v      jsonb;
begin
  if v_code = '' then return null; end if;

  select jsonb_build_object('kind', 'package', 'package_id', p.id, 'package_code', p.package_code, 'package_no', p.package_no,
           'status', p.status, 'stock_transfer_id', p.stock_transfer_id, 'transfer_number', t.transfer_number,
           'to_warehouse_id', t.to_warehouse_id)
    into v
  from inv_transfer_packages p join inv_stock_transfers t on t.id = p.stock_transfer_id
  where upper(p.package_code) = v_code;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'delivery_package', 'package_code', p.package_code, 'package_no', p.package_no,
           'delivery_id', d.id, 'delivery_number', d.delivery_number, 'status', d.status, 'goods_receipt_id', d.goods_receipt_id)
    into v
  from sal_delivery_packages p join sal_deliveries d on d.id = p.delivery_id
  where upper(p.package_code) = v_code;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'batch', 'batch_id', b.id, 'batch_code', b.batch_code, 'item_id', b.item_id,
           'item_code', it.code, 'item_name', it.name, 'unit_code', u.code, 'qty', 1,
           'warehouse_id', b.warehouse_id, 'qty_remaining', b.qty_remaining, 'expiry_date', b.expiry_date, 'lot_number', b.lot_number)
    into v
  from inv_stock_batches b join inv_items it on it.id = b.item_id join inv_units u on u.id = it.base_unit_id
  where upper(b.batch_code) = v_code
  order by (b.warehouse_id = p_warehouse_id) desc nulls last, b.qty_remaining desc
  limit 1;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'item', 'item_id', it.id, 'item_code', it.code, 'item_name', it.name,
           'unit_code', bu.code, 'qty', iu.conversion_qty, 'scanned_unit', su.code)
    into v
  from inv_item_units iu join inv_items it on it.id = iu.item_id
  join inv_units bu on bu.id = it.base_unit_id join inv_units su on su.id = iu.unit_id
  where upper(iu.barcode) = v_code limit 1;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'item', 'item_id', it.id, 'item_code', it.code, 'item_name', it.name,
           'unit_code', u.code, 'qty', 1, 'scanned_unit', u.code)
    into v
  from inv_items it join inv_units u on u.id = it.base_unit_id
  where upper(it.code) = v_code limit 1;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- VIEW
-- ---------------------------------------------------------------------
create view rpt_sales_invoices with (security_invoker = true) as
select i.id, i.company_id, i.outlet_id, so_.name as seller_name, i.sales_order_id, s.so_number,
       i.customer_type, i.buyer_outlet_id, i.customer_id,
       coalesce(bo.name, c.name) as customer_name,
       i.invoice_number, i.invoice_date, i.due_date, i.subtotal, i.tax_amount, i.grand_total,
       i.paid_amount, i.credited_amount, i.grand_total - i.paid_amount - i.credited_amount as outstanding_amount,
       i.status, i.status <> 'paid' and i.due_date < current_date as is_overdue
from sal_invoices i
join sal_sales_orders s on s.id = i.sales_order_id
join sys_outlets so_ on so_.id = i.outlet_id
left join sys_outlets bo on bo.id = i.buyer_outlet_id
left join sal_customers c on c.id = i.customer_id;

-- pendapatan per sumber: POS vs Sales Order (antar cabang / B2B)
create view rpt_revenue_by_source with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date as revenue_date, 'pos'::text as source,
       sum(o.subtotal - o.discount_amount - coalesce(o.promotion_amount, 0) - coalesce(o.points_amount, 0) + o.service_amount) as amount
from pos_orders o where o.status = 'paid'
group by o.company_id, o.outlet_id, o.business_date
union all
select i.company_id, i.outlet_id, i.invoice_date, case when i.customer_type = 'internal' then 'sales_order_internal' else 'sales_order_b2b' end,
       sum(i.subtotal)
from sal_invoices i
group by i.company_id, i.outlet_id, i.invoice_date, i.customer_type;

-- ---------------------------------------------------------------------
-- RLS, PERMISSION, DATA AWAL
-- ---------------------------------------------------------------------
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('sal_customers', 'sales.manage');
select sys_apply_company_policies('sal_pricelists', 'sales.manage');
select sys_apply_company_policies('sal_pricelist_items', 'sales.manage');
select sys_apply_company_policies('sal_sales_orders', 'sales.manage');
select sys_apply_company_policies('sal_sales_order_items', 'sales.manage');
select sys_apply_company_policies('sal_deliveries', 'sales.manage');
select sys_apply_company_policies('sal_delivery_items', 'sales.manage');
select sys_apply_company_policies('sal_delivery_packages');
select sys_apply_company_policies('sal_invoices');
select sys_apply_company_policies('sal_invoice_items');
select sys_apply_company_policies('sal_credit_notes');
select sys_apply_company_policies('sal_payments');
select sys_apply_company_policies('sal_payment_items');

create trigger trg_sal_customers_audit after insert or update or delete on sal_customers
  for each row execute function sys_audit_trigger('');
create trigger trg_sal_pricelists_audit after insert or update or delete on sal_pricelists
  for each row execute function sys_audit_trigger('');
create trigger trg_sal_sales_orders_audit after insert or update or delete on sal_sales_orders
  for each row execute function sys_audit_trigger('');

-- role yang mengelola pembelian juga mendapat akses penjualan
update sys_roles set permissions = permissions || '["sales.manage"]'::jsonb
where permissions ? 'purchasing.manage' and not permissions ? 'sales.manage' and not permissions ? '*';

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform fin_ensure_sales_accounts(r.id); end loop;
  for r in select id from sys_outlets loop perform pur_ensure_internal_supplier(r.id); end loop;
end $$;

alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v5;
revoke execute on function sys_onboard_company_v5(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_result  jsonb;
  v_company uuid;
begin
  v_result := sys_onboard_company_v5(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  v_company := (v_result->>'company_id')::uuid;
  perform fin_ensure_sales_accounts(v_company);
  update sys_roles set permissions = permissions || '["sales.manage"]'::jsonb
  where company_id = v_company and permissions ? 'purchasing.manage' and not permissions ? 'sales.manage' and not permissions ? '*';
  return v_result;
end $$;

revoke execute on function fin_ensure_sales_accounts(uuid)        from public, anon, authenticated;
revoke execute on function pur_ensure_internal_supplier(uuid)     from public, anon, authenticated;
revoke execute on function sal_outlet_of_warehouse(uuid)          from public, anon, authenticated;
revoke execute on function sal_recalculate_order(uuid)            from public, anon, authenticated;
revoke execute on function sal_sync_po_status(uuid)               from public, anon, authenticated;
revoke execute on function sal_refresh_invoice_status(uuid)       from public, anon, authenticated;

-- >>>>>>>>>> migrations/021_pos_settlement.sql
-- =====================================================================
-- SANTAP ERP - 021: SETTLEMENT UANG PENDAPATAN POS
--   Per outlet x metode bayar x tanggal bisnis:
--     seharusnya (penjualan - refund)  vs  dana yang benar-benar masuk
--   Tunai : setoran ke bank (Kas -> Bank), selisih setoran dicatat
--   Non tunai (EDC/QRIS/transfer/ojol): penjualan dicatat ke akun penampung
--     "Piutang Settlement", saat dana cair: Bank + potongan MDR/komisi | penampung
-- =====================================================================

create or replace function fin_ensure_settlement_accounts(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance, system_key)
  select p_company_id, (select id from fin_accounts where company_id = p_company_id and code = x.parent),
         x.code, x.name, x.type, x.normal, x.skey
  from (values
    ('1-0000', '1-1320', 'Piutang Settlement (EDC/QRIS/Ojol)', 'asset',   'debit', 'settlement_clearing'),
    ('6-0000', '6-2100', 'Selisih Kas & Settlement',           'expense', 'debit', 'settlement_difference')
  ) as x(parent, code, name, type, normal, skey)
  where not exists (select 1 from fin_accounts a where a.company_id = p_company_id and (a.system_key = x.skey or a.code = x.code));
end $$;

-- ---------------------------------------------------------------------
-- METODE BAYAR: tujuan pencairan & potongan
-- ---------------------------------------------------------------------
alter table mst_payment_methods add column settlement_account_id uuid references fin_accounts(id);  -- dana cair ke (bank)
alter table mst_payment_methods add column fee_account_id        uuid references fin_accounts(id);  -- beban MDR / komisi
alter table mst_payment_methods add column fee_pct               numeric(6,3) not null default 0 check (fee_pct between 0 and 100);
alter table mst_payment_methods add column settlement_from       date not null default current_date; -- penjualan sebelum ini tidak perlu settlement

-- metode non tunai lama: penjualan berikutnya ke akun penampung, cair ke bank
create or replace function fin_setup_payment_settlement(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  perform fin_ensure_settlement_accounts(p_company_id);
  update mst_payment_methods m set
    settlement_account_id = coalesce(m.settlement_account_id,
      case when m.type = 'cash' then fin_account_id(p_company_id, 'bank')
           else coalesce(nullif(m.account_id, fin_account_id(p_company_id, 'cash')), fin_account_id(p_company_id, 'bank')) end),
    account_id = case when m.type <> 'cash' and m.account_id = fin_account_id(p_company_id, 'bank')
                      then fin_account_id(p_company_id, 'settlement_clearing') else m.account_id end,
    fee_account_id = coalesce(m.fee_account_id,
      (select id from fin_accounts where company_id = p_company_id and code = case when m.type = 'online' then '6-1700' else '6-1800' end))
  where m.company_id = p_company_id;
end $$;

-- metode bayar baru: non tunai -> akun penampung
create or replace function mst_on_payment_method_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from fin_accounts where company_id = new.company_id) then
    if new.account_id is null then
      new.account_id := case when new.type = 'cash' then fin_account_id(new.company_id, 'cash')
                             else coalesce(fin_account_id_or_null(new.company_id, 'settlement_clearing'), fin_account_id(new.company_id, 'bank')) end;
    end if;
    new.settlement_account_id := coalesce(new.settlement_account_id, fin_account_id_or_null(new.company_id, 'bank'));
    new.fee_account_id := coalesce(new.fee_account_id,
      (select id from fin_accounts where company_id = new.company_id and code = case when new.type = 'online' then '6-1700' else '6-1800' end));
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- SETTLEMENT
-- ---------------------------------------------------------------------
create table pos_settlements (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  outlet_id          uuid not null references sys_outlets(id),
  payment_method_id  uuid not null references mst_payment_methods(id),
  settlement_number  text not null,
  settlement_date    date not null default current_date,   -- tanggal dana masuk / setor
  date_from          date not null,
  date_to            date not null,
  expected_amount    numeric(15,2) not null,                -- penjualan - refund
  received_amount    numeric(15,2) not null check (received_amount >= 0),
  fee_amount         numeric(15,2) not null default 0 check (fee_amount >= 0),
  difference_amount  numeric(15,2) not null default 0,      -- + = kurang terima
  to_account_id      uuid not null references fin_accounts(id),
  reference_number   text,
  note               text,
  created_by         uuid references sys_users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table pos_settlement_items (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  settlement_id      uuid not null references pos_settlements(id) on delete cascade,
  outlet_id          uuid not null references sys_outlets(id),
  payment_method_id  uuid not null references mst_payment_methods(id),
  business_date      date not null,
  sales_amount       numeric(15,2) not null,
  refund_amount      numeric(15,2) not null default 0,
  created_at         timestamptz not null default now(),
  unique (outlet_id, payment_method_id, business_date)
);

-- pendapatan POS per outlet x metode x tanggal + status settlement
create view rpt_pos_settlement_days with (security_invoker = true) as
with sales as (
  select o.company_id, o.outlet_id, p.payment_method_id, o.business_date, sum(p.amount - p.change_amount) amount, count(distinct o.id) orders
  from pos_payments p join pos_orders o on o.id = p.order_id
  where o.status in ('paid', 'refunded')
  group by o.company_id, o.outlet_id, p.payment_method_id, o.business_date
), refunds as (
  select r.company_id, r.outlet_id, rp.payment_method_id, r.business_date, sum(rp.amount) amount
  from pos_refund_payments rp join pos_refunds r on r.id = rp.refund_id
  group by r.company_id, r.outlet_id, rp.payment_method_id, r.business_date
), days as (
  select company_id, outlet_id, payment_method_id, business_date from sales
  union
  select company_id, outlet_id, payment_method_id, business_date from refunds
)
select d.company_id, d.outlet_id, o.name as outlet_name, d.payment_method_id, m.name as payment_method_name, m.type as payment_type,
       d.business_date, coalesce(s.orders, 0) as order_count,
       coalesce(s.amount, 0) as sales_amount, coalesce(r.amount, 0) as refund_amount,
       coalesce(s.amount, 0) - coalesce(r.amount, 0) as net_amount,
       round((coalesce(s.amount, 0) - coalesce(r.amount, 0)) * m.fee_pct / 100, 2) as estimated_fee,
       si.settlement_id, st.settlement_number,
       d.business_date >= m.settlement_from as needs_settlement
from days d
join sys_outlets o on o.id = d.outlet_id
join mst_payment_methods m on m.id = d.payment_method_id
left join sales s on s.outlet_id = d.outlet_id and s.payment_method_id = d.payment_method_id and s.business_date = d.business_date
left join refunds r on r.outlet_id = d.outlet_id and r.payment_method_id = d.payment_method_id and r.business_date = d.business_date
left join pos_settlement_items si on si.outlet_id = d.outlet_id and si.payment_method_id = d.payment_method_id and si.business_date = d.business_date
left join pos_settlements st on st.id = si.settlement_id;

-- Buat settlement: tanggal-tanggal yang belum di-settle untuk 1 outlet & 1 metode
create or replace function pos_create_settlement(
  p_outlet_id uuid, p_payment_method_id uuid, p_dates date[], p_received_amount numeric,
  p_fee_amount numeric default 0, p_to_account_id uuid default null, p_settlement_date date default current_date,
  p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  m          mst_payment_methods%rowtype;
  s          pos_settlements%rowtype;
  v_expected numeric(15,2);
  v_diff     numeric(15,2);
  v_to       uuid;
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  select * into m from mst_payment_methods where id = p_payment_method_id and company_id = v_company;
  if not found then raise exception 'Metode bayar tidak ditemukan'; end if;
  if not exists (select 1 from sys_outlets where id = p_outlet_id and company_id = v_company) then raise exception 'Outlet tidak ditemukan'; end if;
  if coalesce(array_length(p_dates, 1), 0) = 0 then raise exception 'Pilih tanggal yang di-settle'; end if;
  if coalesce(p_received_amount, -1) < 0 or coalesce(p_fee_amount, 0) < 0 then raise exception 'Nominal tidak valid'; end if;

  if exists (select 1 from pos_settlement_items where outlet_id = p_outlet_id and payment_method_id = m.id and business_date = any(p_dates)) then
    raise exception 'Sebagian tanggal sudah pernah di-settle';
  end if;
  select coalesce(sum(net_amount), 0) into v_expected
  from rpt_pos_settlement_days where outlet_id = p_outlet_id and payment_method_id = m.id and business_date = any(p_dates);
  v_diff := v_expected - round(p_received_amount, 2) - round(coalesce(p_fee_amount, 0), 2);
  v_to := coalesce(p_to_account_id, m.settlement_account_id);
  if not exists (select 1 from fin_accounts where id = v_to and company_id = v_company and account_type = 'asset' and not is_header) then
    raise exception 'Pilih akun bank tujuan';
  end if;

  insert into pos_settlements (company_id, outlet_id, payment_method_id, settlement_number, settlement_date, date_from, date_to,
    expected_amount, received_amount, fee_amount, difference_amount, to_account_id, reference_number, note, created_by)
  values (v_company, p_outlet_id, m.id, sys_next_document_number(v_company, 'STL', coalesce(p_settlement_date, current_date)),
    coalesce(p_settlement_date, current_date), (select min(x) from unnest(p_dates) x), (select max(x) from unnest(p_dates) x),
    v_expected, round(p_received_amount, 2), round(coalesce(p_fee_amount, 0), 2), v_diff, v_to,
    nullif(trim(p_reference), ''), nullif(trim(p_note), ''), auth.uid())
  returning * into s;

  insert into pos_settlement_items (company_id, settlement_id, outlet_id, payment_method_id, business_date, sales_amount, refund_amount)
  select v_company, s.id, p_outlet_id, m.id, d.business_date, d.sales_amount, d.refund_amount
  from rpt_pos_settlement_days d
  where d.outlet_id = p_outlet_id and d.payment_method_id = m.id and d.business_date = any(p_dates);
  if not found then raise exception 'Tidak ada penjualan pada tanggal tersebut'; end if;

  -- Bank (diterima) + beban potongan + selisih | akun metode bayar (kas / penampung)
  if exists (select 1 from fin_accounts where company_id = v_company) then
    perform fin_create_journal(v_company, p_outlet_id, s.settlement_date, 'pos_settlement', s.id,
      'Settlement ' || m.name || ' ' || to_char(s.date_from, 'DD/MM') ||
        case when s.date_to <> s.date_from then ' - ' || to_char(s.date_to, 'DD/MM') else '' end,
      jsonb_build_array(
        jsonb_build_object('account_id', v_to, 'debit', s.received_amount, 'note', coalesce(s.reference_number, 'Dana masuk')),
        jsonb_build_object('account_id', coalesce(m.fee_account_id, fin_account_id(v_company, 'settlement_difference')),
                           'debit', s.fee_amount, 'note', 'Potongan MDR / komisi'),
        jsonb_build_object('account_id', fin_account_id(v_company, 'settlement_difference'), 'debit', s.difference_amount, 'note', 'Selisih'),
        jsonb_build_object('account_id', coalesce(m.account_id, fin_account_id(v_company, 'cash')), 'credit', s.expected_amount)));
  end if;
  return to_jsonb(s);
end $$;

-- ---------------------------------------------------------------------
-- RLS & DATA AWAL
-- ---------------------------------------------------------------------
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('pos_settlements');
select sys_apply_company_policies('pos_settlement_items');

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform fin_setup_payment_settlement(r.id); end loop;
end $$;

alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v6;
revoke execute on function sys_onboard_company_v6(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v6(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform fin_setup_payment_settlement((v_result->>'company_id')::uuid);
  return v_result;
end $$;

revoke execute on function fin_ensure_settlement_accounts(uuid)  from public, anon, authenticated;
revoke execute on function fin_setup_payment_settlement(uuid)    from public, anon, authenticated;

-- >>>>>>>>>> migrations/022_approval_matrix.sql
-- =====================================================================
-- SANTAP ERP - 022: APPROVAL UNTUK SEMUA TRANSAKSI PENTING (1 TINGKAT)
--   Jenis baru: sales_order, credit_note, sales_payment, supplier_payment,
--               pos_settlement, manual_journal, stock_transfer
--   Penyetuju = role yang punya hak approval.<jenis> (diatur di matriks
--   Pengaturan -> Approval Transaksi). Penyetuju tidak perlu punya akses
--   modulnya: saat menyetujui, sistem menjalankan transaksi atas nama pembuat.
-- =====================================================================

-- ---------------------------------------------------------------------
-- DELEGASI: selama keputusan approval diproses, penyetuju "bertindak sebagai"
-- pembuat untuk hak akses modul tertentu (hanya di dalam transaksi itu)
-- ---------------------------------------------------------------------
create or replace function sys_has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select r.permissions ? '*' or r.permissions ? p_permission
    from sys_users u join sys_roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active
  ), false)
  or coalesce(p_permission = any(string_to_array(nullif(current_setting('erp.acting_for', true), ''), ',')), false)
$$;

create or replace function sys_act_for(p_permissions text)
returns void language sql security definer set search_path = public as $$
  select set_config('erp.acting_for', coalesce(p_permissions, ''), true)
$$;

-- ---------------------------------------------------------------------
-- ATURAN
-- ---------------------------------------------------------------------
alter table sys_approval_rules drop constraint sys_approval_rules_document_type_check;
alter table sys_approval_rules add constraint sys_approval_rules_document_type_check
  check (document_type in ('purchase_order', 'expense', 'stock_adjustment', 'stock_opname', 'refund', 'product', 'pricelist',
                           'sales_order', 'credit_note', 'sales_payment', 'supplier_payment', 'pos_settlement',
                           'manual_journal', 'stock_transfer'));

create or replace function sys_setup_approval_rules(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into sys_approval_rules (company_id, document_type, min_amount, is_enabled) values
    (p_company_id, 'purchase_order',   5000000, false),
    (p_company_id, 'expense',          1000000, false),
    (p_company_id, 'stock_adjustment',  500000, false),
    (p_company_id, 'stock_opname',     1000000, false),
    (p_company_id, 'refund',                 0, false),
    (p_company_id, 'product',                0, false),
    (p_company_id, 'pricelist',              0, false),
    (p_company_id, 'sales_order',     10000000, false),
    (p_company_id, 'credit_note',            0, false),
    (p_company_id, 'sales_payment',   10000000, false),
    (p_company_id, 'supplier_payment', 5000000, false),
    (p_company_id, 'pos_settlement',     50000, false),
    (p_company_id, 'manual_journal',         0, false),
    (p_company_id, 'stock_transfer',   5000000, false)
  on conflict do nothing
$$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform sys_setup_approval_rules(r.id); end loop;
end $$;

-- ---------------------------------------------------------------------
-- SALES ORDER: konfirmasi SO (cabang & B2B)
-- ---------------------------------------------------------------------
alter table sal_sales_orders drop constraint sal_sales_orders_status_check;
alter table sal_sales_orders add constraint sal_sales_orders_status_check check (status in
  ('draft', 'new', 'pending_approval', 'confirmed', 'partially_delivered', 'delivered', 'closed', 'rejected', 'cancelled'));

create or replace function sal_confirm_sales_order(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  so      sal_sales_orders%rowtype;
  c       sal_customers%rowtype;
  v_open  numeric;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('approval.sales_order')) then raise exception 'Tidak punya izin'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('draft', 'new', 'pending_approval') then raise exception 'Sales order tidak ditemukan / sudah dikonfirmasi'; end if;
  if not exists (select 1 from sal_sales_order_items where sales_order_id = p_id) then raise exception 'Sales order belum punya item'; end if;
  if exists (select 1 from sal_sales_order_items where sales_order_id = p_id and unit_price <= 0) and so.customer_type = 'external' then
    raise exception 'Ada barang tanpa harga. Isi harga atau tambahkan di Pricelist Jual.';
  end if;
  perform sal_recalculate_order(p_id);
  select * into so from sal_sales_orders where id = p_id;

  if so.customer_type = 'external' then
    select * into c from sal_customers where id = so.customer_id;
    if c.credit_limit > 0 then
      select coalesce((select sum(grand_total - paid_amount - credited_amount) from sal_invoices where customer_id = c.id), 0)
           + coalesce((select sum(grand_total) from sal_sales_orders where customer_id = c.id and id <> p_id
                       and status in ('confirmed', 'partially_delivered')), 0)
        into v_open;
      if v_open + so.grand_total > c.credit_limit then
        raise exception 'Melebihi limit kredit % (terpakai %, SO ini %)', to_char(c.credit_limit, 'FM999G999G999'),
          to_char(v_open, 'FM999G999G999'), to_char(so.grand_total, 'FM999G999G999');
      end if;
    end if;
  end if;

  if sys_approval_required('sales_order', so.grand_total) then
    if so.status = 'pending_approval' then raise exception 'Sales order ini masih menunggu persetujuan'; end if;
    update sal_sales_orders set status = 'pending_approval',
      so_number = coalesce(so_number, sys_next_document_number(company_id, 'SO', so_date))
    where id = p_id returning * into so;
    return to_jsonb(so) || sys_request_approval('sales_order', p_id, so.outlet_id, so.grand_total,
      'SO ' || so.so_number || ' - ' || coalesce((select name from sal_customers where id = so.customer_id),
                                                 (select name from sys_outlets where id = so.buyer_outlet_id), ''), '{}');
  end if;

  update sal_sales_orders set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now(),
    so_number = coalesce(so_number, sys_next_document_number(company_id, 'SO', so_date))
  where id = p_id returning * into so;
  perform sys_close_approval('sales_order', p_id);
  return to_jsonb(so);
end $$;

create or replace function sal_reject_sales_order(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare so sal_sales_orders%rowtype;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('draft', 'new', 'pending_approval', 'confirmed')
     or exists (select 1 from sal_deliveries where sales_order_id = p_id and status <> 'cancelled') then
    raise exception 'Sales order tidak bisa ditolak (sudah ada pengiriman)';
  end if;
  update sal_sales_orders set status = case when customer_type = 'internal' then 'rejected' else 'cancelled' end,
    reject_reason = trim(p_reason) where id = p_id;
  update sys_approval_requests set status = 'cancelled', decision_note = 'SO ditolak / dibatalkan'
  where document_type = 'sales_order' and document_id = p_id and status = 'pending';
  if so.purchase_order_id is not null then
    update pur_purchase_orders set status = 'cancelled', sales_note = 'Ditolak penjual: ' || trim(p_reason) where id = so.purchase_order_id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- TRANSAKSI SEKALI JALAN: dibungkus pemeriksa approval.
-- Fungsi asli diganti nama *_execute dan hanya dipanggil wrapper / keputusan approval.
-- ---------------------------------------------------------------------
alter function sal_create_credit_note(uuid, numeric, text, text) rename to sal_create_credit_note_execute;
alter function sal_record_payment(jsonb, uuid, uuid, date, text, text) rename to sal_record_payment_execute;
alter function fin_pay_supplier(uuid, uuid, date, jsonb, text) rename to fin_pay_supplier_execute;
alter function pos_create_settlement(uuid, uuid, date[], numeric, numeric, uuid, date, text, text) rename to pos_create_settlement_execute;
alter function fin_post_manual_journal(date, text, jsonb) rename to fin_post_manual_journal_execute;

-- Nota kredit
create or replace function sal_create_credit_note(p_invoice_id uuid, p_amount numeric, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv sal_invoices%rowtype;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('approval.credit_note')) then raise exception 'Tidak punya izin'; end if;
  select * into inv from sal_invoices where id = p_invoice_id and company_id = sys_current_company_id();
  if not found then raise exception 'Invoice tidak ditemukan'; end if;
  if coalesce(p_amount, 0) <= 0 or p_amount > inv.grand_total - inv.paid_amount - inv.credited_amount then
    raise exception 'Nominal nota kredit maksimal sisa tagihan (%)', inv.grand_total - inv.paid_amount - inv.credited_amount;
  end if;
  if sys_approval_required('credit_note', p_amount) then
    return sys_request_approval('credit_note', inv.id, inv.outlet_id, p_amount, 'Nota kredit ' || inv.invoice_number,
      jsonb_build_object('amount', p_amount, 'reason', p_reason, 'note', p_note));
  end if;
  return sal_create_credit_note_execute(p_invoice_id, p_amount, p_reason, p_note);
end $$;

-- Pembayaran invoice (terima pembayaran B2B / bayar tagihan cabang)
create or replace function sal_record_payment(
  p_allocations jsonb, p_to_account_id uuid, p_from_account_id uuid default null,
  p_payment_date date default current_date, p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_total numeric;
  v_inv   sal_invoices%rowtype;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('finance.manage') or sys_has_permission('purchasing.manage')
          or sys_has_permission('approval.sales_payment')) then
    raise exception 'Tidak punya izin';
  end if;
  select coalesce(sum(round((a->>'amount')::numeric, 2)), 0) into v_total from jsonb_array_elements(p_allocations) a where (a->>'amount')::numeric > 0;
  select * into v_inv from sal_invoices where id = (p_allocations->0->>'invoice_id')::uuid and company_id = sys_current_company_id();
  if not found then raise exception 'Pilih invoice yang dibayar'; end if;
  if sys_approval_required('sales_payment', v_total) then
    return sys_request_approval('sales_payment', v_inv.id, v_inv.outlet_id, v_total,
      'Pembayaran ' || v_inv.invoice_number || case when jsonb_array_length(p_allocations) > 1 then ' dkk' else '' end,
      jsonb_build_object('allocations', p_allocations, 'to_account_id', p_to_account_id, 'from_account_id', p_from_account_id,
                         'payment_date', coalesce(p_payment_date, current_date), 'reference', p_reference, 'note', p_note));
  end if;
  return sal_record_payment_execute(p_allocations, p_to_account_id, p_from_account_id, p_payment_date, p_reference, p_note);
end $$;

-- Bayar supplier
create or replace function fin_pay_supplier(
  p_supplier_id uuid, p_account_id uuid, p_payment_date date, p_allocations jsonb, p_reference_number text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_total numeric;
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.supplier_payment')) then raise exception 'Tidak punya izin'; end if;
  select coalesce(sum((a->>'amount')::numeric), 0) into v_total from jsonb_array_elements(p_allocations) a where (a->>'amount')::numeric > 0;
  if v_total <= 0 then raise exception 'Nominal pembayaran harus lebih dari 0'; end if;
  if sys_approval_required('supplier_payment', v_total) then
    return sys_request_approval('supplier_payment', p_supplier_id, null, v_total,
      'Bayar supplier ' || coalesce((select name from pur_suppliers where id = p_supplier_id), ''),
      jsonb_build_object('supplier_id', p_supplier_id, 'account_id', p_account_id, 'payment_date', coalesce(p_payment_date, current_date),
                         'allocations', p_allocations, 'reference', p_reference_number));
  end if;
  return fin_pay_supplier_execute(p_supplier_id, p_account_id, p_payment_date, p_allocations, p_reference_number);
end $$;

-- Settlement POS: yang dinilai adalah SELISIH (seharusnya - diterima - potongan)
create or replace function pos_create_settlement(
  p_outlet_id uuid, p_payment_method_id uuid, p_dates date[], p_received_amount numeric,
  p_fee_amount numeric default 0, p_to_account_id uuid default null, p_settlement_date date default current_date,
  p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_expected numeric;
  v_diff     numeric;
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.pos_settlement')) then raise exception 'Tidak punya izin'; end if;
  if exists (select 1 from pos_settlement_items where outlet_id = p_outlet_id and payment_method_id = p_payment_method_id and business_date = any(p_dates)) then
    raise exception 'Sebagian tanggal sudah pernah di-settle';
  end if;
  if exists (select 1 from sys_approval_requests where document_type = 'pos_settlement' and status = 'pending'
             and payload->>'outlet_id' = p_outlet_id::text and payload->>'payment_method_id' = p_payment_method_id::text
             and exists (select 1 from jsonb_array_elements_text(payload->'dates') d where d::date = any(p_dates))) then
    raise exception 'Sebagian tanggal sedang menunggu persetujuan settlement';
  end if;
  select coalesce(sum(net_amount), 0) into v_expected
  from rpt_pos_settlement_days where outlet_id = p_outlet_id and payment_method_id = p_payment_method_id and business_date = any(p_dates);
  v_diff := v_expected - round(coalesce(p_received_amount, 0), 2) - round(coalesce(p_fee_amount, 0), 2);

  if sys_approval_required('pos_settlement', abs(v_diff)) then
    return sys_request_approval('pos_settlement', p_payment_method_id, p_outlet_id, abs(v_diff),
      'Settlement ' || (select name from mst_payment_methods where id = p_payment_method_id) || ' ' ||
        (select name from sys_outlets where id = p_outlet_id) || ', selisih ' || to_char(v_diff, 'FM999G999G999'),
      jsonb_build_object('outlet_id', p_outlet_id, 'payment_method_id', p_payment_method_id, 'dates', to_jsonb(p_dates),
        'received_amount', p_received_amount, 'fee_amount', coalesce(p_fee_amount, 0), 'to_account_id', p_to_account_id,
        'settlement_date', coalesce(p_settlement_date, current_date), 'reference', p_reference, 'note', p_note));
  end if;
  return pos_create_settlement_execute(p_outlet_id, p_payment_method_id, p_dates, p_received_amount, p_fee_amount,
    p_to_account_id, p_settlement_date, p_reference, p_note);
end $$;

-- Jurnal manual (null = menunggu persetujuan)
create or replace function fin_post_manual_journal(p_date date, p_description text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_total numeric;
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.manual_journal')) then raise exception 'Tidak punya izin'; end if;
  select coalesce(sum(round(coalesce((l->>'debit')::numeric, 0), 2)), 0) into v_total from jsonb_array_elements(p_lines) l;
  if sys_approval_required('manual_journal', v_total) then
    perform sys_request_approval('manual_journal', null, null, v_total, coalesce(nullif(trim(p_description), ''), 'Jurnal manual'),
      jsonb_build_object('date', coalesce(p_date, current_date), 'description', p_description, 'lines', p_lines));
    return null;
  end if;
  return fin_post_manual_journal_execute(p_date, p_description, p_lines);
end $$;

-- ---------------------------------------------------------------------
-- TRANSFER GUDANG (kirim / kirim & terima)
-- ---------------------------------------------------------------------
alter function inv_ship_stock_transfer(uuid) rename to inv_ship_stock_transfer_execute;
alter function inv_post_stock_transfer(uuid) rename to inv_post_stock_transfer_execute;

-- true = transfer ditahan untuk approval (status pending_approval + permintaan dibuat)
create or replace function inv_transfer_hold_for_approval(p_id uuid, p_mode text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  t       inv_stock_transfers%rowtype;
  v_value numeric;
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_transfer')) then raise exception 'Tidak punya izin'; end if;
  select * into t from inv_stock_transfers where id = p_id and company_id = sys_current_company_id() for update;
  if not found or t.status not in ('draft', 'pending_approval') then raise exception 'Transfer tidak ditemukan / sudah dikirim'; end if;

  select coalesce(sum(i.quantity * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
  from inv_stock_transfer_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = t.from_warehouse_id and s.item_id = i.item_id
  where i.stock_transfer_id = p_id;

  if sys_approval_required('stock_transfer', v_value) then
    if t.status = 'pending_approval' then raise exception 'Transfer ini masih menunggu persetujuan'; end if;
    update inv_stock_transfers set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_transfer', p_id, (select outlet_id from inv_warehouses where id = t.from_warehouse_id), v_value,
      'Transfer ' || (select name from inv_warehouses where id = t.from_warehouse_id) || ' → ' || (select name from inv_warehouses where id = t.to_warehouse_id),
      jsonb_build_object('mode', p_mode));
    return true;
  end if;

  if t.status = 'pending_approval' then
    update inv_stock_transfers set status = 'draft' where id = p_id;
    perform sys_close_approval('stock_transfer', p_id);
  end if;
  return false;
end $$;

create or replace function inv_ship_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if inv_transfer_hold_for_approval(p_id, 'ship') then return; end if;
  perform inv_ship_stock_transfer_execute(p_id);
end $$;

create or replace function inv_post_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if inv_transfer_hold_for_approval(p_id, 'post') then return; end if;
  perform inv_post_stock_transfer_execute(p_id);
end $$;

-- ---------------------------------------------------------------------
-- KEPUTUSAN APPROVAL
-- ---------------------------------------------------------------------
create or replace function sys_revert_pending_document(p_document_type text, p_document_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('erp.approval_decision', 'on', true);
  if p_document_type = 'purchase_order' then
    update pur_purchase_orders set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_adjustment' then
    update inv_stock_adjustments set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_opname' then
    update inv_stock_opnames set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'product' then
    update inv_items set approval_status = 'rejected' where id = p_document_id and approval_status = 'pending';
  elsif p_document_type = 'pricelist' then
    update pur_pricelists set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'sales_order' then
    update sal_sales_orders set status = case when customer_type = 'internal' then 'new' else 'draft' end
    where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_transfer' then
    update inv_stock_transfers set status = 'draft' where id = p_document_id and status = 'pending_approval';
  end if;
  perform set_config('erp.approval_decision', 'off', true);
end $$;

create or replace function sys_decide_approval(p_request_id uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        sys_approval_requests%rowtype;
  v_result jsonb;
  v_dates  date[];
begin
  select * into v from sys_approval_requests
  where id = p_request_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Permintaan tidak ditemukan'; end if;
  if v.status <> 'pending' then raise exception 'Permintaan sudah diputuskan'; end if;
  if not sys_has_permission('approval.' || v.document_type) then raise exception 'Anda tidak berwenang menyetujui ini'; end if;
  if v.requested_by = auth.uid() and not sys_has_permission('*') then
    raise exception 'Tidak bisa menyetujui permintaan sendiri';
  end if;

  if p_approve then
    if v.document_type = 'purchase_order' then
      v_result := pur_approve_purchase_order(v.document_id);
    elsif v.document_type = 'expense' then
      v_result := jsonb_build_object('journal_id', fin_record_expense(
        (v.payload->>'date')::date, (v.payload->>'expense_account_id')::uuid, (v.payload->>'paid_from_account_id')::uuid,
        (v.payload->>'amount')::numeric, v.payload->>'description', nullif(v.payload->>'outlet_id', '')::uuid));
    elsif v.document_type = 'stock_adjustment' then
      perform inv_post_stock_adjustment(v.document_id);
    elsif v.document_type = 'stock_opname' then
      perform inv_post_stock_opname(v.document_id);
    elsif v.document_type = 'refund' then
      v_result := pos_refund_order_execute(v.document_id, v.payload->>'reason',
                                           coalesce((v.payload->>'return_stock')::boolean, false), v.requested_by);
    elsif v.document_type = 'product' then
      perform set_config('erp.approval_decision', 'on', true);
      update inv_items set approval_status = 'approved' where id = v.document_id and approval_status = 'pending';
      perform set_config('erp.approval_decision', 'off', true);
    elsif v.document_type = 'pricelist' then
      v_result := pur_approve_pricelist(v.document_id);

    -- jenis baru: dijalankan dengan hak modul pembuat
    elsif v.document_type = 'sales_order' then
      v_result := sal_confirm_sales_order(v.document_id);
    elsif v.document_type = 'credit_note' then
      perform sys_act_for('sales.manage');
      v_result := sal_create_credit_note_execute(v.document_id, (v.payload->>'amount')::numeric, v.payload->>'reason', v.payload->>'note');
    elsif v.document_type = 'sales_payment' then
      perform sys_act_for('sales.manage');
      v_result := sal_record_payment_execute(v.payload->'allocations', (v.payload->>'to_account_id')::uuid,
        nullif(v.payload->>'from_account_id', '')::uuid, (v.payload->>'payment_date')::date, v.payload->>'reference', v.payload->>'note');
    elsif v.document_type = 'supplier_payment' then
      perform sys_act_for('finance.manage');
      v_result := fin_pay_supplier_execute((v.payload->>'supplier_id')::uuid, (v.payload->>'account_id')::uuid,
        (v.payload->>'payment_date')::date, v.payload->'allocations', v.payload->>'reference');
    elsif v.document_type = 'pos_settlement' then
      perform sys_act_for('finance.manage');
      select array_agg(d::date) into v_dates from jsonb_array_elements_text(v.payload->'dates') d;
      v_result := pos_create_settlement_execute((v.payload->>'outlet_id')::uuid, (v.payload->>'payment_method_id')::uuid, v_dates,
        (v.payload->>'received_amount')::numeric, (v.payload->>'fee_amount')::numeric, nullif(v.payload->>'to_account_id', '')::uuid,
        (v.payload->>'settlement_date')::date, v.payload->>'reference', v.payload->>'note');
    elsif v.document_type = 'manual_journal' then
      perform sys_act_for('finance.manage');
      v_result := jsonb_build_object('journal_id', fin_post_manual_journal_execute((v.payload->>'date')::date, v.payload->>'description', v.payload->'lines'));
    elsif v.document_type = 'stock_transfer' then
      perform sys_act_for('inventory.manage');
      if v.payload->>'mode' = 'post' then perform inv_post_stock_transfer(v.document_id);
      else perform inv_ship_stock_transfer(v.document_id); end if;
    end if;
    perform sys_act_for('');
  else
    perform sys_revert_pending_document(v.document_type, v.document_id);
  end if;

  update sys_approval_requests set
    status        = case when p_approve then 'approved' else 'rejected' end,
    decided_by    = auth.uid(),
    decided_at    = now(),
    decision_note = nullif(trim(p_note), ''),
    result        = v_result
  where id = p_request_id
  returning * into v;
  return to_jsonb(v);
end $$;

revoke execute on function sys_act_for(text)                                                     from public, anon, authenticated;
revoke execute on function inv_transfer_hold_for_approval(uuid, text)                            from public, anon, authenticated;
revoke execute on function sal_create_credit_note_execute(uuid, numeric, text, text)             from public, anon, authenticated;
revoke execute on function sal_record_payment_execute(jsonb, uuid, uuid, date, text, text)       from public, anon, authenticated;
revoke execute on function fin_pay_supplier_execute(uuid, uuid, date, jsonb, text)               from public, anon, authenticated;
revoke execute on function pos_create_settlement_execute(uuid, uuid, date[], numeric, numeric, uuid, date, text, text)
                                                                                                 from public, anon, authenticated;
revoke execute on function fin_post_manual_journal_execute(date, text, jsonb)                    from public, anon, authenticated;
revoke execute on function inv_ship_stock_transfer_execute(uuid)                                 from public, anon, authenticated;
revoke execute on function inv_post_stock_transfer_execute(uuid)                                 from public, anon, authenticated;

-- >>>>>>>>>> migrations/023_staff_users.sql
-- =====================================================================
-- SANTAP ERP - 023: USER STAF DIBUAT OWNER (TANPA DAFTAR SENDIRI)
--   * Owner daftar sendiri dengan email (seperti biasa)
--   * Staf dibuat owner/admin di Pengaturan -> User: nama, USERNAME, password, role, outlet
--   * Akun login staf dibuat Edge Function "staff-users" (auth admin API) dengan
--     email sintetis <username>@staff.santap.local -> staf login cukup pakai username
--   * Fungsi di bawah dipanggil Edge Function: prepare/check (sebagai user yang login),
--     register (service role)
-- =====================================================================

alter table sys_users add column username   text;
alter table sys_users add column created_by uuid references sys_users(id);
alter table sys_users add constraint sys_users_username_check check (username is null or username ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
create unique index uq_sys_users_username on sys_users(lower(username)) where username is not null;

create or replace function sys_staff_email(p_username text)
returns text language sql immutable as $$
  select lower(trim(p_username)) || '@staff.santap.local'
$$;

-- Validasi sebelum akun login dibuat (dipanggil dengan JWT pengelola user)
create or replace function sys_prepare_staff_user(p_username text, p_full_name text, p_role_id uuid, p_outlet_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_username text := lower(trim(coalesce(p_username, '')));
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then
    raise exception 'Username 3-32 karakter: huruf kecil, angka, titik, minus atau garis bawah (tanpa spasi)';
  end if;
  if exists (select 1 from sys_users where lower(username) = v_username)
     or exists (select 1 from auth.users where lower(email) = sys_staff_email(v_username)) then
    raise exception 'Username "%" sudah dipakai', v_username;
  end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then raise exception 'Role tidak valid'; end if;
  if (select permissions ? '*' from sys_roles where id = p_role_id) then
    raise exception 'Role Owner tidak bisa diberikan ke user staf (owner mendaftar sendiri dengan email)';
  end if;
  if coalesce(array_length(p_outlet_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 outlet'; end if;

  return jsonb_build_object('company_id', v_company, 'username', v_username, 'email', sys_staff_email(v_username), 'caller_id', auth.uid());
end $$;

-- Simpan user staf setelah akun login dibuat (hanya service role / Edge Function)
create or replace function sys_register_staff_user(
  p_user_id uuid, p_company_id uuid, p_username text, p_full_name text, p_role_id uuid, p_outlet_ids uuid[], p_created_by uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = p_company_id and not permissions ? '*') then
    raise exception 'Role tidak valid';
  end if;
  insert into sys_users (id, company_id, role_id, full_name, username, created_by)
  values (p_user_id, p_company_id, p_role_id, trim(p_full_name), lower(trim(p_username)), p_created_by);
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o where o.company_id = p_company_id and o.id = any(p_outlet_ids);
  perform sys_log_activity(p_company_id, 'create_user', 'sys_users', p_user_id, trim(p_full_name) || ' (' || lower(trim(p_username)) || ')', null);
end $$;

-- Boleh reset password user ini? (dipanggil dengan JWT pengelola user)
create or replace function sys_check_staff_reset(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u sys_users%rowtype;
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  select * into u from sys_users where id = p_user_id and company_id = sys_current_company_id();
  if not found then raise exception 'User tidak ditemukan'; end if;
  if u.username is null then raise exception 'User ini login dengan email: reset password lewat menu "Lupa password" / profil masing-masing'; end if;
  return jsonb_build_object('user_id', u.id, 'username', u.username);
end $$;

-- Daftar user: tampilkan username staf, sembunyikan email sintetis
create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'username', u.username,
           'email', case when u.username is null then au.email end, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

revoke execute on function sys_register_staff_user(uuid, uuid, text, text, uuid, uuid[], uuid) from public, anon, authenticated;
grant execute on function sys_register_staff_user(uuid, uuid, text, text, uuid, uuid[], uuid) to service_role;

-- >>>>>>>>>> migrations/024_data_tools.sql
-- =====================================================================
-- SANTAP ERP - 024: ALAT DATA (KHUSUS OWNER)
--   * Data contoh transaksi: pembelian, penjualan POS harian, waste, biaya, SO B2B, settlement
--   * Reset data: hapus transaksi saja, atau reset total (master + transaksi)
--   * Backup (export JSON) & restore (import JSON) data perusahaan
--   Perusahaan, outlet, user, role, COA, gudang, metode bayar & pengaturan TIDAK pernah dihapus.
-- =====================================================================

-- ---------------------------------------------------------------------
-- KLASIFIKASI TABEL
-- ---------------------------------------------------------------------
-- tabel inti: tidak pernah dihapus (restore = timpa / upsert)
create or replace function sys_data_core_tables()
returns text[] language sql immutable as $$
  select array['sys_brands', 'sys_outlets', 'sys_roles', 'sys_users', 'sys_user_invitations', 'sys_approval_rules',
               'sys_payment_gateways', 'sys_payment_gateway_secrets', 'fin_accounts', 'mst_payment_methods', 'inv_warehouses',
               'inv_units', 'inv_adjustment_purposes', 'crm_settings', 'crm_membership_tiers']
$$;

-- master data: ikut terhapus hanya pada reset total
create or replace function sys_data_master_tables()
returns text[] language sql immutable as $$
  select array['mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
               'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_price_schedules', 'mst_price_schedule_items',
               'inv_item_categories', 'inv_item_sub_categories', 'inv_item_custom_fields', 'inv_items', 'inv_item_units',
               'inv_item_stock_levels', 'inv_recipes', 'inv_recipe_items', 'inv_recipe_costs', 'inv_recipe_access',
               'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items', 'crm_customers', 'crm_promotions',
               'sal_customers', 'sal_pricelists', 'sal_pricelist_items']
$$;

-- semua tabel perusahaan (punya kolom company_id)
create or replace function sys_data_company_tables()
returns text[] language sql stable as $$
  select coalesce(array_agg(c.table_name::text order by c.table_name), '{}')
  from information_schema.columns c
  join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
  where c.table_schema = 'public' and c.column_name = 'company_id'
$$;

-- p_scope: 'transactions' = transaksi saja, 'all' = transaksi + master
create or replace function sys_data_wipe_tables(p_scope text)
returns text[] language sql stable as $$
  select coalesce(array_agg(t), '{}') from unnest(sys_data_company_tables()) t
  where t <> all(sys_data_core_tables())
    and (p_scope = 'all' or t <> all(sys_data_master_tables()))
$$;

-- kolom foreign key antar tabel public
create or replace function sys_data_fk_columns()
returns table (child text, col text, parent text, nullable boolean) language sql stable as $$
  select c.conrelid::regclass::text, a.attname::text, c.confrelid::regclass::text, not a.attnotnull
  from pg_constraint c
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
  where c.contype = 'f' and c.connamespace = 'public'::regnamespace
$$;

-- kolom FK (boleh null) yang membentuk siklus di antara tabel-tabel p_tables
create or replace function sys_data_cycle_columns(p_tables text[])
returns table (child text, col text) language sql stable as $$
  select f.child, f.col from sys_data_fk_columns() f
  where f.child = any(p_tables) and f.parent = any(p_tables) and f.nullable and f.child <> f.parent
    and exists (
      with recursive reach(t) as (
        select f.parent
        union
        select g.parent from sys_data_fk_columns() g join reach on g.child = reach.t
        where g.parent = any(p_tables) and g.child <> g.parent)
      select 1 from reach where reach.t = f.child)
$$;

create or replace function sys_data_set_triggers(p_tables text[], p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t text;
begin
  foreach t in array p_tables loop
    execute format('alter table %I %s trigger user', t, case when p_enabled then 'enable' else 'disable' end);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- HAPUS DATA PERUSAHAAN (internal). Urutan hapus dicari otomatis (anak dulu),
-- siklus FK diputus dengan mengosongkan kolom FK yang boleh null.
-- ---------------------------------------------------------------------
create or replace function sys_data_wipe(p_company_id uuid, p_scope text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tables   text[] := sys_data_wipe_tables(p_scope);
  v_left     text[];
  v_counts   jsonb := '{}';
  v_progress boolean;
  v_n        bigint;
  t          text;
  r          record;
begin
  if p_scope not in ('transactions', 'all') then raise exception 'Jenis reset tidak dikenal'; end if;
  perform sys_data_set_triggers(v_tables, false);
  v_left := v_tables;
  for pass in 1..60 loop
    exit when cardinality(v_left) = 0;
    v_progress := false;
    foreach t in array v_left loop
      begin
        execute format('delete from %I where company_id = $1%s', t,
          case when t = 'pur_suppliers' then ' and supplier_type = ''external''' else '' end) using p_company_id;
        get diagnostics v_n = row_count;
        v_counts := v_counts || jsonb_build_object(t, v_n);
        v_left := array_remove(v_left, t);
        v_progress := true;
      exception when foreign_key_violation then null;
      end;
    end loop;
    if not v_progress then
      for r in select * from sys_data_cycle_columns(v_left) loop
        execute format('update %I set %I = null where company_id = $1 and %I is not null', r.child, r.col, r.col) using p_company_id;
      end loop;
    end if;
  end loop;
  if cardinality(v_left) > 0 then raise exception 'Data tidak bisa dihapus (masih dipakai): %', array_to_string(v_left, ', '); end if;
  set constraints all immediate;   -- cek FK tertunda dulu sebelum trigger diaktifkan lagi
  perform sys_data_set_triggers(v_tables, true);

  if p_scope = 'transactions' then
    -- master tetap, angka turunan dari transaksi dikembalikan ke nol
    update crm_customers set points_balance = 0, total_spent = 0, visit_count = 0 where company_id = p_company_id;
    update crm_promotions set usage_count = 0 where company_id = p_company_id;
  end if;
  return v_counts;
end $$;

-- Reset (owner): ketik nama perusahaan sebagai konfirmasi
create or replace function sys_reset_company_data(p_scope text, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_name    text;
  v_counts  jsonb;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa mereset data'; end if;
  select name into v_name from sys_companies where id = v_company;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(trim(v_name)) then raise exception 'Ketik nama perusahaan "%" untuk konfirmasi', v_name; end if;
  v_counts := sys_data_wipe(v_company, p_scope);
  perform sys_log_activity(v_company, 'reset_data', 'sys_companies', v_company,
    case when p_scope = 'all' then 'Reset total (master & transaksi)' else 'Hapus semua transaksi' end, null);
  return jsonb_build_object('scope', p_scope, 'deleted', v_counts);
end $$;

-- ---------------------------------------------------------------------
-- BACKUP (export) - semua data perusahaan sebagai JSON
-- ---------------------------------------------------------------------
create or replace function sys_export_company_data()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_tables  jsonb := '{}';
  v_rows    jsonb;
  t         text;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa membuat backup'; end if;
  foreach t in array sys_data_company_tables() loop
    continue when t = 'sys_payment_gateway_secrets';      -- rahasia tidak ikut di-backup
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from %I x where company_id = $1', t) into v_rows using v_company;
    v_tables := v_tables || jsonb_build_object(t, v_rows);
  end loop;
  v_tables := v_tables || jsonb_build_object('sys_user_outlets',
    (select coalesce(jsonb_agg(to_jsonb(uo)), '[]') from sys_user_outlets uo join sys_users u on u.id = uo.user_id where u.company_id = v_company));

  perform sys_log_activity(v_company, 'export_data', 'sys_companies', v_company, 'Backup data', null);
  return jsonb_build_object('format', 'santap-backup', 'version', 1, 'company_id', v_company,
    'company_name', (select name from sys_companies where id = v_company), 'exported_at', now(),
    'exported_by', (select full_name from sys_users where id = auth.uid()), 'tables', v_tables);
end $$;

-- ---------------------------------------------------------------------
-- RESTORE (import) - kembalikan data perusahaan dari file backup
--   Master & transaksi diganti isi backup; data inti di-upsert; user tidak diubah.
-- ---------------------------------------------------------------------
create or replace function sys_data_insert_sql(p_table text, p_rows jsonb, p_null_cols text[], p_upsert boolean)
returns text language plpgsql stable set search_path = public as $$
declare
  v_keys  text[] := (select coalesce(array_agg(k), '{}') from jsonb_object_keys(coalesce(p_rows->0, '{}')) k);
  v_cols  text;
  v_exprs text;
  v_pk    text;
  v_set   text;
  v_upd   text;
  v_pkarr text[];
begin
  -- kolom yang tidak ada di backup (versi lama) memakai nilai default kolom
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg(case when c.column_name = any(p_null_cols) then 'null'
                         when c.column_name = any(v_keys) then 'r.' || quote_ident(c.column_name)
                         else coalesce(c.column_default, 'null') end, ', ' order by c.ordinal_position),
         null
    into v_cols, v_exprs, v_set
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.is_generated = 'NEVER';

  select string_agg(quote_ident(a.attname), ', '), array_agg(a.attname::text) into v_pk, v_pkarr
  from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
  where i.indrelid = p_table::regclass and i.indisprimary;

  -- upsert: kolom biasa saja (tanpa primary key & identity)
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg('excluded.' || quote_ident(c.column_name), ', ' order by c.ordinal_position)
    into v_upd, v_set
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.is_generated = 'NEVER' and c.is_identity = 'NO'
    and c.column_name <> all(coalesce(v_pkarr, '{}'));

  return format('insert into %I (%s) overriding system value select %s from jsonb_populate_recordset(null::%I, $1) r%s',
    p_table, v_cols, v_exprs, p_table,
    case when not p_upsert or v_pk is null then ''
         when v_upd is null then format(' on conflict (%s) do nothing', v_pk)
         else format(' on conflict (%s) do update set (%s) = row(%s)', v_pk, v_upd, v_set) end);
end $$;

create or replace function sys_import_company_data(p_backup jsonb, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_name     text;
  v_skip     text[] := array['sys_users', 'sys_user_outlets', 'sys_user_invitations', 'sys_payment_gateway_secrets'];
  v_tables   text[];
  v_left     text[];
  v_nulls    jsonb := '{}';      -- tabel -> kolom FK yang diisi belakangan (pemutus siklus)
  v_counts   jsonb := '{}';
  v_progress boolean;
  v_rows     jsonb;
  v_n        bigint;
  v_cols     text[];
  v_pk       text;
  t          text;
  r          record;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa restore data'; end if;
  select name into v_name from sys_companies where id = v_company;
  if p_backup->>'format' <> 'santap-backup' then raise exception 'File bukan backup Santap ERP'; end if;
  if (p_backup->>'company_id')::uuid is distinct from v_company then
    raise exception 'Backup ini milik perusahaan lain (%). Restore hanya untuk perusahaan yang sama.', p_backup->>'company_name';
  end if;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(trim(v_name)) then raise exception 'Ketik nama perusahaan "%" untuk konfirmasi', v_name; end if;

  perform sys_data_wipe(v_company, 'all');

  select coalesce(array_agg(k), '{}') into v_tables
  from jsonb_object_keys(p_backup->'tables') k
  where k = any(sys_data_company_tables()) and k <> all(v_skip);
  perform sys_data_set_triggers(v_tables, false);

  v_left := v_tables;
  for pass in 1..80 loop
    exit when cardinality(v_left) = 0;
    v_progress := false;
    foreach t in array v_left loop
      -- hanya baris milik perusahaan ini
      select coalesce(jsonb_agg(x), '[]') into v_rows from jsonb_array_elements(p_backup->'tables'->t) x
      where x->>'company_id' = v_company::text;
      begin
        if jsonb_array_length(v_rows) > 0 then
          execute sys_data_insert_sql(t, v_rows,
            coalesce((select array_agg(c) from jsonb_array_elements_text(v_nulls->t) c), '{}'), true)
            using v_rows;
        end if;
        v_counts := v_counts || jsonb_build_object(t, jsonb_array_length(v_rows));
        v_left := array_remove(v_left, t);
        v_progress := true;
      exception when foreign_key_violation then null;
      end;
    end loop;
    if not v_progress then
      -- siklus: isi kolom FK yang boleh null belakangan
      v_n := 0;
      for r in select * from sys_data_cycle_columns(v_left) loop
        if not coalesce(v_nulls->r.child, '[]') ? r.col then
          v_nulls := jsonb_set(v_nulls, array[r.child], coalesce(v_nulls->r.child, '[]') || to_jsonb(r.col));
          v_n := v_n + 1;
        end if;
      end loop;
      exit when v_n = 0;
    end if;
  end loop;
  if cardinality(v_left) > 0 then raise exception 'Restore gagal, tabel bermasalah: %', array_to_string(v_left, ', '); end if;

  -- isi kolom yang tadi dikosongkan
  for t in select jsonb_object_keys(v_nulls) loop
    select array_agg(c) into v_cols from jsonb_array_elements_text(v_nulls->t) c;
    select string_agg(format('x.%1$I = r.%1$I', a.attname), ' and ') into v_pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    where i.indrelid = t::regclass and i.indisprimary;
    execute format('update %I x set %s from jsonb_populate_recordset(null::%I, $1) r where %s',
      t, (select string_agg(format('%1$I = r.%1$I', c), ', ') from unnest(v_cols) c), t, v_pk)
      using (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(p_backup->'tables'->t) x where x->>'company_id' = v_company::text);
  end loop;

  -- kolom identity (mis. urutan alokasi batch) dilanjutkan dari nilai terbesar
  for r in select c.table_name, c.column_name from information_schema.columns c
           where c.table_schema = 'public' and c.is_identity = 'YES' and c.table_name = any(v_tables) loop
    execute format('select setval(pg_get_serial_sequence(%L, %L), greatest(coalesce((select max(%I) from %I), 0), 1))',
      r.table_name, r.column_name, r.column_name, r.table_name);
  end loop;

  set constraints all immediate;   -- cek FK tertunda dulu sebelum trigger diaktifkan lagi
  perform sys_data_set_triggers(v_tables, true);
  perform sys_log_activity(v_company, 'import_data', 'sys_companies', v_company,
    'Restore backup ' || coalesce(to_char((p_backup->>'exported_at')::timestamptz, 'DD Mon YYYY HH24:MI'), ''), null);
  return jsonb_build_object('restored', v_counts);
end $$;

-- =====================================================================
-- DATA CONTOH TRANSAKSI (dipanggil per hari dari aplikasi supaya tidak timeout)
-- =====================================================================
create or replace function sys_seed_demo_check(p_outlet_id uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_wh uuid;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa membuat data contoh'; end if;
  select default_warehouse_id into v_wh from sys_outlets where id = p_outlet_id and company_id = sys_current_company_id();
  if v_wh is null then raise exception 'Outlet tidak ditemukan / belum punya gudang POS'; end if;
  return v_wh;
end $$;

-- menu yang bisa dijual tanpa pilihan wajib
create or replace function sys_seed_demo_menus()
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(mi.id), '{}') from mst_menu_items mi
  where mi.company_id = sys_current_company_id() and mi.is_active and mi.base_price > 0
    and not exists (select 1 from mst_menu_item_modifier_groups mg join mst_modifier_groups g on g.id = mg.modifier_group_id
                    where mg.menu_item_id = mi.id and g.min_select > 0)
$$;

create or replace function sys_seed_demo_prepare(p_outlet_id uuid, p_start_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_wh      uuid := sys_seed_demo_check(p_outlet_id);
  v_shift   uuid;
  v_opened  boolean := false;
begin
  if cardinality(sys_seed_demo_menus()) = 0 then raise exception 'Belum ada menu aktif berharga. Isi master menu & resep dulu.'; end if;

  if not exists (select 1 from pur_suppliers where company_id = v_company and supplier_type = 'external' and is_active) then
    insert into pur_suppliers (company_id, code, name, payment_term_days) values (v_company, 'DEMO-SUP', 'CV Demo Pangan Segar', 14);
  end if;
  insert into sal_customers (company_id, code, name, contact_name, phone, address, payment_term_days, credit_limit)
  values (v_company, 'DEMO-B2B', 'PT Demo Katering Sejahtera', 'Ibu Rina', '0812000000', 'Jl. Contoh No. 1', 14, 0)
  on conflict (company_id, code) do nothing;

  -- tanggal contoh di masa lalu ikut di-settle
  update mst_payment_methods set settlement_from = least(settlement_from, p_start_date) where company_id = v_company;

  select id into v_shift from pos_shifts where outlet_id = p_outlet_id and user_id = auth.uid() and status = 'open' limit 1;
  if v_shift is null then
    v_shift := (pos_open_shift(p_outlet_id, 500000)->>'id')::uuid;
    v_opened := true;
  end if;
  return jsonb_build_object('shift_id', v_shift, 'shift_opened', v_opened, 'warehouse_id', v_wh);
end $$;

create or replace function sys_seed_demo_day(p_outlet_id uuid, p_date date, p_orders int default 20, p_purchase boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_wh       uuid := sys_seed_demo_check(p_outlet_id);
  v_menus    uuid[] := sys_seed_demo_menus();
  v_methods  uuid[];
  v_supplier uuid;
  v_po       uuid;
  v_gr       uuid;
  v_order    jsonb;
  v_items    jsonb;
  v_ts       timestamptz;
  v_doc      uuid;
  v_orders   int := 0;
  v_failed   int := 0;
  v_n        int;
  r          record;
begin
  if p_date > current_date then raise exception 'Tanggal tidak boleh di masa depan'; end if;

  -- 1) PEMBELIAN: stok bahan resep untuk ~4 hari
  if p_purchase then
    select id into v_supplier from pur_suppliers where company_id = v_company and supplier_type = 'external' and is_active order by code limit 1;
    insert into pur_purchase_orders (company_id, supplier_id, warehouse_id, po_date, expected_date, note)
    values (v_company, v_supplier, v_wh, p_date, p_date, 'Data contoh') returning id into v_po;
    insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
    select v_company, v_po, x.item_id, it.base_unit_id, 1, x.qty, x.price, round(x.qty * x.price, 2)
    from (
      select ri.item_id,
             ceil(sum(ri.quantity / r2.yield_qty) / cardinality(v_menus) * 2.5 * greatest(p_orders, 1) * 4 * (1.1 + random() * 0.4)::numeric) as qty,
             round(greatest(max(it2.last_purchase_cost), 1) * (0.95 + random() * 0.15)::numeric, 2) as price
      from inv_recipe_items ri
      join inv_recipes r2 on r2.id = ri.recipe_id
      join inv_items it2 on it2.id = ri.item_id
      where r2.menu_item_id = any(v_menus) and it2.is_purchasable and it2.is_active and it2.approval_status = 'approved'
      group by ri.item_id
    ) x join inv_items it on it.id = x.item_id
    where x.qty > 0;
    if exists (select 1 from pur_purchase_order_items where purchase_order_id = v_po) then
      perform pur_approve_purchase_order(v_po);
      v_gr := pur_create_goods_receipt_from_po(v_po);
      update pur_goods_receipt_items gi set expiry_date = p_date + 30, lot_number = 'DEMO-' || to_char(p_date, 'MMDD')
      from inv_items it where gi.goods_receipt_id = v_gr and it.id = gi.item_id and it.track_batch and it.shelf_life_days is null;
      update pur_goods_receipts set receipt_date = p_date, supplier_invoice_number = 'INV-DEMO-' || to_char(p_date, 'YYMMDD') where id = v_gr;
      perform pur_post_goods_receipt(v_gr);
      v_ts := p_date + time '08:00';
      update pur_purchase_orders set approved_at = v_ts, created_at = v_ts where id = v_po;
      update pur_goods_receipts set posted_at = v_ts, created_at = v_ts where id = v_gr;
      update inv_stock_movements set movement_at = v_ts where reference_id = v_gr;
      update inv_stock_batches set received_at = v_ts where reference_id = v_gr;
      update fin_journals set journal_date = p_date where source_id = v_gr;
    else
      delete from pur_purchase_orders where id = v_po;
    end if;
  end if;

  -- 2) PENJUALAN POS
  select array_agg(id order by sort_order) into v_methods from mst_payment_methods
  where company_id = v_company and is_active and code in ('cash', 'qris', 'debit');
  for i in 1..greatest(p_orders, 0) loop
    begin
      select jsonb_agg(jsonb_build_object('menu_item_id', v_menus[1 + floor(random() * cardinality(v_menus))::int],
                                          'quantity', case when random() < 0.25 then 2 else 1 end))
        into v_items from generate_series(1, 1 + floor(random() * 3)::int);
      v_order := pos_save_order(jsonb_build_object('outlet_id', p_outlet_id,
        'sales_channel', (array['dine_in', 'dine_in', 'takeaway', 'gofood'])[1 + floor(random() * 4)::int],
        'guest_count', 1 + floor(random() * 3)::int, 'items', v_items));
      perform pos_pay_order((v_order->>'id')::uuid, jsonb_build_array(jsonb_build_object(
        'payment_method_id', v_methods[1 + floor(random() * cardinality(v_methods))::int],
        'amount', (select grand_total from pos_orders where id = (v_order->>'id')::uuid))));
      v_ts := p_date + time '10:00' + (random() * interval '11 hours');
      update pos_orders set business_date = p_date, created_at = v_ts, paid_at = v_ts + interval '25 minutes' where id = (v_order->>'id')::uuid;
      update pos_payments set created_at = v_ts + interval '25 minutes' where order_id = (v_order->>'id')::uuid;
      update fin_journals set journal_date = p_date where source_id = (v_order->>'id')::uuid;
      update inv_stock_movements set movement_at = v_ts + interval '25 minutes' where reference_id = (v_order->>'id')::uuid;
      v_orders := v_orders + 1;
    exception when others then
      v_failed := v_failed + 1;
    end;
  end loop;

  -- 3) WASTE tiap Senin, PEMAKAIAN tiap Jumat (2 bahan acak, qty kecil)
  if extract(isodow from p_date) in (1, 5) then
    insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type, adjustment_date, purpose_id, note)
    values (v_company, v_wh, case when extract(isodow from p_date) = 1 then 'waste' else 'usage' end, p_date,
      (select id from inv_adjustment_purposes where company_id = v_company
         and adjustment_type = case when extract(isodow from p_date) = 1 then 'waste' else 'usage' end order by sort_order limit 1),
      'Data contoh') returning id into v_doc;
    insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity)
    select v_company, v_doc, s.item_id, greatest(round(s.quantity * (0.01 + random() * 0.02)::numeric), 1)
    from inv_stocks s where s.warehouse_id = v_wh and s.quantity > 10 order by random() limit 2;
    if exists (select 1 from inv_stock_adjustment_items where stock_adjustment_id = v_doc) then
      perform inv_post_stock_adjustment(v_doc);
      update inv_stock_movements set movement_at = p_date + time '22:00' where reference_id = v_doc;
      update fin_journals set journal_date = p_date where source_id = v_doc;
    else
      delete from inv_stock_adjustments where id = v_doc;
    end if;
  end if;

  -- 4) BIAYA: listrik tiap Senin, sewa tiap tanggal 1
  if exists (select 1 from fin_accounts where company_id = v_company and code = '6-1300') then
    if extract(isodow from p_date) = 1 then
      perform fin_record_expense(p_date, (select id from fin_accounts where company_id = v_company and code = '6-1300'),
        fin_account_id(v_company, 'bank'), 750000 + round((random() * 250000)::numeric, -3), 'Listrik & air minggu ini (contoh)', p_outlet_id);
    end if;
    if extract(day from p_date) = 1 then
      perform fin_record_expense(p_date, (select id from fin_accounts where company_id = v_company and code = '6-1200'),
        fin_account_id(v_company, 'bank'), 15000000, 'Sewa tempat bulan ini (contoh)', p_outlet_id);
    end if;
  end if;

  return jsonb_build_object('date', p_date, 'orders', v_orders, 'failed', v_failed, 'purchase', v_gr is not null);
end $$;

create or replace function sys_seed_demo_finish(p_outlet_id uuid, p_shift_id uuid default null, p_close_shift boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_wh       uuid := sys_seed_demo_check(p_outlet_id);
  v_cust     uuid;
  v_pl       uuid;
  v_so       uuid;
  v_del      uuid;
  v_inv      jsonb;
  v_settled  int := 0;
  r          record;
begin
  -- 1) SALES ORDER B2B: 2 bahan dengan stok, kirim, invoice, bayar sebagian
  select id into v_cust from sal_customers where company_id = v_company and code = 'DEMO-B2B';
  if v_cust is not null and exists (select 1 from inv_stocks where warehouse_id = v_wh and quantity > 100) then
    insert into sal_pricelists (company_id, name, customer_id, valid_from) values (v_company, 'Harga Demo Katering', v_cust, current_date - 30)
    returning id into v_pl;
    insert into sal_pricelist_items (company_id, pricelist_id, item_id, unit_id, price)
    select v_company, v_pl, it.id, it.base_unit_id, round(greatest(it.last_purchase_cost, 1) * 1.4, 2)
    from inv_stocks s join inv_items it on it.id = s.item_id
    where s.warehouse_id = v_wh and s.quantity > 100 order by s.quantity desc limit 2;

    insert into sal_sales_orders (company_id, outlet_id, warehouse_id, customer_type, customer_id, so_date, tax_pct, shipping_address, note)
    values (v_company, p_outlet_id, v_wh, 'external', v_cust, current_date - 3, 11, 'Jl. Contoh No. 1', 'Data contoh') returning id into v_so;
    insert into sal_sales_order_items (company_id, sales_order_id, item_id, unit_id, quantity)
    select v_company, v_so, pi.item_id, pi.unit_id, least(round(s.quantity * 0.05), 5000)
    from sal_pricelist_items pi join inv_stocks s on s.item_id = pi.item_id and s.warehouse_id = v_wh where pi.pricelist_id = v_pl;
    perform sal_confirm_sales_order(v_so);
    v_del := sal_create_delivery(v_so, v_wh);
    perform sal_ship_delivery(v_del);
    v_inv := sal_create_invoice(v_so, current_date - 2, 'Data contoh');
    perform sal_record_payment(jsonb_build_array(jsonb_build_object('invoice_id', v_inv->>'id', 'amount', round((v_inv->>'grand_total')::numeric / 2))),
      fin_account_id(v_company, 'bank'), null, current_date - 1, 'TRF-DEMO');
  end if;

  -- 2) SETTLEMENT: semua metode, tanggal s/d 2 hari lalu (dana non tunai dipotong estimasi MDR)
  for r in
    select payment_method_id, payment_type, array_agg(business_date order by business_date) dates,
           sum(net_amount) net, sum(estimated_fee) fee, max(business_date) last_date
    from rpt_pos_settlement_days
    where outlet_id = p_outlet_id and settlement_id is null and needs_settlement and business_date <= current_date - 2 and net_amount > 0
    group by payment_method_id, payment_type
  loop
    perform pos_create_settlement(p_outlet_id, r.payment_method_id, r.dates,
      r.net - case when r.payment_type = 'cash' then 0 else r.fee end,
      case when r.payment_type = 'cash' then 0 else r.fee end, null, r.last_date + 1, 'DEMO', 'Data contoh');
    v_settled := v_settled + 1;
  end loop;

  if p_close_shift and p_shift_id is not null then
    perform pos_close_shift(p_shift_id, 0);
    update pos_shifts set closing_cash = expected_cash where id = p_shift_id;
  end if;
  return jsonb_build_object('sales_order', v_so is not null, 'settlements', v_settled);
end $$;

-- Satu perintah untuk SQL Editor: select sys_seed_demo_transactions('<outlet_id>', 14, 20);
create or replace function sys_seed_demo_transactions(p_outlet_id uuid, p_days int default 14, p_orders_per_day int default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prep  jsonb;
  v_total int := 0;
  v_day   jsonb;
begin
  if p_days not between 1 and 90 then raise exception 'Jumlah hari 1-90'; end if;
  v_prep := sys_seed_demo_prepare(p_outlet_id, current_date - p_days + 1);
  for d in reverse (p_days - 1)..0 loop
    v_day := sys_seed_demo_day(p_outlet_id, current_date - d, greatest(1, round(p_orders_per_day * (0.7 + random() * 0.6))::int),
                               (p_days - 1 - d) % 4 = 0);
    v_total := v_total + (v_day->>'orders')::int;
  end loop;
  return sys_seed_demo_finish(p_outlet_id, (v_prep->>'shift_id')::uuid, (v_prep->>'shift_opened')::boolean)
    || jsonb_build_object('orders', v_total, 'days', p_days);
end $$;

revoke execute on function sys_data_set_triggers(text[], boolean)          from public, anon, authenticated;
revoke execute on function sys_data_wipe(uuid, text)                       from public, anon, authenticated;
revoke execute on function sys_data_insert_sql(text, jsonb, text[], boolean) from public, anon, authenticated;
revoke execute on function sys_data_fk_columns()                           from public, anon, authenticated;
revoke execute on function sys_data_cycle_columns(text[])                  from public, anon, authenticated;
revoke execute on function sys_data_company_tables()                       from public, anon, authenticated;
revoke execute on function sys_data_wipe_tables(text)                      from public, anon, authenticated;
revoke execute on function sys_seed_demo_check(uuid)                       from public, anon, authenticated;
revoke execute on function sys_seed_demo_menus()                           from public, anon, authenticated;

-- >>>>>>>>>> migrations/025_simple_manufacturing.sql
-- =====================================================================
-- SANTAP ERP - 025: SIMPLE MANUFACTURING (ala ESB, actual costing)
--   * Lokasi asal (bahan diambil) & lokasi tujuan (hasil masuk) boleh berbeda,
--     mis. bahan dari Central Kitchen, hasil ke Warehouse
--   * Satuan produksi bisa satuan lain dari produk (mis. PACK isi 9 PCS)
--   * Baris bahan / hasil: Qty BOM, Total Qty By System, Total Qty aktual (bisa diubah)
--   * Assembly: hasil aktual (result qty) & tanggal kedaluwarsa bisa diisi
--   * Disassembly: qty hasil aktual & weight factor bisa diubah per transaksi
--   * Beberapa BOM dalam 1 dokumen: nomor SM/YYYYMMDD/0001 - 1, - 2, ...
--   * Approval jenis baru "production" (matriks Approval Transaksi)
--   HPP hasil = nilai bahan yang BENAR-BENAR terpakai (batch FIFO) + biaya tambahan BOM
-- =====================================================================

alter table inv_productions add column dest_warehouse_id uuid references inv_warehouses(id);   -- null = sama dengan asal
alter table inv_productions add column group_id          uuid;                                  -- dokumen berisi beberapa BOM
alter table inv_productions add column group_number      text;                                  -- nomor dasar dokumen
alter table inv_productions add column line_no           int not null default 1;
alter table inv_productions add column unit_id           uuid references inv_units(id);         -- satuan qty produksi
alter table inv_productions add column conversion_qty    numeric(15,4) not null default 1 check (conversion_qty > 0);
alter table inv_productions add column result_qty        numeric(15,4) check (result_qty is null or result_qty >= 0);  -- assembly: hasil aktual
alter table inv_productions add column expiry_date       date;                                  -- assembly: kedaluwarsa hasil
create index idx_inv_productions_group on inv_productions(group_id);

-- baris bahan (assembly) / hasil (disassembly)
create table inv_production_lines (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  production_id  uuid not null references inv_productions(id) on delete cascade,
  line_type      text not null check (line_type in ('material', 'result')),
  item_id        uuid not null references inv_items(id),
  bom_qty        numeric(15,4) not null default 0,     -- per 1 qty produksi (satuan dasar, termasuk waste)
  system_qty     numeric(15,4) not null default 0,     -- bom_qty x qty produksi
  actual_qty     numeric(15,4) not null default 0 check (actual_qty >= 0),
  weight_factor  numeric(10,4) check (weight_factor is null or weight_factor > 0),
  expiry_date    date,
  sort_order     int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_inv_production_lines_prod on inv_production_lines(production_id);

-- Isi baris dari BOM (dipakai bila dokumen belum punya baris)
create or replace function inv_prepare_production_lines(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  p inv_productions%rowtype;
  r inv_recipes%rowtype;
begin
  select * into p from inv_productions where id = p_id;
  select * into r from inv_recipes where id = p.recipe_id;
  p.conversion_qty := case when p.unit_id is null then 1 else coalesce(inv_unit_factor(r.item_id, p.unit_id), 1) end;
  update inv_productions set conversion_qty = p.conversion_qty where id = p_id;
  delete from inv_production_lines where production_id = p_id;
  insert into inv_production_lines (company_id, production_id, line_type, item_id, bom_qty, system_qty, actual_qty, weight_factor, sort_order)
  select p.company_id, p.id,
         case when r.recipe_type = 'assembly' then 'material' else 'result' end,
         ri.item_id, x.bom, round(x.bom * p.quantity, 4), round(x.bom * p.quantity, 4),
         case when r.recipe_type = 'disassembly' then coalesce(ri.weight_factor, 1) end,
         row_number() over (order by ri.created_at, ri.id)
  from inv_recipe_items ri
  cross join lateral (select ri.quantity / r.yield_qty * p.conversion_qty
                        * case when r.recipe_type = 'assembly' then 1 + ri.waste_pct / 100 else 1 end as bom) x
  where ri.recipe_id = r.id;
end $$;

create or replace function inv_prepare_production(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  if not exists (select 1 from inv_productions where id = p_id and company_id = sys_current_company_id() and status = 'draft') then
    raise exception 'Produksi tidak ditemukan / bukan draft';
  end if;
  perform inv_prepare_production_lines(p_id);
end $$;

-- ---------------------------------------------------------------------
-- POSTING
-- ---------------------------------------------------------------------
create or replace function inv_post_production(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p          inv_productions%rowtype;
  r          inv_recipes%rowtype;
  v_dest     uuid;
  v_base     numeric;
  v_factor   numeric;
  v_value    numeric;
  v_input    numeric;
  v_extra    numeric;
  v_result   numeric;
  v_total_wf numeric;
  v_inv_net  numeric;
  v_lines    jsonb;
  v_base_no  text;
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.production')) then raise exception 'Tidak punya izin'; end if;
  select * into p from inv_productions where id = p_id and company_id = sys_current_company_id() for update;
  if not found or p.status not in ('draft', 'pending_approval') then raise exception 'Produksi tidak ditemukan / sudah diposting'; end if;
  select * into r from inv_recipes where id = p.recipe_id;
  if r.recipe_type not in ('assembly', 'disassembly') then raise exception 'Resep harus bertipe Assembly / Disassembly'; end if;
  if not r.is_active then raise exception 'Resep tidak aktif'; end if;
  if not exists (select 1 from inv_recipe_items where recipe_id = r.id) then raise exception 'Resep belum punya bahan'; end if;

  -- konversi satuan selalu dari master produk (bukan dari klien)
  p.conversion_qty := case when p.unit_id is null then 1 else coalesce(inv_unit_factor(r.item_id, p.unit_id), 1) end;
  update inv_productions set conversion_qty = p.conversion_qty where id = p.id;
  if not exists (select 1 from inv_production_lines where production_id = p.id) then
    perform inv_prepare_production_lines(p.id);
  end if;
  v_dest := coalesce(p.dest_warehouse_id, p.warehouse_id);
  v_base := p.quantity * p.conversion_qty;

  -- nilai perkiraan untuk aturan approval
  if r.recipe_type = 'assembly' then
    select coalesce(sum(l.actual_qty * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
    from inv_production_lines l join inv_items it on it.id = l.item_id
    left join inv_stocks s on s.warehouse_id = p.warehouse_id and s.item_id = l.item_id
    where l.production_id = p.id and l.line_type = 'material';
  else
    select v_base * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost) into v_value
    from inv_items it left join inv_stocks s on s.warehouse_id = p.warehouse_id and s.item_id = it.id where it.id = r.item_id;
  end if;

  -- nomor dokumen: SM/YYYYMMDD/0001 - n (sama untuk 1 dokumen berisi beberapa BOM)
  if p.production_number is null then
    select group_number into v_base_no from inv_productions
    where group_id = p.group_id and group_number is not null and p.group_id is not null limit 1;
    if v_base_no is null then
      v_base_no := sys_next_document_number(p.company_id, 'SM', p.production_date);
      update inv_productions set group_number = v_base_no where id = p.id or (p.group_id is not null and group_id = p.group_id);
    end if;
    p.production_number := v_base_no || ' - ' || p.line_no;
    update inv_productions set production_number = p.production_number where id = p.id;
  end if;

  if sys_approval_required('production', v_value) then
    if p.status = 'pending_approval' then raise exception 'Produksi ini masih menunggu persetujuan'; end if;
    update inv_productions set status = 'pending_approval' where id = p.id;
    return jsonb_build_object('production_number', p.production_number) || sys_request_approval('production', p.id,
      (select outlet_id from inv_warehouses where id = p.warehouse_id), v_value,
      'Produksi ' || p.production_number || ' - ' || coalesce(r.name, ''), '{}');
  end if;

  v_factor := v_base / r.yield_qty;
  v_extra := round(coalesce((select sum(amount) from inv_recipe_costs where recipe_id = r.id), 0) * v_factor, 2);

  if r.recipe_type = 'assembly' then
    -- bahan keluar dari lokasi asal sesuai qty AKTUAL
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
      reference_type, reference_id, reference_number, created_by)
    select p.company_id, p.warehouse_id, l.item_id, 'production_out', -l.actual_qty,
           'inv_productions', p.id, p.production_number, auth.uid()
    from inv_production_lines l where l.production_id = p.id and l.line_type = 'material' and l.actual_qty > 0
    order by l.sort_order;

    select -coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_input
    from inv_stock_movements where reference_type = 'inv_productions' and reference_id = p.id;

    v_result := coalesce(p.result_qty, p.quantity) * p.conversion_qty;
    if v_result <= 0 then raise exception 'Qty hasil produksi harus lebih dari 0'; end if;
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost, expiry_date,
      reference_type, reference_id, reference_number, created_by)
    values (p.company_id, v_dest, r.item_id, 'production_in', v_result, (v_input + v_extra) / v_result, p.expiry_date,
            'inv_productions', p.id, p.production_number, auth.uid());
  else
    -- bahan sumber keluar dari lokasi asal
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
      reference_type, reference_id, reference_number, created_by)
    values (p.company_id, p.warehouse_id, r.item_id, 'production_out', -v_base,
            'inv_productions', p.id, p.production_number, auth.uid());

    select -coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_input
    from inv_stock_movements where reference_type = 'inv_productions' and reference_id = p.id;
    select sum(coalesce(weight_factor, 1)) into v_total_wf
    from inv_production_lines where production_id = p.id and line_type = 'result' and actual_qty > 0;
    if coalesce(v_total_wf, 0) = 0 then raise exception 'Isi qty hasil pemotongan'; end if;

    -- hasil masuk ke lokasi tujuan; nilai dibagi sesuai weight factor
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost, expiry_date,
      reference_type, reference_id, reference_number, created_by)
    select p.company_id, v_dest, l.item_id, 'production_in', l.actual_qty,
           (v_input + v_extra) * coalesce(l.weight_factor, 1) / v_total_wf / l.actual_qty, l.expiry_date,
           'inv_productions', p.id, p.production_number, auth.uid()
    from inv_production_lines l where l.production_id = p.id and l.line_type = 'result' and l.actual_qty > 0
    order by l.sort_order;
  end if;

  update inv_productions set status = 'posted', posted_at = now() where id = p.id;
  perform sys_close_approval('production', p.id);

  -- Jurnal: persediaan per kategori (bersih = biaya tambahan) | akun biaya tambahan
  if exists (select 1 from fin_accounts where company_id = p.company_id) then
    select coalesce(sum(round(quantity * unit_cost, 2)), 0) into v_inv_net
    from inv_stock_movements where reference_type = 'inv_productions' and reference_id = p.id;

    select coalesce(jsonb_agg(jsonb_build_object('account_id', account_id, 'credit', round(amount * v_factor, 2), 'note', description)), '[]'::jsonb)
      into v_lines
    from inv_recipe_costs where recipe_id = r.id;

    v_lines := v_lines || fin_stock_journal_lines('inv_productions', p.id)
      || jsonb_build_array(jsonb_build_object('account_id', fin_account_id(p.company_id, 'inventory'),
           'debit', (select coalesce(sum(round(amount * v_factor, 2)), 0) from inv_recipe_costs where recipe_id = r.id) - v_inv_net));

    perform fin_create_journal(p.company_id, (select outlet_id from inv_warehouses where id = p.warehouse_id),
      p.production_date, 'production', p.id, 'Produksi ' || p.production_number || ' - ' || coalesce(r.name, ''), v_lines);
  end if;

  return jsonb_build_object('production_number', p.production_number, 'input_value', v_input, 'extra_cost', v_extra);
end $$;

-- Laporan selisih pemakaian vs BOM
create view rpt_production_variances with (security_invoker = true) as
select l.company_id, p.id as production_id, p.production_number, p.production_date, p.status, r.recipe_type, r.name as recipe_name,
       l.line_type, l.item_id, it.code as item_code, it.name as item_name, u.code as unit_code,
       l.bom_qty, l.system_qty, l.actual_qty, l.actual_qty - l.system_qty as variance_qty,
       case when l.system_qty > 0 then round((l.actual_qty - l.system_qty) / l.system_qty * 100, 1) end as variance_pct
from inv_production_lines l
join inv_productions p on p.id = l.production_id
join inv_recipes r on r.id = p.recipe_id
join inv_items it on it.id = l.item_id
join inv_units u on u.id = it.base_unit_id;

-- ---------------------------------------------------------------------
-- APPROVAL: jenis "production"
-- ---------------------------------------------------------------------
alter table sys_approval_rules drop constraint sys_approval_rules_document_type_check;
alter table sys_approval_rules add constraint sys_approval_rules_document_type_check
  check (document_type in ('purchase_order', 'expense', 'stock_adjustment', 'stock_opname', 'refund', 'product', 'pricelist',
                           'sales_order', 'credit_note', 'sales_payment', 'supplier_payment', 'pos_settlement',
                           'manual_journal', 'stock_transfer', 'production'));

create or replace function sys_setup_approval_rules(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into sys_approval_rules (company_id, document_type, min_amount, is_enabled) values
    (p_company_id, 'purchase_order',   5000000, false),
    (p_company_id, 'expense',          1000000, false),
    (p_company_id, 'stock_adjustment',  500000, false),
    (p_company_id, 'stock_opname',     1000000, false),
    (p_company_id, 'refund',                 0, false),
    (p_company_id, 'product',                0, false),
    (p_company_id, 'pricelist',              0, false),
    (p_company_id, 'sales_order',     10000000, false),
    (p_company_id, 'credit_note',            0, false),
    (p_company_id, 'sales_payment',   10000000, false),
    (p_company_id, 'supplier_payment', 5000000, false),
    (p_company_id, 'pos_settlement',     50000, false),
    (p_company_id, 'manual_journal',         0, false),
    (p_company_id, 'stock_transfer',   5000000, false),
    (p_company_id, 'production',             0, false)
  on conflict do nothing
$$;

do $$
declare c record;
begin
  for c in select id from sys_companies loop perform sys_setup_approval_rules(c.id); end loop;
end $$;

-- keputusan & batal approval: tambah jenis production
create or replace function sys_revert_pending_document(p_document_type text, p_document_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('erp.approval_decision', 'on', true);
  if p_document_type = 'purchase_order' then
    update pur_purchase_orders set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_adjustment' then
    update inv_stock_adjustments set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_opname' then
    update inv_stock_opnames set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'product' then
    update inv_items set approval_status = 'rejected' where id = p_document_id and approval_status = 'pending';
  elsif p_document_type = 'pricelist' then
    update pur_pricelists set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'sales_order' then
    update sal_sales_orders set status = case when customer_type = 'internal' then 'new' else 'draft' end
    where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'stock_transfer' then
    update inv_stock_transfers set status = 'draft' where id = p_document_id and status = 'pending_approval';
  elsif p_document_type = 'production' then
    update inv_productions set status = 'draft' where id = p_document_id and status = 'pending_approval';
  end if;
  perform set_config('erp.approval_decision', 'off', true);
end $$;

create or replace function sys_decide_approval(p_request_id uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        sys_approval_requests%rowtype;
  v_result jsonb;
  v_dates  date[];
begin
  select * into v from sys_approval_requests
  where id = p_request_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Permintaan tidak ditemukan'; end if;
  if v.status <> 'pending' then raise exception 'Permintaan sudah diputuskan'; end if;
  if not sys_has_permission('approval.' || v.document_type) then raise exception 'Anda tidak berwenang menyetujui ini'; end if;
  if v.requested_by = auth.uid() and not sys_has_permission('*') then
    raise exception 'Tidak bisa menyetujui permintaan sendiri';
  end if;

  if p_approve then
    if v.document_type = 'purchase_order' then
      v_result := pur_approve_purchase_order(v.document_id);
    elsif v.document_type = 'expense' then
      v_result := jsonb_build_object('journal_id', fin_record_expense(
        (v.payload->>'date')::date, (v.payload->>'expense_account_id')::uuid, (v.payload->>'paid_from_account_id')::uuid,
        (v.payload->>'amount')::numeric, v.payload->>'description', nullif(v.payload->>'outlet_id', '')::uuid));
    elsif v.document_type = 'stock_adjustment' then
      perform inv_post_stock_adjustment(v.document_id);
    elsif v.document_type = 'stock_opname' then
      perform inv_post_stock_opname(v.document_id);
    elsif v.document_type = 'refund' then
      v_result := pos_refund_order_execute(v.document_id, v.payload->>'reason',
                                           coalesce((v.payload->>'return_stock')::boolean, false), v.requested_by);
    elsif v.document_type = 'product' then
      perform set_config('erp.approval_decision', 'on', true);
      update inv_items set approval_status = 'approved' where id = v.document_id and approval_status = 'pending';
      perform set_config('erp.approval_decision', 'off', true);
    elsif v.document_type = 'pricelist' then
      v_result := pur_approve_pricelist(v.document_id);

    -- jenis baru: dijalankan dengan hak modul pembuat
    elsif v.document_type = 'sales_order' then
      v_result := sal_confirm_sales_order(v.document_id);
    elsif v.document_type = 'credit_note' then
      perform sys_act_for('sales.manage');
      v_result := sal_create_credit_note_execute(v.document_id, (v.payload->>'amount')::numeric, v.payload->>'reason', v.payload->>'note');
    elsif v.document_type = 'sales_payment' then
      perform sys_act_for('sales.manage');
      v_result := sal_record_payment_execute(v.payload->'allocations', (v.payload->>'to_account_id')::uuid,
        nullif(v.payload->>'from_account_id', '')::uuid, (v.payload->>'payment_date')::date, v.payload->>'reference', v.payload->>'note');
    elsif v.document_type = 'supplier_payment' then
      perform sys_act_for('finance.manage');
      v_result := fin_pay_supplier_execute((v.payload->>'supplier_id')::uuid, (v.payload->>'account_id')::uuid,
        (v.payload->>'payment_date')::date, v.payload->'allocations', v.payload->>'reference');
    elsif v.document_type = 'pos_settlement' then
      perform sys_act_for('finance.manage');
      select array_agg(d::date) into v_dates from jsonb_array_elements_text(v.payload->'dates') d;
      v_result := pos_create_settlement_execute((v.payload->>'outlet_id')::uuid, (v.payload->>'payment_method_id')::uuid, v_dates,
        (v.payload->>'received_amount')::numeric, (v.payload->>'fee_amount')::numeric, nullif(v.payload->>'to_account_id', '')::uuid,
        (v.payload->>'settlement_date')::date, v.payload->>'reference', v.payload->>'note');
    elsif v.document_type = 'manual_journal' then
      perform sys_act_for('finance.manage');
      v_result := jsonb_build_object('journal_id', fin_post_manual_journal_execute((v.payload->>'date')::date, v.payload->>'description', v.payload->'lines'));
    elsif v.document_type = 'stock_transfer' then
      perform sys_act_for('inventory.manage');
      if v.payload->>'mode' = 'post' then perform inv_post_stock_transfer(v.document_id);
      else perform inv_ship_stock_transfer(v.document_id); end if;
    elsif v.document_type = 'production' then
      perform sys_act_for('inventory.manage');
      v_result := inv_post_production(v.document_id);
    end if;
    perform sys_act_for('');
  else
    perform sys_revert_pending_document(v.document_type, v.document_id);
  end if;

  update sys_approval_requests set
    status        = case when p_approve then 'approved' else 'rejected' end,
    decided_by    = auth.uid(),
    decided_at    = now(),
    decision_note = nullif(trim(p_note), ''),
    result        = v_result
  where id = p_request_id
  returning * into v;
  return to_jsonb(v);
end $$;

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('inv_production_lines', 'inventory.manage');

revoke execute on function inv_prepare_production_lines(uuid) from public, anon, authenticated;

-- >>>>>>>>>> migrations/026_branch_access.sql
-- =====================================================================
-- SANTAP ERP - 026: AKSES BRANCH PER USER + ROLE TEMPLATE
--   * outlet_scope per user: 'all' = semua branch (termasuk branch baru),
--     'selected' = hanya branch yang dicentang (1 branch = terkunci di branch itu)
--   * Data dikunci per branch di database (policy RESTRICTIVE):
--     POS, shift, refund, settlement, stok, batch, kartu stok, dokumen stok, transfer,
--     produksi, PO, penerimaan, sales order, pengiriman, invoice, pembayaran, approval
--   * Owner selalu semua branch. Gudang tanpa outlet (pusat) hanya untuk akses semua branch.
--   * Role template (GM, Finance, Purchasing, ... Supervisor) + cakupan branch default per role
-- =====================================================================

alter table sys_users add column outlet_scope text not null default 'selected';
alter table sys_users add constraint sys_users_outlet_scope_check check (outlet_scope in ('all', 'selected'));
alter table sys_roles add column default_outlet_scope text not null default 'selected';
alter table sys_roles add constraint sys_roles_default_outlet_scope_check check (default_outlet_scope in ('all', 'selected'));

-- ---------------------------------------------------------------------
-- PEMERIKSA AKSES
-- ---------------------------------------------------------------------
create or replace function sys_user_all_outlets()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('*') or coalesce((select outlet_scope = 'all' from sys_users where id = auth.uid() and is_active), false)
$$;

create or replace function sys_can_access_outlet(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (sys_user_all_outlets() and exists (
            select 1 from sys_outlets where id = p_outlet_id and company_id = sys_current_company_id()))
      or exists (select 1 from sys_user_outlets where user_id = auth.uid() and outlet_id = p_outlet_id)
$$;

create or replace function sys_can_access_warehouse(p_warehouse_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when w.outlet_id is null then sys_user_all_outlets() else sys_can_access_outlet(w.outlet_id) end
    from inv_warehouses w where w.id = p_warehouse_id and w.company_id = sys_current_company_id()), false)
$$;

-- profil: daftar branch yang boleh diakses + cakupannya
create or replace function sys_get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', u.id,
    'full_name', u.full_name,
    'phone', u.phone,
    'avatar_url', u.avatar_url,
    'email', (select email from auth.users where id = u.id),
    'company_id', c.id,
    'company_name', c.name,
    'company_app_name', c.app_name,
    'company_logo_url', c.logo_url,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlet_scope', case when r.permissions ? '*' then 'all' else u.outlet_scope end,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or u.outlet_scope = 'all' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'username', u.username,
           'email', case when u.username is null then au.email end, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_scope', case when r.permissions ? '*' then 'all' else u.outlet_scope end,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

-- Atur role, cakupan branch, branch & status user
create or replace function sys_set_user_access(p_user_id uuid, p_role_id uuid, p_outlet_scope text, p_outlet_ids uuid[], p_is_active boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if p_user_id = auth.uid() then raise exception 'Tidak bisa mengubah akun sendiri'; end if;
  if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then raise exception 'User tidak ditemukan'; end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then raise exception 'Role tidak valid'; end if;
  if p_outlet_scope not in ('all', 'selected') then raise exception 'Cakupan branch tidak valid'; end if;
  if p_outlet_scope = 'selected' and coalesce(array_length(p_outlet_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 branch'; end if;

  update sys_users set role_id = p_role_id, is_active = coalesce(p_is_active, true), outlet_scope = p_outlet_scope where id = p_user_id;
  delete from sys_user_outlets where user_id = p_user_id;
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o
  where o.company_id = v_company and (p_outlet_scope = 'all' or o.id = any(p_outlet_ids));
  perform sys_log_activity(v_company, 'update_user_access', 'sys_users', p_user_id,
    (select full_name from sys_users where id = p_user_id) || case when p_outlet_scope = 'all' then ' (semua branch)'
      else ' (' || coalesce(array_length(p_outlet_ids, 1), 0) || ' branch)' end, null);
end $$;

-- ---------------------------------------------------------------------
-- KUNCI DATA PER BRANCH (policy restrictive = DIGABUNG "AND" dengan policy yang sudah ada)
-- ---------------------------------------------------------------------
create or replace function sys_apply_outlet_lock(p_table text, p_predicate text)
returns void language plpgsql as $$
begin
  execute format('drop policy if exists %I on %I', p_table || '_branch', p_table);
  execute format('create policy %I on %I as restrictive for all to authenticated using (%s) with check (%s)',
    p_table || '_branch', p_table, p_predicate, p_predicate);
end $$;

select sys_apply_outlet_lock('pos_orders',            'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_shifts',            'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_refunds',           'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_settlements',       'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_settlement_items',  'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('inv_stocks',            'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_movements',   'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_batches',     'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_adjustments', 'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_opnames',     'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_productions',       'sys_can_access_warehouse(warehouse_id) or (dest_warehouse_id is not null and sys_can_access_warehouse(dest_warehouse_id))');
select sys_apply_outlet_lock('inv_stock_transfers',   'sys_can_access_warehouse(from_warehouse_id) or sys_can_access_warehouse(to_warehouse_id)');
select sys_apply_outlet_lock('pur_purchase_orders',   'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('pur_goods_receipts',    'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('sal_sales_orders',      'sys_can_access_outlet(outlet_id) or (buyer_outlet_id is not null and sys_can_access_outlet(buyer_outlet_id))');
select sys_apply_outlet_lock('sal_deliveries',        'exists (select 1 from sal_sales_orders s where s.id = sales_order_id)');
select sys_apply_outlet_lock('sal_invoices',          'sys_can_access_outlet(outlet_id) or (buyer_outlet_id is not null and sys_can_access_outlet(buyer_outlet_id))');
select sys_apply_outlet_lock('sal_payments',          'sys_can_access_outlet(outlet_id) or (buyer_outlet_id is not null and sys_can_access_outlet(buyer_outlet_id))');
select sys_apply_outlet_lock('sys_approval_requests', 'outlet_id is null or sys_can_access_outlet(outlet_id)');

-- ---------------------------------------------------------------------
-- ROLE TEMPLATE
-- ---------------------------------------------------------------------
create or replace function sys_create_role_templates()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_n       int;
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola role'; end if;
  insert into sys_roles (company_id, code, name, permissions, default_outlet_scope)
  select v_company, x.code, x.name, x.perms::jsonb, x.scope
  from (values
    -- HEAD OFFICE (semua branch)
    ('gm', 'General Manager', '["report.view","master.manage","inventory.manage","purchasing.manage","sales.manage","crm.manage","finance.view","pos.order","pos.pay","pos.discount","pos.void","pos.refund","kds.update","approval.purchase_order","approval.sales_order","approval.stock_transfer","approval.production","approval.stock_adjustment","approval.stock_opname","approval.refund"]', 'all'),
    ('finance', 'Finance & Accounting', '["finance.view","finance.manage","report.view","approval.expense","approval.supplier_payment","approval.sales_payment","approval.credit_note","approval.pos_settlement","approval.manual_journal"]', 'all'),
    ('purchasing', 'Purchasing', '["purchasing.manage","report.view"]', 'all'),
    ('cost_control', 'Cost Control / Inventory Controller', '["inventory.manage","report.view","approval.stock_adjustment","approval.stock_opname","approval.product","approval.pricelist"]', 'all'),
    ('sales_admin', 'Sales B2B / Admin Sales', '["sales.manage","report.view"]', 'all'),
    ('marketing', 'Marketing / CRM', '["crm.manage","master.manage","report.view"]', 'all'),
    ('admin_it', 'Admin / HR-IT', '["user.manage","audit.view"]', 'all'),
    -- SUPPLY CHAIN / CENTRAL KITCHEN
    ('head_chef', 'Head Chef / Supervisor CK', '["inventory.manage","sales.manage","kds.update","report.view"]', 'selected'),
    ('warehouse', 'Staf Gudang', '["inventory.manage","purchasing.manage"]', 'selected'),
    -- OUTLET
    ('store_manager', 'Store Manager', '["pos.order","pos.pay","pos.discount","pos.void","pos.refund","kds.update","inventory.manage","purchasing.manage","report.view","approval.refund","approval.stock_adjustment"]', 'selected'),
    ('supervisor', 'Supervisor / Kapten', '["pos.order","pos.pay","pos.discount","pos.void","kds.update","approval.refund"]', 'selected')
  ) as x(code, name, perms, scope)
  where not exists (select 1 from sys_roles r where r.company_id = v_company and r.code = x.code);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function sys_apply_outlet_lock(text, text) from public, anon, authenticated;

-- >>>>>>>>>> migrations/027_platform_groups_brands.sql
-- =====================================================================
-- SANTAP ERP - 027: PLATFORM ADMIN, GRUP USAHA (MULTI PT), BRAND
--   Tingkat:  Platform Admin (developer)  >  Grup usaha  >  PT (perusahaan)  >  Brand  >  Outlet
--   * Platform Admin: HANYA bisa diberikan lewat SQL Editor (tabel sys_platform_admins).
--     Bisa melihat semua perusahaan, memetakan PT ke grup, menonaktifkan PT,
--     dan MASUK ke PT mana pun (mode support = akses penuh, semua aksi dicatat).
--   * Grup usaha: beberapa PT dikelompokkan (mapping, bukan merge). Pemilik grup bisa
--     pindah antar PT di grupnya dengan akses penuh (seperti owner PT tersebut).
--   * PT tetap terpisah total untuk owner/staf biasa.
--   * Brand: outlet masuk ke brand; akses user bisa per brand (termasuk outlet baru brand itu).
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABEL
-- ---------------------------------------------------------------------
create table sys_platform_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  note        text,
  created_at  timestamptz not null default now()
);
alter table sys_platform_admins enable row level security;     -- tanpa policy: hanya lewat fungsi

create table sys_company_groups (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table sys_company_groups enable row level security;

alter table sys_companies add column group_id uuid references sys_company_groups(id) on delete set null;

create table sys_group_members (
  group_id    uuid not null references sys_company_groups(id) on delete cascade,
  user_id     uuid not null references sys_users(id) on delete cascade,
  role        text not null default 'owner' check (role in ('owner')),
  created_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table sys_group_members enable row level security;

-- PT yang sedang "dimasuki" user (pindah PT grup / mode support)
create table sys_user_context (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  acting_company_id  uuid not null references sys_companies(id) on delete cascade,
  mode               text not null check (mode in ('group', 'support')),
  started_at         timestamptz not null default now()
);
alter table sys_user_context enable row level security;

-- akses per brand
alter table sys_users drop constraint sys_users_outlet_scope_check;
alter table sys_users add constraint sys_users_outlet_scope_check check (outlet_scope in ('all', 'selected', 'brands'));
create table sys_user_brands (
  user_id   uuid not null references sys_users(id) on delete cascade,
  brand_id  uuid not null references sys_brands(id) on delete cascade,
  primary key (user_id, brand_id)
);
alter table sys_user_brands enable row level security;
create policy sys_user_brands_select on sys_user_brands for select to authenticated
  using (user_id in (select id from sys_users where company_id = sys_current_company_id()));

-- ---------------------------------------------------------------------
-- IDENTITAS & PERUSAHAAN AKTIF
-- ---------------------------------------------------------------------
create or replace function sys_is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from sys_platform_admins where user_id = auth.uid())
$$;

-- perusahaan "rumah" user (PT aktif & user aktif)
create or replace function sys_home_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select u.company_id from sys_users u join sys_companies c on c.id = u.company_id
  where u.id = auth.uid() and u.is_active and c.is_active
$$;

-- PT yang sedang dimasuki (null = di PT sendiri); dicek ulang setiap kali dipakai
create or replace function sys_acting_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select x.acting_company_id from sys_user_context x
  where x.user_id = auth.uid()
    and ((x.mode = 'support' and exists (select 1 from sys_platform_admins where user_id = auth.uid()))
      or (x.mode = 'group' and exists (
            select 1 from sys_companies c join sys_group_members m on m.group_id = c.group_id
            join sys_users u on u.id = m.user_id and u.is_active
            where c.id = x.acting_company_id and c.is_active and m.user_id = auth.uid())))
$$;

create or replace function sys_acting_mode()
returns text language sql stable security definer set search_path = public as $$
  select case when sys_acting_company_id() is null then null
              else (select mode from sys_user_context where user_id = auth.uid()) end
$$;

create or replace function sys_current_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(sys_acting_company_id(), sys_home_company_id())
$$;

-- di PT yang dimasuki (grup / support) = akses penuh seperti owner
create or replace function sys_has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select case when sys_acting_company_id() is not null then true else coalesce((
    select r.permissions ? '*' or r.permissions ? p_permission
    from sys_users u join sys_roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active
  ), false) end
  or coalesce(p_permission = any(string_to_array(nullif(current_setting('erp.acting_for', true), ''), ',')), false)
$$;

-- akses outlet: semua / branch tertentu / brand tertentu
create or replace function sys_user_all_outlets()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('*') or coalesce((select outlet_scope = 'all' from sys_users where id = auth.uid() and is_active), false)
$$;

create or replace function sys_can_access_outlet(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (sys_user_all_outlets() and exists (
            select 1 from sys_outlets where id = p_outlet_id and company_id = sys_current_company_id()))
      or (sys_acting_company_id() is null and (
            exists (select 1 from sys_user_outlets where user_id = auth.uid() and outlet_id = p_outlet_id)
         or exists (select 1 from sys_outlets o join sys_user_brands ub on ub.brand_id = o.brand_id
                    join sys_users u on u.id = ub.user_id and u.outlet_scope = 'brands'
                    where o.id = p_outlet_id and ub.user_id = auth.uid())))
$$;

-- nama pelaku di log: tandai mode support / pemilik grup
create or replace function sys_actor_label()
returns text language sql stable security definer set search_path = public as $$
  select (select full_name from sys_users where id = auth.uid())
      || case sys_acting_mode() when 'support' then ' (Platform support)' when 'group' then ' (Pemilik grup)' else '' end
$$;

create or replace function sys_log_activity(
  p_company_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_label text, p_changes jsonb default null
)
returns void language sql security definer set search_path = public as $$
  insert into sys_activity_logs (company_id, user_id, user_name, action, entity_type, entity_id, entity_label, changes)
  values (p_company_id, auth.uid(), sys_actor_label(), p_action, p_entity_type, p_entity_id, left(p_label, 200), p_changes)
$$;

-- ---------------------------------------------------------------------
-- PROFIL: PT aktif, mode, daftar PT yang bisa dipindah
-- ---------------------------------------------------------------------
create or replace function sys_get_my_profile()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  u      sys_users%rowtype;
  r      sys_roles%rowtype;
  c      sys_companies%rowtype;
  v_home uuid := sys_home_company_id();
  v_act  uuid := sys_acting_company_id();
  v_mode text := sys_acting_mode();
begin
  select * into u from sys_users where id = auth.uid() and is_active;
  if not found or (v_home is null and v_act is null) then return null; end if;
  select * into c from sys_companies where id = coalesce(v_act, v_home);
  select * into r from sys_roles where id = u.role_id;

  return jsonb_build_object(
    'user_id', u.id, 'full_name', u.full_name, 'phone', u.phone, 'avatar_url', u.avatar_url,
    'email', (select email from auth.users where id = u.id),
    'company_id', c.id, 'company_name', c.name, 'company_app_name', c.app_name, 'company_logo_url', c.logo_url,
    'role_code', case when v_act is not null then 'owner' else r.code end,
    'role_name', case v_mode when 'support' then 'Platform support' when 'group' then 'Pemilik grup' else r.name end,
    'permissions', case when v_act is not null then '["*"]'::jsonb else r.permissions end,
    'outlet_scope', case when v_act is not null or r.permissions ? '*' then 'all' else u.outlet_scope end,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name, 'brand_id', o.brand_id) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (v_act is not null or r.permissions ? '*' or u.outlet_scope = 'all'
             or exists (select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id)
             or (u.outlet_scope = 'brands' and exists (select 1 from sys_user_brands ub where ub.user_id = u.id and ub.brand_id = o.brand_id)))
    ), '[]'::jsonb),
    'is_platform_admin', sys_is_platform_admin(),
    'acting_mode', v_mode,
    'home_company_id', u.company_id,
    'home_company_name', (select name from sys_companies where id = u.company_id),
    'group_name', (select name from sys_company_groups where id = c.group_id),
    -- PT yang bisa dipindah: PT sendiri + PT di grup yang dia miliki
    'companies', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'group_name', g.name) order by x.name)
      from sys_companies x left join sys_company_groups g on g.id = x.group_id
      where x.is_active and (x.id = u.company_id or exists (
        select 1 from sys_group_members m where m.user_id = u.id and m.group_id = x.group_id))
    ), '[]'::jsonb)
  );
end $$;

-- Pindah PT. null / PT sendiri = kembali ke PT sendiri
create or replace function sys_switch_company(p_company_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_home uuid := (select company_id from sys_users where id = auth.uid() and is_active);
  v_mode text;
begin
  if v_home is null then raise exception 'Akun tidak aktif'; end if;
  if p_company_id is null or p_company_id = v_home then
    delete from sys_user_context where user_id = auth.uid();
    return jsonb_build_object('company_id', v_home, 'mode', null);
  end if;
  if not exists (select 1 from sys_companies where id = p_company_id) then raise exception 'Perusahaan tidak ditemukan'; end if;

  if exists (select 1 from sys_companies c join sys_group_members m on m.group_id = c.group_id
             where c.id = p_company_id and c.is_active and m.user_id = auth.uid()) then
    v_mode := 'group';
  elsif sys_is_platform_admin() then
    v_mode := 'support';
  else
    raise exception 'Anda tidak punya akses ke perusahaan ini';
  end if;

  insert into sys_user_context (user_id, acting_company_id, mode) values (auth.uid(), p_company_id, v_mode)
  on conflict (user_id) do update set acting_company_id = excluded.acting_company_id, mode = excluded.mode, started_at = now();
  perform sys_log_activity(p_company_id, case v_mode when 'support' then 'support_enter' else 'switch_company' end,
    'sys_companies', p_company_id, (select name from sys_companies where id = p_company_id), null);
  return jsonb_build_object('company_id', p_company_id, 'mode', v_mode);
end $$;

-- ---------------------------------------------------------------------
-- CONSOLE PLATFORM (khusus Platform Admin)
-- ---------------------------------------------------------------------
create or replace function sys_platform_check()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_is_platform_admin() then raise exception 'Khusus Platform Admin'; end if;
end $$;

create or replace function sys_platform_companies()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name, 'is_active', c.is_active, 'created_at', c.created_at,
      'group_id', c.group_id, 'group_name', g.name,
      'users', (select count(*) from sys_users u where u.company_id = c.id),
      'outlets', (select count(*) from sys_outlets o where o.company_id = c.id),
      'brands', (select count(*) from sys_brands b where b.company_id = c.id),
      'owners', (select string_agg(coalesce(au.email, u.full_name), ', ') from sys_users u join sys_roles r on r.id = u.role_id
                 left join auth.users au on au.id = u.id where u.company_id = c.id and r.permissions ? '*'),
      'orders_30d', (select count(*) from pos_orders po where po.company_id = c.id and po.status = 'paid' and po.business_date >= current_date - 30),
      'last_activity', (select max(l.created_at) from sys_activity_logs l where l.company_id = c.id)
    ) order by c.created_at desc)
    from sys_companies c left join sys_company_groups g on g.id = c.group_id), '[]'::jsonb);
end $$;

create or replace function sys_platform_groups()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'code', g.code, 'name', g.name,
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from sys_companies c where c.group_id = g.id), '[]'),
      'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'full_name', u.full_name, 'email', au.email,
                             'home_company', hc.name) order by u.full_name)
                           from sys_group_members m join sys_users u on u.id = m.user_id
                           join sys_companies hc on hc.id = u.company_id left join auth.users au on au.id = u.id
                           where m.group_id = g.id), '[]')
    ) order by g.name)
    from sys_company_groups g), '[]'::jsonb);
end $$;

create or replace function sys_platform_save_group(p_id uuid, p_code text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform sys_platform_check();
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_code), '') = '' then raise exception 'Kode & nama grup wajib diisi'; end if;
  if p_id is null then
    insert into sys_company_groups (code, name) values (upper(trim(p_code)), trim(p_name)) returning id into v_id;
  else
    update sys_company_groups set code = upper(trim(p_code)), name = trim(p_name) where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;

-- mapping PT ke grup (null = keluarkan dari grup)
create or replace function sys_platform_set_company_group(p_company_id uuid, p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  update sys_companies set group_id = p_group_id where id = p_company_id;
  perform sys_log_activity(p_company_id, 'map_group', 'sys_companies', p_company_id,
    coalesce('Masuk grup ' || (select name from sys_company_groups where id = p_group_id), 'Keluar dari grup'), null);
end $$;

create or replace function sys_platform_add_group_member(p_group_id uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform sys_platform_check();
  select u.id into v_user from sys_users u join auth.users au on au.id = u.id
  where lower(au.email) = lower(trim(p_email)) or lower(u.username) = lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'User "%" belum terdaftar di perusahaan mana pun', p_email; end if;
  insert into sys_group_members (group_id, user_id) values (p_group_id, v_user) on conflict do nothing;
end $$;

create or replace function sys_platform_remove_group_member(p_group_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  delete from sys_group_members where group_id = p_group_id and user_id = p_user_id;
  delete from sys_user_context where user_id = p_user_id and mode = 'group';
end $$;

create or replace function sys_platform_set_company_active(p_company_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  if not p_active and p_company_id = (select company_id from sys_users where id = auth.uid()) then
    raise exception 'Tidak bisa menonaktifkan perusahaan Anda sendiri';
  end if;
  update sys_companies set is_active = p_active where id = p_company_id;
  perform sys_log_activity(p_company_id, case when p_active then 'activate' else 'suspend' end, 'sys_companies', p_company_id,
    case when p_active then 'Perusahaan diaktifkan' else 'Perusahaan dinonaktifkan oleh platform' end, null);
end $$;

-- ---------------------------------------------------------------------
-- BRAND: outlet baru bisa memilih brand; akses user per brand
-- ---------------------------------------------------------------------
drop function sys_create_outlet(text, text, text);
create or replace function sys_create_outlet(p_code text, p_name text, p_address text default null, p_brand_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_outlet  sys_outlets%rowtype;
  v_wh      uuid;
  v_brand   uuid;
begin
  if not sys_has_permission('settings.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then
    raise exception 'Kode dan nama outlet wajib diisi';
  end if;
  v_brand := coalesce((select id from sys_brands where id = p_brand_id and company_id = v_company),
                      (select id from sys_brands where company_id = v_company order by created_at limit 1));

  insert into sys_outlets (company_id, brand_id, code, name, address)
  values (v_company, v_brand, upper(trim(p_code)), trim(p_name), p_address)
  returning * into v_outlet;

  insert into inv_warehouses (company_id, outlet_id, code, name)
  values (v_company, v_outlet.id, 'WH-' || v_outlet.code, 'Gudang ' || v_outlet.name)
  returning id into v_wh;

  update sys_outlets set default_warehouse_id = v_wh where id = v_outlet.id;
  if exists (select 1 from sys_users where id = auth.uid() and company_id = v_company) then
    insert into sys_user_outlets (user_id, outlet_id) values (auth.uid(), v_outlet.id) on conflict do nothing;
  end if;
  return to_jsonb(v_outlet);
end $$;

drop function sys_set_user_access(uuid, uuid, text, uuid[], boolean);
create or replace function sys_set_user_access(
  p_user_id uuid, p_role_id uuid, p_outlet_scope text, p_outlet_ids uuid[], p_is_active boolean default true, p_brand_ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if p_user_id = auth.uid() then raise exception 'Tidak bisa mengubah akun sendiri'; end if;
  if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then raise exception 'User tidak ditemukan'; end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then raise exception 'Role tidak valid'; end if;
  if p_outlet_scope not in ('all', 'selected', 'brands') then raise exception 'Cakupan akses tidak valid'; end if;
  if p_outlet_scope = 'selected' and coalesce(array_length(p_outlet_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 branch'; end if;
  if p_outlet_scope = 'brands' and coalesce(array_length(p_brand_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 brand'; end if;

  update sys_users set role_id = p_role_id, is_active = coalesce(p_is_active, true), outlet_scope = p_outlet_scope where id = p_user_id;
  delete from sys_user_outlets where user_id = p_user_id;
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o
  where o.company_id = v_company and (p_outlet_scope = 'all' or (p_outlet_scope = 'selected' and o.id = any(p_outlet_ids))
                                      or (p_outlet_scope = 'brands' and o.brand_id = any(p_brand_ids)));
  delete from sys_user_brands where user_id = p_user_id;
  if p_outlet_scope = 'brands' then
    insert into sys_user_brands (user_id, brand_id)
    select p_user_id, b.id from sys_brands b where b.company_id = v_company and b.id = any(p_brand_ids);
  end if;
  perform sys_log_activity(v_company, 'update_user_access', 'sys_users', p_user_id,
    (select full_name from sys_users where id = p_user_id) || case p_outlet_scope when 'all' then ' (semua branch)'
      when 'brands' then ' (' || coalesce(array_length(p_brand_ids, 1), 0) || ' brand)'
      else ' (' || coalesce(array_length(p_outlet_ids, 1), 0) || ' branch)' end, null);
end $$;

create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'username', u.username,
           'email', case when u.username is null then au.email end, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_scope', case when r.permissions ? '*' then 'all' else u.outlet_scope end,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'brand_ids', coalesce((select jsonb_agg(ub.brand_id) from sys_user_brands ub where ub.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

create trigger trg_sys_brands_audit after insert or update or delete on sys_brands
  for each row execute function sys_audit_trigger('');

revoke execute on function sys_platform_check() from public, anon, authenticated;

-- >>>>>>>>>> migrations/028_platform_signups.sql
-- =====================================================================
-- SANTAP ERP - 028: PENDAFTAR BARU DI CONSOLE PLATFORM
--   * Daftar semua akun yang mendaftar sendiri (email), termasuk yang belum
--     menyelesaikan setup usaha. Staf yang dibuat owner (username) tidak ikut.
--   * Badge jumlah pendaftar baru sejak terakhir tab Pendaftar dibuka.
-- =====================================================================

alter table sys_platform_admins add column signups_seen_at timestamptz;

-- akun yang mendaftar sendiri (bukan staf username buatan owner)
create or replace function sys_platform_signup_users()
returns table (user_id uuid, email text, created_at timestamptz, email_confirmed_at timestamptz, last_sign_in_at timestamptz)
language sql stable security definer set search_path = public as $$
  select au.id, au.email::text, au.created_at, au.email_confirmed_at, au.last_sign_in_at
  from auth.users au
  where coalesce(au.email, '') not like '%@staff.santap.local'
    and not exists (select 1 from sys_users u where u.id = au.id and u.username is not null)
$$;

create or replace function sys_platform_signups()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', s.user_id, 'email', s.email, 'created_at', s.created_at,
      'email_confirmed_at', s.email_confirmed_at, 'last_sign_in_at', s.last_sign_in_at,
      'full_name', u.full_name, 'company_id', c.id, 'company_name', c.name, 'company_active', c.is_active, 'role_name', r.name,
      -- pending = belum buat PT / belum gabung; owner = pemilik PT; staff = gabung lewat undangan email
      'status', case when u.id is null then 'pending' when r.permissions ? '*' then 'owner' else 'staff' end,
      'is_new', s.created_at > coalesce((select signups_seen_at from sys_platform_admins where user_id = auth.uid()), now() - interval '7 days')
    ) order by s.created_at desc)
    from sys_platform_signup_users() s
    left join sys_users u on u.id = s.user_id
    left join sys_companies c on c.id = u.company_id
    left join sys_roles r on r.id = u.role_id), '[]'::jsonb);
end $$;

-- jumlah pendaftar baru sejak tab Pendaftar terakhir dibuka (pertama kali: 7 hari terakhir)
create or replace function sys_platform_new_signups()
returns integer language sql stable security definer set search_path = public as $$
  select case when not sys_is_platform_admin() then 0 else (
    select count(*)::int from sys_platform_signup_users() s
    where s.created_at > coalesce((select signups_seen_at from sys_platform_admins where user_id = auth.uid()), now() - interval '7 days')
  ) end
$$;

create or replace function sys_platform_mark_signups_seen()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  update sys_platform_admins set signups_seen_at = now() where user_id = auth.uid();
end $$;

-- daftar perusahaan: tandai PT yang baru dibuat 7 hari terakhir
create or replace function sys_platform_companies()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name, 'is_active', c.is_active, 'created_at', c.created_at,
      'is_new', c.created_at > now() - interval '7 days',
      'group_id', c.group_id, 'group_name', g.name,
      'users', (select count(*) from sys_users u where u.company_id = c.id),
      'outlets', (select count(*) from sys_outlets o where o.company_id = c.id),
      'brands', (select count(*) from sys_brands b where b.company_id = c.id),
      'owners', (select string_agg(coalesce(au.email, u.full_name), ', ') from sys_users u join sys_roles r on r.id = u.role_id
                 left join auth.users au on au.id = u.id where u.company_id = c.id and r.permissions ? '*'),
      'orders_30d', (select count(*) from pos_orders po where po.company_id = c.id and po.status = 'paid' and po.business_date >= current_date - 30),
      'last_activity', (select max(l.created_at) from sys_activity_logs l where l.company_id = c.id)
    ) order by c.created_at desc)
    from sys_companies c left join sys_company_groups g on g.id = c.group_id), '[]'::jsonb);
end $$;

revoke execute on function sys_platform_signup_users() from public, anon, authenticated;

-- >>>>>>>>>> migrations/029_fix_onboarding_activity_log.sql
-- =====================================================================
-- SANTAP ERP - 029: PERBAIKAN DAFTAR USAHA BARU (ONBOARDING)
--   Saat onboarding, perusahaan dibuat lebih dulu daripada baris sys_users.
--   Log aktivitas otomatis mencatat user_id = auth.uid() yang belum ada di sys_users,
--   sehingga gagal: "violates foreign key constraint sys_activity_logs_user_id_fkey".
--   Sekarang: user_id hanya diisi bila user sudah terdaftar; nama pelaku jatuh ke email.
-- =====================================================================

create or replace function sys_actor_label()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from sys_users where id = auth.uid()), (select email from auth.users where id = auth.uid()))
      || case sys_acting_mode() when 'support' then ' (Platform support)' when 'group' then ' (Pemilik grup)' else '' end
$$;

create or replace function sys_log_activity(
  p_company_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_label text, p_changes jsonb default null
)
returns void language sql security definer set search_path = public as $$
  insert into sys_activity_logs (company_id, user_id, user_name, action, entity_type, entity_id, entity_label, changes)
  values (p_company_id, (select id from sys_users where id = auth.uid()), sys_actor_label(),
          p_action, p_entity_type, p_entity_id, left(p_label, 200), p_changes)
$$;

-- >>>>>>>>>> migrations/030_semar_agent.sql
-- =====================================================================
-- SANTAP ERP - 030: AGENT AI "SEMAR" (KEPALA KONSULTAN)
--   * Hanya OWNER (permission '*') yang bisa mengobrol dengan Semar.
--   * Semar membaca & mengubah data lewat JWT owner sendiri -> RLS menjamin hanya data
--     perusahaan owner tersebut (company_id) yang tersentuh.
--   * Perubahan data selalu berupa USULAN yang harus disetujui owner di jendela obrolan.
--   * Semar hanya boleh MENGUBAH master data (ai_writable_tables); transaksi hanya dibaca.
--   * Kunci API Claude disimpan sebagai secret Edge Function (ANTHROPIC_API_KEY), tidak di database.
-- =====================================================================

create table ai_chat_messages (
  id               bigint generated always as identity primary key,
  company_id       uuid not null references sys_companies(id) on delete cascade,
  user_id          uuid not null references sys_users(id) on delete cascade,
  conversation_id  uuid not null,
  role             text not null check (role in ('user', 'assistant')),
  content          jsonb not null,           -- blok pesan format Claude (text, tool_use, tool_result)
  meta             jsonb,                    -- mis. { action_id, status: 'executed'|'rejected', result }
  input_tokens     int not null default 0,
  output_tokens    int not null default 0,
  created_at       timestamptz not null default now()
);
create index ai_chat_messages_conv_idx on ai_chat_messages (user_id, conversation_id, id);
alter table ai_chat_messages enable row level security;
-- obrolan pribadi: hanya pemiliknya sendiri, di perusahaan aktif, dan harus owner
create policy ai_chat_messages_select on ai_chat_messages for select to authenticated
  using (user_id = auth.uid() and company_id = sys_current_company_id() and sys_has_permission('*'));
create policy ai_chat_messages_insert on ai_chat_messages for insert to authenticated
  with check (user_id = auth.uid() and company_id = sys_current_company_id() and sys_has_permission('*'));
create policy ai_chat_messages_delete on ai_chat_messages for delete to authenticated
  using (user_id = auth.uid() and company_id = sys_current_company_id());

-- tabel yang tidak boleh dilihat agent sama sekali
create or replace function ai_hidden_tables()
returns text[] language sql immutable as $$
  select array['sys_platform_admins', 'sys_user_context', 'sys_payment_gateway_secrets', 'sys_company_groups',
               'sys_group_members', 'ai_chat_messages', 'sys_document_sequences']
$$;

-- master data yang boleh ditambah/diubah/dihapus agent (transaksi & stok hanya dibaca)
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers']
$$;

-- Struktur tabel untuk agent: kolom, tipe, wajib/tidak, relasi, aturan (check). Khusus owner.
create or replace function ai_table_info(p_tables text[] default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_has_permission('*') then raise exception 'Khusus owner'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'table', t.table_name,
      'kind', case when t.table_type = 'VIEW' then 'laporan (view, hanya baca)' else 'tabel' end,
      'writable', t.table_name = any(ai_writable_tables()),
      'has_company_id', exists (select 1 from information_schema.columns c where c.table_schema = 'public' and c.table_name = t.table_name and c.column_name = 'company_id'),
      'columns', case when p_tables is null then null else (
        select jsonb_agg(jsonb_build_object(
          'name', c.column_name, 'type', c.data_type, 'required', c.is_nullable = 'NO' and c.column_default is null and c.is_identity = 'NO',
          'default', c.column_default) order by c.ordinal_position)
        from information_schema.columns c where c.table_schema = 'public' and c.table_name = t.table_name) end,
      'references', case when p_tables is null then null else (
        select jsonb_agg(jsonb_build_object('column', a.attname, 'table', pl.relname))
        from pg_constraint k join pg_class cl on cl.oid = k.conrelid join pg_class pl on pl.oid = k.confrelid
        join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
        where k.contype = 'f' and cl.relname = t.table_name and cl.relnamespace = 'public'::regnamespace) end,
      'rules', case when p_tables is null then null else (
        select jsonb_agg(pg_get_constraintdef(k.oid))
        from pg_constraint k join pg_class cl on cl.oid = k.conrelid
        where k.contype in ('c', 'u') and cl.relname = t.table_name and cl.relnamespace = 'public'::regnamespace) end
    ) order by t.table_name)
    from information_schema.tables t
    where t.table_schema = 'public' and t.table_name <> all(ai_hidden_tables())
      and (t.table_type = 'BASE TABLE' or t.table_name like 'rpt\_%')
      and (p_tables is null or t.table_name = any(p_tables))
  ), '[]'::jsonb);
end $$;

-- penggunaan agent: jumlah pesan owner dalam 1 jam terakhir (batas pemakaian kunci API)
create or replace function ai_recent_usage()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'messages_last_hour', (select count(*) from ai_chat_messages where user_id = auth.uid() and role = 'user'
                             and created_at > now() - interval '1 hour' and meta is null),
    'tokens_today', (select coalesce(sum(input_tokens + output_tokens), 0) from ai_chat_messages
                       where company_id = sys_current_company_id() and created_at > now() - interval '1 day'))
$$;

-- >>>>>>>>>> migrations/031_brand_logos_landing.sql
-- =====================================================================
-- SANTAP ERP - 031: LOGO BRAND & "BRAND YANG SUDAH BERSAMA SEMAR" DI LANDING PAGE
--   * Setiap brand bisa punya logo (sys_brands.logo_url, unggah di Pengaturan > Brand).
--   * show_on_landing: owner mengizinkan logo & nama brand tampil di halaman depan SEMAR.
--   * sys_public_brands(): bisa dipanggil tanpa login, HANYA mengembalikan nama & logo brand
--     yang aktif, punya logo, mengizinkan tampil, dan perusahaannya aktif.
-- =====================================================================

alter table sys_brands add column show_on_landing boolean not null default true;

create or replace function sys_public_brands()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'logo_url', b.logo_url) order by b.created_at), '[]'::jsonb)
  from sys_brands b join sys_companies c on c.id = b.company_id
  where b.is_active and b.show_on_landing and c.is_active and coalesce(b.logo_url, '') <> ''
$$;
grant execute on function sys_public_brands() to anon, authenticated;

-- >>>>>>>>>> migrations/032_semar_purchase_order.sql
-- =====================================================================
-- SANTAP ERP - 032: SEMAR BISA MENGANALISA KEBUTUHAN BELI & MEMBUAT PO
--   * ai_purchase_forecast: per bahan -> stok, pemakaian/hari, cukup berapa hari, saran beli
--     (satuan beli), opsi supplier & harga dari pricelist aktif, harga pembelian terakhir.
--   * ai_create_purchase_order: buat PO dari usulan Semar. p_dry_run = true -> hanya pratinjau
--     (harga diisi otomatis dari pricelist / pembelian terakhir), tanpa menyimpan.
--     submit = true -> langsung diajukan lewat pur_approve_purchase_order (ikut matriks approval).
--   Keduanya memakai hak akses user yang memanggil (purchasing.manage, akses gudang/branch).
-- =====================================================================

create or replace function ai_purchase_forecast(
  p_warehouse_id uuid default null, p_days int default 14, p_cover_days int default 7, p_search text default null
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_days int := greatest(coalesce(p_days, 14), 1);
  v_cover int := greatest(coalesce(p_cover_days, 7), 1);
begin
  if not (sys_has_permission('purchasing.manage') or sys_has_permission('inventory.manage')) then raise exception 'Tidak punya izin melihat kebutuhan beli'; end if;
  return jsonb_build_object(
    'periode_data_hari', v_days, 'target_cukup_hari', v_cover,
    'gudang', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'nama', w.name)) from inv_warehouses w
                        where w.company_id = v_company and (p_warehouse_id is null or w.id = p_warehouse_id) and sys_can_access_warehouse(w.id)), '[]'::jsonb),
    'items', coalesce((
      with wh as (
        select id from inv_warehouses where company_id = v_company and (p_warehouse_id is null or id = p_warehouse_id) and sys_can_access_warehouse(id)
      ), stock as (
        select item_id, sum(quantity) qty from inv_stocks where warehouse_id in (select id from wh) group by item_id
      ), usage as (
        select item_id, -sum(quantity) used from inv_stock_movements
        where warehouse_id in (select id from wh) and quantity < 0 and movement_type not in ('transfer_out', 'opname')
          and movement_at >= now() - make_interval(days => v_days)
        group by item_id
      ), lvl as (
        select item_id, sum(min_qty) min_qty from inv_item_stock_levels where warehouse_id in (select id from wh) group by item_id
      ), calc as (
        select i.id, i.code, i.name, b.code base_unit, coalesce(st.qty, 0) stock, coalesce(u.used, 0) / v_days daily,
               coalesce(l.min_qty, i.min_stock, 0) min_qty, coalesce(pu.unit_id, i.base_unit_id) p_unit, coalesce(pu.conversion_qty, 1) p_conv,
               coalesce(pun.code, b.code) p_unit_code, i.last_purchase_cost
        from inv_items i
        join inv_units b on b.id = i.base_unit_id
        left join stock st on st.item_id = i.id
        left join usage u on u.item_id = i.id
        left join lvl l on l.item_id = i.id
        left join inv_item_units pu on pu.item_id = i.id and pu.is_purchase_unit
        left join inv_units pun on pun.id = pu.unit_id
        where i.company_id = v_company and i.is_active and i.is_purchasable
          and (p_search is null or i.name ilike '%' || p_search || '%' or i.code ilike '%' || p_search || '%')
      )
      select jsonb_agg(x order by (x->>'cukup_untuk_hari')::numeric nulls last, x->>'nama')
      from (
        select jsonb_build_object(
          'item_id', c.id, 'kode', c.code, 'nama', c.name,
          'stok', round(c.stock, 2), 'satuan_dasar', c.base_unit,
          'pemakaian_per_hari', round(c.daily, 3),
          'cukup_untuk_hari', case when c.daily > 0 then round(c.stock / c.daily, 1) end,
          'stok_minimum', c.min_qty,
          'saran_beli', ceil(greatest(0, c.daily * v_cover + c.min_qty - c.stock) / c.p_conv),
          'satuan_beli', c.p_unit_code, 'unit_id_beli', c.p_unit, 'isi_per_satuan_beli', c.p_conv,
          'harga_beli_terakhir_per_satuan_beli', round(c.last_purchase_cost * c.p_conv, 2),
          'opsi_supplier', coalesce((
            select jsonb_agg(o order by (o->>'harga')::numeric) from (
              select distinct on (pl.supplier_id) jsonb_build_object(
                'supplier_id', s.id, 'supplier', s.name, 'harga', pi.price, 'satuan', un.code, 'unit_id', pi.unit_id,
                'sumber', 'pricelist ' || coalesce(pl.pricelist_number, '')) o
              from pur_pricelist_items pi join pur_pricelists pl on pl.id = pi.pricelist_id
              join pur_suppliers s on s.id = pl.supplier_id join inv_units un on un.id = pi.unit_id
              where pi.item_id = c.id and pl.company_id = v_company and pl.status = 'approved'
                and pl.effective_date <= current_date and (pl.expiry_date is null or pl.expiry_date >= current_date)
              order by pl.supplier_id, pl.effective_date desc
            ) q), '[]'::jsonb),
          'pembelian_terakhir', (
            select jsonb_build_object('supplier_id', s.id, 'supplier', s.name, 'harga', gi.unit_price, 'satuan', un.code, 'tanggal', g.receipt_date)
            from pur_goods_receipt_items gi join pur_goods_receipts g on g.id = gi.goods_receipt_id
            join pur_suppliers s on s.id = g.supplier_id join inv_units un on un.id = gi.unit_id
            where gi.item_id = c.id and g.company_id = v_company and g.status = 'posted'
            order by g.receipt_date desc limit 1)
        ) x
        from calc c
        where c.daily > 0 or c.stock <= c.min_qty
        limit 80
      ) t
    ), '[]'::jsonb));
end $$;

create or replace function ai_create_purchase_order(p jsonb, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_sup     pur_suppliers%rowtype;
  v_wh      inv_warehouses%rowtype;
  v_item    inv_items%rowtype;
  v_po      uuid;
  r         jsonb;
  v_lines   jsonb := '[]'::jsonb;
  v_total   numeric := 0;
  v_unit    uuid;
  v_conv    numeric;
  v_qty     numeric;
  v_price   numeric;
  v_src     text;
  v_warn    text[] := '{}';
  v_res     jsonb;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin membuat PO'; end if;
  select * into v_sup from pur_suppliers where id = nullif(p->>'supplier_id', '')::uuid and company_id = v_company;
  if not found then raise exception 'Supplier tidak ditemukan'; end if;
  select * into v_wh from inv_warehouses where id = nullif(p->>'warehouse_id', '')::uuid and company_id = v_company;
  if not found then raise exception 'Gudang tidak ditemukan'; end if;
  if not sys_can_access_warehouse(v_wh.id) then raise exception 'Tidak punya akses ke gudang %', v_wh.name; end if;
  if jsonb_array_length(coalesce(p->'items', '[]'::jsonb)) = 0 then raise exception 'Item PO masih kosong'; end if;

  for r in select * from jsonb_array_elements(p->'items') loop
    select * into v_item from inv_items where id = nullif(r->>'item_id', '')::uuid and company_id = v_company and is_active;
    if not found then raise exception 'Bahan % tidak ditemukan', coalesce(r->>'nama', r->>'item_id'); end if;
    -- satuan: yang diminta, satuan beli, atau satuan dasar
    v_unit := coalesce(nullif(r->>'unit_id', '')::uuid, (select unit_id from inv_item_units where item_id = v_item.id and is_purchase_unit), v_item.base_unit_id);
    v_conv := case when v_unit = v_item.base_unit_id then 1 else (select conversion_qty from inv_item_units where item_id = v_item.id and unit_id = v_unit) end;
    if v_conv is null then raise exception 'Satuan untuk % tidak terdaftar di Master Produk', v_item.name; end if;
    v_qty := nullif(r->>'qty', '')::numeric;
    if coalesce(v_qty, 0) <= 0 then raise exception 'Qty % harus lebih dari 0', v_item.name; end if;
    v_price := nullif(r->>'harga', '')::numeric;
    v_src := 'diisi Semar';
    if v_price is null then
      v_res := pur_get_item_price(v_sup.id, v_item.id, v_unit, v_wh.outlet_id);
      v_price := (v_res->'pricelist'->>'price')::numeric; v_src := 'pricelist';
      if v_price is null then v_price := (v_res->'last'->>'price')::numeric; v_src := 'pembelian terakhir'; end if;
      if v_price is null then v_price := round(v_item.last_purchase_cost * v_conv, 2); v_src := 'harga beli terakhir bahan'; end if;
    end if;
    if coalesce(v_price, 0) = 0 then v_warn := v_warn || format('Harga %s masih 0, isi pricelist atau harga manual', v_item.name); end if;
    v_lines := v_lines || jsonb_build_object(
      'item_id', v_item.id, 'nama', v_item.name, 'unit_id', v_unit, 'satuan', (select code from inv_units where id = v_unit),
      'conversion_qty', v_conv, 'qty', v_qty, 'harga', coalesce(v_price, 0), 'sumber_harga', v_src,
      'subtotal', round(v_qty * coalesce(v_price, 0), 2));
    v_total := v_total + round(v_qty * coalesce(v_price, 0), 2);
  end loop;

  if p_dry_run then
    return jsonb_build_object('supplier', v_sup.name, 'gudang', v_wh.name, 'items', v_lines, 'total', v_total, 'peringatan', to_jsonb(v_warn),
                              'akan_diajukan', coalesce((p->>'submit')::boolean, false));
  end if;

  insert into pur_purchase_orders (company_id, supplier_id, warehouse_id, expected_date, note, created_by)
  values (v_company, v_sup.id, v_wh.id, nullif(p->>'expected_date', '')::date, coalesce(nullif(p->>'note', ''), 'Dibuat oleh Semar (AI)'), auth.uid())
  returning id into v_po;
  insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
  select v_company, v_po, (l->>'item_id')::uuid, (l->>'unit_id')::uuid, (l->>'conversion_qty')::numeric,
         (l->>'qty')::numeric, (l->>'harga')::numeric, (l->>'subtotal')::numeric
  from jsonb_array_elements(v_lines) l;

  if coalesce((p->>'submit')::boolean, false) then
    v_res := pur_approve_purchase_order(v_po);
    return jsonb_build_object('id', v_po, 'po_number', v_res->>'po_number', 'total', v_total,
      'status', case when coalesce((v_res->>'pending_approval')::boolean, false) or v_res->>'status' = 'pending_approval'
                     then 'menunggu persetujuan' else 'disetujui' end);
  end if;
  return jsonb_build_object('id', v_po, 'po_number', null, 'status', 'draft', 'total', v_total);
end $$;

-- >>>>>>>>>> migrations/033_hr_employees.sql
-- =====================================================================
-- SANTAP ERP - 033: SDM / HR FASE A - DATA KARYAWAN, STRUKTUR, PENGUMUMAN
--   * hr_departments, hr_positions: struktur organisasi (jabatan bisa punya role default).
--   * hr_employees: biodata lengkap karyawan; bisa ditautkan ke akun login (sys_users) 1:1.
--     Data sensitif (KTP, NPWP, BPJS, alamat) hanya terbaca oleh hr.view / hr.manage
--     dan oleh karyawan itu sendiri. Rekan kerja hanya melihat direktori (nama, jabatan, outlet).
--   * hr_employee_documents + bucket privat 'hr-files' (scan KTP, kontrak, sertifikat, foto).
--   * hr_announcements: pengumuman untuk semua / per outlet / per role, dengan tanda sudah dibaca.
--   Izin baru: hr.view (lihat data karyawan), hr.manage (kelola karyawan, struktur, pengumuman).
-- =====================================================================

create table hr_departments (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text not null,
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);
select sys_apply_company_policies('hr_departments', 'hr.manage');

create table hr_positions (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  department_id    uuid references hr_departments(id) on delete set null,
  code             text not null,
  name             text not null,
  default_role_id  uuid references sys_roles(id) on delete set null,   -- role saat dibuatkan akun login
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, code)
);
select sys_apply_company_policies('hr_positions', 'hr.manage');

create table hr_employees (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references sys_companies(id),
  employee_number       text,                                   -- otomatis EMP-0001
  user_id               uuid unique references sys_users(id) on delete set null,
  -- pribadi
  full_name             text not null check (trim(full_name) <> ''),
  nickname              text,
  photo_path            text,                                   -- di bucket hr-files
  gender                text check (gender in ('L', 'P')),
  birth_place           text,
  birth_date            date,
  religion              text,
  marital_status        text check (marital_status in ('single', 'married', 'divorced', 'widowed')),
  blood_type            text,
  -- identitas (sensitif)
  national_id           text,                                   -- No. KTP
  tax_number            text,                                   -- NPWP
  bpjs_kesehatan        text,
  bpjs_ketenagakerjaan  text,
  -- kontak
  phone                 text,
  email                 text,
  address_ktp           text,
  address_domicile      text,
  emergency_name        text,
  emergency_relation    text,
  emergency_phone       text,
  -- pekerjaan
  department_id         uuid references hr_departments(id) on delete set null,
  position_id           uuid references hr_positions(id) on delete set null,
  outlet_id             uuid references sys_outlets(id) on delete set null,
  manager_id            uuid references hr_employees(id) on delete set null,
  employment_status     text not null default 'permanent' check (employment_status in ('permanent', 'contract', 'probation', 'intern', 'daily')),
  join_date             date,
  contract_end_date     date,
  resign_date           date,
  is_active             boolean not null default true,
  -- riwayat
  education             jsonb not null default '[]',           -- [{level, school, major, year}]
  experience            jsonb not null default '[]',           -- [{company, position, from, to}]
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, employee_number),
  check (contract_end_date is null or join_date is null or contract_end_date >= join_date)
);
alter table hr_employees enable row level security;
create policy hr_employees_select on hr_employees for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('hr.view') or sys_has_permission('hr.manage') or user_id = auth.uid()));
create policy hr_employees_insert on hr_employees for insert to authenticated
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
create policy hr_employees_update on hr_employees for update to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage')) with check (company_id = sys_current_company_id());
create policy hr_employees_delete on hr_employees for delete to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
-- HR dengan akses branch tertentu hanya mengelola karyawan branch-nya
select sys_apply_outlet_lock('hr_employees', 'user_id = auth.uid() or outlet_id is null or sys_can_access_outlet(outlet_id)');

-- nomor karyawan otomatis
create or replace function hr_set_employee_number()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(new.employee_number), '') = '' then
    new.employee_number := 'EMP-' || lpad(sys_next_sequence(new.company_id, 'EMP')::text, 4, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_hr_employees_number before insert or update on hr_employees
  for each row execute function hr_set_employee_number();
-- audit tanpa menyalin data sensitif ke log aktivitas
create trigger trg_hr_employees_audit after insert or update or delete on hr_employees
  for each row execute function sys_audit_trigger('national_id,tax_number,bpjs_kesehatan,bpjs_ketenagakerjaan,address_ktp,birth_date');
create trigger trg_hr_departments_audit after insert or update or delete on hr_departments for each row execute function sys_audit_trigger('');
create trigger trg_hr_positions_audit after insert or update or delete on hr_positions for each row execute function sys_audit_trigger('');

create table hr_employee_documents (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  employee_id  uuid not null references hr_employees(id) on delete cascade,
  doc_type     text not null default 'lainnya',    -- ktp / kontrak / sertifikat / ijazah / lainnya
  name         text not null,
  file_path    text not null,                       -- hr-files/<company>/<employee>/<file>
  expiry_date  date,
  created_by   uuid references sys_users(id),
  created_at   timestamptz not null default now()
);
alter table hr_employee_documents enable row level security;
create policy hr_employee_documents_select on hr_employee_documents for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
create policy hr_employee_documents_write on hr_employee_documents for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));

-- ---------------------------------------------------------------------
-- STORAGE PRIVAT: hr-files/<company_id>/<employee_id>/<file>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hr-files', 'hr-files', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create or replace function hr_can_read_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
          or exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid()))
$$;
create or replace function hr_can_write_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text and sys_has_permission('hr.manage')
$$;
create policy hr_files_select on storage.objects for select to authenticated using (bucket_id = 'hr-files' and hr_can_read_file(name));
create policy hr_files_insert on storage.objects for insert to authenticated with check (bucket_id = 'hr-files' and hr_can_write_file(name));
create policy hr_files_update on storage.objects for update to authenticated using (bucket_id = 'hr-files' and hr_can_write_file(name));
create policy hr_files_delete on storage.objects for delete to authenticated using (bucket_id = 'hr-files' and hr_can_write_file(name));

-- ---------------------------------------------------------------------
-- DIREKTORI & PROFIL SAYA
-- ---------------------------------------------------------------------
-- direktori karyawan (tanpa data sensitif), untuk semua user di perusahaan
create or replace function hr_directory()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name, 'nickname', e.nickname,
    'photo_path', e.photo_path, 'position', p.name, 'department', d.name, 'outlet', o.name, 'phone', e.phone,
    'has_account', e.user_id is not null) order by e.full_name), '[]'::jsonb)
  from hr_employees e
  left join hr_positions p on p.id = e.position_id
  left join hr_departments d on d.id = e.department_id
  left join sys_outlets o on o.id = e.outlet_id
  where e.company_id = sys_current_company_id() and e.is_active and sys_current_company_id() is not null
$$;

-- data karyawan milik user yang login
create or replace function hr_my_employee()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(e) || jsonb_build_object('position', p.name, 'department', d.name, 'outlet', o.name, 'manager', m.full_name)
  from hr_employees e
  left join hr_positions p on p.id = e.position_id
  left join hr_departments d on d.id = e.department_id
  left join sys_outlets o on o.id = e.outlet_id
  left join hr_employees m on m.id = e.manager_id
  where e.user_id = auth.uid() and e.company_id = sys_current_company_id()
$$;

-- karyawan boleh mengubah sebagian datanya sendiri
create or replace function hr_update_my_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  update hr_employees set
    nickname = coalesce(p->>'nickname', nickname),
    phone = coalesce(p->>'phone', phone),
    email = coalesce(p->>'email', email),
    address_domicile = coalesce(p->>'address_domicile', address_domicile),
    emergency_name = coalesce(p->>'emergency_name', emergency_name),
    emergency_relation = coalesce(p->>'emergency_relation', emergency_relation),
    emergency_phone = coalesce(p->>'emergency_phone', emergency_phone)
  where user_id = auth.uid() and company_id = sys_current_company_id()
  returning id into v_id;
  if v_id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  return hr_my_employee();
end $$;

-- tautkan / lepas akun login dari data karyawan
create or replace function hr_link_user(p_employee_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (sys_has_permission('hr.manage') and sys_has_permission('user.manage')) then raise exception 'Butuh izin kelola karyawan & user'; end if;
  if not exists (select 1 from hr_employees where id = p_employee_id and company_id = v_company) then raise exception 'Karyawan tidak ditemukan'; end if;
  if p_user_id is not null then
    if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then raise exception 'User tidak ditemukan'; end if;
    if exists (select 1 from hr_employees where user_id = p_user_id and id <> p_employee_id) then raise exception 'Akun ini sudah tertaut ke karyawan lain'; end if;
  end if;
  update hr_employees set user_id = p_user_id where id = p_employee_id;
end $$;

-- pengingat HR: kontrak hampir habis & ulang tahun bulan ini
create or replace function hr_reminders()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not (sys_has_permission('hr.view') or sys_has_permission('hr.manage')) then '{}'::jsonb else jsonb_build_object(
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'contract_end_date', contract_end_date) order by contract_end_date)
                  from hr_employees where company_id = sys_current_company_id() and is_active and contract_end_date between current_date and current_date + 30), '[]'::jsonb),
    'birthdays', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'day', extract(day from birth_date)) order by extract(day from birth_date))
                  from hr_employees where company_id = sys_current_company_id() and is_active and extract(month from birth_date) = extract(month from current_date)), '[]'::jsonb))
  end
$$;

-- ---------------------------------------------------------------------
-- PENGUMUMAN
-- ---------------------------------------------------------------------
create table hr_announcements (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  title         text not null check (trim(title) <> ''),
  body          text not null default '',
  audience      text not null default 'all' check (audience in ('all', 'outlet', 'role')),
  outlet_ids    uuid[] not null default '{}',
  role_ids      uuid[] not null default '{}',
  pinned        boolean not null default false,
  published_at  timestamptz not null default now(),
  expires_at    timestamptz,
  created_by    uuid references sys_users(id) default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
select sys_apply_company_policies('hr_announcements', 'hr.manage');

create table hr_announcement_reads (
  announcement_id  uuid not null references hr_announcements(id) on delete cascade,
  user_id          uuid not null references sys_users(id) on delete cascade,
  read_at          timestamptz not null default now(),
  primary key (announcement_id, user_id)
);
alter table hr_announcement_reads enable row level security;
create policy hr_announcement_reads_own on hr_announcement_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- pengumuman yang ditujukan untuk user ini (semua / outlet-nya / role-nya)
create or replace function hr_my_announcements()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'title', a.title, 'body', a.body, 'pinned', a.pinned, 'published_at', a.published_at,
    'author', (select full_name from sys_users where id = a.created_by),
    'read', exists (select 1 from hr_announcement_reads r where r.announcement_id = a.id and r.user_id = auth.uid()))
    order by a.pinned desc, a.published_at desc), '[]'::jsonb)
  from hr_announcements a
  where a.company_id = sys_current_company_id() and a.published_at <= now() and (a.expires_at is null or a.expires_at > now())
    and (a.audience = 'all'
      or (a.audience = 'outlet' and exists (select 1 from unnest(a.outlet_ids) o where sys_can_access_outlet(o)))
      or (a.audience = 'role' and (sys_has_permission('*') or (select role_id from sys_users where id = auth.uid()) = any(a.role_ids))))
$$;

create or replace function hr_mark_announcement_read(p_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into hr_announcement_reads (announcement_id, user_id)
  select p_id, auth.uid() where exists (select 1 from hr_announcements where id = p_id and company_id = sys_current_company_id())
  on conflict do nothing
$$;

-- jumlah yang sudah membaca (untuk HR)
create or replace function hr_announcement_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(a.id, (select count(*) from hr_announcement_reads r where r.announcement_id = a.id)), '{}'::jsonb)
  from hr_announcements a where a.company_id = sys_current_company_id() and sys_has_permission('hr.manage')
$$;

-- ---------------------------------------------------------------------
-- Semar boleh membantu migrasi data karyawan & struktur (tetap lewat usulan + persetujuan owner)
-- ---------------------------------------------------------------------
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers',
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements']
$$;

-- >>>>>>>>>> migrations/034_hr_attendance.sql
-- =====================================================================
-- SEMAR - 034: SDM / HR FASE B - ABSENSI FOTO + GPS, JADWAL SHIFT, KOREKSI
--   * sys_outlets: titik lokasi (lat/lng) + radius absen (geofence).
--   * hr_settings: aturan absensi per perusahaan (toleransi telat, wajib foto / GPS).
--   * hr_shifts: template shift (Pagi 07-15, Malam 22-06, ...). hr_rosters: jadwal per hari.
--   * hr_attendances: absen masuk/pulang dengan selfie + GPS. Jam diambil dari SERVER,
--     jarak ke outlet dihitung di SERVER. Di luar radius tetap tercatat tapi ditandai
--     untuk direview HR / atasan.
--   * hr_attendance_corrections: pengajuan koreksi absen (lupa absen, HP mati) + persetujuan.
--   Izin baru: hr.attendance (kelola jadwal shift & review absensi).
-- =====================================================================

alter table sys_outlets add column if not exists geo_lat numeric(9, 6);
alter table sys_outlets add column if not exists geo_lng numeric(9, 6);
alter table sys_outlets add column if not exists geo_radius_m int not null default 100 check (geo_radius_m between 10 and 5000);

-- yang boleh mengatur jadwal & mereview absensi
create or replace function hr_can_schedule()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('hr.manage') or sys_has_permission('hr.attendance')
$$;

-- ---------------------------------------------------------------------
-- PENGATURAN
-- ---------------------------------------------------------------------
create table hr_settings (
  company_id              uuid primary key references sys_companies(id),
  late_tolerance_minutes  int not null default 10 check (late_tolerance_minutes between 0 and 240),
  require_photo           boolean not null default true,
  require_gps             boolean not null default true,
  max_gps_accuracy_m      int not null default 150 check (max_gps_accuracy_m between 10 and 5000),
  updated_at              timestamptz not null default now()
);
select sys_apply_company_policies('hr_settings', 'hr.manage');

create or replace function hr_get_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select to_jsonb(s) - 'company_id' - 'updated_at' from hr_settings s where s.company_id = sys_current_company_id()),
    jsonb_build_object('late_tolerance_minutes', 10, 'require_photo', true, 'require_gps', true, 'max_gps_accuracy_m', 150))
$$;

-- ---------------------------------------------------------------------
-- TEMPLATE SHIFT & JADWAL
-- ---------------------------------------------------------------------
create table hr_shifts (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  code           text not null,
  name           text not null,
  start_time     time not null,
  end_time       time not null,                 -- lebih kecil dari start_time = lewat tengah malam
  break_minutes  int not null default 60 check (break_minutes >= 0),
  color          text not null default '#4ABDAC',
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, code)
);
alter table hr_shifts enable row level security;
create policy hr_shifts_select on hr_shifts for select to authenticated using (company_id = sys_current_company_id());
create policy hr_shifts_write on hr_shifts for all to authenticated
  using (company_id = sys_current_company_id() and hr_can_schedule())
  with check (company_id = sys_current_company_id() and hr_can_schedule());

create table hr_rosters (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  employee_id  uuid not null references hr_employees(id) on delete cascade,
  work_date    date not null,
  outlet_id    uuid references sys_outlets(id) on delete set null,   -- tempat kerja hari itu
  shift_id     uuid references hr_shifts(id) on delete set null,
  is_off       boolean not null default false,                       -- libur terjadwal
  note         text,
  updated_at   timestamptz not null default now(),
  unique (employee_id, work_date),
  check (is_off or shift_id is not null)
);
alter table hr_rosters enable row level security;
create policy hr_rosters_select on hr_rosters for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
create policy hr_rosters_write on hr_rosters for all to authenticated
  using (company_id = sys_current_company_id() and hr_can_schedule())
  with check (company_id = sys_current_company_id() and hr_can_schedule());
select sys_apply_outlet_lock('hr_rosters', 'outlet_id is null or sys_can_access_outlet(outlet_id) or employee_id in (select id from hr_employees where user_id = auth.uid())');

-- jadwal seorang karyawan pada tanggal tertentu (jam mulai/selesai sudah dalam zona waktu outlet)
create or replace function hr_schedule_for(p_employee_id uuid, p_date date)
returns jsonb language sql stable security definer set search_path = public as $$
  with e as (select id, outlet_id from hr_employees where id = p_employee_id),
  r as (select * from hr_rosters where employee_id = p_employee_id and work_date = p_date),
  o as (select o.* from sys_outlets o where o.id = coalesce((select outlet_id from r), (select outlet_id from e)))
  select jsonb_build_object(
    'work_date', p_date,
    'outlet_id', (select id from o), 'outlet', (select name from o),
    'geo_lat', (select geo_lat from o), 'geo_lng', (select geo_lng from o), 'geo_radius_m', (select geo_radius_m from o),
    'is_off', coalesce((select is_off from r), false),
    'has_roster', exists (select 1 from r),
    'shift_id', s.id, 'shift', s.name, 'shift_color', s.color, 'start_time', s.start_time, 'end_time', s.end_time,
    'scheduled_start', case when s.id is not null then (p_date + s.start_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end,
    'scheduled_end', case when s.id is not null then (p_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end)
  from (select 1) x
  left join r on true
  left join hr_shifts s on s.id = r.shift_id and not r.is_off
$$;

-- papan jadwal (untuk HR / kepala outlet): karyawan, jadwal, template shift
create or replace function hr_roster_board(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not hr_can_schedule() then raise exception 'Butuh izin kelola jadwal & absensi'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Rentang tanggal maksimal 2 bulan'; end if;
  return jsonb_build_object(
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name,
        'nickname', e.nickname, 'photo_path', e.photo_path, 'position', p.name, 'outlet_id', e.outlet_id, 'outlet', o.name) order by o.name nulls first, e.full_name)
      from hr_employees e left join hr_positions p on p.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
      where e.company_id = v_company and e.is_active
        and (p_outlet_id is null or e.outlet_id = p_outlet_id)
        and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('employee_id', r.employee_id, 'work_date', r.work_date, 'shift_id', r.shift_id,
        'is_off', r.is_off, 'outlet_id', r.outlet_id, 'note', r.note))
      from hr_rosters r where r.company_id = v_company and r.work_date between p_from and p_to), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(s) order by s.start_time) from hr_shifts s where s.company_id = v_company and s.is_active), '[]'::jsonb));
end $$;

-- simpan banyak sel jadwal sekaligus: [{employee_id, work_date, shift_id | null, is_off}]
-- shift_id null & is_off false = hapus jadwal hari itu
create or replace function hr_roster_save(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id(); r jsonb; v_emp hr_employees; v_n int := 0; v_shift uuid; v_off boolean;
begin
  if not hr_can_schedule() then raise exception 'Butuh izin kelola jadwal & absensi'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    select * into v_emp from hr_employees where id = (r->>'employee_id')::uuid and company_id = v_company;
    if v_emp.id is null then raise exception 'Karyawan tidak ditemukan'; end if;
    if v_emp.outlet_id is not null and not sys_can_access_outlet(v_emp.outlet_id) then raise exception 'Tidak punya akses ke outlet karyawan %', v_emp.full_name; end if;
    v_shift := nullif(r->>'shift_id', '')::uuid;
    v_off := coalesce((r->>'is_off')::boolean, false);
    if v_shift is not null and not exists (select 1 from hr_shifts where id = v_shift and company_id = v_company) then raise exception 'Shift tidak ditemukan'; end if;
    if v_shift is null and not v_off then
      delete from hr_rosters where employee_id = v_emp.id and work_date = (r->>'work_date')::date;
    else
      insert into hr_rosters (company_id, employee_id, work_date, outlet_id, shift_id, is_off, note)
      values (v_company, v_emp.id, (r->>'work_date')::date, coalesce(nullif(r->>'outlet_id', '')::uuid, v_emp.outlet_id),
              case when v_off then null else v_shift end, v_off, nullif(r->>'note', ''))
      on conflict (employee_id, work_date) do update set
        shift_id = excluded.shift_id, is_off = excluded.is_off, outlet_id = excluded.outlet_id, note = excluded.note, updated_at = now();
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- salin jadwal satu minggu ke minggu lain (template mingguan)
create or replace function hr_roster_copy_week(p_from_week date, p_to_week date, p_outlet_id uuid default null, p_overwrite boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id(); v_n int;
begin
  if not hr_can_schedule() then raise exception 'Butuh izin kelola jadwal & absensi'; end if;
  if p_from_week = p_to_week then raise exception 'Minggu asal dan tujuan sama'; end if;
  with src as (
    select r.* from hr_rosters r join hr_employees e on e.id = r.employee_id
    where r.company_id = v_company and r.work_date between p_from_week and p_from_week + 6 and e.is_active
      and (p_outlet_id is null or e.outlet_id = p_outlet_id)
      and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))
  ), ins as (
    insert into hr_rosters (company_id, employee_id, work_date, outlet_id, shift_id, is_off, note)
    select v_company, employee_id, p_to_week + (work_date - p_from_week), outlet_id, shift_id, is_off, note from src
    on conflict (employee_id, work_date) do update set
      shift_id = excluded.shift_id, is_off = excluded.is_off, outlet_id = excluded.outlet_id, note = excluded.note, updated_at = now()
      where p_overwrite
    returning 1
  ) select count(*) into v_n from ins;
  return v_n;
end $$;

-- jadwal saya
create or replace function hr_my_roster(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(hr_schedule_for(e.id, d::date) order by d), '[]'::jsonb)
  from hr_employees e, generate_series(p_from, least(p_to, p_from + 62), interval '1 day') d
  where e.user_id = auth.uid() and e.company_id = sys_current_company_id()
$$;

-- ---------------------------------------------------------------------
-- ABSENSI
-- ---------------------------------------------------------------------
create table hr_attendances (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references sys_companies(id),
  employee_id           uuid not null references hr_employees(id) on delete cascade,
  work_date             date not null,
  outlet_id             uuid references sys_outlets(id) on delete set null,
  shift_id              uuid references hr_shifts(id) on delete set null,
  scheduled_start       timestamptz,
  scheduled_end         timestamptz,
  -- masuk
  check_in_at           timestamptz,
  check_in_lat          numeric(9, 6),
  check_in_lng          numeric(9, 6),
  check_in_accuracy_m   numeric(8, 1),
  check_in_distance_m   int,
  check_in_photo        text,                                  -- hr-files/<company>/<employee>/attendance/...
  -- pulang
  check_out_at          timestamptz,
  check_out_lat         numeric(9, 6),
  check_out_lng         numeric(9, 6),
  check_out_accuracy_m  numeric(8, 1),
  check_out_distance_m  int,
  check_out_photo       text,
  -- hasil
  late_minutes          int not null default 0,
  early_leave_minutes   int not null default 0,
  flags                 text[] not null default '{}',          -- outside_radius / low_accuracy / day_off / no_geofence / corrected
  review_status         text not null default 'none' check (review_status in ('none', 'pending', 'approved', 'rejected')),
  reviewed_by           uuid references sys_users(id),
  reviewed_at           timestamptz,
  review_note           text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (employee_id, work_date),
  check (check_out_at is null or check_in_at is null or check_out_at >= check_in_at)
);
create index hr_attendances_company_date on hr_attendances (company_id, work_date);
alter table hr_attendances enable row level security;
create policy hr_attendances_select on hr_attendances for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
-- karyawan TIDAK bisa menulis langsung: absen lewat hr_clock(), koreksi lewat pengajuan
create policy hr_attendances_write on hr_attendances for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
select sys_apply_outlet_lock('hr_attendances', 'outlet_id is null or sys_can_access_outlet(outlet_id) or employee_id in (select id from hr_employees where user_id = auth.uid())');

-- hitung ulang telat / pulang cepat setiap kali jam berubah
create or replace function hr_attendance_compute()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tol int;
begin
  select coalesce((select late_tolerance_minutes from hr_settings where company_id = new.company_id), 10) into v_tol;
  new.late_minutes := case when new.check_in_at is not null and new.scheduled_start is not null
      and new.check_in_at > new.scheduled_start + make_interval(mins => v_tol)
    then floor(extract(epoch from new.check_in_at - new.scheduled_start) / 60)::int else 0 end;
  new.early_leave_minutes := case when new.check_out_at is not null and new.scheduled_end is not null and new.check_out_at < new.scheduled_end
    then ceil(extract(epoch from new.scheduled_end - new.check_out_at) / 60)::int else 0 end;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_hr_attendances_compute before insert or update on hr_attendances
  for each row execute function hr_attendance_compute();

-- jarak dua titik GPS (meter, rumus haversine)
create or replace function hr_distance_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns int language sql immutable as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null else
    round(2 * 6371000 * asin(sqrt(
      power(sin(radians((lat2 - lat1)::float8) / 2), 2)
      + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lng2 - lng1)::float8) / 2), 2))))::int end
$$;

-- absen masuk / pulang. Jam & jarak dihitung server; foto harus sudah diunggah ke folder absensi milik sendiri.
create or replace function hr_clock(p_kind text, p_lat numeric, p_lng numeric, p_accuracy numeric, p_photo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_emp hr_employees; v_set jsonb := hr_get_settings(); v_sched jsonb; v_att hr_attendances;
  v_date date; v_tz text; v_dist int; v_flags text[] := '{}';
begin
  if p_kind not in ('in', 'out') then raise exception 'Jenis absen tidak dikenal'; end if;
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = v_company;
  if v_emp.id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  if not v_emp.is_active then raise exception 'Data karyawan Anda tidak aktif'; end if;
  if (v_set->>'require_gps')::boolean and (p_lat is null or p_lng is null) then raise exception 'Lokasi GPS wajib aktif untuk absen'; end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then raise exception 'Koordinat GPS tidak valid'; end if;
  if p_photo is not null then
    if p_photo not like v_company || '/' || v_emp.id || '/attendance/%' then raise exception 'Foto absen tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'hr-files' and name = p_photo) then raise exception 'Foto absen belum terunggah'; end if;
  elsif (v_set->>'require_photo')::boolean then
    raise exception 'Foto selfie wajib untuk absen';
  end if;

  if p_kind = 'in' then
    select coalesce(o.timezone, 'Asia/Jakarta') into v_tz from (select 1) x left join sys_outlets o on o.id = v_emp.outlet_id;
    v_date := (now() at time zone v_tz)::date;
    -- shift malam: kalau kemarin ada shift lewat tengah malam yang belum dimulai, pakai tanggal kemarin
    v_sched := hr_schedule_for(v_emp.id, v_date - 1);
    if (v_sched->>'scheduled_end')::timestamptz > now() and (v_sched->>'scheduled_start')::timestamptz < now() + interval '3 hours'
       and not exists (select 1 from hr_attendances where employee_id = v_emp.id and work_date = v_date - 1) then
      v_date := v_date - 1;
    else
      v_sched := hr_schedule_for(v_emp.id, v_date);
    end if;
    if exists (select 1 from hr_attendances where employee_id = v_emp.id and work_date = v_date and check_in_at is not null) then
      raise exception 'Anda sudah absen masuk hari ini';
    end if;
  else
    -- pulang: absen masuk terakhir yang belum ditutup (maks. 20 jam lalu)
    select * into v_att from hr_attendances
    where employee_id = v_emp.id and check_in_at is not null and check_out_at is null and check_in_at > now() - interval '20 hours'
    order by check_in_at desc limit 1;
    if v_att.id is null then raise exception 'Belum ada absen masuk yang bisa ditutup'; end if;
    v_date := v_att.work_date;
    v_sched := hr_schedule_for(v_emp.id, v_date);
    v_flags := v_att.flags;
  end if;

  -- geofence
  if (v_sched->>'geo_lat') is null then
    v_flags := array(select distinct unnest(v_flags || array['no_geofence']));
  else
    v_dist := hr_distance_m(p_lat, p_lng, (v_sched->>'geo_lat')::numeric, (v_sched->>'geo_lng')::numeric);
    if v_dist is not null and v_dist > (v_sched->>'geo_radius_m')::int then
      v_flags := array(select distinct unnest(v_flags || array['outside_radius']));
    end if;
  end if;
  if p_accuracy is not null and p_accuracy > (v_set->>'max_gps_accuracy_m')::numeric then
    v_flags := array(select distinct unnest(v_flags || array['low_accuracy']));
  end if;
  if (v_sched->>'is_off')::boolean then v_flags := array(select distinct unnest(v_flags || array['day_off'])); end if;

  if p_kind = 'in' then
    insert into hr_attendances (company_id, employee_id, work_date, outlet_id, shift_id, scheduled_start, scheduled_end,
      check_in_at, check_in_lat, check_in_lng, check_in_accuracy_m, check_in_distance_m, check_in_photo, flags, review_status)
    values (v_company, v_emp.id, v_date, (v_sched->>'outlet_id')::uuid, (v_sched->>'shift_id')::uuid,
      (v_sched->>'scheduled_start')::timestamptz, (v_sched->>'scheduled_end')::timestamptz,
      now(), p_lat, p_lng, p_accuracy, v_dist, p_photo, v_flags,
      case when v_flags && array['outside_radius', 'low_accuracy', 'day_off'] then 'pending' else 'none' end)
    on conflict (employee_id, work_date) do update set
      check_in_at = excluded.check_in_at, check_in_lat = excluded.check_in_lat, check_in_lng = excluded.check_in_lng,
      check_in_accuracy_m = excluded.check_in_accuracy_m, check_in_distance_m = excluded.check_in_distance_m,
      check_in_photo = excluded.check_in_photo, flags = excluded.flags, review_status = excluded.review_status
    returning * into v_att;
  else
    update hr_attendances set check_out_at = now(), check_out_lat = p_lat, check_out_lng = p_lng, check_out_accuracy_m = p_accuracy,
      check_out_distance_m = v_dist, check_out_photo = p_photo, flags = v_flags,
      -- tanda baru saat pulang (mis. pulang di luar radius) perlu direview lagi
      review_status = case when not (v_att.flags @> v_flags) and v_flags && array['outside_radius', 'low_accuracy', 'day_off'] then 'pending' else review_status end
    where id = v_att.id returning * into v_att;
  end if;
  return to_jsonb(v_att);
end $$;

-- status absen hari ini untuk Beranda Saya
create or replace function hr_attendance_today()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_emp hr_employees; v_att hr_attendances; v_tz text; v_date date;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id();
  if v_emp.id is null then return null; end if;
  -- absen yang masih terbuka (mis. shift malam) didahulukan
  select * into v_att from hr_attendances
  where employee_id = v_emp.id and check_in_at is not null and check_out_at is null and check_in_at > now() - interval '20 hours'
  order by check_in_at desc limit 1;
  if v_att.id is not null then
    v_date := v_att.work_date;
  else
    select coalesce(o.timezone, 'Asia/Jakarta') into v_tz from (select 1) x left join sys_outlets o on o.id = v_emp.outlet_id;
    v_date := (now() at time zone v_tz)::date;
    select * into v_att from hr_attendances where employee_id = v_emp.id and work_date = v_date;
  end if;
  return jsonb_build_object(
    'employee_id', v_emp.id, 'work_date', v_date, 'server_time', now(),
    'schedule', hr_schedule_for(v_emp.id, v_date),
    'attendance', case when v_att.id is not null then to_jsonb(v_att) end,
    'settings', hr_get_settings());
end $$;

-- rekap absensi (HR / kepala outlet): satu baris per karyawan per hari, termasuk alpa (dijadwalkan tapi tidak absen)
create or replace function hr_attendance_recap(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (hr_can_schedule() or sys_has_permission('hr.view')) then raise exception 'Butuh izin lihat absensi'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Rentang tanggal maksimal 2 bulan'; end if;
  return coalesce((
    with days as (
      select coalesce(a.employee_id, r.employee_id) as employee_id, coalesce(a.work_date, r.work_date) as work_date, a.id as att_id, r.id as roster_id
      from (select * from hr_attendances where company_id = v_company and work_date between p_from and p_to) a
      full join (select * from hr_rosters where company_id = v_company and work_date between p_from and p_to) r
        on r.employee_id = a.employee_id and r.work_date = a.work_date
    )
    select jsonb_agg(jsonb_build_object(
      'employee_id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name, 'position', p.name,
      'work_date', d.work_date, 'outlet_id', coalesce(a.outlet_id, r.outlet_id, e.outlet_id), 'outlet', o.name,
      'shift', s.name, 'shift_color', s.color, 'is_off', coalesce(r.is_off, false),
      'scheduled_start', coalesce(a.scheduled_start, case when s.id is not null then (d.work_date + s.start_time) at time zone coalesce(o.timezone, 'Asia/Jakarta') end),
      'attendance_id', a.id, 'check_in_at', a.check_in_at, 'check_out_at', a.check_out_at,
      'check_in_photo', a.check_in_photo, 'check_out_photo', a.check_out_photo,
      'check_in_distance_m', a.check_in_distance_m, 'check_out_distance_m', a.check_out_distance_m,
      'check_in_lat', a.check_in_lat, 'check_in_lng', a.check_in_lng,
      'late_minutes', coalesce(a.late_minutes, 0), 'early_leave_minutes', coalesce(a.early_leave_minutes, 0),
      'flags', coalesce(a.flags, '{}'), 'review_status', coalesce(a.review_status, 'none'), 'review_note', a.review_note,
      'status', case
        when a.check_in_at is not null and a.late_minutes > 0 then 'late'
        when a.check_in_at is not null then 'present'
        when coalesce(r.is_off, false) then 'off'
        when s.id is not null and (d.work_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce(o.timezone, 'Asia/Jakarta') < now() then 'absent'
        else 'scheduled' end)
      order by d.work_date desc, e.full_name)
    from days d
    join hr_employees e on e.id = d.employee_id
    left join hr_attendances a on a.id = d.att_id
    left join hr_rosters r on r.id = d.roster_id
    left join hr_shifts s on s.id = coalesce(a.shift_id, case when not r.is_off then r.shift_id end)
    left join hr_positions p on p.id = e.position_id
    left join sys_outlets o on o.id = coalesce(a.outlet_id, r.outlet_id, e.outlet_id)
    where (p_outlet_id is null or coalesce(a.outlet_id, r.outlet_id, e.outlet_id) = p_outlet_id)
      and (coalesce(a.outlet_id, r.outlet_id, e.outlet_id) is null or sys_can_access_outlet(coalesce(a.outlet_id, r.outlet_id, e.outlet_id)))
  ), '[]'::jsonb);
end $$;

-- review absen yang ditandai (di luar radius, GPS tidak akurat, masuk di hari libur)
create or replace function hr_review_attendance(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_att hr_attendances;
begin
  if not hr_can_schedule() then raise exception 'Butuh izin review absensi'; end if;
  select * into v_att from hr_attendances where id = p_id and company_id = sys_current_company_id();
  if v_att.id is null then raise exception 'Data absen tidak ditemukan'; end if;
  if v_att.outlet_id is not null and not sys_can_access_outlet(v_att.outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if v_att.employee_id in (select id from hr_employees where user_id = auth.uid()) and not sys_has_permission('*') then
    raise exception 'Tidak bisa mereview absen sendiri';
  end if;
  update hr_attendances set review_status = case when p_approve then 'approved' else 'rejected' end,
    review_note = nullif(trim(coalesce(p_note, '')), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- KOREKSI ABSEN (lupa absen, HP mati, salah tekan)
-- ---------------------------------------------------------------------
create table hr_attendance_corrections (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  employee_id   uuid not null references hr_employees(id) on delete cascade,
  work_date     date not null,
  check_in_at   timestamptz,                    -- jam yang diajukan
  check_out_at  timestamptz,
  reason        text not null check (trim(reason) <> ''),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reviewed_by   uuid references sys_users(id),
  reviewed_at   timestamptz,
  review_note   text,
  created_at    timestamptz not null default now(),
  check (check_in_at is not null or check_out_at is not null),
  check (check_out_at is null or check_in_at is null or check_out_at > check_in_at)
);
alter table hr_attendance_corrections enable row level security;
create policy hr_attendance_corrections_select on hr_attendance_corrections for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid())
         or employee_id in (select e.id from hr_employees e join hr_employees m on m.id = e.manager_id where m.user_id = auth.uid())));
-- tulis hanya lewat fungsi di bawah

create or replace function hr_request_correction(p_work_date date, p_check_in timestamptz, p_check_out timestamptz, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_emp hr_employees; v_id uuid;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id();
  if v_emp.id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  if p_work_date > current_date + 1 or p_work_date < current_date - 31 then raise exception 'Koreksi hanya untuk 31 hari terakhir'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan wajib diisi'; end if;
  if p_check_in is null and p_check_out is null then raise exception 'Isi jam masuk atau jam pulang'; end if;
  if greatest(p_check_in, p_check_out) > now() then raise exception 'Jam tidak boleh di masa depan'; end if;
  if exists (select 1 from hr_attendance_corrections where employee_id = v_emp.id and work_date = p_work_date and status = 'pending') then
    raise exception 'Masih ada pengajuan koreksi untuk tanggal ini';
  end if;
  insert into hr_attendance_corrections (company_id, employee_id, work_date, check_in_at, check_out_at, reason)
  values (v_emp.company_id, v_emp.id, p_work_date, p_check_in, p_check_out, trim(p_reason)) returning id into v_id;
  return v_id;
end $$;

-- riwayat absen saya + pengajuan koreksi
create or replace function hr_my_attendance(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  with e as (select id from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id())
  select jsonb_build_object(
    'attendances', coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('shift', s.name) order by a.work_date desc)
      from hr_attendances a left join hr_shifts s on s.id = a.shift_id
      where a.employee_id = (select id from e) and a.work_date between p_from and p_to), '[]'::jsonb),
    'corrections', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc)
      from hr_attendance_corrections c where c.employee_id = (select id from e) and c.created_at > now() - interval '60 days'), '[]'::jsonb))
$$;

create or replace function hr_cancel_correction(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update hr_attendance_corrections set status = 'cancelled'
  where id = p_id and status = 'pending' and employee_id in (select id from hr_employees where user_id = auth.uid())
$$;

-- daftar pengajuan yang bisa saya review (HR / kepala outlet / atasan langsung)
create or replace function hr_correction_inbox(p_status text default 'pending')
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('full_name', e.full_name, 'employee_number', e.employee_number, 'outlet', o.name,
      'current', (select jsonb_build_object('check_in_at', a.check_in_at, 'check_out_at', a.check_out_at) from hr_attendances a
                  where a.employee_id = c.employee_id and a.work_date = c.work_date))
    order by c.created_at desc), '[]'::jsonb)
  from hr_attendance_corrections c
  join hr_employees e on e.id = c.employee_id
  left join sys_outlets o on o.id = e.outlet_id
  where c.company_id = sys_current_company_id() and c.status = p_status
    and (p_status = 'pending' or c.created_at > now() - interval '90 days')
    and ((hr_can_schedule() and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)))
      or exists (select 1 from hr_employees m where m.id = e.manager_id and m.user_id = auth.uid()))
    and e.user_id is distinct from auth.uid()
$$;

create or replace function hr_review_correction(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_c hr_attendance_corrections; v_emp hr_employees; v_sched jsonb;
begin
  select * into v_c from hr_attendance_corrections where id = p_id and company_id = sys_current_company_id() for update;
  if v_c.id is null then raise exception 'Pengajuan tidak ditemukan'; end if;
  if v_c.status <> 'pending' then raise exception 'Pengajuan sudah diproses'; end if;
  select * into v_emp from hr_employees where id = v_c.employee_id;
  if v_emp.user_id = auth.uid() then raise exception 'Tidak bisa menyetujui pengajuan sendiri'; end if;
  if not ((hr_can_schedule() and (v_emp.outlet_id is null or sys_can_access_outlet(v_emp.outlet_id)))
          or exists (select 1 from hr_employees m where m.id = v_emp.manager_id and m.user_id = auth.uid())) then
    raise exception 'Anda bukan atasan / HR karyawan ini';
  end if;
  update hr_attendance_corrections set status = case when p_approve then 'approved' else 'rejected' end,
    reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(coalesce(p_note, '')), '')
  where id = p_id;
  if p_approve then
    v_sched := hr_schedule_for(v_emp.id, v_c.work_date);
    insert into hr_attendances (company_id, employee_id, work_date, outlet_id, shift_id, scheduled_start, scheduled_end,
      check_in_at, check_out_at, flags, review_status, reviewed_by, reviewed_at, review_note)
    values (v_c.company_id, v_emp.id, v_c.work_date, (v_sched->>'outlet_id')::uuid, (v_sched->>'shift_id')::uuid,
      (v_sched->>'scheduled_start')::timestamptz, (v_sched->>'scheduled_end')::timestamptz,
      v_c.check_in_at, v_c.check_out_at, array['corrected'], 'approved', auth.uid(), now(), 'Koreksi: ' || v_c.reason)
    on conflict (employee_id, work_date) do update set
      check_in_at = coalesce(v_c.check_in_at, hr_attendances.check_in_at),
      check_out_at = coalesce(v_c.check_out_at, hr_attendances.check_out_at),
      flags = array(select distinct unnest(hr_attendances.flags || array['corrected'])),
      review_status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = 'Koreksi: ' || v_c.reason;
  end if;
end $$;

-- jumlah yang menunggu review (badge menu)
create or replace function hr_attendance_pending_count()
returns int language sql stable security definer set search_path = public as $$
  select (select count(*) from jsonb_array_elements(hr_correction_inbox('pending')))::int
       + case when hr_can_schedule() then (select count(*) from hr_attendances a
           where a.company_id = sys_current_company_id() and a.review_status = 'pending' and a.work_date > current_date - 31
             and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)))::int else 0 end
$$;

-- ---------------------------------------------------------------------
-- STORAGE: karyawan boleh mengunggah selfie absen ke foldernya sendiri (tidak bisa menghapus / menimpa)
-- reviewer absensi boleh melihat foto
-- ---------------------------------------------------------------------
create or replace function hr_can_upload_own(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (storage.foldername(p_name))[3] = 'attendance'
     and exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid() and e.is_active)
$$;
create policy hr_files_insert_self on storage.objects for insert to authenticated
  with check (bucket_id = 'hr-files' and hr_can_upload_own(name));

create or replace function hr_can_read_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
          or ((storage.foldername(p_name))[3] = 'attendance' and sys_has_permission('hr.attendance'))
          or exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid()))
$$;

create trigger trg_hr_shifts_audit after insert or update or delete on hr_shifts for each row execute function sys_audit_trigger('');
create trigger trg_hr_settings_audit after insert or update or delete on hr_settings for each row execute function sys_audit_trigger('');

-- Semar boleh membantu membuat template shift (tetap lewat usulan + persetujuan owner)
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers',
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements', 'hr_shifts']
$$;

-- >>>>>>>>>> migrations/035_hr_leave.sql
-- =====================================================================
-- SEMAR - 035: SDM / HR FASE C - CUTI & IZIN
--   * hr_leave_types: jenis cuti (tahunan, sakit, izin, menikah, duka, melahirkan) per perusahaan.
--   * Saldo cuti tahunan: hr_settings.annual_leave_days (default 12) dengan aturan
--     'after_12_months' (berhak setelah 12 bulan kerja), 'prorata' (tahun pertama sebanding
--     bulan kerja) atau 'immediate'. hr_leave_adjustments untuk saldo awal / carry-over.
--   * hr_leave_requests: pengajuan karyawan (hari dihitung tanpa hari libur di jadwal,
--     bisa setengah hari), lampiran surat dokter di hr-files/<company>/<employee>/leave/.
--   * Persetujuan: masuk menu Persetujuan (jenis 'leave', izin approval.leave) dan bisa juga
--     diputuskan atasan langsung / HR. Cuti yang disetujui tampil di jadwal & rekap absensi.
-- =====================================================================

-- karyawan ini bawahan langsung saya? (security definer: atasan tidak bisa membaca baris hr_employees bawahannya)
create or replace function hr_is_my_report(p_employee_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from hr_employees e join hr_employees m on m.id = e.manager_id
                 where e.id = p_employee_id and m.user_id = auth.uid())
$$;

-- perbaikan 034: atasan langsung bisa melihat pengajuan koreksi bawahannya
drop policy if exists hr_attendance_corrections_select on hr_attendance_corrections;
create policy hr_attendance_corrections_select on hr_attendance_corrections for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid()) or hr_is_my_report(employee_id)));

-- ---------------------------------------------------------------------
-- PENGATURAN CUTI
-- ---------------------------------------------------------------------
alter table hr_settings add column if not exists annual_leave_days int not null default 12 check (annual_leave_days between 0 and 60);
alter table hr_settings add column if not exists leave_policy text not null default 'after_12_months'
  check (leave_policy in ('after_12_months', 'prorata', 'immediate'));

create or replace function hr_get_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select to_jsonb(s) - 'company_id' - 'updated_at' from hr_settings s where s.company_id = sys_current_company_id()),
    jsonb_build_object('late_tolerance_minutes', 10, 'require_photo', true, 'require_gps', true, 'max_gps_accuracy_m', 150,
                       'annual_leave_days', 12, 'leave_policy', 'after_12_months'))
$$;

-- ---------------------------------------------------------------------
-- JENIS CUTI
-- ---------------------------------------------------------------------
create table hr_leave_types (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  code                 text not null,
  name                 text not null,
  deducts_balance      boolean not null default false,   -- memotong saldo cuti tahunan
  is_paid              boolean not null default true,
  attachment_min_days  int,                              -- wajib lampiran mulai N hari (null = tidak wajib)
  max_days             int,                              -- maks. hari per pengajuan (null = bebas)
  color                text not null default '#4ABDAC',
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, code)
);
select sys_apply_company_policies('hr_leave_types', 'hr.manage');
create trigger trg_hr_leave_types_audit after insert or update or delete on hr_leave_types for each row execute function sys_audit_trigger('');

create or replace function hr_setup_leave_types(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into hr_leave_types (company_id, code, name, deducts_balance, is_paid, attachment_min_days, max_days, color) values
    (p_company_id, 'CUTI',       'Cuti tahunan',      true,  true,  null, null, '#4ABDAC'),
    (p_company_id, 'SAKIT',      'Sakit',             false, true,  2,    null, '#FC4A1A'),
    (p_company_id, 'IZIN',       'Izin (tidak dibayar)', false, false, null, null, '#7F8C8D'),
    (p_company_id, 'MENIKAH',    'Cuti menikah',      false, true,  null, 3,    '#8E44AD'),
    (p_company_id, 'DUKA',       'Cuti duka',         false, true,  null, 2,    '#34495E'),
    (p_company_id, 'MELAHIRKAN', 'Cuti melahirkan',   false, true,  1,    90,   '#F7B733')
  on conflict do nothing
$$;
do $$
declare c record;
begin
  for c in select id from sys_companies loop perform hr_setup_leave_types(c.id); end loop;
end $$;
-- perusahaan baru otomatis punya jenis cuti standar
create or replace function hr_company_leave_types_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform hr_setup_leave_types(new.id);
  return new;
end $$;
create trigger trg_sys_companies_leave_types after insert on sys_companies
  for each row execute function hr_company_leave_types_trigger();

-- penyesuaian saldo (saldo awal saat migrasi, carry-over, kompensasi lembur, ...)
create table hr_leave_adjustments (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  employee_id  uuid not null references hr_employees(id) on delete cascade,
  year         int not null,
  days         numeric(5, 1) not null check (days <> 0),
  note         text not null check (trim(note) <> ''),
  created_by   uuid references sys_users(id) default auth.uid(),
  created_at   timestamptz not null default now()
);
alter table hr_leave_adjustments enable row level security;
create policy hr_leave_adjustments_select on hr_leave_adjustments for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
create policy hr_leave_adjustments_write on hr_leave_adjustments for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
create trigger trg_hr_leave_adjustments_audit after insert or update or delete on hr_leave_adjustments for each row execute function sys_audit_trigger('');

-- ---------------------------------------------------------------------
-- PENGAJUAN
-- ---------------------------------------------------------------------
create table hr_leave_requests (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  employee_id          uuid not null references hr_employees(id) on delete cascade,
  leave_type_id        uuid not null references hr_leave_types(id),
  start_date           date not null,
  end_date             date not null,
  half_day             boolean not null default false,
  days                 numeric(5, 1) not null check (days > 0),
  reason               text not null check (trim(reason) <> ''),
  attachment_path      text,
  status               text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  approval_request_id  uuid references sys_approval_requests(id) on delete set null,
  decided_by           uuid references sys_users(id),
  decided_at           timestamptz,
  decision_note        text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (end_date >= start_date),
  check (not half_day or start_date = end_date)
);
create index hr_leave_requests_company_dates on hr_leave_requests (company_id, start_date, end_date);
alter table hr_leave_requests enable row level security;
create policy hr_leave_requests_select on hr_leave_requests for select to authenticated
  using (company_id = sys_current_company_id() and (
    sys_has_permission('hr.view') or sys_has_permission('hr.manage') or sys_has_permission('hr.attendance') or sys_has_permission('approval.leave')
    or employee_id in (select id from hr_employees where user_id = auth.uid()) or hr_is_my_report(employee_id)));
-- tulis hanya lewat fungsi di bawah
create trigger trg_hr_leave_requests_audit after insert or update or delete on hr_leave_requests for each row execute function sys_audit_trigger('reason,attachment_path');

-- jumlah hari cuti: semua tanggal dalam rentang, kecuali yang dijadwalkan libur
create or replace function hr_leave_days(p_employee_id uuid, p_start date, p_end date, p_half_day boolean default false)
returns numeric language sql stable security definer set search_path = public as $$
  select case when p_half_day then 0.5 else (
    select count(*)::numeric from generate_series(p_start, p_end, interval '1 day') d
    where not exists (select 1 from hr_rosters r where r.employee_id = p_employee_id and r.work_date = d::date and r.is_off)) end
$$;

-- saldo cuti tahunan seorang karyawan
create or replace function hr_leave_balance(p_employee_id uuid, p_year int default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_year int := coalesce(p_year, extract(year from current_date)::int);
  v_emp hr_employees; v_set jsonb; v_days int; v_policy text;
  v_eligible date; v_entitle numeric := 0; v_adj numeric; v_used numeric; v_pending numeric;
begin
  select * into v_emp from hr_employees where id = p_employee_id and company_id = sys_current_company_id();
  if v_emp.id is null then return null; end if;
  v_set := hr_get_settings();
  v_days := (v_set->>'annual_leave_days')::int;
  v_policy := v_set->>'leave_policy';
  if v_policy = 'immediate' or v_emp.join_date is null then
    v_entitle := v_days;
    v_eligible := v_emp.join_date;
  elsif v_policy = 'after_12_months' then
    v_eligible := (v_emp.join_date + interval '12 months')::date;
    -- berhak penuh setelah genap 12 bulan; sebelum itu 0
    v_entitle := case when v_eligible <= least(current_date, make_date(v_year, 12, 31)) then v_days else 0 end;
  else  -- prorata: tahun masuk dihitung sebanding bulan kerja
    v_eligible := v_emp.join_date;
    v_entitle := case
      when extract(year from v_emp.join_date) < v_year then v_days
      when extract(year from v_emp.join_date) > v_year then 0
      else floor(v_days * (13 - extract(month from v_emp.join_date)) / 12) end;
  end if;
  select coalesce(sum(days), 0) into v_adj from hr_leave_adjustments where employee_id = p_employee_id and year = v_year;
  select coalesce(sum(r.days) filter (where r.status = 'approved'), 0), coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pending
  from hr_leave_requests r join hr_leave_types t on t.id = r.leave_type_id
  where r.employee_id = p_employee_id and t.deducts_balance and extract(year from r.start_date) = v_year;
  return jsonb_build_object('year', v_year, 'policy', v_policy, 'annual', v_days, 'eligible_from', v_eligible,
    'entitlement', v_entitle, 'adjustment', v_adj, 'used', v_used, 'pending', v_pending,
    'remaining', v_entitle + v_adj - v_used - v_pending);
end $$;

-- karyawan mengajukan cuti / izin
-- p: {leave_type_id, start_date, end_date, half_day, reason, attachment_path}
create or replace function hr_request_leave(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_emp hr_employees; v_type hr_leave_types; v_req hr_leave_requests;
  v_start date := (p->>'start_date')::date;
  v_end date := coalesce((p->>'end_date')::date, (p->>'start_date')::date);
  v_half boolean := coalesce((p->>'half_day')::boolean, false);
  v_att text := nullif(p->>'attachment_path', '');
  v_days numeric; v_bal jsonb; v_appr jsonb;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = v_company;
  if v_emp.id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  if not v_emp.is_active then raise exception 'Data karyawan Anda tidak aktif'; end if;
  select * into v_type from hr_leave_types where id = (p->>'leave_type_id')::uuid and company_id = v_company and is_active;
  if v_type.id is null then raise exception 'Jenis cuti tidak ditemukan'; end if;
  if v_start is null then raise exception 'Tanggal mulai wajib diisi'; end if;
  if v_end < v_start then raise exception 'Tanggal selesai sebelum tanggal mulai'; end if;
  if v_half and v_end <> v_start then raise exception 'Setengah hari hanya untuk satu tanggal'; end if;
  if v_start < current_date - 30 then raise exception 'Pengajuan paling lama untuk 30 hari ke belakang'; end if;
  if v_end - v_start > 180 then raise exception 'Rentang cuti terlalu panjang'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Alasan wajib diisi'; end if;
  if exists (select 1 from hr_leave_requests where employee_id = v_emp.id and status in ('pending', 'approved')
             and daterange(start_date, end_date, '[]') && daterange(v_start, v_end, '[]')) then
    raise exception 'Tanggal ini bertabrakan dengan pengajuan cuti lain';
  end if;
  v_days := hr_leave_days(v_emp.id, v_start, v_end, v_half);
  if v_days <= 0 then raise exception 'Semua tanggal yang dipilih adalah hari libur Anda'; end if;
  if v_type.max_days is not null and v_days > v_type.max_days then
    raise exception '% maksimal % hari per pengajuan', v_type.name, v_type.max_days;
  end if;
  if v_att is not null then
    if v_att not like v_company || '/' || v_emp.id || '/leave/%' then raise exception 'Lampiran tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'hr-files' and name = v_att) then raise exception 'Lampiran belum terunggah'; end if;
  elsif v_type.attachment_min_days is not null and v_days >= v_type.attachment_min_days then
    raise exception '% % hari ke atas wajib melampirkan bukti (mis. surat dokter)', v_type.name, v_type.attachment_min_days;
  end if;
  if v_type.deducts_balance then
    v_bal := hr_leave_balance(v_emp.id, extract(year from v_start)::int);
    if (v_bal->>'remaining')::numeric < v_days then
      raise exception 'Sisa cuti tidak cukup (sisa % hari%)', v_bal->>'remaining',
        case when (v_bal->>'entitlement')::numeric = 0 and v_bal->>'eligible_from' is not null
             then ', berhak cuti mulai ' || to_char((v_bal->>'eligible_from')::date, 'DD-MM-YYYY') else '' end;
    end if;
  end if;

  insert into hr_leave_requests (company_id, employee_id, leave_type_id, start_date, end_date, half_day, days, reason, attachment_path)
  values (v_company, v_emp.id, v_type.id, v_start, v_end, v_half, v_days, trim(p->>'reason'), v_att)
  returning * into v_req;
  v_appr := sys_request_approval('leave', v_req.id, v_emp.outlet_id, v_days,
    v_type.name || ' · ' || v_emp.full_name || ' · ' || v_days || ' hari (' || to_char(v_start, 'DD/MM')
      || case when v_end <> v_start then '–' || to_char(v_end, 'DD/MM') else '' end || ')',
    jsonb_build_object('employee', v_emp.full_name, 'leave_type', v_type.name, 'start_date', v_start, 'end_date', v_end,
                       'days', v_days, 'half_day', v_half, 'reason', trim(p->>'reason'), 'has_attachment', v_att is not null));
  update hr_leave_requests set approval_request_id = (v_appr->>'approval_request_id')::uuid where id = v_req.id returning * into v_req;
  return to_jsonb(v_req);
end $$;

-- keputusan dari menu Persetujuan (sys_decide_approval) / dari HR & atasan diteruskan ke pengajuan cuti
create or replace function hr_leave_sync_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_req hr_leave_requests; v_type hr_leave_types; v_bal jsonb;
begin
  select * into v_req from hr_leave_requests where id = new.document_id for update;
  if v_req.id is null or v_req.status <> 'pending' then return new; end if;
  if new.status = 'approved' then
    select * into v_type from hr_leave_types where id = v_req.leave_type_id;
    if v_type.deducts_balance then
      v_bal := hr_leave_balance(v_req.employee_id, extract(year from v_req.start_date)::int);
      -- saldo sudah termasuk pengajuan ini sebagai 'pending'
      if (v_bal->>'remaining')::numeric < 0 then raise exception 'Sisa cuti karyawan tidak cukup'; end if;
    end if;
  end if;
  update hr_leave_requests set status = new.status, decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()),
    decision_note = new.decision_note, updated_at = now()
  where id = v_req.id;
  return new;
end $$;
create trigger trg_sys_approval_requests_leave after update of status on sys_approval_requests
  for each row when (new.document_type = 'leave' and old.status = 'pending' and new.status in ('approved', 'rejected', 'cancelled'))
  execute function hr_leave_sync_approval();

-- yang berhak memutuskan: HR (hr.manage) / penyetuju cuti (approval.leave) dengan akses outlet, atau atasan langsung
create or replace function hr_can_decide_leave(p_employee_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from hr_employees e
    where e.id = p_employee_id and e.company_id = sys_current_company_id() and e.user_id is distinct from auth.uid()
      and (((sys_has_permission('hr.manage') or sys_has_permission('approval.leave')) and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)))
        or exists (select 1 from hr_employees m where m.id = e.manager_id and m.user_id = auth.uid())))
$$;

create or replace function hr_decide_leave(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_req hr_leave_requests;
begin
  select * into v_req from hr_leave_requests where id = p_id and company_id = sys_current_company_id();
  if v_req.id is null then raise exception 'Pengajuan tidak ditemukan'; end if;
  if v_req.status <> 'pending' then raise exception 'Pengajuan sudah diproses'; end if;
  if v_req.employee_id in (select id from hr_employees where user_id = auth.uid()) then raise exception 'Tidak bisa memutuskan pengajuan sendiri'; end if;
  if not hr_can_decide_leave(v_req.employee_id) then raise exception 'Anda bukan atasan / penyetuju cuti karyawan ini'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
  if v_req.approval_request_id is not null then
    update sys_approval_requests set status = case when p_approve then 'approved' else 'rejected' end,
      decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), '')
    where id = v_req.approval_request_id and status = 'pending';
  end if;
  -- tanpa permintaan approval (atau sudah ditutup): putuskan langsung
  update hr_leave_requests set status = case when p_approve then 'approved' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now()
  where id = p_id and status = 'pending';
end $$;

-- karyawan membatalkan: yang menunggu, atau yang disetujui tapi belum dimulai
create or replace function hr_cancel_leave(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_req hr_leave_requests;
begin
  select r.* into v_req from hr_leave_requests r join hr_employees e on e.id = r.employee_id
  where r.id = p_id and e.user_id = auth.uid() and r.company_id = sys_current_company_id();
  if v_req.id is null then raise exception 'Pengajuan tidak ditemukan'; end if;
  if v_req.status = 'pending' then
    update sys_approval_requests set status = 'cancelled', decided_at = now(), decision_note = 'Dibatalkan pengaju'
    where id = v_req.approval_request_id and status = 'pending';
  elsif not (v_req.status = 'approved' and v_req.start_date > current_date) then
    raise exception 'Pengajuan ini tidak bisa dibatalkan lagi';
  end if;
  update hr_leave_requests set status = 'cancelled', updated_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- TAMPILAN
-- ---------------------------------------------------------------------
-- Beranda Saya: saldo, jenis cuti, pengajuan saya, rekan satu outlet yang cuti 14 hari ke depan
create or replace function hr_my_leave()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_emp hr_employees;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id();
  if v_emp.id is null then return null; end if;
  return jsonb_build_object(
    'employee_id', v_emp.id,
    'balance', hr_leave_balance(v_emp.id, extract(year from current_date)::int),
    'types', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'code', t.code, 'name', t.name, 'deducts_balance', t.deducts_balance,
        'is_paid', t.is_paid, 'attachment_min_days', t.attachment_min_days, 'max_days', t.max_days, 'color', t.color) order by t.deducts_balance desc, t.name)
      from hr_leave_types t where t.company_id = v_emp.company_id and t.is_active), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('leave_type', t.name, 'color', t.color,
        'decider', (select full_name from sys_users where id = r.decided_by)) order by r.start_date desc)
      from hr_leave_requests r join hr_leave_types t on t.id = r.leave_type_id
      where r.employee_id = v_emp.id and (r.status = 'pending' or r.start_date >= date_trunc('year', current_date) - interval '1 month')), '[]'::jsonb),
    'team', coalesce((select jsonb_agg(jsonb_build_object('full_name', coalesce(e.nickname, e.full_name), 'leave_type', t.name, 'color', t.color,
        'start_date', r.start_date, 'end_date', r.end_date) order by r.start_date)
      from hr_leave_requests r join hr_employees e on e.id = r.employee_id join hr_leave_types t on t.id = r.leave_type_id
      where r.company_id = v_emp.company_id and r.status = 'approved' and r.employee_id <> v_emp.id
        and e.outlet_id is not distinct from v_emp.outlet_id
        and r.end_date >= current_date and r.start_date <= current_date + 14), '[]'::jsonb));
end $$;

-- HR / atasan / penyetuju: pengajuan dalam rentang (kalender tim) + yang menunggu keputusan saya
create or replace function hr_leave_board(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id(); v_wide boolean;
begin
  v_wide := sys_has_permission('hr.view') or sys_has_permission('hr.manage') or sys_has_permission('hr.attendance') or sys_has_permission('approval.leave');
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
        'full_name', e.full_name, 'employee_number', e.employee_number, 'outlet', o.name, 'outlet_id', e.outlet_id,
        'position', p.name, 'leave_type', t.name, 'color', t.color, 'is_paid', t.is_paid, 'deducts_balance', t.deducts_balance,
        'decider', (select full_name from sys_users where id = r.decided_by),
        'can_decide', r.status = 'pending' and hr_can_decide_leave(e.id)) order by r.start_date)
      from hr_leave_requests r
      join hr_employees e on e.id = r.employee_id
      join hr_leave_types t on t.id = r.leave_type_id
      left join hr_positions p on p.id = e.position_id
      left join sys_outlets o on o.id = e.outlet_id
      where r.company_id = v_company and r.status <> 'cancelled'
        and ((r.end_date >= p_from and r.start_date <= p_to) or (r.status = 'pending' and hr_can_decide_leave(e.id)))
        and (p_outlet_id is null or e.outlet_id = p_outlet_id)
        and ((v_wide and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)))
          or exists (select 1 from hr_employees m where m.id = e.manager_id and m.user_id = auth.uid()))), '[]'::jsonb),
    'types', coalesce((select jsonb_agg(to_jsonb(t) order by t.deducts_balance desc, t.name) from hr_leave_types t where t.company_id = v_company), '[]'::jsonb));
end $$;

-- saldo cuti semua karyawan (HR)
create or replace function hr_leave_balances(p_year int default null, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (sys_has_permission('hr.view') or sys_has_permission('hr.manage')) then raise exception 'Butuh izin lihat data karyawan'; end if;
  return coalesce((select jsonb_agg(hr_leave_balance(e.id, coalesce(p_year, extract(year from current_date)::int))
      || jsonb_build_object('employee_id', e.id, 'full_name', e.full_name, 'employee_number', e.employee_number,
                            'join_date', e.join_date, 'outlet', o.name, 'position', p.name) order by e.full_name)
    from hr_employees e left join sys_outlets o on o.id = e.outlet_id left join hr_positions p on p.id = e.position_id
    where e.company_id = sys_current_company_id() and e.is_active
      and (p_outlet_id is null or e.outlet_id = p_outlet_id)
      and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))), '[]'::jsonb);
end $$;

-- jumlah pengajuan cuti yang menunggu keputusan saya (badge menu)
create or replace function hr_leave_pending_count()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from hr_leave_requests r
  where r.company_id = sys_current_company_id() and r.status = 'pending' and hr_can_decide_leave(r.employee_id)
$$;

-- ---------------------------------------------------------------------
-- JADWAL & REKAP ABSENSI MENGENAL CUTI
-- ---------------------------------------------------------------------
create or replace function hr_leave_on(p_employee_id uuid, p_date date)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'leave_type', t.name, 'color', t.color, 'half_day', r.half_day)
  from hr_leave_requests r join hr_leave_types t on t.id = r.leave_type_id
  where r.employee_id = p_employee_id and r.status = 'approved' and p_date between r.start_date and r.end_date
  limit 1
$$;

create or replace function hr_schedule_for(p_employee_id uuid, p_date date)
returns jsonb language sql stable security definer set search_path = public as $$
  with e as (select id, outlet_id from hr_employees where id = p_employee_id),
  r as (select * from hr_rosters where employee_id = p_employee_id and work_date = p_date),
  o as (select o.* from sys_outlets o where o.id = coalesce((select outlet_id from r), (select outlet_id from e)))
  select jsonb_build_object(
    'work_date', p_date,
    'outlet_id', (select id from o), 'outlet', (select name from o),
    'geo_lat', (select geo_lat from o), 'geo_lng', (select geo_lng from o), 'geo_radius_m', (select geo_radius_m from o),
    'is_off', coalesce((select is_off from r), false),
    'has_roster', exists (select 1 from r),
    'leave', hr_leave_on(p_employee_id, p_date),
    'shift_id', s.id, 'shift', s.name, 'shift_color', s.color, 'start_time', s.start_time, 'end_time', s.end_time,
    'scheduled_start', case when s.id is not null then (p_date + s.start_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end,
    'scheduled_end', case when s.id is not null then (p_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end)
  from (select 1) x
  left join r on true
  left join hr_shifts s on s.id = r.shift_id and not r.is_off
$$;

-- rekap: hari cuti yang disetujui ikut tampil (status 'leave', menggantikan alpa / terjadwal)
create or replace function hr_attendance_recap(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (hr_can_schedule() or sys_has_permission('hr.view')) then raise exception 'Butuh izin lihat absensi'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Rentang tanggal maksimal 2 bulan'; end if;
  return coalesce((
    with keys as (
      select employee_id, work_date from hr_attendances where company_id = v_company and work_date between p_from and p_to
      union
      select employee_id, work_date from hr_rosters where company_id = v_company and work_date between p_from and p_to
      union
      select lr.employee_id, d::date from hr_leave_requests lr, generate_series(greatest(lr.start_date, p_from), least(lr.end_date, p_to), interval '1 day') d
      where lr.company_id = v_company and lr.status = 'approved' and lr.end_date >= p_from and lr.start_date <= p_to
    ), days as (
      select k.employee_id, k.work_date, a.id as att_id, r.id as roster_id, hr_leave_on(k.employee_id, k.work_date) as lv
      from keys k
      left join hr_attendances a on a.employee_id = k.employee_id and a.work_date = k.work_date
      left join hr_rosters r on r.employee_id = k.employee_id and r.work_date = k.work_date
    )
    select jsonb_agg(jsonb_build_object(
      'employee_id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name, 'position', p.name,
      'work_date', d.work_date, 'outlet_id', coalesce(a.outlet_id, r.outlet_id, e.outlet_id), 'outlet', o.name,
      'shift', s.name, 'shift_color', s.color, 'is_off', coalesce(r.is_off, false),
      'leave_type', d.lv->>'leave_type', 'leave_color', d.lv->>'color',
      'scheduled_start', coalesce(a.scheduled_start, case when s.id is not null then (d.work_date + s.start_time) at time zone coalesce(o.timezone, 'Asia/Jakarta') end),
      'attendance_id', a.id, 'check_in_at', a.check_in_at, 'check_out_at', a.check_out_at,
      'check_in_photo', a.check_in_photo, 'check_out_photo', a.check_out_photo,
      'check_in_distance_m', a.check_in_distance_m, 'check_out_distance_m', a.check_out_distance_m,
      'check_in_lat', a.check_in_lat, 'check_in_lng', a.check_in_lng,
      'late_minutes', coalesce(a.late_minutes, 0), 'early_leave_minutes', coalesce(a.early_leave_minutes, 0),
      'flags', coalesce(a.flags, '{}'), 'review_status', coalesce(a.review_status, 'none'), 'review_note', a.review_note,
      'status', case
        when a.check_in_at is not null and a.late_minutes > 0 then 'late'
        when a.check_in_at is not null then 'present'
        when d.lv is not null then 'leave'
        when coalesce(r.is_off, false) then 'off'
        when s.id is not null and (d.work_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce(o.timezone, 'Asia/Jakarta') < now() then 'absent'
        else 'scheduled' end)
      order by d.work_date desc, e.full_name)
    from days d
    join hr_employees e on e.id = d.employee_id
    left join hr_attendances a on a.id = d.att_id
    left join hr_rosters r on r.id = d.roster_id
    left join hr_shifts s on s.id = coalesce(a.shift_id, case when not r.is_off then r.shift_id end)
    left join hr_positions p on p.id = e.position_id
    left join sys_outlets o on o.id = coalesce(a.outlet_id, r.outlet_id, e.outlet_id)
    where (p_outlet_id is null or coalesce(a.outlet_id, r.outlet_id, e.outlet_id) = p_outlet_id)
      and (coalesce(a.outlet_id, r.outlet_id, e.outlet_id) is null or sys_can_access_outlet(coalesce(a.outlet_id, r.outlet_id, e.outlet_id)))
  ), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- STORAGE: karyawan boleh unggah lampiran cuti ke folder 'leave' miliknya; penyetuju boleh melihat
-- ---------------------------------------------------------------------
create or replace function hr_can_upload_own(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (storage.foldername(p_name))[3] in ('attendance', 'leave')
     and exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid() and e.is_active)
$$;

create or replace function hr_can_read_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
          or ((storage.foldername(p_name))[3] = 'attendance' and sys_has_permission('hr.attendance'))
          or ((storage.foldername(p_name))[3] = 'leave' and (sys_has_permission('approval.leave')
              or exists (select 1 from hr_employees e join hr_employees m on m.id = e.manager_id
                         where e.id::text = (storage.foldername(p_name))[2] and m.user_id = auth.uid())))
          or exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid()))
$$;

-- Semar boleh membantu membuat jenis cuti (tetap lewat usulan + persetujuan owner)
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers',
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements', 'hr_shifts', 'hr_leave_types']
$$;

-- >>>>>>>>>> migrations/036_hr_tasks.sql
-- =====================================================================
-- SEMAR - 036: SDM / HR FASE D - TUGAS (KANBAN) & SOP HARIAN
--   * hr_tasks: tugas dengan alur Baru -> Dikerjakan -> Review -> Selesai -> Arsip.
--     Penerima: satu orang (assignee_id) atau satu tim/role (assignee_role_id, anggota bisa "ambil").
--     Prioritas, tenggat, label, checklist, wajib foto bukti, tautan dokumen, komentar & riwayat.
--     Pengerjaan diajukan ke Review; pembuat / manajer (task.manage) menyetujui atau mengembalikan.
--   * hr_sop_templates + hr_sop_runs: checklist SOP harian per role (mis. buka / tutup toko),
--     dibuat otomatis per hari per outlet saat dibuka; item bisa wajib foto. Rekap kepatuhan.
--   * Bucket privat 'task-files': <company>/tasks/<task_id>/... dan <company>/sop/<run_id>/...
--   Izin baru: task.manage (kelola semua tugas & template SOP).
-- =====================================================================

create table hr_tasks (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  task_number       text,
  title             text not null check (trim(title) <> ''),
  description       text not null default '',
  status            text not null default 'new' check (status in ('new', 'in_progress', 'review', 'done', 'archived')),
  priority          text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  outlet_id         uuid references sys_outlets(id) on delete set null,
  assignee_id       uuid references sys_users(id) on delete set null,
  assignee_role_id  uuid references sys_roles(id) on delete set null,
  due_date          date,
  labels            text[] not null default '{}',
  checklist         jsonb not null default '[]',      -- [{text, done}]
  requires_photo    boolean not null default false,
  photo_paths       text[] not null default '{}',
  link_label        text,                             -- mis. "PO/20261009/0003"
  link_url          text,                             -- rute di aplikasi, mis. /purchasing?tab=po
  sort_order        numeric not null default 0,
  created_by        uuid references sys_users(id) default auth.uid(),
  started_at        timestamptz,
  submitted_at      timestamptz,
  done_at           timestamptz,
  done_by           uuid references sys_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, task_number),
  check (link_url is null or link_url like '/%')
);
create index hr_tasks_company_status on hr_tasks (company_id, status);

create table hr_task_comments (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references hr_tasks(id) on delete cascade,
  user_id     uuid references sys_users(id) default auth.uid(),
  kind        text not null default 'comment' check (kind in ('comment', 'event')),
  body        text not null check (trim(body) <> ''),
  created_at  timestamptz not null default now()
);
create index hr_task_comments_task on hr_task_comments (task_id, created_at);

create or replace function hr_task_set_number()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.task_number, '') = '' then
    new.task_number := 'TSK-' || lpad(sys_next_sequence(new.company_id, 'TSK')::text, 4, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_hr_tasks_number before insert or update on hr_tasks for each row execute function hr_task_set_number();

-- user ini manajer tugas (izin task.manage, dengan akses outlet tugas)
create or replace function hr_task_is_manager(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('task.manage') and (p_outlet_id is null or sys_can_access_outlet(p_outlet_id))
$$;

-- yang boleh melihat tugas: manajer, pembuat, penerima, anggota tim penerima, atasan langsung penerima
create or replace function hr_task_visible(p_task_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from hr_tasks t
    where t.id = p_task_id and t.company_id = sys_current_company_id()
      and (hr_task_is_manager(t.outlet_id) or t.created_by = auth.uid() or t.assignee_id = auth.uid()
        or (t.assignee_role_id is not null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid())
            and (t.outlet_id is null or sys_can_access_outlet(t.outlet_id)))
        or exists (select 1 from hr_employees e where e.user_id = t.assignee_id and hr_is_my_report(e.id))))
$$;

alter table hr_tasks enable row level security;
create policy hr_tasks_select on hr_tasks for select to authenticated
  using (company_id = sys_current_company_id() and hr_task_visible(id));
alter table hr_task_comments enable row level security;
create policy hr_task_comments_select on hr_task_comments for select to authenticated
  using (hr_task_visible(task_id));
-- tulis hanya lewat fungsi di bawah

-- peran user terhadap tugas
create or replace function hr_task_roles(p_task hr_tasks)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'manager', hr_task_is_manager(p_task.outlet_id) or p_task.created_by = auth.uid(),
    'doer', p_task.assignee_id = auth.uid()
         or (p_task.assignee_id is null and p_task.assignee_role_id is not null
             and p_task.assignee_role_id = (select role_id from sys_users where id = auth.uid())
             and (p_task.outlet_id is null or sys_can_access_outlet(p_task.outlet_id)))
         or (p_task.assignee_id is null and p_task.assignee_role_id is null and p_task.created_by = auth.uid()),
    'self_task', p_task.created_by = auth.uid() and coalesce(p_task.assignee_id = auth.uid(), p_task.assignee_role_id is null))
$$;

create or replace function hr_task_log(p_task_id uuid, p_body text)
returns void language sql security definer set search_path = public as $$
  insert into hr_task_comments (task_id, user_id, kind, body) values (p_task_id, auth.uid(), 'event', p_body)
$$;

-- buat / ubah tugas. p: {id?, title, description, priority, outlet_id, assignee_id, assignee_role_id, due_date,
--                        labels[], checklist[], requires_photo, link_label, link_url}
create or replace function hr_task_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_task hr_tasks; v_roles jsonb;
  v_assignee uuid := nullif(p->>'assignee_id', '')::uuid;
  v_role uuid := nullif(p->>'assignee_role_id', '')::uuid;
  v_outlet uuid := nullif(p->>'outlet_id', '')::uuid;
begin
  if v_company is null then raise exception 'Belum login'; end if;
  if coalesce(trim(p->>'title'), '') = '' then raise exception 'Judul tugas wajib diisi'; end if;
  if v_assignee is not null and not exists (select 1 from sys_users where id = v_assignee and company_id = v_company and is_active) then
    raise exception 'Penerima tugas tidak ditemukan';
  end if;
  if v_role is not null and not exists (select 1 from sys_roles where id = v_role and company_id = v_company) then raise exception 'Tim tidak ditemukan'; end if;
  if v_outlet is not null and not sys_can_access_outlet(v_outlet) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  -- tugas untuk tim / orang lain tanpa izin task.manage: hanya untuk outlet yang bisa diakses (dicek di atas)
  if nullif(p->>'id', '') is null then
    insert into hr_tasks (company_id, title, description, priority, outlet_id, assignee_id, assignee_role_id, due_date, labels,
      checklist, requires_photo, link_label, link_url)
    values (v_company, trim(p->>'title'), coalesce(p->>'description', ''), coalesce(nullif(p->>'priority', ''), 'normal'), v_outlet,
      v_assignee, case when v_assignee is null then v_role end, nullif(p->>'due_date', '')::date,
      coalesce(array(select jsonb_array_elements_text(p->'labels')), '{}'),
      coalesce(p->'checklist', '[]'::jsonb), coalesce((p->>'requires_photo')::boolean, false),
      nullif(trim(coalesce(p->>'link_label', '')), ''), nullif(p->>'link_url', ''))
    returning * into v_task;
    perform hr_task_log(v_task.id, 'membuat tugas');
  else
    select * into v_task from hr_tasks where id = (p->>'id')::uuid and company_id = v_company for update;
    if v_task.id is null or not hr_task_visible(v_task.id) then raise exception 'Tugas tidak ditemukan'; end if;
    v_roles := hr_task_roles(v_task);
    if not (v_roles->>'manager')::boolean then
      -- penerima hanya boleh mencentang checklist
      if not (v_roles->>'doer')::boolean then raise exception 'Anda tidak bisa mengubah tugas ini'; end if;
      update hr_tasks set checklist = coalesce(p->'checklist', checklist) where id = v_task.id returning * into v_task;
    else
      if (v_task.assignee_id is distinct from v_assignee) then
        perform hr_task_log(v_task.id, 'mengalihkan tugas ke ' || coalesce((select full_name from sys_users where id = v_assignee),
          (select 'tim ' || name from sys_roles where id = v_role), 'tanpa penerima'));
      end if;
      update hr_tasks set title = trim(p->>'title'), description = coalesce(p->>'description', ''), priority = coalesce(nullif(p->>'priority', ''), 'normal'),
        outlet_id = v_outlet, assignee_id = v_assignee, assignee_role_id = case when v_assignee is null then v_role end,
        due_date = nullif(p->>'due_date', '')::date, labels = coalesce(array(select jsonb_array_elements_text(p->'labels')), '{}'),
        checklist = coalesce(p->'checklist', '[]'::jsonb), requires_photo = coalesce((p->>'requires_photo')::boolean, false),
        link_label = nullif(trim(coalesce(p->>'link_label', '')), ''), link_url = nullif(p->>'link_url', '')
      where id = v_task.id returning * into v_task;
    end if;
  end if;
  return to_jsonb(v_task);
end $$;

-- pindah status (geser kartu)
create or replace function hr_task_move(p_id uuid, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_task hr_tasks; v_roles jsonb; v_mgr boolean; v_doer boolean; v_self boolean;
  v_label jsonb := '{"new":"Baru","in_progress":"Dikerjakan","review":"Review","done":"Selesai","archived":"Arsip"}';
begin
  select * into v_task from hr_tasks where id = p_id and company_id = sys_current_company_id() for update;
  if v_task.id is null or not hr_task_visible(v_task.id) then raise exception 'Tugas tidak ditemukan'; end if;
  if p_status not in ('new', 'in_progress', 'review', 'done', 'archived') then raise exception 'Status tidak dikenal'; end if;
  if p_status = v_task.status then return to_jsonb(v_task); end if;
  v_roles := hr_task_roles(v_task);
  v_mgr := (v_roles->>'manager')::boolean; v_doer := (v_roles->>'doer')::boolean; v_self := (v_roles->>'self_task')::boolean;

  if not v_mgr then
    if not v_doer then raise exception 'Anda bukan penerima tugas ini'; end if;
    if p_status in ('archived') or v_task.status in ('done', 'archived') then raise exception 'Hanya pembuat tugas / manajer yang bisa memindahkan ke sini'; end if;
    if p_status = 'done' and not v_self then raise exception 'Ajukan ke Review dulu; pembuat tugas yang menandai selesai'; end if;
    if v_task.status = 'review' then raise exception 'Tugas sedang direview'; end if;
  end if;
  if v_mgr and v_task.status = 'review' and p_status in ('new', 'in_progress') and coalesce(trim(p_note), '') = '' and not v_self then
    raise exception 'Tulis catatan apa yang perlu diperbaiki';
  end if;
  -- syarat selesai: checklist lengkap & foto bukti
  if p_status in ('review', 'done') then
    if exists (select 1 from jsonb_array_elements(v_task.checklist) c where not coalesce((c->>'done')::boolean, false)) then
      raise exception 'Checklist belum selesai semua';
    end if;
    if v_task.requires_photo and cardinality(v_task.photo_paths) = 0 then raise exception 'Lampirkan foto bukti dulu'; end if;
  end if;

  update hr_tasks set status = p_status,
    -- tugas tim: yang pertama mengerjakan otomatis jadi penerima
    assignee_id = case when assignee_id is null and assignee_role_id is not null and p_status = 'in_progress' and v_doer then auth.uid() else assignee_id end,
    started_at = case when p_status = 'in_progress' then coalesce(started_at, now()) else started_at end,
    submitted_at = case when p_status = 'review' then now() else submitted_at end,
    done_at = case when p_status = 'done' then now() when p_status in ('new', 'in_progress', 'review') then null else done_at end,
    done_by = case when p_status = 'done' then auth.uid() when p_status in ('new', 'in_progress', 'review') then null else done_by end
  where id = p_id returning * into v_task;
  perform hr_task_log(p_id, 'memindahkan ke ' || (v_label->>p_status) || coalesce(': ' || nullif(trim(p_note), ''), ''));
  return to_jsonb(v_task);
end $$;

create or replace function hr_task_comment(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not hr_task_visible(p_id) then raise exception 'Tugas tidak ditemukan'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Komentar kosong'; end if;
  insert into hr_task_comments (task_id, user_id, kind, body) values (p_id, auth.uid(), 'comment', trim(p_body));
end $$;

-- foto bukti: file harus sudah diunggah ke task-files/<company>/tasks/<task_id>/
create or replace function hr_task_photo(p_id uuid, p_path text, p_remove boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_task hr_tasks; v_roles jsonb;
begin
  select * into v_task from hr_tasks where id = p_id and company_id = sys_current_company_id() for update;
  if v_task.id is null or not hr_task_visible(v_task.id) then raise exception 'Tugas tidak ditemukan'; end if;
  v_roles := hr_task_roles(v_task);
  if not ((v_roles->>'manager')::boolean or (v_roles->>'doer')::boolean) then raise exception 'Anda tidak bisa mengubah tugas ini'; end if;
  if p_remove then
    update hr_tasks set photo_paths = array_remove(photo_paths, p_path) where id = p_id returning * into v_task;
  else
    if p_path not like v_task.company_id || '/tasks/' || v_task.id || '/%' then raise exception 'Foto tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'task-files' and name = p_path) then raise exception 'Foto belum terunggah'; end if;
    update hr_tasks set photo_paths = array_append(photo_paths, p_path) where id = p_id returning * into v_task;
    perform hr_task_log(p_id, 'menambahkan foto bukti');
  end if;
  return to_jsonb(v_task);
end $$;

-- orang & tim untuk pilihan penerima (nama saja)
create or replace function hr_task_people()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'full_name', u.full_name, 'avatar_url', u.avatar_url, 'role_id', u.role_id, 'role', r.name) order by u.full_name)
      from sys_users u left join sys_roles r on r.id = u.role_id where u.company_id = sys_current_company_id() and u.is_active), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.name)
      from sys_roles r where r.company_id = sys_current_company_id()), '[]'::jsonb))
$$;

-- papan kanban. p_scope: 'mine' (untuk saya & tim saya) / 'created' (saya buat) / 'all' (semua yang terlihat)
create or replace function hr_task_board(p_scope text default 'mine', p_outlet_id uuid default null, p_include_archived boolean default false)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object(
      'assignee', (select full_name from sys_users where id = t.assignee_id),
      'assignee_avatar', (select avatar_url from sys_users where id = t.assignee_id),
      'assignee_role', (select name from sys_roles where id = t.assignee_role_id),
      'creator', (select full_name from sys_users where id = t.created_by),
      'outlet', (select name from sys_outlets where id = t.outlet_id),
      'comment_count', (select count(*) from hr_task_comments c where c.task_id = t.id and c.kind = 'comment'),
      'roles', hr_task_roles(t))
    order by t.sort_order, case t.priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, t.due_date nulls last, t.created_at), '[]'::jsonb)
  from hr_tasks t
  where t.company_id = sys_current_company_id() and hr_task_visible(t.id)
    and (p_include_archived or t.status <> 'archived')
    and (t.status <> 'done' or t.done_at > now() - interval '30 days' or p_include_archived)
    and (p_outlet_id is null or t.outlet_id = p_outlet_id)
    and case p_scope
      when 'created' then t.created_by = auth.uid()
      when 'all' then true
      else t.assignee_id = auth.uid()
        or (t.assignee_id is null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid()))
        or (t.assignee_id is null and t.assignee_role_id is null and t.created_by = auth.uid())
    end
$$;

create or replace function hr_task_detail(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when hr_task_visible(p_id) then (
    select to_jsonb(t) || jsonb_build_object(
      'assignee', (select full_name from sys_users where id = t.assignee_id),
      'assignee_role', (select name from sys_roles where id = t.assignee_role_id),
      'creator', (select full_name from sys_users where id = t.created_by),
      'outlet', (select name from sys_outlets where id = t.outlet_id),
      'roles', hr_task_roles(t),
      'comments', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'body', c.body, 'created_at', c.created_at,
          'user', u.full_name, 'avatar_url', u.avatar_url) order by c.created_at)
        from hr_task_comments c left join sys_users u on u.id = c.user_id where c.task_id = t.id), '[]'::jsonb))
    from hr_tasks t where t.id = p_id) end
$$;

-- ---------------------------------------------------------------------
-- SOP HARIAN
-- ---------------------------------------------------------------------
create table hr_sop_templates (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  name        text not null check (trim(name) <> ''),
  role_id     uuid references sys_roles(id) on delete set null,     -- null = semua role
  outlet_id   uuid references sys_outlets(id) on delete set null,   -- null = semua outlet
  items       jsonb not null default '[]',                          -- [{text, photo}]
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (jsonb_typeof(items) = 'array')
);
select sys_apply_company_policies('hr_sop_templates', 'task.manage');
create trigger trg_hr_sop_templates_audit after insert or update or delete on hr_sop_templates for each row execute function sys_audit_trigger('');

create table hr_sop_runs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  template_id   uuid not null references hr_sop_templates(id) on delete cascade,
  outlet_id     uuid references sys_outlets(id) on delete set null,
  run_date      date not null,
  items         jsonb not null,                                     -- [{text, photo, done, by, by_name, at, photo_path}]
  completed_at  timestamptz,
  created_at    timestamptz not null default now()
);
create unique index hr_sop_runs_unique on hr_sop_runs (template_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid), run_date);
alter table hr_sop_runs enable row level security;
create policy hr_sop_runs_select on hr_sop_runs for select to authenticated
  using (company_id = sys_current_company_id() and (outlet_id is null or sys_can_access_outlet(outlet_id)));

-- SOP hari ini untuk saya (dibuat otomatis bila belum ada)
create or replace function hr_my_sops()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_role uuid := (select role_id from sys_users where id = auth.uid());
  v_outlet uuid := (select outlet_id from hr_employees where user_id = auth.uid() and company_id = v_company);
  v_date date; t record; v_run_outlet uuid;
begin
  if v_company is null then return '[]'::jsonb; end if;
  for t in select * from hr_sop_templates
           where company_id = v_company and is_active and jsonb_array_length(items) > 0
             and (role_id is null or role_id = v_role)
             and (outlet_id is null or outlet_id = v_outlet or (v_outlet is null and sys_can_access_outlet(outlet_id))) loop
    v_run_outlet := coalesce(t.outlet_id, v_outlet);
    v_date := (now() at time zone coalesce((select timezone from sys_outlets where id = v_run_outlet), 'Asia/Jakarta'))::date;
    insert into hr_sop_runs (company_id, template_id, outlet_id, run_date, items)
    values (v_company, t.id, v_run_outlet, v_date,
      (select coalesce(jsonb_agg(jsonb_build_object('text', i->>'text', 'photo', coalesce((i->>'photo')::boolean, false), 'done', false)), '[]'::jsonb)
       from jsonb_array_elements(t.items) i))
    on conflict do nothing;
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'template_id', r.template_id, 'name', s.name, 'outlet', o.name,
      'run_date', r.run_date, 'items', r.items, 'completed_at', r.completed_at) order by s.sort_order, s.name)
    from hr_sop_runs r join hr_sop_templates s on s.id = r.template_id left join sys_outlets o on o.id = r.outlet_id
    where r.company_id = v_company and s.is_active
      and (s.role_id is null or s.role_id = v_role)
      and r.outlet_id is not distinct from coalesce(s.outlet_id, v_outlet)
      and r.run_date = (now() at time zone coalesce(o.timezone, 'Asia/Jakarta'))::date), '[]'::jsonb);
end $$;

-- centang item SOP (foto wajib bila item meminta)
create or replace function hr_sop_check(p_run_id uuid, p_index int, p_done boolean, p_photo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_run hr_sop_runs; v_tpl hr_sop_templates; v_item jsonb; v_items jsonb;
begin
  select * into v_run from hr_sop_runs where id = p_run_id and company_id = sys_current_company_id() for update;
  if v_run.id is null then raise exception 'SOP tidak ditemukan'; end if;
  select * into v_tpl from hr_sop_templates where id = v_run.template_id;
  if not (sys_has_permission('task.manage') or v_tpl.role_id is null or v_tpl.role_id = (select role_id from sys_users where id = auth.uid())) then
    raise exception 'SOP ini bukan untuk role Anda';
  end if;
  if v_run.outlet_id is not null and not sys_can_access_outlet(v_run.outlet_id)
     and v_run.outlet_id is distinct from (select outlet_id from hr_employees where user_id = auth.uid()) then
    raise exception 'Tidak punya akses ke outlet ini';
  end if;
  if v_run.run_date < (now() at time zone 'Asia/Jakarta')::date - 1 then raise exception 'SOP hari sebelumnya sudah ditutup'; end if;
  v_item := v_run.items->p_index;
  if v_item is null then raise exception 'Item tidak ditemukan'; end if;
  if p_done and coalesce((v_item->>'photo')::boolean, false) then
    if p_photo is null then raise exception 'Item ini wajib foto'; end if;
    if p_photo not like v_run.company_id || '/sop/' || v_run.id || '/%' then raise exception 'Foto tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'task-files' and name = p_photo) then raise exception 'Foto belum terunggah'; end if;
  end if;
  v_item := case when p_done
    then v_item || jsonb_build_object('done', true, 'by', auth.uid(), 'by_name', (select full_name from sys_users where id = auth.uid()), 'at', now(), 'photo_path', p_photo)
    else (v_item - 'by' - 'by_name' - 'at' - 'photo_path') || jsonb_build_object('done', false) end;
  v_items := jsonb_set(v_run.items, array[p_index::text], v_item);
  update hr_sop_runs set items = v_items,
    completed_at = case when not exists (select 1 from jsonb_array_elements(v_items) i where not coalesce((i->>'done')::boolean, false)) then coalesce(completed_at, now()) end
  where id = p_run_id returning * into v_run;
  return to_jsonb(v_run);
end $$;

-- rekap kepatuhan SOP (manajer): per tanggal x template x outlet
create or replace function hr_sop_report(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_has_permission('task.manage') then raise exception 'Butuh izin kelola tugas'; end if;
  return jsonb_build_object(
    'templates', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', r.name, 'outlet', o.name, 'items', s.items,
        'role_id', s.role_id, 'outlet_id', s.outlet_id, 'is_active', s.is_active, 'sort_order', s.sort_order) order by s.sort_order, s.name)
      from hr_sop_templates s left join sys_roles r on r.id = s.role_id left join sys_outlets o on o.id = s.outlet_id
      where s.company_id = sys_current_company_id()), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'template_id', x.template_id, 'outlet_id', x.outlet_id, 'outlet', o.name,
        'run_date', x.run_date, 'items', x.items, 'completed_at', x.completed_at,
        'done', (select count(*) from jsonb_array_elements(x.items) i where (i->>'done')::boolean),
        'total', jsonb_array_length(x.items)) order by x.run_date desc)
      from hr_sop_runs x left join sys_outlets o on o.id = x.outlet_id
      where x.company_id = sys_current_company_id() and x.run_date between p_from and p_to
        and (p_outlet_id is null or x.outlet_id = p_outlet_id)
        and (x.outlet_id is null or sys_can_access_outlet(x.outlet_id))), '[]'::jsonb));
end $$;

-- badge: tugas baru untuk saya, tugas yang menunggu review saya, item SOP hari ini yang belum
create or replace function hr_task_counts()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'todo', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status in ('new', 'in_progress')
             and (t.assignee_id = auth.uid() or (t.assignee_id is null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid())
                  and (t.outlet_id is null or sys_can_access_outlet(t.outlet_id))))),
    'new', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status = 'new'
             and (t.assignee_id = auth.uid() or (t.assignee_id is null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid())
                  and (t.outlet_id is null or sys_can_access_outlet(t.outlet_id))))
             and t.created_by is distinct from auth.uid()),
    'review', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status = 'review'
             and (t.created_by = auth.uid() or hr_task_is_manager(t.outlet_id)) and t.assignee_id is distinct from auth.uid()),
    'overdue', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status in ('new', 'in_progress')
             and t.due_date < current_date and t.assignee_id = auth.uid()))
$$;

-- ---------------------------------------------------------------------
-- STORAGE PRIVAT: task-files/<company>/tasks/<task_id>/... dan <company>/sop/<run_id>/...
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('task-files', 'task-files', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function hr_task_file_ok(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text and (
    ((storage.foldername(p_name))[2] = 'tasks' and case when (storage.foldername(p_name))[3] ~ '^[0-9a-f-]{36}$'
       then hr_task_visible(((storage.foldername(p_name))[3])::uuid) else false end)
    or ((storage.foldername(p_name))[2] = 'sop' and exists (
      select 1 from hr_sop_runs r where r.id::text = (storage.foldername(p_name))[3] and r.company_id = sys_current_company_id())))
$$;
create policy task_files_select on storage.objects for select to authenticated using (bucket_id = 'task-files' and hr_task_file_ok(name));
create policy task_files_insert on storage.objects for insert to authenticated with check (bucket_id = 'task-files' and hr_task_file_ok(name));
create policy task_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'task-files' and hr_task_file_ok(name) and sys_has_permission('task.manage'));

-- >>>>>>>>>> migrations/037_hr_appraisals.sql
-- =====================================================================
-- SEMAR - 037: SDM / HR FASE E - PENILAIAN KINERJA
--   * hr_appraisal_templates: form per role / jabatan, kriteria berbobot dengan skala 1-5.
--     Kriteria 'rating' dinilai manusia; kriteria 'auto' dihitung dari data:
--     attendance (kehadiran), punctuality (tepat waktu), tasks (tugas selesai tepat waktu), sop (kepatuhan SOP).
--   * hr_appraisal_periods: periode penilaian (mis. Q4 2026).
--   * hr_appraisals: per karyawan per periode. Alur: self (penilaian diri) -> manager (atasan / HR)
--     -> acknowledge (karyawan membaca & menanggapi) -> done. Nilai akhir 1-5 + grade A-E.
--   Izin baru: hr.appraisal (kelola template, periode & semua penilaian). Atasan langsung menilai bawahannya.
-- =====================================================================

create table hr_appraisal_templates (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  name         text not null check (trim(name) <> ''),
  role_id      uuid references sys_roles(id) on delete set null,       -- null = semua role
  position_id  uuid references hr_positions(id) on delete set null,    -- null = semua jabatan
  criteria     jsonb not null default '[]',   -- [{key, name, description, weight, kind: 'rating'|'auto', metric}]
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (jsonb_typeof(criteria) = 'array')
);
select sys_apply_company_policies('hr_appraisal_templates', 'hr.appraisal');
create trigger trg_hr_appraisal_templates_audit after insert or update or delete on hr_appraisal_templates for each row execute function sys_audit_trigger('');

create table hr_appraisal_periods (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  name             text not null check (trim(name) <> ''),
  start_date       date not null,
  end_date         date not null,
  self_assessment  boolean not null default true,
  status           text not null default 'open' check (status in ('open', 'closed')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date >= start_date)
);
select sys_apply_company_policies('hr_appraisal_periods', 'hr.appraisal');
create trigger trg_hr_appraisal_periods_audit after insert or update or delete on hr_appraisal_periods for each row execute function sys_audit_trigger('');

create table hr_appraisals (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  period_id         uuid not null references hr_appraisal_periods(id) on delete cascade,
  employee_id       uuid not null references hr_employees(id) on delete cascade,
  template_id       uuid references hr_appraisal_templates(id) on delete set null,
  template_name     text not null,
  criteria          jsonb not null,                   -- salinan kriteria saat penilaian dimulai
  reviewer_id       uuid references sys_users(id) on delete set null,   -- atasan langsung (null = HR)
  status            text not null default 'self' check (status in ('self', 'manager', 'acknowledge', 'done')),
  self_scores       jsonb not null default '{}',      -- {key: {score, note}}
  self_comment      text,
  self_submitted_at timestamptz,
  manager_scores    jsonb not null default '{}',
  metrics           jsonb,                            -- hasil hitung otomatis saat atasan mengirim
  final_score       numeric(4, 2),
  grade             text,
  strengths         text,
  improvements      text,
  goals             text,
  reviewed_by       uuid references sys_users(id),
  reviewed_at       timestamptz,
  employee_comment  text,
  acknowledged_at   timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (period_id, employee_id)
);
alter table hr_appraisals enable row level security;
-- baca hanya lewat fungsi (nilai atasan disembunyikan dari karyawan sampai dikirim)
create policy hr_appraisals_select on hr_appraisals for select to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.appraisal'));

-- ---------------------------------------------------------------------
-- METRIK OTOMATIS
-- ---------------------------------------------------------------------
create or replace function hr_rate_to_score(p_rate numeric)
returns int language sql immutable as $$
  select case when p_rate is null then null when p_rate >= 0.98 then 5 when p_rate >= 0.95 then 4
              when p_rate >= 0.90 then 3 when p_rate >= 0.80 then 2 else 1 end
$$;

create or replace function hr_appraisal_metrics(p_employee_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_emp hr_employees; v_user uuid; v_role uuid; v_to date := least(p_to, v_today);
  v_sched int; v_present int; v_ontime int; v_done int; v_task_ok int; v_overdue int; v_sop numeric; v_runs int;
begin
  select * into v_emp from hr_employees where id = p_employee_id;
  v_user := v_emp.user_id;
  v_role := coalesce((select role_id from sys_users where id = v_user), (select default_role_id from hr_positions where id = v_emp.position_id));
  -- hari kerja terjadwal (bukan libur, bukan cuti disetujui) sampai hari ini
  select count(*), count(a.id) filter (where a.check_in_at is not null), count(a.id) filter (where a.check_in_at is not null and a.late_minutes = 0)
    into v_sched, v_present, v_ontime
  from hr_rosters r
  left join hr_attendances a on a.employee_id = r.employee_id and a.work_date = r.work_date
  where r.employee_id = p_employee_id and r.work_date between p_from and v_to and not r.is_off and r.shift_id is not null
    and hr_leave_on(p_employee_id, r.work_date) is null;
  -- tugas: selesai dalam periode (tepat waktu = tanpa tenggat / selesai <= tenggat) + yang lewat tenggat & belum selesai
  if v_user is not null then
    select count(*) filter (where status = 'done' and done_at::date between p_from and p_to),
           count(*) filter (where status = 'done' and done_at::date between p_from and p_to and (due_date is null or done_at::date <= due_date)),
           count(*) filter (where status in ('new', 'in_progress', 'review') and due_date between p_from and v_to and due_date < v_today)
      into v_done, v_task_ok, v_overdue
    from hr_tasks where assignee_id = v_user;
  end if;
  -- SOP: rata-rata kelengkapan checklist outlet karyawan untuk role-nya
  select avg((select count(*) from jsonb_array_elements(x.items) i where (i->>'done')::boolean)::numeric / greatest(1, jsonb_array_length(x.items))), count(*)
    into v_sop, v_runs
  from hr_sop_runs x join hr_sop_templates t on t.id = x.template_id
  where x.outlet_id is not distinct from v_emp.outlet_id and x.run_date between p_from and v_to
    and (t.role_id is null or t.role_id = v_role);
  return jsonb_build_object(
    'attendance', jsonb_build_object('scheduled', v_sched, 'present', v_present,
      'rate', case when v_sched > 0 then round(v_present::numeric / v_sched, 4) end,
      'score', hr_rate_to_score(case when v_sched > 0 then v_present::numeric / v_sched end)),
    'punctuality', jsonb_build_object('present', v_present, 'on_time', v_ontime,
      'rate', case when v_present > 0 then round(v_ontime::numeric / v_present, 4) end,
      'score', hr_rate_to_score(case when v_present > 0 then v_ontime::numeric / v_present end)),
    'tasks', jsonb_build_object('done', coalesce(v_done, 0), 'on_time', coalesce(v_task_ok, 0), 'overdue', coalesce(v_overdue, 0),
      'rate', case when coalesce(v_done, 0) + coalesce(v_overdue, 0) > 0 then round(v_task_ok::numeric / (v_done + v_overdue), 4) end,
      'score', hr_rate_to_score(case when coalesce(v_done, 0) + coalesce(v_overdue, 0) > 0 then v_task_ok::numeric / (v_done + v_overdue) end)),
    'sop', jsonb_build_object('runs', v_runs, 'rate', round(v_sop, 4), 'score', hr_rate_to_score(v_sop)));
end $$;

-- nilai akhir: rata-rata berbobot kriteria yang punya nilai (kriteria auto tanpa data diabaikan)
create or replace function hr_appraisal_score(p_criteria jsonb, p_scores jsonb, p_metrics jsonb)
returns jsonb language sql immutable as $$
  with c as (
    select coalesce((x->>'weight')::numeric, 0) as w,
      case when x->>'kind' = 'auto' then (p_metrics->(x->>'metric')->>'score')::numeric
           else nullif(p_scores->(x->>'key')->>'score', '')::numeric end as s
    from jsonb_array_elements(p_criteria) x
  ), t as (select sum(w * s) / nullif(sum(w) filter (where s is not null), 0) as score from c where s is not null)
  select jsonb_build_object('score', round(score, 2), 'grade', case when score is null then null when score >= 4.5 then 'A' when score >= 3.75 then 'B'
                                                                     when score >= 3 then 'C' when score >= 2 then 'D' else 'E' end)
  from t
$$;

-- ---------------------------------------------------------------------
-- PERAN
-- ---------------------------------------------------------------------
create or replace function hr_appraisal_access(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  -- 'hr' / 'reviewer' / 'self' / null
  select case
    when sys_has_permission('hr.appraisal') and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)) and e.user_id is distinct from auth.uid() then 'hr'
    when a.reviewer_id = auth.uid() or hr_is_my_report(e.id) then 'reviewer'
    when e.user_id = auth.uid() then 'self' end
  from hr_appraisals a join hr_employees e on e.id = a.employee_id
  where a.id = p_id and a.company_id = sys_current_company_id()
$$;

-- template yang paling cocok untuk karyawan (jabatan + role > jabatan > role > umum)
create or replace function hr_appraisal_template_for(p_employee_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  with e as (
    select e.*, coalesce((select role_id from sys_users where id = e.user_id), (select default_role_id from hr_positions where id = e.position_id)) as role
    from hr_employees e where e.id = p_employee_id
  )
  select t.id from hr_appraisal_templates t, e
  where t.company_id = e.company_id and t.is_active and jsonb_array_length(t.criteria) > 0
    and (t.position_id is null or t.position_id = e.position_id) and (t.role_id is null or t.role_id = e.role)
  order by (t.position_id is not null)::int * 2 + (t.role_id is not null)::int desc, t.created_at
  limit 1
$$;

-- mulai penilaian untuk semua karyawan aktif (atau yang dipilih) pada periode
create or replace function hr_appraisal_start(p_period_id uuid, p_employee_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_period hr_appraisal_periods; e record; v_tpl hr_appraisal_templates; v_n int := 0; v_skip text[] := '{}';
begin
  if not sys_has_permission('hr.appraisal') then raise exception 'Butuh izin kelola penilaian'; end if;
  select * into v_period from hr_appraisal_periods where id = p_period_id and company_id = sys_current_company_id();
  if v_period.id is null then raise exception 'Periode tidak ditemukan'; end if;
  if v_period.status <> 'open' then raise exception 'Periode sudah ditutup'; end if;
  for e in select * from hr_employees where company_id = v_period.company_id and is_active
             and (p_employee_ids is null or id = any(p_employee_ids))
             and (outlet_id is null or sys_can_access_outlet(outlet_id))
             and not exists (select 1 from hr_appraisals a where a.period_id = p_period_id and a.employee_id = hr_employees.id) loop
    select * into v_tpl from hr_appraisal_templates where id = hr_appraisal_template_for(e.id);
    if v_tpl.id is null then v_skip := v_skip || e.full_name; continue; end if;
    insert into hr_appraisals (company_id, period_id, employee_id, template_id, template_name, criteria, reviewer_id, status)
    values (v_period.company_id, p_period_id, e.id, v_tpl.id, v_tpl.name, v_tpl.criteria,
      (select m.user_id from hr_employees m where m.id = e.manager_id),
      case when v_period.self_assessment and e.user_id is not null then 'self' else 'manager' end);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('created', v_n, 'skipped', to_jsonb(v_skip));
end $$;

-- detail sesuai peran (nilai atasan & hasil disembunyikan dari karyawan sampai dikirim)
create or replace function hr_appraisal_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_role text := hr_appraisal_access(p_id); v jsonb;
begin
  if v_role is null then return null; end if;
  select to_jsonb(a) || jsonb_build_object('access', v_role, 'period', p.name, 'start_date', p.start_date, 'end_date', p.end_date,
      'full_name', e.full_name, 'employee_number', e.employee_number, 'position', ps.name, 'outlet', o.name, 'photo_path', e.photo_path,
      'reviewer', (select full_name from sys_users where id = coalesce(a.reviewed_by, a.reviewer_id)),
      'live_metrics', case when a.status in ('self', 'manager') and v_role <> 'self' then hr_appraisal_metrics(a.employee_id, p.start_date, p.end_date) end)
    into v
  from hr_appraisals a join hr_appraisal_periods p on p.id = a.period_id join hr_employees e on e.id = a.employee_id
  left join hr_positions ps on ps.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
  where a.id = p_id;
  if v_role = 'self' and v->>'status' in ('self', 'manager') then
    v := v - 'manager_scores' - 'final_score' - 'grade' - 'strengths' - 'improvements' - 'goals' - 'metrics';
  end if;
  return v;
end $$;

create or replace function hr_appraisal_submit_self(p_id uuid, p_scores jsonb, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if hr_appraisal_access(p_id) is distinct from 'self' then raise exception 'Ini bukan penilaian diri Anda'; end if;
  if (select status from hr_appraisals where id = p_id) <> 'self' then raise exception 'Penilaian diri sudah dikirim'; end if;
  update hr_appraisals set self_scores = coalesce(p_scores, '{}'), self_comment = nullif(trim(coalesce(p_comment, '')), ''),
    self_submitted_at = now(), status = 'manager', updated_at = now()
  where id = p_id;
end $$;

-- atasan / HR mengirim penilaian: metrik otomatis dibekukan, nilai akhir & grade dihitung
create or replace function hr_appraisal_submit_manager(p_id uuid, p_scores jsonb, p_strengths text, p_improvements text, p_goals text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role text := hr_appraisal_access(p_id); v_a hr_appraisals; v_p hr_appraisal_periods; v_metrics jsonb; v_res jsonb; v_has_user boolean;
begin
  if v_role is null or v_role = 'self' then raise exception 'Anda bukan penilai karyawan ini'; end if;
  select * into v_a from hr_appraisals where id = p_id for update;
  if v_a.status = 'self' and v_role <> 'hr' then raise exception 'Menunggu penilaian diri karyawan'; end if;
  if v_a.status in ('acknowledge', 'done') then raise exception 'Penilaian sudah dikirim'; end if;
  -- semua kriteria rating wajib diisi 1-5
  if exists (select 1 from jsonb_array_elements(v_a.criteria) c where c->>'kind' <> 'auto'
             and coalesce(nullif(p_scores->(c->>'key')->>'score', '')::numeric, 0) not between 1 and 5) then
    raise exception 'Semua kriteria wajib dinilai 1-5';
  end if;
  select * into v_p from hr_appraisal_periods where id = v_a.period_id;
  v_metrics := hr_appraisal_metrics(v_a.employee_id, v_p.start_date, v_p.end_date);
  v_res := hr_appraisal_score(v_a.criteria, p_scores, v_metrics);
  v_has_user := (select user_id is not null from hr_employees where id = v_a.employee_id);
  update hr_appraisals set manager_scores = p_scores, metrics = v_metrics, final_score = (v_res->>'score')::numeric, grade = v_res->>'grade',
    strengths = nullif(trim(coalesce(p_strengths, '')), ''), improvements = nullif(trim(coalesce(p_improvements, '')), ''),
    goals = nullif(trim(coalesce(p_goals, '')), ''), reviewed_by = auth.uid(), reviewed_at = now(),
    status = case when v_has_user then 'acknowledge' else 'done' end, updated_at = now()
  where id = p_id;
  return v_res;
end $$;

create or replace function hr_appraisal_acknowledge(p_id uuid, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if hr_appraisal_access(p_id) is distinct from 'self' then raise exception 'Ini bukan penilaian Anda'; end if;
  if (select status from hr_appraisals where id = p_id) <> 'acknowledge' then raise exception 'Belum bisa dikonfirmasi'; end if;
  update hr_appraisals set employee_comment = nullif(trim(coalesce(p_comment, '')), ''), acknowledged_at = now(), status = 'done', updated_at = now()
  where id = p_id;
end $$;

-- HR membuka kembali penilaian (mis. salah nilai)
create or replace function hr_appraisal_reopen(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if hr_appraisal_access(p_id) is distinct from 'hr' then raise exception 'Butuh izin kelola penilaian'; end if;
  update hr_appraisals set status = 'manager', acknowledged_at = null, employee_comment = null, updated_at = now() where id = p_id;
end $$;

-- daftar untuk saya: penilaian diri / hasil saya + yang harus saya nilai
create or replace function hr_my_appraisals()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'period', p.name, 'full_name', e.full_name, 'status', a.status,
      'access', hr_appraisal_access(a.id), 'grade', case when a.status in ('acknowledge', 'done') then a.grade end,
      'final_score', case when a.status in ('acknowledge', 'done') then a.final_score end, 'end_date', p.end_date)
    order by p.end_date desc, e.full_name), '[]'::jsonb)
  from hr_appraisals a join hr_appraisal_periods p on p.id = a.period_id join hr_employees e on e.id = a.employee_id
  where a.company_id = sys_current_company_id()
    and (e.user_id = auth.uid() or ((a.reviewer_id = auth.uid() or hr_is_my_report(e.id)) and e.user_id is distinct from auth.uid()))
    and (a.status <> 'done' or p.end_date > current_date - 120)
$$;

-- jumlah yang perlu tindakan saya (badge)
create or replace function hr_appraisal_todo_count()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from hr_appraisals a join hr_employees e on e.id = a.employee_id
  where a.company_id = sys_current_company_id() and (
    (e.user_id = auth.uid() and a.status in ('self', 'acknowledge'))
    or (a.status = 'manager' and e.user_id is distinct from auth.uid() and (a.reviewer_id = auth.uid() or hr_is_my_report(e.id))))
$$;

-- ringkasan periode untuk HR
create or replace function hr_appraisal_overview(p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_has_permission('hr.appraisal') then raise exception 'Butuh izin kelola penilaian'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'employee_id', e.id, 'full_name', e.full_name, 'employee_number', e.employee_number,
      'position', ps.name, 'outlet', o.name, 'template_name', a.template_name, 'status', a.status, 'final_score', a.final_score, 'grade', a.grade,
      'reviewer', (select full_name from sys_users where id = coalesce(a.reviewed_by, a.reviewer_id)), 'acknowledged_at', a.acknowledged_at)
    order by e.full_name)
    from hr_appraisals a join hr_employees e on e.id = a.employee_id left join hr_positions ps on ps.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
    where a.period_id = p_period_id and a.company_id = sys_current_company_id() and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))), '[]'::jsonb);
end $$;

-- >>>>>>>>>> migrations/038_hr_user_link.sql
-- =====================================================================
-- SEMAR - 038: USER MANAGEMENT <-> DATA KARYAWAN
--   * hr_user_links(): akun mana yang sudah / belum punya data karyawan (hanya id & nomor karyawan,
--     tanpa data pribadi), untuk User Management. Tidak terpengaruh kunci outlet, jadi tidak salah
--     menandai "belum ada data karyawan".
--   * hr_create_employee_for_user(): buat data karyawan dari akun (nama, HP, email asli, outlet, jabatan
--     yang role default-nya cocok). Butuh hr.manage; hanya akun di perusahaan yang sama.
-- =====================================================================

create or replace function hr_user_links()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when sys_has_permission('user.manage') or sys_has_permission('hr.view') or sys_has_permission('hr.manage') then
    coalesce((select jsonb_agg(jsonb_build_object('user_id', e.user_id, 'employee_id', e.id, 'employee_number', e.employee_number, 'is_active', e.is_active))
      from hr_employees e where e.company_id = sys_current_company_id() and e.user_id is not null), '[]'::jsonb)
  else '[]'::jsonb end
$$;

create or replace function hr_create_employee_for_user(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_user sys_users; v_email text; v_outlet uuid; v_position uuid; v_emp hr_employees;
begin
  if not sys_has_permission('hr.manage') then raise exception 'Butuh izin kelola karyawan'; end if;
  select * into v_user from sys_users where id = p_user_id and company_id = v_company;
  if v_user.id is null then raise exception 'User tidak ditemukan'; end if;
  if exists (select 1 from hr_employees where user_id = p_user_id) then raise exception 'User ini sudah punya data karyawan'; end if;
  -- email sintetis akun staf (username@staff.santap.local) tidak disalin
  select nullif(email, '') into v_email from auth.users where id = p_user_id;
  if v_email like '%@staff.santap.local' then v_email := null; end if;
  -- outlet: satu-satunya outlet akun (bila hanya satu) yang juga boleh diakses HR ini
  select min(uo.outlet_id::text)::uuid into v_outlet from sys_user_outlets uo where uo.user_id = p_user_id
  having count(*) = 1;
  if v_outlet is not null and not sys_can_access_outlet(v_outlet) then raise exception 'Tidak punya akses ke outlet user ini'; end if;
  -- jabatan: hanya bila tepat satu jabatan aktif ber-role default sama
  select min(id::text)::uuid into v_position from hr_positions
  where company_id = v_company and is_active and default_role_id = v_user.role_id having count(*) = 1;
  insert into hr_employees (company_id, user_id, full_name, phone, email, outlet_id, position_id, department_id)
  values (v_company, p_user_id, v_user.full_name, v_user.phone, v_email, v_outlet, v_position,
          (select department_id from hr_positions where id = v_position))
  returning * into v_emp;
  return jsonb_build_object('id', v_emp.id, 'employee_number', v_emp.employee_number);
end $$;

-- >>>>>>>>>> migrations/039_receipt_feedback.sql
-- =====================================================================
-- SEMAR - 039: STRUK 80MM + QR ULASAN PELANGGAN
--   * sys_outlets: pengaturan struk (teks atas/bawah, logo, QR ulasan, link Google review).
--   * pos_receipt_data(): semua isi struk dalam satu panggilan (logo brand, kasir, item, pembayaran,
--     member, token ulasan). Token acak dibuat saat struk pertama dicetak.
--   * crm_feedback_settings / crm_feedback_questions / crm_feedback_responses: satu form ulasan + saran
--     yang dibuka dari QR di struk (tanpa login). Pertanyaan bisa diatur; analisa (rating, NPS, aspek,
--     tren, per outlet) & tindak lanjut ulasan buruk.
--   Izin baru: feedback.view (lihat ulasan & analisa), feedback.manage (atur form & tindak lanjut).
-- =====================================================================

alter table sys_outlets add column if not exists receipt_header text;
alter table sys_outlets add column if not exists receipt_footer text not null default 'Terima kasih atas kunjungan Anda';
alter table sys_outlets add column if not exists receipt_show_logo boolean not null default true;
alter table sys_outlets add column if not exists receipt_show_feedback_qr boolean not null default true;
alter table sys_outlets add column if not exists google_review_url text check (google_review_url is null or google_review_url ~ '^https://');
alter table sys_companies add column if not exists tax_number text;

alter table pos_orders add column if not exists feedback_token text unique;

-- ---------------------------------------------------------------------
-- FORM ULASAN
-- ---------------------------------------------------------------------
create table crm_feedback_settings (
  company_id      uuid primary key references sys_companies(id),
  is_enabled      boolean not null default true,
  title           text not null default 'Bagaimana pengalamanmu?',
  intro           text not null default 'Butuh kurang dari 1 menit. Masukanmu langsung dibaca tim kami.',
  thank_you       text not null default 'Terima kasih! Masukanmu sangat berarti untuk kami.',
  incentive_text  text,                          -- mis. "Tunjukkan halaman ini: gratis es teh di kunjungan berikutnya"
  ask_contact     boolean not null default true,
  max_days        int not null default 14 check (max_days between 1 and 90),
  updated_at      timestamptz not null default now()
);
select sys_apply_company_policies('crm_feedback_settings', 'feedback.manage');

create table crm_feedback_questions (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  kind        text not null check (kind in ('stars', 'aspects', 'nps', 'choice', 'text')),
  label       text not null check (trim(label) <> ''),
  help        text,
  options     text[] not null default '{}',     -- aspek (aspects) / pilihan (choice)
  is_overall  boolean not null default false,   -- rating utama (dipakai untuk rata-rata & sentimen)
  required    boolean not null default false,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (kind not in ('aspects', 'choice') or cardinality(options) > 0)
);
select sys_apply_company_policies('crm_feedback_questions', 'feedback.manage');
create trigger trg_crm_feedback_questions_audit after insert or update or delete on crm_feedback_questions for each row execute function sys_audit_trigger('');

create table crm_feedback_responses (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid references sys_outlets(id) on delete set null,
  order_id       uuid unique references pos_orders(id) on delete set null,
  answers        jsonb not null default '{}',   -- {question_id: nilai}
  overall        int check (overall between 1 and 5),
  nps            int check (nps between 0 and 10),
  comment        text,                          -- gabungan jawaban teks (untuk pencarian & daftar)
  contact_name   text,
  contact_phone  text,
  contact_ok     boolean not null default false,
  status         text not null default 'new' check (status in ('new', 'followed_up', 'resolved')),
  follow_note    text,
  handled_by     uuid references sys_users(id),
  handled_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index crm_feedback_responses_company_date on crm_feedback_responses (company_id, created_at);
alter table crm_feedback_responses enable row level security;
create policy crm_feedback_responses_select on crm_feedback_responses for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('feedback.view') or sys_has_permission('feedback.manage'))
         and (outlet_id is null or sys_can_access_outlet(outlet_id)));
-- tulis hanya lewat fungsi

-- pertanyaan standar (pendek: 5 layar, < 1 menit)
create or replace function crm_setup_feedback(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into crm_feedback_settings (company_id) values (p_company_id) on conflict do nothing;
  if exists (select 1 from crm_feedback_questions where company_id = p_company_id) then return; end if;
  insert into crm_feedback_questions (company_id, kind, label, help, options, is_overall, required, sort_order) values
    (p_company_id, 'stars', 'Secara keseluruhan, bagaimana kunjunganmu hari ini?', null, '{}', true, true, 10),
    (p_company_id, 'aspects', 'Nilai beberapa hal ini', 'Lewati yang tidak kamu rasakan',
       array['Rasa makanan & minuman', 'Kecepatan penyajian', 'Keramahan staf', 'Kebersihan tempat', 'Harga sesuai kualitas'], false, false, 20),
    (p_company_id, 'nps', 'Seberapa mungkin kamu merekomendasikan kami ke teman?', '0 = tidak mungkin, 10 = sangat mungkin', '{}', false, false, 30),
    (p_company_id, 'choice', 'Apa yang paling kamu suka?', 'Boleh pilih lebih dari satu',
       array['Rasa', 'Porsi', 'Harga', 'Pelayanan', 'Suasana', 'Kecepatan', 'Kebersihan'], false, false, 40),
    (p_company_id, 'text', 'Ada saran atau masukan untuk kami?', 'Menu yang kamu inginkan, hal yang perlu diperbaiki, apa saja', '{}', false, false, 50);
end $$;
do $$
declare c record;
begin
  for c in select id from sys_companies loop perform crm_setup_feedback(c.id); end loop;
end $$;
create or replace function crm_company_feedback_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform crm_setup_feedback(new.id);
  return new;
end $$;
create trigger trg_sys_companies_feedback after insert on sys_companies for each row execute function crm_company_feedback_trigger();

-- ---------------------------------------------------------------------
-- DATA STRUK
-- ---------------------------------------------------------------------
create or replace function pos_receipt_data(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_o pos_orders; v_token text;
begin
  select * into v_o from pos_orders where id = p_order_id and company_id = sys_current_company_id();
  if v_o.id is null or not sys_can_access_outlet(v_o.outlet_id) then raise exception 'Order tidak ditemukan'; end if;
  if not (sys_has_permission('pos.order') or sys_has_permission('pos.pay') or sys_has_permission('report.view')) then raise exception 'Butuh izin kasir'; end if;
  -- token ulasan acak (tidak bisa ditebak) untuk order yang sudah dibayar
  if v_o.status = 'paid' and v_o.feedback_token is null then
    update pos_orders set feedback_token = replace(gen_random_uuid()::text, '-', '') where id = v_o.id returning feedback_token into v_token;
  else
    v_token := v_o.feedback_token;
  end if;
  return pos_receipt_payload(v_o.id) || jsonb_build_object('feedback_token', case when v_o.status = 'paid' then v_token end);
end $$;

-- isi struk (dipakai kasir & nanti kiosk); tanpa cek izin -> jangan dipanggil langsung dari klien
create or replace function pos_receipt_payload(p_order_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'status', o.status, 'sales_channel', o.sales_channel,
      'order_source', o.order_source, 'customer_name', o.customer_name, 'guest_count', o.guest_count, 'note', o.note,
      'created_at', o.created_at, 'paid_at', o.paid_at, 'table', t.code,
      'subtotal', o.subtotal, 'discount_amount', o.discount_amount, 'promotion_amount', o.promotion_amount, 'promotion', pr.name,
      'points_redeemed', o.points_redeemed, 'points_amount', o.points_amount, 'points_earned', o.points_earned,
      'service_amount', o.service_amount, 'tax_amount', o.tax_amount, 'rounding_amount', o.rounding_amount, 'grand_total', o.grand_total,
      'cashier', (select full_name from sys_users where id = o.created_by)),
    'outlet', jsonb_build_object('name', ol.name, 'address', ol.address, 'phone', ol.phone, 'tax_rate', ol.tax_rate,
      'header', ol.receipt_header, 'footer', ol.receipt_footer, 'show_logo', ol.receipt_show_logo,
      'show_feedback_qr', ol.receipt_show_feedback_qr and coalesce(fs.is_enabled, true)),
    'brand', jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url)),
    'company', jsonb_build_object('name', c.name, 'tax_number', c.tax_number),
    'feedback', jsonb_build_object('title', fs.title, 'incentive', fs.incentive_text),
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.menu_item_name, 'qty', i.quantity, 'unit_price', i.unit_price,
        'line_total', i.line_total, 'note', i.note,
        'modifiers', coalesce((select jsonb_agg(m.modifier_name) from pos_order_item_modifiers m where m.order_item_id = i.id), '[]'::jsonb))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', pm.name, 'amount', p.amount, 'change', p.change_amount) order by p.created_at)
      from pos_payments p join mst_payment_methods pm on pm.id = p.payment_method_id where p.order_id = o.id), '[]'::jsonb),
    'member', case when cu.id is not null then jsonb_build_object('name', cu.name, 'points_balance', cu.points_balance) end)
  from pos_orders o
  join sys_outlets ol on ol.id = o.outlet_id
  join sys_companies c on c.id = o.company_id
  left join sys_brands b on b.id = ol.brand_id
  left join mst_tables t on t.id = o.table_id
  left join crm_promotions pr on pr.id = o.promotion_id
  left join crm_customers cu on cu.id = o.customer_id
  left join crm_feedback_settings fs on fs.company_id = o.company_id
  where o.id = p_order_id
$$;
revoke execute on function pos_receipt_payload(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- FORM PUBLIK (tanpa login, dari QR di struk)
-- ---------------------------------------------------------------------
create or replace function public_feedback_form(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_o pos_orders; v_set crm_feedback_settings; v_state text;
begin
  if coalesce(length(p_token), 0) <> 32 then return jsonb_build_object('state', 'invalid'); end if;
  select * into v_o from pos_orders where feedback_token = p_token and status = 'paid';
  if v_o.id is null then return jsonb_build_object('state', 'invalid'); end if;
  select * into v_set from crm_feedback_settings where company_id = v_o.company_id;
  v_state := case
    when not coalesce(v_set.is_enabled, true) then 'disabled'
    when exists (select 1 from crm_feedback_responses where order_id = v_o.id) then 'done'
    when coalesce(v_o.paid_at, v_o.created_at) < now() - make_interval(days => coalesce(v_set.max_days, 14)) then 'expired'
    else 'open' end;
  -- hanya info yang perlu untuk form: nama outlet & brand, tanggal kunjungan (tanpa harga / isi pesanan)
  return jsonb_build_object('state', v_state,
    'outlet', (select name from sys_outlets where id = v_o.outlet_id),
    'brand', (select jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url))
              from sys_outlets ol join sys_companies c on c.id = ol.company_id left join sys_brands b on b.id = ol.brand_id where ol.id = v_o.outlet_id),
    'visited_at', coalesce(v_o.paid_at, v_o.created_at),
    'google_review_url', (select google_review_url from sys_outlets where id = v_o.outlet_id),
    'settings', jsonb_build_object('title', coalesce(v_set.title, 'Bagaimana pengalamanmu?'), 'intro', v_set.intro, 'thank_you', v_set.thank_you,
      'incentive', v_set.incentive_text, 'ask_contact', coalesce(v_set.ask_contact, true)),
    'questions', case when v_state = 'open' then coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'label', q.label,
        'help', q.help, 'options', q.options, 'required', q.required, 'is_overall', q.is_overall) order by q.sort_order, q.created_at)
      from crm_feedback_questions q where q.company_id = v_o.company_id and q.is_active), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- kirim ulasan: satu kali per struk, divalidasi terhadap pertanyaan aktif
create or replace function public_submit_feedback(p_token text, p_answers jsonb, p_contact jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_o pos_orders; v_form jsonb; q record; v jsonb; v_clean jsonb := '{}'; v_overall int; v_nps int; v_texts text[] := '{}';
  v_phone text := nullif(regexp_replace(coalesce(p_contact->>'phone', ''), '[^0-9+]', '', 'g'), '');
begin
  v_form := public_feedback_form(p_token);
  if v_form->>'state' <> 'open' then raise exception '%', case v_form->>'state'
    when 'done' then 'Ulasan untuk struk ini sudah dikirim. Terima kasih!' when 'expired' then 'Batas waktu ulasan untuk struk ini sudah lewat'
    when 'disabled' then 'Form ulasan sedang tidak aktif' else 'Link ulasan tidak valid' end; end if;
  select * into v_o from pos_orders where feedback_token = p_token;
  if jsonb_typeof(coalesce(p_answers, '{}'::jsonb)) <> 'object' then raise exception 'Jawaban tidak valid'; end if;
  for q in select * from crm_feedback_questions where company_id = v_o.company_id and is_active loop
    v := p_answers->(q.id::text);
    if v is null or v = 'null'::jsonb or v = '""'::jsonb or v = '[]'::jsonb or v = '{}'::jsonb then
      if q.required then raise exception 'Pertanyaan "%" wajib dijawab', q.label; end if;
      continue;
    end if;
    if q.kind = 'stars' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric not in (1, 2, 3, 4, 5) then raise exception 'Nilai bintang tidak valid'; end if;
      if q.is_overall and v_overall is null then v_overall := (v #>> '{}')::int; end if;
    elsif q.kind = 'nps' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric not between 0 and 10 or (v #>> '{}')::numeric <> floor((v #>> '{}')::numeric) then raise exception 'Nilai rekomendasi tidak valid'; end if;
      v_nps := coalesce(v_nps, (v #>> '{}')::int);
    elsif q.kind = 'aspects' then
      if jsonb_typeof(v) <> 'object' or exists (select 1 from jsonb_each(v) e
          where not (e.key = any(q.options)) or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}')::numeric not in (1, 2, 3, 4, 5)) then
        raise exception 'Nilai aspek tidak valid';
      end if;
    elsif q.kind = 'choice' then
      if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements_text(v) x where not (x = any(q.options))) then raise exception 'Pilihan tidak valid'; end if;
    else
      if jsonb_typeof(v) <> 'string' then raise exception 'Jawaban teks tidak valid'; end if;
      v := to_jsonb(left(trim(v #>> '{}'), 1000));
      v_texts := v_texts || (v #>> '{}');
    end if;
    v_clean := v_clean || jsonb_build_object(q.id::text, v);
  end loop;
  insert into crm_feedback_responses (company_id, outlet_id, order_id, answers, overall, nps, comment, contact_name, contact_phone, contact_ok)
  values (v_o.company_id, v_o.outlet_id, v_o.id, v_clean, v_overall, v_nps, nullif(array_to_string(v_texts, E'\n'), ''),
    left(nullif(trim(coalesce(p_contact->>'name', '')), ''), 80), left(v_phone, 20),
    coalesce((p_contact->>'ok')::boolean, false) and v_phone is not null);
  return jsonb_build_object('ok', true, 'thank_you', v_form->'settings'->>'thank_you', 'incentive', v_form->'settings'->>'incentive',
    'google_review_url', case when v_overall >= 4 then v_form->>'google_review_url' end);
end $$;
grant execute on function public_feedback_form(text) to anon, authenticated;
grant execute on function public_submit_feedback(text, jsonb, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- ANALISA & TINDAK LANJUT
-- ---------------------------------------------------------------------
create or replace function crm_feedback_summary(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (sys_has_permission('feedback.view') or sys_has_permission('feedback.manage')) then raise exception 'Butuh izin lihat ulasan'; end if;
  return (
    with r as (
      select * from crm_feedback_responses
      where company_id = v_company and (created_at at time zone 'Asia/Jakarta')::date between p_from and p_to
        and (p_outlet_id is null or outlet_id = p_outlet_id) and (outlet_id is null or sys_can_access_outlet(outlet_id))
    ), paid as (
      select count(*) as n from pos_orders where company_id = v_company and status = 'paid' and business_date between p_from and p_to
        and (p_outlet_id is null or outlet_id = p_outlet_id) and sys_can_access_outlet(outlet_id)
    )
    select jsonb_build_object(
      'responses', (select count(*) from r),
      'paid_orders', (select n from paid),
      'avg_overall', (select round(avg(overall), 2) from r),
      'overall_dist', (select jsonb_object_agg(s, (select count(*) from r where overall = s)) from generate_series(1, 5) s),
      'nps', (select case when count(nps) > 0 then round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(nps)) end from r),
      'nps_count', (select count(nps) from r),
      'negative_open', (select count(*) from r where overall <= 2 and status = 'new'),
      'questions', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'label', q.label,
          'stats', case q.kind
            when 'stars' then jsonb_build_object('avg', (select round(avg((answers->>q.id::text)::numeric), 2) from r where answers ? q.id::text),
                                                 'count', (select count(*) from r where answers ? q.id::text))
            when 'aspects' then (select jsonb_object_agg(a, (select jsonb_build_object('avg', round(avg((answers->q.id::text->>a)::numeric), 2),
                                    'count', count(answers->q.id::text->>a)) from r where answers->q.id::text ? a)) from unnest(q.options) a)
            when 'choice' then (select jsonb_object_agg(a, (select count(*) from r where answers->q.id::text ? a)) from unnest(q.options) a)
            else jsonb_build_object('count', (select count(*) from r where answers ? q.id::text)) end) order by q.sort_order)
        from crm_feedback_questions q where q.company_id = v_company and q.kind <> 'nps'), '[]'::jsonb),
      'trend', coalesce((select jsonb_agg(jsonb_build_object('week', w, 'count', n, 'avg', a) order by w)
        from (select date_trunc('week', created_at at time zone 'Asia/Jakarta')::date as w, count(*) as n, round(avg(overall), 2) as a from r group by 1) t), '[]'::jsonb),
      'outlets', coalesce((select jsonb_agg(jsonb_build_object('outlet', o.name, 'count', x.n, 'avg', x.a, 'nps', x.nps) order by x.a desc nulls last)
        from (select outlet_id, count(*) as n, round(avg(overall), 2) as a,
                case when count(nps) > 0 then round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(nps)) end as nps
              from r group by outlet_id) x left join sys_outlets o on o.id = x.outlet_id), '[]'::jsonb)));
end $$;

create or replace function crm_feedback_list(p_from date, p_to date, p_outlet_id uuid default null, p_filter text default 'all')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (sys_has_permission('feedback.view') or sys_has_permission('feedback.manage')) then raise exception 'Butuh izin lihat ulasan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('outlet', o.name, 'order_number', po.order_number, 'grand_total', po.grand_total,
      'handler', (select full_name from sys_users where id = r.handled_by)) order by r.created_at desc)
    from crm_feedback_responses r left join sys_outlets o on o.id = r.outlet_id left join pos_orders po on po.id = r.order_id
    where r.company_id = sys_current_company_id() and (r.created_at at time zone 'Asia/Jakarta')::date between p_from and p_to
      and (p_outlet_id is null or r.outlet_id = p_outlet_id) and (r.outlet_id is null or sys_can_access_outlet(r.outlet_id))
      and case p_filter when 'negative' then r.overall <= 2 when 'positive' then r.overall >= 4 when 'comment' then r.comment is not null
                        when 'open' then r.status = 'new' and r.overall <= 3 else true end), '[]'::jsonb);
end $$;

create or replace function crm_feedback_update(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_r crm_feedback_responses;
begin
  if not sys_has_permission('feedback.manage') then raise exception 'Butuh izin kelola ulasan'; end if;
  select * into v_r from crm_feedback_responses where id = p_id and company_id = sys_current_company_id();
  if v_r.id is null or (v_r.outlet_id is not null and not sys_can_access_outlet(v_r.outlet_id)) then raise exception 'Ulasan tidak ditemukan'; end if;
  if p_status not in ('new', 'followed_up', 'resolved') then raise exception 'Status tidak dikenal'; end if;
  update crm_feedback_responses set status = p_status, follow_note = coalesce(nullif(trim(coalesce(p_note, '')), ''), follow_note),
    handled_by = auth.uid(), handled_at = now() where id = p_id;
end $$;

-- badge: ulasan buruk (<= 2 bintang) yang belum ditindaklanjuti
create or replace function crm_feedback_open_count()
returns int language sql stable security definer set search_path = public as $$
  select case when sys_has_permission('feedback.manage') or sys_has_permission('feedback.view') then
    (select count(*)::int from crm_feedback_responses where company_id = sys_current_company_id() and status = 'new' and overall <= 2
       and (outlet_id is null or sys_can_access_outlet(outlet_id))) else 0 end
$$;

-- >>>>>>>>>> migrations/040_self_kiosk.sql
-- =====================================================================
-- SEMAR - 040: SELF-ORDER KIOSK (layar sentuh berdiri / portrait)
--   * pos_kiosks: perangkat kiosk per outlet, dibuka lewat /kiosk/<token> (tanpa login staf).
--     Pengaturan: makan di sini / bawa pulang, teks sambutan, waktu idle, cetak struk.
--   * mst_menu_items.kiosk_featured / kiosk_badge: menu unggulan di layar sambutan & rekomendasi.
--     "Terlaris" dihitung otomatis dari penjualan 30 hari.
--   * pos_orders.queue_number: nomor antrean kiosk harian (K001, K002, ...).
--   * Bayar di kasir: item kiosk menunggu (waiting) dan otomatis masuk dapur saat kasir menerima
--     pembayaran, jadi dapur tidak memasak pesanan yang belum dibayar.
--   Izin baru: kiosk.manage (atur perangkat kiosk & menu unggulan).
-- =====================================================================

create table pos_kiosks (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  outlet_id         uuid not null references sys_outlets(id) on delete cascade,
  name              text not null check (trim(name) <> ''),
  token             text not null unique default replace(gen_random_uuid()::text, '-', ''),
  is_active         boolean not null default true,
  allow_dine_in     boolean not null default true,
  allow_takeaway    boolean not null default true,
  welcome_title     text not null default 'Pesan sendiri, lebih cepat',
  welcome_subtitle  text not null default 'Sentuh layar untuk mulai',
  idle_seconds      int not null default 90 check (idle_seconds between 30 and 600),
  print_receipt     boolean not null default true,
  last_seen_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (allow_dine_in or allow_takeaway)
);
alter table pos_kiosks enable row level security;
create policy pos_kiosks_select on pos_kiosks for select to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('kiosk.manage'));
create policy pos_kiosks_write on pos_kiosks for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('kiosk.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('kiosk.manage'));
select sys_apply_outlet_lock('pos_kiosks', 'sys_can_access_outlet(outlet_id)');
create trigger trg_pos_kiosks_audit after insert or update or delete on pos_kiosks for each row execute function sys_audit_trigger('token');

alter table mst_menu_items add column if not exists kiosk_featured boolean not null default false;
alter table mst_menu_items add column if not exists kiosk_badge text check (kiosk_badge is null or length(kiosk_badge) <= 16);
alter table pos_orders add column if not exists queue_number text;
alter table pos_orders add column if not exists kiosk_id uuid references pos_kiosks(id) on delete set null;

create or replace function pos_kiosk_regenerate_token(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text := replace(gen_random_uuid()::text, '-', '');
begin
  if not sys_has_permission('kiosk.manage') then raise exception 'Butuh izin atur kiosk'; end if;
  update pos_kiosks set token = v, updated_at = now()
  where id = p_id and company_id = sys_current_company_id() and sys_can_access_outlet(outlet_id);
  if not found then raise exception 'Kiosk tidak ditemukan'; end if;
  return v;
end $$;

-- menu unggulan (tanpa perlu izin master data penuh)
create or replace function pos_kiosk_set_highlight(p_item_id uuid, p_featured boolean, p_badge text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('kiosk.manage') then raise exception 'Butuh izin atur kiosk'; end if;
  update mst_menu_items set kiosk_featured = coalesce(p_featured, false), kiosk_badge = nullif(left(trim(coalesce(p_badge, '')), 16), '')
  where id = p_item_id and company_id = sys_current_company_id();
  if not found then raise exception 'Menu tidak ditemukan'; end if;
end $$;

-- ---------------------------------------------------------------------
-- PUBLIK (perangkat kiosk, tanpa login) - diakses dengan token kiosk
-- ---------------------------------------------------------------------
create or replace function public_kiosk_menu(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_k pos_kiosks; v_o sys_outlets; v_date date;
begin
  select * into v_k from pos_kiosks where token = p_token and is_active;
  if v_k.id is null or coalesce(length(p_token), 0) <> 32 then raise exception 'Kiosk tidak dikenal. Hubungi staf.'; end if;
  select * into v_o from sys_outlets where id = v_k.outlet_id;
  if not v_o.is_active then raise exception 'Outlet sedang tutup.'; end if;
  update pos_kiosks set last_seen_at = now() where id = v_k.id;
  v_date := sys_outlet_business_date(v_o.id);
  return jsonb_build_object(
    'kiosk', jsonb_build_object('name', v_k.name, 'allow_dine_in', v_k.allow_dine_in, 'allow_takeaway', v_k.allow_takeaway,
      'welcome_title', v_k.welcome_title, 'welcome_subtitle', v_k.welcome_subtitle, 'idle_seconds', v_k.idle_seconds, 'print_receipt', v_k.print_receipt),
    'outlet', jsonb_build_object('name', v_o.name, 'tax_rate', v_o.tax_rate, 'service_charge_rate', v_o.service_charge_rate),
    'brand', (select jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url))
              from sys_companies c left join sys_brands b on b.id = v_o.brand_id where c.id = v_o.company_id),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
          'image_url', (select i.image_url from mst_menu_items i where i.menu_category_id = c.id and i.is_active and i.image_url is not null order by i.kiosk_featured desc, i.name limit 1))
        order by c.sort_order, c.name)
      from mst_menu_categories c
      where c.company_id = v_o.company_id and c.brand_id = v_o.brand_id and c.is_active
        and exists (select 1 from mst_menu_items i where i.menu_category_id = c.id and i.is_active)), '[]'::jsonb),
    'items', coalesce((
      with best as (
        select oi.menu_item_id, sum(oi.quantity) as qty from pos_order_items oi join pos_orders po on po.id = oi.order_id
        where po.outlet_id = v_o.id and po.status = 'paid' and po.business_date > v_date - 30 and not oi.is_void
        group by 1 order by 2 desc limit 6
      )
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'description', i.description, 'image_url', i.image_url, 'menu_category_id', i.menu_category_id,
        'price_dine_in', mst_get_menu_price(i.id, v_o.id, 'dine_in'), 'price_takeaway', mst_get_menu_price(i.id, v_o.id, 'takeaway'),
        'featured', i.kiosk_featured, 'badge', i.kiosk_badge, 'best_seller', exists (select 1 from best where best.menu_item_id = i.id),
        'sold_out', exists (select 1 from mst_menu_sold_outs s where s.outlet_id = v_o.id and s.business_date = v_date and s.menu_item_id = i.id),
        'modifier_groups', coalesce((
          select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select,
            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'extra_price', m.extra_price, 'is_default', m.is_default)
              order by m.sort_order) from mst_modifiers m where m.modifier_group_id = g.id), '[]'::jsonb)) order by g.name)
          from mst_menu_item_modifier_groups l join mst_modifier_groups g on g.id = l.modifier_group_id where l.menu_item_id = i.id), '[]'::jsonb))
        order by i.kiosk_featured desc, i.name)
      from mst_menu_items i
      where i.company_id = v_o.company_id and i.brand_id = v_o.brand_id and i.is_active), '[]'::jsonb));
end $$;

-- kirim pesanan kiosk. p: {channel: 'dine_in'|'takeaway', customer_name, items: [{menu_item_id, quantity, note, modifier_ids[]}]}
create or replace function public_kiosk_submit(p_token text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_k pos_kiosks; v_o sys_outlets; v_order pos_orders; v_item jsonb; v_menu mst_menu_items; g record; v_mods uuid[]; v_n int;
  v_channel text := coalesce(p->>'channel', 'dine_in'); v_date date; v_queue text;
begin
  select * into v_k from pos_kiosks where token = p_token and is_active for update;
  if v_k.id is null or coalesce(length(p_token), 0) <> 32 then raise exception 'Kiosk tidak dikenal. Hubungi staf.'; end if;
  select * into v_o from sys_outlets where id = v_k.outlet_id;
  if not v_o.is_active then raise exception 'Outlet sedang tutup.'; end if;
  if v_channel not in ('dine_in', 'takeaway') or (v_channel = 'dine_in' and not v_k.allow_dine_in) or (v_channel = 'takeaway' and not v_k.allow_takeaway) then
    raise exception 'Pilihan makan di sini / bawa pulang tidak tersedia';
  end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'Keranjang masih kosong'; end if;
  if jsonb_array_length(p->'items') > 30 then raise exception 'Terlalu banyak item dalam satu pesanan. Silakan ke kasir.'; end if;
  -- anti-spam: maks 6 pesanan per kiosk per menit
  if (select count(*) from pos_orders where order_source = 'kiosk' and outlet_id = v_o.id and kiosk_id = v_k.id and created_at > now() - interval '1 minute') >= 6 then
    raise exception 'Terlalu banyak pesanan dalam waktu singkat. Silakan tunggu sebentar.';
  end if;
  v_date := sys_outlet_business_date(v_o.id);
  -- validasi tiap item: brand outlet, tidak habis, pilihan sesuai grup & batas min/maks
  for v_item in select * from jsonb_array_elements(p->'items') loop
    select * into v_menu from mst_menu_items where id = (v_item->>'menu_item_id')::uuid and company_id = v_o.company_id and brand_id = v_o.brand_id and is_active;
    if v_menu.id is null then raise exception 'Menu tidak tersedia'; end if;
    if exists (select 1 from mst_menu_sold_outs where outlet_id = v_o.id and business_date = v_date and menu_item_id = v_menu.id) then
      raise exception '% sedang habis', v_menu.name;
    end if;
    select coalesce(array_agg(x::uuid), '{}') into v_mods from jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'::jsonb)) x;
    if exists (select 1 from unnest(v_mods) mid where not exists (
        select 1 from mst_modifiers m join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id
        where m.id = mid and l.menu_item_id = v_menu.id)) then
      raise exception 'Pilihan untuk % tidak valid', v_menu.name;
    end if;
    for g in select mg.* from mst_menu_item_modifier_groups l join mst_modifier_groups mg on mg.id = l.modifier_group_id where l.menu_item_id = v_menu.id loop
      select count(*) into v_n from mst_modifiers m where m.modifier_group_id = g.id and m.id = any(v_mods);
      if v_n < coalesce(g.min_select, 0) or (coalesce(g.max_select, 0) > 0 and v_n > g.max_select) then
        raise exception 'Pilihan "%" untuk % belum sesuai', g.name, v_menu.name;
      end if;
    end loop;
  end loop;

  v_order := pos_create_order_header(v_o.id, null, v_channel, left(nullif(trim(coalesce(p->>'customer_name', '')), ''), 30), 1,
                                     null, null, 'kiosk', null);
  v_queue := 'K' || lpad(sys_next_sequence(v_o.company_id, 'KIOSK/' || v_o.code || '/' || to_char(v_date, 'YYYYMMDD'))::text, 3, '0');
  update pos_orders set queue_number = v_queue, kiosk_id = v_k.id where id = v_order.id;
  -- bayar di kasir: menunggu pembayaran, belum masuk dapur
  perform pos_add_order_items(v_order.id,
    (select jsonb_agg(jsonb_build_object('menu_item_id', x->>'menu_item_id', 'quantity', least(greatest(coalesce((x->>'quantity')::int, 1), 1), 20),
       'note', left(nullif(trim(coalesce(x->>'note', '')), ''), 120), 'modifier_ids', coalesce(x->'modifier_ids', '[]'::jsonb)))
     from jsonb_array_elements(p->'items') x), 'waiting');
  return jsonb_build_object('order_id', v_order.id, 'queue_number', v_queue, 'receipt', pos_receipt_payload(v_order.id));
end $$;
grant execute on function public_kiosk_menu(text) to anon, authenticated;
grant execute on function public_kiosk_submit(text, jsonb) to anon, authenticated;

-- pesanan kiosk otomatis masuk dapur begitu dibayar (pesanan QR meja tetap harus dikonfirmasi dulu)
create or replace function pos_check_unconfirmed_items()
returns trigger language plpgsql as $$
begin
  if new.order_source = 'kiosk' then
    update pos_order_items set kitchen_status = 'pending' where order_id = new.id and kitchen_status = 'waiting' and not is_void;
    return new;
  end if;
  if exists (select 1 from pos_order_items where order_id = new.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi. Konfirmasi atau void dulu sebelum bayar.';
  end if;
  return new;
end $$;

-- daftar kiosk + status online (untuk halaman pengaturan)
create or replace function pos_kiosk_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when sys_has_permission('kiosk.manage') then coalesce((select jsonb_agg(to_jsonb(k) || jsonb_build_object('outlet', o.name,
      'online', k.last_seen_at > now() - interval '15 minutes',
      'orders_today', (select count(*) from pos_orders po where po.kiosk_id = k.id and po.business_date = sys_outlet_business_date(k.outlet_id)))
    order by o.name, k.name)
    from pos_kiosks k join sys_outlets o on o.id = k.outlet_id
    where k.company_id = sys_current_company_id() and sys_can_access_outlet(k.outlet_id)), '[]'::jsonb) else '[]'::jsonb end
$$;

-- struk: sertakan nomor antrean kiosk
create or replace function pos_receipt_payload(p_order_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'queue_number', o.queue_number, 'status', o.status, 'sales_channel', o.sales_channel,
      'order_source', o.order_source, 'customer_name', o.customer_name, 'guest_count', o.guest_count, 'note', o.note,
      'created_at', o.created_at, 'paid_at', o.paid_at, 'table', t.code,
      'subtotal', o.subtotal, 'discount_amount', o.discount_amount, 'promotion_amount', o.promotion_amount, 'promotion', pr.name,
      'points_redeemed', o.points_redeemed, 'points_amount', o.points_amount, 'points_earned', o.points_earned,
      'service_amount', o.service_amount, 'tax_amount', o.tax_amount, 'rounding_amount', o.rounding_amount, 'grand_total', o.grand_total,
      'cashier', (select full_name from sys_users where id = o.created_by)),
    'outlet', jsonb_build_object('name', ol.name, 'address', ol.address, 'phone', ol.phone, 'tax_rate', ol.tax_rate,
      'header', ol.receipt_header, 'footer', ol.receipt_footer, 'show_logo', ol.receipt_show_logo,
      'show_feedback_qr', ol.receipt_show_feedback_qr and coalesce(fs.is_enabled, true)),
    'brand', jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url)),
    'company', jsonb_build_object('name', c.name, 'tax_number', c.tax_number),
    'feedback', jsonb_build_object('title', fs.title, 'incentive', fs.incentive_text),
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.menu_item_name, 'qty', i.quantity, 'unit_price', i.unit_price,
        'line_total', i.line_total, 'note', i.note,
        'modifiers', coalesce((select jsonb_agg(m.modifier_name) from pos_order_item_modifiers m where m.order_item_id = i.id), '[]'::jsonb))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', pm.name, 'amount', p.amount, 'change', p.change_amount) order by p.created_at)
      from pos_payments p join mst_payment_methods pm on pm.id = p.payment_method_id where p.order_id = o.id), '[]'::jsonb),
    'member', case when cu.id is not null then jsonb_build_object('name', cu.name, 'points_balance', cu.points_balance) end)
  from pos_orders o
  join sys_outlets ol on ol.id = o.outlet_id
  join sys_companies c on c.id = o.company_id
  left join sys_brands b on b.id = ol.brand_id
  left join mst_tables t on t.id = o.table_id
  left join crm_promotions pr on pr.id = o.promotion_id
  left join crm_customers cu on cu.id = o.customer_id
  left join crm_feedback_settings fs on fs.company_id = o.company_id
  where o.id = p_order_id
$$;

-- >>>>>>>>>> migrations/041_group_consolidation.sql
-- =====================================================================
-- SEMAR - 041: DASHBOARD GRUP & LAPORAN KONSOLIDASI (Platform tahap 2)
--   * grp_my_groups(): grup usaha yang boleh dilihat (pemilik grup; Platform Admin melihat semua).
--   * grp_dashboard(): ringkasan semua PT dalam grup sekaligus: penjualan bersih (+ pertumbuhan vs
--     periode sebelumnya), tren harian per PT, outlet & menu terlaris, laba rugi singkat, stok menipis,
--     karyawan & kehadiran hari ini, cuti/persetujuan menunggu, rating ulasan.
--   * grp_financials(): laba rugi & neraca per PT + kolom eliminasi + konsolidasi (digabung per kode akun).
--   * fin_journal_lines.counterparty_company_id: lawan transaksi antar-PT. Baris jurnal ke PT lain
--     dalam grup yang sama dieliminasi di konsolidasi (diisi otomatis oleh transaksi antar-PT, tahap 3).
--   Hanya baca. Tidak mengubah data PT mana pun.
-- =====================================================================

alter table fin_journal_lines add column if not exists counterparty_company_id uuid references sys_companies(id);
create index if not exists fin_journal_lines_counterparty on fin_journal_lines (counterparty_company_id) where counterparty_company_id is not null;

-- boleh melihat grup: pemilik grup (user aktif) atau Platform Admin
create or replace function grp_can_view(p_group_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select sys_is_platform_admin() or exists (
    select 1 from sys_group_members m join sys_users u on u.id = m.user_id and u.is_active
    where m.group_id = p_group_id and m.user_id = auth.uid())
$$;

create or replace function grp_my_groups()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'code', g.code, 'name', g.name,
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'logo_url', c.logo_url) order by c.name)
        from sys_companies c where c.group_id = g.id and c.is_active), '[]'::jsonb)) order by g.name), '[]'::jsonb)
  from sys_company_groups g
  where grp_can_view(g.id)
$$;

-- saldo akun satu PT (versi eksplisit dari fin_get_account_balances, tanpa bergantung RLS)
-- p_eliminate_group: baris jurnal dengan lawan transaksi PT lain di grup ini dipisahkan sebagai eliminasi
create or replace function grp_company_balances(p_company_id uuid, p_from date, p_to date, p_group_id uuid)
returns table (code text, name text, account_type text, normal_balance text, is_header boolean,
               period_balance numeric, closing_balance numeric, period_elim numeric, closing_elim numeric)
language sql stable security definer set search_path = public as $$
  with mv as (
    select l.account_id,
      sum(case when j.journal_date <  p_from then l.debit - l.credit else 0 end) as opening_dc,
      sum(case when j.journal_date >= p_from then l.debit - l.credit else 0 end) as period_dc,
      sum(case when j.journal_date >= p_from and ic.id is not null then l.debit - l.credit else 0 end) as period_ic,
      sum(case when ic.id is not null then l.debit - l.credit else 0 end) as closing_ic
    from fin_journal_lines l
    join fin_journals j on j.id = l.journal_id
    left join sys_companies ic on ic.id = l.counterparty_company_id and ic.group_id = p_group_id and ic.id <> p_company_id
    where l.company_id = p_company_id and j.journal_date <= p_to
    group by l.account_id
  )
  select a.code, a.name, a.account_type, a.normal_balance, a.is_header,
    s.sign * coalesce(mv.period_dc, 0),
    s.sign * (coalesce(mv.opening_dc, 0) + coalesce(mv.period_dc, 0)),
    s.sign * coalesce(mv.period_ic, 0),
    s.sign * coalesce(mv.closing_ic, 0)
  from fin_accounts a
  -- tanda mengikuti jenis akun (aset/HPP/beban = debit), jadi akun kontra (diskon, akumulasi penyusutan, prive) bernilai minus
  cross join lateral (select case when a.account_type in ('asset', 'cogs', 'expense') then 1 else -1 end as sign) s
  left join mv on mv.account_id = a.id
  where a.company_id = p_company_id
$$;
revoke execute on function grp_company_balances(uuid, date, date, uuid) from public, anon, authenticated;

-- laba rugi (periode) & neraca (per p_to) per PT + eliminasi + konsolidasi, digabung per kode akun
create or replace function grp_financials(p_group_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not grp_can_view(p_group_id) then raise exception 'Anda bukan pemilik grup ini'; end if;
  if p_to < p_from then raise exception 'Rentang tanggal tidak valid'; end if;
  return (
    with cs as (select id, name from sys_companies where group_id = p_group_id and is_active),
    b as (select c.id as company_id, x.* from cs c cross join lateral grp_company_balances(c.id, p_from, p_to, p_group_id) x),
    acc as (
      select code, (array_agg(name order by name))[1] as name, (array_agg(account_type))[1] as account_type, bool_or(is_header) as is_header,
        jsonb_object_agg(company_id, case when account_type in ('revenue', 'cogs', 'expense') then period_balance else closing_balance end) as by_company,
        sum(case when account_type in ('revenue', 'cogs', 'expense') then period_balance else closing_balance end) as total,
        sum(case when account_type in ('revenue', 'cogs', 'expense') then period_elim else closing_elim end) as elimination
      from b group by code
    ),
    -- laba ditahan: akumulasi laba rugi sampai p_to (belum ada jurnal penutup tahunan)
    re as (
      select company_id, sum(case when account_type = 'revenue' then closing_balance else -closing_balance end) as earnings,
             sum(case when account_type = 'revenue' then closing_elim else -closing_elim end) as earnings_elim
      from b where account_type in ('revenue', 'cogs', 'expense') and not is_header group by company_id
    )
    select jsonb_build_object(
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from cs), '[]'::jsonb),
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'account_type', account_type, 'is_header', is_header,
          'by_company', by_company, 'total', total, 'elimination', elimination, 'consolidated', total - elimination) order by code) from acc), '[]'::jsonb),
      'retained_earnings', coalesce((select jsonb_object_agg(company_id, earnings) from re), '{}'::jsonb),
      'retained_earnings_elim', coalesce((select sum(earnings_elim) from re), 0)));
end $$;

-- ringkasan grup
create or replace function grp_dashboard(p_group_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_len int := p_to - p_from + 1; v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not grp_can_view(p_group_id) then raise exception 'Anda bukan pemilik grup ini'; end if;
  if p_to < p_from or v_len > 400 then raise exception 'Rentang tanggal tidak valid'; end if;
  return (
    with cs as (select id, name, logo_url from sys_companies where group_id = p_group_id and is_active),
    ord as (
      select o.company_id, o.outlet_id, o.business_date, o.grand_total,
        o.subtotal - o.discount_amount - o.promotion_amount - o.points_amount as net_sales
      from pos_orders o where o.company_id in (select id from cs) and o.status = 'paid' and o.business_date between p_from - v_len and p_to
    ),
    cur as (select * from ord where business_date between p_from and p_to),
    prev as (select * from ord where business_date < p_from),
    pl as (
      select c.id as company_id,
        sum(x.period_balance) filter (where x.account_type = 'revenue' and not x.is_header) as revenue,
        sum(x.period_balance) filter (where x.account_type = 'cogs' and not x.is_header) as cogs,
        sum(x.period_balance) filter (where x.account_type = 'expense' and not x.is_header) as expense
      from cs c cross join lateral grp_company_balances(c.id, p_from, p_to, p_group_id) x group by c.id
    )
    select jsonb_build_object(
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'logo_url', c.logo_url,
          'net_sales', coalesce((select sum(net_sales) from cur where company_id = c.id), 0),
          'gross_sales', coalesce((select sum(grand_total) from cur where company_id = c.id), 0),
          'orders', (select count(*) from cur where company_id = c.id),
          'prev_net_sales', coalesce((select sum(net_sales) from prev where company_id = c.id), 0),
          'outlets', (select count(*) from sys_outlets o where o.company_id = c.id and o.is_active),
          'revenue', coalesce(pl.revenue, 0), 'cogs', coalesce(pl.cogs, 0), 'expense', coalesce(pl.expense, 0),
          'net_profit', coalesce(pl.revenue, 0) - coalesce(pl.cogs, 0) - coalesce(pl.expense, 0),
          'open_orders', (select count(*) from pos_orders o where o.company_id = c.id and o.status = 'open'),
          'low_stock', (select count(*) from rpt_stock_balances s where s.company_id = c.id and s.is_low_stock),
          'employees', (select count(*) from hr_employees e where e.company_id = c.id and e.is_active),
          'present_today', (select count(*) from hr_attendances a where a.company_id = c.id and a.work_date = v_today and a.check_in_at is not null),
          'scheduled_today', (select count(*) from hr_rosters r where r.company_id = c.id and r.work_date = v_today and not r.is_off),
          'pending_leave', (select count(*) from hr_leave_requests l where l.company_id = c.id and l.status = 'pending'),
          'pending_approvals', (select count(*) from sys_approval_requests ar where ar.company_id = c.id and ar.status = 'pending'),
          'rating', (select round(avg(overall), 2) from crm_feedback_responses f where f.company_id = c.id and (f.created_at at time zone 'Asia/Jakarta')::date between p_from and p_to),
          'reviews', (select count(*) from crm_feedback_responses f where f.company_id = c.id and (f.created_at at time zone 'Asia/Jakarta')::date between p_from and p_to))
        order by c.name)
        from cs c left join pl on pl.company_id = c.id), '[]'::jsonb),
      'daily', coalesce((select jsonb_agg(jsonb_build_object('date', d, 'company_id', company_id, 'net_sales', s) order by d)
        from (select business_date as d, company_id, sum(net_sales) as s from cur group by 1, 2) t), '[]'::jsonb),
      'top_outlets', coalesce((select jsonb_agg(jsonb_build_object('outlet', o.name, 'company', c.name, 'net_sales', t.s, 'orders', t.n) order by t.s desc)
        from (select outlet_id, sum(net_sales) as s, count(*) as n from cur group by outlet_id order by 2 desc limit 8) t
        join sys_outlets o on o.id = t.outlet_id join cs c on c.id = o.company_id), '[]'::jsonb),
      'top_menus', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.q, 'revenue', t.r, 'companies', t.cn) order by t.q desc)
        from (select i.menu_item_name as name, sum(i.quantity) as q, sum(i.line_total) as r, count(distinct po.company_id) as cn
              from pos_order_items i join pos_orders po on po.id = i.order_id
              where po.company_id in (select id from cs) and po.status = 'paid' and po.business_date between p_from and p_to and not i.is_void
              group by i.menu_item_name order by 2 desc limit 10) t), '[]'::jsonb)));
end $$;

-- >>>>>>>>>> migrations/042_intercompany.sql
-- =====================================================================
-- SEMAR - 042: TRANSAKSI ANTAR-PT DALAM GRUP (Platform tahap 3)
--   PT pembeli (A)                              PT penjual (B)
--   PO ke supplier "PT B" (otomatis ada) --->   Sales Order baru untuk pelanggan "PT A" (status Baru)
--                                               B konfirmasi / tolak (ditolak -> PO A batal)
--                                               Pengiriman B dikirim
--   Draft Penerimaan Barang otomatis   <---     (qty sesuai kiriman)
--   A terima & posting -> stok + hutang         Invoice B -> piutang & pendapatan
--   A bayar hutang ke supplier "PT B"           B catat penerimaan pembayaran
--   * Supplier & pelanggan antar-PT dibuat otomatis untuk setiap pasangan PT dalam grup.
--   * Barang dicocokkan lewat KODE barang & satuan yang sama di kedua PT.
--   * Semua jurnal dari dokumen antar-PT ditandai counterparty_company_id -> dieliminasi di laporan
--     konsolidasi grup (penjualan, HPP, piutang, hutang antar-PT tidak dihitung dua kali).
-- =====================================================================

-- ---------------------------------------------------------------------
-- MITRA ANTAR-PT
-- ---------------------------------------------------------------------
alter table pur_suppliers add column if not exists linked_company_id uuid references sys_companies(id);
alter table pur_suppliers drop constraint if exists pur_suppliers_type_check;
alter table pur_suppliers add constraint pur_suppliers_type_check check (supplier_type in ('external', 'internal', 'intercompany'));
alter table pur_suppliers drop constraint if exists pur_suppliers_internal_check;
alter table pur_suppliers add constraint pur_suppliers_internal_check check (
  (supplier_type <> 'internal' or linked_outlet_id is not null) and (supplier_type <> 'intercompany' or linked_company_id is not null));
alter table sal_customers add column if not exists linked_company_id uuid references sys_companies(id);
create unique index if not exists uq_pur_suppliers_ic on pur_suppliers (company_id, linked_company_id) where linked_company_id is not null;
create unique index if not exists uq_sal_customers_ic on sal_customers (company_id, linked_company_id) where linked_company_id is not null;

-- tautan lintas PT satu arah & "on delete set null": reset data satu PT tidak terhalang data PT lain
alter table sal_sales_orders add column if not exists ic_purchase_order_id uuid references pur_purchase_orders(id) on delete set null;
create unique index if not exists uq_sal_sales_orders_ic_po on sal_sales_orders (ic_purchase_order_id) where ic_purchase_order_id is not null;
alter table sal_sales_order_items add column if not exists ic_po_item_id uuid references pur_purchase_order_items(id) on delete set null;
alter table pur_goods_receipts add column if not exists ic_delivery_id uuid references sal_deliveries(id) on delete set null;

-- buat / aktifkan supplier & pelanggan antar-PT untuk semua pasangan PT dalam grup;
-- mitra ke PT yang sudah keluar dari grup dinonaktifkan
create or replace function grp_sync_partners(p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s record; b record;
begin
  if p_group_id is not null then
    for s in select * from sys_companies where group_id = p_group_id and is_active loop
      for b in select * from sys_companies where group_id = p_group_id and is_active and id <> s.id loop
        -- di penjual (s): pelanggan = PT b
        insert into sal_customers (company_id, code, name, address, tax_number, payment_term_days, notes, linked_company_id)
        values (s.id, left('IC-' || b.code, 30), b.name, b.address, b.tax_number, 30, 'Pelanggan antar-PT (otomatis)', b.id)
        on conflict (company_id, linked_company_id) where linked_company_id is not null do update set is_active = true, name = excluded.name;
        -- di pembeli (b): supplier = PT s
        insert into pur_suppliers (company_id, code, name, address, payment_term_days, supplier_type, linked_company_id)
        values (b.id, left('IC-' || s.code, 30), s.name, s.address, 30, 'intercompany', s.id)
        on conflict (company_id, linked_company_id) where linked_company_id is not null do update set is_active = true, name = excluded.name;
      end loop;
    end loop;
  end if;
  update sal_customers c set is_active = false
  where c.linked_company_id is not null and c.is_active and not exists (
    select 1 from sys_companies me join sys_companies other on other.id = c.linked_company_id
    where me.id = c.company_id and me.group_id is not null and me.group_id = other.group_id and other.is_active);
  update pur_suppliers p set is_active = false
  where p.linked_company_id is not null and p.is_active and not exists (
    select 1 from sys_companies me join sys_companies other on other.id = p.linked_company_id
    where me.id = p.company_id and me.group_id is not null and me.group_id = other.group_id and other.is_active);
end $$;
revoke execute on function grp_sync_partners(uuid) from public, anon, authenticated;

create or replace function grp_on_company_group_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform grp_sync_partners(new.group_id);
  if old.group_id is distinct from new.group_id then perform grp_sync_partners(old.group_id); end if;
  return new;
end $$;
create trigger trg_sys_companies_ic_partners after update of group_id, is_active on sys_companies
  for each row execute function grp_on_company_group_change();

do $$
declare g record;
begin
  for g in select distinct group_id from sys_companies where group_id is not null loop perform grp_sync_partners(g.group_id); end loop;
end $$;

-- ---------------------------------------------------------------------
-- PENCOCOKAN BARANG ANTAR-PT (kode barang & kode satuan sama)
-- ---------------------------------------------------------------------
create or replace function grp_map_item(p_item_id uuid, p_target_company uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select t.id from inv_items s join inv_items t on t.company_id = p_target_company and lower(t.code) = lower(s.code) and t.is_active
  where s.id = p_item_id limit 1
$$;
create or replace function grp_map_unit(p_unit_id uuid, p_target_company uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select t.id from inv_units s join inv_units t on t.company_id = p_target_company and lower(t.code) = lower(s.code)
  where s.id = p_unit_id limit 1
$$;
-- outlet penjual untuk SO antar-PT: outlet aktif pertama yang punya gudang
create or replace function grp_seller_outlet(p_company_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from sys_outlets where company_id = p_company_id and is_active and default_warehouse_id is not null order by code limit 1
$$;

-- harga PO ke PT lain: dari Pricelist Jual PT penjual (bila ada), barang & satuan harus ada di PT penjual
create or replace function pur_set_ic_po_price()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_po pur_purchase_orders; v_sup pur_suppliers; v_item uuid; v_unit uuid; v_price numeric; v_cust uuid;
begin
  select * into v_po from pur_purchase_orders where id = new.purchase_order_id;
  if v_po.status not in ('draft', 'pending_approval') then return new; end if;
  select * into v_sup from pur_suppliers where id = v_po.supplier_id;
  if v_sup.supplier_type <> 'intercompany' then return new; end if;
  v_item := grp_map_item(new.item_id, v_sup.linked_company_id);
  if v_item is null then
    raise exception 'Barang "%" (kode %) belum ada di %. Samakan kode barang di kedua PT.',
      (select name from inv_items where id = new.item_id), (select code from inv_items where id = new.item_id), v_sup.name;
  end if;
  v_unit := grp_map_unit(new.unit_id, v_sup.linked_company_id);
  if v_unit is null then raise exception 'Satuan "%" belum ada di %', (select code from inv_units where id = new.unit_id), v_sup.name; end if;
  select id into v_cust from sal_customers where company_id = v_sup.linked_company_id and linked_company_id = v_po.company_id;
  v_price := sal_get_price(v_sup.linked_company_id, grp_seller_outlet(v_sup.linked_company_id), null, v_cust, v_item, v_unit, v_po.po_date);
  if v_price is not null then new.unit_price := v_price; end if;
  if coalesce(new.unit_price, 0) <= 0 then
    raise exception 'Harga "%" belum ada di Pricelist Jual %. Isi harga di PO atau buat pricelist di PT penjual.', (select name from inv_items where id = new.item_id), v_sup.name;
  end if;
  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end $$;
create trigger trg_pur_po_items_ic_price before insert or update of item_id, unit_id, unit_price, quantity
  on pur_purchase_order_items for each row execute function pur_set_ic_po_price();

-- ---------------------------------------------------------------------
-- PO DISETUJUI -> SALES ORDER DI PT PENJUAL
-- ---------------------------------------------------------------------
create or replace function grp_on_ic_po_approved()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sup pur_suppliers; v_cust uuid; v_outlet uuid; v_so uuid; v_buyer text;
begin
  select * into v_sup from pur_suppliers where id = new.supplier_id;
  if v_sup.supplier_type <> 'intercompany' or exists (select 1 from sal_sales_orders where ic_purchase_order_id = new.id) then return new; end if;
  -- grup harus masih sama
  if not exists (select 1 from sys_companies a join sys_companies b on b.group_id = a.group_id
                 where a.id = new.company_id and b.id = v_sup.linked_company_id and a.group_id is not null and b.is_active) then
    raise exception '% tidak lagi satu grup dengan PT ini', v_sup.name;
  end if;
  v_outlet := grp_seller_outlet(v_sup.linked_company_id);
  if v_outlet is null then raise exception '% belum punya outlet dengan gudang', v_sup.name; end if;
  select id into v_cust from sal_customers where company_id = v_sup.linked_company_id and linked_company_id = new.company_id;
  if v_cust is null then perform grp_sync_partners((select group_id from sys_companies where id = new.company_id));
    select id into v_cust from sal_customers where company_id = v_sup.linked_company_id and linked_company_id = new.company_id; end if;
  v_buyer := (select name from sys_companies where id = new.company_id);

  insert into sal_sales_orders (company_id, outlet_id, warehouse_id, customer_type, customer_id, ic_purchase_order_id,
    so_number, so_date, expected_date, status, shipping_address, note)
  values (v_sup.linked_company_id, v_outlet, (select default_warehouse_id from sys_outlets where id = v_outlet), 'external', v_cust, new.id,
    sys_next_document_number(v_sup.linked_company_id, 'SO', current_date), current_date, new.expected_date, 'new',
    (select o.address from inv_warehouses w join sys_outlets o on o.id = w.outlet_id where w.id = new.warehouse_id),
    'PO antar-PT ' || new.po_number || ' dari ' || v_buyer || coalesce(' - ' || new.note, ''))
  returning id into v_so;

  insert into sal_sales_order_items (company_id, sales_order_id, ic_po_item_id, item_id, unit_id, quantity, unit_price)
  select v_sup.linked_company_id, v_so, i.id, grp_map_item(i.item_id, v_sup.linked_company_id), grp_map_unit(i.unit_id, v_sup.linked_company_id),
         i.quantity, i.unit_price
  from pur_purchase_order_items i where i.purchase_order_id = new.id order by i.created_at, i.id;
  perform sal_recalculate_order(v_so);
  update pur_purchase_orders set sales_note = 'Menunggu konfirmasi ' || v_sup.name where id = new.id;
  return new;
end $$;
create trigger trg_pur_po_ic_approved after update of status on pur_purchase_orders
  for each row when (new.status = 'approved' and old.status is distinct from 'approved')
  execute function grp_on_ic_po_approved();

-- SO antar-PT dikonfirmasi / ditolak -> kabar ke PO pembeli; ditolak = PO batal (bila belum ada penerimaan)
create or replace function grp_on_ic_so_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.ic_purchase_order_id is null or new.status = old.status then return new; end if;
  if new.status in ('rejected', 'cancelled') then
    update pur_purchase_orders set status = 'cancelled', sales_note = 'Ditolak penjual' || coalesce(': ' || new.reject_reason, '')
    where id = new.ic_purchase_order_id and status = 'approved';
  else
    update pur_purchase_orders set sales_note = case new.status
      when 'confirmed' then 'Dikonfirmasi penjual (' || new.so_number || ')'
      when 'partially_delivered' then 'Sebagian dikirim penjual'
      when 'delivered' then 'Semua sudah dikirim penjual'
      when 'closed' then 'SO penjual ditutup' else sales_note end
    where id = new.ic_purchase_order_id;
  end if;
  return new;
end $$;
create trigger trg_sal_so_ic_status after update of status on sal_sales_orders
  for each row execute function grp_on_ic_so_status();

-- pengiriman PT penjual dikirim -> draft penerimaan barang di PT pembeli (sebagai penerimaan biasa: stok + hutang)
create or replace function grp_on_ic_delivery_shipped()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_so sal_sales_orders; v_po pur_purchase_orders; v_gr uuid;
begin
  select * into v_so from sal_sales_orders where id = new.sales_order_id;
  if v_so.ic_purchase_order_id is null then return new; end if;
  select * into v_po from pur_purchase_orders where id = v_so.ic_purchase_order_id;
  insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, ic_delivery_id, note)
  values (v_po.company_id, v_po.id, v_po.supplier_id, v_po.warehouse_id, new.id,
          'Kiriman ' || coalesce(new.delivery_number, '') || ' dari ' || (select name from sys_companies where id = new.company_id))
  returning id into v_gr;
  insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id, item_id, unit_id,
    conversion_qty, quantity, shipped_qty, unit_price, line_total)
  select v_po.company_id, v_gr, poi.id, poi.item_id, poi.unit_id, poi.conversion_qty, di.quantity, di.quantity, poi.unit_price,
         round(di.quantity * poi.unit_price, 2)
  from sal_delivery_items di
  join sal_sales_order_items soi on soi.id = di.sales_order_item_id
  join pur_purchase_order_items poi on poi.id = soi.ic_po_item_id
  where di.delivery_id = new.id and di.quantity > 0 order by di.package_no, di.created_at, di.id;
  update pur_purchase_orders set sales_note = 'Barang dikirim, menunggu diterima (' || coalesce(new.delivery_number, '') || ')' where id = v_po.id;
  return new;
end $$;
create trigger trg_sal_delivery_ic_shipped after update of status on sal_deliveries
  for each row when (new.status = 'shipped' and old.status is distinct from 'shipped')
  execute function grp_on_ic_delivery_shipped();

-- PO ke PT lain / cabang internal tidak boleh dibuat penerimaan manual (datang dari pengiriman penjual)
create or replace function pur_create_goods_receipt_from_po(p_po_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_po    pur_purchase_orders%rowtype;
  v_gr_id uuid;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_po from pur_purchase_orders
  where id = p_po_id and company_id = sys_current_company_id();
  if not found or v_po.status not in ('approved', 'partially_received') then
    raise exception 'PO harus berstatus approved';
  end if;
  if (select supplier_type from pur_suppliers where id = v_po.supplier_id) = 'internal' then
    raise exception 'PO ke cabang internal diterima dari dokumen Pengiriman penjual (lihat Penerimaan Barang)';
  end if;
  if (select supplier_type from pur_suppliers where id = v_po.supplier_id) = 'intercompany' then
    raise exception 'PO ke PT dalam grup diterima otomatis dari pengiriman PT penjual (lihat Penerimaan Barang)';
  end if;

  insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, created_by)
  values (v_po.company_id, v_po.id, v_po.supplier_id, v_po.warehouse_id, auth.uid())
  returning id into v_gr_id;

  insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id,
    item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
  select company_id, v_gr_id, id, item_id, unit_id, conversion_qty,
         quantity - received_qty, unit_price, (quantity - received_qty) * unit_price
  from pur_purchase_order_items
  where purchase_order_id = p_po_id and quantity > received_qty;

  return v_gr_id;
end $$;

-- ---------------------------------------------------------------------
-- JURNAL: tandai lawan transaksi antar-PT (untuk eliminasi konsolidasi)
-- ---------------------------------------------------------------------
create or replace function fin_ic_counterparty(p_source_type text, p_source_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select case p_source_type
    when 'sales_delivery' then (select c.linked_company_id from sal_deliveries d join sal_sales_orders so on so.id = d.sales_order_id
                                join sal_customers c on c.id = so.customer_id where d.id = p_source_id)
    when 'sales_invoice' then (select c.linked_company_id from sal_invoices i join sal_customers c on c.id = i.customer_id where i.id = p_source_id)
    when 'sales_credit_note' then (select c.linked_company_id from sal_credit_notes n join sal_invoices i on i.id = n.invoice_id
                                   join sal_customers c on c.id = i.customer_id where n.id = p_source_id)
    when 'sales_payment' then (select c.linked_company_id from sal_payments p join sal_customers c on c.id = p.customer_id where p.id = p_source_id)
    when 'purchase_receipt' then (select s.linked_company_id from pur_goods_receipts g join pur_suppliers s on s.id = g.supplier_id where g.id = p_source_id)
    when 'supplier_payment' then (select s.linked_company_id from fin_supplier_payments p join pur_suppliers s on s.id = p.supplier_id where p.id = p_source_id)
  end
$$;

create or replace function fin_tag_ic_line()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_j fin_journals;
begin
  if new.counterparty_company_id is null then
    select * into v_j from fin_journals where id = new.journal_id;
    if v_j.source_type in ('sales_delivery', 'sales_invoice', 'sales_credit_note', 'sales_payment', 'purchase_receipt', 'supplier_payment') then
      new.counterparty_company_id := fin_ic_counterparty(v_j.source_type, v_j.source_id);
    end if;
  end if;
  return new;
end $$;
create trigger trg_fin_journal_lines_ic before insert on fin_journal_lines
  for each row execute function fin_tag_ic_line();

-- ---------------------------------------------------------------------
-- PANTAU ANTAR-PT (pemilik grup): dokumen & saldo piutang/hutang antar-PT
-- ---------------------------------------------------------------------
create or replace function grp_ic_overview(p_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not grp_can_view(p_group_id) then raise exception 'Anda bukan pemilik grup ini'; end if;
  return (
    with cs as (select id, name from sys_companies where group_id = p_group_id),
    docs as (
      select po.id, po.po_number, po.po_date, po.status as po_status, po.subtotal, po.sales_note,
        po.company_id as buyer_id, s.linked_company_id as seller_id, so.so_number, so.status as so_status, so.grand_total as so_total,
        (select coalesce(sum(i.quantity), 0) from pur_purchase_order_items i where i.purchase_order_id = po.id) as qty_ordered,
        (select coalesce(sum(i.received_qty), 0) from pur_purchase_order_items i where i.purchase_order_id = po.id) as qty_received,
        (select coalesce(sum(i.delivered_qty), 0) from sal_sales_order_items i where i.sales_order_id = so.id) as qty_delivered,
        (select count(*) from pur_goods_receipts g where g.purchase_order_id = po.id and g.status = 'draft') as receipts_waiting,
        (select coalesce(sum(inv.grand_total), 0) from sal_invoices inv where inv.sales_order_id = so.id) as invoiced,
        (select coalesce(sum(inv.paid_amount), 0) from sal_invoices inv where inv.sales_order_id = so.id) as paid
      from pur_purchase_orders po
      join pur_suppliers s on s.id = po.supplier_id and s.supplier_type = 'intercompany'
      left join sal_sales_orders so on so.ic_purchase_order_id = po.id
      where po.company_id in (select id from cs)
    ),
    bal as (
      select l.company_id, l.counterparty_company_id as other_id, a.system_key, sum(l.debit - l.credit) as dc
      from fin_journal_lines l join fin_accounts a on a.id = l.account_id
      where l.company_id in (select id from cs) and l.counterparty_company_id in (select id from cs) and a.system_key in ('ar', 'ap')
      group by 1, 2, 3
    )
    select jsonb_build_object(
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from cs), '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('buyer', (select name from cs where id = d.buyer_id),
          'seller', (select name from cs where id = d.seller_id)) order by d.po_date desc, d.po_number desc) from docs d), '[]'::jsonb),
      -- piutang penjual atas pembeli vs hutang pembeli ke penjual (harus sama bila semua sudah diterima & ditagih)
      'balances', coalesce((select jsonb_agg(jsonb_build_object('seller_id', x.seller_id, 'buyer_id', x.buyer_id,
          'seller', (select name from cs where id = x.seller_id), 'buyer', (select name from cs where id = x.buyer_id),
          'receivable', x.ar, 'payable', x.ap, 'difference', x.ar - x.ap))
        from (select coalesce(r.company_id, p.other_id) as seller_id, coalesce(r.other_id, p.company_id) as buyer_id,
                     coalesce(r.dc, 0) as ar, coalesce(-p.dc, 0) as ap
              from (select * from bal where system_key = 'ar') r
              full join (select * from bal where system_key = 'ap') p on p.company_id = r.other_id and p.other_id = r.company_id) x
        where x.ar <> 0 or x.ap <> 0), '[]'::jsonb)));
end $$;

-- >>>>>>>>>> migrations/043_semar_insights.sql
-- =====================================================================
-- SEMAR - 043: SEMAR AI LEBIH PINTAR (insight bisnis untuk owner)
--   * ai_business_brief(): briefing harian dalam satu panggilan: penjualan (hari ini, kemarin, periode vs
--     sebelumnya, per outlet, jam ramai, menu terlaris & menu lambat), stok menipis & mau kedaluwarsa,
--     SDM hari ini (hadir, telat, belum absen, cuti), pengajuan menunggu, tugas lewat tenggat & SOP kemarin,
--     ulasan pelanggan, persetujuan menunggu, pembelian, laba rugi bulan ini.
--   * ai_feedback_insights(): ringkasan ulasan + komentar mentah untuk dianalisa temanya oleh Semar.
--   * ai_hr_recap(): rekap per karyawan (hadir, telat, alpa, cuti, pulang cepat, sisa cuti, tugas).
--   * ai_writable_tables(): Semar boleh mengusulkan template SOP & pertanyaan form ulasan.
--   Semua hanya baca & dibatasi perusahaan aktif; owner (atau izin laporan) saja.
-- =====================================================================

create or replace function ai_business_brief(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_days int := least(greatest(coalesce(p_days, 7), 1), 90);
  v_from date := v_today - (least(greatest(coalesce(p_days, 7), 1), 90) - 1);
  v_now timestamptz := now();
begin
  if v_c is null or not (sys_has_permission('*') or sys_has_permission('report.view')) then raise exception 'Butuh izin laporan'; end if;
  return (
    with o as (
      select po.*, po.subtotal - po.discount_amount - po.promotion_amount - po.points_amount as net
      from pos_orders po where po.company_id = v_c and po.status = 'paid' and po.business_date between v_from - v_days and v_today
        and sys_can_access_outlet(po.outlet_id)
    )
    select jsonb_build_object(
      'periode', jsonb_build_object('dari', v_from, 'sampai', v_today, 'hari', v_days),
      'penjualan', jsonb_build_object(
        'hari_ini', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*)) from o where business_date = v_today),
        'kemarin', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*)) from o where business_date = v_today - 1),
        'periode', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*), 'rata_rata', round(coalesce(avg(net), 0))) from o where business_date >= v_from),
        'periode_sebelumnya', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*)) from o where business_date < v_from),
        'per_outlet', coalesce((select jsonb_agg(jsonb_build_object('outlet', so.name, 'bersih', x.s, 'transaksi', x.n) order by x.s desc)
          from (select outlet_id, sum(net) as s, count(*) as n from o where business_date >= v_from group by 1) x join sys_outlets so on so.id = x.outlet_id), '[]'::jsonb),
        'jam_ramai', coalesce((select jsonb_agg(jsonb_build_object('jam', h, 'transaksi', n) order by n desc)
          from (select extract(hour from coalesce(paid_at, created_at) at time zone 'Asia/Jakarta')::int as h, count(*) as n
                from o where business_date >= v_from group by 1 order by 2 desc limit 3) t), '[]'::jsonb),
        'menu_terlaris', coalesce((select jsonb_agg(jsonb_build_object('menu', t.name, 'porsi', t.q, 'omzet', t.r) order by t.q desc)
          from (select i.menu_item_name as name, sum(i.quantity) as q, sum(i.line_total) as r from pos_order_items i join o on o.id = i.order_id
                where o.business_date >= v_from and not i.is_void group by 1 order by 2 desc limit 5) t), '[]'::jsonb),
        'menu_lambat', coalesce((select jsonb_agg(m.name order by m.name) from (
            select mi.name from mst_menu_items mi where mi.company_id = v_c and mi.is_active
              and not exists (select 1 from pos_order_items i join pos_orders po on po.id = i.order_id
                              where i.menu_item_id = mi.id and po.status = 'paid' and po.business_date > v_today - 14)
            order by mi.name limit 10) m), '[]'::jsonb)),
      'stok', jsonb_build_object(
        'menipis_jumlah', (select count(*) from rpt_stock_balances s where s.company_id = v_c and s.is_low_stock),
        'menipis', coalesce((select jsonb_agg(jsonb_build_object('bahan', s.item_name, 'gudang', s.warehouse_name, 'stok', s.quantity, 'minimum', s.min_stock, 'satuan', s.unit_code))
          from (select * from rpt_stock_balances s where s.company_id = v_c and s.is_low_stock order by s.quantity - s.min_stock limit 10) s), '[]'::jsonb),
        'kedaluwarsa_7_hari', coalesce((select jsonb_agg(jsonb_build_object('bahan', b.item_name, 'batch', b.batch_code, 'kedaluwarsa', b.expiry_date, 'sisa', b.qty_remaining, 'satuan', b.unit_code, 'nilai', b.stock_value) order by b.expiry_date)
          from (select * from rpt_stock_batches b where b.company_id = v_c and b.qty_remaining > 0 and b.expiry_date <= v_today + 7 order by b.expiry_date limit 10) b), '[]'::jsonb)),
      'sdm', jsonb_build_object(
        'karyawan_aktif', (select count(*) from hr_employees where company_id = v_c and is_active),
        'terjadwal_hari_ini', (select count(*) from hr_rosters r where r.company_id = v_c and r.work_date = v_today and not r.is_off),
        'hadir_hari_ini', (select count(*) from hr_attendances a where a.company_id = v_c and a.work_date = v_today and a.check_in_at is not null),
        'telat_hari_ini', coalesce((select jsonb_agg(jsonb_build_object('nama', e.full_name, 'menit', a.late_minutes)) from hr_attendances a join hr_employees e on e.id = a.employee_id
          where a.company_id = v_c and a.work_date = v_today and a.late_minutes > 0), '[]'::jsonb),
        'belum_absen', coalesce((select jsonb_agg(jsonb_build_object('nama', e.full_name, 'shift', s.name, 'mulai', s.start_time))
          from hr_rosters r join hr_employees e on e.id = r.employee_id join hr_shifts s on s.id = r.shift_id
          where r.company_id = v_c and r.work_date = v_today and not r.is_off and (v_today + s.start_time) at time zone 'Asia/Jakarta' < v_now
            and not exists (select 1 from hr_attendances a where a.employee_id = r.employee_id and a.work_date = v_today)
            and hr_leave_on(r.employee_id, v_today) is null), '[]'::jsonb),
        'cuti_hari_ini', coalesce((select jsonb_agg(jsonb_build_object('nama', e.full_name, 'jenis', t.name)) from hr_leave_requests l
          join hr_employees e on e.id = l.employee_id join hr_leave_types t on t.id = l.leave_type_id
          where l.company_id = v_c and l.status = 'approved' and v_today between l.start_date and l.end_date), '[]'::jsonb),
        'cuti_menunggu', (select count(*) from hr_leave_requests where company_id = v_c and status = 'pending'),
        'koreksi_absen_menunggu', (select count(*) from hr_attendance_corrections where company_id = v_c and status = 'pending'),
        'absen_perlu_review', (select count(*) from hr_attendances where company_id = v_c and review_status = 'pending'),
        'kontrak_habis_30_hari', coalesce((select jsonb_agg(jsonb_build_object('nama', full_name, 'tanggal', contract_end_date) order by contract_end_date)
          from hr_employees where company_id = v_c and is_active and contract_end_date between v_today and v_today + 30), '[]'::jsonb)),
      'tugas', jsonb_build_object(
        'terbuka', (select count(*) from hr_tasks where company_id = v_c and status in ('new', 'in_progress')),
        'menunggu_review', (select count(*) from hr_tasks where company_id = v_c and status = 'review'),
        'lewat_tenggat', coalesce((select jsonb_agg(jsonb_build_object('tugas', t.title, 'untuk', coalesce(u.full_name, 'Tim ' || r.name, '-'), 'tenggat', t.due_date) order by t.due_date)
          from (select * from hr_tasks where company_id = v_c and status in ('new', 'in_progress', 'review') and due_date < v_today order by due_date limit 10) t
          left join sys_users u on u.id = t.assignee_id left join sys_roles r on r.id = t.assignee_role_id), '[]'::jsonb),
        'sop_kemarin', coalesce((select jsonb_agg(jsonb_build_object('sop', s.name, 'outlet', ol.name,
            'selesai_persen', round(100.0 * (select count(*) from jsonb_array_elements(x.items) i where (i->>'done')::boolean) / greatest(1, jsonb_array_length(x.items)))))
          from hr_sop_runs x join hr_sop_templates s on s.id = x.template_id left join sys_outlets ol on ol.id = x.outlet_id
          where x.company_id = v_c and x.run_date = v_today - 1), '[]'::jsonb)),
      'ulasan', (select jsonb_build_object('jumlah', count(*), 'rata_rata_bintang', round(avg(overall), 2),
          'nps', case when count(nps) > 0 then round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(nps)) end,
          'buruk_belum_ditangani', count(*) filter (where overall <= 2 and status = 'new'),
          'komentar_terbaru', coalesce((select jsonb_agg(jsonb_build_object('bintang', f2.overall, 'komentar', f2.comment, 'tanggal', (f2.created_at at time zone 'Asia/Jakarta')::date))
            from (select * from crm_feedback_responses where company_id = v_c and comment is not null order by created_at desc limit 8) f2), '[]'::jsonb))
        from crm_feedback_responses f where f.company_id = v_c and (f.created_at at time zone 'Asia/Jakarta')::date >= v_from),
      'persetujuan_menunggu', coalesce((select jsonb_object_agg(document_type, n) from (select document_type, count(*) as n from sys_approval_requests
          where company_id = v_c and status = 'pending' group by 1) t), '{}'::jsonb),
      'pembelian', jsonb_build_object(
        'po_menunggu_persetujuan', (select count(*) from pur_purchase_orders where company_id = v_c and status = 'pending_approval'),
        'penerimaan_draft', (select count(*) from pur_goods_receipts where company_id = v_c and status = 'draft')),
      'keuangan_bulan_ini', (select jsonb_build_object(
          'pendapatan', coalesce(sum(period_balance) filter (where account_type = 'revenue' and not is_header), 0),
          'hpp', coalesce(sum(period_balance) filter (where account_type = 'cogs' and not is_header), 0),
          'beban', coalesce(sum(period_balance) filter (where account_type = 'expense' and not is_header), 0),
          'laba_bersih', coalesce(sum(period_balance) filter (where account_type = 'revenue' and not is_header), 0)
            - coalesce(sum(period_balance) filter (where account_type in ('cogs', 'expense') and not is_header), 0))
        from grp_company_balances(v_c, date_trunc('month', v_today)::date, v_today, null))));
end $$;

-- ulasan untuk dianalisa temanya (komentar mentah, tanpa kontak pelanggan)
create or replace function ai_feedback_insights(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (sys_has_permission('*') or sys_has_permission('feedback.view')) then raise exception 'Butuh izin lihat ulasan'; end if;
  return jsonb_build_object(
    'ringkasan', crm_feedback_summary(p_from, p_to, null),
    'pertanyaan', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'jenis', kind, 'pertanyaan', label) order by sort_order)
      from crm_feedback_questions where company_id = sys_current_company_id()), '[]'::jsonb),
    'ulasan', coalesce((select jsonb_agg(jsonb_build_object('tanggal', (r.created_at at time zone 'Asia/Jakarta')::date, 'outlet', o.name,
        'bintang', r.overall, 'nps', r.nps, 'komentar', r.comment, 'jawaban', r.answers, 'status', r.status) order by r.created_at desc)
      from (select * from crm_feedback_responses where company_id = sys_current_company_id()
              and (created_at at time zone 'Asia/Jakarta')::date between p_from and p_to
              and (outlet_id is null or sys_can_access_outlet(outlet_id)) order by created_at desc limit 120) r
      left join sys_outlets o on o.id = r.outlet_id), '[]'::jsonb));
end $$;

-- rekap SDM per karyawan
create or replace function ai_hr_recap(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not (sys_has_permission('*') or sys_has_permission('hr.view')) then raise exception 'Butuh izin lihat data karyawan'; end if;
  if p_to < p_from or p_to - p_from > 92 then raise exception 'Rentang maksimal 3 bulan'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'alpa')::int desc, (x->>'telat')::int desc, x->>'nama') from (
    select jsonb_build_object(
      'nama', e.full_name, 'jabatan', p.name, 'outlet', o.name, 'status_kerja', e.employment_status, 'masuk_kerja', e.join_date,
      'terjadwal', (select count(*) from hr_rosters r where r.employee_id = e.id and r.work_date between p_from and least(p_to, v_today) and not r.is_off and r.shift_id is not null),
      'hadir', (select count(*) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to and a.check_in_at is not null),
      'telat', (select count(*) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to and a.late_minutes > 0),
      'total_menit_telat', (select coalesce(sum(a.late_minutes), 0) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to),
      'pulang_cepat', (select count(*) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to and a.early_leave_minutes > 0),
      'alpa', (select count(*) from hr_rosters r where r.employee_id = e.id and r.work_date between p_from and least(p_to, v_today - 1) and not r.is_off and r.shift_id is not null
                 and not exists (select 1 from hr_attendances a where a.employee_id = e.id and a.work_date = r.work_date)
                 and hr_leave_on(e.id, r.work_date) is null),
      'cuti_hari', (select coalesce(sum(l.days), 0) from hr_leave_requests l where l.employee_id = e.id and l.status = 'approved' and l.start_date <= p_to and l.end_date >= p_from),
      'sisa_cuti_tahunan', (hr_leave_balance(e.id, extract(year from v_today)::int))->'remaining',
      'tugas_terbuka', (select count(*) from hr_tasks t where t.assignee_id = e.user_id and t.status in ('new', 'in_progress', 'review')),
      'tugas_lewat_tenggat', (select count(*) from hr_tasks t where t.assignee_id = e.user_id and t.status in ('new', 'in_progress', 'review') and t.due_date < v_today)) as x
    from hr_employees e left join hr_positions p on p.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
    where e.company_id = v_c and e.is_active and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))) t), '[]'::jsonb);
end $$;

-- Semar boleh mengusulkan template SOP & pertanyaan form ulasan (tetap lewat persetujuan owner)
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers',
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements', 'hr_shifts', 'hr_leave_types',
    'hr_sop_templates', 'crm_feedback_questions']
$$;
