-- =====================================================================
-- SANTAP ERP - UPDATE FASE 21 (Logo brand & brand di landing page)
-- Untuk database yang SUDAH menjalankan fase 1-20.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/031_brand_logos_landing.sql
-- =====================================================================
-- SANTAP ERP - 031: LOGO BRAND & "BRAND YANG SUDAH BERSAMA SEMAR" DI LANDING PAGE
--   * Setiap brand bisa punya logo (sys_brands.logo_url, unggah di Pengaturan > Brand).
--   * show_on_landing: owner mengizinkan logo & nama brand tampil di halaman depan SEMAR.
--   * sys_public_brands(): bisa dipanggil tanpa login, HANYA mengembalikan nama & logo brand
--     yang aktif, punya logo, mengizinkan tampil, dan perusahaannya aktif.
-- =====================================================================

alter table sys_brands add column show_on_landing boolean not null default true;

create or replace function sys_public_brands()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'logo_url', b.logo_url) order by b.created_at), '[]'::jsonb)
  from sys_brands b join sys_companies c on c.id = b.company_id
  where b.is_active and b.show_on_landing and c.is_active and coalesce(b.logo_url, '') <> ''
$$;
grant execute on function sys_public_brands() to anon, authenticated;
