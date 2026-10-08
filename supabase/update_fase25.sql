-- =====================================================================
-- SANTAP ERP - UPDATE FASE 25 (SDM / HR: cuti & izin)
-- Untuk database yang SUDAH menjalankan fase 1-24.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/035_hr_leave.sql
-- =====================================================================
-- SEMAR - 035: SDM / HR FASE C - CUTI & IZIN
--   * hr_leave_types: jenis cuti (tahunan, sakit, izin, menikah, duka, melahirkan) per perusahaan.
--   * Saldo cuti tahunan: hr_settings.annual_leave_days (default 12) dengan aturan
--     'after_12_months' (berhak setelah 12 bulan kerja), 'prorata' (tahun pertama sebanding
--     bulan kerja) atau 'immediate'. hr_leave_adjustments untuk saldo awal / carry-over.
--   * hr_leave_requests: pengajuan karyawan (hari dihitung tanpa hari libur di jadwal,
--     bisa setengah hari), lampiran surat dokter di hr-files/<company>/<employee>/leave/.
--   * Persetujuan: masuk menu Persetujuan (jenis 'leave', izin approval.leave) dan bisa juga
--     diputuskan atasan langsung / HR. Cuti yang disetujui tampil di jadwal & rekap absensi.
-- =====================================================================

-- karyawan ini bawahan langsung saya? (security definer: atasan tidak bisa membaca baris hr_employees bawahannya)
create or replace function hr_is_my_report(p_employee_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from hr_employees e join hr_employees m on m.id = e.manager_id
                 where e.id = p_employee_id and m.user_id = auth.uid())
$$;

-- perbaikan 034: atasan langsung bisa melihat pengajuan koreksi bawahannya
drop policy if exists hr_attendance_corrections_select on hr_attendance_corrections;
create policy hr_attendance_corrections_select on hr_attendance_corrections for select to authenticated
  using (company_id = sys_current_company_id() and (hr_can_schedule() or sys_has_permission('hr.view')
         or employee_id in (select id from hr_employees where user_id = auth.uid()) or hr_is_my_report(employee_id)));

-- ---------------------------------------------------------------------
-- PENGATURAN CUTI
-- ---------------------------------------------------------------------
alter table hr_settings add column if not exists annual_leave_days int not null default 12 check (annual_leave_days between 0 and 60);
alter table hr_settings add column if not exists leave_policy text not null default 'after_12_months'
  check (leave_policy in ('after_12_months', 'prorata', 'immediate'));

create or replace function hr_get_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select to_jsonb(s) - 'company_id' - 'updated_at' from hr_settings s where s.company_id = sys_current_company_id()),
    jsonb_build_object('late_tolerance_minutes', 10, 'require_photo', true, 'require_gps', true, 'max_gps_accuracy_m', 150,
                       'annual_leave_days', 12, 'leave_policy', 'after_12_months'))
$$;

-- ---------------------------------------------------------------------
-- JENIS CUTI
-- ---------------------------------------------------------------------
create table hr_leave_types (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  code                 text not null,
  name                 text not null,
  deducts_balance      boolean not null default false,   -- memotong saldo cuti tahunan
  is_paid              boolean not null default true,
  attachment_min_days  int,                              -- wajib lampiran mulai N hari (null = tidak wajib)
  max_days             int,                              -- maks. hari per pengajuan (null = bebas)
  color                text not null default '#4ABDAC',
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, code)
);
select sys_apply_company_policies('hr_leave_types', 'hr.manage');
create trigger trg_hr_leave_types_audit after insert or update or delete on hr_leave_types for each row execute function sys_audit_trigger('');

