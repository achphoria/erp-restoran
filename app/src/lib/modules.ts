import {
  Armchair, Boxes, ChefHat, Factory, Gift, ListTodo, MessageSquareHeart, MonitorSmartphone, Receipt, ShoppingCart, Sparkles, Truck, Users, Wallet,
  type LucideIcon,
} from 'lucide-react';

// Modul yang bisa dipilih owner (Pengaturan -> Modul & wizard awal). Modul inti selalu aktif:
// Dashboard, Menu, Laporan, Persetujuan, User Management, Pengaturan, Beranda Saya.
// Mematikan modul hanya menyembunyikan menu & halaman; data tidak dihapus. Kunci sama dengan sys_module_keys() di database.
export type ModuleKey = 'pos' | 'kds' | 'kiosk' | 'crm' | 'feedback' | 'inventory' | 'production' | 'purchasing' | 'sales' | 'finance'
  | 'hr' | 'tasks' | 'assets' | 'ai';

export interface ModuleInfo {
  key: ModuleKey; name: string; icon: LucideIcon; group: string;
  desc: string; who: string; fits: string; requires?: ModuleKey[];
}

export const MODULES: ModuleInfo[] = [
  { key: 'pos', name: 'Kasir (POS)', icon: Receipt, group: 'Jualan', who: 'Kasir',
    desc: 'Layar kasir dine-in & takeaway, struk, pesan lewat QR meja, shift kasir, refund, dan setoran uang harian.', fits: 'Hampir semua usaha yang melayani tamu langsung.' },
  { key: 'kds', name: 'Layar dapur', icon: ChefHat, group: 'Jualan', who: 'Koki / barista', requires: ['pos'],
    desc: 'Pesanan dari kasir & QR meja langsung tampil di layar dapur per stasiun, tanpa kertas.', fits: 'Dapur dengan lebih dari 1 orang, atau pesanan sering ramai.' },
  { key: 'kiosk', name: 'Self kiosk', icon: MonitorSmartphone, group: 'Jualan', who: 'Tamu', requires: ['pos'],
    desc: 'Layar sentuh berdiri untuk tamu memesan sendiri dengan menu unggulan, lalu bayar di kasir.', fits: 'Antrean kasir panjang, atau konsep fast food / kopi.' },
  { key: 'crm', name: 'Member & promo', icon: Gift, group: 'Jualan', who: 'Kasir & owner', requires: ['pos'],
    desc: 'Data pelanggan, poin member & tingkatannya, voucher, promo terjadwal.', fits: 'Ingin pelanggan kembali lagi lewat poin & promo.' },
  { key: 'feedback', name: 'Ulasan pelanggan', icon: MessageSquareHeart, group: 'Jualan', who: 'Owner & manajer', requires: ['pos'],
    desc: 'QR di struk untuk form ulasan; rating, NPS, komentar, dan tindak lanjut keluhan.', fits: 'Ingin tahu pendapat tamu & memperbaiki pelayanan.' },
  { key: 'inventory', name: 'Stok & gudang', icon: Boxes, group: 'Dapur & stok', who: 'Gudang & dapur',
    desc: 'Bahan baku, resep (menu terhubung ke bahan), stok FIFO per batch & kedaluwarsa, opname, waste, transfer antar gudang. HPP otomatis.', fits: 'Ingin stok & HPP terkontrol, tidak sekadar mencatat penjualan.' },
  { key: 'purchasing', name: 'Pembelian', icon: Truck, group: 'Dapur & stok', who: 'Purchasing', requires: ['inventory'],
    desc: 'Supplier, pricelist, purchase order, penerimaan barang per lot, dan hutang supplier.', fits: 'Belanja rutin ke supplier dan ingin harga & hutangnya tercatat.' },
  { key: 'production', name: 'Produksi', icon: Factory, group: 'Dapur & stok', who: 'Central kitchen', requires: ['inventory'],
    desc: 'Simple manufacturing: olah bahan jadi barang setengah jadi (saus, adonan) dengan BOM & hasil aktual.', fits: 'Punya dapur pusat / bahan olahan sendiri.' },
  { key: 'sales', name: 'Penjualan B2B & antar cabang', icon: ShoppingCart, group: 'Dapur & stok', who: 'Admin penjualan', requires: ['inventory'],
    desc: 'Sales order ke pelanggan bisnis & cabang lain, pengiriman per koli, invoice & piutang.', fits: 'Katering, suplai ke cabang / mitra, atau jualan grosir.' },
  { key: 'finance', name: 'Keuangan', icon: Wallet, group: 'Keuangan', who: 'Owner & finance',
    desc: 'Jurnal otomatis, laba rugi, neraca, buku besar, catat biaya, bayar hutang supplier.', fits: 'Ingin pembukuan rapi tanpa input ulang ke software lain.' },
  { key: 'hr', name: 'SDM & absensi', icon: Users, group: 'Tim', who: 'Semua karyawan',
    desc: 'Data karyawan, absen selfie + GPS dari HP, jadwal shift, cuti & izin, penilaian kinerja, pengumuman.', fits: 'Punya beberapa karyawan dengan jadwal bergiliran.' },
  { key: 'tasks', name: 'Tugas & SOP', icon: ListTodo, group: 'Tim', who: 'Semua karyawan',
    desc: 'Papan tugas dengan foto bukti, checklist SOP harian (buka / tutup toko) per role dan rekap kepatuhannya.', fits: 'Ingin pekerjaan rutin tim terpantau.' },
  { key: 'assets', name: 'Aset', icon: Armchair, group: 'Tim', who: 'Owner & semua karyawan',
    desc: 'Daftar peralatan dengan label QR, penyusutan otomatis, jadwal servis, laporan kerusakan, opname aset.', fits: 'Peralatan dapur & elektronik bernilai besar yang perlu dirawat.' },
  { key: 'ai', name: 'Semar AI', icon: Sparkles, group: 'Tim', who: 'Owner',
    desc: 'Konsultan AI: briefing harian, analisa data, menyiapkan PO / tugas / jadwal servis, bantu pindah data dari Excel.', fits: 'Semua owner yang ingin ditemani konsultan.' },
];
export const MODULE_KEYS = MODULES.map((m) => m.key);
export const MODULE_BY_KEY = Object.fromEntries(MODULES.map((m) => [m.key, m])) as Record<ModuleKey, ModuleInfo>;

