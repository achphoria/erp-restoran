-- =====================================================================
-- SANTAP ERP - UPDATE FASE 23 (SDM / HR: data karyawan & pengumuman)
-- Untuk database yang SUDAH menjalankan fase 1-22.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/033_hr_employees.sql
-- =====================================================================
-- SANTAP ERP - 033: SDM / HR FASE A - DATA KARYAWAN, STRUKTUR, PENGUMUMAN
--   * hr_departments, hr_positions: struktur organisasi (jabatan bisa punya role default).
--   * hr_employees: biodata lengkap karyawan; bisa ditautkan ke akun login (sys_users) 1:1.
--     Data sensitif (KTP, NPWP, BPJS, alamat) hanya terbaca oleh hr.view / hr.manage
--     dan oleh karyawan itu sendiri. Rekan kerja hanya melihat direktori (nama, jabatan, outlet).
--   * hr_employee_documents + bucket privat 'hr-files' (scan KTP, kontrak, sertifikat, foto).
--   * hr_announcements: pengumuman untuk semua / per outlet / per role, dengan tanda sudah dibaca.
--   Izin baru: hr.view (lihat data karyawan), hr.manage (kelola karyawan, struktur, pengumuman).
-- =====================================================================

create table hr_departments (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  code        text not null,
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, code)
);
select sys_apply_company_policies('hr_departments', 'hr.manage');

create table hr_positions (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  department_id    uuid references hr_departments(id) on delete set null,
  code             text not null,
  name             text not null,
  default_role_id  uuid references sys_roles(id) on delete set null,   -- role saat dibuatkan akun login
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, code)
);
select sys_apply_company_policies('hr_positions', 'hr.manage');

create table hr_employees (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references sys_companies(id),
  employee_number       text,                                   -- otomatis EMP-0001
  user_id               uuid unique references sys_users(id) on delete set null,
  -- pribadi
  full_name             text not null check (trim(full_name) <> ''),
  nickname              text,
  photo_path            text,                                   -- di bucket hr-files
  gender                text check (gender in ('L', 'P')),
  birth_place           text,
  birth_date            date,
  religion              text,
  marital_status        text check (marital_status in ('single', 'married', 'divorced', 'widowed')),
  blood_type            text,
  -- identitas (sensitif)
  national_id           text,                                   -- No. KTP
  tax_number            text,                                   -- NPWP
  bpjs_kesehatan        text,
  bpjs_ketenagakerjaan  text,
  -- kontak
  phone                 text,
  email                 text,
  address_ktp           text,
  address_domicile      text,
  emergency_name        text,
  emergency_relation    text,
  emergency_phone       text,
  -- pekerjaan
  department_id         uuid references hr_departments(id) on delete set null,
  position_id           uuid references hr_positions(id) on delete set null,
  outlet_id             uuid references sys_outlets(id) on delete set null,
  manager_id            uuid references hr_employees(id) on delete set null,
  employment_status     text not null default 'permanent' check (employment_status in ('permanent', 'contract', 'probation', 'intern', 'daily')),
  join_date             date,
  contract_end_date     date,
  resign_date           date,
  is_active             boolean not null default true,
  -- riwayat
  education             jsonb not null default '[]',           -- [{level, school, major, year}]
  experience            jsonb not null default '[]',           -- [{company, position, from, to}]
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, employee_number),
  check (contract_end_date is null or join_date is null or contract_end_date >= join_date)
);
alter table hr_employees enable row level security;
create policy hr_employees_select on hr_employees for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('hr.view') or sys_has_permission('hr.manage') or user_id = auth.uid()));
create policy hr_employees_insert on hr_employees for insert to authenticated
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
create policy hr_employees_update on hr_employees for update to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage')) with check (company_id = sys_current_company_id());
create policy hr_employees_delete on hr_employees for delete to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
-- HR dengan akses branch tertentu hanya mengelola karyawan branch-nya
select sys_apply_outlet_lock('hr_employees', 'user_id = auth.uid() or outlet_id is null or sys_can_access_outlet(outlet_id)');

