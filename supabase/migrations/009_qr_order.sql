-- =====================================================================
-- ERP RESTORAN - 009: QR SELF-ORDER
--   Tamu scan QR meja -> lihat menu -> pesan. Tanpa login.
--   Item dari QR berstatus 'waiting' sampai kasir konfirmasi
--   (bisa dimatikan per outlet: qr_requires_confirmation = false).
-- =====================================================================

alter table mst_tables add column qr_token text not null default replace(gen_random_uuid()::text, '-', '');
create unique index uq_mst_tables_qr_token on mst_tables(qr_token);

alter table sys_outlets add column is_qr_order_enabled      boolean not null default true;
alter table sys_outlets add column qr_requires_confirmation boolean not null default true;

alter table pos_orders add column order_source text not null default 'pos';   -- pos / qr

-- =====================================================================
-- INTERNAL: buat header order & tambah item (dipakai POS dan QR)
-- =====================================================================
create or replace function pos_create_order_header(
  p_outlet_id uuid, p_table_id uuid, p_sales_channel text, p_customer_name text, p_guest_count int,
  p_note text, p_customer_id uuid, p_order_source text, p_created_by uuid
)
returns pos_orders language plpgsql security definer set search_path = public as $$
declare
  v_outlet sys_outlets%rowtype;
  v_date   date;
  v_key    text;
  v_order  pos_orders%rowtype;
begin
  select * into v_outlet from sys_outlets where id = p_outlet_id;
  v_date := sys_outlet_business_date(p_outlet_id);
  v_key := 'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD');

  insert into pos_orders (
    company_id, outlet_id, table_id, order_number, business_date, sales_channel,
    customer_name, guest_count, note, created_by, customer_id, order_source, shift_id
  ) values (
    v_outlet.company_id, p_outlet_id, p_table_id,
    v_key || '/' || lpad(sys_next_sequence(v_outlet.company_id, v_key)::text, 4, '0'),
    v_date, coalesce(nullif(p_sales_channel, ''), 'dine_in'),
    nullif(trim(p_customer_name), ''), coalesce(p_guest_count, 1), nullif(p_note, ''), p_created_by,
    p_customer_id, p_order_source,
    (select id from pos_shifts where outlet_id = p_outlet_id and user_id = p_created_by and status = 'open' limit 1)
  ) returning * into v_order;

  if p_table_id is not null then
    update mst_tables set status = 'occupied' where id = p_table_id and outlet_id = p_outlet_id;
  end if;
  return v_order;
end $$;

-- items: [{ "menu_item_id", "quantity", "note", "modifier_ids": [] }]
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

    v_price := coalesce(
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id = v_order.outlet_id and sales_channel = v_order.sales_channel),
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id is null and sales_channel = v_order.sales_channel),
      v_menu.base_price);

    -- hanya modifier yang memang terhubung ke menu ini
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

-- =====================================================================
-- POS: simpan order (versi baru, mendukung customer_id)
-- =====================================================================
create or replace function pos_save_order(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company     uuid := sys_current_company_id();
  v_order_id    uuid := nullif(p_payload->>'order_id', '')::uuid;
  v_outlet_id   uuid;
  v_customer_id uuid := nullif(p_payload->>'customer_id', '')::uuid;
  v_order       pos_orders%rowtype;
begin
  if v_company is null then raise exception 'Anda belum login'; end if;
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin membuat order'; end if;

  if v_customer_id is not null and not exists (
      select 1 from crm_customers where id = v_customer_id and company_id = v_company and is_active) then
    raise exception 'Pelanggan tidak ditemukan';
  end if;

  if v_order_id is null then
    v_outlet_id := (p_payload->>'outlet_id')::uuid;
    if not sys_can_access_outlet(v_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
    v_order := pos_create_order_header(
      v_outlet_id, nullif(p_payload->>'table_id', '')::uuid, p_payload->>'sales_channel',
      coalesce(nullif(p_payload->>'customer_name', ''), (select name from crm_customers where id = v_customer_id)),
      (p_payload->>'guest_count')::int, p_payload->>'note', v_customer_id, 'pos', auth.uid());
  else
    select * into v_order from pos_orders where id = v_order_id and company_id = v_company for update;
    if not found then raise exception 'Order tidak ditemukan'; end if;
    if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  end if;

  perform pos_add_order_items(v_order.id, p_payload->'items', 'pending');

  select * into v_order from pos_orders where id = v_order.id;
  return to_jsonb(v_order);
end $$;

-- Kasir mengonfirmasi item dari QR -> diteruskan ke dapur
create or replace function pos_confirm_qr_items(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  update pos_order_items set kitchen_status = 'pending'
  where order_id = p_order_id and kitchen_status = 'waiting' and company_id = sys_current_company_id();
end $$;

create or replace function pos_regenerate_table_qr(p_table_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text := replace(gen_random_uuid()::text, '-', '');
begin
  if not sys_has_permission('master.manage') then raise exception 'Tidak punya izin'; end if;
  update mst_tables set qr_token = v_token where id = p_table_id and company_id = sys_current_company_id();
  if not found then raise exception 'Meja tidak ditemukan'; end if;
  return v_token;
end $$;

-- =====================================================================
-- PUBLIK (tanpa login) - diakses dengan token QR meja
-- =====================================================================
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
        'price', coalesce(
          (select price from mst_menu_prices where menu_item_id = i.id and outlet_id = v_outlet.id and sales_channel = 'dine_in'),
          (select price from mst_menu_prices where menu_item_id = i.id and outlet_id is null and sales_channel = 'dine_in'),
          i.base_price),
        'modifier_groups', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select,
            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'extra_price', m.extra_price)
                                                    order by m.sort_order) from mst_modifiers m where m.modifier_group_id = g.id), '[]'::jsonb)))
          from mst_menu_item_modifier_groups l join mst_modifier_groups g on g.id = l.modifier_group_id
          where l.menu_item_id = i.id), '[]'::jsonb)
      ) order by i.name)
      from mst_menu_items i
      where i.company_id = v_outlet.company_id and i.brand_id = v_outlet.brand_id and i.is_active), '[]'::jsonb)
  );
