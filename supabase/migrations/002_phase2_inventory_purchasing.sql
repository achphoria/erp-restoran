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
