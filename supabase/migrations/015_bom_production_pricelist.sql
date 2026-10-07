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
