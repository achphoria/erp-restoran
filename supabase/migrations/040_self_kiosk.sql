-- =====================================================================
-- SEMAR - 040: SELF-ORDER KIOSK (layar sentuh berdiri / portrait)
--   * pos_kiosks: perangkat kiosk per outlet, dibuka lewat /kiosk/<token> (tanpa login staf).
--     Pengaturan: makan di sini / bawa pulang, teks sambutan, waktu idle, cetak struk.
--   * mst_menu_items.kiosk_featured / kiosk_badge: menu unggulan di layar sambutan & rekomendasi.
--     "Terlaris" dihitung otomatis dari penjualan 30 hari.
--   * pos_orders.queue_number: nomor antrean kiosk harian (K001, K002, ...).
--   * Bayar di kasir: item kiosk menunggu (waiting) dan otomatis masuk dapur saat kasir menerima
--     pembayaran, jadi dapur tidak memasak pesanan yang belum dibayar.
--   Izin baru: kiosk.manage (atur perangkat kiosk & menu unggulan).
-- =====================================================================

create table pos_kiosks (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  outlet_id         uuid not null references sys_outlets(id) on delete cascade,
  name              text not null check (trim(name) <> ''),
  token             text not null unique default replace(gen_random_uuid()::text, '-', ''),
  is_active         boolean not null default true,
  allow_dine_in     boolean not null default true,
  allow_takeaway    boolean not null default true,
  welcome_title     text not null default 'Pesan sendiri, lebih cepat',
  welcome_subtitle  text not null default 'Sentuh layar untuk mulai',
  idle_seconds      int not null default 90 check (idle_seconds between 30 and 600),
  print_receipt     boolean not null default true,
  last_seen_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (allow_dine_in or allow_takeaway)
);
alter table pos_kiosks enable row level security;
create policy pos_kiosks_select on pos_kiosks for select to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('kiosk.manage'));
create policy pos_kiosks_write on pos_kiosks for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('kiosk.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('kiosk.manage'));
select sys_apply_outlet_lock('pos_kiosks', 'sys_can_access_outlet(outlet_id)');
create trigger trg_pos_kiosks_audit after insert or update or delete on pos_kiosks for each row execute function sys_audit_trigger('token');

alter table mst_menu_items add column if not exists kiosk_featured boolean not null default false;
alter table mst_menu_items add column if not exists kiosk_badge text check (kiosk_badge is null or length(kiosk_badge) <= 16);
alter table pos_orders add column if not exists queue_number text;
alter table pos_orders add column if not exists kiosk_id uuid references pos_kiosks(id) on delete set null;

create or replace function pos_kiosk_regenerate_token(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text := replace(gen_random_uuid()::text, '-', '');
begin
  if not sys_has_permission('kiosk.manage') then raise exception 'Butuh izin atur kiosk'; end if;
  update pos_kiosks set token = v, updated_at = now()
  where id = p_id and company_id = sys_current_company_id() and sys_can_access_outlet(outlet_id);
  if not found then raise exception 'Kiosk tidak ditemukan'; end if;
  return v;
end $$;

-- menu unggulan (tanpa perlu izin master data penuh)
create or replace function pos_kiosk_set_highlight(p_item_id uuid, p_featured boolean, p_badge text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('kiosk.manage') then raise exception 'Butuh izin atur kiosk'; end if;
  update mst_menu_items set kiosk_featured = coalesce(p_featured, false), kiosk_badge = nullif(left(trim(coalesce(p_badge, '')), 16), '')
  where id = p_item_id and company_id = sys_current_company_id();
  if not found then raise exception 'Menu tidak ditemukan'; end if;
end $$;

-- ---------------------------------------------------------------------
-- PUBLIK (perangkat kiosk, tanpa login) - diakses dengan token kiosk
-- ---------------------------------------------------------------------
create or replace function public_kiosk_menu(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_k pos_kiosks; v_o sys_outlets; v_date date;
begin
  select * into v_k from pos_kiosks where token = p_token and is_active;
  if v_k.id is null or coalesce(length(p_token), 0) <> 32 then raise exception 'Kiosk tidak dikenal. Hubungi staf.'; end if;
  select * into v_o from sys_outlets where id = v_k.outlet_id;
  if not v_o.is_active then raise exception 'Outlet sedang tutup.'; end if;
  update pos_kiosks set last_seen_at = now() where id = v_k.id;
  v_date := sys_outlet_business_date(v_o.id);
  return jsonb_build_object(
    'kiosk', jsonb_build_object('name', v_k.name, 'allow_dine_in', v_k.allow_dine_in, 'allow_takeaway', v_k.allow_takeaway,
      'welcome_title', v_k.welcome_title, 'welcome_subtitle', v_k.welcome_subtitle, 'idle_seconds', v_k.idle_seconds, 'print_receipt', v_k.print_receipt),
    'outlet', jsonb_build_object('name', v_o.name, 'tax_rate', v_o.tax_rate, 'service_charge_rate', v_o.service_charge_rate),
    'brand', (select jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url))
              from sys_companies c left join sys_brands b on b.id = v_o.brand_id where c.id = v_o.company_id),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
          'image_url', (select i.image_url from mst_menu_items i where i.menu_category_id = c.id and i.is_active and i.image_url is not null order by i.kiosk_featured desc, i.name limit 1))
        order by c.sort_order, c.name)
      from mst_menu_categories c
      where c.company_id = v_o.company_id and c.brand_id = v_o.brand_id and c.is_active
        and exists (select 1 from mst_menu_items i where i.menu_category_id = c.id and i.is_active)), '[]'::jsonb),
    'items', coalesce((
      with best as (
        select oi.menu_item_id, sum(oi.quantity) as qty from pos_order_items oi join pos_orders po on po.id = oi.order_id
        where po.outlet_id = v_o.id and po.status = 'paid' and po.business_date > v_date - 30 and not oi.is_void
        group by 1 order by 2 desc limit 6
      )
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'description', i.description, 'image_url', i.image_url, 'menu_category_id', i.menu_category_id,
        'price_dine_in', mst_get_menu_price(i.id, v_o.id, 'dine_in'), 'price_takeaway', mst_get_menu_price(i.id, v_o.id, 'takeaway'),
        'featured', i.kiosk_featured, 'badge', i.kiosk_badge, 'best_seller', exists (select 1 from best where best.menu_item_id = i.id),
        'sold_out', exists (select 1 from mst_menu_sold_outs s where s.outlet_id = v_o.id and s.business_date = v_date and s.menu_item_id = i.id),
        'modifier_groups', coalesce((
          select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select,
            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'extra_price', m.extra_price, 'is_default', m.is_default)
              order by m.sort_order) from mst_modifiers m where m.modifier_group_id = g.id), '[]'::jsonb)) order by g.name)
          from mst_menu_item_modifier_groups l join mst_modifier_groups g on g.id = l.modifier_group_id where l.menu_item_id = i.id), '[]'::jsonb))
        order by i.kiosk_featured desc, i.name)
      from mst_menu_items i
      where i.company_id = v_o.company_id and i.brand_id = v_o.brand_id and i.is_active), '[]'::jsonb));
