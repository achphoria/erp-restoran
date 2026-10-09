import { useEffect, useState } from 'react';
import { ArrowRight, CircleAlert, CircleCheck } from 'lucide-react';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';

/* eslint-disable @typescript-eslint/no-explicit-any */
const PO_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', ''], pending_approval: ['Menunggu approval', 'badge-warning'], approved: ['Disetujui', 'badge-info'],
  partially_received: ['Diterima sebagian', 'badge-warning'], received: ['Diterima', 'badge-success'], cancelled: ['Batal', 'badge-danger'],
};
const SO_STATUS: Record<string, [string, string]> = {
  new: ['Baru, belum dikonfirmasi', 'badge-warning'], confirmed: ['Dikonfirmasi', 'badge-info'], partially_delivered: ['Dikirim sebagian', 'badge-info'],
  delivered: ['Terkirim', 'badge-success'], closed: ['Ditutup', ''], rejected: ['Ditolak', 'badge-danger'], cancelled: ['Batal', 'badge-danger'], draft: ['Draft', ''],
};

// Transaksi antar-PT: saldo piutang/hutang antar-PT (harus sama di kedua sisi) & status dokumen PO -> SO -> kirim -> terima -> tagih -> bayar
export default function IcTab({ groupId }: { groupId: string }) {
  const { toast } = useFeedback();
  const [d, setD] = useState<any | null>(null);
  useEffect(() => { rpc<any>('grp_ic_overview', { p_group_id: groupId }).then(setD).catch((e) => toast(errorMessage(e), 'error')); }, [groupId, toast]);
  if (!d) return <div className="card">Memuat…</div>;
  const docs: any[] = d.documents;
  const open = docs.filter((x) => !['received', 'cancelled'].includes(x.po_status) || x.receipts_waiting > 0 || Number(x.invoiced) > Number(x.paid));

  return (
    <>
      <div className="card">
        <div className="card-header"><h2>Saldo antar-PT</h2></div>
        <p className="muted small" style={{ marginTop: 0 }}>Piutang PT penjual harus sama dengan hutang PT pembeli. Selisih biasanya berarti barang sudah diterima tapi belum ditagih (atau sebaliknya), atau ada pembayaran yang baru dicatat di satu sisi.</p>
        <div className="ic-balances">
          {d.balances.map((b: any, i: number) => {
            const ok = Math.abs(Number(b.difference)) < 1;
            return (
              <div key={i} className={`ic-bal ${ok ? 'ok' : 'warn'}`}>
                <div className="ic-bal-parties"><b>{b.buyer}</b><ArrowRight size={16} /><b>{b.seller}</b></div>
                <div className="ic-bal-nums">
                  <div><small className="muted">Hutang {b.buyer}</small><b>{formatRupiah(b.payable)}</b></div>
                  <div><small className="muted">Piutang {b.seller}</small><b>{formatRupiah(b.receivable)}</b></div>
                </div>
                <div className="small">{ok ? <><CircleCheck size={14} /> Cocok</> : <><CircleAlert size={14} /> Selisih {formatRupiah(b.difference)}</>}</div>
              </div>
            );
          })}
          {!d.balances.length && <p className="muted">Belum ada saldo piutang / hutang antar-PT.</p>}
        </div>
      </div>

      <div className="card table-wrap">
        <div className="card-header"><h2>Dokumen antar-PT {open.length > 0 && <span className="badge badge-warning">{open.length} berjalan</span>}</h2></div>
        <table className="table">
          <thead><tr><th>PO</th><th>Pembeli → Penjual</th><th>Status PO</th><th>Sales order penjual</th><th>Kirim / terima</th><th className="right">Nilai PO</th><th className="right">Ditagih / dibayar</th></tr></thead>
          <tbody>
            {docs.map((x) => {
              const ordered = Number(x.qty_ordered) || 1;
              return (
                <tr key={x.id}>
                  <td><b>{x.po_number ?? '(draft)'}</b><div className="muted small">{x.po_date}</div></td>
                  <td className="small"><b>{x.buyer}</b> → {x.seller}</td>
                  <td><span className={`badge ${PO_STATUS[x.po_status]?.[1] ?? ''}`}>{PO_STATUS[x.po_status]?.[0] ?? x.po_status}</span>
                    {x.receipts_waiting > 0 && <div className="small text-danger">{x.receipts_waiting} penerimaan menunggu diposting</div>}</td>
                  <td>{x.so_number ? <><b className="small">{x.so_number}</b> <span className={`badge ${SO_STATUS[x.so_status]?.[1] ?? ''}`}>{SO_STATUS[x.so_status]?.[0] ?? x.so_status}</span></> : <span className="muted small">belum ada (PO belum disetujui)</span>}</td>
                  <td style={{ minWidth: 140 }}>
                    <div className="ic-progress" title={`Dikirim ${x.qty_delivered} · diterima ${x.qty_received} dari ${x.qty_ordered}`}>
                      <span className="sent" style={{ width: `${Math.min(100, (Number(x.qty_delivered) / ordered) * 100)}%` }} />
                      <span className="got" style={{ width: `${Math.min(100, (Number(x.qty_received) / ordered) * 100)}%` }} />
                    </div>
                    <small className="muted">kirim {Math.round((Number(x.qty_delivered) / ordered) * 100)}% · terima {Math.round((Number(x.qty_received) / ordered) * 100)}%</small>
                  </td>
                  <td className="right">{formatRupiah(x.subtotal)}</td>
                  <td className="right small">{Number(x.invoiced) ? <>{formatRupiah(x.invoiced)}<div className={Number(x.paid) >= Number(x.invoiced) ? 'text-success' : 'muted'}>dibayar {formatRupiah(x.paid)}</div></> : '—'}</td>
                </tr>
              );
            })}
            {!docs.length && <tr><td colSpan={7} className="empty">Belum ada transaksi antar-PT. Buat PO di PT pembeli dan pilih supplier dari kelompok <b>PT dalam grup</b>.</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="card small">
        <b>Cara kerja</b>
        <ol style={{ margin: '6px 0 0', paddingLeft: 18 }}>
          <li>PT pembeli membuat <b>PO</b> ke supplier dari kelompok <b>PT dalam grup</b> (dibuat otomatis untuk setiap PT di grup). Barang dicocokkan lewat <b>kode barang yang sama</b>.</li>
          <li>PO disetujui → <b>Sales Order</b> otomatis muncul di PT penjual (status Baru). Penjual konfirmasi atau tolak (ditolak = PO batal).</li>
          <li>Penjual membuat & mengirim <b>Pengiriman</b> → <b>Penerimaan Barang</b> draft otomatis muncul di PT pembeli; pembeli cek & posting.</li>
          <li>Penjual membuat <b>Invoice</b>, pembeli membayar hutang ke supplier PT penjual, penjual mencatat penerimaan pembayaran.</li>
          <li>Semua jurnal transaksi ini ditandai antar-PT dan <b>dieliminasi</b> di laporan konsolidasi grup.</li>
        </ol>
      </div>
    </>
  );
}
