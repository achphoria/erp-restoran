-- =====================================================================
-- SANTAP ERP - UPDATE FASE 26 (Tugas kanban & SOP harian)
-- Untuk database yang SUDAH menjalankan fase 1-25.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/036_hr_tasks.sql
-- =====================================================================
-- SEMAR - 036: SDM / HR FASE D - TUGAS (KANBAN) & SOP HARIAN
--   * hr_tasks: tugas dengan alur Baru -> Dikerjakan -> Review -> Selesai -> Arsip.
--     Penerima: satu orang (assignee_id) atau satu tim/role (assignee_role_id, anggota bisa "ambil").
--     Prioritas, tenggat, label, checklist, wajib foto bukti, tautan dokumen, komentar & riwayat.
--     Pengerjaan diajukan ke Review; pembuat / manajer (task.manage) menyetujui atau mengembalikan.
--   * hr_sop_templates + hr_sop_runs: checklist SOP harian per role (mis. buka / tutup toko),
--     dibuat otomatis per hari per outlet saat dibuka; item bisa wajib foto. Rekap kepatuhan.
--   * Bucket privat 'task-files': <company>/tasks/<task_id>/... dan <company>/sop/<run_id>/...
--   Izin baru: task.manage (kelola semua tugas & template SOP).
-- =====================================================================

create table hr_tasks (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  task_number       text,
  title             text not null check (trim(title) <> ''),
  description       text not null default '',
  status            text not null default 'new' check (status in ('new', 'in_progress', 'review', 'done', 'archived')),
  priority          text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  outlet_id         uuid references sys_outlets(id) on delete set null,
  assignee_id       uuid references sys_users(id) on delete set null,
  assignee_role_id  uuid references sys_roles(id) on delete set null,
  due_date          date,
  labels            text[] not null default '{}',
  checklist         jsonb not null default '[]',      -- [{text, done}]
  requires_photo    boolean not null default false,
  photo_paths       text[] not null default '{}',
  link_label        text,                             -- mis. "PO/20261009/0003"
  link_url          text,                             -- rute di aplikasi, mis. /purchasing?tab=po
  sort_order        numeric not null default 0,
  created_by        uuid references sys_users(id) default auth.uid(),
  started_at        timestamptz,
  submitted_at      timestamptz,
  done_at           timestamptz,
  done_by           uuid references sys_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, task_number),
  check (link_url is null or link_url like '/%')
);
create index hr_tasks_company_status on hr_tasks (company_id, status);

create table hr_task_comments (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references hr_tasks(id) on delete cascade,
  user_id     uuid references sys_users(id) default auth.uid(),
  kind        text not null default 'comment' check (kind in ('comment', 'event')),
  body        text not null check (trim(body) <> ''),
  created_at  timestamptz not null default now()
);
create index hr_task_comments_task on hr_task_comments (task_id, created_at);

create or replace function hr_task_set_number()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.task_number, '') = '' then
    new.task_number := 'TSK-' || lpad(sys_next_sequence(new.company_id, 'TSK')::text, 4, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_hr_tasks_number before insert or update on hr_tasks for each row execute function hr_task_set_number();

-- user ini manajer tugas (izin task.manage, dengan akses outlet tugas)
create or replace function hr_task_is_manager(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('task.manage') and (p_outlet_id is null or sys_can_access_outlet(p_outlet_id))
$$;

-- yang boleh melihat tugas: manajer, pembuat, penerima, anggota tim penerima, atasan langsung penerima
create or replace function hr_task_visible(p_task_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from hr_tasks t
    where t.id = p_task_id and t.company_id = sys_current_company_id()
      and (hr_task_is_manager(t.outlet_id) or t.created_by = auth.uid() or t.assignee_id = auth.uid()
        or (t.assignee_role_id is not null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid())
            and (t.outlet_id is null or sys_can_access_outlet(t.outlet_id)))
        or exists (select 1 from hr_employees e where e.user_id = t.assignee_id and hr_is_my_report(e.id))))
$$;

alter table hr_tasks enable row level security;
create policy hr_tasks_select on hr_tasks for select to authenticated
  using (company_id = sys_current_company_id() and hr_task_visible(id));
alter table hr_task_comments enable row level security;
create policy hr_task_comments_select on hr_task_comments for select to authenticated
  using (hr_task_visible(task_id));
-- tulis hanya lewat fungsi di bawah

-- peran user terhadap tugas
create or replace function hr_task_roles(p_task hr_tasks)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'manager', hr_task_is_manager(p_task.outlet_id) or p_task.created_by = auth.uid(),
    'doer', p_task.assignee_id = auth.uid()
         or (p_task.assignee_id is null and p_task.assignee_role_id is not null
             and p_task.assignee_role_id = (select role_id from sys_users where id = auth.uid())
             and (p_task.outlet_id is null or sys_can_access_outlet(p_task.outlet_id)))
         or (p_task.assignee_id is null and p_task.assignee_role_id is null and p_task.created_by = auth.uid()),
    'self_task', p_task.created_by = auth.uid() and coalesce(p_task.assignee_id = auth.uid(), p_task.assignee_role_id is null))