end $$;

-- kirim pesanan kiosk. p: {channel: 'dine_in'|'takeaway', customer_name, items: [{menu_item_id, quantity, note, modifier_ids[]}]}
create or replace function public_kiosk_submit(p_token text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_k pos_kiosks; v_o sys_outlets; v_order pos_orders; v_item jsonb; v_menu mst_menu_items; g record; v_mods uuid[]; v_n int;
  v_channel text := coalesce(p->>'channel', 'dine_in'); v_date date; v_queue text;
begin
  select * into v_k from pos_kiosks where token = p_token and is_active for update;
  if v_k.id is null or coalesce(length(p_token), 0) <> 32 then raise exception 'Kiosk tidak dikenal. Hubungi staf.'; end if;
  select * into v_o from sys_outlets where id = v_k.outlet_id;
  if not v_o.is_active then raise exception 'Outlet sedang tutup.'; end if;
  if v_channel not in ('dine_in', 'takeaway') or (v_channel = 'dine_in' and not v_k.allow_dine_in) or (v_channel = 'takeaway' and not v_k.allow_takeaway) then
    raise exception 'Pilihan makan di sini / bawa pulang tidak tersedia';
  end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'Keranjang masih kosong'; end if;
  if jsonb_array_length(p->'items') > 30 then raise exception 'Terlalu banyak item dalam satu pesanan. Silakan ke kasir.'; end if;
  -- anti-spam: maks 6 pesanan per kiosk per menit
  if (select count(*) from pos_orders where order_source = 'kiosk' and outlet_id = v_o.id and kiosk_id = v_k.id and created_at > now() - interval '1 minute') >= 6 then
    raise exception 'Terlalu banyak pesanan dalam waktu singkat. Silakan tunggu sebentar.';
  end if;
  v_date := sys_outlet_business_date(v_o.id);
  -- validasi tiap item: brand outlet, tidak habis, pilihan sesuai grup & batas min/maks
  for v_item in select * from jsonb_array_elements(p->'items') loop
    select * into v_menu from mst_menu_items where id = (v_item->>'menu_item_id')::uuid and company_id = v_o.company_id and brand_id = v_o.brand_id and is_active;
    if v_menu.id is null then raise exception 'Menu tidak tersedia'; end if;
    if exists (select 1 from mst_menu_sold_outs where outlet_id = v_o.id and business_date = v_date and menu_item_id = v_menu.id) then
      raise exception '% sedang habis', v_menu.name;
    end if;
    select coalesce(array_agg(x::uuid), '{}') into v_mods from jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'::jsonb)) x;
    if exists (select 1 from unnest(v_mods) mid where not exists (
        select 1 from mst_modifiers m join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id
        where m.id = mid and l.menu_item_id = v_menu.id)) then
      raise exception 'Pilihan untuk % tidak valid', v_menu.name;
    end if;
    for g in select mg.* from mst_menu_item_modifier_groups l join mst_modifier_groups mg on mg.id = l.modifier_group_id where l.menu_item_id = v_menu.id loop
      select count(*) into v_n from mst_modifiers m where m.modifier_group_id = g.id and m.id = any(v_mods);
      if v_n < coalesce(g.min_select, 0) or (coalesce(g.max_select, 0) > 0 and v_n > g.max_select) then
        raise exception 'Pilihan "%" untuk % belum sesuai', g.name, v_menu.name;
      end if;
    end loop;
  end loop;

  v_order := pos_create_order_header(v_o.id, null, v_channel, left(nullif(trim(coalesce(p->>'customer_name', '')), ''), 30), 1,
                                     null, null, 'kiosk', null);
  v_queue := 'K' || lpad(sys_next_sequence(v_o.company_id, 'KIOSK/' || v_o.code || '/' || to_char(v_date, 'YYYYMMDD'))::text, 3, '0');
  update pos_orders set queue_number = v_queue, kiosk_id = v_k.id where id = v_order.id;
  -- bayar di kasir: menunggu pembayaran, belum masuk dapur
  perform pos_add_order_items(v_order.id,
    (select jsonb_agg(jsonb_build_object('menu_item_id', x->>'menu_item_id', 'quantity', least(greatest(coalesce((x->>'quantity')::int, 1), 1), 20),
       'note', left(nullif(trim(coalesce(x->>'note', '')), ''), 120), 'modifier_ids', coalesce(x->'modifier_ids', '[]'::jsonb)))
     from jsonb_array_elements(p->'items') x), 'waiting');
  return jsonb_build_object('order_id', v_order.id, 'queue_number', v_queue, 'receipt', pos_receipt_payload(v_order.id));
end $$;
grant execute on function public_kiosk_menu(text) to anon, authenticated;
grant execute on function public_kiosk_submit(text, jsonb) to anon, authenticated;

-- pesanan kiosk otomatis masuk dapur begitu dibayar (pesanan QR meja tetap harus dikonfirmasi dulu)
create or replace function pos_check_unconfirmed_items()
returns trigger language plpgsql as $$
begin
  if new.order_source = 'kiosk' then
    update pos_order_items set kitchen_status = 'pending' where order_id = new.id and kitchen_status = 'waiting' and not is_void;
    return new;
  end if;
  if exists (select 1 from pos_order_items where order_id = new.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi. Konfirmasi atau void dulu sebelum bayar.';
  end if;
  return new;
end $$;

-- daftar kiosk + status online (untuk halaman pengaturan)
create or replace function pos_kiosk_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when sys_has_permission('kiosk.manage') then coalesce((select jsonb_agg(to_jsonb(k) || jsonb_build_object('outlet', o.name,
      'online', k.last_seen_at > now() - interval '15 minutes',
      'orders_today', (select count(*) from pos_orders po where po.kiosk_id = k.id and po.business_date = sys_outlet_business_date(k.outlet_id)))
    order by o.name, k.name)
    from pos_kiosks k join sys_outlets o on o.id = k.outlet_id
    where k.company_id = sys_current_company_id() and sys_can_access_outlet(k.outlet_id)), '[]'::jsonb) else '[]'::jsonb end
$$;

-- struk: sertakan nomor antrean kiosk
create or replace function pos_receipt_payload(p_order_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'queue_number', o.queue_number, 'status', o.status, 'sales_channel', o.sales_channel,
      'order_source', o.order_source, 'customer_name', o.customer_name, 'guest_count', o.guest_count, 'note', o.note,
      'created_at', o.created_at, 'paid_at', o.paid_at, 'table', t.code,
      'subtotal', o.subtotal, 'discount_amount', o.discount_amount, 'promotion_amount', o.promotion_amount, 'promotion', pr.name,
      'points_redeemed', o.points_redeemed, 'points_amount', o.points_amount, 'points_earned', o.points_earned,
      'service_amount', o.service_amount, 'tax_amount', o.tax_amount, 'rounding_amount', o.rounding_amount, 'grand_total', o.grand_total,
      'cashier', (select full_name from sys_users where id = o.created_by)),
    'outlet', jsonb_build_object('name', ol.name, 'address', ol.address, 'phone', ol.phone, 'tax_rate', ol.tax_rate,
      'header', ol.receipt_header, 'footer', ol.receipt_footer, 'show_logo', ol.receipt_show_logo,
      'show_feedback_qr', ol.receipt_show_feedback_qr and coalesce(fs.is_enabled, true)),
    'brand', jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url)),
    'company', jsonb_build_object('name', c.name, 'tax_number', c.tax_number),
    'feedback', jsonb_build_object('title', fs.title, 'incentive', fs.incentive_text),
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.menu_item_name, 'qty', i.quantity, 'unit_price', i.unit_price,
        'line_total', i.line_total, 'note', i.note,
        'modifiers', coalesce((select jsonb_agg(m.modifier_name) from pos_order_item_modifiers m where m.order_item_id = i.id), '[]'::jsonb))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', pm.name, 'amount', p.amount, 'change', p.change_amount) order by p.created_at)
      from pos_payments p join mst_payment_methods pm on pm.id = p.payment_method_id where p.order_id = o.id), '[]'::jsonb),
    'member', case when cu.id is not null then jsonb_build_object('name', cu.name, 'points_balance', cu.points_balance) end)
  from pos_orders o
  join sys_outlets ol on ol.id = o.outlet_id
  join sys_companies c on c.id = o.company_id
  left join sys_brands b on b.id = ol.brand_id
  left join mst_tables t on t.id = o.table_id
  left join crm_promotions pr on pr.id = o.promotion_id
  left join crm_customers cu on cu.id = o.customer_id
  left join crm_feedback_settings fs on fs.company_id = o.company_id
  where o.id = p_order_id
$$;
