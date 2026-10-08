-- =====================================================================
-- SEMAR - 034: SDM / HR FASE B - ABSENSI FOTO + GPS, JADWAL SHIFT, KOREKSI
--   * sys_outlets: titik lokasi (lat/lng) + radius absen (geofence).
--   * hr_settings: aturan absensi per perusahaan (toleransi telat, wajib foto / GPS).
--   * hr_shifts: template shift (Pagi 07-15, Malam 22-06, ...). hr_rosters: jadwal per hari.
--   * hr_attendances: absen masuk/pulang dengan selfie + GPS. Jam diambil dari SERVER,
--     jarak ke outlet dihitung di SERVER. Di luar radius tetap tercatat tapi ditandai
--     untuk direview HR / atasan.
--   * hr_attendance_corrections: pengajuan koreksi absen (lupa absen, HP mati) + persetujuan.
--   Izin baru: hr.attendance (kelola jadwal shift & review absensi).
-- =====================================================================

alter table sys_outlets add column if not exists geo_lat numeric(9, 6);
alter table sys_outlets add column if not exists geo_lng numeric(9, 6);
alter table sys_outlets add column if not exists geo_radius_m int not null default 100 check (geo_radius_m between 10 and 5000);

-- yang boleh mengatur jadwal & mereview absensi
create or replace function hr_can_schedule()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('hr.manage') or sys_has_permission('hr.attendance')
$$;

-- ---------------------------------------------------------------------
-- PENGATURAN
-- ---------------------------------------------------------------------
create table hr_settings (
  company_id              uuid primary key references sys_companies(id),
  late_tolerance_minutes  int not null default 10 check (late_tolerance_minutes between 0 and 240),
  require_photo           boolean not null default true,
  require_gps             boolean not null default true,
  max_gps_accuracy_m      int not null default 150 check (max_gps_accuracy_m between 10 and 5000),
  updated_at              timestamptz not null default now()
);
select sys_apply_company_policies('hr_settings', 'hr.manage');

create or replace function hr_get_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select to_jsonb(s) - 'company_id' - 'updated_at' from hr_settings s where s.company_id = sys_current_company_id()),
    jsonb_build_object('late_tolerance_minutes', 10, 'require_photo', true, 'require_gps', true, 'max_gps_accuracy_m', 150))
$$;

-- ---------------------------------------------------------------------
-- TEMPLATE SHIFT & JADWAL
-- ---------------------------------------------------------------------
create table hr_shifts (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  code           text not null,
  name           text not null,
  start_time     time not null,
  end_time       time not null,                 -- lebih kecil dari start_time = lewat tengah malam
  break_minutes  int not null default 60 check (break_minutes >= 0),
  color          text not null default '#4ABDAC',
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, code)
);
alter table hr_shifts enable row level security;
create policy hr_shifts_select on hr_shifts for select to authenticated using (company_id = sys_current_company_id());
create policy hr_shifts_write on hr_shifts for all to authenticated
  using (company_id = sys_current_company_id() and hr_can_schedule())
  with check (company_id = sys_current_company_id() and hr_can_schedule());

create table hr_rosters (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  employee_id  uuid not null references hr_employees(id) on delete cascade,
  work_date    date not null,
  outlet_id    uuid references sys_outlets(id) on delete set null,   -- tempat kerja hari itu
  shift_id     uuid references hr_shifts(id) on delete set null,
  is_off       boolean not null default false,                       -- libur terjadwal
  note         text,
  updated_at   timestamptz not null default now(),
  unique (employee_id, work_date),
  check (is_off or shift_id is not null)
);
alter table hr_rosters enable row level security;
create policy hr_rosters_select on hr_rosters for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
create policy hr_rosters_write on hr_rosters for all to authenticated
  using (company_id = sys_current_company_id() and hr_can_schedule())
  with check (company_id = sys_current_company_id() and hr_can_schedule());
