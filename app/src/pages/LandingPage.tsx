import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  ArrowRight, Armchair, BadgeCheck, Bell, Boxes, CalendarCheck, ChefHat, ClipboardList, Fingerprint, HandHeart, Languages, LayoutDashboard, ListTodo,
  LogIn, MessageCircle, MessageSquareHeart, MonitorSmartphone, Network, Package, QrCode, Receipt, ScanBarcode, ShieldCheck, Smartphone,
  Sparkles, Sprout, Store, Truck, UserRound, Users, Wallet, Warehouse, Wrench, type LucideIcon,
} from 'lucide-react';
import Gunungan from '../components/Gunungan';
import MiniAvatar from '../components/pendopo/MiniAvatar';
import SemarDemo from '../components/landing/SemarDemo';
import { APP_LONG_NAME, APP_NAME, WHATSAPP_NUMBER, whatsappLink } from '../lib/brand';
import { formatRupiah } from '../lib/format';
import { rpc } from '../lib/supabase';
import '../styles/landing.css';

// Punakawan = modul SEMAR. Watak tiap tokoh dipakai sebagai cerita modulnya.
const PUNAKAWAN: { id: 'semar' | 'gareng' | 'petruk' | 'bagong'; name: string; watak: string; modul: string; desc: string; tone: string }[] = [
  { id: 'semar', name: 'Semar', watak: 'Pamong yang bijak', modul: 'Pusat kendali & tim',
    desc: 'Konsultan AI, approval transaksi, SDM & absensi, tugas & SOP, multi outlet, brand, sampai grup usaha.', tone: 'fresh' },
  { id: 'gareng', name: 'Gareng', watak: 'Teliti, tangannya tak mengambil hak orang', modul: 'Kasir & pelanggan',
    desc: 'POS, QR meja, self kiosk, layar dapur, struk 80mm + QR ulasan, member & promo, setoran harian.', tone: 'sunshine' },
  { id: 'petruk', name: 'Petruk', watak: 'Jangkauannya panjang', modul: 'Stok, gudang & aset',
    desc: 'Stok FIFO/FEFO per batch, PO & antar cabang, produksi & resep, aset dengan label QR & perawatan.', tone: 'vermillion' },
  { id: 'bagong', name: 'Bagong', watak: 'Lugas, bicara apa adanya', modul: 'Keuangan & laporan',
    desc: 'Jurnal otomatis dari setiap transaksi, laba rugi, neraca, penyusutan aset, laporan konsolidasi grup.', tone: 'ink' },
];

