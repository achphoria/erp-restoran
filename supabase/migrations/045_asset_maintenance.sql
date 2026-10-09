-- =====================================================================
-- SEMAR - 045: ASET TAHAP 2 (perawatan, kerusakan, opname)
--   * Jadwal perawatan rutin per aset (tiap N hari / minggu / bulan): tugas otomatis muncul di menu Tugas
--     H-x sebelum jatuh tempo; saat tugas Selesai, riwayat perawatan tercatat & jadwal maju ke periode berikutnya
--   * Riwayat perawatan + biaya (opsional dijurnal: Beban Perbaikan & Perawatan / Kas-Bank)
--   * Laporan kerusakan dari HP oleh semua karyawan (scan QR label / halaman aset): tiket KRS + tugas perbaikan
--     otomatis; status, vendor, biaya perbaikan, lama aset rusak
--   * Opname aset per outlet dengan scan QR: ditemukan / hilang / salah lokasi / rusak (rusak -> tiket kerusakan)
--   * Total biaya perawatan per aset (bahan keputusan ganti baru vs servis)
--   Izin baru: asset.audit (ikut opname aset). Lapor kerusakan: semua user yang punya akses outlet aset.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABEL
-- ---------------------------------------------------------------------
create table ast_maintenance_plans (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  asset_id          uuid not null references ast_assets(id) on delete cascade,
  title             text not null check (trim(title) <> ''),
  description       text,
  interval_value    int not null check (interval_value between 1 and 365),
  interval_unit     text not null check (interval_unit in ('day', 'week', 'month')),
  next_due_date     date not null,
  lead_days         int not null default 3 check (lead_days between 0 and 60),   -- tugas dibuat H-x
  assignee_user_id  uuid references sys_users(id) on delete set null,
  assignee_role_id  uuid references sys_roles(id) on delete set null,
  checklist         jsonb not null default '[]',      -- ["langkah", ...]
  requires_photo    boolean not null default false,
  vendor            text,
  estimated_cost    numeric(15,2),
  open_task_id      uuid references hr_tasks(id) on delete set null,
  last_done_on      date,
  is_active         boolean not null default true,
  created_by        uuid references sys_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index idx_ast_maintenance_plans_due on ast_maintenance_plans(company_id, is_active, next_due_date);

create table ast_maintenance_logs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  asset_id      uuid not null references ast_assets(id) on delete cascade,
  plan_id       uuid references ast_maintenance_plans(id) on delete set null,
  task_id       uuid references hr_tasks(id) on delete set null,
  kind          text not null check (kind in ('scheduled', 'manual', 'skipped')),
  title         text not null,
  performed_on  date not null,
  performed_by  uuid references sys_users(id),
  vendor        text,
  cost          numeric(15,2) not null default 0 check (cost >= 0),
  note          text,
  journal_id    uuid references fin_journals(id) on delete set null,
  created_by    uuid references sys_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index idx_ast_maintenance_logs_asset on ast_maintenance_logs(asset_id, performed_on);

create table ast_repairs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  repair_number text not null,
  asset_id      uuid not null references ast_assets(id) on delete cascade,
  severity      text not null check (severity in ('minor', 'major', 'down')),   -- masih bisa dipakai / terganggu / mati total
  description   text not null check (trim(description) <> ''),
  photo_path    text,
  status        text not null default 'open' check (status in ('open', 'in_progress', 'waiting_parts', 'done', 'cancelled')),
  reported_by   uuid references sys_users(id),
  reported_at   timestamptz not null default now(),
  task_id       uuid references hr_tasks(id) on delete set null,
  vendor        text,
  resolution    text,
  cost          numeric(15,2) not null default 0 check (cost >= 0),
  journal_id    uuid references fin_journals(id) on delete set null,
  resolved_at   timestamptz,
  resolved_by   uuid references sys_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, repair_number)
);
create index idx_ast_repairs_asset on ast_repairs(asset_id, status);

create table ast_audits (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  audit_number  text not null,
  outlet_id     uuid references sys_outlets(id),        -- null = aset kantor pusat
  status        text not null default 'open' check (status in ('open', 'closed')),
  note          text,
  started_by    uuid references sys_users(id),
  started_at    timestamptz not null default now(),
  closed_by     uuid references sys_users(id),
  closed_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, audit_number)
);
create unique index uq_ast_audits_open on ast_audits(company_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status = 'open';

create table ast_audit_items (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  audit_id        uuid not null references ast_audits(id) on delete cascade,
  asset_id        uuid not null references ast_assets(id) on delete cascade,
  expected        boolean not null,                     -- tercatat di outlet ini saat opname dimulai
  result          text not null default 'pending' check (result in ('pending', 'found', 'missing', 'unexpected')),
  condition       text check (condition in ('good', 'damaged')),
  found_location  text,
  note            text,
  scanned_by      uuid references sys_users(id),
  scanned_at      timestamptz,
  unique (audit_id, asset_id)
);

select sys_attach_updated_at_triggers();

do $$
declare t text;
begin
  foreach t in array array['ast_maintenance_plans', 'ast_maintenance_logs', 'ast_repairs', 'ast_audits', 'ast_audit_items'] loop
    perform sys_apply_company_policies(t);
    execute format('drop policy %I on %I', t || '_select', t);
    execute format('create policy %I on %I for select to authenticated using (company_id = sys_current_company_id() and ast_can_view())',
      t || '_select', t);
  end loop;
end $$;
select sys_apply_outlet_lock('ast_maintenance_plans', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_maintenance_logs', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_repairs', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_audits', 'outlet_id is null or sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('ast_audit_items', 'exists (select 1 from ast_audits x where x.id = audit_id)');

-- ---------------------------------------------------------------------
-- BANTUAN
-- ---------------------------------------------------------------------
-- user ini boleh menyentuh aset (outlet aset bisa diakses)
create or replace function ast_asset_reachable(p_asset_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from ast_assets a where a.id = p_asset_id and a.company_id = sys_current_company_id()
                 and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)))
$$;

create or replace function ast_can_audit()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('asset.manage') or sys_has_permission('asset.audit')
$$;

