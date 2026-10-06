import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { errorMessage, formatRupiah } from '../lib/format';
import Modal from '../components/Modal';

interface PublicModifier { id: string; name: string; extra_price: number }
interface PublicGroup { id: string; name: string; min_select: number; max_select: number; modifiers: PublicModifier[] }
interface PublicItem {
  id: string; name: string; description: string | null; image_url: string | null;
  menu_category_id: string; price: number; modifier_groups: PublicGroup[];
}
interface PublicMenu {
  company_name: string;
  outlet: { name: string; tax_rate: number; service_charge_rate: number; requires_confirmation: boolean };
  table: { code: string };
  categories: { id: string; name: string }[];
  items: PublicItem[];
}
interface TableOrder {
  order_number: string; subtotal: number; grand_total: number;
  items: { name: string; quantity: number; line_total: number; note: string | null; kitchen_status: string; modifiers: string[] }[];
}
interface CartLine { key: string; item: PublicItem; quantity: number; modifiers: PublicModifier[]; note: string }

const STATUS: Record<string, [string, string]> = {
  waiting: ['Menunggu konfirmasi', 'badge-warning'],
  pending: ['Diterima dapur', 'badge-info'],
  cooking: ['Sedang dimasak', 'badge-warning'],
  ready: ['Siap diantar', 'badge-success'],
  served: ['Disajikan', 'badge-success'],
};