// fitur dikelompokkan per kebutuhan usaha
const GROUPS: { key: string; label: string; icon: LucideIcon; lead: string; items: [LucideIcon, string, string][] }[] = [
  { key: 'jualan', label: 'Jualan', icon: Receipt, lead: 'Layani tamu lebih cepat, dari kasir, meja, sampai layar pesan sendiri.', items: [
    [Receipt, 'Kasir (POS)', 'Dine-in & takeaway, split bill & split payment, diskon, refund dengan approval, shift kasir.'],
    [QrCode, 'Pesan dari meja', 'Tamu scan QR di meja, pesanan langsung masuk kasir & dapur.'],
    [MonitorSmartphone, 'Self kiosk', 'Layar sentuh berdiri untuk pesan sendiri, menu unggulan & nomor antrean, bayar di kasir.'],
    [ChefHat, 'Layar dapur', 'Pesanan tampil per stasiun dapur, tanpa kertas yang tercecer.'],
    [MessageSquareHeart, 'Struk + QR ulasan', 'Struk thermal 80mm berlogo dengan QR form ulasan, analisa rating & NPS.'],
    [Wallet, 'Member, promo & setoran', 'Poin member, voucher, promo terjadwal, dan settlement uang per metode bayar.'],
  ] },
  { key: 'dapur', label: 'Dapur & stok', icon: Package, lead: 'Stok dan HPP selalu benar, karena setiap menu terhubung ke resep.', items: [
    [ScanBarcode, 'Stok FIFO / FEFO', 'Setiap batch terlacak dari terima barang sampai terjual, lengkap tanggal kedaluwarsa & barcode.'],
    [Boxes, 'Resep & produksi', 'BOM, produksi central kitchen, hasil aktual, HPP otomatis.'],
    [Truck, 'Pembelian', 'PO ke supplier, pricelist, penerimaan barang per lot, tagihan & pembayaran hutang.'],
    [Store, 'Antar cabang', 'Sales order & transfer antar cabang dengan pengiriman per koli.'],
    [ClipboardList, 'Opname & waste', 'Stock opname bertahap, penyesuaian, waste & pemakaian langsung ke jurnal.'],
  ] },
  { key: 'tim', label: 'Tim & SDM', icon: Users, lead: 'Semua karyawan pegang HP; juragan cukup memantau.', items: [
    [Fingerprint, 'Absen foto + GPS', 'Absen dari HP dengan selfie & lokasi; di luar radius tercatat untuk direview.'],
    [CalendarCheck, 'Jadwal shift & cuti', 'Template shift, papan jadwal mingguan, saldo cuti, izin & persetujuan atasan.'],
    [ListTodo, 'Tugas & SOP harian', 'Kanban tugas dengan foto bukti, checklist SOP buka/tutup toko per role.'],
    [BadgeCheck, 'Penilaian kinerja', 'Template per jabatan, penilaian diri & atasan, grade A-E.'],
    [UserRound, 'Beranda Saya', 'Satu halaman di HP: absen, jadwal, cuti, tugas, pengumuman.'],
  ] },
  { key: 'aset', label: 'Aset', icon: Armchair, lead: 'Kompor, AC, chiller, mesin kasir: tercatat, terawat, tersusut otomatis.', items: [
    [QrCode, 'Label QR aset', 'Setiap aset punya kode & label QR; scan dari HP untuk lihat info atau lapor rusak.'],
    [Wallet, 'Penyusutan otomatis', 'Garis lurus / saldo menurun sesuai kelompok pajak, jurnal bulanan per outlet.'],
    [Wrench, 'Perawatan & kerusakan', 'Jadwal servis rutin jadi tugas otomatis; kasir bisa lapor kerusakan dengan foto.'],
    [ScanBarcode, 'Opname aset', 'Cek fisik per outlet dengan scan QR: ditemukan, salah lokasi, rusak, hilang.'],
    [Truck, 'Mutasi & pelepasan', 'Pindah aset antar outlet atau jual / buang lewat approval; laba-rugi dijurnal.'],
  ] },
  { key: 'keuangan', label: 'Keuangan', icon: Wallet, lead: 'Tutup buku tanpa input ulang: jurnal terbentuk dari setiap transaksi.', items: [
    [Wallet, 'Jurnal otomatis', 'Penjualan, HPP, pembelian, stok, setoran, penyusutan: semua langsung jadi jurnal.'],
    [LayoutDashboard, 'Laba rugi & neraca', 'Laporan keuangan per outlet & periode, buku besar, piutang & hutang.'],
    [BadgeCheck, 'Matriks approval', 'Tentukan siapa pembuat & penyetuju PO, biaya, refund, opname, mutasi aset, dll.'],
    [ShieldCheck, 'Log aktivitas', 'Siapa mengubah apa & kapan, tercatat rapi.'],
  ] },
  { key: 'grup', label: 'Multi cabang & grup', icon: Network, lead: 'Dari satu warung sampai beberapa PT, datanya tetap satu tempat.', items: [
    [Store, 'Multi outlet & brand', 'Banyak cabang, banyak brand, gudang per toko & central kitchen.'],
    [ShieldCheck, 'Akses per cabang', 'Staf hanya melihat cabang / brand miliknya, dikunci langsung di database.'],
    [Network, 'Dashboard grup', 'Ringkasan semua PT, laba rugi & neraca konsolidasi dengan eliminasi antar-PT.'],
    [Truck, 'Transaksi antar-PT', 'PO ke PT saudara otomatis jadi sales order di PT penjual, sampai tagihannya.'],
  ] },
];