export type BusinessType = 'warung' | 'resto' | 'multi' | 'catering';
export const BUSINESS_TYPES: { key: BusinessType; emoji: string; name: string; desc: string; modules: ModuleKey[] }[] = [
  { key: 'warung', emoji: '☕', name: 'Warung / kedai kecil', desc: '1 outlet, tim kecil. Fokus kasir, menu, dan stok.', modules: ['pos', 'inventory', 'ai'] },
  { key: 'resto', emoji: '🍽️', name: 'Kafe / restoran', desc: 'Dapur & pelayan, pelanggan tetap, belanja rutin ke supplier.',
    modules: ['pos', 'kds', 'crm', 'feedback', 'inventory', 'purchasing', 'finance', 'tasks', 'ai'] },
  { key: 'multi', emoji: '🏭', name: 'Multi cabang + dapur pusat', desc: 'Beberapa outlet, central kitchen, tim besar.',
    modules: ['pos', 'kds', 'kiosk', 'crm', 'feedback', 'inventory', 'purchasing', 'production', 'sales', 'finance', 'hr', 'tasks', 'assets', 'ai'] },
  { key: 'catering', emoji: '🚚', name: 'Katering / B2B', desc: 'Pesanan dalam jumlah besar ke pelanggan bisnis.',
    modules: ['sales', 'inventory', 'production', 'purchasing', 'finance', 'tasks', 'ai'] },
];

// tambahkan modul pendukung (mis. Pembelian butuh Stok)
export function withRequired(keys: ModuleKey[]): ModuleKey[] {
  const out = new Set(keys);
  for (const k of keys) for (const r of MODULE_BY_KEY[k]?.requires ?? []) out.add(r);
  return MODULE_KEYS.filter((k) => out.has(k));
}
// modul yang ikut mati bila modul ini dimatikan
export const dependents = (key: ModuleKey) => MODULES.filter((m) => m.requires?.includes(key)).map((m) => m.key);

// izin role -> modul (untuk menyembunyikan izin modul nonaktif di editor role)
export function moduleOfPermission(perm: string): ModuleKey | null {
  if (perm.startsWith('pos.')) return 'pos';
  if (perm.startsWith('kds.')) return 'kds';
  if (perm.startsWith('kiosk.')) return 'kiosk';
  if (perm.startsWith('crm.')) return 'crm';
  if (perm.startsWith('feedback.')) return 'feedback';
  if (perm === 'inventory.manage' || perm.startsWith('approval.stock') || perm === 'approval.product') return 'inventory';
  if (perm === 'approval.production') return 'production';
  if (perm === 'purchasing.manage' || perm === 'approval.purchase_order' || perm === 'approval.pricelist' || perm === 'approval.supplier_payment') return 'purchasing';
  if (perm === 'sales.manage' || perm === 'approval.sales_order' || perm === 'approval.credit_note' || perm === 'approval.sales_payment') return 'sales';
  if (perm.startsWith('finance.') || perm === 'approval.expense' || perm === 'approval.manual_journal' || perm === 'approval.pos_settlement') return 'finance';
  if (perm.startsWith('hr.') || perm === 'approval.leave') return 'hr';
  if (perm === 'task.manage') return 'tasks';
  if (perm.startsWith('asset.') || perm.startsWith('approval.asset_')) return 'assets';
  return null;
}

