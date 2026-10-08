-- =====================================================================
-- SANTAP ERP - UPDATE FASE 18 (Pendaftar baru di Console Platform)
-- Untuk database yang SUDAH menjalankan fase 1-17.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/028_platform_signups.sql
-- =====================================================================
-- SANTAP ERP - 028: PENDAFTAR BARU DI CONSOLE PLATFORM
--   * Daftar semua akun yang mendaftar sendiri (email), termasuk yang belum
--     menyelesaikan setup usaha. Staf yang dibuat owner (username) tidak ikut.
--   * Badge jumlah pendaftar baru sejak terakhir tab Pendaftar dibuka.
-- =====================================================================

alter table sys_platform_admins add column signups_seen_at timestamptz;

-- akun yang mendaftar sendiri (bukan staf username buatan owner)
create or replace function sys_platform_signup_users()
returns table (user_id uuid, email text, created_at timestamptz, email_confirmed_at timestamptz, last_sign_in_at timestamptz)
language sql stable security definer set search_path = public as $$
  select au.id, au.email::text, au.created_at, au.email_confirmed_at, au.last_sign_in_at
  from auth.users au
  where coalesce(au.email, '') not like '%@staff.santap.local'
    and not exists (select 1 from sys_users u where u.id = au.id and u.username is not null)
$$;

create or replace function sys_platform_signups()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', s.user_id, 'email', s.email, 'created_at', s.created_at,
      'email_confirmed_at', s.email_confirmed_at, 'last_sign_in_at', s.last_sign_in_at,
      'full_name', u.full_name, 'company_id', c.id, 'company_name', c.name, 'company_active', c.is_active, 'role_name', r.name,
      -- pending = belum buat PT / belum gabung; owner = pemilik PT; staff = gabung lewat undangan email
      'status', case when u.id is null then 'pending' when r.permissions ? '*' then 'owner' else 'staff' end,
      'is_new', s.created_at > coalesce((select signups_seen_at from sys_platform_admins where user_id = auth.uid()), now() - interval '7 days')
    ) order by s.created_at desc)
    from sys_platform_signup_users() s
    left join sys_users u on u.id = s.user_id
    left join sys_companies c on c.id = u.company_id
    left join sys_roles r on r.id = u.role_id), '[]'::jsonb);
end $$;

-- jumlah pendaftar baru sejak tab Pendaftar terakhir dibuka (pertama kali: 7 hari terakhir)
create or replace function sys_platform_new_signups()
returns integer language sql stable security definer set search_path = public as $$
  select case when not sys_is_platform_admin() then 0 else (
    select count(*)::int from sys_platform_signup_users() s
    where s.created_at > coalesce((select signups_seen_at from sys_platform_admins where user_id = auth.uid()), now() - interval '7 days')
  ) end
$$;

create or replace function sys_platform_mark_signups_seen()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform sys_platform_check();
  update sys_platform_admins set signups_seen_at = now() where user_id = auth.uid();
end $$;

-- daftar perusahaan: tandai PT yang baru dibuat 7 hari terakhir
create or replace function sys_platform_companies()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform sys_platform_check();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'code', c.code, 'name', c.name, 'is_active', c.is_active, 'created_at', c.created_at,
      'is_new', c.created_at > now() - interval '7 days',
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

revoke execute on function sys_platform_signup_users() from public, anon, authenticated;
