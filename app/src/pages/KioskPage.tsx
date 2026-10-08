import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';
import { ArrowLeft, Check, ChevronRight, Delete, Minus, Plus, RotateCcw, ShoppingBag, Sparkles, Trash2, Utensils, X } from 'lucide-react';
import { rpc } from '../lib/supabase';
import { errorMessage, formatRupiah } from '../lib/format';
import { buildReceiptHtml, printHtml } from '../lib/receipt';
import '../styles/kiosk.css';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Screen = 'attract' | 'menu' | 'upsell' | 'review' | 'done';
type Channel = 'dine_in' | 'takeaway';
interface Line { key: string; item: any; qty: number; modIds: string[]; mods: any[]; note: string }

const priceOf = (it: any, ch: Channel) => Number(ch === 'takeaway' ? it.price_takeaway ?? it.price_dine_in : it.price_dine_in);
const modTotal = (mods: any[]) => mods.reduce((s, m) => s + Number(m.extra_price || 0), 0);
const lineKey = (id: string, mods: string[], note: string) => `${id}|${[...mods].sort().join(',')}|${note}`;

// Self-order kiosk: layar sentuh portrait. Alur singkat: sambutan (pilih makan di sini / bawa pulang)
// -> menu (kategori di kiri, rekomendasi di atas) -> lengkapi pesanan (1 layar upsell) -> cek & pesan -> nomor antrean + struk
export default function KioskPage() {
  const { token = '' } = useParams();
  const [data, setData] = useState<any | null>(null);
  const [error, setError] = useState('');
  const [screen, setScreen] = useState<Screen>('attract');
  const [channel, setChannel] = useState<Channel>('dine_in');
  const [cart, setCart] = useState<Line[]>([]);
  const [sheet, setSheet] = useState<any | null>(null);
  const [cat, setCat] = useState<string>('');
  const [name, setName] = useState('');
  const [kbd, setKbd] = useState(false);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<any | null>(null);
  const [idle, setIdle] = useState<number | null>(null);
  const [toast, setToast] = useState('');
  const lastTouch = useRef(0);
  const sections = useRef<Record<string, HTMLElement | null>>({});
  const scroller = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    try { setData(await rpc<any>('public_kiosk_menu', { p_token: token })); setError(''); } catch (e) { setError(errorMessage(e)); }
  }, [token]);
  useEffect(() => { document.title = 'Kiosk'; load(); }, [load]);
  // menu & stok habis disegarkan berkala saat layar sambutan
  useEffect(() => { if (screen !== 'attract') return; const t = window.setInterval(load, 300_000); return () => window.clearInterval(t); }, [screen, load]);

  const reset = useCallback(() => {
    setCart([]); setSheet(null); setName(''); setKbd(false); setResult(null); setIdle(null); setScreen('attract');
    scroller.current?.scrollTo({ top: 0 });
  }, []);

  // idle: tanya "masih di sana?" lalu kembali ke layar sambutan
  useEffect(() => {
    const touch = () => { lastTouch.current = Date.now(); setIdle(null); };
    touch();
    window.addEventListener('pointerdown', touch);
    return () => window.removeEventListener('pointerdown', touch);
  }, []);
  useEffect(() => {
    const limit = (data?.kiosk?.idle_seconds ?? 90) * 1000;
    const t = window.setInterval(() => {
      if (screen === 'attract' || screen === 'done') return;
      const left = Math.ceil((limit + 15_000 - (Date.now() - lastTouch.current)) / 1000);
      if (Date.now() - lastTouch.current > limit) { if (left <= 0) reset(); else setIdle(left); }
    }, 500);
    return () => window.clearInterval(t);
  }, [screen, data, reset]);
  // layar selesai kembali sendiri
  useEffect(() => { if (screen !== 'done') return; const t = window.setTimeout(reset, 30_000); return () => window.clearTimeout(t); }, [screen, reset]);
  useEffect(() => { if (!toast) return; const t = window.setTimeout(() => setToast(''), 1600); return () => window.clearTimeout(t); }, [toast]);

  const items: any[] = useMemo(() => data?.items ?? [], [data]);
  const categories: any[] = useMemo(() => (data?.categories ?? []).filter((c: any) => items.some((i) => i.menu_category_id === c.id)), [data, items]);
  const featured = useMemo(() => items.filter((i) => (i.featured || i.best_seller) && !i.sold_out).slice(0, 8), [items]);
  const attractItems = useMemo(() => (featured.length ? featured : items.filter((i) => i.image_url && !i.sold_out).slice(0, 6)), [featured, items]);
  const [slide, setSlide] = useState(0);
  useEffect(() => { if (screen !== 'attract' || attractItems.length < 2) return; const t = window.setInterval(() => setSlide((s) => (s + 1) % attractItems.length), 4500); return () => window.clearInterval(t); }, [screen, attractItems.length]);

  const count = cart.reduce((n, l) => n + l.qty, 0);
  const subtotal = cart.reduce((s, l) => s + l.qty * (priceOf(l.item, channel) + modTotal(l.mods)), 0);
  const service = subtotal * Number(data?.outlet?.service_charge_rate ?? 0) / 100;
  const tax = (subtotal + service) * Number(data?.outlet?.tax_rate ?? 0) / 100;

  const start = (ch: Channel) => {
    setChannel(ch);
    setScreen('menu');
    setCat(categories[0]?.id ?? '');
    document.documentElement.requestFullscreen?.().catch(() => undefined);
  };
  const add = (item: any, qty: number, mods: any[], note = '') => {
    const modIds = mods.map((m) => m.id);
    const key = lineKey(item.id, modIds, note);
    setCart((c) => (c.some((l) => l.key === key) ? c.map((l) => (l.key === key ? { ...l, qty: Math.min(20, l.qty + qty) } : l)) : [...c, { key, item, qty, modIds, mods, note }]));
    setToast(`${item.name} ditambahkan`);
  };
  const quickAdd = (item: any) => {
    if (item.sold_out) return;
    if (item.modifier_groups?.length) setSheet(item);
    else add(item, 1, []);
  };
  const setQty = (key: string, qty: number) => setCart((c) => (qty <= 0 ? c.filter((l) => l.key !== key) : c.map((l) => (l.key === key ? { ...l, qty: Math.min(20, qty) } : l))));
  const jump = (id: string) => { setCat(id); sections.current[id]?.scrollIntoView({ behavior: 'smooth', block: 'start' }); };
  const onScroll = () => {
    const top = scroller.current?.getBoundingClientRect().top ?? 0;
    let cur = cat;
    for (const c of categories) { const el = sections.current[c.id]; if (el && el.getBoundingClientRect().top - top < 120) cur = c.id; }
    if (cur !== cat) setCat(cur);
  };

  // 1 layar upsell: menu populer dari kategori yang belum ada di keranjang
  const suggestions = useMemo(() => {
    const inCart = new Set(cart.map((l) => l.item.id));
    const cats = new Set(cart.map((l) => l.item.menu_category_id));
    return items.filter((i) => !inCart.has(i.id) && !i.sold_out && !cats.has(i.menu_category_id))
      .sort((a, b) => Number(b.best_seller) - Number(a.best_seller) || Number(b.featured) - Number(a.featured)).slice(0, 4);
  }, [cart, items]);
  const checkout = () => setScreen(suggestions.length ? 'upsell' : 'review');

  const submit = async () => {
    setBusy(true);
    try {
      const r = await rpc<any>('public_kiosk_submit', { p_token: token, p: { channel, customer_name: name,
        items: cart.map((l) => ({ menu_item_id: l.item.id, quantity: l.qty, modifier_ids: l.modIds, note: l.note })) } });
      setResult(r);
      setScreen('done');
      if (data?.kiosk?.print_receipt) {
        buildReceiptHtml(r.receipt, { queue: r.queue_number, title: 'BAYAR DI KASIR' }).then(printHtml).catch(() => undefined);
      }
    } catch (e) { setToast(errorMessage(e)); load(); } finally { setBusy(false); }
  };

  const brand = data?.brand;
  const logo = (big = false) => (brand?.logo_url
    ? <img className={`k-logo ${big ? 'big' : ''}`} src={brand.logo_url} alt={brand?.name ?? ''} />
    : <div className={`k-logo k-mono ${big ? 'big' : ''}`}>{(brand?.name ?? data?.outlet?.name ?? 'S').slice(0, 1)}</div>);

  if (error && !data) return <div className="kiosk"><div className="k-frame k-center"><div className="k-error-box"><h1>Kiosk belum siap</h1><p>{error}</p><button className="k-btn" onClick={load}>Coba lagi</button></div></div></div>;
  if (!data) return <div className="kiosk"><div className="k-frame k-center"><div className="k-spinner" /></div></div>;
  const k = data.kiosk;
  const both = k.allow_dine_in && k.allow_takeaway;

  return (
    <div className="kiosk" onContextMenu={(e) => e.preventDefault()}>
      <div className="k-frame">
        {screen === 'attract' && (
          <div className="k-attract" onClick={() => { if (!both) start(k.allow_dine_in ? 'dine_in' : 'takeaway'); }}>
            <div className="k-attract-top">{logo(true)}<div className="k-attract-brand">{brand?.name ?? data.outlet.name}<small>{data.outlet.name}</small></div></div>
            <div className="k-hero">
              {attractItems.map((it, i) => (
                <div key={it.id} className={`k-hero-slide ${i === slide ? 'on' : ''}`}>
                  <div className="k-hero-img">{it.image_url ? <img src={it.image_url} alt="" /> : <Utensils />}</div>
                  {(it.badge || it.best_seller) && <span className="k-badge big">{it.badge ?? 'Terlaris'}</span>}
                  <h2>{it.name}</h2>
                  <div className="k-hero-price">{formatRupiah(priceOf(it, 'dine_in'))}</div>
                </div>
              ))}
              {attractItems.length > 1 && <div className="k-dots">{attractItems.map((it, i) => <i key={it.id} className={i === slide ? 'on' : ''} />)}</div>}
            </div>
            <div className="k-attract-cta">
              <h1>{k.welcome_title}</h1>
              {both ? (
                <div className="k-channels">
                  <button className="k-channel" onClick={(e) => { e.stopPropagation(); start('dine_in'); }}><Utensils /><b>Makan di sini</b></button>
                  <button className="k-channel" onClick={(e) => { e.stopPropagation(); start('takeaway'); }}><ShoppingBag /><b>Bawa pulang</b></button>
                </div>
              ) : <div className="k-touch">{k.welcome_subtitle}</div>}
              {both && <p className="k-sub">{k.welcome_subtitle}</p>}
            </div>
          </div>
        )}

        {screen !== 'attract' && screen !== 'done' && (
          <header className="k-head">
            {logo()}
            <div className="k-head-title"><b>{brand?.name ?? data.outlet.name}</b><small>{channel === 'dine_in' ? 'Makan di sini' : 'Bawa pulang'}{both && <button onClick={() => setChannel(channel === 'dine_in' ? 'takeaway' : 'dine_in')}>ubah</button>}</small></div>
            <button className="k-icon-btn" onClick={reset} aria-label="Mulai ulang"><RotateCcw /><span>Mulai ulang</span></button>
          </header>
        )}

        {screen === 'menu' && (
          <div className="k-menu">
            <nav className="k-rail">
              {featured.length > 0 && <button className={`k-cat ${cat === '__top' ? 'on' : ''}`} onClick={() => { setCat('__top'); scroller.current?.scrollTo({ top: 0, behavior: 'smooth' }); }}><span className="k-cat-img k-cat-star"><Sparkles /></span><b>Rekomendasi</b></button>}
              {categories.map((c) => (
                <button key={c.id} className={`k-cat ${cat === c.id ? 'on' : ''}`} onClick={() => jump(c.id)}>
                  <span className="k-cat-img">{c.image_url ? <img src={c.image_url} alt="" /> : c.name.slice(0, 1)}</span><b>{c.name}</b>
                </button>
              ))}
            </nav>
            <div className="k-scroll" ref={scroller} onScroll={onScroll}>
              {featured.length > 0 && (
                <section className="k-featured">
                  <h2><Sparkles /> Rekomendasi untukmu</h2>
                  <div className="k-strip">
                    {featured.map((it) => (
                      <button key={it.id} className="k-feat" onClick={() => quickAdd(it)}>
                        <div className="k-feat-img">{it.image_url ? <img src={it.image_url} alt="" /> : <Utensils />}</div>
                        <span className="k-badge">{it.badge ?? (it.best_seller ? 'Terlaris' : 'Pilihan')}</span>
                        <b>{it.name}</b><span>{formatRupiah(priceOf(it, channel))}</span>
                      </button>
                    ))}
                  </div>
                </section>
              )}
              {categories.map((c) => (
                <section key={c.id} ref={(el) => { sections.current[c.id] = el; }} className="k-section">
                  <h2>{c.name}</h2>
                  <div className="k-grid">
                    {items.filter((i) => i.menu_category_id === c.id).map((it) => <ItemCard key={it.id} it={it} channel={channel} onOpen={() => !it.sold_out && setSheet(it)} onAdd={() => quickAdd(it)} />)}
                  </div>
                </section>
              ))}
              <div style={{ height: '18vh' }} />
            </div>
          </div>
        )}

        {screen === 'upsell' && (
          <div className="k-page">
            <h1 className="k-page-title">Lengkapi pesananmu?</h1>
            <p className="k-page-sub">Pilihan favorit yang sering dipesan bersama</p>
            <div className="k-grid k-grid-upsell">
              {suggestions.map((it) => <ItemCard key={it.id} it={it} channel={channel} onOpen={() => setSheet(it)} onAdd={() => quickAdd(it)}
                inCart={cart.some((l) => l.item.id === it.id)} />)}
            </div>
            <div className="k-page-actions">
              <button className="k-btn ghost" onClick={() => setScreen('menu')}><ArrowLeft /> Kembali ke menu</button>
              <button className="k-btn primary" onClick={() => setScreen('review')}>{cart.some((l) => suggestions.some((s) => s.id === l.item.id)) ? 'Lanjut' : 'Tidak, terima kasih'} <ChevronRight /></button>
            </div>
          </div>
        )}

        {screen === 'review' && (
          <div className="k-page">
            <h1 className="k-page-title">Cek pesananmu</h1>
            <div className="k-lines">
              {cart.map((l) => (
                <div key={l.key} className="k-line">
                  <div className="k-line-img">{l.item.image_url ? <img src={l.item.image_url} alt="" /> : <Utensils />}</div>
                  <div className="k-line-info">
                    <b>{l.item.name}</b>
                    {l.mods.length > 0 && <small>{l.mods.map((m) => m.name).join(', ')}</small>}
                    <span>{formatRupiah(priceOf(l.item, channel) + modTotal(l.mods))}</span>
                  </div>
                  <div className="k-stepper">
                    <button onClick={() => setQty(l.key, l.qty - 1)} aria-label="Kurangi">{l.qty === 1 ? <Trash2 /> : <Minus />}</button>
                    <b>{l.qty}</b>
                    <button onClick={() => setQty(l.key, l.qty + 1)} aria-label="Tambah"><Plus /></button>
                  </div>
                </div>
              ))}
              {!cart.length && <p className="k-empty">Keranjang kosong.</p>}
            </div>
            <div className="k-name" onClick={() => setKbd(true)}>
              <span>Nama untuk dipanggil <small>(opsional)</small></span>
              <b>{name || <i>Ketuk untuk mengisi</i>}</b>
            </div>
            <div className="k-pay">
              <div className="k-pay-opt on"><div><b>Bayar di kasir</b><small>Tunai, kartu, QRIS & e-wallet. Sebutkan nomor antreanmu.</small></div><Check /></div>
            </div>
            <div className="k-totals">
              <div><span>Subtotal</span><span>{formatRupiah(subtotal)}</span></div>
              {service > 0 && <div><span>Service {Number(data.outlet.service_charge_rate)}%</span><span>{formatRupiah(service)}</span></div>}
              {tax > 0 && <div><span>Pajak {Number(data.outlet.tax_rate)}%</span><span>{formatRupiah(tax)}</span></div>}
              <div className="k-total"><span>Total</span><span>{formatRupiah(subtotal + service + tax)}</span></div>
            </div>
            <div className="k-page-actions">
              <button className="k-btn ghost" onClick={() => setScreen('menu')}><Plus /> Tambah menu</button>
              <button className="k-btn primary" disabled={!cart.length || busy} onClick={submit}>{busy ? 'Mengirim…' : 'Pesan sekarang'} <ChevronRight /></button>
            </div>
          </div>
        )}

        {screen === 'done' && result && (
          <div className="k-done" onClick={reset}>
            <div className="k-done-check"><Check /></div>
            <h1>Pesanan diterima!</h1>
            <p>Nomor antreanmu</p>
            <div className="k-queue">{result.queue_number}</div>
            <div className="k-done-total">Total <b>{formatRupiah(Number(result.receipt?.order?.grand_total ?? 0))}</b></div>
            <p className="k-done-info">Silakan <b>bayar di kasir</b> dengan menyebutkan nomor antrean{k.print_receipt ? ' atau tunjukkan struk' : ''}. Pesanan langsung disiapkan setelah dibayar.</p>
            <button className="k-btn primary" onClick={reset}>Selesai</button>
          </div>
        )}

        {screen === 'menu' && count > 0 && (
          <button className="k-cartbar" onClick={checkout}>
            <span className="k-cartbar-count"><ShoppingBag /><b>{count}</b></span>
            <span className="k-cartbar-label">Lihat pesanan</span>
            <span className="k-cartbar-total">{formatRupiah(subtotal)} <ChevronRight /></span>
          </button>
        )}

        {sheet && <ItemSheet item={sheet} channel={channel} onClose={() => setSheet(null)} onAdd={(qty, mods) => { add(sheet, qty, mods); setSheet(null); }} />}
        {kbd && <Keyboard value={name} onChange={setName} onClose={() => setKbd(false)} />}
        {idle !== null && (
          <div className="k-overlay" onPointerDown={() => setIdle(null)}>
            <div className="k-idle"><h2>Masih di sana?</h2><p>Pesanan akan direset dalam</p><b>{idle}</b><button className="k-btn primary">Saya masih di sini</button></div>
          </div>
        )}
        {toast && <div className="k-toast">{toast}</div>}
      </div>
    </div>
  );
}

