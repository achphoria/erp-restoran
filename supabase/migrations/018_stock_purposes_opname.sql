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