-- nomor karyawan otomatis
create or replace function hr_set_employee_number()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(new.employee_number), '') = '' then
    new.employee_number := 'EMP-' || lpad(sys_next_sequence(new.company_id, 'EMP')::text, 4, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_hr_employees_number before insert or update on hr_employees
  for each row execute function hr_set_employee_number();
-- audit tanpa menyalin data sensitif ke log aktivitas
create trigger trg_hr_employees_audit after insert or update or delete on hr_employees
  for each row execute function sys_audit_trigger('national_id,tax_number,bpjs_kesehatan,bpjs_ketenagakerjaan,address_ktp,birth_date');
create trigger trg_hr_departments_audit after insert or update or delete on hr_departments for each row execute function sys_audit_trigger('');
create trigger trg_hr_positions_audit after insert or update or delete on hr_positions for each row execute function sys_audit_trigger('');

create table hr_employee_documents (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  employee_id  uuid not null references hr_employees(id) on delete cascade,
  doc_type     text not null default 'lainnya',    -- ktp / kontrak / sertifikat / ijazah / lainnya
  name         text not null,
  file_path    text not null,                       -- hr-files/<company>/<employee>/<file>
  expiry_date  date,
  created_by   uuid references sys_users(id),
  created_at   timestamptz not null default now()
);
alter table hr_employee_documents enable row level security;
create policy hr_employee_documents_select on hr_employee_documents for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
create policy hr_employee_documents_write on hr_employee_documents for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));

-- ---------------------------------------------------------------------
-- STORAGE PRIVAT: hr-files/<company_id>/<employee_id>/<file>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hr-files', 'hr-files', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create or replace function hr_can_read_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
          or exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid()))
$$;
create or replace function hr_can_write_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text and sys_has_permission('hr.manage')
$$;
create policy hr_files_select on storage.objects for select to authenticated using (bucket_id = 'hr-files' and hr_can_read_file(name));
create policy hr_files_insert on storage.objects for insert to authenticated with check (bucket_id = 'hr-files' and hr_can_write_file(name));
create policy hr_files_update on storage.objects for update to authenticated using (bucket_id = 'hr-files' and hr_can_write_file(name));
create policy hr_files_delete on storage.objects for delete to authenticated using (bucket_id = 'hr-files' and hr_can_write_file(name));

-- ---------------------------------------------------------------------
-- DIREKTORI & PROFIL SAYA
-- ---------------------------------------------------------------------
-- direktori karyawan (tanpa data sensitif), untuk semua user di perusahaan
create or replace function hr_directory()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name, 'nickname', e.nickname,
    'photo_path', e.photo_path, 'position', p.name, 'department', d.name, 'outlet', o.name, 'phone', e.phone,
    'has_account', e.user_id is not null) order by e.full_name), '[]'::jsonb)
  from hr_employees e
  left join hr_positions p on p.id = e.position_id
  left join hr_departments d on d.id = e.department_id
  left join sys_outlets o on o.id = e.outlet_id
  where e.company_id = sys_current_company_id() and e.is_active and sys_current_company_id() is not null
$$;

-- data karyawan milik user yang login
create or replace function hr_my_employee()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(e) || jsonb_build_object('position', p.name, 'department', d.name, 'outlet', o.name, 'manager', m.full_name)
  from hr_employees e
  left join hr_positions p on p.id = e.position_id
  left join hr_departments d on d.id = e.department_id
  left join sys_outlets o on o.id = e.outlet_id
  left join hr_employees m on m.id = e.manager_id
  where e.user_id = auth.uid() and e.company_id = sys_current_company_id()
$$;

-- karyawan boleh mengubah sebagian datanya sendiri
create or replace function hr_update_my_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  update hr_employees set
    nickname = coalesce(p->>'nickname', nickname),
    phone = coalesce(p->>'phone', phone),
    email = coalesce(p->>'email', email),
    address_domicile = coalesce(p->>'address_domicile', address_domicile),
    emergency_name = coalesce(p->>'emergency_name', emergency_name),
    emergency_relation = coalesce(p->>'emergency_relation', emergency_relation),
    emergency_phone = coalesce(p->>'emergency_phone', emergency_phone)
  where user_id = auth.uid() and company_id = sys_current_company_id()
  returning id into v_id;
  if v_id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  return hr_my_employee();
end $$;

