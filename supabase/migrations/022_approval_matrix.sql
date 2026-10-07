-- =====================================================================
-- SANTAP ERP - 022: APPROVAL UNTUK SEMUA TRANSAKSI PENTING (1 TINGKAT)
--   Jenis baru: sales_order, credit_note, sales_payment, supplier_payment,
--               pos_settlement, manual_journal, stock_transfer
--   Penyetuju = role yang punya hak approval.<jenis> (diatur di matriks
--   Pengaturan -> Approval Transaksi). Penyetuju tidak perlu punya akses
--   modulnya: saat menyetujui, sistem menjalankan transaksi atas nama pembuat.
-- =====================================================================

-- ---------------------------------------------------------------------
-- DELEGASI: selama keputusan approval diproses, penyetuju "bertindak sebagai"
-- pembuat untuk hak akses modul tertentu (hanya di dalam transaksi itu)
-- ---------------------------------------------------------------------
create or replace function sys_has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select r.permissions ? '*' or r.permissions ? p_permission
    from sys_users u join sys_roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active
  ), false)
  or coalesce(p_permission = any(string_to_array(nullif(current_setting('erp.acting_for', true), ''), ',')), false)
$$;

create or replace function sys_act_for(p_permissions text)
returns void language sql security definer set search_path = public as $$
  select set_config('erp.acting_for', coalesce(p_permissions, ''), true)
$$;

-- ---------------------------------------------------------------------
-- ATURAN
-- ---------------------------------------------------------------------
alter table sys_approval_rules drop constraint sys_approval_rules_document_type_check;
alter table sys_approval_rules add constraint sys_approval_rules_document_type_check
  check (document_type in ('purchase_order', 'expense', 'stock_adjustment', 'stock_opname', 'refund', 'product', 'pricelist',
                           'sales_order', 'credit_note', 'sales_payment', 'supplier_payment', 'pos_settlement',
                           'manual_journal', 'stock_transfer'));

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
    (p_company_id, 'stock_transfer',   5000000, false)
  on conflict do nothing
$$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform sys_setup_approval_rules(r.id); end loop;
end $$;

-- ---------------------------------------------------------------------
-- SALES ORDER: konfirmasi SO (cabang & B2B)
-- ---------------------------------------------------------------------
alter table sal_sales_orders drop constraint sal_sales_orders_status_check;
alter table sal_sales_orders add constraint sal_sales_orders_status_check check (status in
  ('draft', 'new', 'pending_approval', 'confirmed', 'partially_delivered', 'delivered', 'closed', 'rejected', 'cancelled'));

create or replace function sal_confirm_sales_order(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  so      sal_sales_orders%rowtype;
  c       sal_customers%rowtype;
  v_open  numeric;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('approval.sales_order')) then raise exception 'Tidak punya izin'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('draft', 'new', 'pending_approval') then raise exception 'Sales order tidak ditemukan / sudah dikonfirmasi'; end if;
  if not exists (select 1 from sal_sales_order_items where sales_order_id = p_id) then raise exception 'Sales order belum punya item'; end if;
  if exists (select 1 from sal_sales_order_items where sales_order_id = p_id and unit_price <= 0) and so.customer_type = 'external' then
    raise exception 'Ada barang tanpa harga. Isi harga atau tambahkan di Pricelist Jual.';
  end if;
  perform sal_recalculate_order(p_id);
  select * into so from sal_sales_orders where id = p_id;

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

  if sys_approval_required('sales_order', so.grand_total) then
    if so.status = 'pending_approval' then raise exception 'Sales order ini masih menunggu persetujuan'; end if;
    update sal_sales_orders set status = 'pending_approval',
      so_number = coalesce(so_number, sys_next_document_number(company_id, 'SO', so_date))
    where id = p_id returning * into so;
    return to_jsonb(so) || sys_request_approval('sales_order', p_id, so.outlet_id, so.grand_total,
      'SO ' || so.so_number || ' - ' || coalesce((select name from sal_customers where id = so.customer_id),
                                                 (select name from sys_outlets where id = so.buyer_outlet_id), ''), '{}');
  end if;

  update sal_sales_orders set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now(),
    so_number = coalesce(so_number, sys_next_document_number(company_id, 'SO', so_date))
  where id = p_id returning * into so;
  perform sys_close_approval('sales_order', p_id);
  return to_jsonb(so);