$$;

create or replace function hr_task_log(p_task_id uuid, p_body text)
returns void language sql security definer set search_path = public as $$
  insert into hr_task_comments (task_id, user_id, kind, body) values (p_task_id, auth.uid(), 'event', p_body)
$$;

-- buat / ubah tugas. p: {id?, title, description, priority, outlet_id, assignee_id, assignee_role_id, due_date,
--                        labels[], checklist[], requires_photo, link_label, link_url}
create or replace function hr_task_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_task hr_tasks; v_roles jsonb;
  v_assignee uuid := nullif(p->>'assignee_id', '')::uuid;
  v_role uuid := nullif(p->>'assignee_role_id', '')::uuid;
  v_outlet uuid := nullif(p->>'outlet_id', '')::uuid;
begin
  if v_company is null then raise exception 'Belum login'; end if;
  if coalesce(trim(p->>'title'), '') = '' then raise exception 'Judul tugas wajib diisi'; end if;
  if v_assignee is not null and not exists (select 1 from sys_users where id = v_assignee and company_id = v_company and is_active) then
    raise exception 'Penerima tugas tidak ditemukan';
  end if;
  if v_role is not null and not exists (select 1 from sys_roles where id = v_role and company_id = v_company) then raise exception 'Tim tidak ditemukan'; end if;
  if v_outlet is not null and not sys_can_access_outlet(v_outlet) then raise exception 'Tidak punya akses ke outlet ini'; end if;
  -- tugas untuk tim / orang lain tanpa izin task.manage: hanya untuk outlet yang bisa diakses (dicek di atas)
  if nullif(p->>'id', '') is null then
    insert into hr_tasks (company_id, title, description, priority, outlet_id, assignee_id, assignee_role_id, due_date, labels,
      checklist, requires_photo, link_label, link_url)
    values (v_company, trim(p->>'title'), coalesce(p->>'description', ''), coalesce(nullif(p->>'priority', ''), 'normal'), v_outlet,
      v_assignee, case when v_assignee is null then v_role end, nullif(p->>'due_date', '')::date,
      coalesce(array(select jsonb_array_elements_text(p->'labels')), '{}'),
      coalesce(p->'checklist', '[]'::jsonb), coalesce((p->>'requires_photo')::boolean, false),
      nullif(trim(coalesce(p->>'link_label', '')), ''), nullif(p->>'link_url', ''))
    returning * into v_task;
    perform hr_task_log(v_task.id, 'membuat tugas');
  else
    select * into v_task from hr_tasks where id = (p->>'id')::uuid and company_id = v_company for update;
    if v_task.id is null or not hr_task_visible(v_task.id) then raise exception 'Tugas tidak ditemukan'; end if;
    v_roles := hr_task_roles(v_task);
    if not (v_roles->>'manager')::boolean then
      -- penerima hanya boleh mencentang checklist
      if not (v_roles->>'doer')::boolean then raise exception 'Anda tidak bisa mengubah tugas ini'; end if;
      update hr_tasks set checklist = coalesce(p->'checklist', checklist) where id = v_task.id returning * into v_task;
    else
      if (v_task.assignee_id is distinct from v_assignee) then
        perform hr_task_log(v_task.id, 'mengalihkan tugas ke ' || coalesce((select full_name from sys_users where id = v_assignee),
          (select 'tim ' || name from sys_roles where id = v_role), 'tanpa penerima'));
      end if;
      update hr_tasks set title = trim(p->>'title'), description = coalesce(p->>'description', ''), priority = coalesce(nullif(p->>'priority', ''), 'normal'),
        outlet_id = v_outlet, assignee_id = v_assignee, assignee_role_id = case when v_assignee is null then v_role end,
        due_date = nullif(p->>'due_date', '')::date, labels = coalesce(array(select jsonb_array_elements_text(p->'labels')), '{}'),
        checklist = coalesce(p->'checklist', '[]'::jsonb), requires_photo = coalesce((p->>'requires_photo')::boolean, false),
        link_label = nullif(trim(coalesce(p->>'link_label', '')), ''), link_url = nullif(p->>'link_url', '')
      where id = v_task.id returning * into v_task;
    end if;
  end if;
  return to_jsonb(v_task);