create or replace function ast_add_interval(p_date date, p_value int, p_unit text)
returns date language sql immutable as $$
  select (p_date + case p_unit when 'day' then make_interval(days => p_value) when 'week' then make_interval(weeks => p_value)
                    else make_interval(months => p_value) end)::date
$$;

-- jadwal berikutnya setelah dikerjakan: maju dari tanggal jatuh tempo sampai melewati tanggal dikerjakan
create or replace function ast_next_due(p_due date, p_done date, p_value int, p_unit text)
returns date language plpgsql immutable as $$
declare v date := ast_add_interval(p_due, p_value, p_unit); n int := 0;
begin
  while v <= p_done and n < 1000 loop v := ast_add_interval(v, p_value, p_unit); n := n + 1; end loop;
  return v;
end $$;

-- jurnal biaya perawatan / perbaikan: Dr Beban Perbaikan & Perawatan / Cr Kas-Bank (dibuat ulang bila diubah)
create or replace function ast_post_cost(p_company uuid, p_outlet uuid, p_date date, p_source_type text, p_source_id uuid,
  p_desc text, p_amount numeric, p_account uuid, p_old_journal uuid)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  -- jurnal lama (p_old_journal) sudah dilepas & dihapus pemanggil sebelum memanggil fungsi ini
  if coalesce(p_amount, 0) <= 0 or p_account is null then return null; end if;
  perform ast_check_account(p_account, array['asset'], 'Akun kas / bank pembayar');
  if sys_approval_required('expense', p_amount) then
    raise exception 'Biaya Rp % perlu persetujuan. Catat pembayarannya lewat Keuangan → Biaya, lalu simpan biaya di sini tanpa jurnal.',
      to_char(p_amount, 'FM999G999G999G990');
  end if;
  return fin_create_journal(p_company, p_outlet, p_date, p_source_type, p_source_id, p_desc,
    jsonb_build_array(jsonb_build_object('account_id', fin_account_id(p_company, 'maintenance_expense'), 'debit', p_amount, 'note', p_desc),
                      jsonb_build_object('account_id', p_account, 'credit', p_amount)));
end $$;

-- buat tugas di menu Tugas (pembuat = pengelola aset, supaya review tidak jatuh ke pelapor / user acak)
create or replace function ast_create_task(p_company uuid, p_title text, p_desc text, p_priority text, p_outlet uuid,
  p_user uuid, p_role uuid, p_due date, p_checklist jsonb, p_photo boolean, p_link_label text, p_link_url text, p_creator uuid, p_label text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into hr_tasks (company_id, title, description, priority, outlet_id, assignee_id, assignee_role_id, due_date, labels, checklist,
    requires_photo, link_label, link_url, created_by)
  values (p_company, left(p_title, 200), coalesce(p_desc, ''), p_priority, p_outlet, p_user, case when p_user is null then p_role end, p_due,
    array[p_label], coalesce(p_checklist, '[]'::jsonb), coalesce(p_photo, false), p_link_label, p_link_url, p_creator)
  returning id into v_id;
  insert into hr_task_comments (task_id, user_id, kind, body) values (v_id, p_creator, 'event', 'dibuat otomatis dari modul Aset');
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- JADWAL PERAWATAN
-- ---------------------------------------------------------------------
create or replace function ast_save_plan(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); v ast_maintenance_plans; a ast_assets;
  v_user uuid := nullif(p->>'assignee_user_id', '')::uuid; v_role uuid := nullif(p->>'assignee_role_id', '')::uuid;
  v_unit text := coalesce(nullif(p->>'interval_unit', ''), 'month');
  v_due date := nullif(p->>'next_due_date', '')::date;
begin
  perform ast_require_manage();
  if nullif(p->>'id', '') is not null then
    select * into v from ast_maintenance_plans where id = (p->>'id')::uuid and company_id = v_c for update;
    if v.id is null or not ast_asset_reachable(v.asset_id) then raise exception 'Jadwal tidak ditemukan'; end if;
  end if;
  select * into a from ast_assets where id = coalesce(v.asset_id, (p->>'asset_id')::uuid) and company_id = v_c;
  if a.id is null or not ast_asset_reachable(a.id) then raise exception 'Aset tidak ditemukan'; end if;
  if a.status <> 'active' then raise exception 'Aset sudah dilepas'; end if;
  if coalesce(trim(p->>'title'), '') = '' then raise exception 'Nama perawatan wajib diisi, mis. Service AC'; end if;
  if coalesce((p->>'interval_value')::int, 0) not between 1 and 365 then raise exception 'Interval 1-365'; end if;
  if v_unit not in ('day', 'week', 'month') then raise exception 'Satuan interval tidak dikenal'; end if;
  if v_due is null then raise exception 'Tanggal jatuh tempo berikutnya wajib diisi'; end if;
  if v_user is not null and not exists (select 1 from sys_users where id = v_user and company_id = v_c and is_active) then raise exception 'Penanggung jawab tidak ditemukan'; end if;
  if v_role is not null and not exists (select 1 from sys_roles where id = v_role and company_id = v_c) then raise exception 'Tim tidak ditemukan'; end if;
  if v.id is null then
    insert into ast_maintenance_plans (company_id, asset_id, title, description, interval_value, interval_unit, next_due_date, lead_days,
      assignee_user_id, assignee_role_id, checklist, requires_photo, vendor, estimated_cost, created_by)
    values (v_c, a.id, trim(p->>'title'), nullif(trim(coalesce(p->>'description', '')), ''), (p->>'interval_value')::int, v_unit, v_due,
      coalesce(nullif(p->>'lead_days', '')::int, 3), v_user, case when v_user is null then v_role end, coalesce(p->'checklist', '[]'::jsonb),
      coalesce((p->>'requires_photo')::boolean, false), nullif(trim(coalesce(p->>'vendor', '')), ''), nullif(p->>'estimated_cost', '')::numeric, auth.uid())
    returning * into v;
    perform ast_log(a.id, 'plan', 'Jadwal perawatan dibuat: ' || v.title || ' tiap ' || v.interval_value || ' '
      || case v.interval_unit when 'day' then 'hari' when 'week' then 'minggu' else 'bulan' end);
  else
    update ast_maintenance_plans set title = trim(p->>'title'), description = nullif(trim(coalesce(p->>'description', '')), ''),
      interval_value = (p->>'interval_value')::int, interval_unit = v_unit, next_due_date = v_due,
      lead_days = coalesce(nullif(p->>'lead_days', '')::int, lead_days), assignee_user_id = v_user, assignee_role_id = case when v_user is null then v_role end,
      checklist = coalesce(p->'checklist', checklist), requires_photo = coalesce((p->>'requires_photo')::boolean, requires_photo),
      vendor = nullif(trim(coalesce(p->>'vendor', '')), ''), estimated_cost = nullif(p->>'estimated_cost', '')::numeric,
      is_active = coalesce((p->>'is_active')::boolean, is_active)
    where id = v.id returning * into v;
  end if;
  perform ast_sync_maintenance();
  return to_jsonb((select x from ast_maintenance_plans x where x.id = v.id));
end $$;

-- buat tugas perawatan yang sudah mendekati jatuh tempo (dipanggil saat halaman Tugas / Aset / Beranda dibuka)
create or replace function ast_sync_maintenance()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
  r record; v_task uuid; v_n int := 0;
begin
  if v_c is null then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('ast_sync_' || v_c::text));
  for r in
    select pl.*, a.asset_number, a.name as asset_name, a.outlet_id, a.location, a.pic_user_id, a.created_by as asset_creator
    from ast_maintenance_plans pl join ast_assets a on a.id = pl.asset_id
    where pl.company_id = v_c and pl.is_active and a.status = 'active' and pl.open_task_id is null
      and pl.next_due_date - pl.lead_days <= v_today
    for update of pl
  loop
    v_task := ast_create_task(v_c, r.title || ' · ' || r.asset_name,
      concat_ws(E'\n', 'Perawatan rutin aset ' || r.asset_number || ' ' || r.asset_name || coalesce(' (' || r.location || ')', '') || '.',
        r.description, case when r.vendor is not null then 'Vendor: ' || r.vendor end,
        case when r.estimated_cost is not null then 'Perkiraan biaya: Rp ' || to_char(r.estimated_cost, 'FM999G999G999G990') end),
      case when r.next_due_date < v_today then 'high' else 'normal' end, r.outlet_id,
      coalesce(r.assignee_user_id, case when r.assignee_role_id is null then r.pic_user_id end), r.assignee_role_id, r.next_due_date,
      (select coalesce(jsonb_agg(jsonb_build_object('text', x, 'done', false)), '[]'::jsonb) from jsonb_array_elements_text(r.checklist) x),
      r.requires_photo, r.asset_number, '/aset/' || r.asset_number, coalesce(r.created_by, r.asset_creator), 'perawatan');
    update ast_maintenance_plans set open_task_id = v_task where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- tugas perawatan / perbaikan selesai (atau diarsipkan) -> riwayat & jadwal berikutnya
