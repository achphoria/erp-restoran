-- =====================================================================
-- ERP RESTORAN - UPDATE FASE 5 (Foto menu, Menu habis, Pindah/Gabung/Split bill, Refund)
-- Untuk database yang SUDAH menjalankan fase 1-4.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/010_pos_extras.sql
-- =====================================================================
-- ERP RESTORAN - 010: FOTO MENU + KELENGKAPAN POS
--   * Foto menu (Supabase Storage, bucket publik "menu-images")
--   * Menu habis / sold out per outlet (reset otomatis hari berikutnya)
--   * Pindah meja, gabung bill, split bill
--   * Refund order lunas (balik stok opsional, poin member, jurnal)
--   Permission baru: pos.refund
-- =====================================================================

-- =====================================================================
-- FOTO MENU
-- File disimpan di menu-images/<company_id>/<nama-file>
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menu-images', 'menu-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy menu_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'menu-images'
              and (storage.foldername(name))[1] = sys_current_company_id()::text
              and sys_has_permission('master.manage'));
create policy menu_images_update on storage.objects for update to authenticated
  using (bucket_id = 'menu-images'
         and (storage.foldername(name))[1] = sys_current_company_id()::text
         and sys_has_permission('master.manage'));
create policy menu_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'menu-images'
         and (storage.foldername(name))[1] = sys_current_company_id()::text
         and sys_has_permission('master.manage'));

-- =====================================================================
-- MENU HABIS (SOLD OUT)
-- =====================================================================
create table mst_menu_sold_outs (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid not null references sys_outlets(id),
  menu_item_id   uuid not null references mst_menu_items(id) on delete cascade,
  business_date  date not null,
  created_by     uuid references sys_users(id),
  created_at     timestamptz not null default now(),
  unique (outlet_id, menu_item_id, business_date)
);

select sys_apply_company_policies('mst_menu_sold_outs');   -- ubah lewat fungsi
alter publication supabase_realtime add table mst_menu_sold_outs;

create or replace function pos_set_menu_sold_out(p_outlet_id uuid, p_menu_item_id uuid, p_is_sold_out boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_date date := sys_outlet_business_date(p_outlet_id);
begin
  if not (sys_has_permission('pos.order') or sys_has_permission('kds.update') or sys_has_permission('master.manage')) then
    raise exception 'Tidak punya izin';
  end if;
  if not sys_can_access_outlet(p_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if not exists (select 1 from mst_menu_items where id = p_menu_item_id and company_id = sys_current_company_id()) then
    raise exception 'Menu tidak ditemukan';
  end if;

  if p_is_sold_out then
    insert into mst_menu_sold_outs (company_id, outlet_id, menu_item_id, business_date, created_by)
    values (sys_current_company_id(), p_outlet_id, p_menu_item_id, v_date, auth.uid())
    on conflict do nothing;
  else
    delete from mst_menu_sold_outs
    where outlet_id = p_outlet_id and menu_item_id = p_menu_item_id and business_date = v_date;
  end if;
end $$;

-- Menu habis tidak bisa dipesan (POS maupun QR)
create or replace function pos_check_menu_available()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('erp.skip_availability_check', true), '') = 'on' then return new; end if;
  if exists (
    select 1 from mst_menu_sold_outs s join pos_orders o on o.id = new.order_id
    where s.menu_item_id = new.menu_item_id and s.outlet_id = o.outlet_id
      and s.business_date = sys_outlet_business_date(o.outlet_id)) then
    raise exception '% sedang habis', new.menu_item_name;
  end if;
  return new;
end $$;

create trigger trg_pos_order_items_available before insert on pos_order_items
  for each row execute function pos_check_menu_available();

-- Untuk halaman QR tamu
create or replace function public_get_sold_out_items(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s.menu_item_id), '[]'::jsonb)
  from mst_tables t
  join mst_menu_sold_outs s on s.outlet_id = t.outlet_id and s.business_date = sys_outlet_business_date(t.outlet_id)
  where t.qr_token = p_token
$$;
grant execute on function public_get_sold_out_items(text) to anon, authenticated;

-- =====================================================================
-- PINDAH MEJA
-- =====================================================================
create or replace function pos_free_table_if_empty(p_table_id uuid)
returns void language sql security definer set search_path = public as $$
  update mst_tables set status = 'available'
  where id = p_table_id and not exists (select 1 from pos_orders where table_id = p_table_id and status = 'open')
$$;

create or replace function pos_move_order_table(p_order_id uuid, p_table_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  v_old   uuid;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);
  if not exists (select 1 from mst_tables where id = p_table_id and outlet_id = v.outlet_id) then
    raise exception 'Meja tidak ditemukan di outlet ini';
  end if;
  v_old := v.table_id;

  update pos_orders set table_id = p_table_id, sales_channel = 'dine_in' where id = p_order_id;
  update mst_tables set status = 'occupied' where id = p_table_id;
  if v_old is not null and v_old <> p_table_id then perform pos_free_table_if_empty(v_old); end if;

  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