end $$;

-- pindah status (geser kartu)
create or replace function hr_task_move(p_id uuid, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_task hr_tasks; v_roles jsonb; v_mgr boolean; v_doer boolean; v_self boolean;
  v_label jsonb := '{"new":"Baru","in_progress":"Dikerjakan","review":"Review","done":"Selesai","archived":"Arsip"}';
begin
  select * into v_task from hr_tasks where id = p_id and company_id = sys_current_company_id() for update;
  if v_task.id is null or not hr_task_visible(v_task.id) then raise exception 'Tugas tidak ditemukan'; end if;
  if p_status not in ('new', 'in_progress', 'review', 'done', 'archived') then raise exception 'Status tidak dikenal'; end if;
  if p_status = v_task.status then return to_jsonb(v_task); end if;
  v_roles := hr_task_roles(v_task);
  v_mgr := (v_roles->>'manager')::boolean; v_doer := (v_roles->>'doer')::boolean; v_self := (v_roles->>'self_task')::boolean;

  if not v_mgr then
    if not v_doer then raise exception 'Anda bukan penerima tugas ini'; end if;
    if p_status in ('archived') or v_task.status in ('done', 'archived') then raise exception 'Hanya pembuat tugas / manajer yang bisa memindahkan ke sini'; end if;
    if p_status = 'done' and not v_self then raise exception 'Ajukan ke Review dulu; pembuat tugas yang menandai selesai'; end if;
    if v_task.status = 'review' then raise exception 'Tugas sedang direview'; end if;
  end if;
  if v_mgr and v_task.status = 'review' and p_status in ('new', 'in_progress') and coalesce(trim(p_note), '') = '' and not v_self then
    raise exception 'Tulis catatan apa yang perlu diperbaiki';
  end if;
  -- syarat selesai: checklist lengkap & foto bukti
  if p_status in ('review', 'done') then
    if exists (select 1 from jsonb_array_elements(v_task.checklist) c where not coalesce((c->>'done')::boolean, false)) then
      raise exception 'Checklist belum selesai semua';
    end if;
    if v_task.requires_photo and cardinality(v_task.photo_paths) = 0 then raise exception 'Lampirkan foto bukti dulu'; end if;
  end if;

  update hr_tasks set status = p_status,
    -- tugas tim: yang pertama mengerjakan otomatis jadi penerima
    assignee_id = case when assignee_id is null and assignee_role_id is not null and p_status = 'in_progress' and v_doer then auth.uid() else assignee_id end,
    started_at = case when p_status = 'in_progress' then coalesce(started_at, now()) else started_at end,
    submitted_at = case when p_status = 'review' then now() else submitted_at end,
    done_at = case when p_status = 'done' then now() when p_status in ('new', 'in_progress', 'review') then null else done_at end,
    done_by = case when p_status = 'done' then auth.uid() when p_status in ('new', 'in_progress', 'review') then null else done_by end
  where id = p_id returning * into v_task;
  perform hr_task_log(p_id, 'memindahkan ke ' || (v_label->>p_status) || coalesce(': ' || nullif(trim(p_note), ''), ''));
  return to_jsonb(v_task);
end $$;

create or replace function hr_task_comment(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not hr_task_visible(p_id) then raise exception 'Tugas tidak ditemukan'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Komentar kosong'; end if;
  insert into hr_task_comments (task_id, user_id, kind, body) values (p_id, auth.uid(), 'comment', trim(p_body));
end $$;

-- foto bukti: file harus sudah diunggah ke task-files/<company>/tasks/<task_id>/
create or replace function hr_task_photo(p_id uuid, p_path text, p_remove boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_task hr_tasks; v_roles jsonb;
begin
  select * into v_task from hr_tasks where id = p_id and company_id = sys_current_company_id() for update;
  if v_task.id is null or not hr_task_visible(v_task.id) then raise exception 'Tugas tidak ditemukan'; end if;
  v_roles := hr_task_roles(v_task);
  if not ((v_roles->>'manager')::boolean or (v_roles->>'doer')::boolean) then raise exception 'Anda tidak bisa mengubah tugas ini'; end if;
  if p_remove then
    update hr_tasks set photo_paths = array_remove(photo_paths, p_path) where id = p_id returning * into v_task;
  else
    if p_path not like v_task.company_id || '/tasks/' || v_task.id || '/%' then raise exception 'Foto tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'task-files' and name = p_path) then raise exception 'Foto belum terunggah'; end if;
    update hr_tasks set photo_paths = array_append(photo_paths, p_path) where id = p_id returning * into v_task;
    perform hr_task_log(p_id, 'menambahkan foto bukti');
  end if;
  return to_jsonb(v_task);
end $$;

-- orang & tim untuk pilihan penerima (nama saja)
create or replace function hr_task_people()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'full_name', u.full_name, 'avatar_url', u.avatar_url, 'role_id', u.role_id, 'role', r.name) order by u.full_name)
      from sys_users u left join sys_roles r on r.id = u.role_id where u.company_id = sys_current_company_id() and u.is_active), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.name)
      from sys_roles r where r.company_id = sys_current_company_id()), '[]'::jsonb))