create or replace function ast_on_task_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare pl ast_maintenance_plans; v_done date := coalesce((new.done_at at time zone 'Asia/Jakarta')::date, (now() at time zone 'Asia/Jakarta')::date);
begin
  select * into pl from ast_maintenance_plans where open_task_id = new.id for update;
  if pl.id is not null then
    insert into ast_maintenance_logs (company_id, asset_id, plan_id, task_id, kind, title, performed_on, performed_by, vendor, note, created_by)
    values (pl.company_id, pl.asset_id, pl.id, new.id, case when new.status = 'done' then 'scheduled' else 'skipped' end, pl.title, v_done,
      case when new.status = 'done' then coalesce(new.assignee_id, new.done_by) end, pl.vendor,
      case when new.status = 'done' then 'Tugas ' || new.task_number || ' selesai' else 'Tugas ' || new.task_number || ' diarsipkan (dilewati)' end, new.done_by);
    update ast_maintenance_plans set open_task_id = null,
      last_done_on = case when new.status = 'done' then v_done else last_done_on end,
      next_due_date = ast_next_due(next_due_date, v_done, interval_value, interval_unit)
    where id = pl.id;
    perform ast_log(pl.asset_id, 'maintenance', pl.title || case when new.status = 'done' then ' selesai (' || new.task_number || ')' else ' dilewati (' || new.task_number || ')' end);
  end if;
  -- tiket kerusakan ikut selesai / batal
  update ast_repairs set status = case when new.status = 'done' then 'done' else 'cancelled' end,
    resolved_at = coalesce(resolved_at, now()), resolved_by = coalesce(resolved_by, new.done_by)
  where task_id = new.id and status not in ('done', 'cancelled');
  return new;
end $$;
create trigger trg_hr_tasks_assets after update of status on hr_tasks
  for each row when (new.status in ('done', 'archived') and old.status is distinct from new.status)
  execute function ast_on_task_status();

-- riwayat perawatan manual / isi biaya pada riwayat
create or replace function ast_save_log(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); l ast_maintenance_logs; a ast_assets;
  v_cost numeric := round(coalesce(nullif(p->>'cost', '')::numeric, 0), 2);
  v_date date := coalesce(nullif(p->>'performed_on', '')::date, (now() at time zone 'Asia/Jakarta')::date);