create or replace function hr_setup_leave_types(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into hr_leave_types (company_id, code, name, deducts_balance, is_paid, attachment_min_days, max_days, color) values
    (p_company_id, 'CUTI',       'Cuti tahunan',      true,  true,  null, null, '#4ABDAC'),
    (p_company_id, 'SAKIT',      'Sakit',             false, true,  2,    null, '#FC4A1A'),
    (p_company_id, 'IZIN',       'Izin (tidak dibayar)', false, false, null, null, '#7F8C8D'),
    (p_company_id, 'MENIKAH',    'Cuti menikah',      false, true,  null, 3,    '#8E44AD'),
    (p_company_id, 'DUKA',       'Cuti duka',         false, true,  null, 2,    '#34495E'),
    (p_company_id, 'MELAHIRKAN', 'Cuti melahirkan',   false, true,  1,    90,   '#F7B733')
  on conflict do nothing
$$;
do $$
declare c record;
begin
  for c in select id from sys_companies loop perform hr_setup_leave_types(c.id); end loop;
end $$;
-- perusahaan baru otomatis punya jenis cuti standar
create or replace function hr_company_leave_types_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform hr_setup_leave_types(new.id);
  return new;
end $$;
create trigger trg_sys_companies_leave_types after insert on sys_companies
  for each row execute function hr_company_leave_types_trigger();

-- penyesuaian saldo (saldo awal saat migrasi, carry-over, kompensasi lembur, ...)
create table hr_leave_adjustments (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  employee_id  uuid not null references hr_employees(id) on delete cascade,
  year         int not null,
  days         numeric(5, 1) not null check (days <> 0),
  note         text not null check (trim(note) <> ''),
  created_by   uuid references sys_users(id) default auth.uid(),
  created_at   timestamptz not null default now()
);
alter table hr_leave_adjustments enable row level security;
create policy hr_leave_adjustments_select on hr_leave_adjustments for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
         or employee_id in (select id from hr_employees where user_id = auth.uid())));
create policy hr_leave_adjustments_write on hr_leave_adjustments for all to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.manage'))
  with check (company_id = sys_current_company_id() and sys_has_permission('hr.manage'));
create trigger trg_hr_leave_adjustments_audit after insert or update or delete on hr_leave_adjustments for each row execute function sys_audit_trigger('');

-- ---------------------------------------------------------------------
-- PENGAJUAN
-- ---------------------------------------------------------------------
create table hr_leave_requests (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  employee_id          uuid not null references hr_employees(id) on delete cascade,
  leave_type_id        uuid not null references hr_leave_types(id),
  start_date           date not null,
  end_date             date not null,
  half_day             boolean not null default false,
  days                 numeric(5, 1) not null check (days > 0),
  reason               text not null check (trim(reason) <> ''),
  attachment_path      text,
  status               text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  approval_request_id  uuid references sys_approval_requests(id) on delete set null,
  decided_by           uuid references sys_users(id),
  decided_at           timestamptz,
  decision_note        text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (end_date >= start_date),
  check (not half_day or start_date = end_date)
);
create index hr_leave_requests_company_dates on hr_leave_requests (company_id, start_date, end_date);
alter table hr_leave_requests enable row level security;
create policy hr_leave_requests_select on hr_leave_requests for select to authenticated
  using (company_id = sys_current_company_id() and (
    sys_has_permission('hr.view') or sys_has_permission('hr.manage') or sys_has_permission('hr.attendance') or sys_has_permission('approval.leave')
    or employee_id in (select id from hr_employees where user_id = auth.uid()) or hr_is_my_report(employee_id)));
-- tulis hanya lewat fungsi di bawah
create trigger trg_hr_leave_requests_audit after insert or update or delete on hr_leave_requests for each row execute function sys_audit_trigger('reason,attachment_path');

-- jumlah hari cuti: semua tanggal dalam rentang, kecuali yang dijadwalkan libur
create or replace function hr_leave_days(p_employee_id uuid, p_start date, p_end date, p_half_day boolean default false)
returns numeric language sql stable security definer set search_path = public as $$
  select case when p_half_day then 0.5 else (
    select count(*)::numeric from generate_series(p_start, p_end, interval '1 day') d
    where not exists (select 1 from hr_rosters r where r.employee_id = p_employee_id and r.work_date = d::date and r.is_off)) end
