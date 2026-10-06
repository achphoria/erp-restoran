-- =====================================================================
-- ERP RESTORAN - 003: FUNGSI POS (dipanggil dari aplikasi via supabase.rpc)
-- =====================================================================

-- Nomor urut dokumen, aman dari tabrakan (atomic) ----------------------
create or replace function sys_next_sequence(p_company_id uuid, p_key text)
returns int language plpgsql security definer set search_path = public as $$
declare v_next int;
begin
  insert into sys_document_sequences (company_id, sequence_key, last_number)
  values (p_company_id, p_key, 1)
  on conflict (company_id, sequence_key)
  do update set last_number = sys_document_sequences.last_number + 1
  returning last_number into v_next;
  return v_next;
end $$;

-- Contoh hasil: PO/20261006/0001
create or replace function sys_next_document_number(p_company_id uuid, p_prefix text, p_date date default current_date)
returns text language plpgsql security definer set search_path = public as $$
declare v_key text := p_prefix || '/' || to_char(p_date, 'YYYYMMDD');
begin
  return v_key || '/' || lpad(sys_next_sequence(p_company_id, v_key)::text, 4, '0');
end $$;

create or replace function sys_outlet_business_date(p_outlet_id uuid)
returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone timezone)::date from sys_outlets where id = p_outlet_id
$$;

-- Info user login (dipakai aplikasi setelah login) ----------------------
create or replace function sys_get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', u.id,
    'full_name', u.full_name,
    'company_id', c.id,
    'company_name', c.name,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

-- =====================================================================
-- HITUNG ULANG TOTAL ORDER
--   subtotal - diskon -> + service -> + pajak (PB1) -> pembulatan
-- =====================================================================
create or replace function pos_recalculate_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order   pos_orders%rowtype;
  v_outlet  sys_outlets%rowtype;
  v_sub     numeric(15,2);
  v_base    numeric(15,2);
  v_service numeric(15,2);
  v_tax     numeric(15,2);
  v_raw     numeric(15,2);
  v_total   numeric(15,2);
begin
  select * into v_order from pos_orders where id = p_order_id;
  select * into v_outlet from sys_outlets where id = v_order.outlet_id;

  select coalesce(sum(line_total), 0) into v_sub
  from pos_order_items where order_id = p_order_id and not is_void;

  v_base    := greatest(v_sub - v_order.discount_amount, 0);
  v_service := round(v_base * v_outlet.service_charge_rate / 100);
  v_tax     := round((v_base + v_service) * v_outlet.tax_rate / 100);
  v_raw     := v_base + v_service + v_tax;
  v_total   := case when v_outlet.rounding_unit > 1
                    then round(v_raw / v_outlet.rounding_unit) * v_outlet.rounding_unit
                    else v_raw end;

  update pos_orders set
    subtotal        = v_sub,
    service_amount  = v_service,
    tax_amount      = v_tax,
    rounding_amount = v_total - v_raw,
    grand_total     = v_total
  where id = p_order_id;
end $$;