export default function PublicOrderPage() {
  const { token = '' } = useParams();
  const [menu, setMenu] = useState<PublicMenu | null>(null);
  const [tableOrder, setTableOrder] = useState<TableOrder | null>(null);
  const [categoryId, setCategoryId] = useState('all');
  const [cart, setCart] = useState<CartLine[]>([]);
  const [customizing, setCustomizing] = useState<PublicItem | null>(null);
  const [view, setView] = useState<'menu' | 'cart' | 'status'>('menu');
  const [name, setName] = useState(() => {
    try { return localStorage.getItem('qr.name') ?? ''; } catch { return ''; }
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [fatal, setFatal] = useState('');

  const loadOrder = useCallback(() => {
    rpc<TableOrder | null>('public_get_table_order', { p_token: token }).then(setTableOrder).catch(() => undefined);
  }, [token]);

  useEffect(() => {
    rpc<PublicMenu>('public_get_table_menu', { p_token: token })
      .then((m) => {
        setMenu(m);
        document.title = `Pesan · ${m.outlet.name}`;
      })
      .catch((e) => setFatal(errorMessage(e)));
    loadOrder();
    const t = setInterval(loadOrder, 10000);   // status pesanan diperbarui tiap 10 detik
    return () => clearInterval(t);
  }, [token, loadOrder]);

  const lineTotal = (l: CartLine) => l.quantity * (Number(l.item.price) + l.modifiers.reduce((s, m) => s + Number(m.extra_price), 0));
  const cartTotal = cart.reduce((s, l) => s + lineTotal(l), 0);
  const cartCount = cart.reduce((s, l) => s + l.quantity, 0);

  const add = (item: PublicItem, modifiers: PublicModifier[] = [], note = '') => {
    const key = `${item.id}|${modifiers.map((m) => m.id).sort().join(',')}|${note}`;
    setCart((prev) => {
      const ex = prev.find((l) => l.key === key);
      if (ex) return prev.map((l) => (l.key === key ? { ...l, quantity: l.quantity + 1 } : l));
      return [...prev, { key, item, quantity: 1, modifiers, note }];
    });
  };
  const changeQty = (key: string, d: number) =>
    setCart((prev) => prev.map((l) => (l.key === key ? { ...l, quantity: l.quantity + d } : l)).filter((l) => l.quantity > 0));

  const submit = async () => {
    setBusy(true);
    setError('');
    try {
      try { localStorage.setItem('qr.name', name); } catch { /* abaikan */ }
      const r = await rpc<TableOrder>('public_submit_table_order', {
        p_token: token,
        p_customer_name: name,
        p_items: cart.map((l) => ({ menu_item_id: l.item.id, quantity: l.quantity, note: l.note, modifier_ids: l.modifiers.map((m) => m.id) })),
      });
      setTableOrder(r);
      setCart([]);
      setView('status');
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const items = useMemo(
    () => (menu?.items ?? []).filter((i) => categoryId === 'all' || i.menu_category_id === categoryId),
    [menu, categoryId],
  );

  if (fatal) {
    return <div className="auth-page"><div className="card auth-card"><h2>😔 Maaf</h2><p>{fatal}</p></div></div>;
  }
  if (!menu) return <div className="auth-page"><p className="muted">Memuat menu…</p></div>;

  return (
    <div className="qr-page">
      <header className="qr-header">
        <div>
          <div className="bold" style={{ fontSize: 17 }}>{menu.outlet.name}</div>
          <div className="small muted">{menu.company_name}</div>
        </div>
        <span className="badge badge-primary" style={{ fontSize: 13 }}>Meja {menu.table.code}</span>
      </header>

      <div className="tabs" style={{ padding: '0 12px', marginBottom: 0, background: 'var(--surface)' }}>
        <button className={view === 'menu' ? 'active' : ''} onClick={() => setView('menu')}>Menu</button>
        <button className={view === 'cart' ? 'active' : ''} onClick={() => setView('cart')}>Keranjang {cartCount > 0 && `(${cartCount})`}</button>
        <button className={view === 'status' ? 'active' : ''} onClick={() => { loadOrder(); setView('status'); }}>Pesanan Saya</button>
      </div>

      <main className="qr-body">
        {error && <div className="alert alert-error">{error}</div>}

        {view === 'menu' && (
          <>
            <div className="pos-categories" style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>
              <button className={categoryId === 'all' ? 'active' : ''} onClick={() => setCategoryId('all')}>Semua</button>
              {menu.categories.map((c) => (
                <button key={c.id} className={categoryId === c.id ? 'active' : ''} onClick={() => setCategoryId(c.id)}>{c.name}</button>
              ))}
            </div>
            <div className="grid">
              {items.map((i) => (
                <div key={i.id} className="card qr-item">
                  {i.image_url && <img src={i.image_url} alt="" />}
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div className="bold">{i.name}</div>
                    {i.description && <div className="muted small">{i.description}</div>}
                    <div className="bold" style={{ color: 'var(--primary)', marginTop: 4 }}>{formatRupiah(i.price)}</div>
                  </div>
                  <button className="btn-primary" onClick={() => (i.modifier_groups.length ? setCustomizing(i) : add(i))}>+ Tambah</button>
                </div>
              ))}
            </div>
          </>
        )}

        {view === 'cart' && (
          <div className="card">
            {!cart.length && <div className="empty">Keranjang masih kosong.</div>}
            {cart.map((l) => (
              <div key={l.key} className="cart-line">
                <div>
                  <div className="bold">{l.item.name}</div>
                  {l.modifiers.length > 0 && <div className="meta">+ {l.modifiers.map((m) => m.name).join(', ')}</div>}
                  {l.note && <div className="meta">📝 {l.note}</div>}
                </div>
                <div className="right">{formatRupiah(lineTotal(l))}</div>
                <div className="qty">
                  <button onClick={() => changeQty(l.key, -1)}>−</button>
                  <span className="bold">{l.quantity}</span>
                  <button onClick={() => changeQty(l.key, 1)}>+</button>
                </div>
              </div>
            ))}
            {cart.length > 0 && (
              <div className="grid" style={{ marginTop: 12 }}>
                <div className="sum-row total"><span>Subtotal</span><span>{formatRupiah(cartTotal)}</span></div>
                <div className="muted small">
                  Belum termasuk pajak {Number(menu.outlet.tax_rate)}%
                  {Number(menu.outlet.service_charge_rate) > 0 && ` & service ${Number(menu.outlet.service_charge_rate)}%`}. Pembayaran di kasir.
                </div>
                <label className="field"><span>Nama Anda</span><input value={name} onChange={(e) => setName(e.target.value)} placeholder="Supaya pelayan mudah memanggil" /></label>
                <button className="btn-primary btn-lg" disabled={busy || !name.trim()} onClick={submit}>
                  {busy ? 'Mengirim…' : 'Kirim Pesanan'}
                </button>
              </div>
            )}
          </div>
        )}

        {view === 'status' && (
          <div className="card">
            {!tableOrder ? (
              <div className="empty">Belum ada pesanan di meja ini.</div>
            ) : (
              <>
                <div className="card-header">
                  <h3>Pesanan {tableOrder.order_number}</h3>
                  <button className="btn-sm" onClick={loadOrder}>↻</button>
                </div>
                {menu.outlet.requires_confirmation && tableOrder.items.some((i) => i.kitchen_status === 'waiting') && (
                  <div className="alert alert-info small">Pesanan baru akan dikonfirmasi kasir sebelum dimasak.</div>
                )}
                {tableOrder.items.map((i, idx) => {
                  const [label, badge] = STATUS[i.kitchen_status] ?? [i.kitchen_status, 'badge'];
                  return (
                    <div key={idx} className="cart-line">
                      <div>
                        <div className="bold">{Number(i.quantity)}× {i.name}</div>
                        {i.modifiers.length > 0 && <div className="meta">+ {i.modifiers.join(', ')}</div>}
                      </div>
                      <div className="right"><span className={`badge ${badge}`}>{label}</span></div>
                    </div>
                  );
                })}
                <div className="sum-row total" style={{ marginTop: 12 }}><span>Total tagihan</span><span>{formatRupiah(tableOrder.grand_total)}</span></div>
                <div className="muted small">Termasuk pajak & service. Silakan bayar di kasir.</div>
              </>
            )}
          </div>
        )}
      </main>

      {view === 'menu' && cartCount > 0 && (
        <button className="btn-primary qr-cart-bar" onClick={() => setView('cart')}>
          🛒 {cartCount} item · {formatRupiah(cartTotal)} — Lihat Keranjang
        </button>
      )}

      {customizing && (
        <CustomizeModal item={customizing} onClose={() => setCustomizing(null)}
          onAdd={(mods, note) => { add(customizing, mods, note); setCustomizing(null); }} />
      )}
    </div>
  );
}

function CustomizeModal({ item, onClose, onAdd }: { item: PublicItem; onClose: () => void; onAdd: (m: PublicModifier[], note: string) => void }) {
  const [selected, setSelected] = useState<{ group: string; mod: PublicModifier }[]>([]);
  const [note, setNote] = useState('');

  const toggle = (g: PublicGroup, m: PublicModifier) =>
    setSelected((prev) => {
      if (prev.some((s) => s.mod.id === m.id)) return prev.filter((s) => s.mod.id !== m.id);
      if (g.max_select === 1) return [...prev.filter((s) => s.group !== g.id), { group: g.id, mod: m }];
      if (prev.filter((s) => s.group === g.id).length >= g.max_select) return prev;
      return [...prev, { group: g.id, mod: m }];
    });
  const missing = item.modifier_groups.some((g) => selected.filter((s) => s.group === g.id).length < g.min_select);
  const extra = selected.reduce((s, x) => s + Number(x.mod.extra_price), 0);

  return (
    <Modal title={item.name} onClose={onClose}
      footer={<button className="btn-primary btn-block" disabled={missing} onClick={() => onAdd(selected.map((s) => s.mod), note.trim())}>
        Tambah · {formatRupiah(Number(item.price) + extra)}
      </button>}>
      <div className="grid">
        {item.modifier_groups.map((g) => (
          <div key={g.id}>
            <div className="bold" style={{ marginBottom: 6 }}>{g.name} <span className="muted small">{g.min_select > 0 ? '(wajib)' : '(opsional)'}</span></div>
            <div className="choice-list">
              {g.modifiers.map((m) => (
                <button key={m.id} className={selected.some((s) => s.mod.id === m.id) ? 'active' : ''} onClick={() => toggle(g, m)}>
                  {m.name}{Number(m.extra_price) > 0 && ` +${formatRupiah(m.extra_price)}`}
                </button>
              ))}
            </div>
          </div>
        ))}
        <label className="field"><span>Catatan</span><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="contoh: tanpa bawang" maxLength={200} /></label>
      </div>
    </Modal>
  );
}
