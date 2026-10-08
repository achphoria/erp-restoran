-- =====================================================================
-- SEMAR - 037: SDM / HR FASE E - PENILAIAN KINERJA
--   * hr_appraisal_templates: form per role / jabatan, kriteria berbobot dengan skala 1-5.
--     Kriteria 'rating' dinilai manusia; kriteria 'auto' dihitung dari data:
--     attendance (kehadiran), punctuality (tepat waktu), tasks (tugas selesai tepat waktu), sop (kepatuhan SOP).
--   * hr_appraisal_periods: periode penilaian (mis. Q4 2026).
--   * hr_appraisals: per karyawan per periode. Alur: self (penilaian diri) -> manager (atasan / HR)
--     -> acknowledge (karyawan membaca & menanggapi) -> done. Nilai akhir 1-5 + grade A-E.
--   Izin baru: hr.appraisal (kelola template, periode & semua penilaian). Atasan langsung menilai bawahannya.
-- =====================================================================

create table hr_appraisal_templates (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  name         text not null check (trim(name) <> ''),
  role_id      uuid references sys_roles(id) on delete set null,       -- null = semua role
  position_id  uuid references hr_positions(id) on delete set null,    -- null = semua jabatan
  criteria     jsonb not null default '[]',   -- [{key, name, description, weight, kind: 'rating'|'auto', metric}]
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (jsonb_typeof(criteria) = 'array')
);
select sys_apply_company_policies('hr_appraisal_templates', 'hr.appraisal');
create trigger trg_hr_appraisal_templates_audit after insert or update or delete on hr_appraisal_templates for each row execute function sys_audit_trigger('');

create table hr_appraisal_periods (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  name             text not null check (trim(name) <> ''),
  start_date       date not null,
  end_date         date not null,
  self_assessment  boolean not null default true,
  status           text not null default 'open' check (status in ('open', 'closed')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date >= start_date)
);
select sys_apply_company_policies('hr_appraisal_periods', 'hr.appraisal');
create trigger trg_hr_appraisal_periods_audit after insert or update or delete on hr_appraisal_periods for each row execute function sys_audit_trigger('');

create table hr_appraisals (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  period_id         uuid not null references hr_appraisal_periods(id) on delete cascade,
  employee_id       uuid not null references hr_employees(id) on delete cascade,
  template_id       uuid references hr_appraisal_templates(id) on delete set null,
  template_name     text not null,
  criteria          jsonb not null,                   -- salinan kriteria saat penilaian dimulai
  reviewer_id       uuid references sys_users(id) on delete set null,   -- atasan langsung (null = HR)
  status            text not null default 'self' check (status in ('self', 'manager', 'acknowledge', 'done')),
  self_scores       jsonb not null default '{}',      -- {key: {score, note}}
  self_comment      text,
  self_submitted_at timestamptz,
  manager_scores    jsonb not null default '{}',
  metrics           jsonb,                            -- hasil hitung otomatis saat atasan mengirim
  final_score       numeric(4, 2),
  grade             text,
  strengths         text,
  improvements      text,
  goals             text,
  reviewed_by       uuid references sys_users(id),
  reviewed_at       timestamptz,
  employee_comment  text,
  acknowledged_at   timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (period_id, employee_id)
);
alter table hr_appraisals enable row level security;
-- baca hanya lewat fungsi (nilai atasan disembunyikan dari karyawan sampai dikirim)
create policy hr_appraisals_select on hr_appraisals for select to authenticated
  using (company_id = sys_current_company_id() and sys_has_permission('hr.appraisal'));

-- ---------------------------------------------------------------------
-- METRIK OTOMATIS
-- ---------------------------------------------------------------------
create or replace function hr_rate_to_score(p_rate numeric)
returns int language sql immutable as $$
  select case when p_rate is null then null when p_rate >= 0.98 then 5 when p_rate >= 0.95 then 4
              when p_rate >= 0.90 then 3 when p_rate >= 0.80 then 2 else 1 end
$$;