const ROLES: [LucideIcon, string, string][] = [
  [LayoutDashboard, 'Juragan / owner', 'Pantau omzet, stok & tim dari HP. Tanya Semar, setujui PO & pengeluaran dari mana saja.'],
  [Receipt, 'Kasir', 'Layar kasir yang cepat, struk otomatis, setoran akhir shift tanpa hitung manual.'],
  [ChefHat, 'Dapur', 'Pesanan masuk ke layar dapur per stasiun, tandai siap saji sekali sentuh.'],
  [Warehouse, 'Gudang & purchasing', 'Terima barang per batch, transfer antar cabang, opname, PO ke supplier.'],
  [Smartphone, 'Semua karyawan', 'Absen, lihat jadwal, ajukan cuti, kerjakan tugas & SOP, lapor aset rusak dari HP.'],
  [Bell, 'Manajer cabang', 'Review absensi, setujui cuti & tugas, cek kepatuhan SOP & ulasan pelanggan cabangnya.'],
];

const UMKM: [LucideIcon, string, string][] = [
  [Sprout, 'Mulai dari satu warung', 'Tidak perlu jadi restoran besar dulu. Mulai dari kasir & stok, fitur lain menyusul saat usaha tumbuh.'],
  [Languages, 'Bahasa Indonesia sepenuhnya', 'Istilah yang akrab untuk pedagang: struk, shift, opname, setoran, tanpa jargon yang membingungkan.'],
  [Smartphone, 'Cukup HP atau tablet', 'Jalan di browser. Kasir pakai tablet, juragan pantau omzet dari HP di mana saja.'],
  [HandHeart, 'Naik kelas tanpa ganti sistem', 'Dari gerobak, cabang, brand baru, sampai grup PT, datanya tetap di satu tempat.'],
];

const JOURNEY: [LucideIcon, string, string][] = [
  [Store, 'Warung pertama', 'Kasir, menu, dan stok rapi sejak hari pertama.'],
  [Package, 'Buka cabang', 'Gudang per toko, central kitchen, transfer stok antar cabang.'],
  [Users, 'Tambah brand & tim', 'Satu PT dengan beberapa brand, absensi & tugas tim di HP.'],
  [Network, 'Grup usaha', 'Beberapa PT dalam satu grup, laporan konsolidasi & transaksi antar-PT.'],
];

const MODULES = ['Kasir', 'QR meja', 'Self kiosk', 'Layar dapur', 'Struk & ulasan', 'Member & promo', 'Stok FIFO/FEFO', 'Pembelian', 'Produksi',
  'Antar cabang', 'Absensi GPS', 'Cuti & shift', 'Tugas & SOP', 'Penilaian kinerja', 'Aset & QR', 'Akuntansi', 'Approval', 'Grup usaha', 'Semar AI'];

