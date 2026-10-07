import { useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah, todayISO } from '../lib/format';

interface DailySales {
  business_date: string; order_count: number; guest_count: number; subtotal: number;
  discount_amount: number; service_amount: number; tax_amount: number; grand_total: number;
}
interface MenuSales { menu_item_id: string; menu_item_name: string; quantity: number; revenue: number }
interface PaymentSummary { payment_method_name: string; transaction_count: number; amount: number }

const sum = <T,>(rows: T[], key: keyof T) => rows.reduce((s, r) => s + Number(r[key] ?? 0), 0);

function downloadCsv(filename: string, rows: Record<string, unknown>[]) {
  if (!rows.length) return;
  const headers = Object.keys(rows[0]);
  const csv = [headers.join(','), ...rows.map((r) => headers.map((h) => JSON.stringify(r[h] ?? '')).join(','))].join('\n');
  const url = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export default function ReportsPage() {
  const { outlet } = useAuth();
  const [from, setFrom] = useState(todayISO().slice(0, 8) + '01');
  const [to, setTo] = useState(todayISO());
  const [daily, setDaily] = useState<DailySales[]>([]);
  const [menu, setMenu] = useState<MenuSales[]>([]);
  const [payments, setPayments] = useState<PaymentSummary[]>([]);
  const [error, setError] = useState('');
  const [bySource, setBySource] = useState<Record<string, number>>({});

  // pendapatan per sumber (POS vs Sales Order) untuk outlet ini
  useEffect(() => {
    if (!outlet) return;
    must(supabase.from('rpt_revenue_by_source').select('source, amount').eq('outlet_id', outlet.id).gte('revenue_date', from).lte('revenue_date', to))
      .then((r: { source: string; amount: number }[]) => setBySource(r.reduce<Record<string, number>>((a, x) => ({ ...a, [x.source]: (a[x.source] ?? 0) + Number(x.amount) }), {})))
      .catch(() => setBySource({}));
  }, [outlet, from, to]);

  useEffect(() => {
    if (!outlet) return;
    const query = (view: string) =>
      supabase.from(view).select('*').eq('outlet_id', outlet.id).gte('business_date', from).lte('business_date', to);
    Promise.all([
      must(query('rpt_daily_sales').order('business_date')),
      must(query('rpt_menu_sales')),
      must(query('rpt_payment_summary')),
    ])
      .then(([d, m, p]) => {
        setDaily(d as DailySales[]);
        // gabungkan per menu (view berisi per hari)
        const byMenu = new Map<string, MenuSales>();
        for (const r of m as MenuSales[]) {
          const cur = byMenu.get(r.menu_item_id) ?? { menu_item_id: r.menu_item_id, menu_item_name: r.menu_item_name, quantity: 0, revenue: 0 };
          cur.quantity += Number(r.quantity);
          cur.revenue += Number(r.revenue);
          byMenu.set(r.menu_item_id, cur);
        }
        setMenu([...byMenu.values()].sort((a, b) => b.revenue - a.revenue));
        const byMethod = new Map<string, PaymentSummary>();
        for (const r of p as PaymentSummary[]) {
          const cur = byMethod.get(r.payment_method_name) ?? { payment_method_name: r.payment_method_name, transaction_count: 0, amount: 0 };
          cur.transaction_count += Number(r.transaction_count);
          cur.amount += Number(r.amount);
          byMethod.set(r.payment_method_name, cur);
        }
        setPayments([...byMethod.values()].sort((a, b) => b.amount - a.amount));
      })
      .catch((e) => setError(errorMessage(e)));
  }, [outlet, from, to]);

  const totalSales = sum(daily, 'grand_total');
  const totalOrders = sum(daily, 'order_count');
  const totalMenuRevenue = sum(menu, 'revenue');

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Laporan</h1>
          <p>{outlet?.name}</p>
        </div>
        <div className="row">
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          <span>s/d</span>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      <div className="grid grid-4">
        <div className="card"><div className="stat-label">Total penjualan</div><div className="stat-value">{formatRupiah(totalSales)}</div></div>
        <div className="card"><div className="stat-label">Transaksi</div><div className="stat-value">{formatNumber(totalOrders)}</div></div>
        <div className="card"><div className="stat-label">Tamu</div><div className="stat-value">{formatNumber(sum(daily, 'guest_count'))}</div></div>
        <div className="card"><div className="stat-label">Pajak terkumpul</div><div className="stat-value">{formatRupiah(sum(daily, 'tax_amount'))}</div></div>
      </div>

      <div className="card" style={{ marginTop: 16 }}>
        <div className="card-header"><h2>Pendapatan per sumber</h2><span className="muted small">sebelum pajak</span></div>
        <div className="grid grid-4">
          {([['pos', 'Sales POS'], ['sales_order_b2b', 'Sales Order B2B'], ['sales_order_internal', 'Sales Order antar cabang']] as const).map(([k, v]) => (
            <div key={k}><div className="stat-label">{v}</div><div className="stat-value" style={{ fontSize: 20 }}>{formatRupiah(bySource[k] ?? 0)}</div></div>
          ))}
          <div><div className="stat-label">Total</div><div className="stat-value" style={{ fontSize: 20 }}>{formatRupiah(Object.values(bySource).reduce((a, b) => a + b, 0))}</div></div>
        </div>
      </div>

      <div className="card table-wrap" style={{ marginTop: 16 }}>
        <div className="card-header">
          <h2>Penjualan Harian</h2>
          <button className="btn-sm" onClick={() => downloadCsv(`penjualan-harian_${from}_${to}.csv`, daily as unknown as Record<string, unknown>[])}>⬇ CSV</button>
        </div>
        <table className="table">
          <thead><tr><th>Tanggal</th><th className="right">Transaksi</th><th className="right">Subtotal</th><th className="right">Diskon</th><th className="right">Service</th><th className="right">Pajak</th><th className="right">Total</th></tr></thead>
          <tbody>
            {daily.map((d) => (
              <tr key={d.business_date}>
                <td>{d.business_date}</td>
                <td className="right">{d.order_count}</td>
                <td className="right">{formatRupiah(d.subtotal)}</td>
                <td className="right">{formatRupiah(d.discount_amount)}</td>
                <td className="right">{formatRupiah(d.service_amount)}</td>
                <td className="right">{formatRupiah(d.tax_amount)}</td>
                <td className="right bold">{formatRupiah(d.grand_total)}</td>
              </tr>
            ))}
            {!daily.length && <tr><td colSpan={7} className="empty">Tidak ada penjualan pada periode ini.</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="grid grid-2" style={{ marginTop: 16 }}>
        <div className="card table-wrap">
          <div className="card-header">
            <h2>Penjualan per Menu</h2>
            <button className="btn-sm" onClick={() => downloadCsv(`penjualan-menu_${from}_${to}.csv`, menu as unknown as Record<string, unknown>[])}>⬇ CSV</button>
          </div>
          <table className="table">
            <thead><tr><th>Menu</th><th className="right">Qty</th><th className="right">Pendapatan</th><th className="right">Kontribusi</th></tr></thead>
            <tbody>
              {menu.map((m) => (
                <tr key={m.menu_item_id}>
                  <td className="bold">{m.menu_item_name}</td>
                  <td className="right">{formatNumber(m.quantity)}</td>
                  <td className="right">{formatRupiah(m.revenue)}</td>
                  <td className="right muted">{totalMenuRevenue ? ((m.revenue / totalMenuRevenue) * 100).toFixed(1) : 0}%</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="card table-wrap">
          <h2 style={{ marginBottom: 12 }}>Metode Pembayaran</h2>
          <table className="table">
            <thead><tr><th>Metode</th><th className="right">Transaksi</th><th className="right">Jumlah</th></tr></thead>
            <tbody>
              {payments.map((p) => (
                <tr key={p.payment_method_name}>
                  <td className="bold">{p.payment_method_name}</td>
                  <td className="right">{p.transaction_count}</td>
                  <td className="right">{formatRupiah(p.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <AuditSection outletId={outlet?.id} from={from} to={to} />
    </>
  );
}

interface RefundRow { refund_number: string; order_number: string; amount: number; reason: string; is_stock_returned: boolean; refunded_at: string; refunded_by_name: string | null }
interface VoidRow { order_number: string; void_type: string; amount: number; reason: string | null; voided_at: string | null }

// Audit kasir: refund & void pada periode
function AuditSection({ outletId, from, to }: { outletId?: string; from: string; to: string }) {
  const [refunds, setRefunds] = useState<RefundRow[]>([]);
  const [voids, setVoids] = useState<VoidRow[]>([]);

  useEffect(() => {
    if (!outletId) return;
    Promise.all([
      must(supabase.from('rpt_refunds').select('*').eq('outlet_id', outletId).gte('business_date', from).lte('business_date', to).order('refunded_at', { ascending: false })),
      must(supabase.from('rpt_voids').select('*').eq('outlet_id', outletId).gte('business_date', from).lte('business_date', to).order('voided_at', { ascending: false })),
    ]).then(([r, v]) => { setRefunds(r); setVoids(v); }).catch(() => undefined);
  }, [outletId, from, to]);

  return (
    <div className="grid grid-2" style={{ marginTop: 16 }}>
      <div className="card table-wrap">
        <h2 style={{ marginBottom: 12 }}>Refund <span className="muted small">({refunds.length} · {formatRupiah(sum(refunds, 'amount'))})</span></h2>
        <table className="table">
          <tbody>
            {refunds.map((r) => (
              <tr key={r.refund_number}>
                <td><b>{r.order_number}</b><div className="muted small">{formatDateTime(r.refunded_at)} · {r.refunded_by_name}</div></td>
                <td className="small">{r.reason}{r.is_stock_returned && <span className="badge" style={{ marginLeft: 6 }}>stok kembali</span>}</td>
                <td className="right">{formatRupiah(r.amount)}</td>
              </tr>
            ))}
            {!refunds.length && <tr><td className="empty">Tidak ada refund.</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="card table-wrap">
        <h2 style={{ marginBottom: 12 }}>Void <span className="muted small">({voids.length} · {formatRupiah(sum(voids, 'amount'))})</span></h2>
        <table className="table">
          <tbody>
            {voids.map((v, idx) => (
              <tr key={idx}>
                <td><b>{v.order_number}</b><div className="muted small">{v.voided_at ? formatDateTime(v.voided_at) : ''}</div></td>
                <td><span className="badge">{v.void_type === 'order' ? 'seluruh order' : 'item'}</span></td>
                <td className="small">{v.reason}</td>
                <td className="right">{formatRupiah(v.amount)}</td>
              </tr>
            ))}
            {!voids.length && <tr><td className="empty">Tidak ada void.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