select sys_apply_outlet_lock('hr_rosters', 'outlet_id is null or sys_can_access_outlet(outlet_id) or employee_id in (select id from hr_employees where user_id = auth.uid())');

-- jadwal seorang karyawan pada tanggal tertentu (jam mulai/selesai sudah dalam zona waktu outlet)
create or replace function hr_schedule_for(p_employee_id uuid, p_date date)
returns jsonb language sql stable security definer set search_path = public as $$
  with e as (select id, outlet_id from hr_employees where id = p_employee_id),
  r as (select * from hr_rosters where employee_id = p_employee_id and work_date = p_date),
  o as (select o.* from sys_outlets o where o.id = coalesce((select outlet_id from r), (select outlet_id from e)))
  select jsonb_build_object(
    'work_date', p_date,
    'outlet_id', (select id from o), 'outlet', (select name from o),
    'geo_lat', (select geo_lat from o), 'geo_lng', (select geo_lng from o), 'geo_radius_m', (select geo_radius_m from o),
    'is_off', coalesce((select is_off from r), false),
    'has_roster', exists (select 1 from r),
    'shift_id', s.id, 'shift', s.name, 'shift_color', s.color, 'start_time', s.start_time, 'end_time', s.end_time,
    'scheduled_start', case when s.id is not null then (p_date + s.start_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end,
    'scheduled_end', case when s.id is not null then (p_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end)
  from (select 1) x
  left join r on true
  left join hr_shifts s on s.id = r.shift_id and not r.is_off
$$;

-- papan jadwal (untuk HR / kepala outlet): karyawan, jadwal, template shift
create or replace function hr_roster_board(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not hr_can_schedule() then raise exception 'Butuh izin kelola jadwal & absensi'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Rentang tanggal maksimal 2 bulan'; end if;
  return jsonb_build_object(
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name,
        'nickname', e.nickname, 'photo_path', e.photo_path, 'position', p.name, 'outlet_id', e.outlet_id, 'outlet', o.name) order by o.name nulls first, e.full_name)
      from hr_employees e left join hr_positions p on p.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
      where e.company_id = v_company and e.is_active
        and (p_outlet_id is null or e.outlet_id = p_outlet_id)
        and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('employee_id', r.employee_id, 'work_date', r.work_date, 'shift_id', r.shift_id,
        'is_off', r.is_off, 'outlet_id', r.outlet_id, 'note', r.note))
      from hr_rosters r where r.company_id = v_company and r.work_date between p_from and p_to), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(s) order by s.start_time) from hr_shifts s where s.company_id = v_company and s.is_active), '[]'::jsonb));
end $$;

