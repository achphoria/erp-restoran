-- =====================================================================
-- SANTAP ERP - 029: PERBAIKAN DAFTAR USAHA BARU (ONBOARDING)
--   Saat onboarding, perusahaan dibuat lebih dulu daripada baris sys_users.
--   Log aktivitas otomatis mencatat user_id = auth.uid() yang belum ada di sys_users,
--   sehingga gagal: "violates foreign key constraint sys_activity_logs_user_id_fkey".
--   Sekarang: user_id hanya diisi bila user sudah terdaftar; nama pelaku jatuh ke email.
-- =====================================================================

create or replace function sys_actor_label()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from sys_users where id = auth.uid()), (select email from auth.users where id = auth.uid()))
      || case sys_acting_mode() when 'support' then ' (Platform support)' when 'group' then ' (Pemilik grup)' else '' end
$$;

create or replace function sys_log_activity(
  p_company_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_label text, p_changes jsonb default null
)
returns void language sql security definer set search_path = public as $$
  insert into sys_activity_logs (company_id, user_id, user_name, action, entity_type, entity_id, entity_label, changes)
  values (p_company_id, (select id from sys_users where id = auth.uid()), sys_actor_label(),
          p_action, p_entity_type, p_entity_id, left(p_label, 200), p_changes)
$$;