$$;

-- saldo cuti tahunan seorang karyawan
create or replace function hr_leave_balance(p_employee_id uuid, p_year int default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_year int := coalesce(p_year, extract(year from current_date)::int);
  v_emp hr_employees; v_set jsonb; v_days int; v_policy text;
  v_eligible date; v_entitle numeric := 0; v_adj numeric; v_used numeric; v_pending numeric;
begin
  select * into v_emp from hr_employees where id = p_employee_id and company_id = sys_current_company_id();
  if v_emp.id is null then return null; end if;
  v_set := hr_get_settings();
  v_days := (v_set->>'annual_leave_days')::int;
  v_policy := v_set->>'leave_policy';
  if v_policy = 'immediate' or v_emp.join_date is null then
    v_entitle := v_days;
    v_eligible := v_emp.join_date;
  elsif v_policy = 'after_12_months' then
    v_eligible := (v_emp.join_date + interval '12 months')::date;
    -- berhak penuh setelah genap 12 bulan; sebelum itu 0
    v_entitle := case when v_eligible <= least(current_date, make_date(v_year, 12, 31)) then v_days else 0 end;
  else  -- prorata: tahun masuk dihitung sebanding bulan kerja
    v_eligible := v_emp.join_date;
    v_entitle := case
      when extract(year from v_emp.join_date) < v_year then v_days
      when extract(year from v_emp.join_date) > v_year then 0
      else floor(v_days * (13 - extract(month from v_emp.join_date)) / 12) end;
  end if;
  select coalesce(sum(days), 0) into v_adj from hr_leave_adjustments where employee_id = p_employee_id and year = v_year;
  select coalesce(sum(r.days) filter (where r.status = 'approved'), 0), coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pending
  from hr_leave_requests r join hr_leave_types t on t.id = r.leave_type_id
  where r.employee_id = p_employee_id and t.deducts_balance and extract(year from r.start_date) = v_year;
  return jsonb_build_object('year', v_year, 'policy', v_policy, 'annual', v_days, 'eligible_from', v_eligible,
    'entitlement', v_entitle, 'adjustment', v_adj, 'used', v_used, 'pending', v_pending,
    'remaining', v_entitle + v_adj - v_used - v_pending);
end $$;

-- karyawan mengajukan cuti / izin
-- p: {leave_type_id, start_date, end_date, half_day, reason, attachment_path}
create or replace function hr_request_leave(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_emp hr_employees; v_type hr_leave_types; v_req hr_leave_requests;
  v_start date := (p->>'start_date')::date;
  v_end date := coalesce((p->>'end_date')::date, (p->>'start_date')::date);
  v_half boolean := coalesce((p->>'half_day')::boolean, false);
  v_att text := nullif(p->>'attachment_path', '');
  v_days numeric; v_bal jsonb; v_appr jsonb;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = v_company;
  if v_emp.id is null then raise exception 'Akun Anda belum terhubung ke data karyawan'; end if;
  if not v_emp.is_active then raise exception 'Data karyawan Anda tidak aktif'; end if;
  select * into v_type from hr_leave_types where id = (p->>'leave_type_id')::uuid and company_id = v_company and is_active;
  if v_type.id is null then raise exception 'Jenis cuti tidak ditemukan'; end if;
  if v_start is null then raise exception 'Tanggal mulai wajib diisi'; end if;
  if v_end < v_start then raise exception 'Tanggal selesai sebelum tanggal mulai'; end if;
  if v_half and v_end <> v_start then raise exception 'Setengah hari hanya untuk satu tanggal'; end if;
  if v_start < current_date - 30 then raise exception 'Pengajuan paling lama untuk 30 hari ke belakang'; end if;
  if v_end - v_start > 180 then raise exception 'Rentang cuti terlalu panjang'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Alasan wajib diisi'; end if;
  if exists (select 1 from hr_leave_requests where employee_id = v_emp.id and status in ('pending', 'approved')
             and daterange(start_date, end_date, '[]') && daterange(v_start, v_end, '[]')) then
    raise exception 'Tanggal ini bertabrakan dengan pengajuan cuti lain';
  end if;
  v_days := hr_leave_days(v_emp.id, v_start, v_end, v_half);
  if v_days <= 0 then raise exception 'Semua tanggal yang dipilih adalah hari libur Anda'; end if;
  if v_type.max_days is not null and v_days > v_type.max_days then
    raise exception '% maksimal % hari per pengajuan', v_type.name, v_type.max_days;
  end if;
  if v_att is not null then
    if v_att not like v_company || '/' || v_emp.id || '/leave/%' then raise exception 'Lampiran tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'hr-files' and name = v_att) then raise exception 'Lampiran belum terunggah'; end if;
  elsif v_type.attachment_min_days is not null and v_days >= v_type.attachment_min_days then
    raise exception '% % hari ke atas wajib melampirkan bukti (mis. surat dokter)', v_type.name, v_type.attachment_min_days;
  end if;
  if v_type.deducts_balance then
    v_bal := hr_leave_balance(v_emp.id, extract(year from v_start)::int);
    if (v_bal->>'remaining')::numeric < v_days then
      raise exception 'Sisa cuti tidak cukup (sisa % hari%)', v_bal->>'remaining',
        case when (v_bal->>'entitlement')::numeric = 0 and v_bal->>'eligible_from' is not null
             then ', berhak cuti mulai ' || to_char((v_bal->>'eligible_from')::date, 'DD-MM-YYYY') else '' end;
    end if;
  end if;

  insert into hr_leave_requests (company_id, employee_id, leave_type_id, start_date, end_date, half_day, days, reason, attachment_path)
  values (v_company, v_emp.id, v_type.id, v_start, v_end, v_half, v_days, trim(p->>'reason'), v_att)
  returning * into v_req;
  v_appr := sys_request_approval('leave', v_req.id, v_emp.outlet_id, v_days,
    v_type.name || ' · ' || v_emp.full_name || ' · ' || v_days || ' hari (' || to_char(v_start, 'DD/MM')
      || case when v_end <> v_start then '–' || to_char(v_end, 'DD/MM') else '' end || ')',
    jsonb_build_object('employee', v_emp.full_name, 'leave_type', v_type.name, 'start_date', v_start, 'end_date', v_end,
                       'days', v_days, 'half_day', v_half, 'reason', trim(p->>'reason'), 'has_attachment', v_att is not null));
  update hr_leave_requests set approval_request_id = (v_appr->>'approval_request_id')::uuid where id = v_req.id returning * into v_req;
  return to_jsonb(v_req);
end $$;

-- keputusan dari menu Persetujuan (sys_decide_approval) / dari HR & atasan diteruskan ke pengajuan cuti
create or replace function hr_leave_sync_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_req hr_leave_requests; v_type hr_leave_types; v_bal jsonb;
begin
  select * into v_req from hr_leave_requests where id = new.document_id for update;
  if v_req.id is null or v_req.status <> 'pending' then return new; end if;
  if new.status = 'approved' then
    select * into v_type from hr_leave_types where id = v_req.leave_type_id;
    if v_type.deducts_balance then
      v_bal := hr_leave_balance(v_req.employee_id, extract(year from v_req.start_date)::int);
      -- saldo sudah termasuk pengajuan ini sebagai 'pending'
      if (v_bal->>'remaining')::numeric < 0 then raise exception 'Sisa cuti karyawan tidak cukup'; end if;
    end if;
  end if;
  update hr_leave_requests set status = new.status, decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()),
    decision_note = new.decision_note, updated_at = now()
  where id = v_req.id;
  return new;
end $$;
create trigger trg_sys_approval_requests_leave after update of status on sys_approval_requests
  for each row when (new.document_type = 'leave' and old.status = 'pending' and new.status in ('approved', 'rejected', 'cancelled'))
  execute function hr_leave_sync_approval();

-- yang berhak memutuskan: HR (hr.manage) / penyetuju cuti (approval.leave) dengan akses outlet, atau atasan langsung
create or replace function hr_can_decide_leave(p_employee_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from hr_employees e
    where e.id = p_employee_id and e.company_id = sys_current_company_id() and e.user_id is distinct from auth.uid()
      and (((sys_has_permission('hr.manage') or sys_has_permission('approval.leave')) and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)))
        or exists (select 1 from hr_employees m where m.id = e.manager_id and m.user_id = auth.uid())))
