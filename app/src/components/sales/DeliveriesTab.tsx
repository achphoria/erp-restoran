import { useCallback, useEffect, useState } from 'react';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime } from '../../lib/format';
import DeliveryDetail from './DeliveryDetail';
import { DELIVERY_STATUS, type SalesMaster } from './salesShared';

interface Row {
  id: string; delivery_number: string | null; delivery_date: string; status: string; shipped_at: string | null; vehicle_note: string | null;
  inv_warehouses: { name: string; outlet_id: string | null };
  sal_sales_orders: { so_number: string; customer_type: string; buyer_outlet_id: string | null; sal_customers: { name: string } | null };
  sal_delivery_packages: { package_no: number }[];
}

export default function DeliveriesTab({ m }: { m: SalesMaster }) {
  const { toast } = useFeedback();
  const [status, setStatus] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const [open, setOpen] = useState<string | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('sal_deliveries')
      .select('*, inv_warehouses(name, outlet_id), sal_sales_orders(so_number, customer_type, buyer_outlet_id, sal_customers(name)), sal_delivery_packages(package_no)')
      .order('created_at', { ascending: false }).limit(200);
    if (status) q = q.eq('status', status);
    setRows(await must(q));
  }, [status]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const outletName = (id: string | null) => m.outlets.find((o) => o.id === id)?.name ?? '';

  return (
    <div className="card table-wrap">
      <div className="filter-bar">
        <div className="choice-list">
          {[['', 'Semua'], ...Object.entries(DELIVERY_STATUS).map(([k, [v]]) => [k, v])].map(([k, v]) => (
            <button key={k} className={status === k ? 'active' : ''} onClick={() => setStatus(k)}>{v}</button>
          ))}
        </div>
        <span className="muted small" style={{ marginLeft: 'auto' }}>Pengiriman dibuat dari detail Sales Order.</span>
      </div>
      <table className="table">
        <thead><tr><th>No. DO</th><th>SO</th><th>Dari</th><th>Ke</th><th>Koli</th><th>Waktu</th><th>Status</th></tr></thead>
        <tbody>
          {rows.map((r) => {
            const [label, cls] = DELIVERY_STATUS[r.status] ?? [r.status, 'badge'];
            return (
              <tr key={r.id} style={{ cursor: 'pointer' }} onClick={() => setOpen(r.id)}>
                <td className="bold">{r.delivery_number ?? '(draft)'}</td>
                <td>{r.sal_sales_orders.so_number}</td>
                <td>{outletName(r.inv_warehouses.outlet_id)}<div className="muted small">{r.inv_warehouses.name}</div></td>
                <td>{r.sal_sales_orders.customer_type === 'internal' ? outletName(r.sal_sales_orders.buyer_outlet_id) : r.sal_sales_orders.sal_customers?.name}</td>
                <td>{r.sal_delivery_packages.length || '-'}</td>
                <td className="small">{r.shipped_at ? formatDateTime(r.shipped_at) : r.delivery_date}{r.vehicle_note && <div className="muted">{r.vehicle_note}</div>}</td>
                <td><span className={`badge ${cls}`}>{label}</span></td>
              </tr>
            );
          })}
          {!rows.length && <tr><td colSpan={7} className="empty">Belum ada pengiriman.</td></tr>}
        </tbody>
      </table>
      {open && <DeliveryDetail m={m} deliveryId={open} onClose={() => { setOpen(null); load(); }} />}
    </div>
  );
}
