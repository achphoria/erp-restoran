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
