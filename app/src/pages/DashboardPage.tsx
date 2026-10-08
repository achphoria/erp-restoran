import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatNumber, formatRupiah, todayISO } from '../lib/format';
import { expiryInfo, NEAR_EXPIRY_DAYS } from '../components/inventory/batchUtils';
import PendopoOffice from '../components/pendopo/PendopoOffice';

interface DailySales { business_date: string; order_count: number; guest_count: number; grand_total: number }
interface MenuSales { menu_item_name: string; quantity: number; revenue: number }
interface LowStock { item_name: string; quantity: number; min_stock: number; unit_code: string; warehouse_name: string }
interface Expiring { id: string; item_name: string; batch_code: string; expiry_date: string; qty_remaining: number; unit_code: string; warehouse_name: string; stock_value: number }

export default function DashboardPage() {
  const { outlet, profile } = useAuth();
  const [week, setWeek] = useState<DailySales[]>([]);
  const [topMenu, setTopMenu] = useState<MenuSales[]>([]);
  const [lowStock, setLowStock] = useState<LowStock[]>([]);
  const [expiring, setExpiring] = useState<Expiring[]>([]);
  const [openBills, setOpenBills] = useState(0);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!outlet) return;
    const today = todayISO();
    const weekAgo = new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10);
    const soon = new Date(Date.now() + NEAR_EXPIRY_DAYS * 86400000).toISOString().slice(0, 10);
    must(supabase.from('rpt_stock_batches').select('id, item_name, batch_code, expiry_date, qty_remaining, unit_code, warehouse_name, stock_value')
      .gt('qty_remaining', 0).lte('expiry_date', soon).order('expiry_date').limit(8))
      .then(setExpiring).catch(() => setExpiring([]));
    Promise.all([
      must(supabase.from('rpt_daily_sales').select('*').eq('outlet_id', outlet.id).gte('business_date', weekAgo).order('business_date')),
      must(supabase.from('rpt_menu_sales').select('menu_item_name, quantity, revenue').eq('outlet_id', outlet.id).eq('business_date', today).order('quantity', { ascending: false }).limit(5)),
      must(supabase.from('rpt_stock_balances').select('item_name, quantity, min_stock, unit_code, warehouse_name').eq('is_low_stock', true).limit(8)),
      supabase.from('pos_orders').select('id', { count: 'exact', head: true }).eq('outlet_id', outlet.id).eq('status', 'open'),
    ])
      .then(([w, m, s, o]) => {
        setWeek(w as DailySales[]);
        setTopMenu(m as MenuSales[]);
        setLowStock(s as LowStock[]);
        setOpenBills(o.count ?? 0);
      })
      .catch((e) => setError(errorMessage(e)));
  }, [outlet]);

  const today = week.find((d) => d.business_date === todayISO());
  const sales = Number(today?.grand_total ?? 0);
  const orders = Number(today?.order_count ?? 0);

  // 7 hari terakhir, termasuk hari tanpa penjualan
  const days = Array.from({ length: 7 }, (_, i) => {
    const d = new Date(Date.now() - (6 - i) * 86400000);
    const iso = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    return { iso, label: d.toLocaleDateString('id-ID', { weekday: 'short' }), total: Number(week.find((w) => w.business_date === iso)?.grand_total ?? 0) };
  });
  const max = Math.max(...days.map((d) => d.total), 1);

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Halo, {profile?.full_name} 👋</h1>
          <p>Ringkasan {outlet?.name} hari ini.</p>
        </div>
        <Link to="/pos" className="btn btn-primary" style={{ textDecoration: 'none' }}>Buka Kasir →</Link>
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      <PendopoOffice />

      <div className="grid grid-4">
        <div className="card"><div className="stat-label">Penjualan hari ini</div><div className="stat-value">{formatRupiah(sales)}</div></div>
        <div className="card"><div className="stat-label">Transaksi</div><div className="stat-value">{formatNumber(orders)}</div></div>
        <div className="card"><div className="stat-label">Rata-rata per transaksi</div><div className="stat-value">{formatRupiah(orders ? sales / orders : 0)}</div></div>
        <div className="card"><div className="stat-label">Open bill</div><div className="stat-value">{openBills}</div></div>
      </div>

      <div className="grid grid-2" style={{ marginTop: 16 }}>
        <div className="card">
          <h2 style={{ marginBottom: 16 }}>Penjualan 7 hari terakhir</h2>
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 8, height: 180 }}>
            {days.map((d) => (
              <div key={d.iso} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, height: '100%', justifyContent: 'flex-end' }}
                title={`${d.iso}: ${formatRupiah(d.total)}`}>
                <div style={{ width: '100%', maxWidth: 40, height: `${(d.total / max) * 100}%`, minHeight: 2, background: d.iso === todayISO() ? 'var(--primary)' : '#ffc9a8', borderRadius: '4px 4px 0 0' }} />
                <span className="small muted">{d.label}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="card">
          <h2 style={{ marginBottom: 12 }}>Menu terlaris hari ini</h2>
          <table className="table">
            <tbody>
              {topMenu.map((m, i) => (
                <tr key={m.menu_item_name}>
                  <td className="muted">#{i + 1}</td>
                  <td className="bold">{m.menu_item_name}</td>
                  <td className="right">{formatNumber(m.quantity)} porsi</td>
                  <td className="right">{formatRupiah(m.revenue)}</td>
                </tr>
              ))}
              {!topMenu.length && <tr><td className="empty">Belum ada penjualan hari ini.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {!!expiring.length && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-header">
            <h2>⏰ Batch hampir / sudah kedaluwarsa</h2>
            <Link to="/inventory">Lihat di Inventory → Batch →</Link>
          </div>
          <table className="table">
            <tbody>
              {expiring.map((b) => {
                const [label, cls] = expiryInfo(b.expiry_date);
                return (
                  <tr key={b.id}>
                    <td className="bold">{b.item_name}<div className="muted small">{b.batch_code} · {b.warehouse_name}</div></td>
                    <td><span className={`badge ${cls}`}>{label}</span></td>
                    <td className="right">{formatNumber(b.qty_remaining)} {b.unit_code}</td>
                    <td className="right muted">{formatRupiah(b.stock_value)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <div className="card" style={{ marginTop: 16 }}>
        <div className="card-header">
          <h2>⚠️ Stok menipis</h2>
          <Link to="/purchasing">Buat Purchase Order →</Link>
        </div>
        <table className="table">
          <tbody>
            {lowStock.map((s) => (
              <tr key={s.item_name + s.warehouse_name}>
                <td className="bold">{s.item_name}</td>
                <td className="muted">{s.warehouse_name}</td>
                <td className="right" style={{ color: 'var(--danger)' }}>{formatNumber(s.quantity)} {s.unit_code}</td>
                <td className="right muted">min {formatNumber(s.min_stock)}</td>
              </tr>
            ))}
            {!lowStock.length && <tr><td className="empty">Semua stok aman 👍</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
