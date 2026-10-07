-- =====================================================================
-- SANTAP ERP - DATA CONTOH TRANSAKSI (lewat SQL Editor)
-- Syarat: update_fase14.sql sudah dijalankan.
-- Cara pakai:
--   1. Ganti EMAIL_OWNER_ANDA dengan email login owner.
--   2. Ganti NAMA_OUTLET_ANDA dengan nama outlet (persis seperti di aplikasi).
--   3. Atur jumlah hari & order per hari di baris terakhir bila perlu.
--   4. Run. Butuh beberapa detik sampai ±1 menit.
-- Alternatif tanpa SQL: aplikasi -> Pengaturan -> Data & Backup -> Buat data contoh.
-- Menghapusnya lagi: Pengaturan -> Data & Backup -> Hapus semua transaksi.
-- =====================================================================

-- jalankan sebagai owner (fungsi memakai hak akses owner)
select set_config('request.jwt.claim.sub', id::text, false),
       set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, false)
from auth.users where email = 'EMAIL_OWNER_ANDA';

-- 14 hari ke belakang, sekitar 20 order per hari
select sys_seed_demo_transactions(
  (select id from sys_outlets where name = 'NAMA_OUTLET_ANDA' limit 1),
  14,
  20
);
