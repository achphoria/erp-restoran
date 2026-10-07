-- =====================================================================
-- SANTAP ERP - UPDATE FASE 7 (Master Produk ala ESB)
-- Kategori bertipe + akun, sub kategori, multi-unit, min/max per gudang, import Excel,
-- BOM lanjutan, produksi, pricelist supplier, toleransi terima, menu paket, jadwal harga.
-- Untuk database yang SUDAH menjalankan fase 1-6.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

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
