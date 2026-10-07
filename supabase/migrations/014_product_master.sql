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
