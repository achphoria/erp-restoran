import { useCallback, useEffect, useState } from 'react';
import { HandCoins } from 'lucide-react';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';
import InvoicePaymentModal from '../sales/InvoicePaymentModal';
import { INVOICE_STATUS, type InvoiceRow } from '../sales/salesShared';

// Tagihan dari cabang lain (Sales Invoice internal) yang harus dibayar outlet pembeli
export default function BranchBillsTab() {
  const { toast } = useFeedback();
  const { profile, outlet } = useAuth();
  const [buyer, setBuyer] = useState(outlet?.id ?? '');
  const [onlyOpen, setOnlyOpen] = useState(true);
  const [rows, setRows] = useState<InvoiceRow[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [paying, setPaying] = useState<InvoiceRow[] | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('rpt_sales_invoices').select('*').eq('customer_type', 'internal').order('due_date');
    if (buyer) q = q.eq('buyer_outlet_id', buyer);
    if (onlyOpen) q = q.neq('status', 'paid');
    setRows(await must(q));
    setSelected([]);
  }, [buyer, onlyOpen]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const sel = rows.filter((r) => selected.includes(r.id));
  const sameParty = sel.every((r) => r.outlet_id === sel[0]?.outlet_id && r.buyer_outlet_id === sel[0]?.buyer_outlet_id);
  const total = rows.reduce((s, r) => s + Number(r.outstanding_amount), 0);

  return (
    <div className="card table-wrap">
      <div className="filter-bar">
        <select value={buyer} onChange={(e) => setBuyer(e.target.value)}>
          <option value="">Semua outlet pembeli</option>
          {profile?.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
        </select>
        <label className="switch"><input type="checkbox" checked={onlyOpen} onChange={(e) => setOnlyOpen(e.target.checked)} /><span>Belum lunas saja</span></label>
        <span className="muted small" style={{ marginLeft: 'auto' }}>Sisa tagihan: <b>{formatRupiah(total)}</b></span>
        <button className="btn-primary" disabled={!sel.length || !sameParty} title={!sameParty ? 'Pilih tagihan dari penjual yang sama' : ''}
          onClick={() => setPaying(sel)}><HandCoins size={16} /> Bayar ({sel.length})</button>
      </div>
      <table className="table">
        <thead><tr><th style={{ width: 28 }}></th><th>Invoice</th><th>Dari cabang</th><th>Untuk</th><th>Jatuh tempo</th><th className="right">Total</th><th className="right">Sisa</th><th>Status</th></tr></thead>
        <tbody>
          {rows.map((r) => {
            const [label, cls] = INVOICE_STATUS[r.status] ?? [r.status, 'badge'];
            return (
              <tr key={r.id}>
                <td>{r.status !== 'paid' && <input type="checkbox" checked={selected.includes(r.id)}
                  onChange={(e) => setSelected(e.target.checked ? [...selected, r.id] : selected.filter((x) => x !== r.id))} />}</td>
                <td><b>{r.invoice_number}</b><div className="muted small">{r.so_number} · {r.invoice_date}</div></td>
                <td>{r.seller_name}</td>
                <td>{r.customer_name}</td>
                <td style={{ color: r.is_overdue ? 'var(--danger)' : undefined }}>{r.due_date}{r.is_overdue && ' (lewat)'}</td>
                <td className="right">{formatRupiah(r.grand_total)}</td>
                <td className="right bold">{formatRupiah(r.outstanding_amount)}</td>
                <td><span className={`badge ${cls}`}>{label}</span></td>
              </tr>
            );
          })}
          {!rows.length && <tr><td colSpan={8} className="empty">Tidak ada tagihan dari cabang.</td></tr>}
        </tbody>
      </table>
      {paying && <InvoicePaymentModal invoices={paying} onClose={() => setPaying(null)} onDone={() => { setPaying(null); load(); }} />}
    </div>
  );
}
