import { useCallback, useEffect, useState } from 'react';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';

interface Row {
  id: string; payment_number: string; payment_date: string; customer_type: string; amount: number; reference_number: string | null;
  seller: { name: string }; buyer: { name: string } | null; sal_customers: { name: string } | null;
  sal_payment_items: { amount: number; sal_invoices: { invoice_number: string } }[];
}

// Riwayat pembayaran invoice (antar cabang & B2B)
export default function PaymentsTab() {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Row[]>([]);

  const load = useCallback(async () => {
    setRows(await must(supabase.from('sal_payments')
      .select('*, seller:sys_outlets!sal_payments_outlet_id_fkey(name), buyer:sys_outlets!sal_payments_buyer_outlet_id_fkey(name), sal_customers(name), sal_payment_items(amount, sal_invoices(invoice_number))')
      .order('created_at', { ascending: false }).limit(200)));
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  return (
    <div className="card table-wrap">
      <table className="table">
        <thead><tr><th>No.</th><th>Tanggal</th><th>Dari</th><th>Ke</th><th>Invoice</th><th>Referensi</th><th className="right">Jumlah</th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id}>
              <td className="bold">{r.payment_number}</td>
              <td>{r.payment_date}</td>
              <td>{r.customer_type === 'internal' ? <><span className="badge badge-primary">Cabang</span> {r.buyer?.name}</> : r.sal_customers?.name}</td>
              <td>{r.seller?.name}</td>
              <td className="small">{r.sal_payment_items.map((i) => <div key={i.sal_invoices.invoice_number}>{i.sal_invoices.invoice_number}: {formatRupiah(i.amount)}</div>)}</td>
              <td className="muted small">{r.reference_number}</td>
              <td className="right bold">{formatRupiah(r.amount)}</td>
            </tr>
          ))}
          {!rows.length && <tr><td colSpan={7} className="empty">Belum ada pembayaran. Terima pembayaran dari tab Invoice & Piutang; tagihan cabang dibayar di Pembelian → Tagihan Cabang.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