-- tautkan / lepas akun login dari data karyawan
create or replace function hr_link_user(p_employee_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (sys_has_permission('hr.manage') and sys_has_permission('user.manage')) then raise exception 'Butuh izin kelola karyawan & user'; end if;
  if not exists (select 1 from hr_employees where id = p_employee_id and company_id = v_company) then raise exception 'Karyawan tidak ditemukan'; end if;
  if p_user_id is not null then
    if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then raise exception 'User tidak ditemukan'; end if;
    if exists (select 1 from hr_employees where user_id = p_user_id and id <> p_employee_id) then raise exception 'Akun ini sudah tertaut ke karyawan lain'; end if;
  end if;
  update hr_employees set user_id = p_user_id where id = p_employee_id;
end $$;

-- pengingat HR: kontrak hampir habis & ulang tahun bulan ini
create or replace function hr_reminders()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not (sys_has_permission('hr.view') or sys_has_permission('hr.manage')) then '{}'::jsonb else jsonb_build_object(
    'contracts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'contract_end_date', contract_end_date) order by contract_end_date)
                  from hr_employees where company_id = sys_current_company_id() and is_active and contract_end_date between current_date and current_date + 30), '[]'::jsonb),
    'birthdays', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'day', extract(day from birth_date)) order by extract(day from birth_date))
                  from hr_employees where company_id = sys_current_company_id() and is_active and extract(month from birth_date) = extract(month from current_date)), '[]'::jsonb))
  end
$$;

-- ---------------------------------------------------------------------
-- PENGUMUMAN
-- ---------------------------------------------------------------------
create table hr_announcements (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  title         text not null check (trim(title) <> ''),
  body          text not null default '',
  audience      text not null default 'all' check (audience in ('all', 'outlet', 'role')),
  outlet_ids    uuid[] not null default '{}',
  role_ids      uuid[] not null default '{}',
  pinned        boolean not null default false,
  published_at  timestamptz not null default now(),
  expires_at    timestamptz,
  created_by    uuid references sys_users(id) default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
select sys_apply_company_policies('hr_announcements', 'hr.manage');

create table hr_announcement_reads (
  announcement_id  uuid not null references hr_announcements(id) on delete cascade,
  user_id          uuid not null references sys_users(id) on delete cascade,
  read_at          timestamptz not null default now(),
  primary key (announcement_id, user_id)
);
alter table hr_announcement_reads enable row level security;
create policy hr_announcement_reads_own on hr_announcement_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- pengumuman yang ditujukan untuk user ini (semua / outlet-nya / role-nya)
create or replace function hr_my_announcements()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'title', a.title, 'body', a.body, 'pinned', a.pinned, 'published_at', a.published_at,
    'author', (select full_name from sys_users where id = a.created_by),
    'read', exists (select 1 from hr_announcement_reads r where r.announcement_id = a.id and r.user_id = auth.uid()))
    order by a.pinned desc, a.published_at desc), '[]'::jsonb)
  from hr_announcements a
  where a.company_id = sys_current_company_id() and a.published_at <= now() and (a.expires_at is null or a.expires_at > now())
    and (a.audience = 'all'
      or (a.audience = 'outlet' and exists (select 1 from unnest(a.outlet_ids) o where sys_can_access_outlet(o)))
      or (a.audience = 'role' and (sys_has_permission('*') or (select role_id from sys_users where id = auth.uid()) = any(a.role_ids))))
$$;

create or replace function hr_mark_announcement_read(p_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into hr_announcement_reads (announcement_id, user_id)
  select p_id, auth.uid() where exists (select 1 from hr_announcements where id = p_id and company_id = sys_current_company_id())
  on conflict do nothing
$$;

-- jumlah yang sudah membaca (untuk HR)
create or replace function hr_announcement_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(a.id, (select count(*) from hr_announcement_reads r where r.announcement_id = a.id)), '{}'::jsonb)
  from hr_announcements a where a.company_id = sys_current_company_id() and sys_has_permission('hr.manage')
$$;

-- ---------------------------------------------------------------------
-- Semar boleh membantu migrasi data karyawan & struktur (tetap lewat usulan + persetujuan owner)
-- ---------------------------------------------------------------------
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers',
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements']
$$;