-- =====================================================================
-- SIMPAN ORDER (buat baru, atau tambah item ke open bill)
-- payload:
-- {
--   "order_id": null | uuid,          -- isi untuk menambah item
--   "outlet_id": uuid,
--   "table_id": uuid | null,
--   "sales_channel": "dine_in",
--   "customer_name": "Budi",
--   "guest_count": 2,
--   "note": "",
--   "items": [
--     { "menu_item_id": uuid, "quantity": 2, "note": "tanpa bawang",
--       "modifier_ids": [uuid, ...] }
--   ]
-- }
-- =====================================================================
create or replace function pos_save_order(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company   uuid := sys_current_company_id();
  v_order_id  uuid := nullif(p_payload->>'order_id', '')::uuid;
  v_outlet_id uuid;
  v_order     pos_orders%rowtype;
  v_outlet    sys_outlets%rowtype;
  v_channel   text;
  v_date      date;
  v_item      jsonb;
  v_menu      mst_menu_items%rowtype;
  v_price     numeric(15,2);
  v_mod_total numeric(15,2);
  v_qty       numeric(10,2);
  v_line_id   uuid;
begin
  if v_company is null then raise exception 'Anda belum login'; end if;
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin membuat order'; end if;
  if jsonb_array_length(coalesce(p_payload->'items', '[]')) = 0 then
    raise exception 'Order tidak punya item';
  end if;

  if v_order_id is null then
    v_outlet_id := (p_payload->>'outlet_id')::uuid;
    if not sys_can_access_outlet(v_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
    select * into v_outlet from sys_outlets where id = v_outlet_id;
    v_channel := coalesce(nullif(p_payload->>'sales_channel', ''), 'dine_in');
    v_date := sys_outlet_business_date(v_outlet_id);

    insert into pos_orders (
      company_id, outlet_id, table_id, order_number, business_date, sales_channel,
      customer_name, guest_count, note, created_by, shift_id
    ) values (
      v_company, v_outlet_id, nullif(p_payload->>'table_id', '')::uuid,
      'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD') || '/' ||
        lpad(sys_next_sequence(v_company, 'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD'))::text, 4, '0'),
      v_date, v_channel,
      nullif(p_payload->>'customer_name', ''),
      coalesce((p_payload->>'guest_count')::int, 1),
      nullif(p_payload->>'note', ''),
      auth.uid(),
      (select id from pos_shifts where outlet_id = v_outlet_id and user_id = auth.uid() and status = 'open' limit 1)
    ) returning * into v_order;

    if v_order.table_id is not null then
      update mst_tables set status = 'occupied' where id = v_order.table_id and company_id = v_company;
    end if;
  else
    select * into v_order from pos_orders where id = v_order_id and company_id = v_company for update;
    if not found then raise exception 'Order tidak ditemukan'; end if;
    if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
    v_outlet_id := v_order.outlet_id;
    v_channel := v_order.sales_channel;
  end if;

  for v_item in select * from jsonb_array_elements(p_payload->'items') loop
    select * into v_menu from mst_menu_items
    where id = (v_item->>'menu_item_id')::uuid and company_id = v_company and is_active;
    if not found then raise exception 'Menu tidak ditemukan / tidak aktif'; end if;

    v_qty := coalesce((v_item->>'quantity')::numeric, 1);
    if v_qty <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;

    v_price := coalesce(
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id = v_outlet_id and sales_channel = v_channel),
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id is null and sales_channel = v_channel),
      v_menu.base_price);

    select coalesce(sum(m.extra_price), 0) into v_mod_total
    from mst_modifiers m
    where m.company_id = v_company
      and m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);

    insert into pos_order_items (
      company_id, order_id, menu_item_id, menu_item_name, station,
      quantity, unit_price, modifier_amount, line_total, note
    ) values (
      v_company, v_order.id, v_menu.id, v_menu.name, v_menu.station,
      v_qty, v_price, v_mod_total, v_qty * (v_price + v_mod_total),
      nullif(v_item->>'note', '')
    ) returning id into v_line_id;

    insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
    select v_company, v_line_id, m.id, m.name, m.extra_price
    from mst_modifiers m
    where m.company_id = v_company
      and m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);
  end loop;

  perform pos_recalculate_order(v_order.id);

  select * into v_order from pos_orders where id = v_order.id;
  return to_jsonb(v_order);
end $$;

