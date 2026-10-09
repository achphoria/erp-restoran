-- =====================================================================
-- SANTAP ERP - UPDATE FASE 33 (Semar AI insight)
-- Untuk database yang SUDAH menjalankan fase 1-32.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/043_semar_insights.sql
-- =====================================================================
-- SEMAR - 043: SEMAR AI LEBIH PINTAR (insight bisnis untuk owner)
--   * ai_business_brief(): briefing harian dalam satu panggilan: penjualan (hari ini, kemarin, periode vs
--     sebelumnya, per outlet, jam ramai, menu terlaris & menu lambat), stok menipis & mau kedaluwarsa,
--     SDM hari ini (hadir, telat, belum absen, cuti), pengajuan menunggu, tugas lewat tenggat & SOP kemarin,
--     ulasan pelanggan, persetujuan menunggu, pembelian, laba rugi bulan ini.
--   * ai_feedback_insights(): ringkasan ulasan + komentar mentah untuk dianalisa temanya oleh Semar.
--   * ai_hr_recap(): rekap per karyawan (hadir, telat, alpa, cuti, pulang cepat, sisa cuti, tugas).
--   * ai_writable_tables(): Semar boleh mengusulkan template SOP & pertanyaan form ulasan.
--   Semua hanya baca & dibatasi perusahaan aktif; owner (atau izin laporan) saja.
-- =====================================================================

