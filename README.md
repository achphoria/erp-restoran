# SEMAR
**S**istem **E**RP, **M**anajemen, **A**kuntansi & **R**estoran: abdi setia usaha kuliner.

> Nama SEMAR diambil dari tokoh punakawan wayang: tampil sebagai abdi, padahal dewa yang paling bijak. Lambangnya gunungan (kayon) dengan cahaya blencong. Modul diibaratkan punakawan: Semar (pusat kendali), Gareng (kasir), Petruk (stok & gudang), Bagong (keuangan & laporan).

ERP restoran (POS, Kitchen Display, Inventory, Resep/HPP, Purchasing, Laporan) dengan **Supabase** + **React**.

## Cara menjalankan

### 1. Siapkan database
Buka Supabase Dashboard → project → **SQL Editor** → **New query**, lalu:
- **Database baru**: jalankan [`supabase/setup_all.sql`](supabase/setup_all.sql) (berisi semua migrasi 001–047)
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
  - [`supabase/update_fase16.sql`](supabase/update_fase16.sql) (026: akses branch per user + role template)
  - [`supabase/update_fase17.sql`](supabase/update_fase17.sql) (027: platform admin, grup usaha multi PT, master brand & akses per brand)
  - [`supabase/update_fase18.sql`](supabase/update_fase18.sql) (028: daftar pendaftar baru & badge di Console Platform)
  - [`supabase/update_fase19.sql`](supabase/update_fase19.sql) (029: perbaikan error saat pendaftar baru membuat usaha)
  - [`supabase/update_fase20.sql`](supabase/update_fase20.sql) (030: agent AI Semar, lalu deploy Edge Function `semar-agent`)
  - [`supabase/update_fase21.sql`](supabase/update_fase21.sql) (031: logo per brand & "Brand yang sudah bersama SEMAR" di landing page)
  - [`supabase/update_fase22.sql`](supabase/update_fase22.sql) (032: Semar bisa forecasting kebutuhan beli & membuat PO; deploy ulang Edge Function `semar-agent`)
  - [`supabase/update_fase23.sql`](supabase/update_fase23.sql) (033: SDM / HR fase A: data karyawan, jabatan & departemen, pengumuman, Beranda Saya)
  - [`supabase/update_fase24.sql`](supabase/update_fase24.sql) (034: SDM / HR fase B: absensi foto + GPS, titik lokasi outlet, jadwal shift, koreksi absen)
  - [`supabase/update_fase25.sql`](supabase/update_fase25.sql) (035: SDM / HR fase C: cuti & izin, saldo cuti, persetujuan cuti)
  - [`supabase/update_fase26.sql`](supabase/update_fase26.sql) (036: Tugas kanban & SOP harian)
  - [`supabase/update_fase27.sql`](supabase/update_fase27.sql) (037: SDM / HR fase E: penilaian kinerja)
  - [`supabase/update_fase28.sql`](supabase/update_fase28.sql) (038: User Management ↔ data karyawan)
  - [`supabase/update_fase29.sql`](supabase/update_fase29.sql) (039: struk 80mm, QR ulasan & analisa ulasan pelanggan)
  - [`supabase/update_fase30.sql`](supabase/update_fase30.sql) (040: self-order kiosk)
  - [`supabase/update_fase31.sql`](supabase/update_fase31.sql) (041: dashboard grup & laporan konsolidasi)
  - [`supabase/update_fase32.sql`](supabase/update_fase32.sql) (042: transaksi antar-PT dalam grup)
  - [`supabase/update_fase33.sql`](supabase/update_fase33.sql) (043: Semar makin pintar: briefing harian, ulasan, rekap SDM, membuat tugas & SOP; deploy ulang Edge Function `semar-agent`)
  - [`supabase/update_fase34.sql`](supabase/update_fase34.sql) (044: manajemen aset tetap: daftar aset, label QR, penyusutan, mutasi & pelepasan)
  - [`supabase/update_fase35.sql`](supabase/update_fase35.sql) (045: perawatan rutin → Tugas, laporan kerusakan, opname aset scan QR)
  - [`supabase/update_fase36.sql`](supabase/update_fase36.sql) (046: Semar membaca aset & briefing harian berisi aset; deploy ulang Edge Function `semar-agent`)
  - [`supabase/update_fase37.sql`](supabase/update_fase37.sql) (047: modul per perusahaan, wizard owner baru & panduan memulai; deploy ulang Edge Function `semar-agent`)

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
Alamatnya: `https://<username>.github.io/<nama-repo>/` (repo ini: `https://achphoria.github.io/semar-erp/`).
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
semar-erp/
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
│   ├── setup_all.sql                            gabungan semua migrasi (database baru)
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
- **Logo & identitas**: Pengaturan → Perusahaan & Logo. Nama sistem **SEMAR** tetap (hardcode di `app/src/lib/brand.ts`); perusahaan hanya bisa mengganti logo yang tampil di sidebar & struk. Landing page di `/`, form masuk di `/login`.
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