$$;

create or replace function hr_decide_leave(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_req hr_leave_requests;
begin
  select * into v_req from hr_leave_requests where id = p_id and company_id = sys_current_company_id();
  if v_req.id is null then raise exception 'Pengajuan tidak ditemukan'; end if;
  if v_req.status <> 'pending' then raise exception 'Pengajuan sudah diproses'; end if;
  if v_req.employee_id in (select id from hr_employees where user_id = auth.uid()) then raise exception 'Tidak bisa memutuskan pengajuan sendiri'; end if;
  if not hr_can_decide_leave(v_req.employee_id) then raise exception 'Anda bukan atasan / penyetuju cuti karyawan ini'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception 'Alasan penolakan wajib diisi'; end if;
  if v_req.approval_request_id is not null then
    update sys_approval_requests set status = case when p_approve then 'approved' else 'rejected' end,
      decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), '')
    where id = v_req.approval_request_id and status = 'pending';
  end if;
  -- tanpa permintaan approval (atau sudah ditutup): putuskan langsung
  update hr_leave_requests set status = case when p_approve then 'approved' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now()
  where id = p_id and status = 'pending';
end $$;

-- karyawan membatalkan: yang menunggu, atau yang disetujui tapi belum dimulai
create or replace function hr_cancel_leave(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_req hr_leave_requests;
begin
  select r.* into v_req from hr_leave_requests r join hr_employees e on e.id = r.employee_id
  where r.id = p_id and e.user_id = auth.uid() and r.company_id = sys_current_company_id();
  if v_req.id is null then raise exception 'Pengajuan tidak ditemukan'; end if;
  if v_req.status = 'pending' then
    update sys_approval_requests set status = 'cancelled', decided_at = now(), decision_note = 'Dibatalkan pengaju'
    where id = v_req.approval_request_id and status = 'pending';
  elsif not (v_req.status = 'approved' and v_req.start_date > current_date) then
    raise exception 'Pengajuan ini tidak bisa dibatalkan lagi';
  end if;
  update hr_leave_requests set status = 'cancelled', updated_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- TAMPILAN
-- ---------------------------------------------------------------------
-- Beranda Saya: saldo, jenis cuti, pengajuan saya, rekan satu outlet yang cuti 14 hari ke depan
create or replace function hr_my_leave()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_emp hr_employees;
begin
  select * into v_emp from hr_employees where user_id = auth.uid() and company_id = sys_current_company_id();
  if v_emp.id is null then return null; end if;
  return jsonb_build_object(
    'employee_id', v_emp.id,
    'balance', hr_leave_balance(v_emp.id, extract(year from current_date)::int),
    'types', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'code', t.code, 'name', t.name, 'deducts_balance', t.deducts_balance,
        'is_paid', t.is_paid, 'attachment_min_days', t.attachment_min_days, 'max_days', t.max_days, 'color', t.color) order by t.deducts_balance desc, t.name)
      from hr_leave_types t where t.company_id = v_emp.company_id and t.is_active), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('leave_type', t.name, 'color', t.color,
        'decider', (select full_name from sys_users where id = r.decided_by)) order by r.start_date desc)
      from hr_leave_requests r join hr_leave_types t on t.id = r.leave_type_id
      where r.employee_id = v_emp.id and (r.status = 'pending' or r.start_date >= date_trunc('year', current_date) - interval '1 month')), '[]'::jsonb),
    'team', coalesce((select jsonb_agg(jsonb_build_object('full_name', coalesce(e.nickname, e.full_name), 'leave_type', t.name, 'color', t.color,
        'start_date', r.start_date, 'end_date', r.end_date) order by r.start_date)
      from hr_leave_requests r join hr_employees e on e.id = r.employee_id join hr_leave_types t on t.id = r.leave_type_id
      where r.company_id = v_emp.company_id and r.status = 'approved' and r.employee_id <> v_emp.id
        and e.outlet_id is not distinct from v_emp.outlet_id
        and r.end_date >= current_date and r.start_date <= current_date + 14), '[]'::jsonb));