-- =====================================================================
-- DISKON ORDER (nominal Rp, sebelum service & pajak)
-- =====================================================================
create or replace function pos_set_order_discount(p_order_id uuid, p_discount_amount numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_order pos_orders%rowtype;
begin
  if not sys_has_permission('pos.discount') then raise exception 'Tidak punya izin memberi diskon'; end if;
  select * into v_order from pos_orders
  where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  if p_discount_amount < 0 or p_discount_amount > v_order.subtotal then
    raise exception 'Diskon harus antara 0 dan subtotal';
  end if;

  update pos_orders set discount_amount = p_discount_amount where id = p_order_id;
  perform pos_recalculate_order(p_order_id);
  select * into v_order from pos_orders where id = p_order_id;
  return to_jsonb(v_order);
end $$;

-- =====================================================================
-- BAYAR ORDER
-- payments: [ { "payment_method_id": uuid, "amount": 100000, "reference_number": "" } ]
-- =====================================================================
create or replace function pos_pay_order(
  p_order_id uuid,
  p_payments jsonb,
  p_discount_amount numeric default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_order    pos_orders%rowtype;
  v_shift_id uuid;
  v_paid     numeric(15,2);
  v_change   numeric(15,2);
  v_cash_id  uuid;
  v_pay      jsonb;
  v_method   mst_payment_methods%rowtype;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin menerima pembayaran'; end if;

  select * into v_order from pos_orders where id = p_order_id and company_id = v_company for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v_order.status <> 'open' then raise exception 'Order sudah dibayar / dibatalkan'; end if;

  select id into v_shift_id from pos_shifts
  where outlet_id = v_order.outlet_id and user_id = auth.uid() and status = 'open' limit 1;
  if v_shift_id is null then raise exception 'Buka shift kasir terlebih dahulu'; end if;

  if p_discount_amount is not null and p_discount_amount <> v_order.discount_amount then
    if p_discount_amount > 0 and not sys_has_permission('pos.discount') then
      raise exception 'Tidak punya izin memberi diskon';
    end if;
    update pos_orders set discount_amount = greatest(p_discount_amount, 0) where id = p_order_id;
    perform pos_recalculate_order(p_order_id);
    select * into v_order from pos_orders where id = p_order_id;
  end if;

  select coalesce(sum((p->>'amount')::numeric), 0) into v_paid
  from jsonb_array_elements(coalesce(p_payments, '[]')) p;

  if v_paid < v_order.grand_total then
    raise exception 'Pembayaran kurang: total %, dibayar %', v_order.grand_total, v_paid;
  end if;
  v_change := v_paid - v_order.grand_total;

  for v_pay in select * from jsonb_array_elements(p_payments) loop
    select * into v_method from mst_payment_methods
    where id = (v_pay->>'payment_method_id')::uuid and company_id = v_company and is_active;
    if not found then raise exception 'Metode pembayaran tidak valid'; end if;
    if (v_pay->>'amount')::numeric <= 0 then continue; end if;

    insert into pos_payments (company_id, order_id, payment_method_id, amount, reference_number)
    values (v_company, p_order_id, v_method.id, (v_pay->>'amount')::numeric, nullif(v_pay->>'reference_number', ''));
  end loop;

  if v_change > 0 then
    select pp.id into v_cash_id from pos_payments pp
    join mst_payment_methods m on m.id = pp.payment_method_id
    where pp.order_id = p_order_id and m.type = 'cash' limit 1;
    if v_cash_id is null then raise exception 'Kembalian hanya untuk pembayaran tunai'; end if;
    update pos_payments set change_amount = v_change where id = v_cash_id;
  end if;

  update pos_orders
     set status = 'paid', paid_at = now(), shift_id = v_shift_id
   where id = p_order_id;

  if v_order.table_id is not null and not exists (
      select 1 from pos_orders where table_id = v_order.table_id and status = 'open') then
    update mst_tables set status = 'available' where id = v_order.table_id;
  end if;

  return jsonb_build_object(
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'grand_total', v_order.grand_total,
    'paid_amount', v_paid,
    'change_amount', v_change);
end $$;

-- =====================================================================
-- VOID
-- =====================================================================
create or replace function pos_void_order(p_order_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_order pos_orders%rowtype;
begin
  if not sys_has_permission('pos.void') then raise exception 'Tidak punya izin void'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan void wajib diisi'; end if;

  select * into v_order from pos_orders
  where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v_order.status <> 'open' then raise exception 'Hanya order yang belum dibayar yang bisa di-void'; end if;

  update pos_orders set status = 'void', voided_at = now(), void_reason = p_reason where id = p_order_id;
  update pos_order_items set is_void = true where order_id = p_order_id;

  if v_order.table_id is not null and not exists (
      select 1 from pos_orders where table_id = v_order.table_id and status = 'open') then
    update mst_tables set status = 'available' where id = v_order.table_id;
  end if;
end $$;

create or replace function pos_void_order_item(p_order_item_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_order_id uuid;
begin
  if not sys_has_permission('pos.void') then raise exception 'Tidak punya izin void'; end if;

  select i.order_id into v_order_id
  from pos_order_items i join pos_orders o on o.id = i.order_id
  where i.id = p_order_item_id and o.company_id = sys_current_company_id() and o.status = 'open';
  if v_order_id is null then raise exception 'Item tidak ditemukan / order sudah ditutup'; end if;

  update pos_order_items
     set is_void = true, note = trim(coalesce(note, '') || ' [VOID: ' || coalesce(p_reason, '-') || ']')
   where id = p_order_item_id;
  perform pos_recalculate_order(v_order_id);
end $$;

-- =====================================================================
-- SHIFT KASIR
-- =====================================================================
create or replace function pos_open_shift(p_outlet_id uuid, p_opening_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shift pos_shifts%rowtype;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin membuka shift'; end if;
  if not sys_can_access_outlet(p_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if exists (select 1 from pos_shifts where outlet_id = p_outlet_id and user_id = auth.uid() and status = 'open') then
    raise exception 'Anda masih punya shift yang terbuka';
  end if;

  insert into pos_shifts (company_id, outlet_id, user_id, business_date, opening_cash)
  values (sys_current_company_id(), p_outlet_id, auth.uid(),
          sys_outlet_business_date(p_outlet_id), coalesce(p_opening_cash, 0))
  returning * into v_shift;
  return to_jsonb(v_shift);
end $$;

create or replace function pos_close_shift(p_shift_id uuid, p_closing_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shift    pos_shifts%rowtype;
  v_cash_in  numeric(15,2);
begin
  select * into v_shift from pos_shifts
  where id = p_shift_id and user_id = auth.uid() and status = 'open' for update;
  if not found then raise exception 'Shift tidak ditemukan / sudah ditutup'; end if;

  select coalesce(sum(p.amount - p.change_amount), 0) into v_cash_in
  from pos_payments p
  join pos_orders o on o.id = p.order_id
  join mst_payment_methods m on m.id = p.payment_method_id
  where o.shift_id = p_shift_id and o.status = 'paid' and m.type = 'cash';

  update pos_shifts set
    status        = 'closed',
    closed_at     = now(),
    closing_cash  = p_closing_cash,
    expected_cash = v_shift.opening_cash + v_cash_in
  where id = p_shift_id
  returning * into v_shift;

  return to_jsonb(v_shift) || jsonb_build_object('difference', v_shift.closing_cash - v_shift.expected_cash);
end $$;
