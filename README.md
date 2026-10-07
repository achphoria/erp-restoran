# Santap ERP

ERP restoran (POS, Kitchen Display, Inventory, Resep/HPP, Purchasing, Laporan) dengan **Supabase** + **React**.

## Cara menjalankan

### 1. Siapkan database
Buka Supabase Dashboard → project → **SQL Editor** → **New query**, lalu:
- **Database baru**: jalankan [`supabase/setup_all.sql`](supabase/setup_all.sql) (berisi semua migrasi 001–025)
- **Update database lama**, jalankan berurutan yang belum pernah dijalankan:
  - [`supabase/update_fase3.sql`](supabase/update_fase3.sql) (006–007: user & keuangan)
  - [`supabase/update_fase4.sql`](supabase/update_fase4.sql) (008–009: member, promo, QR order)
  - [`supabase/update_fase5.sql`](supabase/update_fase5.sql) (010: foto menu, menu habis, pindah/gabung/split bill, refund)
  - [`supabase/update_fase6.sql`](supabase/update_fase6.sql) (011–013: logo & profil, log aktivitas, approval, iPay88)
  - [`supabase/update_fase7.sql`](supabase/update_fase7.sql) (014–016: master produk, BOM & produksi, pricelist, paket, jadwal harga)
  - [`supabase/update_fase8.sql`](supabase/update_fase8.sql) (017: nama aplikasi bisa diatur di Pengaturan)
  - [`supabase/update_fase9.sql`](supabase/update_fase9.sql) (018: purpose waste/pemakaian/penyusutan ke COA + stock opname bertahap)
  - [`supabase/update_fase10.sql`](supabase/update_fase10.sql) (019: batch/lot & kedaluwarsa, HPP FIFO + FEFO, koli transfer, barcode)
  - [`supabase/update_fase11.sql`](supabase/update_fase11.sql) (020–021: Sales Order antar cabang & B2B, gudang per toko, settlement POS)
  - [`supabase/update_fase12.sql`](supabase/update_fase12.sql) (022: approval untuk semua transaksi + matriks pembuat/penyetuju)
  - [`supabase/update_fase13.sql`](supabase/update_fase13.sql) (023: user staf dibuat owner dengan username, lalu deploy Edge Function `staff-users`)
  - [`supabase/update_fase14.sql`](supabase/update_fase14.sql) (024: data contoh, reset, backup & restore)
  - [`supabase/update_fase15.sql`](supabase/update_fase15.sql) (025: Simple Manufacturing ala ESB)

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

## Fase 6: logo, profil, log, approval, iPay88
- **Logo & identitas**: Pengaturan → Perusahaan & Logo. Default: logo & nama *Santap ERP* (`app/public/favicon.svg`, `app/src/lib/brand.ts`).
- **Profil user**: klik nama di sidebar → foto & nomor HP. Owner bisa mengubah profil staf di Pengaturan → User.
- **Log aktivitas**: Pengaturan → Log Aktivitas. Mencatat login, perubahan data penting (nilai lama → baru), status order, dan keputusan approval.
- **Approval**: Pengaturan → Approval untuk menyalakan aturan & batas nominal (PO, biaya, penyesuaian stok/waste, opname, refund).
  Penyetuju diatur per role (grup *Persetujuan*). Kotak masuk di menu **Persetujuan**; aksi baru dijalankan saat disetujui.
- **iPay88** (disiapkan, belum aktif): Pengaturan → Pembayaran Online. Langkah:
  1. Deploy fungsi: `supabase functions deploy ipay88-checkout` dan `supabase functions deploy ipay88-callback --no-verify-jwt`
  2. Secret `APP_URL` = alamat aplikasi; daftarkan Backend URL `https://<project>.supabase.co/functions/v1/ipay88-callback` di iPay88
  3. **Cocokkan rumus tanda tangan** di `supabase/functions/_shared/ipay88.ts` dengan dokumen teknis iPay88 Anda.

