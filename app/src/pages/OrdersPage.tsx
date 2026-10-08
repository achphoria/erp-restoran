import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { useFeedback, useNotice } from '../components/Feedback';
import { errorMessage, formatRupiah, formatTime, SALES_CHANNELS, todayISO } from '../lib/format';
import { printReceipt } from '../lib/receipt';
import type { Order } from '../lib/types';
import PaymentModal from '../components/PaymentModal';
import OrderActions, { type OrderAction } from '../components/OrderActions';

const STATUS_BADGE: Record<string, string> = {
  open: 'badge-warning', paid: 'badge-success', void: 'badge-danger', refunded: 'badge-danger', merged: 'badge',
};
const STATUS_LABEL: Record<string, string> = {
  open: 'Open Bill', paid: 'Lunas', void: 'Void', refunded: 'Refund', merged: 'Digabung',
};

export default function OrdersPage() {
  const { outlet, can } = useAuth();
  const navigate = useNavigate();
  const [orders, setOrders] = useState<Order[]>([]);
  const [status, setStatus] = useState('open');
  const [date, setDate] = useState(todayISO());
  const [expanded, setExpanded] = useState<string | null>(null);
  const [payOrder, setPayOrder] = useState<Order | null>(null);
  const [action, setAction] = useState<{ action: OrderAction; order: Order } | null>(null);
  const [error, setError] = useState('');
  const setNotice = useNotice();
  const { prompt } = useFeedback();

  const load = useCallback(async () => {
    if (!outlet) return;
    try {
      let q = supabase
        .from('pos_orders')
        .select('*, mst_tables(code), pos_order_items(*, pos_order_item_modifiers(modifier_name))')
        .eq('outlet_id', outlet.id)
        .order('created_at', { ascending: false });
      if (status !== 'all') q = q.eq('status', status);
      if (status !== 'open') q = q.eq('business_date', date);
      setOrders((await must(q)) as Order[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [outlet, status, date]);

  useEffect(() => {
    load();
    const channel = supabase
      .channel('orders-page')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'pos_orders' }, () => load())
      .subscribe();
    return () => {
      supabase.removeChannel(channel);
    };
  }, [load]);

  const act = async (fn: () => Promise<unknown>) => {
    setError('');
    try {
      await fn();
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const voidOrder = async (o: Order) => {
    const reason = await prompt({ title: `Void ${o.order_number}`, label: 'Alasan void (wajib, tercatat di log)', placeholder: 'contoh: pelanggan batal pesan', confirmLabel: 'Void order' });
    if (reason) act(() => rpc('pos_void_order', { p_order_id: o.id, p_reason: reason }));
  };

  const voidItem = async (itemId: string, name: string) => {
    const reason = await prompt({ title: `Void "${name}"`, label: 'Alasan void (wajib, tercatat di log)', placeholder: 'contoh: salah input', confirmLabel: 'Void item' });
    if (reason) act(() => rpc('pos_void_order_item', { p_order_item_id: itemId, p_reason: reason }));
  };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Daftar Order</h1>
          <p>Kelola open bill, pembayaran, dan riwayat transaksi.</p>
        </div>
        <div className="row">
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="open">Open Bill</option>
            <option value="paid">Lunas</option>
            <option value="void">Void</option>
            <option value="refunded">Refund</option>
            <option value="all">Semua</option>
          </select>
          {status !== 'open' && <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />}
        </div>
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      <div className="card table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th>No. Order</th><th>Jam</th><th>Tipe</th><th>Meja / Pelanggan</th><th>Status</th>
              <th className="right">Total</th><th></th>
            </tr>
          </thead>
          <tbody>
            {orders.map((o) => (
              <OrderRow
                key={o.id}
                order={o}
                expanded={expanded === o.id}
                onToggle={() => setExpanded(expanded === o.id ? null : o.id)}
                actions={
                  <div className="row" style={{ justifyContent: 'flex-end' }}>
                    {o.status === 'open' && (
                      <>
                        {o.pos_order_items?.some((i) => i.kitchen_status === 'waiting' && !i.is_void) && (
                          <button className="btn-sm btn-success" onClick={() => act(() => rpc('pos_confirm_qr_items', { p_order_id: o.id }))}>
                            ✅ Konfirmasi QR
                          </button>
                        )}
                        <button className="btn-sm" onClick={() => navigate(`/pos?order=${o.id}`)}>+ Item</button>
                        <button className="btn-sm" title="Cetak tagihan untuk tamu" onClick={() => printReceipt(o.id).catch((e) => setError(errorMessage(e)))}>🧾 Tagihan</button>
                        {can('pos.pay') && <button className="btn-sm btn-primary" onClick={() => setPayOrder(o)}>Bayar</button>}
                        <select className="btn-sm" value="" onChange={(e) => setAction({ action: e.target.value as OrderAction, order: o })}>
                          <option value="" disabled>⋯ Lainnya</option>
                          <option value="move">Pindah meja</option>
                          <option value="split">Split bill</option>
                          <option value="merge">Gabung bill</option>
                        </select>
                        {can('pos.void') && <button className="btn-sm btn-danger" onClick={() => voidOrder(o)}>Void</button>}
                      </>
                    )}
                    {o.status === 'paid' && (
                      <>
                        <button className="btn-sm" onClick={() => printReceipt(o.id, { copy: true }).catch((e) => setError(errorMessage(e)))}>🖨️ Struk</button>
                        <button className="btn-sm btn-danger" onClick={() => setAction({ action: 'refund', order: o })}>{can(['pos.refund', 'approval.refund']) ? 'Refund' : 'Ajukan refund'}</button>
                      </>
                    )}
                  </div>
                }
                onVoidItem={o.status === 'open' && can('pos.void') ? voidItem : undefined}
              />
            ))}
            {!orders.length && (
              <tr><td colSpan={7} className="empty">Tidak ada order.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {action && (
        <OrderActions
          action={action.action}
          order={action.order}
          openOrders={orders.filter((o) => o.status === 'open')}
          onClose={() => setAction(null)}
          onDone={(msg) => {
            setAction(null);
            setNotice(msg);
            load();
          }}
        />
      )}

      {payOrder && (
        <PaymentModal
          order={payOrder}
          onClose={() => setPayOrder(null)}
          onPaid={() => {
            setPayOrder(null);
            load();
          }}
        />
      )}
    </>
  );
}

function OrderRow({
  order: o, expanded, onToggle, actions, onVoidItem,
}: {
  order: Order;
  expanded: boolean;
  onToggle: () => void;
  actions: React.ReactNode;
  onVoidItem?: (itemId: string, name: string) => void;
}) {
  return (
    <>
      <tr>
        <td>
          <button className="btn-sm" onClick={onToggle}>{expanded ? '▾' : '▸'}</button>{' '}
          <span className="bold">{o.order_number}</span>
          {o.order_source === 'qr' && <span className="badge badge-info" style={{ marginLeft: 6 }}>QR</span>}
          {o.pos_order_items?.some((i) => i.kitchen_status === 'waiting' && !i.is_void) && (
            <span className="badge badge-warning" style={{ marginLeft: 6 }}>Perlu konfirmasi</span>
          )}
        </td>
        <td>{formatTime(o.created_at)}</td>
        <td>{SALES_CHANNELS[o.sales_channel] ?? o.sales_channel}</td>
        <td>{o.mst_tables ? `Meja ${o.mst_tables.code}` : ''} {o.customer_name ?? ''}</td>
        <td><span className={`badge ${STATUS_BADGE[o.status]}`}>{STATUS_LABEL[o.status]}</span></td>
        <td className="right bold">{formatRupiah(o.grand_total)}</td>
        <td>{actions}</td>
      </tr>
      {expanded && (
        <tr>
          <td colSpan={7} style={{ background: 'var(--surface-2)' }}>
            <table className="table">
              <tbody>
                {o.pos_order_items?.map((i) => (
                  <tr key={i.id} style={i.is_void ? { textDecoration: 'line-through', opacity: 0.5 } : undefined}>
                    <td>
                      {Number(i.quantity)}× {i.menu_item_name}
                      {!!i.pos_order_item_modifiers?.length && (
                        <span className="muted small"> + {i.pos_order_item_modifiers.map((m) => m.modifier_name).join(', ')}</span>
                      )}
                      {i.note && <div className="muted small">📝 {i.note}</div>}
                    </td>
                    <td><span className={`badge ${i.kitchen_status === 'waiting' ? 'badge-warning' : ''}`}>{i.kitchen_status === 'waiting' ? 'menunggu konfirmasi' : i.kitchen_status}</span></td>
                    <td className="right">{formatRupiah(i.line_total)}</td>
                    <td className="right">
                      {onVoidItem && !i.is_void && (
                        <button className="btn-sm btn-danger" onClick={() => onVoidItem(i.id, i.menu_item_name)}>Void</button>
                      )}
                    </td>
                  </tr>
                ))}
                <tr><td colSpan={2} className="muted">Subtotal</td><td className="right">{formatRupiah(o.subtotal)}</td><td /></tr>
                {Number(o.discount_amount) > 0 && (
                  <tr><td colSpan={2} className="muted">Diskon</td><td className="right">-{formatRupiah(o.discount_amount)}</td><td /></tr>
                )}
                <tr><td colSpan={2} className="muted">Service + Pajak</td><td className="right">{formatRupiah(Number(o.service_amount) + Number(o.tax_amount))}</td><td /></tr>
              </tbody>
            </table>
          </td>
        </tr>
      )}
    </>
  );
}
