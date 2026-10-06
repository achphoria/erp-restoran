# ERP Resto

ERP restoran (POS, Kitchen Display, Inventory, Resep/HPP, Purchasing, Laporan) dengan **Supabase** + **React**.

## Cara menjalankan

### 1. Siapkan database
Buka Supabase Dashboard → project → **SQL Editor** → **New query**, lalu:
- **Database baru**: jalankan [`supabase/setup_all.sql`](supabase/setup_all.sql) (berisi semua migrasi 001–009)
- **Update database lama**, jalankan berurutan yang belum pernah dijalankan:
  - [`supabase/update_fase3.sql`](supabase/update_fase3.sql) (006–007: user & keuangan)
  - [`supabase/update_fase4.sql`](supabase/update_fase4.sql) (008–009: member, promo, QR order)

Lalu:
3. (Disarankan untuk development) **Authentication → Sign In / Providers → Email** → matikan **Confirm email**,
   supaya bisa langsung login setelah daftar tanpa cek email.

### 2. Jalankan aplikasi
```bash
cd app
npm install
npm run dev
```
Buka http://localhost:5173, klik **Daftar**, lalu isi nama restoran.
Centang "Isi dengan data contoh" untuk langsung mendapat menu, meja, bahan baku, resep, dan supplier.

### Deploy (GitHub Pages)
Setiap `git push` ke branch `main` otomatis menjalankan tes database lalu men-deploy aplikasi
(lihat [`.github/workflows/deploy-pages.yml`](.github/workflows/deploy-pages.yml)).
Alamatnya: `https://<username>.github.io/erp-restoran/`.
Pengaturan Supabase untuk build ada di `app/.env.production` (URL + anon key, aman untuk publik;
**jangan pernah** menaruh `service_role` key di repo ini).

### 3. Uji database lokal (opsional)
```bash
cd app
npm run test:db
```
Menjalankan semua migrasi di PostgreSQL lokal (PGlite) dan menguji alur bisnis + keamanan (33 skenario).

## Struktur

```
erp-restoran/
├── supabase/
│   ├── migrations/
│   │   ├── 001_phase1_master_pos.sql            tabel sistem, master, POS + RLS
│   │   ├── 002_phase2_inventory_purchasing.sql  tabel inventory, resep, purchasing
│   │   ├── 003_functions_pos.sql                order, bayar, diskon, void, shift
│   │   ├── 004_functions_inventory_purchasing.sql  potong stok, posting dokumen, view laporan
│   │   ├── 005_onboarding_demo_seed.sql         daftar perusahaan baru + data demo
│   │   ├── 006_users_settings.sql               undangan staf, kelola user, tambah outlet
│   │   ├── 007_finance.sql                      COA, jurnal otomatis, biaya, hutang, laporan keuangan
│   │   ├── 008_crm_promotions.sql               member, poin, level, promo otomatis & voucher
│   │   └── 009_qr_order.sql                     pesan mandiri lewat QR meja (tanpa login)
│   ├── setup_all.sql                            gabungan 001–009 (database baru)
│   ├── update_fase3.sql                         gabungan 006–007
│   └── update_fase4.sql                         gabungan 008–009
└── app/                                         React + Vite + TypeScript
    ├── scripts/test-db.mjs                      tes database
    └── src/
        ├── lib/        koneksi supabase, format rupiah, tipe data, cetak struk
        ├── context/    login, profil, outlet aktif, hak akses
        ├── components/ layout, modal, pembayaran
        └── pages/      Dashboard, POS, Order, Dapur, Shift, Menu, Inventory, Pembelian, Laporan,
                        Keuangan, Pengaturan
```

## Konvensi penamaan database

| Aturan | Contoh |
|---|---|
| Tabel: `prefix_modul` + snake_case + jamak | `pos_orders`, `inv_stock_movements` |
| Prefix: `sys_` sistem · `mst_` master · `pos_` kasir · `inv_` inventory · `pur_` pembelian · `fin_` keuangan · `crm_` pelanggan · `hr_` SDM · `rpt_` view laporan | |
| Detail dokumen: `<dokumen>_items` | `pos_order_items`, `pur_purchase_order_items` |
| Primary key `id` (uuid), foreign key `<tunggal>_id` | `outlet_id`, `menu_item_id` |
| Boolean `is_*`, waktu `*_at`, tanggal `*_date` | `is_active`, `paid_at`, `business_date` |
| Fungsi: `<prefix>_<kata_kerja>_<objek>` | `pos_pay_order`, `pur_post_goods_receipt` |

## Prinsip desain
- **Multi-perusahaan & multi-outlet**: semua tabel punya `company_id`, data antar perusahaan terisolasi lewat RLS.
- **Hak akses per role** (owner, manager, kasir, pelayan, dapur) lewat daftar permission di `sys_roles.permissions`.
- **Transaksi lewat fungsi database**: total order, pembayaran, dan stok dihitung di server, jadi tidak bisa dimanipulasi dari aplikasi.
- **Kartu stok**: setiap perubahan stok tercatat di `inv_stock_movements`, dan HPP memakai moving average.
- **Snapshot**: nama & harga menu disalin ke order, jadi laporan lama tetap benar walaupun menu diubah.

## Jurnal otomatis (Fase 3)

| Kejadian | Debit | Kredit |
|---|---|---|
| Order dibayar | Kas/Bank (per metode bayar), Diskon Penjualan, HPP | Penjualan, Service Charge, Hutang PB1, Pembulatan, Persediaan |
| Penerimaan barang | Persediaan | Hutang Usaha |
| Bayar supplier | Hutang Usaha | Kas/Bank |
| Waste | Bahan Terbuang | Persediaan |
| Penyesuaian / opname | Persediaan ↔ Selisih Stok | |
| Catat biaya | Beban … | Kas/Bank |
| Stok awal | Persediaan | Ekuitas Saldo Awal |

## Mengundang staf
Pengaturan → User & Undangan → **Undang Staf** (email + role + outlet).
Staf membuka aplikasi → **Daftar** dengan email tersebut → klik **Terima & Bergabung**.
Untuk produksi, nyalakan kembali **Confirm email** di Supabase supaya undangan hanya bisa diterima pemilik email asli.

## Member, promo & QR order (Fase 4)
- **Member**: daftar dari POS (nama + HP). Poin = belanja ÷ "Rp per poin" × pengali level; ditukar di layar bayar.
  Level (Regular/Silver/Gold) naik otomatis berdasarkan total belanja.
- **Promo otomatis** (tanpa kode, mis. happy hour) dipilih otomatis yang potongannya terbesar.
  **Voucher** (dengan kode) diinput kasir dan menggantikan promo otomatis.
  Syarat: tanggal, hari, jam, outlet, kanal, kategori/menu, minimal belanja, khusus member, kuota, batas per member.
- **QR order**: Menu → tab *Meja & QR* → cetak QR. Tamu scan → pesan → kasir dapat notifikasi 🔔 →
  **Konfirmasi QR** di Daftar Order → masuk Layar Dapur. Order dengan item belum dikonfirmasi tidak bisa dibayar.
  QR hanya bisa di-scan dari HP setelah aplikasi di-deploy ke internet (bukan `localhost`).

## Roadmap berikutnya
- **Deploy** ke internet (Vercel/Netlify) supaya QR bisa dipakai tamu & aplikasi bisa dibuka dari tablet kasir
- **Fase 5 – Central kitchen & HR**: produksi bahan setengah jadi, absensi, payroll
- Integrasi GoFood/GrabFood, refund order yang sudah dibayar, mode offline POS, penutupan buku akhir tahun