begin
  perform ast_require_manage();
  if nullif(p->>'id', '') is not null then
    select * into l from ast_maintenance_logs where id = (p->>'id')::uuid and company_id = v_c for update;
    if l.id is null or not ast_asset_reachable(l.asset_id) then raise exception 'Riwayat tidak ditemukan'; end if;
  end if;
  select * into a from ast_assets where id = coalesce(l.asset_id, (p->>'asset_id')::uuid) and company_id = v_c;
  if a.id is null or not ast_asset_reachable(a.id) then raise exception 'Aset tidak ditemukan'; end if;
  if v_cost < 0 then raise exception 'Biaya tidak valid'; end if;
  if v_date > (now() at time zone 'Asia/Jakarta')::date then raise exception 'Tanggal tidak boleh di masa depan'; end if;
  if l.id is null then
    if coalesce(trim(p->>'title'), '') = '' then raise exception 'Isi pekerjaan perawatan, mis. Ganti freon'; end if;
    insert into ast_maintenance_logs (company_id, asset_id, kind, title, performed_on, performed_by, vendor, cost, note, created_by)
    values (v_c, a.id, 'manual', trim(p->>'title'), v_date, coalesce(nullif(p->>'performed_by', '')::uuid, auth.uid()),
      nullif(trim(coalesce(p->>'vendor', '')), ''), v_cost, nullif(trim(coalesce(p->>'note', '')), ''), auth.uid())
    returning * into l;
    perform ast_log(a.id, 'maintenance', 'Perawatan dicatat: ' || l.title || case when v_cost > 0 then ' · Rp ' || to_char(v_cost, 'FM999G999G999G990') else '' end);
  else
    update ast_maintenance_logs set title = coalesce(nullif(trim(coalesce(p->>'title', '')), ''), title), performed_on = v_date,
      vendor = nullif(trim(coalesce(p->>'vendor', '')), ''), cost = v_cost, note = nullif(trim(coalesce(p->>'note', '')), '')
    where id = l.id returning * into l;
  end if;
  if l.journal_id is not null then
    update ast_maintenance_logs set journal_id = null where id = l.id;
    delete from fin_journals where id = l.journal_id;
  end if;
  update ast_maintenance_logs set journal_id = ast_post_cost(v_c, a.outlet_id, l.performed_on, 'asset_maintenance', l.id,
      'Perawatan ' || a.asset_number || ' ' || a.name || ': ' || l.title, case when (p->>'record_journal')::boolean then v_cost else 0 end,
      nullif(p->>'paid_from_account_id', '')::uuid, null)
  where id = l.id returning * into l;
  return to_jsonb(l);
end $$;

-- ---------------------------------------------------------------------
-- LAPORAN KERUSAKAN
-- ---------------------------------------------------------------------
create or replace function ast_report_damage(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); a ast_assets; r ast_repairs;
  v_sev text := coalesce(nullif(p->>'severity', ''), 'major');
  v_photo text := nullif(p->>'photo_path', '');
begin
  if v_c is null then raise exception 'Belum login'; end if;
  select * into a from ast_assets where id = (p->>'asset_id')::uuid and company_id = v_c;
  if a.id is null or not ast_asset_reachable(a.id) then raise exception 'Aset tidak ditemukan'; end if;
  if a.status <> 'active' then raise exception 'Aset sudah dilepas'; end if;
  if v_sev not in ('minor', 'major', 'down') then raise exception 'Tingkat kerusakan tidak dikenal'; end if;
  if coalesce(trim(p->>'description'), '') = '' then raise exception 'Ceritakan kerusakannya'; end if;
  if v_photo is not null and v_photo not like v_c::text || '/' || a.id::text || '/%' then raise exception 'Foto tidak valid'; end if;
  if exists (select 1 from ast_repairs where asset_id = a.id and status in ('open', 'in_progress', 'waiting_parts') and reported_at > now() - interval '10 minutes'
             and reported_by = auth.uid()) then
    raise exception 'Kerusakan aset ini baru saja Anda laporkan';
  end if;
  insert into ast_repairs (company_id, repair_number, asset_id, severity, description, photo_path, reported_by)
  values (v_c, sys_next_document_number(v_c, 'KRS', (now() at time zone 'Asia/Jakarta')::date), a.id, v_sev, trim(p->>'description'), v_photo, auth.uid())
  returning * into r;
  update ast_repairs set task_id = ast_create_task(v_c, 'Perbaikan: ' || a.name,
      concat_ws(E'\n', 'Laporan kerusakan ' || r.repair_number || ' oleh ' || coalesce((select full_name from sys_users where id = auth.uid()), '-') || ':',
        trim(p->>'description'), 'Aset ' || a.asset_number || coalesce(' · ' || a.location, '') || ' · ' ||
        case v_sev when 'down' then 'MATI TOTAL' when 'major' then 'terganggu' else 'masih bisa dipakai' end),
      case v_sev when 'down' then 'urgent' when 'major' then 'high' else 'normal' end, a.outlet_id, a.pic_user_id, null,
      (now() at time zone 'Asia/Jakarta')::date + case v_sev when 'down' then 0 when 'major' then 2 else 7 end,
      '[]'::jsonb, false, r.repair_number, '/aset/' || a.asset_number, coalesce(a.created_by, auth.uid()), 'perbaikan')
  where id = r.id returning * into r;
  perform ast_log(a.id, 'damage', 'Kerusakan dilaporkan (' || r.repair_number || '): ' || left(trim(p->>'description'), 120));
  return to_jsonb(r);
end $$;

create or replace function ast_update_repair(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); r ast_repairs; a ast_assets;
  v_status text := coalesce(nullif(p->>'status', ''), 'open');
  v_cost numeric := round(coalesce(nullif(p->>'cost', '')::numeric, 0), 2);
  v_date date := coalesce(nullif(p->>'cost_date', '')::date, (now() at time zone 'Asia/Jakarta')::date);
