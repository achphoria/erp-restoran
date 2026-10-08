-- =====================================================================
-- SEMAR - 038: USER MANAGEMENT <-> DATA KARYAWAN
--   * hr_user_links(): akun mana yang sudah / belum punya data karyawan (hanya id & nomor karyawan,
--     tanpa data pribadi), untuk User Management. Tidak terpengaruh kunci outlet, jadi tidak salah
--     menandai "belum ada data karyawan".
--   * hr_create_employee_for_user(): buat data karyawan dari akun (nama, HP, email asli, outlet, jabatan
--     yang role default-nya cocok). Butuh hr.manage; hanya akun di perusahaan yang sama.
-- =====================================================================

create or replace function hr_user_links()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when sys_has_permission('user.manage') or sys_has_permission('hr.view') or sys_has_permission('hr.manage') then
    coalesce((select jsonb_agg(jsonb_build_object('user_id', e.user_id, 'employee_id', e.id, 'employee_number', e.employee_number, 'is_active', e.is_active))
      from hr_employees e where e.company_id = sys_current_company_id() and e.user_id is not null), '[]'::jsonb)
  else '[]'::jsonb end
$$;

create or replace function hr_create_employee_for_user(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_user sys_users; v_email text; v_outlet uuid; v_position uuid; v_emp hr_employees;
begin
  if not sys_has_permission('hr.manage') then raise exception 'Butuh izin kelola karyawan'; end if;
  select * into v_user from sys_users where id = p_user_id and company_id = v_company;
  if v_user.id is null then raise exception 'User tidak ditemukan'; end if;
  if exists (select 1 from hr_employees where user_id = p_user_id) then raise exception 'User ini sudah punya data karyawan'; end if;
  -- email sintetis akun staf (username@staff.santap.local) tidak disalin
  select nullif(email, '') into v_email from auth.users where id = p_user_id;
  if v_email like '%@staff.santap.local' then v_email := null; end if;
  -- outlet: satu-satunya outlet akun (bila hanya satu) yang juga boleh diakses HR ini
  select min(uo.outlet_id::text)::uuid into v_outlet from sys_user_outlets uo where uo.user_id = p_user_id
  having count(*) = 1;
  if v_outlet is not null and not sys_can_access_outlet(v_outlet) then raise exception 'Tidak punya akses ke outlet user ini'; end if;
  -- jabatan: hanya bila tepat satu jabatan aktif ber-role default sama
  select min(id::text)::uuid into v_position from hr_positions
  where company_id = v_company and is_active and default_role_id = v_user.role_id having count(*) = 1;
  insert into hr_employees (company_id, user_id, full_name, phone, email, outlet_id, position_id, department_id)
  values (v_company, p_user_id, v_user.full_name, v_user.phone, v_email, v_outlet, v_position,
          (select department_id from hr_positions where id = v_position))
  returning * into v_emp;
  return jsonb_build_object('id', v_emp.id, 'employee_number', v_emp.employee_number);
end $$;