end $$;

-- HR / atasan / penyetuju: pengajuan dalam rentang (kalender tim) + yang menunggu keputusan saya
create or replace function hr_leave_board(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id(); v_wide boolean;
begin
  v_wide := sys_has_permission('hr.view') or sys_has_permission('hr.manage') or sys_has_permission('hr.attendance') or sys_has_permission('approval.leave');
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
        'full_name', e.full_name, 'employee_number', e.employee_number, 'outlet', o.name, 'outlet_id', e.outlet_id,
        'position', p.name, 'leave_type', t.name, 'color', t.color, 'is_paid', t.is_paid, 'deducts_balance', t.deducts_balance,
        'decider', (select full_name from sys_users where id = r.decided_by),
        'can_decide', r.status = 'pending' and hr_can_decide_leave(e.id)) order by r.start_date)
      from hr_leave_requests r
      join hr_employees e on e.id = r.employee_id
      join hr_leave_types t on t.id = r.leave_type_id
      left join hr_positions p on p.id = e.position_id
      left join sys_outlets o on o.id = e.outlet_id
      where r.company_id = v_company and r.status <> 'cancelled'
        and ((r.end_date >= p_from and r.start_date <= p_to) or (r.status = 'pending' and hr_can_decide_leave(e.id)))
        and (p_outlet_id is null or e.outlet_id = p_outlet_id)
        and ((v_wide and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)))
          or exists (select 1 from hr_employees m where m.id = e.manager_id and m.user_id = auth.uid()))), '[]'::jsonb),
    'types', coalesce((select jsonb_agg(to_jsonb(t) order by t.deducts_balance desc, t.name) from hr_leave_types t where t.company_id = v_company), '[]'::jsonb));