begin
  perform ast_require_manage();
  select * into r from ast_repairs where id = (p->>'id')::uuid and company_id = v_c for update;
  if r.id is null or not ast_asset_reachable(r.asset_id) then raise exception 'Laporan kerusakan tidak ditemukan'; end if;
  select * into a from ast_assets where id = r.asset_id;
  if v_status not in ('open', 'in_progress', 'waiting_parts', 'done', 'cancelled') then raise exception 'Status tidak dikenal'; end if;
  if v_cost < 0 then raise exception 'Biaya tidak valid'; end if;
  update ast_repairs set status = v_status, vendor = nullif(trim(coalesce(p->>'vendor', '')), ''), resolution = nullif(trim(coalesce(p->>'resolution', '')), ''),
    cost = v_cost,
    resolved_at = case when v_status in ('done', 'cancelled') then coalesce(resolved_at, now()) else null end,
    resolved_by = case when v_status in ('done', 'cancelled') then coalesce(resolved_by, auth.uid()) else null end
  where id = r.id returning * into r;
  if r.journal_id is not null then
    update ast_repairs set journal_id = null where id = r.id;
    delete from fin_journals where id = r.journal_id;
  end if;
  update ast_repairs set journal_id = ast_post_cost(v_c, a.outlet_id, v_date, 'asset_repair', r.id,
      'Perbaikan ' || a.asset_number || ' ' || a.name || ' (' || r.repair_number || ')', case when (p->>'record_journal')::boolean then v_cost else 0 end,
      nullif(p->>'paid_from_account_id', '')::uuid, null)
  where id = r.id returning * into r;
  -- tugas perbaikan ikut ditutup bila tiket selesai / batal dari sini
  if v_status in ('done', 'cancelled') and r.task_id is not null then
    update hr_tasks set status = case when v_status = 'done' then 'done' else 'archived' end,
      done_at = case when v_status = 'done' then coalesce(done_at, now()) else done_at end, done_by = coalesce(done_by, auth.uid())
    where id = r.task_id and status not in ('done', 'archived');
    if found then perform hr_task_log(r.task_id, case when v_status = 'done' then 'ditutup dari modul Aset (perbaikan selesai)' else 'dibatalkan dari modul Aset' end); end if;
  end if;
  perform ast_log(a.id, 'repair', r.repair_number || ': ' || case v_status when 'open' then 'dibuka' when 'in_progress' then 'sedang diperbaiki'
    when 'waiting_parts' then 'menunggu suku cadang' when 'done' then 'selesai' else 'dibatalkan' end
    || case when v_cost > 0 then ' · biaya Rp ' || to_char(v_cost, 'FM999G999G999G990') else '' end);
  return to_jsonb(r);
end $$;

-- ---------------------------------------------------------------------
-- OPNAME ASET
-- ---------------------------------------------------------------------
create or replace function ast_audit_start(p_outlet_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); x ast_audits;
begin
  if v_c is null or not ast_can_audit() then raise exception 'Butuh izin opname aset'; end if;
  if p_outlet_id is not null and not exists (select 1 from sys_outlets where id = p_outlet_id and company_id = v_c) then raise exception 'Outlet tidak ditemukan'; end if;
  if p_outlet_id is not null and not sys_can_access_outlet(p_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  if p_outlet_id is null and not sys_user_all_outlets() then raise exception 'Pilih outlet'; end if;
  if exists (select 1 from ast_audits where company_id = v_c and outlet_id is not distinct from p_outlet_id and status = 'open') then
    raise exception 'Masih ada opname yang terbuka untuk lokasi ini';
  end if;
  insert into ast_audits (company_id, audit_number, outlet_id, note, started_by)
  values (v_c, sys_next_document_number(v_c, 'OPA', (now() at time zone 'Asia/Jakarta')::date), p_outlet_id, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning * into x;
  insert into ast_audit_items (company_id, audit_id, asset_id, expected)
  select v_c, x.id, a.id, true from ast_assets a where a.company_id = v_c and a.status = 'active' and a.outlet_id is not distinct from p_outlet_id;
  return to_jsonb(x) || jsonb_build_object('items', (select count(*) from ast_audit_items where audit_id = x.id));
end $$;

create or replace function ast_audit_scan(p_audit_id uuid, p_code text, p_condition text default 'good', p_location text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); x ast_audits; a ast_assets; it ast_audit_items; v_cond text := coalesce(nullif(p_condition, ''), 'good');
begin
  if v_c is null or not ast_can_audit() then raise exception 'Butuh izin opname aset'; end if;
  select * into x from ast_audits where id = p_audit_id and company_id = v_c;
  if x.id is null or not (x.outlet_id is null or sys_can_access_outlet(x.outlet_id)) then raise exception 'Opname tidak ditemukan'; end if;
  if x.status <> 'open' then raise exception 'Opname sudah ditutup'; end if;
  if v_cond not in ('good', 'damaged') then raise exception 'Kondisi tidak dikenal'; end if;
  select * into a from ast_assets where company_id = v_c and (upper(asset_number) = upper(trim(p_code)) or id::text = trim(p_code)) limit 1;
  if a.id is null then raise exception 'Kode % tidak dikenal', trim(p_code); end if;
  if a.status <> 'active' then raise exception '% % sudah dilepas', a.asset_number, a.name; end if;
  insert into ast_audit_items (company_id, audit_id, asset_id, expected, result)
  values (v_c, x.id, a.id, false, 'unexpected')
  on conflict (audit_id, asset_id) do nothing;
  update ast_audit_items set result = case when expected then 'found' else 'unexpected' end, condition = v_cond,
    found_location = coalesce(nullif(trim(coalesce(p_location, '')), ''), found_location), note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note),
    scanned_by = auth.uid(), scanned_at = now()
  where audit_id = x.id and asset_id = a.id returning * into it;
  -- rusak saat opname -> tiket kerusakan (bila belum ada yang terbuka)
  if v_cond = 'damaged' and ast_asset_reachable(a.id)
     and not exists (select 1 from ast_repairs where asset_id = a.id and status in ('open', 'in_progress', 'waiting_parts')) then
    perform ast_report_damage(jsonb_build_object('asset_id', a.id, 'severity', 'major',
      'description', coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Ditemukan rusak saat opname') || ' (opname ' || x.audit_number || ')'));
  end if;
  return to_jsonb(it) || jsonb_build_object('asset_number', a.asset_number, 'name', a.name, 'registered_outlet', (select name from sys_outlets where id = a.outlet_id));
end $$;

create or replace function ast_audit_close(p_audit_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); x ast_audits;
begin
  if v_c is null or not ast_can_audit() then raise exception 'Butuh izin opname aset'; end if;
  select * into x from ast_audits where id = p_audit_id and company_id = v_c for update;
  if x.id is null or not (x.outlet_id is null or sys_can_access_outlet(x.outlet_id)) then raise exception 'Opname tidak ditemukan'; end if;
  if x.status <> 'open' then raise exception 'Opname sudah ditutup'; end if;
  update ast_audit_items set result = 'missing' where audit_id = x.id and result = 'pending';
  update ast_audits set status = 'closed', closed_by = auth.uid(), closed_at = now() where id = x.id;
  perform sys_log_activity(v_c, 'close', 'ast_audits', x.id, 'Opname aset ' || x.audit_number, null);
  return ast_audit_detail(x.id);
end $$;

create or replace function ast_audit_detail(p_audit_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare x ast_audits;
begin
  if not (ast_can_view() or ast_can_audit()) then raise exception 'Butuh izin lihat aset'; end if;
  select * into x from ast_audits where id = p_audit_id and company_id = sys_current_company_id();
  if x.id is null or not (x.outlet_id is null or sys_can_access_outlet(x.outlet_id)) then raise exception 'Opname tidak ditemukan'; end if;
  return to_jsonb(x) || jsonb_build_object(
    'outlet', coalesce((select name from sys_outlets where id = x.outlet_id), 'Kantor pusat'),
    'started_by_name', (select full_name from sys_users where id = x.started_by),
    'summary', (select jsonb_build_object('total', count(*) filter (where expected), 'found', count(*) filter (where result = 'found'),
        'pending', count(*) filter (where result = 'pending'), 'missing', count(*) filter (where result = 'missing'),
        'unexpected', count(*) filter (where result = 'unexpected'), 'damaged', count(*) filter (where condition = 'damaged'))
      from ast_audit_items where audit_id = x.id),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'asset_id', a.id, 'asset_number', a.asset_number, 'name', a.name,
        'category', k.name, 'location', a.location, 'registered_outlet', coalesce(o.name, 'Kantor pusat'), 'registered_outlet_id', a.outlet_id,
        'asset_status', a.status, 'expected', i.expected, 'result', i.result, 'condition', i.condition, 'found_location', i.found_location,
        'note', i.note, 'scanned_by', u.full_name, 'scanned_at', i.scanned_at)
        order by case i.result when 'pending' then 0 when 'unexpected' then 1 when 'missing' then 2 else 3 end, a.asset_number)
      from ast_audit_items i join ast_assets a on a.id = i.asset_id join ast_categories k on k.id = a.category_id
      left join sys_outlets o on o.id = a.outlet_id left join sys_users u on u.id = i.scanned_by where i.audit_id = x.id), '[]'::jsonb));
