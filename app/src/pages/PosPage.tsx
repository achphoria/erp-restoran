import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah, SALES_CHANNELS, todayISO } from '../lib/format';
import type { CustomerSummary, DiningTable, MenuCategory, MenuItem, Modifier, ModifierGroup, Order } from '../lib/types';
import Modal from '../components/Modal';
import CustomerPicker from '../components/CustomerPicker';
import PaymentModal from '../components/PaymentModal';

interface CartLine {
  key: string;
  item: MenuItem;
  quantity: number;
  modifiers: Modifier[];
  note: string;
}

interface MenuPrice {
  menu_item_id: string;
  outlet_id: string | null;
  sales_channel: string;
  price: number;
}

interface OutletSettings {
  tax_rate: number;
  service_charge_rate: number;
  rounding_unit: number;
}

export default function PosPage() {
  const { outlet } = useAuth();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const appendOrderId = params.get('order');

  const [categories, setCategories] = useState<MenuCategory[]>([]);
  const [items, setItems] = useState<MenuItem[]>([]);
  const [prices, setPrices] = useState<MenuPrice[]>([]);
  const [groups, setGroups] = useState<ModifierGroup[]>([]);
  const [itemGroups, setItemGroups] = useState<{ menu_item_id: string; modifier_group_id: string }[]>([]);
  const [tables, setTables] = useState<DiningTable[]>([]);
  const [settings, setSettings] = useState<OutletSettings>({ tax_rate: 0, service_charge_rate: 0, rounding_unit: 1 });
  const [appendOrder, setAppendOrder] = useState<Order | null>(null);

  const [categoryId, setCategoryId] = useState<string>('all');
  const [search, setSearch] = useState('');
  const [cart, setCart] = useState<CartLine[]>([]);
  const [channel, setChannel] = useState('dine_in');
  const [tableId, setTableId] = useState<string | null>(null);
  const [customerName, setCustomerName] = useState('');
  const [guestCount, setGuestCount] = useState(1);
  const [customer, setCustomer] = useState<CustomerSummary | null>(null);
  const [pickingCustomer, setPickingCustomer] = useState(false);

  const [modifierFor, setModifierFor] = useState<MenuItem | null>(null);
  const [pickingTable, setPickingTable] = useState(false);
  const [payOrder, setPayOrder] = useState<Order | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const loadTables = useCallback(async () => {
    if (!outlet) return;
    setTables(await must(supabase.from('mst_tables').select('*').eq('outlet_id', outlet.id).order('code')) as DiningTable[]);
  }, [outlet]);

  useEffect(() => {
    if (!outlet) return;
    (async () => {
      try {
        const [cats, menu, pr, grp, links, out] = await Promise.all([
          must(supabase.from('mst_menu_categories').select('*').eq('is_active', true).order('sort_order')),
          must(supabase.from('mst_menu_items').select('*').eq('is_active', true).order('name')),
          must(supabase.from('mst_menu_prices').select('*')),
          must(supabase.from('mst_modifier_groups').select('*, mst_modifiers(*)').order('name')),
          must(supabase.from('mst_menu_item_modifier_groups').select('menu_item_id, modifier_group_id')),
          must(supabase.from('sys_outlets').select('tax_rate, service_charge_rate, rounding_unit').eq('id', outlet.id).single()),
        ]);
        setCategories(cats as MenuCategory[]);
        setItems(menu as MenuItem[]);
        setPrices(pr as MenuPrice[]);
        setGroups(grp as ModifierGroup[]);
        setItemGroups(links as { menu_item_id: string; modifier_group_id: string }[]);
        setSettings(out as OutletSettings);
        await loadTables();
      } catch (e) {
        setError(errorMessage(e));
      }
    })();
  }, [outlet, loadTables]);

  // Mode "tambah item ke open bill"
  useEffect(() => {
    if (!appendOrderId) {
      setAppendOrder(null);
      return;
    }
    must(supabase.from('pos_orders').select('*, mst_tables(code)').eq('id', appendOrderId).single())
      .then((o) => {
        const order = o as Order;
        setAppendOrder(order);
        setChannel(order.sales_channel);
      })
      .catch((e) => setError(errorMessage(e)));
  }, [appendOrderId]);

  const priceOf = useCallback(
    (item: MenuItem) => {
      const specific = prices.find((p) => p.menu_item_id === item.id && p.outlet_id === outlet?.id && p.sales_channel === channel);
      const general = prices.find((p) => p.menu_item_id === item.id && p.outlet_id === null && p.sales_channel === channel);
      return Number(specific?.price ?? general?.price ?? item.base_price);
    },
    [prices, channel, outlet],
  );

  const visibleItems = items.filter(
    (i) =>
      (categoryId === 'all' || i.menu_category_id === categoryId) &&
      (!search || i.name.toLowerCase().includes(search.toLowerCase()) || i.code.toLowerCase().includes(search.toLowerCase())),
  );

  const groupsFor = (item: MenuItem) =>
    itemGroups
      .filter((l) => l.menu_item_id === item.id)
      .map((l) => groups.find((g) => g.id === l.modifier_group_id))
      .filter((g): g is ModifierGroup => !!g);

  const addToCart = (item: MenuItem, modifiers: Modifier[] = [], note = '') => {
    const key = `${item.id}|${modifiers.map((m) => m.id).sort().join(',')}|${note}`;
    setCart((prev) => {
      const existing = prev.find((l) => l.key === key);
      if (existing) return prev.map((l) => (l.key === key ? { ...l, quantity: l.quantity + 1 } : l));
      return [...prev, { key, item, quantity: 1, modifiers, note }];
    });
  };

  // Menu habis hari ini (realtime: dapur menandai habis -> langsung terlihat di kasir)
  const [soldOut, setSoldOut] = useState<Set<string>>(new Set());
  const [soldOutMode, setSoldOutMode] = useState(false);

  const loadSoldOut = useCallback(async () => {
    if (!outlet) return;
    const rows = (await must(supabase.from('mst_menu_sold_outs').select('menu_item_id')
      .eq('outlet_id', outlet.id).eq('business_date', todayISO()))) as { menu_item_id: string }[];
    setSoldOut(new Set(rows.map((r) => r.menu_item_id)));
  }, [outlet]);

  useEffect(() => {
    loadSoldOut().catch(() => undefined);
    const ch = supabase.channel('pos-sold-out')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'mst_menu_sold_outs' }, () => loadSoldOut().catch(() => undefined))
      .subscribe();
    return () => {
      supabase.removeChannel(ch);
    };
  }, [loadSoldOut]);

  const onMenuClick = async (item: MenuItem) => {
    if (soldOutMode) {
      try {
        await rpc('pos_set_menu_sold_out', { p_outlet_id: outlet!.id, p_menu_item_id: item.id, p_is_sold_out: !soldOut.has(item.id) });
        await loadSoldOut();
      } catch (e) {
        setError(errorMessage(e));
      }
      return;
    }
    if (soldOut.has(item.id)) return;
    if (groupsFor(item).length) setModifierFor(item);
    else addToCart(item);
  };

  const changeQty = (key: string, delta: number) =>
    setCart((prev) => prev.map((l) => (l.key === key ? { ...l, quantity: l.quantity + delta } : l)).filter((l) => l.quantity > 0));

  // Estimasi total (total final dihitung server)
  const totals = useMemo(() => {
    const subtotal = cart.reduce(
      (s, l) => s + l.quantity * (priceOf(l.item) + l.modifiers.reduce((m, x) => m + Number(x.extra_price), 0)),
      0,
    );
    const service = Math.round((subtotal * Number(settings.service_charge_rate)) / 100);
    const tax = Math.round(((subtotal + service) * Number(settings.tax_rate)) / 100);
    const raw = subtotal + service + tax;
    const unit = Number(settings.rounding_unit) || 1;
    return { subtotal, service, tax, total: Math.round(raw / unit) * unit };
  }, [cart, priceOf, settings]);

  const resetCart = () => {
    setCart([]);
    setTableId(null);
    setCustomerName('');
    setGuestCount(1);
    setCustomer(null);
  };

  const saveOrder = async (thenPay: boolean) => {
    if (!outlet || !cart.length) return;
    if (channel === 'dine_in' && !tableId && !appendOrder) {
      setPickingTable(true);
      return;
    }
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const order = await rpc<Order>('pos_save_order', {
        p_payload: {
          order_id: appendOrder?.id ?? null,
          outlet_id: outlet.id,
          table_id: channel === 'dine_in' ? tableId : null,
          sales_channel: channel,
          customer_name: customerName,
          customer_id: customer?.id ?? null,
          guest_count: guestCount,
          items: cart.map((l) => ({
            menu_item_id: l.item.id,
            quantity: l.quantity,
            note: l.note,
            modifier_ids: l.modifiers.map((m) => m.id),
          })),
        },
      });
      resetCart();
      if (appendOrder) setParams({});
      await loadTables();
      if (thenPay) setPayOrder(order);
      else setNotice(`Order ${order.order_number} tersimpan & dikirim ke dapur.`);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const selectedTable = tables.find((t) => t.id === tableId);

  return (
    <div className="pos">
      <section className="pos-menu">
        <div className="page-header" style={{ marginBottom: 12 }}>
          <h1>Kasir</h1>
          <div className="row">
            <button className={soldOutMode ? 'btn-danger' : ''} onClick={() => setSoldOutMode(!soldOutMode)}>
              {soldOutMode ? '✓ Selesai atur menu habis' : '🚫 Atur menu habis'}
            </button>
            <input placeholder="🔍 Cari menu…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 220 }} />
          </div>
        </div>
        {soldOutMode && (
          <div className="alert alert-info">Klik menu untuk menandai <b>habis</b> / <b>tersedia</b>. Status habis otomatis hilang besok.</div>
        )}
        {error && <div className="alert alert-error">{error}</div>}
        {notice && <div className="alert alert-success">{notice}</div>}
        <div className="pos-categories">
          <button className={categoryId === 'all' ? 'active' : ''} onClick={() => setCategoryId('all')}>Semua</button>
          {categories.map((c) => (
            <button key={c.id} className={categoryId === c.id ? 'active' : ''} onClick={() => setCategoryId(c.id)}>
              {c.name}
            </button>
          ))}
        </div>
        <div className="pos-grid">
          {visibleItems.map((item) => (
            <button key={item.id} className={`menu-tile ${soldOut.has(item.id) ? 'sold-out' : ''}`} onClick={() => onMenuClick(item)}>
              {item.image_url && <img src={item.image_url} alt="" className="menu-tile-img" loading="lazy" />}
              {soldOut.has(item.id) && <span className="sold-out-badge">HABIS</span>}
              <span className="name">{item.name}</span>
              <span className="muted small">{item.code}</span>
              <span className="price">{formatRupiah(priceOf(item))}</span>
            </button>
          ))}
          {!visibleItems.length && <div className="empty">Belum ada menu. Tambahkan di halaman Menu.</div>}
        </div>
      </section>

      <section className="card pos-cart">
        <div className="pos-cart-head">
          {appendOrder ? (
            <div className="alert alert-info" style={{ margin: 0 }}>
              Menambah item ke <b>{appendOrder.order_number}</b>
              {appendOrder.mst_tables && <> (Meja {appendOrder.mst_tables.code})</>}
              <button className="btn-sm" style={{ marginLeft: 8 }} onClick={() => setParams({})}>Batal</button>
            </div>
          ) : (
            <>
              <div className="choice-list">
                {Object.entries(SALES_CHANNELS).map(([k, v]) => (
                  <button key={k} className={channel === k ? 'active' : ''} onClick={() => setChannel(k)}>{v}</button>
                ))}
              </div>
              <div className="row">
                {channel === 'dine_in' && (
                  <button onClick={() => setPickingTable(true)}>🪑 {selectedTable ? `Meja ${selectedTable.code}` : 'Pilih Meja'}</button>
                )}
                <button onClick={() => setPickingCustomer(true)} title="Member">
                  👤 {customer ? `${customer.name} ⭐${customer.points_balance}` : 'Member'}
                </button>
                {!customer && (
                  <input placeholder="Nama pelanggan" value={customerName} onChange={(e) => setCustomerName(e.target.value)} style={{ flex: 1 }} />
                )}
                {channel === 'dine_in' && (
                  <input type="number" min={1} title="Jumlah tamu" value={guestCount}
                    onChange={(e) => setGuestCount(Number(e.target.value) || 1)} style={{ width: 60 }} />
                )}
              </div>
            </>
          )}
        </div>

        <div className="pos-cart-items">
          {!cart.length && <div className="empty">Keranjang kosong.<br />Klik menu untuk menambahkan.</div>}
          {cart.map((l) => (
            <div key={l.key} className="cart-line">
              <div>
                <div className="bold">{l.item.name}</div>
                {l.modifiers.length > 0 && <div className="meta">+ {l.modifiers.map((m) => m.name).join(', ')}</div>}
                {l.note && <div className="meta">📝 {l.note}</div>}
              </div>
              <div className="right">
                {formatRupiah(l.quantity * (priceOf(l.item) + l.modifiers.reduce((s, m) => s + Number(m.extra_price), 0)))}
              </div>
              <div className="qty">
                <button onClick={() => changeQty(l.key, -1)}>−</button>
                <span className="bold">{l.quantity}</span>
                <button onClick={() => changeQty(l.key, 1)}>+</button>
              </div>
            </div>
          ))}
        </div>

        <div className="pos-cart-foot">
          <div className="sum-row"><span className="muted">Subtotal</span><span>{formatRupiah(totals.subtotal)}</span></div>
          <div className="sum-row"><span className="muted">Service {Number(settings.service_charge_rate)}%</span><span>{formatRupiah(totals.service)}</span></div>
          <div className="sum-row"><span className="muted">Pajak {Number(settings.tax_rate)}%</span><span>{formatRupiah(totals.tax)}</span></div>
          <div className="sum-row total"><span>Total</span><span>{formatRupiah(totals.total)}</span></div>
          <div className="muted small">Promo, voucher & tukar poin dihitung di layar pembayaran.</div>
          <div className="grid grid-2">
            <button disabled={busy || !cart.length} onClick={() => saveOrder(false)}>
              {appendOrder ? 'Tambahkan' : 'Simpan (Open Bill)'}
            </button>
            <button className="btn-primary" disabled={busy || !cart.length} onClick={() => saveOrder(true)}>
              {busy ? 'Memproses…' : 'Bayar'}
            </button>
          </div>
          {cart.length > 0 && <button className="btn-sm btn-danger" onClick={resetCart}>Kosongkan</button>}
        </div>
      </section>

      {modifierFor && (
        <ModifierModal
          item={modifierFor}
          groups={groupsFor(modifierFor)}
          onClose={() => setModifierFor(null)}
          onAdd={(mods, note) => {
            addToCart(modifierFor, mods, note);
            setModifierFor(null);
          }}
        />
      )}

      {pickingCustomer && (
        <CustomerPicker
          onClose={() => setPickingCustomer(false)}
          onPick={(c) => {
            setCustomer(c);
            if (c) setCustomerName(c.name);
            setPickingCustomer(false);
          }}
        />
      )}

      {pickingTable && (
        <Modal title="Pilih Meja" onClose={() => setPickingTable(false)}>
          <div className="table-picker">
            {tables.map((t) => (
              <button
                key={t.id}
                className={`table-chip ${t.status === 'occupied' ? 'occupied' : ''} ${t.id === tableId ? 'selected' : ''}`}
                onClick={() => {
                  setTableId(t.id);
                  setPickingTable(false);
                }}
              >
                {t.code}
                <div className="small muted">{t.status === 'occupied' ? 'Terisi' : `${t.capacity} org`}</div>
              </button>
            ))}
          </div>
          <p className="muted small">Meja terisi tetap bisa dipilih (order baru untuk meja yang sama).</p>
        </Modal>
      )}

      {payOrder && (
        <PaymentModal
          order={payOrder}
          onClose={() => {
            setNotice(`Order ${payOrder.order_number} disimpan sebagai open bill.`);
            setPayOrder(null);
          }}
          onPaid={() => {
            setPayOrder(null);
            loadTables();
            if (appendOrderId) navigate('/pos');
          }}
        />
      )}
    </div>
  );
}