-- simpan banyak sel jadwal sekaligus: [{employee_id, work_date, shift_id | null, is_off}]
-- shift_id null & is_off false = hapus jadwal hari itu
create or replace function hr_roster_save(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id(); r jsonb; v_emp hr_employees; v_n int := 0; v_shift uuid; v_off boolean;
begin
  if not hr_can_schedule() then raise exception 'Butuh izin kelola jadwal & absensi'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    select * into v_emp from hr_employees where id = (r->>'employee_id')::uuid and company_id = v_company;
    if v_emp.id is null then raise exception 'Karyawan tidak ditemukan'; end if;
    if v_emp.outlet_id is not null and not sys_can_access_outlet(v_emp.outlet_id) then raise exception 'Tidak punya akses ke outlet karyawan %', v_emp.full_name; end if;
    v_shift := nullif(r->>'shift_id', '')::uuid;
    v_off := coalesce((r->>'is_off')::boolean, false);
    if v_shift is not null and not exists (select 1 from hr_shifts where id = v_shift and company_id = v_company) then raise exception 'Shift tidak ditemukan'; end if;
    if v_shift is null and not v_off then
      delete from hr_rosters where employee_id = v_emp.id and work_date = (r->>'work_date')::date;
    else
      insert into hr_rosters (company_id, employee_id, work_date, outlet_id, shift_id, is_off, note)
      values (v_company, v_emp.id, (r->>'work_date')::date, coalesce(nullif(r->>'outlet_id', '')::uuid, v_emp.outlet_id),
              case when v_off then null else v_shift end, v_off, nullif(r->>'note', ''))
      on conflict (employee_id, work_date) do update set
        shift_id = excluded.shift_id, is_off = excluded.is_off, outlet_id = excluded.outlet_id, note = excluded.note, updated_at = now();
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- salin jadwal satu minggu ke minggu lain (template mingguan)
create or replace function hr_roster_copy_week(p_from_week date, p_to_week date, p_outlet_id uuid default null, p_overwrite boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id(); v_n int;
begin
  if not hr_can_schedule() then raise exception 'Butuh izin kelola jadwal & absensi'; end if;
  if p_from_week = p_to_week then raise exception 'Minggu asal dan tujuan sama'; end if;
  with src as (
    select r.* from hr_rosters r join hr_employees e on e.id = r.employee_id
    where r.company_id = v_company and r.work_date between p_from_week and p_from_week + 6 and e.is_active
      and (p_outlet_id is null or e.outlet_id = p_outlet_id)
      and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))
  ), ins as (
    insert into hr_rosters (company_id, employee_id, work_date, outlet_id, shift_id, is_off, note)
    select v_company, employee_id, p_to_week + (work_date - p_from_week), outlet_id, shift_id, is_off, note from src
    on conflict (employee_id, work_date) do update set
      shift_id = excluded.shift_id, is_off = excluded.is_off, outlet_id = excluded.outlet_id, note = excluded.note, updated_at = now()
      where p_overwrite
    returning 1
  ) select count(*) into v_n from ins;
  return v_n;
end $$;

-- jadwal saya
create or replace function hr_my_roster(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(hr_schedule_for(e.id, d::date) order by d), '[]'::jsonb)
  from hr_employees e, generate_series(p_from, least(p_to, p_from + 62), interval '1 day') d
  where e.user_id = auth.uid() and e.company_id = sys_current_company_id()
$$;

-- ---------------------------------------------------------------------
-- ABSENSI
-- ---------------------------------------------------------------------
create table hr_attendances (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references sys_companies(id),
  employee_id           uuid not null references hr_employees(id) on delete cascade,
  work_date             date not null,
  outlet_id             uuid references sys_outlets(id) on delete set null,
  shift_id              uuid references hr_shifts(id) on delete set null,
  scheduled_start       timestamptz,
  scheduled_end         timestamptz,
  -- masuk
  check_in_at           timestamptz,
  check_in_lat          numeric(9, 6),
  check_in_lng          numeric(9, 6),
  check_in_accuracy_m   numeric(8, 1),
  check_in_distance_m   int,
  check_in_photo        text,                                  -- hr-files/<company>/<employee>/attendance/...
  -- pulang
  check_out_at          timestamptz,
  check_out_lat         numeric(9, 6),
  check_out_lng         numeric(9, 6),
  check_out_accuracy_m  numeric(8, 1),
  check_out_distance_m  int,
  check_out_photo       text,
  -- hasil
  late_minutes          int not null default 0,
  early_leave_minutes   int not null default 0,
  flags                 text[] not null default '{}',          -- outside_radius / low_accuracy / day_off / no_geofence / corrected
  review_status         text not null default 'none' check (review_status in ('none', 'pending', 'approved', 'rejected')),
  reviewed_by           uuid references sys_users(id),
  reviewed_at           timestamptz,
  review_note           text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (employee_id, work_date),
  check (check_out_at is null or check_in_at is null or check_out_at >= check_in_at)
);
create index hr_attendances_company_date on hr_attendances (company_id, work_date);
alter table hr_attendances enable row level security;
create policy hr_attendances_select on hr_attendances for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
-- karyawan TIDAK bisa menulis langsung: absen lewat hr_clock(), koreksi lewat pengajuan
create policy hr_attendances_write on hr_attendances for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
select sys_apply_outlet_lock('hr_attendances', 'outlet_id is null or sys_can_access_outlet(outlet_id) or employee_id in (select id from hr_employees where user_id = auth.uid())');