function ItemCard({ it, channel, onOpen, onAdd, inCart }: { it: any; channel: Channel; onOpen: () => void; onAdd: () => void; inCart?: boolean }) {
  return (
    <article className={`k-card ${it.sold_out ? 'soldout' : ''}`} onClick={onOpen}>
      <div className="k-card-img">
        {it.image_url ? <img src={it.image_url} alt="" loading="lazy" /> : <Utensils />}
        <div className="k-card-badges">
          {it.best_seller && <span className="k-badge hot">Terlaris</span>}
          {it.badge && <span className="k-badge">{it.badge}</span>}
        </div>
        {it.sold_out && <div className="k-soldout">Habis</div>}
      </div>
      <b className="k-card-name">{it.name}</b>
      <div className="k-card-foot">
        <span>{formatRupiah(priceOf(it, channel))}</span>
        {!it.sold_out && <button className={`k-add ${inCart ? 'in' : ''}`} onClick={(e) => { e.stopPropagation(); onAdd(); }} aria-label={`Tambah ${it.name}`}>{inCart ? <Check /> : <Plus />}</button>}
      </div>
    </article>
  );
}

function ItemSheet({ item, channel, onClose, onAdd }: { item: any; channel: Channel; onClose: () => void; onAdd: (qty: number, mods: any[]) => void }) {
  const groups: any[] = item.modifier_groups ?? [];
  const [sel, setSel] = useState<Record<string, string[]>>(() => Object.fromEntries(groups.map((g) => [g.id, g.modifiers.filter((m: any) => m.is_default).map((m: any) => m.id)])));
  const [qty, setQty] = useState(1);
  const toggle = (g: any, id: string) => setSel((s) => {
    const cur = s[g.id] ?? [];
    if (cur.includes(id)) return { ...s, [g.id]: cur.filter((x) => x !== id) };
    if (g.max_select === 1) return { ...s, [g.id]: [id] };
    if (g.max_select > 0 && cur.length >= g.max_select) return s;
    return { ...s, [g.id]: [...cur, id] };
  });
  const mods = groups.flatMap((g) => g.modifiers.filter((m: any) => (sel[g.id] ?? []).includes(m.id)));
  const missing = groups.filter((g) => (sel[g.id] ?? []).length < (g.min_select ?? 0));
  const unit = priceOf(item, channel) + modTotal(mods);
  return (
    <div className="k-overlay" onClick={onClose}>
      <div className="k-sheet" onClick={(e) => e.stopPropagation()}>
        <button className="k-close" onClick={onClose} aria-label="Tutup"><X /></button>
        <div className="k-sheet-img">{item.image_url ? <img src={item.image_url} alt="" /> : <Utensils />}</div>
        <div className="k-sheet-body">
          <h2>{item.name}</h2>
          {item.description && <p className="k-desc">{item.description}</p>}
          <div className="k-sheet-price">{formatRupiah(priceOf(item, channel))}</div>
          {groups.map((g) => (
            <div key={g.id} className="k-group">
              <div className="k-group-head"><b>{g.name}</b><small className={(sel[g.id] ?? []).length < (g.min_select ?? 0) ? 'need' : ''}>
                {g.min_select > 0 ? `Wajib pilih ${g.min_select === g.max_select ? g.min_select : `min. ${g.min_select}`}` : 'Opsional'}{g.max_select > 1 ? ` · maks. ${g.max_select}` : ''}</small></div>
              <div className="k-opts">
                {g.modifiers.map((m: any) => {
                  const on = (sel[g.id] ?? []).includes(m.id);
                  return <button key={m.id} className={`k-opt ${on ? 'on' : ''}`} onClick={() => toggle(g, m.id)}>{on && <Check />}<span>{m.name}</span>{Number(m.extra_price) > 0 && <small>+{formatRupiah(m.extra_price)}</small>}</button>;
                })}
              </div>
            </div>
          ))}
        </div>
        <div className="k-sheet-foot">
          <div className="k-stepper big">
            <button onClick={() => setQty(Math.max(1, qty - 1))} aria-label="Kurangi"><Minus /></button><b>{qty}</b>
            <button onClick={() => setQty(Math.min(20, qty + 1))} aria-label="Tambah"><Plus /></button>
          </div>
          <button className="k-btn primary grow" disabled={missing.length > 0} onClick={() => onAdd(qty, mods)}>
            {missing.length ? `Pilih ${missing[0].name}` : <>Tambah · {formatRupiah(unit * qty)}</>}
          </button>
        </div>
      </div>
    </div>
  );
}