const FAQ: [string, string][] = [
  ['Apakah data usaha saya aman?', 'Data setiap perusahaan dipisahkan langsung di database (row level security): pengguna hanya bisa membaca data perusahaannya, dan staf hanya cabang yang diberikan kepadanya. Owner bisa mengunduh backup kapan saja dari menu Data & Backup.'],
  ['Perangkat apa yang dibutuhkan?', 'Cukup browser di HP, tablet, atau komputer. Opsional: printer thermal 80mm untuk struk, scanner barcode (USB/Bluetooth) atau kamera HP, dan layar sentuh untuk self kiosk.'],
  ['Apakah bisa dipakai tanpa internet?', 'Belum. SEMAR berjalan online supaya stok, laporan, dan semua cabang selalu sinkron, jadi pastikan koneksi internet di outlet stabil.'],
  ['Data lama saya ada di Excel, bisa dipindah?', 'Bisa. Produk & menu punya fitur impor Excel, dan Semar AI bisa membantu memindahkan data supplier, pelanggan, resep, dan pricelist dari file Excel / CSV / PDF: Anda cukup memeriksa dan menyetujui usulannya.'],
  ['Bagaimana cara kerja Semar AI?', 'Semar membaca data perusahaan Anda sendiri untuk memberi briefing & saran. Setiap perubahan (PO, tugas, jadwal perawatan, data master) hanya berupa usulan dan baru dijalankan setelah Anda menekan Setujui. Semar memakai model Claude dengan kunci API milik Anda.'],
  ['Saya baru punya satu warung, apa terlalu berat?', 'Tidak. Mulai saja dari kasir, menu, dan stok. Fitur seperti SDM, aset, atau grup usaha bisa dipakai nanti saat usaha bertambah besar, tanpa pindah sistem.'],
  ['Bagaimana cara mulai?', 'Klik Daftarkan usaha, isi nama usaha & outlet pertama, lalu ikuti panduan awal. Anda bisa memakai data contoh untuk mencoba, kemudian membuatkan akun untuk kasir dan tim.'],
];

// Brand pengguna SEMAR yang mengizinkan tampil (dari database, tanpa login)
function useBrands() {
  const [brands, setBrands] = useState<{ name: string; logo_url: string }[]>([]);
  useEffect(() => { rpc<{ name: string; logo_url: string }[]>('sys_public_brands').then(setBrands).catch(() => setBrands([])); }, []);
  return brands;
}

