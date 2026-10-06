-- =====================================================================
-- ERP RESTORAN - 006: USER, UNDANGAN, OUTLET
--   Alur: owner mengundang email + role + outlet -> staf daftar akun
--         dengan email tsb -> di halaman awal muncul undangan -> terima.
-- =====================================================================

create table sys_user_invitations (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  email        text not null check (email = lower(trim(email))),
  role_id      uuid not null references sys_roles(id),
  outlet_ids   uuid[] not null default '{}',
  status       text not null default 'pending',   -- pending / accepted / cancelled
  invited_by   uuid references sys_users(id),
  accepted_by  uuid references sys_users(id),
  accepted_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create unique index uq_sys_user_invitations_pending
  on sys_user_invitations(company_id, email) where status = 'pending';

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('sys_user_invitations', 'user.manage');

-- Email user yang sedang login
create or replace function sys_current_user_email()
returns text language sql stable security definer set search_path = public as $$
  select lower(email) from auth.users where id = auth.uid()
$$;

-- Undangan untuk email saya (dipanggil di halaman onboarding)
create or replace function sys_get_my_invitations()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'company_name', c.name, 'role_name', r.name, 'created_at', i.created_at)
         order by i.created_at desc), '[]'::jsonb)
  from sys_user_invitations i
  join sys_companies c on c.id = i.company_id
  join sys_roles r on r.id = i.role_id
  where i.status = 'pending' and i.email = sys_current_user_email()
$$;

create or replace function sys_accept_invitation(p_invitation_id uuid, p_full_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v_inv sys_user_invitations%rowtype;
begin
  if auth.uid() is null then raise exception 'Anda belum login'; end if;
  if exists (select 1 from sys_users where id = auth.uid()) then
    raise exception 'Akun ini sudah terdaftar di sebuah perusahaan';
  end if;

  select * into v_inv from sys_user_invitations
  where id = p_invitation_id and status = 'pending' and email = sys_current_user_email()
  for update;
  if not found then raise exception 'Undangan tidak ditemukan atau sudah tidak berlaku'; end if;

  insert into sys_users (id, company_id, role_id, full_name)
  values (auth.uid(), v_inv.company_id, v_inv.role_id, coalesce(nullif(trim(p_full_name), ''), split_part(v_inv.email, '@', 1)));

  insert into sys_user_outlets (user_id, outlet_id)
  select auth.uid(), o.id from sys_outlets o
  where o.company_id = v_inv.company_id and o.id = any(v_inv.outlet_ids);

  update sys_user_invitations
     set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
   where id = v_inv.id;
end $$;

-- Daftar user + email (email ada di auth.users, tidak bisa dibaca langsung dari aplikasi)
create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'email', au.email, 'is_active', u.is_active,
           'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

-- Ubah role, outlet, status aktif user lain
create or replace function sys_update_user(p_user_id uuid, p_role_id uuid, p_outlet_ids uuid[], p_is_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if p_user_id = auth.uid() then raise exception 'Tidak bisa mengubah akun sendiri'; end if;
  if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then
    raise exception 'User tidak ditemukan';
  end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then
    raise exception 'Role tidak valid';
  end if;

  update sys_users set role_id = p_role_id, is_active = p_is_active where id = p_user_id;
  delete from sys_user_outlets where user_id = p_user_id;
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o where o.company_id = v_company and o.id = any(p_outlet_ids);
end $$;

-- Tambah outlet baru beserta gudangnya
create or replace function sys_create_outlet(p_code text, p_name text, p_address text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_outlet  sys_outlets%rowtype;
  v_wh      uuid;
begin
  if not sys_has_permission('settings.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then
    raise exception 'Kode dan nama outlet wajib diisi';
  end if;

  insert into sys_outlets (company_id, brand_id, code, name, address)
  values (v_company, (select id from sys_brands where company_id = v_company order by created_at limit 1),
          upper(trim(p_code)), trim(p_name), p_address)
  returning * into v_outlet;

  insert into inv_warehouses (company_id, outlet_id, code, name)
  values (v_company, v_outlet.id, 'WH-' || v_outlet.code, 'Gudang ' || v_outlet.name)
  returning id into v_wh;

  update sys_outlets set default_warehouse_id = v_wh where id = v_outlet.id;
  insert into sys_user_outlets (user_id, outlet_id) values (auth.uid(), v_outlet.id) on conflict do nothing;

  return to_jsonb(v_outlet);
end $$;

revoke execute on function sys_current_user_email() from public, anon, authenticated;
