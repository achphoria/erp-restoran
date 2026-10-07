-- =====================================================================
-- SANTAP ERP - UPDATE FASE 13 (User staf dibuat owner: username + password)
-- Untuk database yang SUDAH menjalankan fase 1-12.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- Lalu deploy Edge Function "staff-users" (lihat README bagian Fase 13).
-- =====================================================================

-- >>>>>>>>>> migrations/023_staff_users.sql
-- =====================================================================
-- SANTAP ERP - 023: USER STAF DIBUAT OWNER (TANPA DAFTAR SENDIRI)
--   * Owner daftar sendiri dengan email (seperti biasa)
--   * Staf dibuat owner/admin di Pengaturan -> User: nama, USERNAME, password, role, outlet
--   * Akun login staf dibuat Edge Function "staff-users" (auth admin API) dengan
--     email sintetis <username>@staff.santap.local -> staf login cukup pakai username
--   * Fungsi di bawah dipanggil Edge Function: prepare/check (sebagai user yang login),
--     register (service role)
-- =====================================================================

alter table sys_users add column username   text;
alter table sys_users add column created_by uuid references sys_users(id);
alter table sys_users add constraint sys_users_username_check check (username is null or username ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
create unique index uq_sys_users_username on sys_users(lower(username)) where username is not null;

create or replace function sys_staff_email(p_username text)
returns text language sql immutable as $$
  select lower(trim(p_username)) || '@staff.santap.local'
$$;

-- Validasi sebelum akun login dibuat (dipanggil dengan JWT pengelola user)
create or replace function sys_prepare_staff_user(p_username text, p_full_name text, p_role_id uuid, p_outlet_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_username text := lower(trim(coalesce(p_username, '')));
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then
    raise exception 'Username 3-32 karakter: huruf kecil, angka, titik, minus atau garis bawah (tanpa spasi)';
  end if;
  if exists (select 1 from sys_users where lower(username) = v_username)
     or exists (select 1 from auth.users where lower(email) = sys_staff_email(v_username)) then
    raise exception 'Username "%" sudah dipakai', v_username;
  end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then raise exception 'Role tidak valid'; end if;
  if (select permissions ? '*' from sys_roles where id = p_role_id) then
    raise exception 'Role Owner tidak bisa diberikan ke user staf (owner mendaftar sendiri dengan email)';
  end if;
  if coalesce(array_length(p_outlet_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 outlet'; end if;

  return jsonb_build_object('company_id', v_company, 'username', v_username, 'email', sys_staff_email(v_username), 'caller_id', auth.uid());
end $$;

-- Simpan user staf setelah akun login dibuat (hanya service role / Edge Function)
create or replace function sys_register_staff_user(
  p_user_id uuid, p_company_id uuid, p_username text, p_full_name text, p_role_id uuid, p_outlet_ids uuid[], p_created_by uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = p_company_id and not permissions ? '*') then
    raise exception 'Role tidak valid';
  end if;
  insert into sys_users (id, company_id, role_id, full_name, username, created_by)
  values (p_user_id, p_company_id, p_role_id, trim(p_full_name), lower(trim(p_username)), p_created_by);
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o where o.company_id = p_company_id and o.id = any(p_outlet_ids);
  perform sys_log_activity(p_company_id, 'create_user', 'sys_users', p_user_id, trim(p_full_name) || ' (' || lower(trim(p_username)) || ')', null);
end $$;

-- Boleh reset password user ini? (dipanggil dengan JWT pengelola user)
create or replace function sys_check_staff_reset(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u sys_users%rowtype;
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  select * into u from sys_users where id = p_user_id and company_id = sys_current_company_id();
  if not found then raise exception 'User tidak ditemukan'; end if;
  if u.username is null then raise exception 'User ini login dengan email: reset password lewat menu "Lupa password" / profil masing-masing'; end if;
  return jsonb_build_object('user_id', u.id, 'username', u.username);
end $$;

-- Daftar user: tampilkan username staf, sembunyikan email sintetis
create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'username', u.username,
           'email', case when u.username is null then au.email end, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

revoke execute on function sys_register_staff_user(uuid, uuid, text, text, uuid, uuid[], uuid) from public, anon, authenticated;
grant execute on function sys_register_staff_user(uuid, uuid, text, text, uuid, uuid[], uuid) to service_role;
