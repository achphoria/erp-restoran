-- =====================================================================
-- SANTAP ERP - UPDATE FASE 11 (Sales Order antar cabang & B2B, gudang per toko, settlement POS)
-- Untuk database yang SUDAH menjalankan fase 1-10.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

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
