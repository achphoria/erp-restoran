-- =====================================================================
-- SANTAP ERP - 027: PLATFORM ADMIN, GRUP USAHA (MULTI PT), BRAND
--   Tingkat:  Platform Admin (developer)  >  Grup usaha  >  PT (perusahaan)  >  Brand  >  Outlet
--   * Platform Admin: HANYA bisa diberikan lewat SQL Editor (tabel sys_platform_admins).
--     Bisa melihat semua perusahaan, memetakan PT ke grup, menonaktifkan PT,
--     dan MASUK ke PT mana pun (mode support = akses penuh, semua aksi dicatat).
--   * Grup usaha: beberapa PT dikelompokkan (mapping, bukan merge). Pemilik grup bisa
--     pindah antar PT di grupnya dengan akses penuh (seperti owner PT tersebut).
--   * PT tetap terpisah total untuk owner/staf biasa.
--   * Brand: outlet masuk ke brand; akses user bisa per brand (termasuk outlet baru brand itu).
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABEL
-- ---------------------------------------------------------------------
create table sys_platform_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  note        text,
  created_at  timestamptz not null default now()
);
alter table sys_platform_admins enable row level security;     -- tanpa policy: hanya lewat fungsi

create table sys_company_groups (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table sys_company_groups enable row level security;

alter table sys_companies add column group_id uuid references sys_company_groups(id) on delete set null;

create table sys_group_members (
  group_id    uuid not null references sys_company_groups(id) on delete cascade,
  user_id     uuid not null references sys_users(id) on delete cascade,
  role        text not null default 'owner' check (role in ('owner')),
  created_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table sys_group_members enable row level security;

-- PT yang sedang "dimasuki" user (pindah PT grup / mode support)
create table sys_user_context (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  acting_company_id  uuid not null references sys_companies(id) on delete cascade,
  mode               text not null check (mode in ('group', 'support')),
  started_at         timestamptz not null default now()
);
alter table sys_user_context enable row level security;

-- akses per brand
alter table sys_users drop constraint sys_users_outlet_scope_check;
alter table sys_users add constraint sys_users_outlet_scope_check check (outlet_scope in ('all', 'selected', 'brands'));
create table sys_user_brands (
  user_id   uuid not null references sys_users(id) on delete cascade,
  brand_id  uuid not null references sys_brands(id) on delete cascade,
  primary key (user_id, brand_id)
);
alter table sys_user_brands enable row level security;
create policy sys_user_brands_select on sys_user_brands for select to authenticated
  using (user_id in (select id from sys_users where company_id = sys_current_company_id()));

-- ---------------------------------------------------------------------
-- IDENTITAS & PERUSAHAAN AKTIF
-- ---------------------------------------------------------------------
create or replace function sys_is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from sys_platform_admins where user_id = auth.uid())
$$;

-- perusahaan "rumah" user (PT aktif & user aktif)
create or replace function sys_home_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select u.company_id from sys_users u join sys_companies c on c.id = u.company_id
  where u.id = auth.uid() and u.is_active and c.is_active
$$;

-- PT yang sedang dimasuki (null = di PT sendiri); dicek ulang setiap kali dipakai
create or replace function sys_acting_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select x.acting_company_id from sys_user_context x
  where x.user_id = auth.uid()
    and ((x.mode = 'support' and exists (select 1 from sys_platform_admins where user_id = auth.uid()))
      or (x.mode = 'group' and exists (
            select 1 from sys_companies c join sys_group_members m on m.group_id = c.group_id
            join sys_users u on u.id = m.user_id and u.is_active
            where c.id = x.acting_company_id and c.is_active and m.user_id = auth.uid())))
$$;

create or replace function sys_acting_mode()
returns text language sql stable security definer set search_path = public as $$
  select case when sys_acting_company_id() is null then null
              else (select mode from sys_user_context where user_id = auth.uid()) end
$$;

create or replace function sys_current_company_id()
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(sys_acting_company_id(), sys_home_company_id())
$$;

-- di PT yang dimasuki (grup / support) = akses penuh seperti owner
create or replace function sys_has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select case when sys_acting_company_id() is not null then true else coalesce((
    select r.permissions ? '*' or r.permissions ? p_permission
    from sys_users u join sys_roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active
  ), false) end
  or coalesce(p_permission = any(string_to_array(nullif(current_setting('erp.acting_for', true), ''), ',')), false)
$$;

-- akses outlet: semua / branch tertentu / brand tertentu
create or replace function sys_user_all_outlets()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('*') or coalesce((select outlet_scope = 'all' from sys_users where id = auth.uid() and is_active), false)
$$;

create or replace function sys_can_access_outlet(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (sys_user_all_outlets() and exists (
            select 1 from sys_outlets where id = p_outlet_id and company_id = sys_current_company_id()))
      or (sys_acting_company_id() is null and (
            exists (select 1 from sys_user_outlets where user_id = auth.uid() and outlet_id = p_outlet_id)
         or exists (select 1 from sys_outlets o join sys_user_brands ub on ub.brand_id = o.brand_id
                    join sys_users u on u.id = ub.user_id and u.outlet_scope = 'brands'
                    where o.id = p_outlet_id and ub.user_id = auth.uid())))
$$;

-- nama pelaku di log: tandai mode support / pemilik grup
create or replace function sys_actor_label()
returns text language sql stable security definer set search_path = public as $$
  select (select full_name from sys_users where id = auth.uid())
      || case sys_acting_mode() when 'support' then ' (Platform support)' when 'group' then ' (Pemilik grup)' else '' end
$$;

create or replace function sys_log_activity(
  p_company_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_label text, p_changes jsonb default null
)
returns void language sql security definer set search_path = public as $$
  insert into sys_activity_logs (company_id, user_id, user_name, action, entity_type, entity_id, entity_label, changes)
  values (p_company_id, auth.uid(), sys_actor_label(), p_action, p_entity_type, p_entity_id, left(p_label, 200), p_changes)
$$;

-- ---------------------------------------------------------------------
-- PROFIL: PT aktif, mode, daftar PT yang bisa dipindah
-- ---------------------------------------------------------------------
create or replace function sys_get_my_profile()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  u      sys_users%rowtype;
  r      sys_roles%rowtype;
  c      sys_companies%rowtype;
  v_home uuid := sys_home_company_id();
  v_act  uuid := sys_acting_company_id();
  v_mode text := sys_acting_mode();
begin
  select * into u from sys_users where id = auth.uid() and is_active;
  if not found or (v_home is null and v_act is null) then return null; end if;
  select * into c from sys_companies where id = coalesce(v_act, v_home);
  select * into r from sys_roles where id = u.role_id;

  return jsonb_build_object(
    'user_id', u.id, 'full_name', u.full_name, 'phone', u.phone, 'avatar_url', u.avatar_url,
    'email', (select email from auth.users where id = u.id),
    'company_id', c.id, 'company_name', c.name, 'company_app_name', c.app_name, 'company_logo_url', c.logo_url,
    'role_code', case when v_act is not null then 'owner' else r.code end,
    'role_name', case v_mode when 'support' then 'Platform support' when 'group' then 'Pemilik grup' else r.name end,
    'permissions', case when v_act is not null then '["*"]'::jsonb else r.permissions end,
    'outlet_scope', case when v_act is not null or r.permissions ? '*' then 'all' else u.outlet_scope end,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name, 'brand_id', o.brand_id) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (v_act is not null or r.permissions ? '*' or u.outlet_scope = 'all'
             or exists (select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id)
             or (u.outlet_scope = 'brands' and exists (select 1 from sys_user_brands ub where ub.user_id = u.id and ub.brand_id = o.brand_id)))
    ), '[]'::jsonb),
    'is_platform_admin', sys_is_platform_admin(),
    'acting_mode', v_mode,
    'home_company_id', u.company_id,
    'home_company_name', (select name from sys_companies where id = u.company_id),
    'group_name', (select name from sys_company_groups where id = c.group_id),
    -- PT yang bisa dipindah: PT sendiri + PT di grup yang dia miliki
    'companies', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'group_name', g.name) order by x.name)
      from sys_companies x left join sys_company_groups g on g.id = x.group_id
      where x.is_active and (x.id = u.company_id or exists (
        select 1 from sys_group_members m where m.user_id = u.id and m.group_id = x.group_id))
    ), '[]'::jsonb)
  );
