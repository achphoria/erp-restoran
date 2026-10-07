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