-- hitung ulang telat / pulang cepat setiap kali jam berubah
create or replace function hr_attendance_compute()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tol int;
begin
  select coalesce((select late_tolerance_minutes from hr_settings where company_id = new.company_id), 10) into v_tol;
  new.late_minutes := case when new.check_in_at is not null and new.scheduled_start is not null
      and new.check_in_at > new.scheduled_start + make_interval(mins => v_tol)
    then floor(extract(epoch from new.check_in_at - new.scheduled_start) / 60)::int else 0 end;
  new.early_leave_minutes := case when new.check_out_at is not null and new.scheduled_end is not null and new.check_out_at < new.scheduled_end
    then ceil(extract(epoch from new.scheduled_end - new.check_out_at) / 60)::int else 0 end;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_hr_attendances_compute before insert or update on hr_attendances
  for each row execute function hr_attendance_compute();

-- jarak dua titik GPS (meter, rumus haversine)
create or replace function hr_distance_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns int language sql immutable as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null else
    round(2 * 6371000 * asin(sqrt(
      power(sin(radians((lat2 - lat1)::float8) / 2), 2)
      + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lng2 - lng1)::float8) / 2), 2))))::int end
$$;

-- absen masuk / pulang. Jam & jarak dihitung server; foto harus sudah diunggah ke folder absensi milik sendiri.
create or replace function hr_clock(p_kind text, p_lat numeric, p_lng numeric, p_accuracy numeric, p_photo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_emp hr_employees; v_set jsonb := hr_get_settings(); v_sched jsonb; v_att hr_attendances;
  v_date date; v_tz text; v_dist int; v_flags text[] := '{}';
begin
  if p_kind not in ('in', 'out') then raise exception 'Jenis absen tidak dikenal'; end if;
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = v_company;
  if v_emp.id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  if not v_emp.is_active then raise exception 'Data karyawan Anda tidak aktif'; end if;
  if (v_set->>'require_gps')::boolean and (p_lat is null or p_lng is null) then raise exception 'Lokasi GPS wajib aktif untuk absen'; end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then raise exception 'Koordinat GPS tidak valid'; end if;
  if p_photo is not null then
    if p_photo not like v_company || '/' || v_emp.id || '/attendance/%' then raise exception 'Foto absen tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'hr-files' and name = p_photo) then raise exception 'Foto absen belum terunggah'; end if;
  elsif (v_set->>'require_photo')::boolean then
    raise exception 'Foto selfie wajib untuk absen';
  end if;

  if p_kind = 'in' then
    select coalesce(o.timezone, 'Asia/Jakarta') into v_tz from (select 1) x left join sys_outlets o on o.id = v_emp.outlet_id;
    v_date := (now() at time zone v_tz)::date;
    -- shift malam: kalau kemarin ada shift lewat tengah malam yang belum dimulai, pakai tanggal kemarin
    v_sched := hr_schedule_for(v_emp.id, v_date - 1);
    if (v_sched->>'scheduled_end')::timestamptz > now() and (v_sched->>'scheduled_start')::timestamptz < now() + interval '3 hours'
       and not exists (select 1 from hr_attendances where employee_id = v_emp.id and work_date = v_date - 1) then
      v_date := v_date - 1;
    else
      v_sched := hr_schedule_for(v_emp.id, v_date);
    end if;
    if exists (select 1 from hr_attendances where employee_id = v_emp.id and work_date = v_date and check_in_at is not null) then
      raise exception 'Anda sudah absen masuk hari ini';
    end if;
  else
    -- pulang: absen masuk terakhir yang belum ditutup (maks. 20 jam lalu)
    select * into v_att from hr_attendances
    where employee_id = v_emp.id and check_in_at is not null and check_out_at is null and check_in_at > now() - interval '20 hours'
    order by check_in_at desc limit 1;
    if v_att.id is null then raise exception 'Belum ada absen masuk yang bisa ditutup'; end if;
    v_date := v_att.work_date;
    v_sched := hr_schedule_for(v_emp.id, v_date);
    v_flags := v_att.flags;
  end if;

  -- geofence
  if (v_sched->>'geo_lat') is null then
    v_flags := array(select distinct unnest(v_flags || array['no_geofence']));
  else
    v_dist := hr_distance_m(p_lat, p_lng, (v_sched->>'geo_lat')::numeric, (v_sched->>'geo_lng')::numeric);
    if v_dist is not null and v_dist > (v_sched->>'geo_radius_m')::int then
      v_flags := array(select distinct unnest(v_flags || array['outside_radius']));
    end if;
  end if;
  if p_accuracy is not null and p_accuracy > (v_set->>'max_gps_accuracy_m')::numeric then
    v_flags := array(select distinct unnest(v_flags || array['low_accuracy']));
  end if;
  if (v_sched->>'is_off')::boolean then v_flags := array(select distinct unnest(v_flags || array['day_off'])); end if;

  if p_kind = 'in' then
    insert into hr_attendances (company_id, employee_id, work_date, outlet_id, shift_id, scheduled_start, scheduled_end,
      check_in_at, check_in_lat, check_in_lng, check_in_accuracy_m, check_in_distance_m, check_in_photo, flags, review_status)
    values (v_company, v_emp.id, v_date, (v_sched->>'outlet_id')::uuid, (v_sched->>'shift_id')::uuid,
      (v_sched->>'scheduled_start')::timestamptz, (v_sched->>'scheduled_end')::timestamptz,
      now(), p_lat, p_lng, p_accuracy, v_dist, p_photo, v_flags,
      case when v_flags && array['outside_radius', 'low_accuracy', 'day_off'] then 'pending' else 'none' end)
    on conflict (employee_id, work_date) do update set
      check_in_at = excluded.check_in_at, check_in_lat = excluded.check_in_lat, check_in_lng = excluded.check_in_lng,
      check_in_accuracy_m = excluded.check_in_accuracy_m, check_in_distance_m = excluded.check_in_distance_m,
      check_in_photo = excluded.check_in_photo, flags = excluded.flags, review_status = excluded.review_status
    returning * into v_att;
  else
    update hr_attendances set check_out_at = now(), check_out_lat = p_lat, check_out_lng = p_lng, check_out_accuracy_m = p_accuracy,
      check_out_distance_m = v_dist, check_out_photo = p_photo, flags = v_flags,
      -- tanda baru saat pulang (mis. pulang di luar radius) perlu direview lagi
      review_status = case when not (v_att.flags @> v_flags) and v_flags && array['outside_radius', 'low_accuracy', 'day_off'] then 'pending' else review_status end
    where id = v_att.id returning * into v_att;
  end if;
  return to_jsonb(v_att);
end $$;

-- status absen hari ini untuk Beranda Saya
create or replace function hr_attendance_today()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_emp hr_employees; v_att hr_attendances; v_tz text; v_date date;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id();
  if v_emp.id is null then return null; end if;
  -- absen yang masih terbuka (mis. shift malam) didahulukan
  select * into v_att from hr_attendances
  where employee_id = v_emp.id and check_in_at is not null and check_out_at is null and check_in_at > now() - interval '20 hours'
  order by check_in_at desc limit 1;
  if v_att.id is not null then
    v_date := v_att.work_date;
  else
    select coalesce(o.timezone, 'Asia/Jakarta') into v_tz from (select 1) x left join sys_outlets o on o.id = v_emp.outlet_id;
    v_date := (now() at time zone v_tz)::date;
    select * into v_att from hr_attendances where employee_id = v_emp.id and work_date = v_date;
  end if;
  return jsonb_build_object(
    'employee_id', v_emp.id, 'work_date', v_date, 'server_time', now(),
    'schedule', hr_schedule_for(v_emp.id, v_date),
    'attendance', case when v_att.id is not null then to_jsonb(v_att) end,
    'settings', hr_get_settings());
end $$;

-- rekap absensi (HR / kepala outlet): satu baris per karyawan per hari, termasuk alpa (dijadwalkan tapi tidak absen)
create or replace function hr_attendance_recap(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (hr_can_schedule() or sys_has_permission('hr.view')) then raise exception 'Butuh izin lihat absensi'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Rentang tanggal maksimal 2 bulan'; end if;
  return coalesce((
    with days as (
      select coalesce(a.employee_id, r.employee_id) as employee_id, coalesce(a.work_date, r.work_date) as work_date, a.id as att_id, r.id as roster_id
      from (select * from hr_attendances where company_id = v_company and work_date between p_from and p_to) a
      full join (select * from hr_rosters where company_id = v_company and work_date between p_from and p_to) r
        on r.employee_id = a.employee_id and r.work_date = a.work_date
    )
    select jsonb_agg(jsonb_build_object(
      'employee_id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name, 'position', p.name,
      'work_date', d.work_date, 'outlet_id', coalesce(a.outlet_id, r.outlet_id, e.outlet_id), 'outlet', o.name,
      'shift', s.name, 'shift_color', s.color, 'is_off', coalesce(r.is_off, false),
      'scheduled_start', coalesce(a.scheduled_start, case when s.id is not null then (d.work_date + s.start_time) at time zone coalesce(o.timezone, 'Asia/Jakarta') end),
      'attendance_id', a.id, 'check_in_at', a.check_in_at, 'check_out_at', a.check_out_at,
      'check_in_photo', a.check_in_photo, 'check_out_photo', a.check_out_photo,
      'check_in_distance_m', a.check_in_distance_m, 'check_out_distance_m', a.check_out_distance_m,
      'check_in_lat', a.check_in_lat, 'check_in_lng', a.check_in_lng,
      'late_minutes', coalesce(a.late_minutes, 0), 'early_leave_minutes', coalesce(a.early_leave_minutes, 0),
      'flags', coalesce(a.flags, '{}'), 'review_status', coalesce(a.review_status, 'none'), 'review_note', a.review_note,
      'status', case
        when a.check_in_at is not null and a.late_minutes > 0 then 'late'
        when a.check_in_at is not null then 'present'
        when coalesce(r.is_off, false) then 'off'
        when s.id is not null and (d.work_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce(o.timezone, 'Asia/Jakarta') < now() then 'absent'
        else 'scheduled' end)
      order by d.work_date desc, e.full_name)
    from days d
    join hr_employees e on e.id = d.employee_id
    left join hr_attendances a on a.id = d.att_id
    left join hr_rosters r on r.id = d.roster_id
    left join hr_shifts s on s.id = coalesce(a.shift_id, case when not r.is_off then r.shift_id end)
    left join hr_positions p on p.id = e.position_id
    left join sys_outlets o on o.id = coalesce(a.outlet_id, r.outlet_id, e.outlet_id)
    where (p_outlet_id is null or coalesce(a.outlet_id, r.outlet_id, e.outlet_id) = p_outlet_id)
      and (coalesce(a.outlet_id, r.outlet_id, e.outlet_id) is null or sys_can_access_outlet(coalesce(a.outlet_id, r.outlet_id, e.outlet_id)))
  ), '[]'::jsonb);
end $$;

-- review absen yang ditandai (di luar radius, GPS tidak akurat, masuk di hari libur)
create or replace function hr_review_attendance(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_att hr_attendances;
begin
  if not hr_can_schedule() then raise exception 'Butuh izin review absensi'; end if;
  select * into v_att from hr_attendances where id = p_id and company_id = sys_current_company_id();
  if v_att.id is null then raise exception 'Data absen tidak ditemukan'; end if;
  if v_att.outlet_id is not null and not sys_can_access_outlet(v_att.outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if v_att.employee_id in (select id from hr_employees where user_id = auth.uid()) and not sys_has_permission('*') then
    raise exception 'Tidak bisa mereview absen sendiri';
  end if;
  update hr_attendances set review_status = case when p_approve then 'approved' else 'rejected' end,
    review_note = nullif(trim(coalesce(p_note, '')), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- KOREKSI ABSEN (lupa absen, HP mati, salah tekan)
-- ---------------------------------------------------------------------
create table hr_attendance_corrections (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  employee_id   uuid not null references hr_employees(id) on delete cascade,
  work_date     date not null,
  check_in_at   timestamptz,                    -- jam yang diajukan
  check_out_at  timestamptz,
  reason        text not null check (trim(reason) <> ''),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reviewed_by   uuid references sys_users(id),
  reviewed_at   timestamptz,
  review_note   text,
  created_at    timestamptz not null default now(),
  check (check_in_at is not null or check_out_at is not null),
  check (check_out_at is null or check_in_at is null or check_out_at > check_in_at)
);
alter table hr_attendance_corrections enable row level security;
create policy hr_attendance_corrections_select on hr_attendance_corrections for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid())
         or employee_id in (select e.id from hr_employees e join hr_employees m on m.id = e.manager_id where m.user_id = auth.uid())));
-- tulis hanya lewat fungsi di bawah

create or replace function hr_request_correction(p_work_date date, p_check_in timestamptz, p_check_out timestamptz, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_emp hr_employees; v_id uuid;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id();
  if v_emp.id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  if p_work_date > current_date + 1 or p_work_date < current_date - 31 then raise exception 'Koreksi hanya untuk 31 hari terakhir'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Alasan wajib diisi'; end if;
  if p_check_in is null and p_check_out is null then raise exception 'Isi jam masuk atau jam pulang'; end if;
  if greatest(p_check_in, p_check_out) > now() then raise exception 'Jam tidak boleh di masa depan'; end if;
  if exists (select 1 from hr_attendance_corrections where employee_id = v_emp.id and work_date = p_work_date and status = 'pending') then
    raise exception 'Masih ada pengajuan koreksi untuk tanggal ini';
  end if;
  insert into hr_attendance_corrections (company_id, employee_id, work_date, check_in_at, check_out_at, reason)
  values (v_emp.company_id, v_emp.id, p_work_date, p_check_in, p_check_out, trim(p_reason)) returning id into v_id;
  return v_id;
end $$;

-- riwayat absen saya + pengajuan koreksi
create or replace function hr_my_attendance(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  with e as (select id from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id())
  select jsonb_build_object(
    'attendances', coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('shift', s.name) order by a.work_date desc)
      from hr_attendances a left join hr_shifts s on s.id = a.shift_id
      where a.employee_id = (select id from e) and a.work_date between p_from and p_to), '[]'::jsonb),
    'corrections', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc)
      from hr_attendance_corrections c where c.employee_id = (select id from e) and c.created_at > now() - interval '60 days'), '[]'::jsonb))
