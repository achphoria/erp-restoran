-- =====================================================================
-- SANTAP ERP - DATA CONTOH TRANSAKSI (lewat SQL Editor)
-- Syarat: update_fase14.sql sudah dijalankan.
-- Cara pakai:
--   1. Ganti EMAIL_OWNER_ANDA dengan email login owner.
--   2. Ganti KATA_NAMA_OUTLET dengan sebagian nama OUTLET (bukan nama perusahaan),
--      mis. 'pluit' untuk outlet "PLUIT Jakarta Utara". Daftar outlet muncul di langkah 2.
--   3. Atur jumlah hari & order per hari bila perlu, lalu Run.
-- Alternatif tanpa SQL: aplikasi -> Pengaturan -> Data & Backup -> Buat data contoh.
-- Menghapusnya lagi: Pengaturan -> Data & Backup -> Hapus semua transaksi.
-- =====================================================================

-- 1) jalankan sebagai owner (fungsi memakai hak akses owner)
select set_config('request.jwt.claim.sub', id::text, false),
       set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, false)
from auth.users where email = 'EMAIL_OWNER_ANDA';

-- 2) daftar outlet perusahaan Anda (harus punya gudang POS)
select name as outlet, default_warehouse_id is not null as punya_gudang_pos
from sys_outlets where company_id = sys_current_company_id();

-- 3) 14 hari ke belakang, sekitar 20 order per hari
select sys_seed_demo_transactions(
  (select id from sys_outlets
   where company_id = sys_current_company_id() and name ilike '%KATA_NAMA_OUTLET%' and default_warehouse_id is not null
   limit 1),
  14,
  20
);
