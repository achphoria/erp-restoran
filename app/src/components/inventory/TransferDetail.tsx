import { useCallback, useEffect, useState } from 'react';
import { CheckCircle2, Package, Printer, Send, Trash2, Truck } from 'lucide-react';
import Modal from '../Modal';
import ScanInput from '../ScanInput';
import LabelPrintModal from './LabelPrintModal';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah } from '../../lib/format';
import { formatDate, resolveBarcode } from './batchUtils';

interface Transfer {
  id: string; transfer_number: string | null; transfer_date: string; status: string; note: string | null;
  shipped_at: string | null; received_at: string | null;
  from: { name: string }; to: { name: string };
}
interface Pkg { id: string; package_no: number; package_code: string | null; status: string; received_at: string | null }
interface Line {
  id: string; package_id: string | null; quantity: number; received_qty: number | null;
  inv_items: { code: string; name: string; inv_units: { code: string } };
  inv_stock_batches: { batch_code: string; expiry_date: string | null } | null;
}

const PKG_STATUS: Record<string, [string, string]> = {
  open: ['Belum dikirim', 'badge'], shipped: ['Dalam perjalanan', 'badge-info'], received: ['Diterima', 'badge-success'],
};
const TRF_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge-warning'], in_transit: ['Dalam perjalanan', 'badge-info'], posted: ['Selesai', 'badge-success'],
};