end $$;

-- saldo cuti semua karyawan (HR)
create or replace function hr_leave_balances(p_year int default null, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (sys_has_permission('hr.view') or sys_has_permission('hr.manage')) then raise exception 'Butuh izin lihat data karyawan'; end if;
  return coalesce((select jsonb_agg(hr_leave_balance(e.id, coalesce(p_year, extract(year from current_date)::int))
      || jsonb_build_object('employee_id', e.id, 'full_name', e.full_name, 'employee_number', e.employee_number,
                            'join_date', e.join_date, 'outlet', o.name, 'position', p.name) order by e.full_name)
    from hr_employees e left join sys_outlets o on o.id = e.outlet_id left join hr_positions p on p.id = e.position_id
    where e.company_id = sys_current_company_id() and e.is_active
      and (p_outlet_id is null or e.outlet_id = p_outlet_id)
      and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))), '[]'::jsonb);
end $$;

-- jumlah pengajuan cuti yang menunggu keputusan saya (badge menu)
create or replace function hr_leave_pending_count()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from hr_leave_requests r
  where r.company_id = sys_current_company_id() and r.status = 'pending' and hr_can_decide_leave(r.employee_id)
$$;

-- ---------------------------------------------------------------------
-- JADWAL & REKAP ABSENSI MENGENAL CUTI
-- ---------------------------------------------------------------------
create or replace function hr_leave_on(p_employee_id uuid, p_date date)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'leave_type', t.name, 'color', t.color, 'half_day', r.half_day)
  from hr_leave_requests r join hr_leave_types t on t.id = r.leave_type_id
  where r.employee_id = p_employee_id and r.status = 'approved' and p_date between r.start_date and r.end_date
  limit 1