create or replace function hr_appraisal_metrics(p_employee_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_emp hr_employees; v_user uuid; v_role uuid; v_to date := least(p_to, v_today);
  v_sched int; v_present int; v_ontime int; v_done int; v_task_ok int; v_overdue int; v_sop numeric; v_runs int;
begin
  select * into v_emp from hr_employees where id = p_employee_id;
  v_user := v_emp.user_id;
  v_role := coalesce((select role_id from sys_users where id = v_user), (select default_role_id from hr_positions where id = v_emp.position_id));
  -- hari kerja terjadwal (bukan libur, bukan cuti disetujui) sampai hari ini
  select count(*), count(a.id) filter (where a.check_in_at is not null), count(a.id) filter (where a.check_in_at is not null and a.late_minutes = 0)
    into v_sched, v_present, v_ontime
  from hr_rosters r
  left join hr_attendances a on a.employee_id = r.employee_id and a.work_date = r.work_date
  where r.employee_id = p_employee_id and r.work_date between p_from and v_to and not r.is_off and r.shift_id is not null
    and hr_leave_on(p_employee_id, r.work_date) is null;
  -- tugas: selesai dalam periode (tepat waktu = tanpa tenggat / selesai <= tenggat) + yang lewat tenggat & belum selesai
  if v_user is not null then
    select count(*) filter (where status = 'done' and done_at::date between p_from and p_to),
           count(*) filter (where status = 'done' and done_at::date between p_from and p_to and (due_date is null or done_at::date <= due_date)),
           count(*) filter (where status in ('new', 'in_progress', 'review') and due_date between p_from and v_to and due_date < v_today)
      into v_done, v_task_ok, v_overdue
    from hr_tasks where assignee_id = v_user;
  end if;
  -- SOP: rata-rata kelengkapan checklist outlet karyawan untuk role-nya
  select avg((select count(*) from jsonb_array_elements(x.items) i where (i->>'done')::boolean)::numeric / greatest(1, jsonb_array_length(x.items))), count(*)
    into v_sop, v_runs
  from hr_sop_runs x join hr_sop_templates t on t.id = x.template_id
  where x.outlet_id is not distinct from v_emp.outlet_id and x.run_date between p_from and v_to
    and (t.role_id is null or t.role_id = v_role);
  return jsonb_build_object(
    'attendance', jsonb_build_object('scheduled', v_sched, 'present', v_present,
      'rate', case when v_sched > 0 then round(v_present::numeric / v_sched, 4) end,
      'score', hr_rate_to_score(case when v_sched > 0 then v_present::numeric / v_sched end)),
    'punctuality', jsonb_build_object('present', v_present, 'on_time', v_ontime,
      'rate', case when v_present > 0 then round(v_ontime::numeric / v_present, 4) end,
      'score', hr_rate_to_score(case when v_present > 0 then v_ontime::numeric / v_present end)),
    'tasks', jsonb_build_object('done', coalesce(v_done, 0), 'on_time', coalesce(v_task_ok, 0), 'overdue', coalesce(v_overdue, 0),
      'rate', case when coalesce(v_done, 0) + coalesce(v_overdue, 0) > 0 then round(v_task_ok::numeric / (v_done + v_overdue), 4) end,
      'score', hr_rate_to_score(case when coalesce(v_done, 0) + coalesce(v_overdue, 0) > 0 then v_task_ok::numeric / (v_done + v_overdue) end)),
    'sop', jsonb_build_object('runs', v_runs, 'rate', round(v_sop, 4), 'score', hr_rate_to_score(v_sop)));
end $$;

-- nilai akhir: rata-rata berbobot kriteria yang punya nilai (kriteria auto tanpa data diabaikan)
create or replace function hr_appraisal_score(p_criteria jsonb, p_scores jsonb, p_metrics jsonb)
returns jsonb language sql immutable as $$
  with c as (
    select coalesce((x->>'weight')::numeric, 0) as w,
      case when x->>'kind' = 'auto' then (p_metrics->(x->>'metric')->>'score')::numeric
           else nullif(p_scores->(x->>'key')->>'score', '')::numeric end as s
    from jsonb_array_elements(p_criteria) x
  ), t as (select sum(w * s) / nullif(sum(w) filter (where s is not null), 0) as score from c where s is not null)
  select jsonb_build_object('score', round(score, 2), 'grade', case when score is null then null when score >= 4.5 then 'A' when score >= 3.75 then 'B'
                                                                     when score >= 3 then 'C' when score >= 2 then 'D' else 'E' end)
  from t
$$;

-- ---------------------------------------------------------------------
-- PERAN
-- ---------------------------------------------------------------------
create or replace function hr_appraisal_access(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  -- 'hr' / 'reviewer' / 'self' / null
  select case
    when sys_has_permission('hr.appraisal') and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id)) and e.user_id is distinct from auth.uid() then 'hr'
    when a.reviewer_id = auth.uid() or hr_is_my_report(e.id) then 'reviewer'
    when e.user_id = auth.uid() then 'self' end
  from hr_appraisals a join hr_employees e on e.id = a.employee_id
  where a.id = p_id and a.company_id = sys_current_company_id()
$$;

