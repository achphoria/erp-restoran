import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  ArrowRight, BadgeCheck, ChefHat, HandHeart, Languages, LogIn, Network, Package, QrCode, Receipt, ScanBarcode, ShieldCheck, Smartphone, Sprout, Store, Truck, Users, Wallet,
  type LucideIcon,
} from 'lucide-react';
import Gunungan from '../components/Gunungan';
import { APP_LONG_NAME, APP_NAME } from '../lib/brand';
import { formatRupiah } from '../lib/format';
import { rpc } from '../lib/supabase';
import '../styles/landing.css';

// Punakawan = modul SEMAR. Watak tiap tokoh dipakai sebagai cerita modulnya.
const PUNAKAWAN: { name: string; watak: string; modul: string; desc: string; tone: string }[] = [
  { name: 'Semar', watak: 'Pamong yang bijak', modul: 'Pusat kendali',
    desc: 'Dashboard, approval transaksi, user & role, akses per branch, multi outlet, brand, sampai grup usaha.', tone: 'fresh' },
  { name: 'Gareng', watak: 'Teliti, tangannya tak mengambil hak orang', modul: 'Kasir & penjualan',
    desc: 'POS, pesan lewat QR meja, layar dapur, shift kasir, member & promo, settlement uang harian.', tone: 'sunshine' },
  { name: 'Petruk', watak: 'Jangkauannya panjang', modul: 'Stok, gudang & pembelian',
    desc: 'Stok FIFO/FEFO per batch, barcode & koli, transfer antar cabang, PO, produksi & resep (BOM).', tone: 'vermillion' },
  { name: 'Bagong', watak: 'Lugas, bicara apa adanya', modul: 'Keuangan & laporan',
    desc: 'Jurnal otomatis dari setiap transaksi, laba rugi, neraca, piutang & hutang, laporan penjualan.', tone: 'ink' },
];

const FEATURES: [LucideIcon, string, string][] = [
  [Receipt, 'Kasir cepat & QR order', 'Dine-in, takeaway, split payment, struk, dan pesanan tamu langsung dari meja.'],
  [ScanBarcode, 'Stok FIFO/FEFO & barcode', 'Setiap batch terlacak dari terima barang sampai terjual, lengkap dengan kedaluwarsa.'],
  [Truck, 'Pembelian & SO antar cabang', 'PO ke supplier atau ke cabang lain, pengiriman per koli, invoice & pembayaran.'],
  [ChefHat, 'Produksi & resep', 'Simple manufacturing ala central kitchen: BOM, hasil aktual, dan HPP otomatis.'],
  [Wallet, 'Akuntansi otomatis', 'Jurnal terbentuk sendiri dari penjualan, pembelian, stok, dan settlement POS.'],
  [BadgeCheck, 'Approval transaksi', 'Atur siapa pembuat & penyetuju untuk PO, refund, opname, produksi, dan lainnya.'],
  [Network, 'Multi outlet, brand & PT', 'Satu juragan, banyak cabang, banyak brand, bahkan beberapa PT dalam satu grup.'],
  [ShieldCheck, 'Akses aman per branch', 'Staf hanya melihat branch atau brand miliknya, dikunci langsung di database.'],
];

// alasan SEMAR cocok untuk UMKM
const UMKM: [LucideIcon, string, string][] = [
  [Sprout, 'Mulai dari satu warung', 'Tidak perlu jadi restoran besar dulu. Mulai dari kasir & stok, fitur lain menyusul saat usaha tumbuh.'],
  [Languages, 'Bahasa Indonesia sepenuhnya', 'Istilah yang akrab untuk pedagang: struk, shift, opname, setoran, tanpa jargon yang membingungkan.'],
  [Smartphone, 'Cukup HP atau tablet', 'Jalan di browser. Kasir pakai tablet, juragan pantau omzet dari HP di mana saja.'],
  [HandHeart, 'Naik kelas tanpa ganti sistem', 'Dari gerobak, cabang, brand baru, sampai grup PT, datanya tetap di satu tempat.'],
];