-- =====================================================================
-- GABUNG BILL: semua item order sumber pindah ke order tujuan
-- =====================================================================
create or replace function pos_merge_orders(p_target_order_id uuid, p_source_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t pos_orders%rowtype;
  s pos_orders%rowtype;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  if p_target_order_id = p_source_order_id then raise exception 'Pilih dua order yang berbeda'; end if;
  t := pos_lock_open_order(p_target_order_id);
  s := pos_lock_open_order(p_source_order_id);
  if t.outlet_id <> s.outlet_id then raise exception 'Order harus dari outlet yang sama'; end if;

  update pos_order_items set order_id = t.id where order_id = s.id;
  update pos_orders set guest_count = t.guest_count + s.guest_count where id = t.id;
  update pos_orders set status = 'merged', voided_at = now(), void_reason = 'Digabung ke ' || t.order_number
  where id = s.id;
  if s.table_id is not null then perform pos_free_table_if_empty(s.table_id); end if;

  perform pos_recalculate_order(t.id);
  perform pos_recalculate_order(s.id);
  select * into t from pos_orders where id = t.id;
  return to_jsonb(t);
end $$;

-- =====================================================================
-- SPLIT BILL: pindahkan sebagian item (boleh sebagian qty) ke order baru
-- p_items: [{ "order_item_id": uuid, "quantity": 1 }]
-- =====================================================================
create or replace function pos_split_order(p_order_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  n       pos_orders%rowtype;
  v_req   jsonb;
  v_line  pos_order_items%rowtype;
  v_qty   numeric(10,2);
  v_new   uuid;
  v_moved int := 0;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);

  n := pos_create_order_header(v.outlet_id, v.table_id, v.sales_channel, v.customer_name, 1,
                               'Split dari ' || v.order_number, null, v.order_source, auth.uid());
  -- item yang dipindah sudah dipesan sebelumnya, jadi tidak dicek ulang status habisnya
  perform set_config('erp.skip_availability_check', 'on', true);

  for v_req in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    select * into v_line from pos_order_items
    where id = (v_req->>'order_item_id')::uuid and order_id = p_order_id and not is_void
    for update;
    if not found then continue; end if;
    v_qty := least(coalesce((v_req->>'quantity')::numeric, v_line.quantity), v_line.quantity);
    if v_qty <= 0 then continue; end if;

    if v_qty = v_line.quantity then
      update pos_order_items set order_id = n.id where id = v_line.id;
    else
      update pos_order_items
         set quantity = quantity - v_qty, line_total = (quantity - v_qty) * (unit_price + modifier_amount)
       where id = v_line.id;
      insert into pos_order_items (company_id, order_id, menu_item_id, menu_item_name, station, quantity,
        unit_price, modifier_amount, line_total, note, kitchen_status, created_at)
      values (v_line.company_id, n.id, v_line.menu_item_id, v_line.menu_item_name, v_line.station, v_qty,
        v_line.unit_price, v_line.modifier_amount, v_qty * (v_line.unit_price + v_line.modifier_amount),
        v_line.note, v_line.kitchen_status, v_line.created_at)
      returning id into v_new;
      insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
      select company_id, v_new, modifier_id, modifier_name, extra_price
      from pos_order_item_modifiers where order_item_id = v_line.id;
    end if;
    v_moved := v_moved + 1;
  end loop;

  perform set_config('erp.skip_availability_check', 'off', true);

  if v_moved = 0 then raise exception 'Pilih item yang mau dipisah'; end if;
  if not exists (select 1 from pos_order_items where order_id = p_order_id and not is_void) then
    raise exception 'Sisakan minimal satu item di bill asal';
  end if;

  perform pos_recalculate_order(p_order_id);
  perform pos_recalculate_order(n.id);
  select * into n from pos_orders where id = n.id;
  return to_jsonb(n);
end $$;

-- =====================================================================
-- REFUND ORDER LUNAS (penuh)
-- =====================================================================
create table pos_refunds (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid not null references sys_outlets(id),
  order_id       uuid not null unique references pos_orders(id),
  shift_id       uuid references pos_shifts(id),
  refund_number  text not null,
  business_date  date not null,
  amount         numeric(15,2) not null,
  reason         text not null,
  is_stock_returned boolean not null default false,
  refunded_by    uuid references sys_users(id),
  refunded_at    timestamptz not null default now(),
  created_at     timestamptz not null default now()
);

create table pos_refund_payments (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  refund_id          uuid not null references pos_refunds(id) on delete cascade,
  payment_method_id  uuid not null references mst_payment_methods(id),
  amount             numeric(15,2) not null,
  created_at         timestamptz not null default now()
);

alter table pos_orders add column refunded_at timestamptz;

select sys_apply_company_policies('pos_refunds');
select sys_apply_company_policies('pos_refund_payments');

create or replace function pos_refund_order(p_order_id uuid, p_reason text, p_return_stock boolean default false)
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
  if not sys_has_permission('pos.refund') then raise exception 'Tidak punya izin refund'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan refund wajib diisi'; end if;

  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if o.status <> 'paid' then raise exception 'Hanya order lunas yang bisa direfund'; end if;

  select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = auth.uid() and status = 'open' limit 1;
  if v_shift is null and exists (
      select 1 from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
      where p.order_id = o.id and m.type = 'cash') then
    raise exception 'Buka shift kasir dulu (uang tunai dikembalikan dari laci)';
  end if;
  v_date := sys_outlet_business_date(o.outlet_id);

  insert into pos_refunds (company_id, outlet_id, order_id, shift_id, refund_number, business_date, amount,
                           reason, is_stock_returned, refunded_by)
  values (o.company_id, o.outlet_id, o.id, v_shift, sys_next_document_number(o.company_id, 'RFD', v_date), v_date,
          o.grand_total, trim(p_reason), coalesce(p_return_stock, false), auth.uid())
  returning * into r;

  -- uang kembali lewat metode bayar semula
  insert into pos_refund_payments (company_id, refund_id, payment_method_id, amount)
  select o.company_id, r.id, payment_method_id, amount - change_amount
  from pos_payments where order_id = o.id;

  update pos_orders set status = 'refunded', refunded_at = now() where id = o.id;

  -- stok dikembalikan (mis. salah input, makanan belum dibuat)
  if p_return_stock then
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, note, created_by)
    select company_id, warehouse_id, item_id, 'sales_return', -quantity, unit_cost,
           'pos_refunds', r.id, r.refund_number, 'Refund ' || o.order_number, auth.uid()
    from inv_stock_movements where reference_type = 'pos_orders' and reference_id = o.id;
  end if;

  -- member: tarik poin yang didapat, kembalikan poin yang ditukar
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

  -- jurnal balik dari jurnal penjualan (HPP ikut dibalik hanya bila stok dikembalikan)
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

