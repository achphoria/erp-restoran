-- =====================================================================
-- SEMAR - 046: SEMAR AI x ASET (aset tahap 3)
--   * Briefing harian (ai_business_brief) ikut berisi bagian 'aset': kerusakan terbuka (mati total dulu),
--     perawatan terlambat & 7 hari ke depan, garansi mau habis, penyusutan belum dijalankan, opname terbuka, hutang aset
--   * ai_asset_insights(): data aset untuk dianalisa Semar (umur, % tersusut, biaya perawatan & jumlah kerusakan
--     12 bulan, jadwal perawatan, garansi) -> saran servis vs ganti baru, aset tanpa jadwal perawatan, dll.
--   Usulan jadwal perawatan oleh Semar dijalankan lewat ast_save_plan (setelah disetujui owner).
-- =====================================================================

-- ringkasan aset untuk briefing (perusahaan & outlet yang bisa diakses user ini)
create or replace function ai_asset_brief()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if v_c is null then return null; end if;
  if not exists (select 1 from ast_assets where company_id = v_c) then return jsonb_build_object('jumlah_aset', 0); end if;
  return (with a as (
      select * from ast_assets where company_id = v_c and status = 'active' and (outlet_id is null or sys_can_access_outlet(outlet_id)))
    select jsonb_build_object(
      'jumlah_aset', (select count(*) from a),
      'nilai_buku', (select coalesce(sum(acquisition_cost - accumulated_depreciation), 0) from a),
      'kerusakan_terbuka', coalesce((select jsonb_agg(jsonb_build_object('aset', x.name, 'kode', x.asset_number, 'outlet', x.outlet,
          'tingkat', case x.severity when 'down' then 'mati total' when 'major' then 'terganggu' else 'masih bisa dipakai' end,
          'status', x.status, 'sejak_jam', x.hours, 'laporan', left(x.description, 120)) order by x.sev_order, x.reported_at)
        from (select a.name, a.asset_number, coalesce(o.name, 'Kantor pusat') outlet, r.severity, r.status, r.description, r.reported_at,
                case r.severity when 'down' then 0 when 'major' then 1 else 2 end sev_order,
                round(extract(epoch from (now() - r.reported_at)) / 3600) hours
              from ast_repairs r join a on a.id = r.asset_id left join sys_outlets o on o.id = a.outlet_id
              where r.status in ('open', 'in_progress', 'waiting_parts') order by sev_order, r.reported_at limit 8) x), '[]'::jsonb),
      'perawatan_terlambat', coalesce((select jsonb_agg(jsonb_build_object('aset', x.name, 'perawatan', x.title, 'jatuh_tempo', x.next_due_date,
          'tugas', x.task_number) order by x.next_due_date)
        from (select a.name, pl.title, pl.next_due_date, t.task_number from ast_maintenance_plans pl join a on a.id = pl.asset_id
              left join hr_tasks t on t.id = pl.open_task_id
              where pl.is_active and pl.next_due_date < v_today order by pl.next_due_date limit 8) x), '[]'::jsonb),
      'perawatan_7_hari', (select count(*) from ast_maintenance_plans pl join a on a.id = pl.asset_id
        where pl.is_active and pl.next_due_date between v_today and v_today + 7),
      'garansi_habis_30_hari', coalesce((select jsonb_agg(jsonb_build_object('aset', name, 'kode', asset_number, 'sampai', warranty_until) order by warranty_until)
        from a where warranty_until between v_today and v_today + 30), '[]'::jsonb),
      'perlu_disusutkan_sampai_bulan_lalu', (select count(*) from a cross join lateral ast_pending_depreciation(a, (date_trunc('month', v_today) - interval '1 month')::date) d
        where d.months > 0),
      'opname_terbuka', (select count(*) from ast_audits x where x.company_id = v_c and x.status = 'open'),
      'mutasi_pelepasan_menunggu', (select count(*) from ast_transfers t where t.company_id = v_c and t.status = 'pending_approval')
        + (select count(*) from ast_disposals x where x.company_id = v_c and x.status = 'pending_approval'),
      'hutang_aset', (select coalesce(sum(a.acquisition_cost - coalesce((select sum(amount) from ast_payments p where p.asset_id = a.id), 0)), 0)
        from a where a.funding = 'payable')));