end $$;

create or replace function ast_audit_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (ast_can_view() or ast_can_audit()) then raise exception 'Butuh izin lihat aset'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'audit_number', x.audit_number, 'status', x.status,
      'outlet', coalesce(o.name, 'Kantor pusat'), 'outlet_id', x.outlet_id, 'started_at', x.started_at, 'closed_at', x.closed_at,
      'started_by', u.full_name, 'note', x.note,
      'total', (select count(*) from ast_audit_items i where i.audit_id = x.id and i.expected),
      'found', (select count(*) from ast_audit_items i where i.audit_id = x.id and i.result = 'found'),
      'missing', (select count(*) from ast_audit_items i where i.audit_id = x.id and i.result = 'missing'),
      'unexpected', (select count(*) from ast_audit_items i where i.audit_id = x.id and i.result = 'unexpected')) order by x.started_at desc)
    from ast_audits x left join sys_outlets o on o.id = x.outlet_id left join sys_users u on u.id = x.started_by
    where x.company_id = sys_current_company_id() and (x.outlet_id is null or sys_can_access_outlet(x.outlet_id))), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- BACA
-- ---------------------------------------------------------------------
-- halaman scan QR (/aset/<kode>) untuk semua karyawan: info ringkas tanpa angka keuangan
create or replace function ast_scan_info(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); a ast_assets;
begin
  if v_c is null then raise exception 'Belum login'; end if;
  select * into a from ast_assets where company_id = v_c and (upper(asset_number) = upper(trim(p_code)) or id::text = trim(p_code)) limit 1;
  if a.id is null or not ast_asset_reachable(a.id) then raise exception 'Aset tidak ditemukan atau di luar outlet Anda'; end if;
  return jsonb_build_object('id', a.id, 'asset_number', a.asset_number, 'name', a.name, 'status', a.status,
    'category', (select name from ast_categories where id = a.category_id), 'outlet', coalesce((select name from sys_outlets where id = a.outlet_id), 'Kantor pusat'),
    'location', a.location, 'brand_model', a.brand_model, 'serial_number', a.serial_number, 'photo_path', a.photo_path,
    'pic', (select full_name from sys_users where id = a.pic_user_id), 'warranty_until', a.warranty_until,
    'repairs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.repair_number, 'severity', r.severity, 'status', r.status,
        'description', r.description, 'reported_at', r.reported_at, 'reported_by', u.full_name) order by r.reported_at desc)
      from ast_repairs r left join sys_users u on u.id = r.reported_by where r.asset_id = a.id and r.status in ('open', 'in_progress', 'waiting_parts')), '[]'::jsonb),
    'next_maintenance', (select jsonb_build_object('title', title, 'due', next_due_date) from ast_maintenance_plans
      where asset_id = a.id and is_active order by next_due_date limit 1),
    'can_view', ast_can_view(),
    'open_audit', case when ast_can_audit() then (select jsonb_build_object('id', x.id, 'number', x.audit_number) from ast_audits x
      where x.company_id = v_c and x.status = 'open' and x.outlet_id is not distinct from a.outlet_id limit 1) end);
end $$;