$$;

create or replace function hr_cancel_correction(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update hr_attendance_corrections set status = 'cancelled'
  where id = p_id and status = 'pending' and employee_id in (select id from hr_employees where user_id = auth.uid())
$$;

-- daftar pengajuan yang bisa saya review (HR / kepala outlet / atasan langsung)
create or replace function hr_correction_inbox(p_status text default 'pending')
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('full_name', e.full_name, 'employee_number', e.employee_number, 'outlet', o.name,
      'current', (select jsonb_build_object('check_in_at', a.check_in_at, 'check_out_at', a.check_out_at) from hr_attendances a
                  where a.employee_id = c.employee_id and a.work_date = c.work_date))
    order by c.created_at desc), '[]'::jsonb)
  from hr_attendance_corrections c
  join hr_employees e on e.id = c.employee_id
  left join sys_outlets o on o.id = e.outlet_id
  where c.company_id = sys_current_company_id() and c.status = p_status
    and (p_status = 'pending' or c.created_at > now() - interval '90 days')
    and ((hr_can_schedule() and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)))
      or exists (select 1 from hr_employees m where m.id = e.manager_id and m.user_id = auth.uid()))
    and e.user_id is distinct from auth.uid()
$$;

create or replace function hr_review_correction(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_c hr_attendance_corrections; v_emp hr_employees; v_sched jsonb;
begin
  select * into v_c from hr_attendance_corrections where id = p_id and company_id = sys_current_company_id() for update;
  if v_c.id is null then raise exception 'Pengajuan tidak ditemukan'; end if;
  if v_c.status <> 'pending' then raise exception 'Pengajuan sudah diproses'; end if;
  select * into v_emp from hr_employees where id = v_c.employee_id;
  if v_emp.user_id = auth.uid() then raise exception 'Tidak bisa menyetujui pengajuan sendiri'; end if;
  if not ((hr_can_schedule() and (v_emp.outlet_id is null or sys_can_access_outlet(v_emp.outlet_id)))
          or exists (select 1 from hr_employees m where m.id = v_emp.manager_id and m.user_id = auth.uid())) then
    raise exception 'Anda bukan atasan / HR karyawan ini';
  end if;
  update hr_attendance_corrections set status = case when p_approve then 'approved' else 'rejected' end,
    reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(coalesce(p_note, '')), '')
  where id = p_id;
  if p_approve then
    v_sched := hr_schedule_for(v_emp.id, v_c.work_date);
    insert into hr_attendances (company_id, employee_id, work_date, outlet_id, shift_id, scheduled_start, scheduled_end,
      check_in_at, check_out_at, flags, review_status, reviewed_by, reviewed_at, review_note)
    values (v_c.company_id, v_emp.id, v_c.work_date, (v_sched->>'outlet_id')::uuid, (v_sched->>'shift_id')::uuid,
      (v_sched->>'scheduled_start')::timestamptz, (v_sched->>'scheduled_end')::timestamptz,
      v_c.check_in_at, v_c.check_out_at, array['corrected'], 'approved', auth.uid(), now(), 'Koreksi: ' || v_c.reason)
    on conflict (employee_id, work_date) do update set
      check_in_at = coalesce(v_c.check_in_at, hr_attendances.check_in_at),
      check_out_at = coalesce(v_c.check_out_at, hr_attendances.check_out_at),
      flags = array(select distinct unnest(hr_attendances.flags || array['corrected'])),
      review_status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = 'Koreksi: ' || v_c.reason;
  end if;