$$;

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
    'leave', hr_leave_on(p_employee_id, p_date),
    'shift_id', s.id, 'shift', s.name, 'shift_color', s.color, 'start_time', s.start_time, 'end_time', s.end_time,
    'scheduled_start', case when s.id is not null then (p_date + s.start_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end,
    'scheduled_end', case when s.id is not null then (p_date + (s.end_time <= s.start_time)::int + s.end_time) at time zone coalesce((select timezone from o), 'Asia/Jakarta') end)
  from (select 1) x
  left join r on true
  left join hr_shifts s on s.id = r.shift_id and not r.is_off
$$;

-- rekap: hari cuti yang disetujui ikut tampil (status 'leave', menggantikan alpa / terjadwal)
create or replace function hr_attendance_recap(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (hr_can_schedule() or sys_has_permission('hr.view')) then raise exception 'Butuh izin lihat absensi'; end if;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'Rentang tanggal maksimal 2 bulan'; end if;
  return coalesce((
    with keys as (
      select employee_id, work_date from hr_attendances where company_id = v_company and work_date between p_from and p_to
      union
      select employee_id, work_date from hr_rosters where company_id = v_company and work_date between p_from and p_to
      union
      select lr.employee_id, d::date from hr_leave_requests lr, generate_series(greatest(lr.start_date, p_from), least(lr.end_date, p_to), interval '1 day') d
      where lr.company_id = v_company and lr.status = 'approved' and lr.end_date >= p_from and lr.start_date <= p_to
    ), days as (
      select k.employee_id, k.work_date, a.id as att_id, r.id as roster_id, hr_leave_on(k.employee_id, k.work_date) as lv
      from keys k
      left join hr_attendances a on a.employee_id = k.employee_id and a.work_date = k.work_date
      left join hr_rosters r on r.employee_id = k.employee_id and r.work_date = k.work_date
    )
    select jsonb_agg(jsonb_build_object(
      'employee_id', e.id, 'employee_number', e.employee_number, 'full_name', e.full_name, 'position', p.name,
      'work_date', d.work_date, 'outlet_id', coalesce(a.outlet_id, r.outlet_id, e.outlet_id), 'outlet', o.name,
      'shift', s.name, 'shift_color', s.color, 'is_off', coalesce(r.is_off, false),
      'leave_type', d.lv->>'leave_type', 'leave_color', d.lv->>'color',
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
        when d.lv is not null then 'leave'
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

-- ---------------------------------------------------------------------
-- STORAGE: karyawan boleh unggah lampiran cuti ke folder 'leave' miliknya; penyetuju boleh melihat
-- ---------------------------------------------------------------------
create or replace function hr_can_upload_own(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (storage.foldername(p_name))[3] in ('attendance', 'leave')
     and exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid() and e.is_active)
$$;

create or replace function hr_can_read_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (sys_has_permission('hr.view') or sys_has_permission('hr.manage')
          or ((storage.foldername(p_name))[3] = 'attendance' and sys_has_permission('hr.attendance'))
          or ((storage.foldername(p_name))[3] = 'leave' and (sys_has_permission('approval.leave')
              or exists (select 1 from hr_employees e join hr_employees m on m.id = e.manager_id
                         where e.id::text = (storage.foldername(p_name))[2] and m.user_id = auth.uid())))
          or exists (select 1 from hr_employees e where e.id::text = (storage.foldername(p_name))[2] and e.user_id = auth.uid()))
$$;

-- Semar boleh membantu membuat jenis cuti (tetap lewat usulan + persetujuan owner)
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
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements', 'hr_shifts', 'hr_leave_types']
$$;
