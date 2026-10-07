import { useEffect, useState } from 'react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../../lib/format';
import { loadCashAccounts, type CashAccount, type InvoiceRow } from './salesShared';

// Bayar / terima pembayaran beberapa invoice (penjual & pembeli yang sama).
// Antar cabang: dari akun kas/bank pembeli -> ke akun kas/bank penjual (boleh akun yang sama).
export default function InvoicePaymentModal({ invoices, onClose, onDone }: { invoices: InvoiceRow[]; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const internal = invoices[0]?.customer_type === 'internal';
  const [accounts, setAccounts] = useState<CashAccount[]>([]);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [date, setDate] = useState(todayISO());
  const [ref, setRef] = useState('');
  const [amounts, setAmounts] = useState<Record<string, string>>(Object.fromEntries(invoices.map((i) => [i.id, String(Number(i.outstanding_amount))])));
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    loadCashAccounts().then((a) => {
      setAccounts(a);
      const bank = a.find((x) => x.code === '1-1200') ?? a[0];
      setFrom(bank?.id ?? ''); setTo(bank?.id ?? '');
    });
  }, []);

  const total = invoices.reduce((s, i) => s + Number(amounts[i.id] || 0), 0);
  const invalid = invoices.some((i) => Number(amounts[i.id] || 0) > Number(i.outstanding_amount) || Number(amounts[i.id] || 0) < 0);

  const pay = async () => {
    setBusy(true);
    try {
      const r = await rpc<{ payment_number: string; pending_approval?: boolean }>('sal_record_payment', {
        p_allocations: invoices.map((i) => ({ invoice_id: i.id, amount: Number(amounts[i.id] || 0) })).filter((a) => a.amount > 0),
        p_to_account_id: to, p_from_account_id: internal ? from : null, p_payment_date: date, p_reference: ref || null,
      });
      toast(r.pending_approval ? `Pembayaran ${formatRupiah(total)} dikirim ke penyetuju` : `Pembayaran ${r.payment_number} tercatat`);
      onDone();
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <Modal title={internal ? 'Bayar Tagihan Cabang' : 'Terima Pembayaran'} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || total <= 0 || invalid || !to || (internal && !from)} onClick={pay}>Simpan pembayaran {formatRupiah(total)}</button></>}>
      <p className="muted small" style={{ marginTop: 0 }}>
        {invoices[0]?.customer_name} → {invoices[0]?.seller_name}
      </p>
      {!accounts.length && <div className="alert alert-info small">Daftar akun kas/bank butuh akses Keuangan (finance.view).</div>}
      <div className="form-grid">
        {internal && (
          <label className="field"><span>Dibayar dari (akun pembeli)</span>
            <select value={from} onChange={(e) => setFrom(e.target.value)}>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label>
        )}
        <label className="field"><span>{internal ? 'Masuk ke (akun penjual)' : 'Masuk ke akun'}</span>
          <select value={to} onChange={(e) => setTo(e.target.value)}>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label>
        <label className="field"><span>Tanggal</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>No. referensi / transfer</span><input value={ref} onChange={(e) => setRef(e.target.value)} /></label>
      </div>
      <table className="table" style={{ marginTop: 12 }}>
        <thead><tr><th>Invoice</th><th className="right">Sisa</th><th>Dibayar</th></tr></thead>
        <tbody>
          {invoices.map((i) => (
            <tr key={i.id}>
              <td><b>{i.invoice_number}</b><div className="muted small">jatuh tempo {i.due_date}</div></td>
              <td className="right">{formatRupiah(i.outstanding_amount)}</td>
              <td><MoneyInput value={amounts[i.id] ?? ''} onChange={(v) => setAmounts({ ...amounts, [i.id]: v })} style={{ width: 140 }} /></td>
            </tr>
          ))}
        </tbody>
      </table>
      {internal && <p className="muted small">Kalau kedua cabang memakai rekening yang sama, pilih akun yang sama: saldo bank tidak berubah, hanya hutang/piutang antar cabang yang lunas.</p>}
    </Modal>
  );
}