## Fase 7: Master Produk (ala ESB)
- **Master Produk** (menu baru di Back Office): produk dengan tipe (bahan baku / setengah jadi / barang jadi / kemasan / habis pakai),
  flag dapat dibeli / dijual / direquest / PPN, toleransi terima, 5 field tambahan, multi-satuan dengan SKU, barcode, berat & volume.
- **Kategori bertipe** (Inventory / Non Inventory / Asset) dengan **akun COA sendiri**: HPP & persediaan di jurnal otomatis terpisah per kategori.
- **Min/max stok per gudang** + saran jumlah beli, bisa disalin antar gudang.
- **Import / Export Excel** produk & menu: template + validasi semua baris; satu baris salah = tidak ada yang disimpan, error bisa diunduh.
- **Resep (BOM)** Menu / Assembly / Disassembly, waste %, biaya tambahan, resep rahasia; **Produksi** di Inventory → Produksi.
- **Kalkulator Food Cost**: target food cost % atau markup → saran harga, simpan jadi resep.
- **Pricelist supplier** (Pembelian → Pricelist): harga berlaku otomatis di PO, peringatan bila harga di atas pricelist.
- **Menu paket** (Menu → Modifier & Paket): isi paket = menu, stok isi ikut terpotong; modifier bisa memotong bahan (Extra Telur).
- **Jadwal harga** (Menu → Jadwal Harga): harga menu berganti otomatis per hari/jam/tanggal/outlet/kanal di POS & QR.

## Fase 9: Dokumen stok & purpose ke COA
- **Inventory → Dokumen Stok**: Penyesuaian (+/−), **Waste**, **Pemakaian (Usage)**, **Penyusutan**, Stock Opname, Transfer.
  Penomoran: ADJ / WST / USG / SHR. Bisa disimpan draft dulu, lalu diposting (ikut aturan approval).
- **Purpose (sub alasan)** per jenis, mis. Waste → Human Error / Kedaluwarsa; Pemakaian → Peralatan Dapur / Makan Karyawan;
  Penyusutan → Bahan Baku / Produksi. Purpose bisa per dokumen atau per baris.
- **Inventory → Purpose & Akun**: atur purpose masuk ke akun COA mana. Kosong = akun default
  (5-1200 Waste, 5-1400 Pemakaian, 5-1500 Penyusutan, akun selisih stok kategori untuk Penyesuaian).
- **Stock opname bertahap**: buat daftar (per gudang/kategori) → stok sistem dipotret → isi hasil hitung (bisa draft) →
  review selisih → posting. Stok dikoreksi sebesar **selisih terhadap potret**, jadi penjualan setelah penghitungan tidak mengacaukan hasil.
  Produk yang tidak diisi tidak diubah.

## Fase 10: Batch, FIFO/FEFO, koli & barcode
- **Setiap stok masuk = 1 batch** (penerimaan, produksi, penyesuaian +) dengan kode label `L<YYMMDD><urut>`,
  no. lot supplier, tanggal kedaluwarsa & harga beli. Saldo lama otomatis jadi batch "Saldo awal".
- **Stok keluar memakai FEFO lalu FIFO**: batch yang kedaluwarsa duluan diambil duluan, yang tanpa kedaluwarsa
  urut tanggal masuk. **HPP = harga batch yang terpakai** (FIFO cost), dan jurnal HPP ikut harga ini.
- **Master Produk**: centang *Lacak batch & kedaluwarsa* (penerimaan wajib isi kedaluwarsa) dan *Umur simpan*
  (kedaluwarsa otomatis = tanggal terima + umur simpan).
- **Inventory → Batch & Kedaluwarsa**: sisa per batch, peringatan kedaluwarsa (juga di Dashboard), jejak lengkap
  per batch (diterima → dipakai di order/waste/transfer), koreksi lot/kedaluwarsa, **cetak label** printer thermal.
- **Scan barcode** (kamera HP atau scanner USB): label batch, barcode produk/satuan, label koli. Scan label batch di
  dokumen Waste/Pemakaian/dll = stok diambil dari batch itu.