end $$;

-- jumlah yang menunggu review (badge menu)
create or replace function hr_attendance_pending_count()
returns int language sql stable security definer set search_path = public as $$
  select (select count(*) from jsonb_array_elements(hr_correction_inbox('pending')))::int
       + case when hr_can_schedule() then (select count(*) from hr_attendances a
           where a.company_id = sys_current_company_id() and a.review_status = 'pending' and a.work_date > current_date - 31
             and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)))::int else 0 end
$$;

-- ---------------------------------------------------------------------
-- STORAGE: karyawan boleh mengunggah selfie absen ke foldernya sendiri (tidak bisa menghapus / menimpa)
-- reviewer absensi boleh melihat foto
-- ---------------------------------------------------------------------
create or replace function hr_can_upload_own(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (storage.foldername(p_name))[3] = 'attendance'
     and exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid() and e.is_active)
$$;
create policy hr_files_insert_self on storage.objects for insert to authenticated
  with check (bucket_id = 'hr-files' and hr_can_upload_own(name));

create or replace function hr_can_read_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
          or ((storage.foldername(p_name))[3] = 'attendance' and sys_has_permission('hr.attendance'))
          or exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid()))
$$;

create trigger trg_hr_shifts_audit after insert or update or delete on hr_shifts for each row execute function sys_audit_trigger('');
create trigger trg_hr_settings_audit after insert or update or delete on hr_settings for each row execute function sys_audit_trigger('');

-- Semar boleh membantu membuat template shift (tetap lewat usulan + persetujuan owner)
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
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements', 'hr_shifts']
$$;