-- template yang paling cocok untuk karyawan (jabatan + role > jabatan > role > umum)
create or replace function hr_appraisal_template_for(p_employee_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  with e as (
    select e.*, coalesce((select role_id from sys_users where id = e.user_id), (select default_role_id from hr_positions where id = e.position_id)) as role
    from hr_employees e where e.id = p_employee_id
  )
  select t.id from hr_appraisal_templates t, e
  where t.company_id = e.company_id and t.is_active and jsonb_array_length(t.criteria) > 0
    and (t.position_id is null or t.position_id = e.position_id) and (t.role_id is null or t.role_id = e.role)
  order by (t.position_id is not null)::int * 2 + (t.role_id is not null)::int desc, t.created_at
  limit 1
$$;

-- mulai penilaian untuk semua karyawan aktif (atau yang dipilih) pada periode
create or replace function hr_appraisal_start(p_period_id uuid, p_employee_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_period hr_appraisal_periods; e record; v_tpl hr_appraisal_templates; v_n int := 0; v_skip text[] := '{}';
begin
  if not sys_has_permission('hr.appraisal') then raise exception 'Butuh izin kelola penilaian'; end if;
  select * into v_period from hr_appraisal_periods where id = p_period_id and company_id = sys_current_company_id();
  if v_period.id is null then raise exception 'Periode tidak ditemukan'; end if;
  if v_period.status <> 'open' then raise exception 'Periode sudah ditutup'; end if;
  for e in select * from hr_employees where company_id = v_period.company_id and is_active
             and (p_employee_ids is null or id = any(p_employee_ids))
             and (outlet_id is null or sys_can_access_outlet(outlet_id))
             and not exists (select 1 from hr_appraisals a where a.period_id = p_period_id and a.employee_id = hr_employees.id) loop
    select * into v_tpl from hr_appraisal_templates where id = hr_appraisal_template_for(e.id);
    if v_tpl.id is null then v_skip := v_skip || e.full_name; continue; end if;
    insert into hr_appraisals (company_id, period_id, employee_id, template_id, template_name, criteria, reviewer_id, status)
    values (v_period.company_id, p_period_id, e.id, v_tpl.id, v_tpl.name, v_tpl.criteria,
      (select m.user_id from hr_employees m where m.id = e.manager_id),
      case when v_period.self_assessment and e.user_id is not null then 'self' else 'manager' end);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('created', v_n, 'skipped', to_jsonb(v_skip));
end $$;

-- detail sesuai peran (nilai atasan & hasil disembunyikan dari karyawan sampai dikirim)
create or replace function hr_appraisal_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_role text := hr_appraisal_access(p_id); v jsonb;
begin
  if v_role is null then return null; end if;
  select to_jsonb(a) || jsonb_build_object('access', v_role, 'period', p.name, 'start_date', p.start_date, 'end_date', p.end_date,
      'full_name', e.full_name, 'employee_number', e.employee_number, 'position', ps.name, 'outlet', o.name, 'photo_path', e.photo_path,
      'reviewer', (select full_name from sys_users where id = coalesce(a.reviewed_by, a.reviewer_id)),
      'live_metrics', case when a.status in ('self', 'manager') and v_role <> 'self' then hr_appraisal_metrics(a.employee_id, p.start_date, p.end_date) end)
    into v
  from hr_appraisals a join hr_appraisal_periods p on p.id = a.period_id join hr_employees e on e.id = a.employee_id
  left join hr_positions ps on ps.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
  where a.id = p_id;
  if v_role = 'self' and v->>'status' in ('self', 'manager') then
    v := v - 'manager_scores' - 'final_score' - 'grade' - 'strengths' - 'improvements' - 'goals' - 'metrics';
  end if;
  return v;
end $$;

create or replace function hr_appraisal_submit_self(p_id uuid, p_scores jsonb, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if hr_appraisal_access(p_id) is distinct from 'self' then raise exception 'Ini bukan penilaian diri Anda'; end if;
  if (select status from hr_appraisals where id = p_id) <> 'self' then raise exception 'Penilaian diri sudah dikirim'; end if;
  update hr_appraisals set self_scores = coalesce(p_scores, '{}'), self_comment = nullif(trim(coalesce(p_comment, '')), ''),
    self_submitted_at = now(), status = 'manager', updated_at = now()
  where id = p_id;
end $$;

-- atasan / HR mengirim penilaian: metrik otomatis dibekukan, nilai akhir & grade dihitung
create or replace function hr_appraisal_submit_manager(p_id uuid, p_scores jsonb, p_strengths text, p_improvements text, p_goals text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role text := hr_appraisal_access(p_id); v_a hr_appraisals; v_p hr_appraisal_periods; v_metrics jsonb; v_res jsonb; v_has_user boolean;
begin
  if v_role is null or v_role = 'self' then raise exception 'Anda bukan penilai karyawan ini'; end if;
  select * into v_a from hr_appraisals where id = p_id for update;
  if v_a.status = 'self' and v_role <> 'hr' then raise exception 'Menunggu penilaian diri karyawan'; end if;
  if v_a.status in ('acknowledge', 'done') then raise exception 'Penilaian sudah dikirim'; end if;
  -- semua kriteria rating wajib diisi 1-5
  if exists (select 1 from jsonb_array_elements(v_a.criteria) c where c->>'kind' <> 'auto'
             and coalesce(nullif(p_scores->(c->>'key')->>'score', '')::numeric, 0) not between 1 and 5) then
    raise exception 'Semua kriteria wajib dinilai 1-5';
  end if;
  select * into v_p from hr_appraisal_periods where id = v_a.period_id;
  v_metrics := hr_appraisal_metrics(v_a.employee_id, v_p.start_date, v_p.end_date);
  v_res := hr_appraisal_score(v_a.criteria, p_scores, v_metrics);
  v_has_user := (select user_id is not null from hr_employees where id = v_a.employee_id);
  update hr_appraisals set manager_scores = p_scores, metrics = v_metrics, final_score = (v_res->>'score')::numeric, grade = v_res->>'grade',
    strengths = nullif(trim(coalesce(p_strengths, '')), ''), improvements = nullif(trim(coalesce(p_improvements, '')), ''),
    goals = nullif(trim(coalesce(p_goals, '')), ''), reviewed_by = auth.uid(), reviewed_at = now(),
    status = case when v_has_user then 'acknowledge' else 'done' end, updated_at = now()
  where id = p_id;
  return v_res;
end $$;

create or replace function hr_appraisal_acknowledge(p_id uuid, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if hr_appraisal_access(p_id) is distinct from 'self' then raise exception 'Ini bukan penilaian Anda'; end if;
  if (select status from hr_appraisals where id = p_id) <> 'acknowledge' then raise exception 'Belum bisa dikonfirmasi'; end if;
  update hr_appraisals set employee_comment = nullif(trim(coalesce(p_comment, '')), ''), acknowledged_at = now(), status = 'done', updated_at = now()
  where id = p_id;
end $$;

-- HR membuka kembali penilaian (mis. salah nilai)
create or replace function hr_appraisal_reopen(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if hr_appraisal_access(p_id) is distinct from 'hr' then raise exception 'Butuh izin kelola penilaian'; end if;
  update hr_appraisals set status = 'manager', acknowledged_at = null, employee_comment = null, updated_at = now() where id = p_id;
end $$;

-- daftar untuk saya: penilaian diri / hasil saya + yang harus saya nilai
create or replace function hr_my_appraisals()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'period', p.name, 'full_name', e.full_name, 'status', a.status,
      'access', hr_appraisal_access(a.id), 'grade', case when a.status in ('acknowledge', 'done') then a.grade end,
      'final_score', case when a.status in ('acknowledge', 'done') then a.final_score end, 'end_date', p.end_date)
    order by p.end_date desc, e.full_name), '[]'::jsonb)
  from hr_appraisals a join hr_appraisal_periods p on p.id = a.period_id join hr_employees e on e.id = a.employee_id
  where a.company_id = sys_current_company_id()
    and (e.user_id = auth.uid() or ((a.reviewer_id = auth.uid() or hr_is_my_report(e.id)) and e.user_id is distinct from auth.uid()))
    and (a.status <> 'done' or p.end_date > current_date - 120)
$$;

-- jumlah yang perlu tindakan saya (badge)
create or replace function hr_appraisal_todo_count()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from hr_appraisals a join hr_employees e on e.id = a.employee_id
  where a.company_id = sys_current_company_id() and (
    (e.user_id = auth.uid() and a.status in ('self', 'acknowledge'))
    or (a.status = 'manager' and e.user_id is distinct from auth.uid() and (a.reviewer_id = auth.uid() or hr_is_my_report(e.id))))
$$;

-- ringkasan periode untuk HR
create or replace function hr_appraisal_overview(p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_has_permission('hr.appraisal') then raise exception 'Butuh izin kelola penilaian'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'employee_id', e.id, 'full_name', e.full_name, 'employee_number', e.employee_number,
      'position', ps.name, 'outlet', o.name, 'template_name', a.template_name, 'status', a.status, 'final_score', a.final_score, 'grade', a.grade,
      'reviewer', (select full_name from sys_users where id = coalesce(a.reviewed_by, a.reviewer_id)), 'acknowledged_at', a.acknowledged_at)
    order by e.full_name)
    from hr_appraisals a join hr_employees e on e.id = a.employee_id left join hr_positions ps on ps.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
    where a.period_id = p_period_id and a.company_id = sys_current_company_id() and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))), '[]'::jsonb);
end $$;