end $$;

-- briefing harian = briefing lama + bagian aset
alter function ai_business_brief(int) rename to ai_business_brief_v1;
revoke execute on function ai_business_brief_v1(int) from public, anon, authenticated;
create or replace function ai_business_brief(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return ai_business_brief_v1(p_days) || jsonb_build_object('aset', ai_asset_brief());
end $$;

-- data aset untuk dianalisa Semar
create or replace function ai_asset_insights()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if v_c is null or not (sys_has_permission('*') or ast_can_view()) then raise exception 'Butuh izin lihat aset'; end if;
  return jsonb_build_object(
    'ringkasan', ast_summary() || ast_maintenance_counts(),
    'aset', coalesce((select jsonb_agg(x order by (x->>'biaya_perawatan_12_bulan')::numeric desc, x->>'kode') from (
      select jsonb_build_object('id', a.id, 'kode', a.asset_number, 'nama', a.name, 'kategori', k.name, 'outlet', coalesce(o.name, 'Kantor pusat'),
        'lokasi', a.location, 'merek', a.brand_model,
        'umur_bulan', ((extract(year from age(v_today, a.acquisition_date)) * 12) + extract(month from age(v_today, a.acquisition_date)))::int,
        'umur_manfaat_bulan', a.useful_life_months,
        'persen_tersusut', round(100.0 * a.accumulated_depreciation / greatest(a.acquisition_cost - a.residual_value, 1)),
        'harga_perolehan', a.acquisition_cost, 'nilai_buku', a.acquisition_cost - a.accumulated_depreciation,
        'biaya_perawatan_12_bulan', coalesce((select sum(cost) from ast_maintenance_logs l where l.asset_id = a.id and l.performed_on > v_today - 365), 0)
          + coalesce((select sum(cost) from ast_repairs r where r.asset_id = a.id and r.reported_at > now() - interval '365 days'), 0),
        'kerusakan_12_bulan', (select count(*) from ast_repairs r where r.asset_id = a.id and r.reported_at > now() - interval '365 days'),
        'kerusakan_terbuka', (select count(*) from ast_repairs r where r.asset_id = a.id and r.status in ('open', 'in_progress', 'waiting_parts')),
        'jadwal_perawatan', coalesce((select jsonb_agg(jsonb_build_object('perawatan', pl.title, 'tiap', pl.interval_value || ' ' ||
            case pl.interval_unit when 'day' then 'hari' when 'week' then 'minggu' else 'bulan' end, 'berikutnya', pl.next_due_date))
          from ast_maintenance_plans pl where pl.asset_id = a.id and pl.is_active), '[]'::jsonb),
        'garansi_sampai', a.warranty_until) as x
      from ast_assets a join ast_categories k on k.id = a.category_id left join sys_outlets o on o.id = a.outlet_id
      where a.company_id = v_c and a.status = 'active' and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id))
      order by a.asset_number limit 200) s), '[]'::jsonb),
    'kerusakan_60_hari', coalesce((select jsonb_agg(jsonb_build_object('kode', a.asset_number, 'aset', a.name, 'tingkat', r.severity, 'status', r.status,
        'laporan', left(r.description, 160), 'tindakan', r.resolution, 'biaya', r.cost, 'tanggal', (r.reported_at at time zone 'Asia/Jakarta')::date) order by r.reported_at desc)
      from ast_repairs r join ast_assets a on a.id = r.asset_id
      where r.company_id = v_c and r.reported_at > now() - interval '60 days' and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id))), '[]'::jsonb));
end $$;

revoke execute on function ai_asset_brief() from public, anon;
grant execute on function ai_asset_brief() to authenticated;
revoke execute on function ai_asset_insights() from public, anon;
grant execute on function ai_asset_insights() to authenticated;
revoke execute on function ai_business_brief(int) from public, anon;
grant execute on function ai_business_brief(int) to authenticated;