$$;

-- papan kanban. p_scope: 'mine' (untuk saya & tim saya) / 'created' (saya buat) / 'all' (semua yang terlihat)
create or replace function hr_task_board(p_scope text default 'mine', p_outlet_id uuid default null, p_include_archived boolean default false)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object(
      'assignee', (select full_name from sys_users where id = t.assignee_id),
      'assignee_avatar', (select avatar_url from sys_users where id = t.assignee_id),
      'assignee_role', (select name from sys_roles where id = t.assignee_role_id),
      'creator', (select full_name from sys_users where id = t.created_by),
      'outlet', (select name from sys_outlets where id = t.outlet_id),
      'comment_count', (select count(*) from hr_task_comments c where c.task_id = t.id and c.kind = 'comment'),
      'roles', hr_task_roles(t))
    order by t.sort_order, case t.priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, t.due_date nulls last, t.created_at), '[]'::jsonb)
  from hr_tasks t
  where t.company_id = sys_current_company_id() and hr_task_visible(t.id)
    and (p_include_archived or t.status <> 'archived')
    and (t.status <> 'done' or t.done_at > now() - interval '30 days' or p_include_archived)
    and (p_outlet_id is null or t.outlet_id = p_outlet_id)
    and case p_scope
      when 'created' then t.created_by = auth.uid()
      when 'all' then true
      else t.assignee_id = auth.uid()
        or (t.assignee_id is null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid()))
        or (t.assignee_id is null and t.assignee_role_id is null and t.created_by = auth.uid())
    end
$$;

create or replace function hr_task_detail(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when hr_task_visible(p_id) then (
    select to_jsonb(t) || jsonb_build_object(
      'assignee', (select full_name from sys_users where id = t.assignee_id),
      'assignee_role', (select name from sys_roles where id = t.assignee_role_id),
      'creator', (select full_name from sys_users where id = t.created_by),
      'outlet', (select name from sys_outlets where id = t.outlet_id),
      'roles', hr_task_roles(t),
      'comments', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'body', c.body, 'created_at', c.created_at,
          'user', u.full_name, 'avatar_url', u.avatar_url) order by c.created_at)
        from hr_task_comments c left join sys_users u on u.id = c.user_id where c.task_id = t.id), '[]'::jsonb))
    from hr_tasks t where t.id = p_id) end
$$;

-- ---------------------------------------------------------------------
-- SOP HARIAN
-- ---------------------------------------------------------------------
create table hr_sop_templates (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  name        text not null check (trim(name) <> ''),
  role_id     uuid references sys_roles(id) on delete set null,     -- null = semua role
  outlet_id   uuid references sys_outlets(id) on delete set null,   -- null = semua outlet
  items       jsonb not null default '[]',                          -- [{text, photo}]
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (jsonb_typeof(items) = 'array')
);
select sys_apply_company_policies('hr_sop_templates', 'task.manage');
create trigger trg_hr_sop_templates_audit after insert or update or delete on hr_sop_templates for each row execute function sys_audit_trigger('');

