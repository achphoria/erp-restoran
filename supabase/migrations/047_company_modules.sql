-- =====================================================================
-- SEMAR - 047: MODUL PER PERUSAHAAN + PANDUAN MEMULAI
--   * Owner memilih modul yang dipakai (wizard setelah daftar & Pengaturan -> Modul). Modul yang dimatikan
--     disembunyikan dari menu & halaman; datanya TIDAK dihapus. enabled_modules null = semua modul aktif
--     (perusahaan lama tetap seperti sebelumnya).
--   * Tipe usaha (warung, resto, multi cabang, katering) dipakai sebagai paket modul awal.
--   * Panduan memulai: checklist yang tercentang otomatis dari data (menu, akun kasir, stok awal, dst.).
--   * Profil user membawa info modul (dipakai aplikasi & Semar AI).
-- =====================================================================

alter table sys_companies add column if not exists enabled_modules text[];
alter table sys_companies add column if not exists business_type text
  check (business_type is null or business_type in ('warung', 'resto', 'multi', 'catering'));
alter table sys_companies add column if not exists setup_completed_at timestamptz;
alter table sys_companies add column if not exists setup_guide_dismissed_at timestamptz;

-- perusahaan yang sudah berjalan tidak diminta wizard lagi & panduannya tidak dimunculkan
update sys_companies set setup_completed_at = coalesce(setup_completed_at, now()),
  setup_guide_dismissed_at = coalesce(setup_guide_dismissed_at, now());

-- modul yang bisa dipilih (selain modul inti: dashboard, menu, laporan, persetujuan, user, pengaturan, beranda saya)
create or replace function sys_module_keys()
returns text[] language sql immutable as $$
  select array['pos', 'kds', 'kiosk', 'crm', 'feedback', 'inventory', 'production', 'purchasing', 'sales', 'finance',
               'hr', 'tasks', 'assets', 'ai']
$$;

-- modul yang membutuhkan modul lain
create or replace function sys_module_requires(p_key text)
returns text[] language sql immutable as $$
  select case p_key
    when 'kds' then array['pos'] when 'kiosk' then array['pos'] when 'crm' then array['pos'] when 'feedback' then array['pos']
    when 'production' then array['inventory'] when 'purchasing' then array['inventory'] when 'sales' then array['inventory']
    else array[]::text[] end
$$;

create or replace function sys_company_modules(p_company_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', to_jsonb(c.enabled_modules), 'business_type', c.business_type,
    'setup_completed_at', c.setup_completed_at, 'guide_dismissed_at', c.setup_guide_dismissed_at)
  from sys_companies c where c.id = p_company_id
$$;

-- simpan pilihan modul (owner / pengelola pengaturan). p_finish = selesai wizard awal
create or replace function sys_save_modules(p_modules text[], p_business_type text default null, p_finish boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_mods text[]; v_bad text[]; k text;
begin
  if v_c is null then raise exception 'Belum login'; end if;
  if not (sys_has_permission('*') or sys_has_permission('settings.manage')) then raise exception 'Hanya owner / pengelola pengaturan yang bisa mengatur modul'; end if;
  if p_business_type is not null and p_business_type not in ('warung', 'resto', 'multi', 'catering') then raise exception 'Tipe usaha tidak dikenal'; end if;
  if p_modules is null then
    v_mods := null;                                   -- semua modul aktif
  else
    select array_agg(x) into v_bad from unnest(p_modules) x where x <> all(sys_module_keys());
    if v_bad is not null then raise exception 'Modul tidak dikenal: %', array_to_string(v_bad, ', '); end if;
    v_mods := p_modules;
    -- modul pendukung ikut aktif
    foreach k in array p_modules loop
      v_mods := v_mods || sys_module_requires(k);
    end loop;
    select array_agg(distinct x order by x) into v_mods from unnest(v_mods) x;
    v_mods := coalesce(v_mods, '{}');
  end if;
  update sys_companies set enabled_modules = v_mods,
    business_type = coalesce(p_business_type, business_type),
    setup_completed_at = case when p_finish then coalesce(setup_completed_at, now()) else setup_completed_at end
  where id = v_c;
  perform sys_log_activity(v_c, 'update', 'sys_companies', v_c, 'Pengaturan modul',
    jsonb_build_object('modules', coalesce(to_jsonb(v_mods), '"semua"'::jsonb)));
  return sys_company_modules(v_c);
end $$;

create or replace function sys_dismiss_setup_guide(p_dismiss boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('*') then raise exception 'Khusus owner'; end if;
  update sys_companies set setup_guide_dismissed_at = case when p_dismiss then now() end where id = sys_current_company_id();
end $$;

-- panduan memulai: langkah yang sudah dikerjakan (dihitung dari data perusahaan)
create or replace function sys_setup_progress()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id();
begin
  if v_c is null or not sys_has_permission('*') then raise exception 'Khusus owner'; end if;
  return jsonb_build_object(
    'company_logo', exists (select 1 from sys_companies where id = v_c and logo_url is not null),
    'menu', exists (select 1 from mst_menu_items where company_id = v_c),
    'tables', exists (select 1 from mst_tables where company_id = v_c),
    'staff', (select count(*) from sys_users where company_id = v_c and is_active) > 1,
    'first_order', exists (select 1 from pos_orders where company_id = v_c and status = 'paid'),
    'items', exists (select 1 from inv_items where company_id = v_c),
    'recipe', exists (select 1 from inv_recipes where company_id = v_c),
    'opening_stock', exists (select 1 from inv_stocks where company_id = v_c and quantity > 0),
    'supplier', exists (select 1 from pur_suppliers where company_id = v_c and supplier_type = 'external'),
    'employees', exists (select 1 from hr_employees where company_id = v_c),
    'shifts', exists (select 1 from hr_shifts where company_id = v_c),
    'sop', exists (select 1 from hr_sop_templates where company_id = v_c),
    'asset', exists (select 1 from ast_assets where company_id = v_c),
    'feedback', exists (select 1 from crm_feedback_questions where company_id = v_c),
    'kiosk', exists (select 1 from pos_kiosks where company_id = v_c),
    'promo', exists (select 1 from crm_promotions where company_id = v_c),
    'semar', exists (select 1 from ai_chat_messages where company_id = v_c and role = 'user'));
end $$;

-- profil user + info modul perusahaan aktif
alter function sys_get_my_profile() rename to sys_get_my_profile_base;
revoke execute on function sys_get_my_profile_base() from public, anon, authenticated;
create or replace function sys_get_my_profile()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p jsonb := sys_get_my_profile_base();
begin
  if p is null then return null; end if;
  return p || jsonb_build_object('modules', sys_company_modules((p->>'company_id')::uuid));
end $$;

revoke execute on function sys_module_keys() from public, anon;
revoke execute on function sys_module_requires(text) from public, anon;
revoke execute on function sys_company_modules(uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['sys_save_modules(text[], text, boolean)', 'sys_dismiss_setup_guide(boolean)', 'sys_setup_progress()', 'sys_get_my_profile()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