end $$;

-- Pindah PT. null / PT sendiri = kembali ke PT sendiri
create or replace function sys_switch_company(p_company_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_home uuid := (select company_id from sys_users where id = auth.uid() and is_active);
  v_mode text;
begin
  if v_home is null then raise exception 'Akun tidak aktif'; end if;
  if p_company_id is null or p_company_id = v_home then
    delete from sys_user_context where user_id = auth.uid();
    return jsonb_build_object('company_id', v_home, 'mode', null);
  end if;
  if not exists (select 1 from sys_companies where id = p_company_id) then raise exception 'Perusahaan tidak ditemukan'; end if;

  if exists (select 1 from sys_companies c join sys_group_members m on m.group_id = c.group_id
             where c.id = p_company_id and c.is_active and m.user_id = auth.uid()) then
    v_mode := 'group';
  elsif sys_is_platform_admin() then
    v_mode := 'support';
  else
    raise exception 'Anda tidak punya akses ke perusahaan ini';
  end if;

  insert into sys_user_context (user_id, acting_company_id, mode) values (auth.uid(), p_company_id, v_mode)
  on conflict (user_id) do update set acting_company_id = excluded.acting_company_id, mode = excluded.mode, started_at = now();
  perform sys_log_activity(p_company_id, case v_mode when 'support' then 'support_enter' else 'switch_company' end,
    'sys_companies', p_company_id, (select name from sys_companies where id = p_company_id), null);
  return jsonb_build_object('company_id', p_company_id, 'mode', v_mode);
end $$;

-- ---------------------------------------------------------------------
-- CONSOLE PLATFORM (khusus Platform Admin)
-- ---------------------------------------------------------------------
create or replace function sys_platform_check()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_is_platform_admin() then raise exception 'Khusus Platform Admin'; end if;
end $$;

create or replace function sys_platform_companies()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name, 'is_active', c.is_active, 'created_at', c.created_at,
      'group_id', c.group_id, 'group_name', g.name,
      'users', (select count(*) from sys_users u where u.company_id = c.id),
      'outlets', (select count(*) from sys_outlets o where o.company_id = c.id),
      'brands', (select count(*) from sys_brands b where b.company_id = c.id),
      'owners', (select string_agg(coalesce(au.email, u.full_name), ', ') from sys_users u join sys_roles r on r.id = u.role_id
                 left join auth.users au on au.id = u.id where u.company_id = c.id and r.permissions ? '*'),
      'orders_30d', (select count(*) from pos_orders po where po.company_id = c.id and po.status = 'paid' and po.business_date >= current_date - 30),
      'last_activity', (select max(l.created_at) from sys_activity_logs l where l.company_id = c.id)
    ) order by c.created_at desc)
    from sys_companies c left join sys_company_groups g on g.id = c.group_id), '[]'::jsonb);
