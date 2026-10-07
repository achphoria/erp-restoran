import { useCallback, useEffect, useState } from 'react';
import { HandCoins, Printer, ReceiptText } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatNumber, formatRupiah } from '../../lib/format';
import { printDocument } from '../../lib/printDoc';
import InvoicePaymentModal from './InvoicePaymentModal';
import { INVOICE_STATUS, type InvoiceRow } from './salesShared';

const REASONS: Record<string, string> = { shortage: 'Kurang kirim / hilang', return: 'Retur barang', discount: 'Potongan harga', other: 'Lainnya' };

// Daftar invoice & piutang (antar cabang + B2B): terima pembayaran, nota kredit, cetak
export default function InvoicesTab() {
  const { toast } = useFeedback();
  const [type, setType] = useState('');
  const [onlyOpen, setOnlyOpen] = useState(true);
  const [rows, setRows] = useState<InvoiceRow[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [paying, setPaying] = useState<InvoiceRow[] | null>(null);
  const [crediting, setCrediting] = useState<InvoiceRow | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('rpt_sales_invoices').select('*').order('invoice_date', { ascending: false }).limit(300);
    if (type) q = q.eq('customer_type', type);
    if (onlyOpen) q = q.neq('status', 'paid');
    setRows(await must(q));
    setSelected([]);
  }, [type, onlyOpen]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const sel = rows.filter((r) => selected.includes(r.id));
  const same = sel.every((r) => r.outlet_id === sel[0].outlet_id && r.customer_type === sel[0].customer_type
    && r.buyer_outlet_id === sel[0].buyer_outlet_id && r.customer_id === sel[0].customer_id);
  const outstanding = rows.reduce((s, r) => s + Number(r.outstanding_amount), 0);
  const overdue = rows.filter((r) => r.is_overdue).reduce((s, r) => s + Number(r.outstanding_amount), 0);

  const print = async (r: InvoiceRow) => {
    try {
      const items = await must(supabase.from('sal_invoice_items').select('quantity, unit_price, line_total, inv_items(code, name), inv_units(code)').eq('invoice_id', r.id).order('created_at'));
      printDocument({
        title: 'INVOICE', number: r.invoice_number,
        meta: [['Tanggal', r.invoice_date], ['Jatuh tempo', r.due_date], ['No. SO', r.so_number ?? '-'], ['Penjual', r.seller_name]],
        partyLabel: 'Ditagihkan kepada', party: [r.customer_name],
        columns: [{ label: 'Kode' }, { label: 'Barang' }, { label: 'Qty', right: true }, { label: 'Harga', right: true }, { label: 'Jumlah', right: true }],
        rows: (items as { quantity: number; unit_price: number; line_total: number; inv_items: { code: string; name: string }; inv_units: { code: string } }[])
          .map((i) => [i.inv_items.code, i.inv_items.name, `${formatNumber(i.quantity)} ${i.inv_units.code}`, formatRupiah(i.unit_price), formatRupiah(i.line_total)]),
        totals: [['Subtotal', Number(r.subtotal)], ...(Number(r.tax_amount) ? [['PPN', Number(r.tax_amount)] as [string, number]] : []),
          ['Total', Number(r.grand_total)], ...(Number(r.paid_amount) + Number(r.credited_amount) ? [['Sisa tagihan', Number(r.outstanding_amount)] as [string, number]] : [])],
        signatures: ['Hormat kami'],
      });
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <>
      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <div className="card stat-card"><div className="stat-label">Piutang berjalan</div><div className="stat-value">{formatRupiah(outstanding)}</div><div className="muted small">{rows.filter((r) => r.status !== 'paid').length} invoice</div></div>
        <div className="card stat-card" style={{ '--stat-color': 'var(--danger)' } as React.CSSProperties}><div className="stat-label">Lewat jatuh tempo</div>
          <div className="stat-value" style={{ color: overdue ? 'var(--danger)' : undefined }}>{formatRupiah(overdue)}</div></div>
        <div className="card stat-card"><div className="stat-label">Dasar tagihan</div><div className="stat-value" style={{ fontSize: 18 }}>Qty dikirim</div><div className="muted small">Kekurangan → nota kredit</div></div>
      </div>
      <div className="card table-wrap">
        <div className="filter-bar">
          <select value={type} onChange={(e) => setType(e.target.value)}>
            <option value="">Antar cabang & B2B</option><option value="internal">Antar cabang</option><option value="external">B2B</option>
          </select>
          <label className="switch"><input type="checkbox" checked={onlyOpen} onChange={(e) => setOnlyOpen(e.target.checked)} /><span>Belum lunas saja</span></label>
          <button className="btn-primary" style={{ marginLeft: 'auto' }} disabled={!sel.length || !same} title={!same ? 'Pilih invoice dari penjual & pembeli yang sama' : ''}
            onClick={() => setPaying(sel)}><HandCoins size={16} /> Terima pembayaran ({sel.length})</button>
        </div>
        <table className="table">
          <thead><tr><th style={{ width: 28 }}></th><th>Invoice</th><th>Penjual</th><th>Pelanggan</th><th>Jatuh tempo</th><th className="right">Total</th><th className="right">Sisa</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {rows.map((r) => {
              const [label, cls] = INVOICE_STATUS[r.status] ?? [r.status, 'badge'];
              return (
                <tr key={r.id}>
                  <td>{r.status !== 'paid' && <input type="checkbox" checked={selected.includes(r.id)}
                    onChange={(e) => setSelected(e.target.checked ? [...selected, r.id] : selected.filter((x) => x !== r.id))} />}</td>
                  <td><b>{r.invoice_number}</b><div className="muted small">{r.so_number} · {r.invoice_date}</div></td>
                  <td>{r.seller_name}</td>
                  <td>{r.customer_type === 'internal' ? <span className="badge badge-primary">Cabang</span> : <span className="badge">B2B</span>} {r.customer_name}</td>
                  <td style={{ color: r.is_overdue ? 'var(--danger)' : undefined }}>{r.due_date}</td>
                  <td className="right">{formatRupiah(r.grand_total)}{Number(r.credited_amount) > 0 && <div className="muted small">kredit −{formatRupiah(r.credited_amount)}</div>}</td>
                  <td className="right bold">{formatRupiah(r.outstanding_amount)}</td>
                  <td><span className={`badge ${cls}`}>{label}</span></td>
                  <td className="right"><div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                    {r.status !== 'paid' && <button className="btn-sm" title="Nota kredit" onClick={() => setCrediting(r)}><ReceiptText size={14} /></button>}
                    <button className="btn-sm" title="Cetak" onClick={() => print(r)}><Printer size={14} /></button>
                  </div></td>
                </tr>
              );
            })}
            {!rows.length && <tr><td colSpan={9} className="empty">Belum ada invoice. Buat invoice dari detail Sales Order setelah barang dikirim.</td></tr>}
          </tbody>
        </table>
      </div>
      {paying && <InvoicePaymentModal invoices={paying} onClose={() => setPaying(null)} onDone={() => { setPaying(null); load(); }} />}
      {crediting && <CreditNoteModal invoice={crediting} onClose={() => setCrediting(null)} onDone={() => { setCrediting(null); load(); }} />}
    </>
  );
}

function CreditNoteModal({ invoice, onClose, onDone }: { invoice: InvoiceRow; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('shortage');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const max = Number(invoice.outstanding_amount);

  const save = async () => {
    setBusy(true);
    try {
      const r = await rpc<{ credit_number: string }>('sal_create_credit_note', { p_invoice_id: invoice.id, p_amount: Number(amount), p_reason: reason, p_note: note });
      toast(`Nota kredit ${r.credit_number} dibuat`);
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); setBusy(false); }
  };

  return (
    <Modal title={`Nota Kredit · ${invoice.invoice_number}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !(Number(amount) > 0) || Number(amount) > max} onClick={save}>Buat nota kredit</button></>}>
      <p className="muted small" style={{ marginTop: 0 }}>Mengurangi tagihan {invoice.customer_name}. Sisa tagihan {formatRupiah(max)}.
        {invoice.customer_type === 'internal' && ' Di cabang pembeli, hutang & selisih kiriman ikut berkurang otomatis.'}</p>
      <div className="form-grid">
        <label className="field"><span>Alasan</span>
          <select value={reason} onChange={(e) => setReason(e.target.value)}>{Object.entries(REASONS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
        <label className="field"><span>Nominal</span><MoneyInput value={amount} onChange={setAmount} /></label>
        <label className="field" style={{ gridColumn: '1 / -1' }}><span>Catatan</span><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="mis. kurang 1 pcs di koli 2" /></label>
      </div>
    </Modal>
  );
}