export default function LandingPage() {
  const brands = useBrands();
  const marquee = brands.length >= 5;
  const [group, setGroup] = useState(GROUPS[0].key);
  const g = GROUPS.find((x) => x.key === group) ?? GROUPS[0];
  const wa = WHATSAPP_NUMBER ? whatsappLink(`Halo, saya tertarik memakai ${APP_NAME} untuk usaha kuliner saya.`) : null;

  return (
    <div className="landing">
      <header className="lp-nav">
        <Link to="/" className="lp-brand" aria-label={APP_NAME}>
          <img src={`${import.meta.env.BASE_URL}favicon.svg`} alt="" width={36} height={36} />
          <span>{APP_NAME}</span>
        </Link>
        <nav className="lp-links">
          <a href="#semar-ai">Semar AI</a>
          <a href="#fitur">Fitur</a>
          <a href="#tim">Untuk tim</a>
          <a href="#faq">FAQ</a>
        </nav>
        <Link to="/login" className="btn btn-primary lp-nav-cta"><LogIn size={16} /> Masuk</Link>
      </header>

      {/* HERO: kelir (layar wayang) dengan cahaya blencong */}
      <section className="lp-hero">
        <div className="lp-hero-copy">
          <span className="lp-pill">🇮🇩 Mendukung UMKM kuliner Indonesia</span>
          <span className="lp-eyebrow">{APP_LONG_NAME}</span>
          <h1>Abdi setia untuk <em>usaha kuliner</em> Anda.</h1>
          <p>
            Kasir, dapur, stok, tim, aset, sampai pembukuan dalam satu sistem, ditemani <b>Semar</b>, konsultan AI yang memberi
            briefing tiap pagi dan menyiapkan PO, tugas, & jadwal servis untuk Anda setujui.
          </p>
          <div className="lp-cta">
            <Link to="/login?daftar=1" className="btn btn-primary btn-lg">Daftarkan usaha <ArrowRight size={18} /></Link>
            <Link to="/login" className="btn btn-lg">Masuk ke {APP_NAME}</Link>
          </div>
          <ul className="lp-ticks">
            <li>Kasir, QR meja & kiosk</li><li>Stok FIFO per batch</li><li>Absen & tugas dari HP</li><li>Jurnal otomatis</li>
          </ul>
        </div>

        <div className="lp-kelir" aria-hidden="true">
          <div className="lp-blencong" />
          <Gunungan className="lp-gunungan" />
          <div className="lp-float lp-float-sales">
            <small>Penjualan hari ini</small>
            <b>{formatRupiah(12450000)}</b>
            <span className="lp-up">▲ 18% dari kemarin</span>
            <div className="lp-bars">{[40, 62, 48, 75, 58, 88, 70].map((h, i) => <i key={i} style={{ height: `${h}%` }} />)}</div>
          </div>
          <div className="lp-float lp-float-semar">
            <MiniAvatar id="semar" size={34} />
            <span><b>Semar</b><small>Sugeng enjang, Juragan. Susu UHT cukup 1 hari lagi, PO sudah saya siapkan.</small></span>
          </div>
          <div className="lp-float lp-float-approve">
            <BadgeCheck size={16} />
            <span><b>PO/2026/0142</b><small>Menunggu persetujuan Anda</small></span>
          </div>
          <div className="lp-float lp-float-qr">
            <MonitorSmartphone size={16} />
            <span><b>Kiosk · antrean K012</b><small>Pesanan baru, bayar di kasir</small></span>
          </div>
        </div>
      </section>

      {/* MODUL dalam satu sistem */}
      <div className="lp-modules" aria-label="Modul SEMAR">
        <div className="lp-modules-row">
          {[...MODULES, ...MODULES].map((m, i) => <span key={i} aria-hidden={i >= MODULES.length ? true : undefined}>{m}</span>)}
        </div>
      </div>

      {/* BRAND YANG SUDAH BERSAMA SEMAR */}
      {brands.length > 0 && (
        <section className="lp-brands" aria-label="Brand yang sudah bersama SEMAR">
          <span className="lp-eyebrow">Kolaborasi brand</span>
          <h2>Brand yang sudah bersama {APP_NAME}</h2>
          <div className={`lp-brands-track ${marquee ? 'marquee' : ''}`}>
            <div className="lp-brands-row">
              {(marquee ? [...brands, ...brands] : brands).map((b, i) => (
                <figure key={`${b.name}-${i}`} className="lp-logo" aria-hidden={i >= brands.length ? true : undefined}>
                  <img src={b.logo_url} alt={b.name} loading="lazy" />
                  <figcaption>{b.name}</figcaption>
                </figure>
              ))}
            </div>
          </div>
        </section>
      )}

      {/* SEMAR AI */}
      <section id="semar-ai" className="lp-section">
        <div className="lp-ai">
          <div className="lp-ai-copy">
            <span className="lp-eyebrow light"><Sparkles size={13} /> Semar AI · kepala konsultan</span>
            <h2>Konsultan yang paham usaha Anda, siap 24 jam.</h2>
            <p>Semar membaca data usaha Anda sendiri, lalu bicara seperti konsultan yang ngemong: apa yang perlu diperhatikan hari ini, dan apa yang sebaiknya dilakukan.</p>
            <ul className="lp-ai-list">
              <li><b>Briefing harian</b> penjualan, stok, absensi, tugas, ulasan, aset & keuangan dalam satu jawaban.</li>
              <li><b>Analisa</b> menu terlaris, kebutuhan beli 7 hari, ulasan pelanggan, aset yang lebih baik diganti.</li>
              <li><b>Menyiapkan pekerjaan</b>: PO ke supplier, tugas untuk tim, jadwal servis, migrasi data dari Excel.</li>
              <li><b>Anda tetap pegang kendali</b>: semuanya berupa usulan, baru dijalankan setelah Anda menekan Setujui.</li>
            </ul>
          </div>
          <SemarDemo />
        </div>
      </section>

      {/* PUNAKAWAN = MODUL */}
      <section id="punakawan" className="lp-section">
        <div className="lp-head">
          <span className="lp-eyebrow">Punakawan {APP_NAME}</span>
          <h2>Empat abdi, satu sistem.</h2>
          <p>Setiap modul punya watak punakawan: bijak, teliti, jangkauannya panjang, dan lugas apa adanya.</p>
        </div>
        <div className="lp-puna">
          {PUNAKAWAN.map((p) => (
            <article key={p.name} className={`lp-puna-card ${p.tone}`}>
              <div className="lp-puna-badge"><MiniAvatar id={p.id} size={52} /></div>
              <div className="lp-puna-name">{p.name}</div>
              <div className="lp-puna-watak">“{p.watak}”</div>
              <h3>{p.modul}</h3>
              <p>{p.desc}</p>
            </article>
          ))}
        </div>
      </section>

      {/* FITUR per kebutuhan */}
      <section id="fitur" className="lp-section">
        <div className="lp-head">
          <span className="lp-eyebrow">Semua jadi satu</span>
          <h2>Dari dapur sampai laporan keuangan.</h2>
          <p>Tidak perlu lagi aplikasi kasir, spreadsheet stok, absensi, dan software akuntansi yang terpisah-pisah.</p>
        </div>
        <div className="lp-groups" role="tablist" aria-label="Kelompok fitur">
          {GROUPS.map((x) => (
            <button key={x.key} type="button" role="tab" aria-selected={x.key === group} className={x.key === group ? 'active' : ''} onClick={() => setGroup(x.key)}>
              <x.icon size={16} /> {x.label}
            </button>
          ))}
        </div>
        <div className="lp-group" role="tabpanel">
          <p className="lp-group-lead">{g.lead}</p>
          <div className="lp-features">
            {g.items.map(([Icon, title, desc]) => (
              <div key={title} className="lp-feature">
                <span className="lp-feature-icon"><Icon size={20} /></span>
                <h3>{title}</h3>
                <p>{desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* UNTUK TIM */}
      <section id="tim" className="lp-section">
        <div className="lp-head">
          <span className="lp-eyebrow">Untuk seluruh tim</span>
          <h2>Setiap orang punya layarnya sendiri.</h2>
          <p>Hak akses diatur per role & cabang, jadi setiap orang hanya melihat apa yang ia perlukan.</p>
        </div>
        <div className="lp-roles">
          {ROLES.map(([Icon, title, desc]) => (
            <div key={title} className="lp-role">
              <span className="lp-feature-icon"><Icon size={20} /></span>
              <div><h3>{title}</h3><p>{desc}</p></div>
            </div>
          ))}
        </div>
      </section>

      {/* UMKM */}
      <section id="umkm" className="lp-section">
        <div className="lp-umkm">
          <div className="lp-umkm-copy">
            <span className="lp-eyebrow">Untuk UMKM</span>
            <h2>Sistem sekelas restoran besar, untuk warung & kedai Indonesia.</h2>
            <p>
              {APP_NAME} lahir untuk UMKM kuliner: pemilik warung, kedai kopi, katering, sampai usaha yang baru buka cabang kedua.
              Pembukuan rapi, stok terkendali, dan laporan jelas, supaya usaha kecil bisa naik kelas.
            </p>
            <span className="lp-umkm-badge"><HandHeart size={16} /> Karya anak bangsa, untuk usaha anak bangsa</span>
          </div>
          <div className="lp-umkm-grid">
            {UMKM.map(([Icon, title, desc]) => (
              <div key={title} className="lp-umkm-item">
                <span className="lp-feature-icon"><Icon size={20} /></span>
                <div><h3>{title}</h3><p>{desc}</p></div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* PERJALANAN USAHA */}
      <section className="lp-section">
        <div className="lp-head">
          <span className="lp-eyebrow">Tumbuh bersama</span>
          <h2>Dari gerobak sampai grup usaha.</h2>
        </div>
        <ol className="lp-journey">
          {JOURNEY.map(([Icon, title, desc], i) => (
            <li key={title}>
              <span className="lp-journey-step"><Icon size={20} /><b>{i + 1}</b></span>
              <h3>{title}</h3>
              <p>{desc}</p>
            </li>
          ))}
        </ol>
      </section>

      {/* FILOSOFI */}
      <section id="filosofi" className="lp-section">
        <div className="lp-philo">
          <Gunungan className="lp-philo-art" tone="shadow" />
          <div>
            <span className="lp-eyebrow light">Mengapa {APP_NAME}?</span>
            <blockquote>“Urip iku urup.”</blockquote>
            <p className="lp-philo-trans">Hidup itu menyala: memberi terang bagi sekitarnya.</p>
            <p>
              Dalam pewayangan, Semar tampil sederhana sebagai abdi, padahal ia dewa yang paling bijak. Ia tidak memerintah,
              tetapi <i>ngemong</i>: menjaga, menasihati, dan menerangi jalan para ksatria. Begitulah {APP_NAME} dibuat:
              bekerja diam-diam di belakang layar, supaya usaha Anda terang dan tertata.
            </p>
          </div>
        </div>
      </section>

      {/* SANG DALANG: pembuat sistem */}
      <section id="dalang" className="lp-section">
        <div className="lp-dalang">
          <figure className="lp-dalang-photo">
            <img src={`${import.meta.env.BASE_URL}dalang-achphoria.jpg`} alt="Achphoria, dalang SEMAR" width={928} height={1152} loading="lazy" />
          </figure>
          <div className="lp-dalang-copy">
            <span className="lp-eyebrow">Sang Dalang</span>
            <h2>Di balik layar, selalu ada dalang.</h2>
            <p>
              Dalam pertunjukan wayang, dalang yang menghidupkan setiap tokoh: Semar, Gareng, Petruk, dan Bagong bergerak di tangannya
              semalam suntuk. {APP_NAME} pun punya dalangnya sendiri.
            </p>
            <div className="lp-dalang-card">
              <div className="lp-dalang-name">Achphoria</div>
              <div className="lp-dalang-role">Dalang {APP_NAME} · Developer</div>
              <p>
                Merancang dan membangun {APP_NAME}, dari layar kasir sampai jurnal akuntansi, dengan satu lakon:
                membantu UMKM kuliner Indonesia naik kelas.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* FAQ */}
      <section id="faq" className="lp-section">
        <div className="lp-head">
          <span className="lp-eyebrow">Pertanyaan umum</span>
          <h2>Yang sering ditanyakan juragan.</h2>
        </div>
        <div className="lp-faq">
          {FAQ.map(([q, a], i) => (
            <details key={q} open={i === 0}>
              <summary>{q}</summary>
              <p>{a}</p>
            </details>
          ))}
          {wa && <p className="lp-faq-more">Pertanyaan lain? <a href={wa} target="_blank" rel="noreferrer">Tanya langsung lewat WhatsApp</a>.</p>}
        </div>
      </section>

      <section className="lp-final">
        <h2>Siap ditemani {APP_NAME}?</h2>
        <p>Daftar sebagai pemilik usaha, lalu buatkan akun untuk kasir, dapur, gudang, dan tim Anda.</p>
        <div className="lp-cta center">
          <Link to="/login?daftar=1" className="btn btn-accent btn-lg">Daftarkan usaha <ArrowRight size={18} /></Link>
          {wa
            ? <a href={wa} target="_blank" rel="noreferrer" className="btn btn-lg lp-wa-btn"><MessageCircle size={18} /> Tanya via WhatsApp</a>
            : <Link to="/login" className="btn btn-lg lp-ghost">Saya sudah punya akun</Link>}
        </div>
      </section>

      <footer className="lp-footer">
        <span><b>{APP_NAME}</b> · {APP_LONG_NAME}</span>
        <span>Dalang: <b>Achphoria</b> · Untuk UMKM kuliner Indonesia 🇮🇩</span>
      </footer>

      {wa && (
        <a href={wa} target="_blank" rel="noreferrer" className="lp-wa-float" aria-label="Chat WhatsApp">
          <MessageCircle size={26} />
        </a>
      )}
    </div>
  );
}