create or replace function ai_business_brief(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_days int := least(greatest(coalesce(p_days, 7), 1), 90);
  v_from date := v_today - (least(greatest(coalesce(p_days, 7), 1), 90) - 1);
  v_now timestamptz := now();
begin
  if v_c is null or not (sys_has_permission('*') or sys_has_permission('report.view')) then raise exception 'Butuh izin laporan'; end if;
  return (
    with o as (
      select po.*, po.subtotal - po.discount_amount - po.promotion_amount - po.points_amount as net
      from pos_orders po where po.company_id = v_c and po.status = 'paid' and po.business_date between v_from - v_days and v_today
        and sys_can_access_outlet(po.outlet_id)
    )
    select jsonb_build_object(
      'periode', jsonb_build_object('dari', v_from, 'sampai', v_today, 'hari', v_days),
      'penjualan', jsonb_build_object(
        'hari_ini', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*)) from o where business_date = v_today),
        'kemarin', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*)) from o where business_date = v_today - 1),
        'periode', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*), 'rata_rata', round(coalesce(avg(net), 0))) from o where business_date >= v_from),
        'periode_sebelumnya', (select jsonb_build_object('bersih', coalesce(sum(net), 0), 'transaksi', count(*)) from o where business_date < v_from),
        'per_outlet', coalesce((select jsonb_agg(jsonb_build_object('outlet', so.name, 'bersih', x.s, 'transaksi', x.n) order by x.s desc)
          from (select outlet_id, sum(net) as s, count(*) as n from o where business_date >= v_from group by 1) x join sys_outlets so on so.id = x.outlet_id), '[]'::jsonb),
        'jam_ramai', coalesce((select jsonb_agg(jsonb_build_object('jam', h, 'transaksi', n) order by n desc)
          from (select extract(hour from coalesce(paid_at, created_at) at time zone 'Asia/Jakarta')::int as h, count(*) as n
                from o where business_date >= v_from group by 1 order by 2 desc limit 3) t), '[]'::jsonb),
        'menu_terlaris', coalesce((select jsonb_agg(jsonb_build_object('menu', t.name, 'porsi', t.q, 'omzet', t.r) order by t.q desc)
          from (select i.menu_item_name as name, sum(i.quantity) as q, sum(i.line_total) as r from pos_order_items i join o on o.id = i.order_id
                where o.business_date >= v_from and not i.is_void group by 1 order by 2 desc limit 5) t), '[]'::jsonb),
        'menu_lambat', coalesce((select jsonb_agg(m.name order by m.name) from (
            select mi.name from mst_menu_items mi where mi.company_id = v_c and mi.is_active
              and not exists (select 1 from pos_order_items i join pos_orders po on po.id = i.order_id
                              where i.menu_item_id = mi.id and po.status = 'paid' and po.business_date > v_today - 14)
            order by mi.name limit 10) m), '[]'::jsonb)),
      'stok', jsonb_build_object(
        'menipis_jumlah', (select count(*) from rpt_stock_balances s where s.company_id = v_c and s.is_low_stock),
        'menipis', coalesce((select jsonb_agg(jsonb_build_object('bahan', s.item_name, 'gudang', s.warehouse_name, 'stok', s.quantity, 'minimum', s.min_stock, 'satuan', s.unit_code))
          from (select * from rpt_stock_balances s where s.company_id = v_c and s.is_low_stock order by s.quantity - s.min_stock limit 10) s), '[]'::jsonb),
        'kedaluwarsa_7_hari', coalesce((select jsonb_agg(jsonb_build_object('bahan', b.item_name, 'batch', b.batch_code, 'kedaluwarsa', b.expiry_date, 'sisa', b.qty_remaining, 'satuan', b.unit_code, 'nilai', b.stock_value) order by b.expiry_date)
          from (select * from rpt_stock_batches b where b.company_id = v_c and b.qty_remaining > 0 and b.expiry_date <= v_today + 7 order by b.expiry_date limit 10) b), '[]'::jsonb)),
      'sdm', jsonb_build_object(
        'karyawan_aktif', (select count(*) from hr_employees where company_id = v_c and is_active),
        'terjadwal_hari_ini', (select count(*) from hr_rosters r where r.company_id = v_c and r.work_date = v_today and not r.is_off),
        'hadir_hari_ini', (select count(*) from hr_attendances a where a.company_id = v_c and a.work_date = v_today and a.check_in_at is not null),
        'telat_hari_ini', coalesce((select jsonb_agg(jsonb_build_object('nama', e.full_name, 'menit', a.late_minutes)) from hr_attendances a join hr_employees e on e.id = a.employee_id
          where a.company_id = v_c and a.work_date = v_today and a.late_minutes > 0), '[]'::jsonb),
        'belum_absen', coalesce((select jsonb_agg(jsonb_build_object('nama', e.full_name, 'shift', s.name, 'mulai', s.start_time))
          from hr_rosters r join hr_employees e on e.id = r.employee_id join hr_shifts s on s.id = r.shift_id
          where r.company_id = v_c and r.work_date = v_today and not r.is_off and (v_today + s.start_time) at time zone 'Asia/Jakarta' < v_now
            and not exists (select 1 from hr_attendances a where a.employee_id = r.employee_id and a.work_date = v_today)
            and hr_leave_on(r.employee_id, v_today) is null), '[]'::jsonb),
        'cuti_hari_ini', coalesce((select jsonb_agg(jsonb_build_object('nama', e.full_name, 'jenis', t.name)) from hr_leave_requests l
          join hr_employees e on e.id = l.employee_id join hr_leave_types t on t.id = l.leave_type_id
          where l.company_id = v_c and l.status = 'approved' and v_today between l.start_date and l.end_date), '[]'::jsonb),
        'cuti_menunggu', (select count(*) from hr_leave_requests where company_id = v_c and status = 'pending'),
        'koreksi_absen_menunggu', (select count(*) from hr_attendance_corrections where company_id = v_c and status = 'pending'),
        'absen_perlu_review', (select count(*) from hr_attendances where company_id = v_c and review_status = 'pending'),
        'kontrak_habis_30_hari', coalesce((select jsonb_agg(jsonb_build_object('nama', full_name, 'tanggal', contract_end_date) order by contract_end_date)
          from hr_employees where company_id = v_c and is_active and contract_end_date between v_today and v_today + 30), '[]'::jsonb)),
      'tugas', jsonb_build_object(
        'terbuka', (select count(*) from hr_tasks where company_id = v_c and status in ('new', 'in_progress')),
        'menunggu_review', (select count(*) from hr_tasks where company_id = v_c and status = 'review'),
        'lewat_tenggat', coalesce((select jsonb_agg(jsonb_build_object('tugas', t.title, 'untuk', coalesce(u.full_name, 'Tim ' || r.name, '-'), 'tenggat', t.due_date) order by t.due_date)
          from (select * from hr_tasks where company_id = v_c and status in ('new', 'in_progress', 'review') and due_date < v_today order by due_date limit 10) t
          left join sys_users u on u.id = t.assignee_id left join sys_roles r on r.id = t.assignee_role_id), '[]'::jsonb),
        'sop_kemarin', coalesce((select jsonb_agg(jsonb_build_object('sop', s.name, 'outlet', ol.name,
            'selesai_persen', round(100.0 * (select count(*) from jsonb_array_elements(x.items) i where (i->>'done')::boolean) / greatest(1, jsonb_array_length(x.items)))))
          from hr_sop_runs x join hr_sop_templates s on s.id = x.template_id left join sys_outlets ol on ol.id = x.outlet_id
          where x.company_id = v_c and x.run_date = v_today - 1), '[]'::jsonb)),
      'ulasan', (select jsonb_build_object('jumlah', count(*), 'rata_rata_bintang', round(avg(overall), 2),
          'nps', case when count(nps) > 0 then round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(nps)) end,
          'buruk_belum_ditangani', count(*) filter (where overall <= 2 and status = 'new'),
          'komentar_terbaru', coalesce((select jsonb_agg(jsonb_build_object('bintang', f2.overall, 'komentar', f2.comment, 'tanggal', (f2.created_at at time zone 'Asia/Jakarta')::date))
            from (select * from crm_feedback_responses where company_id = v_c and comment is not null order by created_at desc limit 8) f2), '[]'::jsonb))
        from crm_feedback_responses f where f.company_id = v_c and (f.created_at at time zone 'Asia/Jakarta')::date >= v_from),
      'persetujuan_menunggu', coalesce((select jsonb_object_agg(document_type, n) from (select document_type, count(*) as n from sys_approval_requests
          where company_id = v_c and status = 'pending' group by 1) t), '{}'::jsonb),
      'pembelian', jsonb_build_object(
        'po_menunggu_persetujuan', (select count(*) from pur_purchase_orders where company_id = v_c and status = 'pending_approval'),
        'penerimaan_draft', (select count(*) from pur_goods_receipts where company_id = v_c and status = 'draft')),
      'keuangan_bulan_ini', (select jsonb_build_object(
          'pendapatan', coalesce(sum(period_balance) filter (where account_type = 'revenue' and not is_header), 0),
          'hpp', coalesce(sum(period_balance) filter (where account_type = 'cogs' and not is_header), 0),
          'beban', coalesce(sum(period_balance) filter (where account_type = 'expense' and not is_header), 0),
          'laba_bersih', coalesce(sum(period_balance) filter (where account_type = 'revenue' and not is_header), 0)
            - coalesce(sum(period_balance) filter (where account_type in ('cogs', 'expense') and not is_header), 0))
        from grp_company_balances(v_c, date_trunc('month', v_today)::date, v_today, null))));