end $$;

-- Status pesanan yang sedang berjalan di meja ini
create or replace function public_get_table_order(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'grand_total', o.grand_total, 'subtotal', o.subtotal,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.menu_item_name, 'quantity', i.quantity, 'line_total', i.line_total, 'note', i.note,
        'kitchen_status', i.kitchen_status,
        'modifiers', (select coalesce(jsonb_agg(m.modifier_name), '[]'::jsonb) from pos_order_item_modifiers m where m.order_item_id = i.id))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb))
  from mst_tables t
  join pos_orders o on o.table_id = t.id and o.status = 'open'
  where t.qr_token = p_token
  order by o.created_at desc
  limit 1
$$;

-- p_items: [{ "menu_item_id", "quantity", "note", "modifier_ids": [] }]
create or replace function public_submit_table_order(p_token text, p_customer_name text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_table  mst_tables%rowtype;
  v_outlet sys_outlets%rowtype;
  v_order  pos_orders%rowtype;
  v_recent int;
begin
  select * into v_table from mst_tables where qr_token = p_token for update;
  if not found then raise exception 'QR tidak valid. Silakan minta bantuan pelayan.'; end if;
  select * into v_outlet from sys_outlets where id = v_table.outlet_id;
  if not v_outlet.is_active or not v_outlet.is_qr_order_enabled then
    raise exception 'Pemesanan lewat QR sedang tidak tersedia.';
  end if;

  -- batas anti-spam: maks 40 item dari QR per meja dalam 10 menit
  select count(*) into v_recent
  from pos_order_items i join pos_orders o on o.id = i.order_id
  where o.table_id = v_table.id and o.order_source = 'qr' and i.created_at > now() - interval '10 minutes';
  if v_recent + jsonb_array_length(coalesce(p_items, '[]')) > 40 then
    raise exception 'Terlalu banyak pesanan dalam waktu singkat. Silakan panggil pelayan.';
  end if;

  -- gabung ke order yang masih terbuka di meja ini, atau buat baru
  select * into v_order from pos_orders
  where table_id = v_table.id and status = 'open'
  order by created_at desc limit 1 for update;

  if not found then
    v_order := pos_create_order_header(v_outlet.id, v_table.id, 'dine_in', left(p_customer_name, 60), 1,
                                       null, null, 'qr', null);
  end if;

  perform pos_add_order_items(v_order.id, p_items,
    case when v_outlet.qr_requires_confirmation then 'waiting' else 'pending' end);

  return public_get_table_order(p_token);
end $$;

-- Order dengan item QR yang belum dikonfirmasi tidak boleh dibayar
create or replace function pos_check_unconfirmed_items()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from pos_order_items where order_id = new.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi. Konfirmasi atau void dulu sebelum bayar.';
  end if;
  return new;
end $$;

create trigger trg_pos_orders_check_unconfirmed
  before update of status on pos_orders
  for each row when (new.status = 'paid' and old.status is distinct from 'paid')
  execute function pos_check_unconfirmed_items();

-- =====================================================================
-- HAK EKSEKUSI
-- =====================================================================
revoke execute on function pos_create_order_header(uuid, uuid, text, text, int, text, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function pos_add_order_items(uuid, jsonb, text) from public, anon, authenticated;

grant execute on function public_get_table_menu(text)                  to anon, authenticated;
grant execute on function public_get_table_order(text)                 to anon, authenticated;
grant execute on function public_submit_table_order(text, text, jsonb) to anon, authenticated;

-- realtime untuk notifikasi pesanan QR (pos_order_items sudah terdaftar)