create table hr_sop_runs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  template_id   uuid not null references hr_sop_templates(id) on delete cascade,
  outlet_id     uuid references sys_outlets(id) on delete set null,
  run_date      date not null,
  items         jsonb not null,                                     -- [{text, photo, done, by, by_name, at, photo_path}]
  completed_at  timestamptz,
  created_at    timestamptz not null default now()
);
create unique index hr_sop_runs_unique on hr_sop_runs (template_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid), run_date);
alter table hr_sop_runs enable row level security;
create policy hr_sop_runs_select on hr_sop_runs for select to authenticated
  using (company_id = sys_current_company_id() and (outlet_id is null or sys_can_access_outlet(outlet_id)));

-- SOP hari ini untuk saya (dibuat otomatis bila belum ada)
create or replace function hr_my_sops()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_role uuid := (select role_id from sys_users where id = auth.uid());
  v_outlet uuid := (select outlet_id from hr_employees where user_id = auth.uid() and company_id = v_company);
  v_date date; t record; v_run_outlet uuid;
begin
  if v_company is null then return '[]'::jsonb; end if;
  for t in select * from hr_sop_templates
           where company_id = v_company and is_active and jsonb_array_length(items) > 0
             and (role_id is null or role_id = v_role)
             and (outlet_id is null or outlet_id = v_outlet or (v_outlet is null and sys_can_access_outlet(outlet_id))) loop
    v_run_outlet := coalesce(t.outlet_id, v_outlet);
    v_date := (now() at time zone coalesce((select timezone from sys_outlets where id = v_run_outlet), 'Asia/Jakarta'))::date;
    insert into hr_sop_runs (company_id, template_id, outlet_id, run_date, items)
    values (v_company, t.id, v_run_outlet, v_date,
      (select coalesce(jsonb_agg(jsonb_build_object('text', i->>'text', 'photo', coalesce((i->>'photo')::boolean, false), 'done', false)), '[]'::jsonb)
       from jsonb_array_elements(t.items) i))
    on conflict do nothing;
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'template_id', r.template_id, 'name', s.name, 'outlet', o.name,
      'run_date', r.run_date, 'items', r.items, 'completed_at', r.completed_at) order by s.sort_order, s.name)
    from hr_sop_runs r join hr_sop_templates s on s.id = r.template_id left join sys_outlets o on o.id = r.outlet_id
    where r.company_id = v_company and s.is_active
      and (s.role_id is null or s.role_id = v_role)
      and r.outlet_id is not distinct from coalesce(s.outlet_id, v_outlet)
      and r.run_date = (now() at time zone coalesce(o.timezone, 'Asia/Jakarta'))::date), '[]'::jsonb);
end $$;

-- centang item SOP (foto wajib bila item meminta)
create or replace function hr_sop_check(p_run_id uuid, p_index int, p_done boolean, p_photo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_run hr_sop_runs; v_tpl hr_sop_templates; v_item jsonb; v_items jsonb;
begin
  select * into v_run from hr_sop_runs where id = p_run_id and company_id = sys_current_company_id() for update;
  if v_run.id is null then raise exception 'SOP tidak ditemukan'; end if;
  select * into v_tpl from hr_sop_templates where id = v_run.template_id;
  if not (sys_has_permission('task.manage') or v_tpl.role_id is null or v_tpl.role_id = (select role_id from sys_users where id = auth.uid())) then
    raise exception 'SOP ini bukan untuk role Anda';
  end if;
  if v_run.outlet_id is not null and not sys_can_access_outlet(v_run.outlet_id)
     and v_run.outlet_id is distinct from (select outlet_id from hr_employees where user_id = auth.uid()) then
    raise exception 'Tidak punya akses ke outlet ini';
  end if;
  if v_run.run_date < (now() at time zone 'Asia/Jakarta')::date - 1 then raise exception 'SOP hari sebelumnya sudah ditutup'; end if;
  v_item := v_run.items->p_index;
  if v_item is null then raise exception 'Item tidak ditemukan'; end if;
  if p_done and coalesce((v_item->>'photo')::boolean, false) then
    if p_photo is null then raise exception 'Item ini wajib foto'; end if;
    if p_photo not like v_run.company_id || '/sop/' || v_run.id || '/%' then raise exception 'Foto tidak valid'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'task-files' and name = p_photo) then raise exception 'Foto belum terunggah'; end if;
  end if;
  v_item := case when p_done
    then v_item || jsonb_build_object('done', true, 'by', auth.uid(), 'by_name', (select full_name from sys_users where id = auth.uid()), 'at', now(), 'photo_path', p_photo)
    else (v_item - 'by' - 'by_name' - 'at' - 'photo_path') || jsonb_build_object('done', false) end;
  v_items := jsonb_set(v_run.items, array[p_index::text], v_item);
  update hr_sop_runs set items = v_items,
    completed_at = case when not exists (select 1 from jsonb_array_elements(v_items) i where not coalesce((i->>'done')::boolean, false)) then coalesce(completed_at, now()) end
  where id = p_run_id returning * into v_run;
  return to_jsonb(v_run);