## Fase 16: Akses branch per user & role template
- Setiap user punya **akses branch**: *Semua branch* (termasuk branch baru, untuk Head Office) atau *Branch tertentu*
  (1 branch = terkunci, beberapa branch = bisa pindah lewat pilihan outlet di sidebar). Owner selalu semua branch.
- **Data dikunci per branch di database**: POS, shift, refund, settlement, stok, batch, kartu stok, dokumen stok, transfer,
  produksi, PO, penerimaan, sales order, pengiriman, invoice, pembayaran & permintaan approval. User branch A tidak bisa melihat
  maupun membuat dokumen untuk gudang branch B. Transfer & SO antar cabang terlihat oleh kedua branch.
- **Pengaturan → Role → Buat role template**: GM, Finance & Accounting, Purchasing, Cost Control, Sales B2B, Marketing, Admin/HR-IT,
  Head Chef CK, Staf Gudang, Store Manager, Supervisor (lengkap dengan hak akses, penyetuju & akses branch default).

## Fase 17: Platform admin, grup usaha (multi PT) & brand
Tingkatan: **Platform Admin** (developer) → **Grup usaha** → **Perusahaan / PT** → **Brand** → **Outlet / branch**.
- **Owner & staf biasa** hanya melihat PT-nya sendiri (data antar PT tetap terpisah total).
- **Platform Admin** (menu *Platform*): melihat semua perusahaan yang memakai aplikasi, membuat grup usaha, memetakan PT ke grup,
  menonaktifkan / mengaktifkan PT, dan **Masuk** ke PT mana pun (mode support = akses penuh seperti owner).
  Selama mode support muncul banner kuning, dan semua perubahan tercatat di log aktivitas PT itu dengan tanda *(Platform support)*.
- **Grup usaha**: beberapa PT dikelompokkan (mapping, bukan merge). *Pemilik grup* bisa pindah antar PT di grupnya
  lewat pilihan 🏢 perusahaan di sidebar, dengan akses penuh (log ditandai *(Pemilik grup)*).
  PT baru tetap dibuat lewat daftar biasa, lalu Platform Admin memasukkannya ke grup.
- **Pengaturan → Brand**: 1 PT bisa punya beberapa brand; setiap outlet dipilih brand-nya (menu kasir mengikuti brand outlet).
  Setiap brand bisa diberi **logo** (tampil di sidebar outlet brand itu). Bila diizinkan owner (*Tampilkan di halaman depan SEMAR*, default aktif),
  logo & nama brand muncul di landing page bagian **Brand yang sudah bersama SEMAR** (hanya nama & logo, tanpa data lain).
- **Akses per brand** (User Management → Akses): user melihat semua branch milik brand tertentu, termasuk branch baru brand itu.

### Menjadikan akun Anda Platform Admin (sekali, lewat SQL Editor)
Status Platform Admin sengaja **tidak bisa** diberikan dari aplikasi. Jalankan di Supabase SQL Editor (ganti emailnya):
```sql
insert into sys_platform_admins (user_id, note)
select id, 'developer' from auth.users where email = 'EMAIL_ANDA@contoh.com';
```
**Pendaftar baru** (Platform → Pendaftar): semua akun yang daftar sendiri, termasuk yang belum setup usaha, dengan status *Belum setup* / *Owner PT* / *Staf*. Menu Platform menampilkan badge jumlah pendaftar baru sejak tab ini terakhir dibuka.