// Panduan memulai: langkah per modul, dicentang otomatis dari sys_setup_progress()
export interface GuideStep { key: string; title: string; desc: string; to: string; module?: ModuleKey; optional?: boolean }
export const GUIDE_STEPS: GuideStep[] = [
  { key: 'company_logo', title: 'Lengkapi profil & logo usaha', desc: 'Logo tampil di struk, invoice, dan layar kiosk.', to: '/settings?tab=company' },
  { key: 'menu', title: 'Masukkan menu', desc: 'Kategori, harga, modifier. Bisa impor dari Excel.', to: '/menu' },
  { key: 'items', title: 'Masukkan bahan baku', desc: 'Satuan, kategori, harga beli. Bisa impor dari Excel.', to: '/products', module: 'inventory' },
  { key: 'recipe', title: 'Hubungkan menu ke resep', desc: 'Supaya stok berkurang otomatis & HPP terhitung.', to: '/products', module: 'inventory' },
  { key: 'opening_stock', title: 'Isi stok awal', desc: 'Stok fisik hari ini lewat penyesuaian / opname.', to: '/inventory?tab=documents', module: 'inventory' },
  { key: 'supplier', title: 'Tambah supplier', desc: 'Untuk purchase order & pricelist.', to: '/purchasing?tab=suppliers', module: 'purchasing' },
  { key: 'tables', title: 'Atur meja & QR', desc: 'Cetak QR meja supaya tamu bisa pesan sendiri.', to: '/menu', module: 'pos', optional: true },
  { key: 'staff', title: 'Buat akun tim', desc: 'Akun kasir, dapur, gudang dengan username & role.', to: '/users?tab=users' },
  { key: 'employees', title: 'Masukkan data karyawan', desc: 'Biodata, jabatan, outlet, lalu tautkan ke akun login.', to: '/hr?tab=employees', module: 'hr' },
  { key: 'shifts', title: 'Atur jadwal shift', desc: 'Template shift & jadwal mingguan untuk absensi.', to: '/hr?tab=roster', module: 'hr' },
  { key: 'sop', title: 'Buat SOP harian', desc: 'Checklist buka / tutup toko per role.', to: '/tugas?tab=sop', module: 'tasks', optional: true },
  { key: 'promo', title: 'Buat promo pertama', desc: 'Diskon, voucher, atau promo jam tertentu.', to: '/customers', module: 'crm', optional: true },
  { key: 'feedback', title: 'Atur form ulasan', desc: 'Pertanyaan ulasan yang muncul dari QR di struk.', to: '/ulasan', module: 'feedback', optional: true },
  { key: 'kiosk', title: 'Pasang self kiosk', desc: 'Buat perangkat kiosk & buka link-nya di layar sentuh.', to: '/kiosks', module: 'kiosk', optional: true },
  { key: 'asset', title: 'Catat aset utama', desc: 'Kompor, AC, kulkas, mesin kasir, lalu cetak label QR.', to: '/assets', module: 'assets', optional: true },
  { key: 'first_order', title: 'Coba transaksi pertama', desc: 'Buka shift kasir, buat pesanan, terima pembayaran.', to: '/pos', module: 'pos' },
  { key: 'semar', title: 'Kenalan dengan Semar', desc: 'Tanya "apa langkah pertama saya?" di Pendopo.', to: '/', module: 'ai', optional: true },
];

// modul pemilik sebuah halaman (menu sidebar & penjaga halaman); null = halaman inti
export function moduleOfPath(path: string): ModuleKey | null {
  const [p, q = ''] = path.split('?');
  const tab = new URLSearchParams(q).get('tab');
  if (['/pos', '/orders', '/shifts', '/settlement'].some((x) => p.startsWith(x))) return 'pos';
  if (p.startsWith('/kitchen')) return 'kds';
  if (p.startsWith('/kiosks')) return 'kiosk';
  if (p.startsWith('/customers')) return 'crm';
  if (p.startsWith('/ulasan')) return 'feedback';
  if (p.startsWith('/sales')) return 'sales';
  if (p.startsWith('/purchasing')) return 'purchasing';
  if (p.startsWith('/inventory')) return tab === 'production' ? 'production' : 'inventory';
  if (p.startsWith('/products')) return 'inventory';
  if (p.startsWith('/finance')) return 'finance';
  if (p.startsWith('/hr')) return 'hr';
  if (p.startsWith('/tugas')) return 'tasks';
  if (p.startsWith('/assets') || p.startsWith('/aset/')) return 'assets';
  return null;
}
