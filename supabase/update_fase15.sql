-- =====================================================================
-- SANTAP ERP - UPDATE FASE 15 (Simple Manufacturing ala ESB)
-- Untuk database yang SUDAH menjalankan fase 1-14.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

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