const JOURNEY: [LucideIcon, string, string][] = [
  [Store, 'Warung pertama', 'Kasir, menu, dan stok rapi sejak hari pertama.'],
  [Package, 'Buka cabang', 'Gudang per toko, central kitchen, transfer stok antar cabang.'],
  [Users, 'Tambah brand', 'Satu PT dengan beberapa brand, akses staf per brand.'],
  [Network, 'Grup usaha', 'Beberapa PT dalam satu grup, pindah PT dengan sekali klik.'],
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
  return (
    <div className="landing">
      <header className="lp-nav">
        <Link to="/" className="lp-brand" aria-label={APP_NAME}>
          <img src={`${import.meta.env.BASE_URL}favicon.svg`} alt="" width={36} height={36} />
          <span>{APP_NAME}</span>
        </Link>
        <nav className="lp-links">
          <a href="#punakawan">Modul</a>
          <a href="#fitur">Fitur</a>
          <a href="#umkm">UMKM</a>
          <a href="#dalang">Sang Dalang</a>
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
            Seperti Semar yang ngemong para ksatria, {APP_NAME} mengurus kasir, stok, pembelian, produksi, sampai pembukuan,
            supaya juragan bisa fokus melayani tamu dan membesarkan usaha.
          </p>
          <div className="lp-cta">
            <Link to="/login" className="btn btn-primary btn-lg">Masuk ke {APP_NAME} <ArrowRight size={18} /></Link>
            <Link to="/login?daftar=1" className="btn btn-lg">Daftarkan usaha</Link>
          </div>
          <ul className="lp-ticks">
            <li>Kasir & QR order</li><li>Stok FIFO per batch</li><li>Jurnal otomatis</li><li>Multi outlet</li>
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
          <div className="lp-float lp-float-stock">
            <Package size={16} />
            <span><b>Susu UHT</b><small>Batch LOT-0912 kedaluwarsa 3 hari lagi</small></span>
          </div>
          <div className="lp-float lp-float-approve">
            <BadgeCheck size={16} />
            <span><b>PO/2026/0142</b><small>Menunggu persetujuan Anda</small></span>
          </div>
          <div className="lp-float lp-float-qr">
            <QrCode size={16} />
            <span><b>Meja 7</b><small>Pesanan QR baru masuk</small></span>
          </div>
        </div>
      </section>

      {/* BRAND YANG SUDAH BERSAMA SEMAR */}
      {brands.length > 0 && (
        <section className="lp-brands" aria-label="Brand yang sudah bersama SEMAR">
          <span className="lp-eyebrow">Kolaborasi brand</span>
          <h2>Brand yang sudah bersama {APP_NAME}</h2>
          <div className={`lp-brands-track ${marquee ? 'marquee' : ''}`}>
            <div className="lp-brands-row">
              {(marquee ? [...brands, ...brands] : brands).map((b, i) => (
                <figure key={`${b.name}-${i}`} className="lp-brand" aria-hidden={i >= brands.length ? true : undefined}>
                  <img src={b.logo_url} alt={b.name} loading="lazy" />
                  <figcaption>{b.name}</figcaption>
                </figure>
              ))}
            </div>
          </div>
        </section>
      )}

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
              <div className="lp-puna-badge">{p.name[0]}</div>
              <div className="lp-puna-name">{p.name}</div>
              <div className="lp-puna-watak">“{p.watak}”</div>
              <h3>{p.modul}</h3>
              <p>{p.desc}</p>
            </article>
          ))}
        </div>
      </section>

      {/* FITUR */}
      <section id="fitur" className="lp-section">
        <div className="lp-head">
          <span className="lp-eyebrow">Semua jadi satu</span>
          <h2>Dari dapur sampai laporan keuangan.</h2>
          <p>Tidak perlu lagi aplikasi kasir, spreadsheet stok, dan software akuntansi terpisah.</p>
        </div>
        <div className="lp-features">
          {FEATURES.map(([Icon, title, desc]) => (
            <div key={title} className="lp-feature">
              <span className="lp-feature-icon"><Icon size={20} /></span>
              <h3>{title}</h3>
              <p>{desc}</p>
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

      <section className="lp-final">
        <h2>Siap ditemani {APP_NAME}?</h2>
        <p>Daftar sebagai pemilik usaha, lalu buatkan akun untuk kasir, gudang, dan tim Anda.</p>
        <div className="lp-cta center">
          <Link to="/login?daftar=1" className="btn btn-accent btn-lg">Daftarkan usaha <ArrowRight size={18} /></Link>
          <Link to="/login" className="btn btn-lg lp-ghost">Saya sudah punya akun</Link>
        </div>
      </section>

      <footer className="lp-footer">
        <span><b>{APP_NAME}</b> · {APP_LONG_NAME}</span>
        <span>Dalang: <b>Achphoria</b> · Untuk UMKM kuliner Indonesia 🇮🇩</span>
      </footer>
    </div>
  );
}