Untuk mencabut: `delete from sys_platform_admins where user_id = (select id from auth.users where email = 'EMAIL_ANDA@contoh.com');`

## Agent Semar (AI kepala konsultan, khusus owner)
Semar ada di **Dashboard → Pendopo**: tombol **Tanya Semar** / tombol **Tanya** di atas karakter Semar.
Owner bisa bertanya tutorial, minta analisa data, dan melampirkan file (Excel, CSV, PDF, gambar) untuk dimigrasi ke master data
(supplier, produk, kategori, satuan, menu, resep, pelanggan, pricelist).
- **Khusus owner** (role dengan hak `*`). Staf melihat pesan "Semar hanya melayani owner".
- Semar membaca & menulis memakai **akun owner sendiri**, jadi hanya data perusahaan owner itu yang tersentuh (dijamin RLS database).
- Setiap perubahan data muncul sebagai **kartu usulan**; data baru berubah setelah owner menekan **Setujui & jalankan**.
- Yang bisa diubah langsung hanya **master data**. Transaksi yang bisa dibuat: **Purchase Order** (usulan PO dengan pratinjau harga;
  draft atau langsung diajukan lewat matriks approval). Transaksi lain (penjualan, stok, jurnal) hanya dibaca.
- **Forecasting kebutuhan beli**: pemakaian per hari dari kartu stok, stok cukup berapa hari, saran qty (satuan beli),
  opsi supplier & harga dari pricelist aktif, dan pembelian terakhir. Contoh: *"Bahan apa yang perlu dibeli 7 hari ke depan? Buatkan PO-nya"*.
- **Briefing & saran harian**: penjualan hari ini vs kemarin, jam ramai, menu terlaris & tidak laku, stok menipis/kedaluwarsa,
  siapa belum absen/telat, cuti & koreksi menunggu, tugas lewat tenggat, ulasan buruk, persetujuan menunggu, laba rugi bulan ini,
  lalu 3-5 saran tindakan prioritas. Contoh: *"Ringkasan usaha hari ini & saran prioritas"*.
- **Ulasan pelanggan**: tema keluhan & pujian, aspek terendah, NPS, tanpa menampilkan kontak pelanggan.
- **Rekap SDM**: per karyawan hadir, telat (menit), pulang cepat, alpa, cuti, sisa cuti, tugas lewat tenggat (maks 3 bulan).
- **Tugas & SOP**: Semar mengusulkan tugas untuk orang / tim (kartu usulan, dibuat setelah disetujui), template SOP harian,
  dan pertanyaan form ulasan.
- Batas 40 pesan per jam per owner; token yang terpakai tercatat di tabel `ai_chat_messages`.

### Setup (sekali saja)
1. Jalankan `supabase/update_fase20.sql` di SQL Editor.
2. **Deploy Edge Function**: Supabase Dashboard → **Edge Functions** → **Deploy a new function** → *Via Editor*,
   beri nama **`semar-agent`**, hapus isi contoh lalu tempel seluruh isi
   [`supabase/functions/semar-agent/index.ts`](supabase/functions/semar-agent/index.ts), klik **Deploy**.
   Di pengaturan fungsi, matikan **Verify JWT with legacy secret** (fungsi mengecek login & owner sendiri).
