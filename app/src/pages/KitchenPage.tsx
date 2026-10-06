import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatTime } from '../lib/format';
import type { OrderItem } from '../lib/types';

interface KitchenItem extends OrderItem {
  pos_orders: {
    order_number: string;
    sales_channel: string;
    customer_name: string | null;
    created_at: string;
    status: string;
    outlet_id: string;
    mst_tables: { code: string } | null;
  };
}

const NEXT_STATUS: Record<string, { next: string; label: string; className: string }> = {
  pending: { next: 'cooking', label: 'Masak', className: 'btn-sm' },
  cooking: { next: 'ready', label: 'Siap', className: 'btn-sm btn-primary' },
  ready: { next: 'served', label: 'Disajikan', className: 'btn-sm btn-success' },
};
const STATUS_BADGE: Record<string, string> = {
  pending: 'badge', cooking: 'badge badge-warning', ready: 'badge badge-success',
};
const LATE_MINUTES = 15;

export default function KitchenPage() {
  const { outlet } = useAuth();
  const [items, setItems] = useState<KitchenItem[]>([]);
  const [station, setStation] = useState('all');
  const [error, setError] = useState('');
  const [, setTick] = useState(0);

  const load = useCallback(async () => {
    if (!outlet) return;
    try {
      const rows = await must(
        supabase
          .from('pos_order_items')
          .select('*, pos_order_item_modifiers(modifier_name), pos_orders!inner(order_number, sales_channel, customer_name, created_at, status, outlet_id, mst_tables(code))')
          .eq('pos_orders.outlet_id', outlet.id)
          .neq('pos_orders.status', 'void')
          .eq('is_void', false)
          .in('kitchen_status', ['pending', 'cooking', 'ready'])
          .order('created_at'),
      );
      setItems(rows as KitchenItem[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [outlet]);

  useEffect(() => {
    load();
    const channel = supabase
      .channel('kitchen')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'pos_order_items' }, () => load())
      .subscribe();
    const timer = setInterval(() => setTick((t) => t + 1), 30000); // refresh timer
    return () => {
      supabase.removeChannel(channel);
      clearInterval(timer);
    };
  }, [load]);

  const advance = async (item: KitchenItem) => {
    const step = NEXT_STATUS[item.kitchen_status];
    if (!step) return;
    setItems((prev) => prev.map((i) => (i.id === item.id ? { ...i, kitchen_status: step.next } : i)).filter((i) => i.kitchen_status !== 'served'));
    const { error } = await supabase.from('pos_order_items').update({ kitchen_status: step.next }).eq('id', item.id);
    if (error) {
      setError(error.message);
      load();
    }
  };

  const filtered = items.filter((i) => station === 'all' || i.station === station);
  const tickets = Object.values(
    filtered.reduce<Record<string, KitchenItem[]>>((acc, i) => {
      (acc[i.order_id] ??= []).push(i);
      return acc;
    }, {}),
  );

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Layar Dapur</h1>
          <p>Update otomatis secara realtime. Tiket merah = lebih dari {LATE_MINUTES} menit.</p>
        </div>
        <div className="choice-list">
          {[['all', 'Semua'], ['kitchen', 'Dapur'], ['bar', 'Bar'], ['pastry', 'Pastry']].map(([k, v]) => (
            <button key={k} className={station === k ? 'active' : ''} onClick={() => setStation(k)}>{v}</button>
          ))}
        </div>
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      {!tickets.length && <div className="card empty">🎉 Tidak ada pesanan yang menunggu.</div>}
      <div className="kds">
        {tickets.map((ticketItems) => {
          const o = ticketItems[0].pos_orders;
          const firstAt = ticketItems[0].created_at;
          const minutes = Math.floor((Date.now() - new Date(firstAt).getTime()) / 60000);
          return (
            <div key={ticketItems[0].order_id} className={`card kds-ticket ${minutes >= LATE_MINUTES ? 'late' : ''}`}>
              <div className="kds-ticket-head">
                <div>
                  <div className="bold">{o.mst_tables ? `Meja ${o.mst_tables.code}` : o.sales_channel.toUpperCase()}</div>
                  <div className="muted small">{o.order_number} {o.customer_name && `· ${o.customer_name}`}</div>
                </div>
                <div className="right">
                  <div className="bold">{minutes} mnt</div>
                  <div className="muted small">{formatTime(firstAt)}</div>
                </div>
              </div>
              <div className="kds-ticket-body">
                {ticketItems.map((i) => {
                  const step = NEXT_STATUS[i.kitchen_status];
                  return (
                    <div key={i.id} className={`kds-item ${i.kitchen_status === 'ready' ? 'ready' : ''}`}>
                      <div>
                        <div className="kds-name">{Number(i.quantity)}× {i.menu_item_name}</div>
                        {!!i.pos_order_item_modifiers?.length && (
                          <div className="small muted">+ {i.pos_order_item_modifiers.map((m) => m.modifier_name).join(', ')}</div>
                        )}
                        {i.note && <div className="small" style={{ color: 'var(--danger)' }}>📝 {i.note}</div>}
                        <span className={STATUS_BADGE[i.kitchen_status]}>{i.kitchen_status}</span>
                      </div>
                      {step && <button className={step.className} onClick={() => advance(i)}>{step.label}</button>}
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
}
