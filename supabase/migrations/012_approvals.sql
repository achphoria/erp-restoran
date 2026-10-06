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
