import { useCallback, useEffect, useState } from 'react';
import { FileText, Printer, Save, Trash2, Truck } from 'lucide-react';
import Modal from '../Modal';
import BatchSelect from '../inventory/BatchSelect';
import LabelPrintModal from '../inventory/LabelPrintModal';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatNumber } from '../../lib/format';
import { printDocument } from '../../lib/printDoc';
import { formatDate, loadBatches, type BatchOption } from '../inventory/batchUtils';
import { DELIVERY_STATUS, type SalesMaster } from './salesShared';

interface Delivery {
  id: string; delivery_number: string | null; delivery_date: string; status: string; warehouse_id: string; vehicle_note: string | null; note: string | null;
  shipped_at: string | null; goods_receipt_id: string | null;
  inv_warehouses: { name: string };
  sal_sales_orders: { so_number: string; customer_type: string; shipping_address: string | null; outlet_id: string; buyer_outlet_id: string | null;
    sal_customers: { name: string; address: string | null; phone: string | null } | null };
}
interface Line {
  id: string; item_id: string; quantity: number; conversion_qty: number; batch_id: string | null; package_no: number;
  inv_items: { code: string; name: string }; inv_units: { code: string };
  sal_sales_order_items: { quantity: number; delivered_qty: number };
  inv_stock_batches: { batch_code: string; expiry_date: string | null } | null;
}

