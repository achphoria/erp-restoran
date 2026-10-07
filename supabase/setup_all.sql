-- =====================================================================
-- SANTAP ERP - SETUP LENGKAP (gabungan migrations/001 s/d 018)
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
