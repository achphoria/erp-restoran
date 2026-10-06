import { useEffect, useState } from 'react';
import Modal from './Modal';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah } from '../lib/format';
import type { DiningTable, Order } from '../lib/types';

export type OrderAction = 'move' | 'merge' | 'split' | 'refund';

interface Props {
  action: OrderAction;
  order: Order;
  openOrders: Order[];   // order open lain di outlet yang sama (untuk gabung)
  onClose: () => void;
  onDone: (message: string) => void;
}

export default function OrderActions({ action, order, openOrders, onClose, onDone }: Props) {
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const run = async (fn: () => Promise<string>) => {
    setBusy(true);
    setError('');
    try {
      onDone(await fn());
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  const props = { order, openOrders, busy, run, onClose };
  return (
    <>
      {action === 'move' && <MoveTable {...props} error={error} />}
      {action === 'merge' && <Merge {...props} error={error} />}
      {action === 'split' && <Split {...props} error={error} />}
      {action === 'refund' && <Refund {...props} error={error} />}
    </>
  );
}

interface InnerProps {
  order: Order;
  openOrders: Order[];
  busy: boolean;
  error: string;
  run: (fn: () => Promise<string>) => void;
  onClose: () => void;
}

// ---------------------------------------------------------------- Pindah meja
function MoveTable({ order, busy, error, run, onClose }: InnerProps) {
  const [tables, setTables] = useState<DiningTable[]>([]);
  useEffect(() => {
    must(supabase.from('mst_tables').select('*').eq('outlet_id', order.outlet_id).order('code')).then(setTables).catch(() => undefined);
  }, [order.outlet_id]);

  return (
    <Modal title={`Pindah Meja · ${order.order_number}`} onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      <p className="muted">Sekarang: {order.mst_tables ? `Meja ${order.mst_tables.code}` : 'tanpa meja'}. Pilih meja tujuan:</p>
      <div className="table-picker">
        {tables.filter((t) => t.id !== order.table_id).map((t) => (
          <button key={t.id} disabled={busy} className={`table-chip ${t.status === 'occupied' ? 'occupied' : ''}`}
            onClick={() => run(async () => {
              await rpc('pos_move_order_table', { p_order_id: order.id, p_table_id: t.id });
              return `${order.order_number} dipindah ke meja ${t.code}.`;
            })}>
            {t.code}
            <div className="small muted">{t.status === 'occupied' ? 'Terisi' : 'Kosong'}</div>
          </button>
        ))}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- Gabung bill
function Merge({ order, openOrders, busy, error, run, onClose }: InnerProps) {
  const others = openOrders.filter((o) => o.id !== order.id);
  return (
    <Modal title={`Gabung Bill ke ${order.order_number}`} onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      <p className="muted">Semua item dari bill yang dipilih akan dipindah ke <b>{order.order_number}</b>
        {order.mst_tables && <> (Meja {order.mst_tables.code})</>}.</p>
      <div className="grid">
        {others.map((o) => (
          <button key={o.id} disabled={busy} className="btn-block" style={{ textAlign: 'left' }}
            onClick={() => run(async () => {
              await rpc('pos_merge_orders', { p_target_order_id: order.id, p_source_order_id: o.id });
              return `${o.order_number} digabung ke ${order.order_number}.`;
            })}>
            <b>{o.order_number}</b> {o.mst_tables && `· Meja ${o.mst_tables.code}`} {o.customer_name && `· ${o.customer_name}`}
            <span style={{ float: 'right' }}>{formatRupiah(o.grand_total)}</span>
          </button>
        ))}
        {!others.length && <div className="empty">Tidak ada open bill lain.</div>}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- Split bill
function Split({ order, busy, error, run, onClose }: InnerProps) {
  const items = (order.pos_order_items ?? []).filter((i) => !i.is_void);
  const [qty, setQty] = useState<Record<string, number>>({});
  const set = (id: string, v: number, max: number) => setQty({ ...qty, [id]: Math.max(0, Math.min(max, v)) });
  const selected = Object.entries(qty).filter(([, v]) => v > 0);
  const total = items.reduce((s, i) => s + (qty[i.id] ?? 0) * (Number(i.unit_price) + Number(i.modifier_amount)), 0);

  return (
    <Modal title={`Split Bill · ${order.order_number}`} onClose={onClose} large
      footer={<>
        <span className="bold" style={{ marginRight: 'auto' }}>Bill baru: {formatRupiah(total)} (sebelum pajak)</span>
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || !selected.length}
          onClick={() => run(async () => {
            const n = await rpc<Order>('pos_split_order', {
              p_order_id: order.id,
              p_items: selected.map(([order_item_id, quantity]) => ({ order_item_id, quantity })),
            });
            return `Bill baru ${n.order_number} dibuat (${formatRupiah(n.grand_total)}). Bayar masing-masing dari daftar.`;
          })}>Pisahkan</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      <p className="muted">Pilih item (dan jumlahnya) yang dipindah ke bill baru:</p>
      <table className="table">
        <tbody>
          {items.map((i) => (
            <tr key={i.id}>
              <td>
                <b>{i.menu_item_name}</b>
                {!!i.pos_order_item_modifiers?.length && <span className="muted small"> + {i.pos_order_item_modifiers.map((m) => m.modifier_name).join(', ')}</span>}
                <div className="muted small">{Number(i.quantity)} × {formatRupiah(Number(i.unit_price) + Number(i.modifier_amount))}</div>
              </td>
              <td className="right">
                <div className="qty">
                  <button onClick={() => set(i.id, (qty[i.id] ?? 0) - 1, Number(i.quantity))}>−</button>
                  <span className="bold" style={{ minWidth: 20, textAlign: 'center' }}>{qty[i.id] ?? 0}</span>
                  <button onClick={() => set(i.id, (qty[i.id] ?? 0) + 1, Number(i.quantity))}>+</button>
                  <button className="btn-sm" onClick={() => set(i.id, Number(i.quantity), Number(i.quantity))}>Semua</button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </Modal>
  );
}

// ---------------------------------------------------------------- Refund
function Refund({ order, busy, error, run, onClose }: InnerProps) {
  const [reason, setReason] = useState('');
  const [returnStock, setReturnStock] = useState(false);
  return (
    <Modal title={`Refund ${order.order_number}`} onClose={onClose}
      footer={<>
        <button onClick={onClose}>Batal</button>
        <button className="btn-danger" disabled={busy || !reason.trim()}
          onClick={() => run(async () => {
            const r = await rpc<{ refund_number: string }>('pos_refund_order', { p_order_id: order.id, p_reason: reason, p_return_stock: returnStock });
            return `Refund ${r.refund_number} sebesar ${formatRupiah(order.grand_total)} tercatat.`;
          })}>Refund {formatRupiah(order.grand_total)}</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="grid">
        <div className="alert alert-info small" style={{ margin: 0 }}>
          Uang dikembalikan lewat metode bayar semula (tunai keluar dari laci shift Anda).
          Poin member, kuota promo, dan jurnal keuangan otomatis dibalik.
        </div>
        <label className="field"><span>Alasan refund (wajib)</span>
          <input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} placeholder="contoh: salah input menu / pelanggan komplain" /></label>
        <label className="row">
          <input type="checkbox" checked={returnStock} onChange={(e) => setReturnStock(e.target.checked)} />
          Kembalikan bahan ke stok (centang hanya jika makanan <b>belum dibuat</b>)
        </label>
      </div>
    </Modal>
  );
}