end $$;

create or replace function sys_platform_groups()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'code', g.code, 'name', g.name,
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from sys_companies c where c.group_id = g.id), '[]'),
      'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'full_name', u.full_name, 'email', au.email,
                             'home_company', hc.name) order by u.full_name)
                           from sys_group_members m join sys_users u on u.id = m.user_id
                           join sys_companies hc on hc.id = u.company_id left join auth.users au on au.id = u.id
                           where m.group_id = g.id), '[]')
    ) order by g.name)
    from sys_company_groups g), '[]'::jsonb);
end $$;

create or replace function sys_platform_save_group(p_id uuid, p_code text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform sys_platform_check();
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_code), '') = '' then raise exception 'Kode & nama grup wajib diisi'; end if;
  if p_id is null then
    insert into sys_company_groups (code, name) values (upper(trim(p_code)), trim(p_name)) returning id into v_id;
  else
    update sys_company_groups set code = upper(trim(p_code)), name = trim(p_name) where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;

-- mapping PT ke grup (null = keluarkan dari grup)
create or replace function sys_platform_set_company_group(p_company_id uuid, p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  update sys_companies set group_id = p_group_id where id = p_company_id;
  perform sys_log_activity(p_company_id, 'map_group', 'sys_companies', p_company_id,
    coalesce('Masuk grup ' || (select name from sys_company_groups where id = p_group_id), 'Keluar dari grup'), null);
end $$;

create or replace function sys_platform_add_group_member(p_group_id uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform sys_platform_check();
  select u.id into v_user from sys_users u join auth.users au on au.id = u.id
  where lower(au.email) = lower(trim(p_email)) or lower(u.username) = lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'User "%" belum terdaftar di perusahaan mana pun', p_email; end if;
  insert into sys_group_members (group_id, user_id) values (p_group_id, v_user) on conflict do nothing;
end $$;

create or replace function sys_platform_remove_group_member(p_group_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  delete from sys_group_members where group_id = p_group_id and user_id = p_user_id;
  delete from sys_user_context where user_id = p_user_id and mode = 'group';
end $$;

create or replace function sys_platform_set_company_active(p_company_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  if not p_active and p_company_id = (select company_id from sys_users where id = auth.uid()) then
    raise exception 'Tidak bisa menonaktifkan perusahaan Anda sendiri';
  end if;
  update sys_companies set is_active = p_active where id = p_company_id;
  perform sys_log_activity(p_company_id, case when p_active then 'activate' else 'suspend' end, 'sys_companies', p_company_id,
    case when p_active then 'Perusahaan diaktifkan' else 'Perusahaan dinonaktifkan oleh platform' end, null);
end $$;

-- ---------------------------------------------------------------------
-- BRAND: outlet baru bisa memilih brand; akses user per brand
-- ---------------------------------------------------------------------
drop function sys_create_outlet(text, text, text);
create or replace function sys_create_outlet(p_code text, p_name text, p_address text default null, p_brand_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_outlet  sys_outlets%rowtype;
  v_wh      uuid;
  v_brand   uuid;
begin
  if not sys_has_permission('settings.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then
    raise exception 'Kode dan nama outlet wajib diisi';
  end if;
  v_brand := coalesce((select id from sys_brands where id = p_brand_id and company_id = v_company),
                      (select id from sys_brands where company_id = v_company order by created_at limit 1));

  insert into sys_outlets (company_id, brand_id, code, name, address)
  values (v_company, v_brand, upper(trim(p_code)), trim(p_name), p_address)
  returning * into v_outlet;

  insert into inv_warehouses (company_id, outlet_id, code, name)
  values (v_company, v_outlet.id, 'WH-' || v_outlet.code, 'Gudang ' || v_outlet.name)
  returning id into v_wh;

  update sys_outlets set default_warehouse_id = v_wh where id = v_outlet.id;
  if exists (select 1 from sys_users where id = auth.uid() and company_id = v_company) then
    insert into sys_user_outlets (user_id, outlet_id) values (auth.uid(), v_outlet.id) on conflict do nothing;
  end if;
  return to_jsonb(v_outlet);
end $$;

drop function sys_set_user_access(uuid, uuid, text, uuid[], boolean);
create or replace function sys_set_user_access(
  p_user_id uuid, p_role_id uuid, p_outlet_scope text, p_outlet_ids uuid[], p_is_active boolean default true, p_brand_ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if p_user_id = auth.uid() then raise exception 'Tidak bisa mengubah akun sendiri'; end if;
  if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then raise exception 'User tidak ditemukan'; end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then raise exception 'Role tidak valid'; end if;
  if p_outlet_scope not in ('all', 'selected', 'brands') then raise exception 'Cakupan akses tidak valid'; end if;
  if p_outlet_scope = 'selected' and coalesce(array_length(p_outlet_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 branch'; end if;
  if p_outlet_scope = 'brands' and coalesce(array_length(p_brand_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 brand'; end if;

  update sys_users set role_id = p_role_id, is_active = coalesce(p_is_active, true), outlet_scope = p_outlet_scope where id = p_user_id;
  delete from sys_user_outlets where user_id = p_user_id;
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o
  where o.company_id = v_company and (p_outlet_scope = 'all' or (p_outlet_scope = 'selected' and o.id = any(p_outlet_ids))
                                      or (p_outlet_scope = 'brands' and o.brand_id = any(p_brand_ids)));
  delete from sys_user_brands where user_id = p_user_id;
  if p_outlet_scope = 'brands' then
    insert into sys_user_brands (user_id, brand_id)
    select p_user_id, b.id from sys_brands b where b.company_id = v_company and b.id = any(p_brand_ids);
  end if;
  perform sys_log_activity(v_company, 'update_user_access', 'sys_users', p_user_id,
    (select full_name from sys_users where id = p_user_id) || case p_outlet_scope when 'all' then ' (semua branch)'
      when 'brands' then ' (' || coalesce(array_length(p_brand_ids, 1), 0) || ' brand)'
      else ' (' || coalesce(array_length(p_outlet_ids, 1), 0) || ' branch)' end, null);
end $$;

create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'username', u.username,
           'email', case when u.username is null then au.email end, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_scope', case when r.permissions ? '*' then 'all' else u.outlet_scope end,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'brand_ids', coalesce((select jsonb_agg(ub.brand_id) from sys_user_brands ub where ub.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

create trigger trg_sys_brands_audit after insert or update or delete on sys_brands
  for each row execute function sys_audit_trigger('');

revoke execute on function sys_platform_check() from public, anon, authenticated;