-- perawatan & kerusakan untuk detail aset
create or replace function ast_maintenance_detail(p_asset_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  if not ast_asset_reachable(p_asset_id) then raise exception 'Aset tidak ditemukan'; end if;
  return jsonb_build_object(
    'plans', coalesce((select jsonb_agg(to_jsonb(pl) || jsonb_build_object('assignee', coalesce(u.full_name, 'Tim ' || ro.name),
        'open_task_number', t.task_number, 'open_task_status', t.status) order by pl.is_active desc, pl.next_due_date)
      from ast_maintenance_plans pl left join sys_users u on u.id = pl.assignee_user_id left join sys_roles ro on ro.id = pl.assignee_role_id
      left join hr_tasks t on t.id = pl.open_task_id where pl.asset_id = p_asset_id), '[]'::jsonb),
    'logs', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('performed_by_name', u.full_name, 'journal_number', j.journal_number,
        'task_number', t.task_number) order by l.performed_on desc, l.created_at desc)
      from ast_maintenance_logs l left join sys_users u on u.id = l.performed_by left join fin_journals j on j.id = l.journal_id
      left join hr_tasks t on t.id = l.task_id where l.asset_id = p_asset_id), '[]'::jsonb),
    'repairs', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('reported_by_name', u.full_name, 'task_number', t.task_number,
        'task_status', t.status, 'journal_number', j.journal_number,
        'downtime_hours', round(extract(epoch from (coalesce(r.resolved_at, now()) - r.reported_at)) / 3600)) order by r.reported_at desc)
      from ast_repairs r left join sys_users u on u.id = r.reported_by left join hr_tasks t on t.id = r.task_id
      left join fin_journals j on j.id = r.journal_id where r.asset_id = p_asset_id), '[]'::jsonb),
    'total_cost', (select coalesce(sum(cost), 0) from ast_maintenance_logs where asset_id = p_asset_id)
      + (select coalesce(sum(cost), 0) from ast_repairs where asset_id = p_asset_id));
end $$;

-- ringkasan perawatan & kerusakan semua aset (tab Perawatan)
create or replace function ast_maintenance_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if v_c is null or not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return jsonb_build_object(
    'plans', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'asset_id', a.id, 'asset_number', a.asset_number, 'asset', a.name,
        'outlet', coalesce(o.name, 'Kantor pusat'), 'title', pl.title, 'next_due_date', pl.next_due_date, 'interval_value', pl.interval_value,
        'interval_unit', pl.interval_unit, 'assignee', coalesce(u.full_name, 'Tim ' || ro.name), 'open_task_number', t.task_number,
        'open_task_status', t.status, 'last_done_on', pl.last_done_on, 'overdue', pl.next_due_date < v_today) order by pl.next_due_date)
      from ast_maintenance_plans pl join ast_assets a on a.id = pl.asset_id left join sys_outlets o on o.id = a.outlet_id
      left join sys_users u on u.id = pl.assignee_user_id left join sys_roles ro on ro.id = pl.assignee_role_id left join hr_tasks t on t.id = pl.open_task_id
      where pl.company_id = v_c and pl.is_active and a.status = 'active' and ast_asset_reachable(a.id)), '[]'::jsonb),
    'repairs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'asset_id', a.id, 'asset_number', a.asset_number, 'asset', a.name,
        'outlet', coalesce(o.name, 'Kantor pusat'), 'number', r.repair_number, 'severity', r.severity, 'status', r.status, 'description', r.description,
        'reported_at', r.reported_at, 'reported_by', u.full_name, 'task_number', t.task_number, 'cost', r.cost, 'vendor', r.vendor,
        'resolution', r.resolution, 'resolved_at', r.resolved_at, 'photo_path', r.photo_path,
        'downtime_hours', round(extract(epoch from (coalesce(r.resolved_at, now()) - r.reported_at)) / 3600))
        order by r.status in ('done', 'cancelled'), case r.severity when 'down' then 0 when 'major' then 1 else 2 end, r.reported_at desc)
      from ast_repairs r join ast_assets a on a.id = r.asset_id left join sys_outlets o on o.id = a.outlet_id
      left join sys_users u on u.id = r.reported_by left join hr_tasks t on t.id = r.task_id
      where r.company_id = v_c and ast_asset_reachable(a.id)
        and (r.status in ('open', 'in_progress', 'waiting_parts') or r.reported_at > now() - interval '60 days')), '[]'::jsonb),
    -- aset dengan biaya perawatan + perbaikan terbesar 12 bulan terakhir (pertimbangan ganti baru)
    'top_cost', coalesce((select jsonb_agg(z order by (z->>'total')::numeric desc) from (
        select jsonb_build_object('asset_id', a.id, 'asset_number', a.asset_number, 'asset', a.name, 'book_value', a.acquisition_cost - a.accumulated_depreciation,
          'acquisition_cost', a.acquisition_cost, 'total', c.total, 'count', c.n) as z
        from ast_assets a join (
          select asset_id, sum(cost) total, count(*) n from (
            select asset_id, cost from ast_maintenance_logs where company_id = v_c and performed_on > v_today - 365 and cost > 0
            union all select asset_id, cost from ast_repairs where company_id = v_c and reported_at > now() - interval '365 days' and cost > 0) s
          group by asset_id) c on c.asset_id = a.id
        where ast_asset_reachable(a.id) order by c.total desc limit 10) q), '[]'::jsonb));
end $$;

-- ringkasan aset + angka perawatan (dipakai kartu peringatan di halaman Aset)
create or replace function ast_maintenance_counts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if v_c is null or not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return jsonb_build_object(
    'perawatan_terlambat', (select count(*) from ast_maintenance_plans pl join ast_assets a on a.id = pl.asset_id
      where pl.company_id = v_c and pl.is_active and a.status = 'active' and pl.next_due_date < v_today and ast_asset_reachable(a.id)),
    'perawatan_7_hari', (select count(*) from ast_maintenance_plans pl join ast_assets a on a.id = pl.asset_id
      where pl.company_id = v_c and pl.is_active and a.status = 'active' and pl.next_due_date between v_today and v_today + 7 and ast_asset_reachable(a.id)),
    'kerusakan_terbuka', (select count(*) from ast_repairs r where r.company_id = v_c and r.status in ('open', 'in_progress', 'waiting_parts') and ast_asset_reachable(r.asset_id)),
    'mati_total', (select count(*) from ast_repairs r where r.company_id = v_c and r.severity = 'down' and r.status in ('open', 'in_progress', 'waiting_parts') and ast_asset_reachable(r.asset_id)),
    'opname_terbuka', (select count(*) from ast_audits x where x.company_id = v_c and x.status = 'open' and (x.outlet_id is null or sys_can_access_outlet(x.outlet_id))));