// keyboard layar (TV sentuh tidak punya keyboard fisik)
function Keyboard({ value, onChange, onClose }: { value: string; onChange: (f: (v: string) => string) => void; onClose: () => void }) {
  const rows = ['QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM'];
  // pembaruan fungsional: ketukan cepat beruntun tidak hilang
  const press = (ch: string) => onChange((v) => (v.length >= 20 || (ch === ' ' && (!v || v.endsWith(' '))) ? v : v + (v && !v.endsWith(' ') ? ch.toLowerCase() : ch)));
  return (
    <div className="k-overlay" onClick={onClose}>
      <div className="k-kbd" onClick={(e) => e.stopPropagation()}>
        <div className="k-kbd-input">{value || <i>Nama kamu</i>}<span className="k-caret" /></div>
        {rows.map((r) => <div key={r} className="k-kbd-row">{r.split('').map((c) => <button key={c} onClick={() => press(c)}>{c}</button>)}</div>)}
        <div className="k-kbd-row">
          <button className="wide" onClick={() => onChange(() => '')}>Hapus semua</button>
          <button className="space" onClick={() => press(' ')}>spasi</button>
          <button className="wide" onClick={() => onChange((v) => v.slice(0, -1))} aria-label="Hapus"><Delete /></button>
          <button className="wide done" onClick={onClose}>Selesai</button>
        </div>
      </div>
    </div>
  );
}