end $$;

create or replace function sal_reject_sales_order(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare so sal_sales_orders%rowtype;
begin
  if not sys_has_permission('sales.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
  select * into so from sal_sales_orders where id = p_id and company_id = sys_current_company_id() for update;
  if not found or so.status not in ('draft', 'new', 'pending_approval', 'confirmed')
     or exists (select 1 from sal_deliveries where sales_order_id = p_id and status <> 'cancelled') then
    raise exception 'Sales order tidak bisa ditolak (sudah ada pengiriman)';
  end if;
  update sal_sales_orders set status = case when customer_type = 'internal' then 'rejected' else 'cancelled' end,
    reject_reason = trim(p_reason) where id = p_id;
  update sys_approval_requests set status = 'cancelled', decision_note = 'SO ditolak / dibatalkan'
  where document_type = 'sales_order' and document_id = p_id and status = 'pending';
  if so.purchase_order_id is not null then
    update pur_purchase_orders set status = 'cancelled', sales_note = 'Ditolak penjual: ' || trim(p_reason) where id = so.purchase_order_id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- TRANSAKSI SEKALI JALAN: dibungkus pemeriksa approval.
-- Fungsi asli diganti nama *_execute dan hanya dipanggil wrapper / keputusan approval.
-- ---------------------------------------------------------------------
alter function sal_create_credit_note(uuid, numeric, text, text) rename to sal_create_credit_note_execute;
alter function sal_record_payment(jsonb, uuid, uuid, date, text, text) rename to sal_record_payment_execute;
alter function fin_pay_supplier(uuid, uuid, date, jsonb, text) rename to fin_pay_supplier_execute;
alter function pos_create_settlement(uuid, uuid, date[], numeric, numeric, uuid, date, text, text) rename to pos_create_settlement_execute;
alter function fin_post_manual_journal(date, text, jsonb) rename to fin_post_manual_journal_execute;

-- Nota kredit
create or replace function sal_create_credit_note(p_invoice_id uuid, p_amount numeric, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv sal_invoices%rowtype;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('approval.credit_note')) then raise exception 'Tidak punya izin'; end if;
  select * into inv from sal_invoices where id = p_invoice_id and company_id = sys_current_company_id();
  if not found then raise exception 'Invoice tidak ditemukan'; end if;
  if coalesce(p_amount, 0) <= 0 or p_amount > inv.grand_total - inv.paid_amount - inv.credited_amount then
    raise exception 'Nominal nota kredit maksimal sisa tagihan (%)', inv.grand_total - inv.paid_amount - inv.credited_amount;
  end if;
  if sys_approval_required('credit_note', p_amount) then
    return sys_request_approval('credit_note', inv.id, inv.outlet_id, p_amount, 'Nota kredit ' || inv.invoice_number,
      jsonb_build_object('amount', p_amount, 'reason', p_reason, 'note', p_note));
  end if;
  return sal_create_credit_note_execute(p_invoice_id, p_amount, p_reason, p_note);
end $$;

-- Pembayaran invoice (terima pembayaran B2B / bayar tagihan cabang)
create or replace function sal_record_payment(
  p_allocations jsonb, p_to_account_id uuid, p_from_account_id uuid default null,
  p_payment_date date default current_date, p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_total numeric;
  v_inv   sal_invoices%rowtype;
begin
  if not (sys_has_permission('sales.manage') or sys_has_permission('finance.manage') or sys_has_permission('purchasing.manage')
          or sys_has_permission('approval.sales_payment')) then
    raise exception 'Tidak punya izin';
  end if;
  select coalesce(sum(round((a->>'amount')::numeric, 2)), 0) into v_total from jsonb_array_elements(p_allocations) a where (a->>'amount')::numeric > 0;
  select * into v_inv from sal_invoices where id = (p_allocations->0->>'invoice_id')::uuid and company_id = sys_current_company_id();
  if not found then raise exception 'Pilih invoice yang dibayar'; end if;
  if sys_approval_required('sales_payment', v_total) then
    return sys_request_approval('sales_payment', v_inv.id, v_inv.outlet_id, v_total,
      'Pembayaran ' || v_inv.invoice_number || case when jsonb_array_length(p_allocations) > 1 then ' dkk' else '' end,
      jsonb_build_object('allocations', p_allocations, 'to_account_id', p_to_account_id, 'from_account_id', p_from_account_id,
                         'payment_date', coalesce(p_payment_date, current_date), 'reference', p_reference, 'note', p_note));
  end if;
  return sal_record_payment_execute(p_allocations, p_to_account_id, p_from_account_id, p_payment_date, p_reference, p_note);
end $$;

-- Bayar supplier
create or replace function fin_pay_supplier(
  p_supplier_id uuid, p_account_id uuid, p_payment_date date, p_allocations jsonb, p_reference_number text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_total numeric;
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.supplier_payment')) then raise exception 'Tidak punya izin'; end if;
  select coalesce(sum((a->>'amount')::numeric), 0) into v_total from jsonb_array_elements(p_allocations) a where (a->>'amount')::numeric > 0;
  if v_total <= 0 then raise exception 'Nominal pembayaran harus lebih dari 0'; end if;
  if sys_approval_required('supplier_payment', v_total) then
    return sys_request_approval('supplier_payment', p_supplier_id, null, v_total,
      'Bayar supplier ' || coalesce((select name from pur_suppliers where id = p_supplier_id), ''),
      jsonb_build_object('supplier_id', p_supplier_id, 'account_id', p_account_id, 'payment_date', coalesce(p_payment_date, current_date),
                         'allocations', p_allocations, 'reference', p_reference_number));
  end if;
  return fin_pay_supplier_execute(p_supplier_id, p_account_id, p_payment_date, p_allocations, p_reference_number);
end $$;

-- Settlement POS: yang dinilai adalah SELISIH (seharusnya - diterima - potongan)
create or replace function pos_create_settlement(
  p_outlet_id uuid, p_payment_method_id uuid, p_dates date[], p_received_amount numeric,
  p_fee_amount numeric default 0, p_to_account_id uuid default null, p_settlement_date date default current_date,
  p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_expected numeric;
  v_diff     numeric;
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.pos_settlement')) then raise exception 'Tidak punya izin'; end if;
  if exists (select 1 from pos_settlement_items where outlet_id = p_outlet_id and payment_method_id = p_payment_method_id and business_date = any(p_dates)) then
    raise exception 'Sebagian tanggal sudah pernah di-settle';
  end if;
  if exists (select 1 from sys_approval_requests where document_type = 'pos_settlement' and status = 'pending'
             and payload->>'outlet_id' = p_outlet_id::text and payload->>'payment_method_id' = p_payment_method_id::text
             and exists (select 1 from jsonb_array_elements_text(payload->'dates') d where d::date = any(p_dates))) then
    raise exception 'Sebagian tanggal sedang menunggu persetujuan settlement';
  end if;
  select coalesce(sum(net_amount), 0) into v_expected
  from rpt_pos_settlement_days where outlet_id = p_outlet_id and payment_method_id = p_payment_method_id and business_date = any(p_dates);
  v_diff := v_expected - round(coalesce(p_received_amount, 0), 2) - round(coalesce(p_fee_amount, 0), 2);

  if sys_approval_required('pos_settlement', abs(v_diff)) then
    return sys_request_approval('pos_settlement', p_payment_method_id, p_outlet_id, abs(v_diff),
      'Settlement ' || (select name from mst_payment_methods where id = p_payment_method_id) || ' ' ||
        (select name from sys_outlets where id = p_outlet_id) || ', selisih ' || to_char(v_diff, 'FM999G999G999'),
      jsonb_build_object('outlet_id', p_outlet_id, 'payment_method_id', p_payment_method_id, 'dates', to_jsonb(p_dates),
        'received_amount', p_received_amount, 'fee_amount', coalesce(p_fee_amount, 0), 'to_account_id', p_to_account_id,
        'settlement_date', coalesce(p_settlement_date, current_date), 'reference', p_reference, 'note', p_note));
  end if;
  return pos_create_settlement_execute(p_outlet_id, p_payment_method_id, p_dates, p_received_amount, p_fee_amount,
    p_to_account_id, p_settlement_date, p_reference, p_note);
end $$;

-- Jurnal manual (null = menunggu persetujuan)
create or replace function fin_post_manual_journal(p_date date, p_description text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_total numeric;
begin
  if not (sys_has_permission('finance.manage') or sys_has_permission('approval.manual_journal')) then raise exception 'Tidak punya izin'; end if;
  select coalesce(sum(round(coalesce((l->>'debit')::numeric, 0), 2)), 0) into v_total from jsonb_array_elements(p_lines) l;
  if sys_approval_required('manual_journal', v_total) then
    perform sys_request_approval('manual_journal', null, null, v_total, coalesce(nullif(trim(p_description), ''), 'Jurnal manual'),
      jsonb_build_object('date', coalesce(p_date, current_date), 'description', p_description, 'lines', p_lines));
    return null;
  end if;
  return fin_post_manual_journal_execute(p_date, p_description, p_lines);
end $$;

-- ---------------------------------------------------------------------
-- TRANSFER GUDANG (kirim / kirim & terima)
-- ---------------------------------------------------------------------
alter function inv_ship_stock_transfer(uuid) rename to inv_ship_stock_transfer_execute;
alter function inv_post_stock_transfer(uuid) rename to inv_post_stock_transfer_execute;

-- true = transfer ditahan untuk approval (status pending_approval + permintaan dibuat)
create or replace function inv_transfer_hold_for_approval(p_id uuid, p_mode text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  t       inv_stock_transfers%rowtype;
  v_value numeric;
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_transfer')) then raise exception 'Tidak punya izin'; end if;
  select * into t from inv_stock_transfers where id = p_id and company_id = sys_current_company_id() for update;
  if not found or t.status not in ('draft', 'pending_approval') then raise exception 'Transfer tidak ditemukan / sudah dikirim'; end if;

  select coalesce(sum(i.quantity * coalesce(nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
  from inv_stock_transfer_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = t.from_warehouse_id and s.item_id = i.item_id
  where i.stock_transfer_id = p_id;

  if sys_approval_required('stock_transfer', v_value) then
    if t.status = 'pending_approval' then raise exception 'Transfer ini masih menunggu persetujuan'; end if;
    update inv_stock_transfers set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_transfer', p_id, (select outlet_id from inv_warehouses where id = t.from_warehouse_id), v_value,
      'Transfer ' || (select name from inv_warehouses where id = t.from_warehouse_id) || ' → ' || (select name from inv_warehouses where id = t.to_warehouse_id),
      jsonb_build_object('mode', p_mode));
    return true;
  end if;

  if t.status = 'pending_approval' then
    update inv_stock_transfers set status = 'draft' where id = p_id;
    perform sys_close_approval('stock_transfer', p_id);
  end if;
  return false;
end $$;

create or replace function inv_ship_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if inv_transfer_hold_for_approval(p_id, 'ship') then return; end if;
  perform inv_ship_stock_transfer_execute(p_id);
end $$;

create or replace function inv_post_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if inv_transfer_hold_for_approval(p_id, 'post') then return; end if;
  perform inv_post_stock_transfer_execute(p_id);
end $$;

-- ---------------------------------------------------------------------
-- KEPUTUSAN APPROVAL
-- ---------------------------------------------------------------------
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

revoke execute on function sys_act_for(text)                                                     from public, anon, authenticated;
revoke execute on function inv_transfer_hold_for_approval(uuid, text)                            from public, anon, authenticated;
revoke execute on function sal_create_credit_note_execute(uuid, numeric, text, text)             from public, anon, authenticated;
revoke execute on function sal_record_payment_execute(jsonb, uuid, uuid, date, text, text)       from public, anon, authenticated;
revoke execute on function fin_pay_supplier_execute(uuid, uuid, date, jsonb, text)               from public, anon, authenticated;
revoke execute on function pos_create_settlement_execute(uuid, uuid, date[], numeric, numeric, uuid, date, text, text)
                                                                                                 from public, anon, authenticated;
revoke execute on function fin_post_manual_journal_execute(date, text, jsonb)                    from public, anon, authenticated;
revoke execute on function inv_ship_stock_transfer_execute(uuid)                                 from public, anon, authenticated;
revoke execute on function inv_post_stock_transfer_execute(uuid)                                 from public, anon, authenticated;