// Detail transfer: kirim draft, cetak label koli, terima per koli (scan label koli)
export default function TransferDetail({ transferId, receivePackageId, onClose }: {
  transferId: string; receivePackageId?: string; onClose: () => void;
}) {
  const { toast, confirm } = useFeedback();
  const [doc, setDoc] = useState<Transfer | null>(null);
  const [pkgs, setPkgs] = useState<Pkg[]>([]);
  const [lines, setLines] = useState<Line[]>([]);
  const [receiving, setReceiving] = useState<string | null>(receivePackageId ?? null);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [printing, setPrinting] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const [d, p, l] = await Promise.all([
      must(supabase.from('inv_stock_transfers')
        .select('*, from:inv_warehouses!inv_stock_transfers_from_warehouse_id_fkey(name), to:inv_warehouses!inv_stock_transfers_to_warehouse_id_fkey(name)')
        .eq('id', transferId).single()),
      must(supabase.from('inv_transfer_packages').select('id, package_no, package_code, status, received_at').eq('stock_transfer_id', transferId).order('package_no')),
      must(supabase.from('inv_stock_transfer_items')
        .select('id, package_id, quantity, received_qty, inv_items(code, name, inv_units(code)), inv_stock_batches(batch_code, expiry_date)')
        .eq('stock_transfer_id', transferId).order('created_at')),
    ]);
    setDoc(d); setPkgs(p); setLines(l);
  }, [transferId]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  // koli yang akan diterima: isi default qty = qty dikirim
  useEffect(() => {
    if (!receiving) return;
    setQty(Object.fromEntries(lines.filter((l) => l.package_id === receiving).map((l) => [l.id, String(Number(l.quantity))])));
  }, [receiving, lines]);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); await load(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  const onScan = async (code: string) => {
    try {
      const r = await resolveBarcode(code);
      const pkg = r?.kind === 'package' ? pkgs.find((p) => p.id === r.package_id) : null;
      if (!pkg) return toast(r?.kind === 'package' ? `Koli ${r.package_code} milik transfer lain (${r.transfer_number})` : 'Bukan label koli transfer ini', 'error');
      if (pkg.status !== 'shipped') return toast(`Koli ${pkg.package_no} ${pkg.status === 'received' ? 'sudah diterima' : 'belum dikirim'}`, 'info');
      setReceiving(pkg.id);
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const receive = (pkg: Pkg) => run(async () => {
    const pl = lines.filter((l) => l.package_id === pkg.id).map((l) => ({ id: l.id, received_qty: Number(qty[l.id] ?? l.quantity) }));
    const r = await rpc<{ loss_value: number; transfer_status: string }>('inv_receive_transfer_package', { p_package_id: pkg.id, p_lines: pl });
    toast(Number(r.loss_value) > 0
      ? `Koli ${pkg.package_no} diterima. Kekurangan ${formatRupiah(r.loss_value)} dicatat sebagai hilang di perjalanan.`
      : `Koli ${pkg.package_no} diterima lengkap`, Number(r.loss_value) > 0 ? 'info' : 'success');
    setReceiving(null);
    if (r.transfer_status === 'posted') toast('Semua koli diterima, transfer selesai');
  });

  if (!doc) return <Modal title="Transfer" onClose={onClose}><div className="empty">Memuat…</div></Modal>;
  const [stLabel, stBadge] = TRF_STATUS[doc.status] ?? [doc.status, 'badge'];
  const shipped = pkgs.filter((p) => p.package_code);

  return (
    <Modal title={`Transfer ${doc.transfer_number ?? '(draft)'}`} onClose={onClose} large
      footer={<>
        {doc.status === 'draft' && <>
          <button className="btn-danger" style={{ marginRight: 'auto' }} disabled={busy} onClick={async () => {
            if (await confirm({ title: 'Hapus draft transfer?', message: 'Draft ini akan dihapus.', confirmLabel: 'Hapus', danger: true })) {
              run(async () => { await must(supabase.from('inv_stock_transfers').delete().eq('id', doc.id)); onClose(); });
            }
          }}><Trash2 size={16} /> Hapus</button>
          <button disabled={busy} onClick={() => run(async () => { await rpc('inv_post_stock_transfer', { p_id: doc.id }); toast('Transfer selesai, stok sudah pindah'); })}>
            <Send size={16} /> Kirim & langsung terima</button>
          <button className="btn-primary" disabled={busy} onClick={() => run(async () => { await rpc('inv_ship_stock_transfer', { p_id: doc.id }); toast('Koli dikirim. Cetak & tempel label koli.'); })}>
            <Truck size={16} /> Kirim</button>
        </>}
        {!!shipped.length && <button onClick={() => setPrinting(true)}><Printer size={16} /> Label koli</button>}
        {doc.status !== 'draft' && <button onClick={onClose}>Tutup</button>}
      </>}>
      <div className="row" style={{ gap: 10, marginBottom: 12 }}>
        <span className={`badge ${stBadge}`}>{stLabel}</span>
        <b>{doc.from?.name} → {doc.to?.name}</b>
        <span className="muted small">{doc.shipped_at ? `Dikirim ${formatDateTime(doc.shipped_at)}` : doc.transfer_date}
          {doc.received_at ? ` · Diterima ${formatDateTime(doc.received_at)}` : ''}</span>
        {doc.note && <span className="muted small">· {doc.note}</span>}
      </div>
      {doc.status === 'in_transit' && <ScanInput onScan={onScan} autoFocus placeholder="Scan label koli yang datang" />}

      {pkgs.map((p) => {
        const [pl, pb] = PKG_STATUS[p.status] ?? [p.status, 'badge'];
        const isRecv = receiving === p.id && p.status === 'shipped';
        return (
          <div key={p.id} className={`koli-card ${isRecv ? 'active' : ''}`}>
            <div className="koli-head">
              <b><Package size={16} style={{ verticalAlign: -3 }} /> Koli {p.package_no}/{pkgs.length}</b>
              {p.package_code && <code>{p.package_code}</code>}
              <span className={`badge ${pb}`}>{pl}</span>
              {p.status === 'shipped' && !isRecv && <button className="btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setReceiving(p.id)}>Terima koli</button>}
            </div>
            <div className="table-wrap">
              <table className="table">
                <thead><tr><th>Produk</th><th>Batch</th><th className="right">Dikirim</th><th className="right">{isRecv ? 'Qty diterima' : 'Diterima'}</th></tr></thead>
                <tbody>
                  {lines.filter((l) => l.package_id === p.id).map((l) => {
                    const short = l.received_qty !== null && Number(l.received_qty) < Number(l.quantity);
                    return (
                      <tr key={l.id}>
                        <td><b>{l.inv_items.code}</b> · {l.inv_items.name}</td>
                        <td className="small">{l.inv_stock_batches ? <>{l.inv_stock_batches.batch_code}<div className="muted">exp {formatDate(l.inv_stock_batches.expiry_date)}</div></> : <span className="muted">FEFO</span>}</td>
                        <td className="right">{formatNumber(l.quantity)} {l.inv_items.inv_units.code}</td>
                        <td className="right">{isRecv
                          ? <input type="number" step="any" min={0} max={Number(l.quantity)} style={{ width: 90 }} value={qty[l.id] ?? ''}
                              onChange={(e) => setQty({ ...qty, [l.id]: e.target.value })} />
                          : l.received_qty === null ? '-' : <span style={{ color: short ? 'var(--danger)' : 'var(--success)' }}>{formatNumber(l.received_qty)}{short ? ' (kurang)' : ''}</span>}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {isRecv && (
              <div className="row" style={{ justifyContent: 'flex-end', marginTop: 8 }}>
                <span className="muted small" style={{ marginRight: 'auto' }}>Ubah qty bila ada yang kurang/rusak. Kekurangan dijurnal ke purpose "Hilang / Rusak di Perjalanan".</span>
                <button onClick={() => setReceiving(null)}>Batal</button>
                <button className="btn-success" disabled={busy} onClick={() => receive(p)}><CheckCircle2 size={16} /> Konfirmasi terima</button>
              </div>
            )}
            {p.received_at && <div className="muted small">Diterima {formatDateTime(p.received_at)}</div>}
          </div>
        );
      })}

      {printing && (
        <LabelPrintModal kind="koli" title="Cetak Label Koli" defaultSize="80x50" onClose={() => setPrinting(false)}
          labels={shipped.map((p) => ({
            code: p.package_code!,
            title: `KOLI ${p.package_no}/${pkgs.length} · ${doc.transfer_number ?? ''}`,
            lines: [`${doc.from?.name} → ${doc.to?.name}`,
              `${lines.filter((l) => l.package_id === p.id).length} jenis barang · ${formatDate(doc.shipped_at ?? doc.transfer_date)}`],
          }))} />
      )}
    </Modal>
  );
}