3. **Isi kunci API Claude** sebagai secret: Edge Functions → **Secrets** → **Add new secret**:
   - `ANTHROPIC_API_KEY` = kunci dari [console.anthropic.com](https://console.anthropic.com) → API keys → Create key.
   - (opsional) `SEMAR_MODEL` = model Claude, default `claude-sonnet-5-5`.
   Kunci hanya disimpan di server Supabase, tidak pernah dikirim ke browser. **Jangan menempelkan kunci API di chat, kode, atau repo.**
4. Atur batas belanja di Claude Console (Settings → Limits) supaya biaya terkendali.

## SDM / HR
Konsep: **karyawan dulu, baru akun**. Data orang dikelola di **SDM / HR**, akun login & hak akses di **User Management**.
- **Karyawan**: biodata lengkap (pribadi, identitas KTP/NPWP/BPJS, kontak & kontak darurat, pekerjaan, riwayat pendidikan & kerja),
  foto & dokumen di storage **privat** (`hr-files`, dibuka lewat link sementara), nomor karyawan otomatis (EMP-0001),
  pengingat kontrak habis (30 hari) & ulang tahun. Data sensitif hanya terlihat HR (`hr.view`/`hr.manage`), owner, dan karyawan itu sendiri.
- **Buatkan akun login** langsung dari data karyawan (role default mengikuti jabatan), atau tautkan ke akun yang sudah ada.
- **Dari User Management**: akun tanpa data karyawan diberi tanda *Belum ada data karyawan* + tombol **Buat data karyawan** (nama, HP, email asli, outlet & jabatan diisi otomatis). Saat **+ Tambah User**, ada pilihan *Buat juga data karyawan* (aktif bawaan). Daftar tautan hanya berisi id & nomor karyawan, tanpa data pribadi.
- **Jabatan & Departemen**, **Pengumuman** (semua / per outlet / per role, dengan jumlah pembaca).
- **Beranda Saya** (`/saya`, untuk semua karyawan): kartu karyawan, pengumuman, ubah kontak sendiri. User tanpa menu lain otomatis diarahkan ke sini.
- **Absensi foto + GPS** (dari Beranda Saya di HP): selfie langsung dari kamera depan (dengan cap waktu & koordinat), lokasi GPS akurasi tinggi.
  Jam absen diambil dari **server** dan jarak ke outlet dihitung di **server** (bukan di HP). Di luar radius / GPS kurang akurat /
  masuk di hari libur tetap tercatat tapi **ditandai untuk direview**. Foto hanya bisa diunggah ke folder absensi milik sendiri.
  Shift malam (lewat tengah malam) didukung.
- **Titik lokasi outlet**: Pengaturan → Outlet → *Lokasi absen karyawan* (latitude, longitude, radius; tombol **Pakai lokasi saya**).
- **Jadwal Shift**: template shift (Pagi/Siang/Malam, warna), papan mingguan dengan "kuas" (klik sel untuk mengisi, klik nama untuk isi seminggu),
  **salin minggu lalu**. Karyawan melihat jadwal minggu ini di Beranda Saya.
- **Absensi (rekap)**: hadir / telat / alpa (dijadwalkan tapi tidak absen) / libur, foto masuk & pulang, jarak, lokasi di peta,
  review absen yang ditandai, **pengajuan koreksi** (lupa absen / HP mati) yang disetujui HR atau atasan langsung, export **Excel**
  (ringkasan per karyawan + detail), aturan (toleransi telat, wajib foto / GPS, batas akurasi). Badge menu untuk yang perlu direview.
- Izin baru: `hr.attendance` (atur jadwal shift & review absensi), cocok untuk kepala outlet. Terbatas ke outlet yang boleh diaksesnya.
- **Cuti & izin**: jenis cuti standar (tahunan, sakit, izin tidak dibayar, menikah, duka, melahirkan; bisa ditambah/diubah),
  saldo cuti tahunan (default 12 hari; aturan *berhak setelah 12 bulan* / *prorata* / *langsung*), penyesuaian saldo (saldo awal, sisa tahun lalu).
  Karyawan mengajukan dari Beranda Saya (bisa setengah hari, lampiran surat dokter wajib untuk sakit ≥ 2 hari, hari libur di jadwal tidak dihitung).
  Persetujuan: menu **Persetujuan** (izin `approval.leave`), tab **Cuti & Izin** (HR), atau **atasan langsung** dari Beranda Saya (kartu *Persetujuan tim*).
  Kalender cuti tim per bulan, saldo semua karyawan + export Excel. Cuti yang disetujui tampil di jadwal & rekap absensi (tidak dihitung alpa).
- **Penilaian kinerja**: template per role / jabatan (kriteria berbobot, skala 1–5; tombol *Pakai contoh* berisi kriteria standar restoran).
  Kriteria **otomatis** dihitung dari data periode: kehadiran (hadir / hari terjadwal, cuti tidak dihitung), ketepatan waktu, tugas selesai
  tepat waktu, kepatuhan SOP. Periode (mis. per kuartal) → **Mulai penilaian** → karyawan **menilai diri** → **atasan langsung** / HR menilai
  (nilai diri tampil berdampingan; kekuatan, yang perlu ditingkatkan, target) → karyawan **membaca & konfirmasi**. Nilai akhir + grade
  A (≥ 4,5) / B (≥ 3,75) / C (≥ 3) / D (≥ 2) / E. Nilai atasan tidak terlihat karyawan sebelum dikirim. Rekap per periode + Excel, bisa dicetak.
  Izin `hr.appraisal`; tindakan karyawan & atasan ada di Beranda Saya (badge di menu Beranda Saya).
- Belum ada: payroll / gaji (sengaja ditunda).

## Struk 80mm & ulasan pelanggan
- **Struk thermal 80mm** (semua tempat cetak: setelah bayar, Daftar Order, kiosk): logo brand (dicetak hitam-putih), nama brand & outlet, alamat, telp, NPWP,
  teks atas/bawah per outlet, banner tipe pesanan + meja, kasir, item + modifier + catatan, pajak/service/pembulatan, pembayaran & kembalian, poin member.
  Dicetak lewat iframe (tanpa popup). **Cetak otomatis** bisa diaktifkan per perangkat kasir. Order yang belum dibayar dicetak sebagai **TAGIHAN**; cetak ulang ditandai *SALINAN*.
  Atur di **Pengaturan → Outlet → Struk** (ada **Pratinjau struk** & uji cetak).
- **QR ulasan di struk** (satu form ulasan + saran, tanpa login, sekali per struk, berlaku N hari): bintang keseluruhan (wajib, otomatis lanjut),
  nilai aspek (rasa, kecepatan, keramahan, kebersihan, harga), rekomendasi 0–10 (NPS), yang paling disukai, saran teks, kontak opsional + izin dihubungi.
  Satu pertanyaan per layar, < 1 menit (mengikuti praktik riset: maks ±5 layar, tombol besar). Pemberi 4–5 bintang ditawari ulasan Google Maps; hadiah opsional untuk semua pengisi.
- **Ulasan Pelanggan** (menu Kasir & Outlet): rata-rata bintang, NPS, tingkat respons, sebaran bintang, tren mingguan, nilai per aspek, yang disukai, per outlet;
  daftar ulasan + filter + **tindak lanjut** (WhatsApp pelanggan yang bersedia), export Excel; atur pertanyaan & teks form. Izin `feedback.view` / `feedback.manage`.
  Form publik hanya menampilkan nama outlet/brand & tanggal (tanpa isi pesanan/harga).

## Dashboard grup & laporan konsolidasi
Menu **Dashboard Grup** (`/grup`) untuk **pemilik grup usaha** (beberapa PT) dan Platform Admin. Hanya membaca, tidak mengubah data PT.
- **Ringkasan semua PT sekaligus**: penjualan bersih (tanpa pajak/service) + pertumbuhan vs periode sebelumnya, rata-rata transaksi,
  laba bersih dari jurnal, kehadiran karyawan hari ini, grafik penjualan harian bertumpuk per PT, tabel perbandingan PT
  (porsi penjualan, stok menipis, rating ulasan, approval & cuti menunggu, tombol **Masuk** ke PT), outlet & menu terlaris se-grup.
- **Laba rugi konsolidasi** & **neraca konsolidasi**: kolom per PT + **Eliminasi** + **Konsolidasi**, digabung per kode akun, kelompok bisa dilipat, export Excel.
  Akun kontra (diskon penjualan, akumulasi penyusutan, prive) bernilai minus; laba ditahan = akumulasi laba rugi (belum ada jurnal penutup).
- **Eliminasi antar-PT**: baris jurnal bertanda lawan transaksi PT lain dalam grup yang sama (`fin_journal_lines.counterparty_company_id`)
  dikeluarkan dari konsolidasi. Diisi otomatis oleh transaksi antar-PT (tahap berikutnya).
- Rentang cepat: hari ini, 7 hari, bulan ini, bulan lalu, tahun ini, atau tanggal bebas.

## Transaksi antar-PT dalam grup
PT dalam satu grup bisa saling jual-beli dengan alur lengkap di kedua sisi:
1. PT pembeli membuat **PO** ke supplier dari kelompok **PT dalam grup** (supplier & pelanggan antar-PT dibuat otomatis untuk setiap
   pasangan PT saat PT masuk grup; dinonaktifkan saat keluar grup). Barang dicocokkan lewat **kode barang & satuan yang sama** di kedua PT;
   harga dari Pricelist Jual PT penjual bila ada.
2. PO disetujui → **Sales Order** otomatis di PT penjual (status Baru). Penjual konfirmasi / tolak (ditolak → PO pembeli batal). Status SO tampil di catatan PO.
3. Penjual mengirim **Pengiriman** → **Penerimaan Barang** draft otomatis di PT pembeli (qty sesuai kiriman), pembeli posting → stok + hutang.
   Penerimaan manual untuk PO antar-PT ditolak.
4. Penjual membuat **Invoice** (piutang & pendapatan), pembeli membayar hutang, penjual mencatat pembayaran.
5. Semua jurnal dokumen antar-PT diberi tanda `counterparty_company_id` → **dieliminasi** di laporan konsolidasi (penjualan, HPP, piutang, hutang).
   Penyederhanaan: laba antar-PT yang masih ada di stok pembeli tidak disesuaikan saat stok itu dijual lagi.
- **Dashboard Grup → Antar-PT**: saldo piutang vs hutang per pasangan PT (cocok / selisih) & daftar dokumen dengan progres kirim/terima/tagih/bayar.
- Tautan lintas PT satu arah dan `on delete set null`, sehingga **reset data** satu PT tidak terhalang data PT lain.

## Self-order kiosk
Layar sentuh **berdiri (portrait, mis. TV 1080×1920)** untuk pelanggan memesan sendiri, dibuka di `/kiosk/<token>` tanpa login staf.
Atur di menu **Kasir & Outlet → Self Kiosk** (izin `kiosk.manage`).
- Alur singkat (mengikuti praktik kiosk QSR: sedikit langkah, satu keputusan per layar, keranjang selalu di tempat yang sama, upsell sekali saja):
  **layar sambutan** (menu unggulan bergantian + tombol besar *Makan di sini / Bawa pulang*) → **menu** (kategori bergambar di kiri,
  baris *Rekomendasi* di atas, kartu besar dengan label *Terlaris* otomatis, label sendiri seperti *Baru/Promo/Pedas*, *Habis*) →
  **detail** (pilihan wajib/opsional, jumlah) → **Lengkapi pesananmu?** (1 layar) → **cek pesanan** (keyboard layar untuk nama) →
  **nomor antrean besar** + struk otomatis.
- Bayar di kasir: pesanan masuk **Daftar Order** berlabel *Kiosk K012*; **dapur baru menerima setelah dibayar** (otomatis saat kasir menerima pembayaran).
- Harga mengikuti kanal (dine in / takeaway). Tidak disentuh N detik → "Masih di sana?" lalu kembali ke awal.
- Pengaturan per kiosk: outlet, makan di sini / bawa pulang, teks sambutan, waktu idle, cetak struk; status online & jumlah pesanan hari ini; **ganti link** bila bocor.
- Server memvalidasi setiap pesanan (brand outlet, stok habis, pilihan sesuai grup & batas min/maks, maks 30 item, maks 6 pesanan/menit per kiosk).
- Pemasangan: Chrome `--kiosk --kiosk-printing "<link>"` + printer thermal 80mm sebagai default (struk tercetak tanpa dialog).

## Tugas (kanban) & SOP harian
Menu **Tugas** untuk semua user (badge = tugas baru untuk saya + yang menunggu review saya).
- **Papan kanban**: Baru → Dikerjakan → Review → Selesai → Arsip. Geser kartu (desktop) atau pakai tombol di detail (HP).
  Filter *Untuk saya / Saya buat / Semua*, outlet, cari, tampilkan arsip.
- **Penerima**: satu orang, atau satu **tim (role)** (mis. "Tim Kasir"): anggota pertama yang mengerjakan otomatis jadi penerima.
- **Isi tugas**: prioritas, tenggat (merah bila lewat), label, checklist, **wajib foto bukti** (kamera langsung), tautan dokumen, komentar & riwayat.
- **Alur review**: tugas untuk orang lain diajukan ke *Review*; pembuat / manajer (`task.manage`) menyetujui *Selesai* atau mengembalikan
  dengan catatan. Checklist harus lengkap & foto bukti ada sebelum review. Tugas pribadi bisa langsung selesai.
- **SOP harian**: template per role / outlet (mis. *Buka toko*, *Tutup toko*, *Cek suhu chiller*), langkah bisa wajib foto.
  Checklist hari ini dibuat otomatis per outlet saat dibuka; tercatat siapa & jam berapa. Rekap **kepatuhan SOP** 7 hari (%) untuk manajer.
- Beranda Saya: kartu *Tugas saya* + pengingat SOP hari ini. Foto di bucket privat `task-files`.

## Aset tetap (tahap 1)
Menu **Aset**: peralatan dapur, elektronik, mesin besar, furnitur, kendaraan & renovasi.
- **Kategori** default mengikuti kelompok pajak (4 / 8 / 20 tahun), akun COA per kategori (Peralatan, Elektronik, Mesin, Furnitur,
  Kendaraan, Bangunan; Akumulasi Penyusutan; Beban Penyusutan). **Batas nilai aset** default Rp 1.000.000: di bawahnya dicatat sebagai biaya.
- **Daftar aset**: kode otomatis `AST-DPR-0001`, outlet & lokasi, penanggung jawab, merek, nomor seri, supplier, garansi, foto (bucket privat `asset-files`).
- **Cara perolehan** (dijurnal otomatis): dibayar tunai/bank · belum dibayar (hutang pembelian aset, bayar dari detail aset) ·
  **aset lama** sebelum pakai SEMAR (akumulasi penyusutan lama dihitung otomatis, lawan Ekuitas Saldo Awal) · sudah dicatat di jurnal (tanpa jurnal).
- **Penyusutan bulanan**: garis lurus / saldo menurun, jurnal per outlet (Beban Penyusutan / Akumulasi), bulan yang tertinggal otomatis disusulkan,
  periode terakhir bisa dibatalkan. Proyeksi nilai buku per tahun di detail aset.
- **Mutasi** antar outlet / lokasi & **pelepasan** (dijual, rusak, hilang, hibah) lewat matriks approval (jenis *Mutasi Aset* & *Pelepasan Aset*,
  default aktif; owner/penyetuju langsung jalan). Laba / rugi pelepasan dijurnal otomatis.
- **Label QR** untuk printer thermal: scan pakai kamera HP langsung membuka detail aset; bisa cetak banyak sekaligus.
- Izin: `asset.view`, `asset.manage`, `asset.audit` (ikut opname), `approval.asset_transfer`, `approval.asset_disposal`.

**Tahap 2: perawatan, kerusakan & opname**
- **Jadwal perawatan rutin** per aset (tiap N hari / minggu / bulan, mis. *Service AC tiap 3 bulan*): tugas otomatis muncul di menu **Tugas**
  H-x sebelum jatuh tempo (untuk orang / tim / penanggung jawab aset, dengan checklist & wajib foto). Saat tugas *Selesai*, riwayat perawatan
  tercatat dan jadwal maju ke periode berikutnya; tugas yang diarsipkan dicatat *dilewati*.
- **Riwayat perawatan + biaya**; biaya bisa langsung dijurnal (Beban Perbaikan & Perawatan / Kas-Bank). Biaya di atas batas approval *Biaya*
  diarahkan lewat Keuangan → Biaya.
- **Lapor kerusakan oleh semua karyawan**: scan label QR di aset (link `/aset/<kode>`) atau dari **Beranda Saya** → pilih tingkat
  (masih bisa dipakai / terganggu / mati total) + foto. Otomatis jadi tiket `KRS/…` + tugas perbaikan (prioritas sesuai tingkat).
  Pengelola aset mengisi status, vendor, tindakan & biaya; lama aset rusak tercatat.
- **Opname aset** per outlet: scan QR satu per satu → ditemukan / salah lokasi / rusak (rusak otomatis jadi laporan kerusakan);
  saat ditutup yang tidak ter-scan tercatat hilang. Petugas opname juga bisa menandai dari halaman scan QR.
- **Biaya perawatan terbesar 12 bulan** per aset, dengan tanda bila biaya > 50% nilai buku (pertimbangkan ganti baru).
**Tahap 3: Semar x aset**
- Briefing harian Semar ikut menyebut aset mati total / rusak, perawatan terlambat, garansi mau habis, penyusutan yang belum dijalankan.
- Tanya Semar *"Aset mana yang perlu perhatian? Servis atau ganti baru?"*: Semar menganalisa umur, % tersusut, biaya perawatan & kerusakan 12 bulan.
- Semar bisa **mengusulkan jadwal perawatan** untuk aset penting yang belum punya jadwal (kartu usulan → Setujui → jadwal dibuat).

## Modul per perusahaan & panduan memulai
Tidak semua usaha memakai semua modul, jadi owner memilih sendiri modul yang tampil.
- **Wizard owner baru** (muncul sekali setelah membuat usaha): pilih **tipe usaha** (warung / kafe-restoran / multi cabang + dapur pusat /
  katering-B2B) → modul yang cocok tercentang otomatis → kartu modul berisi *apa gunanya, siapa yang memakai, cocok bila…* → langkah pertama.
  Ada tombol *Lewati, aktifkan semua modul*.
- **Pengaturan → Modul**: nyalakan / matikan kapan saja. Modul pendukung ikut otomatis (mis. Pembelian butuh Stok, Self kiosk butuh Kasir).
  Modul yang dimatikan **disembunyikan** dari menu, halaman, hak akses role, Beranda Saya & saran Semar; **data tidak dihapus**.
  Modul inti selalu aktif: Dashboard, Menu, Laporan, Persetujuan, User, Pengaturan, Beranda Saya.
- **Panduan memulai** di Dashboard (owner): checklist sesuai modul aktif yang tercentang otomatis dari data (menu, bahan, resep, stok awal,
  supplier, akun tim, karyawan, shift, transaksi pertama, dll.), tiap langkah langsung membuka halaman terkait.
- Perusahaan yang sudah ada sebelum fitur ini: semua modul aktif & tidak diminta wizard. Kunci modul: `sys_module_keys()`.

## Email pendaftaran (Supabase Auth)
Template email konfirmasi bertema SEMAR ada di [`supabase/email_templates/confirm_signup.html`](supabase/email_templates/confirm_signup.html).

1. **Authentication → URL Configuration**: isi **Site URL** dengan `https://achphoria.github.io/semar-erp/`
   dan tambahkan alamat yang sama di **Redirect URLs** (supaya link di email tidak mengarah ke localhost).
2. **Authentication → Emails → Confirm signup**: isi Subject `Konfirmasi email Anda · SEMAR`, lalu tempel seluruh isi file template ke kolom body.
3. **Disarankan: Custom SMTP** (Authentication → Emails → SMTP Settings), misalnya Resend atau Brevo.
   Pengirim bawaan Supabase hanya untuk uji coba: kuotanya sangat kecil dan bisa hanya mengirim ke anggota tim project,
   sehingga pendaftar sungguhan mungkin tidak menerima email.

## Roadmap berikutnya
- **Deploy** ke internet (Vercel/Netlify) supaya QR bisa dipakai tamu & aplikasi bisa dibuka dari tablet kasir
- **Fase 5 – Central kitchen & HR**: produksi bahan setengah jadi, absensi, payroll
- Integrasi GoFood/GrabFood, refund order yang sudah dibayar, mode offline POS, penutupan buku akhir tahun