- **Transfer per koli**: isi barang per koli → *Kirim* (stok **dalam perjalanan**) → cetak & tempel label koli →
  gudang tujuan scan label koli untuk menerima. Batch, kedaluwarsa & harga ikut pindah. Kekurangan kiriman dijurnal ke
  purpose *Hilang / Rusak di Perjalanan*.
- Refund penjualan mengembalikan stok ke batch asalnya. Stok minus tetap diizinkan (POS tidak terhambat) dan otomatis
  ditutup oleh batch berikutnya.

## Fase 11: Sales Order antar cabang & B2B, gudang per toko, settlement POS
- **Supplier**: pihak ke-3 atau **cabang internal**. Setiap outlet otomatis tersedia sebagai supplier internal.
- **Alur antar cabang** (satu perusahaan, jurnal per outlet):
  PO pembeli disetujui → **Sales Order** otomatis di penjual (harga dikunci dari **Pricelist Jual**) → penjual konfirmasi/tolak →
  **Pengiriman** dari gudang mana pun milik penjual (batch FEFO, koli & label, surat jalan) → draft **Penerimaan** otomatis di pembeli
  (scan label koli, isi qty diterima; batch & kedaluwarsa ikut) → **Sales Invoice** (qty **dikirim**) → **Tagihan Cabang** di pembeli →
  **Pembayaran** oleh pembeli melunasi piutang penjual. Kekurangan kiriman dicatat sebagai *Selisih Kiriman* sampai penjual memberi **nota kredit**.
- **Pelanggan B2B** (katering, reseller): SO manual, harga dari pricelist pelanggan, PPN, termin & limit kredit, pengiriman, invoice, pembayaran.
- **Akun baru**: Piutang/Hutang Antar Cabang, Penerimaan Antar Cabang Belum Ditagih, Penjualan Antar Cabang, HPP Antar Cabang,
  Selisih Kiriman, Penjualan SO (B2B), Retur & Potongan SO, PPN Keluaran. Di laporan gabungan, akun antar cabang saling menghapus.
- **Gudang & Lokasi** (Inventory): 1 toko bisa punya beberapa lokasi (mis. Supply Chain = Central Kitchen + Warehouse) dan memilih gudang POS.
- **Settlement POS**: penjualan per outlet × metode bayar × tanggal. Tunai = setoran ke bank, sedangkan EDC/QRIS/ojol = pencairan dengan potongan
  MDR/komisi otomatis dijurnal. Metode non tunai dicatat ke *Piutang Settlement* lalu dipindah ke bank saat cair. Selisih masuk *Selisih Kas & Settlement*.
- **Laporan**: pendapatan per sumber (Sales POS, Sales Order B2B, Sales Order antar cabang).
- **Sidebar baru**: grup bisa dilipat (Ringkasan, Kasir & Outlet, Penjualan, Pembelian, Persediaan, Master Data, Keuangan & Laporan), dan menu
  langsung membuka tab yang dituju.

## Fase 12: Approval semua transaksi (matriks)
- **Pengaturan → Approval Transaksi**: satu tabel untuk 14 transaksi (SO, nota kredit, pembayaran invoice, refund, settlement,
  PO, pricelist supplier, bayar supplier, penyesuaian/waste, opname, transfer, produk baru, biaya, jurnal manual).
  Per baris: approval aktif/nonaktif, batas nominal, role **pembuat**, dan role **penyetuju** (1 tingkat).
- Transaksi di atas batas dari pembuat masuk ke menu **Persetujuan**. Setelah disetujui, transaksi dijalankan otomatis.
  Penyetuju tidak perlu akses modulnya. Role yang sekaligus pembuat & penyetuju (dan Owner) langsung jalan.
- Settlement POS dinilai dari **selisih**, dan tanggal yang sedang menunggu persetujuan terkunci.

## Fase 13: User staf tanpa daftar sendiri
- **Owner** tetap mendaftar sendiri dengan email (halaman Daftar).
- **Staf dibuat owner/admin** di **Pengaturan → User → + Tambah User**: nama, **username**, password, role, dan outlet.
  Staf langsung bisa masuk dengan **username + password** (tanpa email, tanpa konfirmasi).