end $$;

-- aset dilepas -> jadwal perawatan nonaktif, tugas perawatan terbuka diarsipkan
create or replace function ast_on_asset_disposed()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_task uuid;
begin
  for v_task in select open_task_id from ast_maintenance_plans where asset_id = new.id and open_task_id is not null loop
    update ast_maintenance_plans set open_task_id = null where open_task_id = v_task;
    update hr_tasks set status = 'archived' where id = v_task and status not in ('done', 'archived');
    if found then perform hr_task_log(v_task, 'diarsipkan: aset sudah dilepas'); end if;
  end loop;
  update ast_maintenance_plans set is_active = false where asset_id = new.id;
  return new;
end $$;
create trigger trg_ast_assets_disposed after update of status on ast_assets
  for each row when (new.status = 'disposed' and old.status <> 'disposed') execute function ast_on_asset_disposed();

-- ---------------------------------------------------------------------
-- FOTO: semua karyawan dengan akses outlet aset boleh melihat foto & mengunggah foto kerusakan
--   asset-files/<company>/<asset_id>/<file>          (foto aset: kelola aset)
--   asset-files/<company>/<asset_id>/repairs/<file>  (foto kerusakan: semua yang bisa melapor)
-- ---------------------------------------------------------------------
create or replace function ast_file_ok(p_name text, p_write boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and case
       when (storage.foldername(p_name))[2] = 'new' then sys_has_permission('asset.manage')
       when (storage.foldername(p_name))[2] ~ '^[0-9a-f-]{36}$' then
         ast_asset_reachable(((storage.foldername(p_name))[2])::uuid)
         and (not p_write or sys_has_permission('asset.manage') or (storage.foldername(p_name))[3] = 'repairs')
       else false end
$$;

-- ---------------------------------------------------------------------
-- HAK EKSEKUSI
-- ---------------------------------------------------------------------
revoke execute on function ast_post_cost(uuid, uuid, date, text, uuid, text, numeric, uuid, uuid) from public, anon, authenticated;
revoke execute on function ast_create_task(uuid, text, text, text, uuid, uuid, uuid, date, jsonb, boolean, text, text, uuid, text) from public, anon, authenticated;
revoke execute on function ast_on_task_status() from public, anon, authenticated;
revoke execute on function ast_on_asset_disposed() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['ast_asset_reachable(uuid)', 'ast_can_audit()', 'ast_add_interval(date, integer, text)', 'ast_next_due(date, date, integer, text)',
    'ast_save_plan(jsonb)', 'ast_sync_maintenance()', 'ast_save_log(jsonb)', 'ast_report_damage(jsonb)', 'ast_update_repair(jsonb)',
    'ast_audit_start(uuid, text)', 'ast_audit_scan(uuid, text, text, text, text)', 'ast_audit_close(uuid)', 'ast_audit_detail(uuid)',
    'ast_audit_list()', 'ast_scan_info(text)', 'ast_maintenance_detail(uuid)', 'ast_maintenance_overview()', 'ast_maintenance_counts()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- owner/manager sudah punya asset.manage; staf toko boleh ikut opname bila diberi asset.audit
update sys_roles set permissions = permissions || '["asset.audit"]'::jsonb
where code in ('store_manager', 'supervisor') and not permissions ? '*' and not permissions ? 'asset.audit';
update sys_roles set permissions = permissions || '["asset.audit"]'::jsonb
where code = 'warehouse' and not permissions ? '*' and not permissions ? 'asset.audit';
update sys_roles set permissions = permissions || '["asset.manage", "approval.asset_transfer", "approval.asset_disposal"]'::jsonb
where code = 'gm' and not permissions ? '*' and not permissions ? 'asset.manage';
update sys_roles set permissions = permissions || '["asset.manage"]'::jsonb
where code = 'cost_control' and not permissions ? '*' and not permissions ? 'asset.manage';

-- petugas opname (asset.audit) ikut bisa melihat daftar aset
create or replace function ast_can_view()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('asset.view') or sys_has_permission('asset.manage') or sys_has_permission('finance.view')
      or sys_has_permission('asset.audit')
      or sys_has_permission('approval.asset_transfer') or sys_has_permission('approval.asset_disposal')
$$;

-- hapus aset salah input: juga ditolak bila sudah ada riwayat perawatan / laporan kerusakan;
-- tugas perawatan yang masih terbuka ikut diarsipkan
create or replace function ast_delete_asset(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a ast_assets; v_task uuid;
begin
  perform ast_require_manage();
  select * into a from ast_assets where id = p_id and company_id = sys_current_company_id() for update;
  if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
  if exists (select 1 from ast_depreciation_lines where asset_id = p_id) or exists (select 1 from ast_payments where asset_id = p_id)
     or exists (select 1 from ast_transfers where asset_id = p_id and status = 'completed') or exists (select 1 from ast_disposals where asset_id = p_id)
     or exists (select 1 from ast_maintenance_logs where asset_id = p_id) or exists (select 1 from ast_repairs where asset_id = p_id) then
    raise exception 'Aset sudah punya penyusutan / pembayaran / mutasi / perawatan / laporan kerusakan, tidak bisa dihapus. Gunakan Lepas aset.';
  end if;
  update sys_approval_requests set status = 'cancelled', decided_at = now(), decision_note = 'Aset dihapus'
  where document_type = 'asset_transfer' and status = 'pending' and document_id in (select id from ast_transfers where asset_id = p_id);
  for v_task in select open_task_id from ast_maintenance_plans where asset_id = p_id and open_task_id is not null loop
    update hr_tasks set status = 'archived' where id = v_task and status not in ('done', 'archived');
    if found then perform hr_task_log(v_task, 'diarsipkan: aset dihapus'); end if;
  end loop;
  if a.acquisition_journal_id is not null then delete from fin_journals where id = a.acquisition_journal_id; end if;
  delete from ast_assets where id = p_id;
  perform sys_log_activity(a.company_id, 'delete', 'ast_assets', a.id, a.asset_number || ' ' || a.name, null);
end $$;