end $$;

-- ulasan untuk dianalisa temanya (komentar mentah, tanpa kontak pelanggan)
create or replace function ai_feedback_insights(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (sys_has_permission('*') or sys_has_permission('feedback.view')) then raise exception 'Butuh izin lihat ulasan'; end if;
  return jsonb_build_object(
    'ringkasan', crm_feedback_summary(p_from, p_to, null),
    'pertanyaan', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'jenis', kind, 'pertanyaan', label) order by sort_order)
      from crm_feedback_questions where company_id = sys_current_company_id()), '[]'::jsonb),
    'ulasan', coalesce((select jsonb_agg(jsonb_build_object('tanggal', (r.created_at at time zone 'Asia/Jakarta')::date, 'outlet', o.name,
        'bintang', r.overall, 'nps', r.nps, 'komentar', r.comment, 'jawaban', r.answers, 'status', r.status) order by r.created_at desc)
      from (select * from crm_feedback_responses where company_id = sys_current_company_id()
              and (created_at at time zone 'Asia/Jakarta')::date between p_from and p_to
              and (outlet_id is null or sys_can_access_outlet(outlet_id)) order by created_at desc limit 120) r
      left join sys_outlets o on o.id = r.outlet_id), '[]'::jsonb));
end $$;

-- rekap SDM per karyawan
create or replace function ai_hr_recap(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not (sys_has_permission('*') or sys_has_permission('hr.view')) then raise exception 'Butuh izin lihat data karyawan'; end if;
  if p_to < p_from or p_to - p_from > 92 then raise exception 'Rentang maksimal 3 bulan'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'alpa')::int desc, (x->>'telat')::int desc, x->>'nama') from (
    select jsonb_build_object(
      'nama', e.full_name, 'jabatan', p.name, 'outlet', o.name, 'status_kerja', e.employment_status, 'masuk_kerja', e.join_date,
      'terjadwal', (select count(*) from hr_rosters r where r.employee_id = e.id and r.work_date between p_from and least(p_to, v_today) and not r.is_off and r.shift_id is not null),
      'hadir', (select count(*) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to and a.check_in_at is not null),
      'telat', (select count(*) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to and a.late_minutes > 0),
      'total_menit_telat', (select coalesce(sum(a.late_minutes), 0) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to),
      'pulang_cepat', (select count(*) from hr_attendances a where a.employee_id = e.id and a.work_date between p_from and p_to and a.early_leave_minutes > 0),
      'alpa', (select count(*) from hr_rosters r where r.employee_id = e.id and r.work_date between p_from and least(p_to, v_today - 1) and not r.is_off and r.shift_id is not null
                 and not exists (select 1 from hr_attendances a where a.employee_id = e.id and a.work_date = r.work_date)
                 and hr_leave_on(e.id, r.work_date) is null),
      'cuti_hari', (select coalesce(sum(l.days), 0) from hr_leave_requests l where l.employee_id = e.id and l.status = 'approved' and l.start_date <= p_to and l.end_date >= p_from),
      'sisa_cuti_tahunan', (hr_leave_balance(e.id, extract(year from v_today)::int))->'remaining',
      'tugas_terbuka', (select count(*) from hr_tasks t where t.assignee_id = e.user_id and t.status in ('new', 'in_progress', 'review')),
      'tugas_lewat_tenggat', (select count(*) from hr_tasks t where t.assignee_id = e.user_id and t.status in ('new', 'in_progress', 'review') and t.due_date < v_today)) as x
    from hr_employees e left join hr_positions p on p.id = e.position_id left join sys_outlets o on o.id = e.outlet_id
    where e.company_id = v_c and e.is_active and (e.outlet_id is null or sys_can_access_outlet(e.outlet_id))) t), '[]'::jsonb);
end $$;

-- Semar boleh mengusulkan template SOP & pertanyaan form ulasan (tetap lewat persetujuan owner)
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
    'hr_departments', 'hr_positions', 'hr_employees', 'hr_announcements', 'hr_shifts', 'hr_leave_types',
    'hr_sop_templates', 'crm_feedback_questions']
$$;