- Owner bisa **reset password** staf. Semua user bisa ganti password sendiri di **Profil Saya**.
- Di belakang layar, akun login staf dibuat oleh Edge Function `staff-users` (Supabase Auth admin API). Service role key hanya ada di server.
- Undangan via email tetap ada untuk staf yang ingin login dengan email pribadinya.

### Deploy Edge Function `staff-users` (sekali saja, lewat Dashboard)
1. Jalankan `supabase/update_fase13.sql` di SQL Editor.
2. Supabase Dashboard → **Edge Functions** → **Deploy a new function** → **Via Editor**.
3. Nama fungsi: `staff-users` (harus persis).
4. Hapus isi contoh, lalu tempel seluruh isi file [`supabase/functions/staff-users/index.ts`](supabase/functions/staff-users/index.ts).
5. Klik **Deploy function**. Biarkan **Verify JWT** aktif. Tidak perlu menambah secret.
6. Coba di aplikasi: Pengaturan → User → + Tambah User.

Alternatif lewat CLI: `supabase functions deploy staff-users`.

## Fase 14: Data contoh, reset, backup & restore (khusus owner)
- **Pengaturan → Data & Backup**:
  - **Data contoh**: pilih outlet, jumlah hari (7/14/30) & order per hari. Sistem membuat pembelian berkala, penjualan POS per hari
    (tanggal mundur), waste & pemakaian, biaya listrik/sewa, Sales Order B2B (kirim, invoice, bayar sebagian), lalu settlement.
    Memakai menu, resep & produk yang sudah ada. Lewat SQL: [`supabase/demo_data.sql`](supabase/demo_data.sql).
    Contoh BOM & produksi (assembly sambal, disassembly ayam utuh): [`supabase/demo_production.sql`](supabase/demo_production.sql).
  - **Backup**: download semua data perusahaan sebagai file `.json` (password & merchant key tidak ikut).
  - **Restore**: unggah file backup perusahaan yang sama, lalu master & transaksi diganti isi backup.
  - **Reset**: *Hapus semua transaksi* (master tetap, stok nol, nomor dokumen mulai lagi) atau *Reset total* (master + transaksi).
    Perusahaan, outlet, gudang, user, role, COA, metode bayar & pengaturan tidak pernah dihapus. Konfirmasi dengan mengetik nama perusahaan.

## Fase 15: Simple Manufacturing (ala ESB)
- **Persediaan → Produksi**: tombol **Assembly** / **Disassembly**. Isinya Branch, **lokasi asal** (bahan diambil) dan **lokasi tujuan** (hasil masuk),
  mis. dari Central Kitchen ke Warehouse.
- **Beberapa BOM dalam 1 dokumen** (tab per BOM). Nomor dokumen `SM/YYYYMMDD/0001 - 1`, `- 2`, dst.
- Per BOM: **satuan produksi** (mis. kg / PACK isi 9 PCS), manufacturing qty, **result qty** aktual & **kedaluwarsa** hasil (assembly).
- Tabel bahan/hasil seperti ESB: Stok, Qty BOM, **Total by system**, **Total qty aktual** (bisa diubah, selisih vs BOM ditandai),
  **weight factor** per transaksi (disassembly).
- **Actual costing**: HPP hasil = nilai bahan yang benar-benar terpakai (harga batch FIFO) + biaya tambahan BOM.
- Simpan draft lalu posting, atau langsung posting. Bisa wajib **approval** (matriks Approval Transaksi → Produksi).
- View `rpt_production_variances`: selisih pemakaian vs BOM per bahan.

## Roadmap berikutnya
- **Deploy** ke internet (Vercel/Netlify) supaya QR bisa dipakai tamu & aplikasi bisa dibuka dari tablet kasir
- **Fase 5 – Central kitchen & HR**: produksi bahan setengah jadi, absensi, payroll
- Integrasi GoFood/GrabFood, refund order yang sudah dibayar, mode offline POS, penutupan buku akhir tahun