-- Tutup shift: kas = modal + tunai masuk - refund tunai
create or replace function pos_close_shift(p_shift_id uuid, p_closing_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shift    pos_shifts%rowtype;
  v_cash_in  numeric(15,2);
  v_cash_out numeric(15,2);
begin
  select * into v_shift from pos_shifts
  where id = p_shift_id and user_id = auth.uid() and status = 'open' for update;
  if not found then raise exception 'Shift tidak ditemukan / sudah ditutup'; end if;

  select coalesce(sum(p.amount - p.change_amount), 0) into v_cash_in
  from pos_payments p
  join pos_orders o on o.id = p.order_id
  join mst_payment_methods m on m.id = p.payment_method_id
  where o.shift_id = p_shift_id and o.status in ('paid', 'refunded') and m.type = 'cash';

  select coalesce(sum(rp.amount), 0) into v_cash_out
  from pos_refund_payments rp
  join pos_refunds r on r.id = rp.refund_id
  join mst_payment_methods m on m.id = rp.payment_method_id
  where r.shift_id = p_shift_id and m.type = 'cash';

  update pos_shifts set
    status        = 'closed',
    closed_at     = now(),
    closing_cash  = p_closing_cash,
    expected_cash = v_shift.opening_cash + v_cash_in - v_cash_out
  where id = p_shift_id
  returning * into v_shift;

  return to_jsonb(v_shift) || jsonb_build_object('difference', v_shift.closing_cash - v_shift.expected_cash);
end $$;

-- Laporan refund & void (audit kasir)
create view rpt_refunds with (security_invoker = true) as
select r.company_id, r.outlet_id, r.business_date, r.refund_number, o.order_number, r.amount, r.reason,
       r.is_stock_returned, r.refunded_at, u.full_name as refunded_by_name
from pos_refunds r
join pos_orders o on o.id = r.order_id
left join sys_users u on u.id = r.refunded_by;

create view rpt_voids with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date, o.order_number, 'order' as void_type,
       o.subtotal as amount, o.void_reason as reason, o.voided_at
from pos_orders o where o.status = 'void'
union all
select o.company_id, o.outlet_id, o.business_date, o.order_number, 'item',
       i.line_total, substring(i.note from '\[VOID: (.*)\]'), i.updated_at
from pos_order_items i join pos_orders o on o.id = i.order_id
where i.is_void and o.status <> 'void';

update sys_roles set permissions = permissions || '["pos.refund"]'::jsonb
where code = 'manager' and not permissions ? 'pos.refund';

revoke execute on function pos_free_table_if_empty(uuid) from public, anon, authenticated;