function ModifierModal({
  item, groups, onClose, onAdd,
}: {
  item: MenuItem;
  groups: ModifierGroup[];
  onClose: () => void;
  onAdd: (mods: Modifier[], note: string) => void;
}) {
  const [selected, setSelected] = useState<Modifier[]>([]);
  const [note, setNote] = useState('');

  const toggle = (group: ModifierGroup, mod: Modifier) => {
    setSelected((prev) => {
      if (prev.some((m) => m.id === mod.id)) return prev.filter((m) => m.id !== mod.id);
      const inGroup = prev.filter((m) => m.modifier_group_id === group.id);
      if (group.max_select === 1) return [...prev.filter((m) => m.modifier_group_id !== group.id), mod];
      if (inGroup.length >= group.max_select) return prev;
      return [...prev, mod];
    });
  };

  const missing = groups.find((g) => selected.filter((m) => m.modifier_group_id === g.id).length < g.min_select);

  return (
    <Modal
      title={item.name}
      onClose={onClose}
      footer={
        <>
          <button onClick={onClose}>Batal</button>
          <button className="btn-primary" disabled={!!missing} onClick={() => onAdd(selected, note.trim())}>
            Tambah ke Keranjang
          </button>
        </>
      }
    >
      <div className="grid">
        {groups.map((g) => (
          <div key={g.id}>
            <div className="bold" style={{ marginBottom: 6 }}>
              {g.name}{' '}
              <span className="muted small">
                {g.min_select > 0 ? `(wajib, ` : '(opsional, '}maks {g.max_select})
              </span>
            </div>
            <div className="choice-list">
              {[...g.mst_modifiers].sort((a, b) => a.sort_order - b.sort_order).map((m) => (
                <button key={m.id} className={selected.some((s) => s.id === m.id) ? 'active' : ''} onClick={() => toggle(g, m)}>
                  {m.name}
                  {Number(m.extra_price) > 0 && ` +${formatRupiah(m.extra_price)}`}
                </button>
              ))}
            </div>
          </div>
        ))}
        <label className="field">
          <span>Catatan untuk dapur</span>
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="contoh: tanpa bawang" />
        </label>
      </div>
    </Modal>
  );
}