end $$;

-- rekap kepatuhan SOP (manajer): per tanggal x template x outlet
create or replace function hr_sop_report(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_has_permission('task.manage') then raise exception 'Butuh izin kelola tugas'; end if;
  return jsonb_build_object(
    'templates', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', r.name, 'outlet', o.name, 'items', s.items,
        'role_id', s.role_id, 'outlet_id', s.outlet_id, 'is_active', s.is_active, 'sort_order', s.sort_order) order by s.sort_order, s.name)
      from hr_sop_templates s left join sys_roles r on r.id = s.role_id left join sys_outlets o on o.id = s.outlet_id
      where s.company_id = sys_current_company_id()), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'template_id', x.template_id, 'outlet_id', x.outlet_id, 'outlet', o.name,
        'run_date', x.run_date, 'items', x.items, 'completed_at', x.completed_at,
        'done', (select count(*) from jsonb_array_elements(x.items) i where (i->>'done')::boolean),
        'total', jsonb_array_length(x.items)) order by x.run_date desc)
      from hr_sop_runs x left join sys_outlets o on o.id = x.outlet_id
      where x.company_id = sys_current_company_id() and x.run_date between p_from and p_to
        and (p_outlet_id is null or x.outlet_id = p_outlet_id)
        and (x.outlet_id is null or sys_can_access_outlet(x.outlet_id))), '[]'::jsonb));
end $$;

-- badge: tugas baru untuk saya, tugas yang menunggu review saya, item SOP hari ini yang belum
create or replace function hr_task_counts()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'todo', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status in ('new', 'in_progress')
             and (t.assignee_id = auth.uid() or (t.assignee_id is null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid())
                  and (t.outlet_id is null or sys_can_access_outlet(t.outlet_id))))),
    'new', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status = 'new'
             and (t.assignee_id = auth.uid() or (t.assignee_id is null and t.assignee_role_id = (select role_id from sys_users where id = auth.uid())
                  and (t.outlet_id is null or sys_can_access_outlet(t.outlet_id))))
             and t.created_by is distinct from auth.uid()),
    'review', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status = 'review'
             and (t.created_by = auth.uid() or hr_task_is_manager(t.outlet_id)) and t.assignee_id is distinct from auth.uid()),
    'overdue', (select count(*) from hr_tasks t where t.company_id = sys_current_company_id() and t.status in ('new', 'in_progress')
             and t.due_date < current_date and t.assignee_id = auth.uid()))
$$;

-- ---------------------------------------------------------------------
-- STORAGE PRIVAT: task-files/<company>/tasks/<task_id>/... dan <company>/sop/<run_id>/...
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('task-files', 'task-files', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function hr_task_file_ok(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text and (
    ((storage.foldername(p_name))[2] = 'tasks' and case when (storage.foldername(p_name))[3] ~ '^[0-9a-f-]{36}$'
       then hr_task_visible(((storage.foldername(p_name))[3])::uuid) else false end)
    or ((storage.foldername(p_name))[2] = 'sop' and exists (
      select 1 from hr_sop_runs r where r.id::text = (storage.foldername(p_name))[3] and r.company_id = sys_current_company_id())))
$$;
create policy task_files_select on storage.objects for select to authenticated using (bucket_id = 'task-files' and hr_task_file_ok(name));
create policy task_files_insert on storage.objects for insert to authenticated with check (bucket_id = 'task-files' and hr_task_file_ok(name));
create policy task_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'task-files' and hr_task_file_ok(name) and sys_has_permission('task.manage'));