// Pengiriman: draft (qty, batch, nomor koli) -> Kirim (stok keluar) -> label koli & surat jalan
export default function DeliveryDetail({ m, deliveryId, onClose }: { m: SalesMaster; deliveryId: string; onClose: () => void }) {
  const { toast, confirm } = useFeedback();
  const [d, setD] = useState<Delivery | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [pkgs, setPkgs] = useState<{ package_no: number; package_code: string }[]>([]);
  const [batches, setBatches] = useState<BatchOption[]>([]);
  const [receipt, setReceipt] = useState<{ status: string; receipt_number: string | null } | null>(null);
  const [vehicle, setVehicle] = useState('');
  const [printing, setPrinting] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const [x, l, p] = await Promise.all([
      must(supabase.from('sal_deliveries').select('*, inv_warehouses(name), sal_sales_orders(so_number, customer_type, shipping_address, outlet_id, buyer_outlet_id, sal_customers(name, address, phone))').eq('id', deliveryId).single()),
      must(supabase.from('sal_delivery_items').select('id, item_id, quantity, conversion_qty, batch_id, package_no, inv_items(code, name), inv_units(code), sal_sales_order_items(quantity, delivered_qty), inv_stock_batches(batch_code, expiry_date)')
        .eq('delivery_id', deliveryId).order('package_no').order('created_at')),
      must(supabase.from('sal_delivery_packages').select('package_no, package_code').eq('delivery_id', deliveryId).order('package_no')),
    ]);
    setD(x); setLines(l); setPkgs(p); setVehicle(x.vehicle_note ?? '');
    if (x.status === 'draft') loadBatches(x.warehouse_id).then(setBatches).catch(() => setBatches([]));
    if (x.goods_receipt_id) {
      must(supabase.from('pur_goods_receipts').select('status, receipt_number').eq('id', x.goods_receipt_id).single()).then(setReceipt).catch(() => setReceipt(null));
    }
  }, [deliveryId]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const saveLines = async () => {
    for (const l of lines) {
      await must(supabase.from('sal_delivery_items').update({ quantity: Number(l.quantity) || 0, batch_id: l.batch_id || null, package_no: Math.max(1, Number(l.package_no) || 1) }).eq('id', l.id));
    }
    await must(supabase.from('sal_deliveries').update({ vehicle_note: vehicle.trim() || null }).eq('id', deliveryId));
  };
  const run = async (fn: () => Promise<unknown>, msg?: string) => {
    setBusy(true);
    try { await fn(); if (msg) toast(msg); await load(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  if (!d) return <Modal title="Pengiriman" onClose={onClose}><div className="empty">Memuat…</div></Modal>;
  const so = d.sal_sales_orders;
  const draft = d.status === 'draft';
  const [label, cls] = DELIVERY_STATUS[d.status] ?? [d.status, 'badge'];
  const buyerName = so.customer_type === 'internal' ? m.outlets.find((o) => o.id === so.buyer_outlet_id)?.name ?? '' : so.sal_customers?.name ?? '';
  const sellerName = m.outlets.find((o) => o.id === so.outlet_id)?.name ?? '';
  const upd = (i: number, patch: Partial<Line>) => setLines(lines.map((l, j) => (j === i ? { ...l, ...patch } : l)));

  const printSuratJalan = () => {
    try {
      printDocument({
        title: 'SURAT JALAN', number: d.delivery_number ?? '',
        meta: [['Tanggal', d.delivery_date], ['No. SO', so.so_number], ['Gudang', d.inv_warehouses.name], ['Kendaraan', d.vehicle_note ?? '-']],
        partyLabel: 'Kepada',
        party: [buyerName, so.shipping_address ?? (so.customer_type === 'internal' ? m.outlets.find((o) => o.id === so.buyer_outlet_id)?.address ?? '' : so.sal_customers?.address ?? ''), so.sal_customers?.phone ?? ''],
        columns: [{ label: 'Kode' }, { label: 'Barang' }, { label: 'Batch / Exp' }, { label: 'Koli' }, { label: 'Qty', right: true }],
        rows: lines.map((l) => [l.inv_items.code, l.inv_items.name,
          l.inv_stock_batches ? `${l.inv_stock_batches.batch_code} / ${formatDate(l.inv_stock_batches.expiry_date)}` : 'FEFO',
          pkgs.find((p) => p.package_no === l.package_no)?.package_code ?? l.package_no, `${formatNumber(l.quantity)} ${l.inv_units.code}`]),
        notes: `${pkgs.length} koli. Barang diterima dalam keadaan baik & jumlah sesuai.`,
        signatures: ['Pengirim', 'Sopir / Kurir', 'Penerima'],
      });
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <Modal title={`Pengiriman ${d.delivery_number ?? '(draft)'}`} onClose={onClose} large
      footer={draft ? <>
        <button className="btn-danger" style={{ marginRight: 'auto' }} disabled={busy} onClick={async () => {
          if (await confirm({ title: 'Hapus draft pengiriman?', danger: true, confirmLabel: 'Hapus' })) {
            run(async () => { await must(supabase.from('sal_deliveries').delete().eq('id', d.id)); onClose(); });
          }
        }}><Trash2 size={16} /> Hapus</button>
        <button disabled={busy} onClick={() => run(saveLines, 'Draft disimpan')}><Save size={16} /> Simpan</button>
        <button className="btn-primary" disabled={busy || !lines.some((l) => Number(l.quantity) > 0)} onClick={async () => {
          if (!(await confirm({ title: 'Kirim sekarang?', message: 'Stok keluar dari gudang & HPP dicatat. Setelah ini cetak label koli & surat jalan.', confirmLabel: 'Kirim' }))) return;
          run(async () => { await saveLines(); const r = await rpc<{ delivery_number: string }>('sal_ship_delivery', { p_id: d.id }); toast(`${r.delivery_number} dikirim`); });
        }}><Truck size={16} /> Kirim</button>
      </> : <>
        <button style={{ marginRight: 'auto' }} onClick={() => setPrinting(true)} disabled={!pkgs.length}><Printer size={16} /> Label koli</button>
        <button onClick={printSuratJalan}><FileText size={16} /> Surat jalan</button>
        <button onClick={onClose}>Tutup</button>
      </>}>
      <div className="row" style={{ gap: 10, marginBottom: 12 }}>
        <span className={`badge ${cls}`}>{label}</span>
        <b>{sellerName} → {buyerName}</b>
        <span className="muted small">SO {so.so_number} · dari {d.inv_warehouses.name}{d.shipped_at ? ` · dikirim ${formatDateTime(d.shipped_at)}` : ''}</span>
      </div>
      {receipt && <div className={`alert ${receipt.status === 'posted' ? 'alert-success' : 'alert-info'} small`}>
        {receipt.status === 'posted' ? `Sudah diterima pembeli (${receipt.receipt_number}).` : 'Menunggu pembeli scan label koli & konfirmasi terima di menu Pembelian → Penerimaan Barang.'}</div>}
      {draft && (
        <label className="field" style={{ maxWidth: 360 }}><span>Kendaraan / kurir</span>
          <input value={vehicle} placeholder="mis. Box B 1234 XY - Budi" onChange={(e) => setVehicle(e.target.value)} /></label>
      )}
      <div className="table-wrap" style={{ marginTop: 10 }}>
        <table className="table">
          <thead><tr><th>Produk</th><th>Batch</th><th>Koli</th><th>Qty kirim</th></tr></thead>
          <tbody>
            {lines.map((l, i) => {
              const sisa = Number(l.sal_sales_order_items.quantity) - Number(l.sal_sales_order_items.delivered_qty);
              return (
                <tr key={l.id}>
                  <td><b>{l.inv_items.code}</b> · {l.inv_items.name}{draft && <div className="muted small">sisa SO {formatNumber(sisa)} {l.inv_units.code}</div>}</td>
                  <td>{draft
                    ? <BatchSelect batches={batches.filter((b) => b.item_id === l.item_id)} value={l.batch_id ?? ''} onChange={(v) => upd(i, { batch_id: v || null })} />
                    : l.inv_stock_batches ? <>{l.inv_stock_batches.batch_code}<div className="muted small">exp {formatDate(l.inv_stock_batches.expiry_date)}</div></> : <span className="muted">FEFO</span>}</td>
                  <td>{draft
                    ? <input type="number" min={1} style={{ width: 64 }} value={l.package_no} onChange={(e) => upd(i, { package_no: Number(e.target.value) })} />
                    : <code>{pkgs.find((p) => p.package_no === l.package_no)?.package_code ?? l.package_no}</code>}</td>
                  <td>{draft
                    ? <div className="row" style={{ flexWrap: 'nowrap' }}>
                        <input type="number" step="any" min={0} max={sisa} style={{ width: 90 }} value={l.quantity} onChange={(e) => upd(i, { quantity: e.target.value as unknown as number })} />
                        <span className="muted small">{l.inv_units.code}</span></div>
                    : `${formatNumber(l.quantity)} ${l.inv_units.code}`}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {draft && <p className="muted small">Isi nomor koli 1, 2, 3… untuk membagi barang ke beberapa koli; setiap koli dapat label barcode saat dikirim. Qty 0 = tidak dikirim sekarang.</p>}
      {printing && (
        <LabelPrintModal kind="koli" title="Cetak Label Koli" defaultSize="80x50" onClose={() => setPrinting(false)}
          labels={pkgs.map((p) => ({
            code: p.package_code, title: `KOLI ${p.package_no}/${pkgs.length} · ${d.delivery_number ?? ''}`,
            lines: [`${sellerName} → ${buyerName}`, `${lines.filter((l) => l.package_no === p.package_no).length} jenis barang · ${formatDate(d.delivery_date)}`],
          }))} />
      )}
    </Modal>
  );
}
