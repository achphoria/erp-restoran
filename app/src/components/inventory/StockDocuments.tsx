import { useCallback, useEffect, useMemo, useState } from 'react';
import { ClipboardCheck, Flame, PackagePlus, Plus, Trash2, Truck, Utensils } from 'lucide-react';
import Modal from '../Modal';
import { useAuth } from '../../context/AuthContext';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah, todayISO } from '../../lib/format';
import OpnameForm from './OpnameForm';
import TransferForm from './TransferForm';
import TransferDetail from './TransferDetail';
import BatchSelect from './BatchSelect';
import ScanInput from '../ScanInput';
import { loadBatches, resolveBarcode, type BatchOption } from './batchUtils';

export type AdjustmentType = 'adjustment' | 'waste' | 'usage' | 'shrinkage';
type DocType = AdjustmentType | 'opname' | 'transfer';

export const DOC_INFO: Record<DocType, { label: string; desc: string; icon: typeof Plus; prefix: string }> = {
  adjustment: { label: 'Penyesuaian (+/−)', desc: 'Koreksi qty stok naik atau turun', icon: PackagePlus, prefix: 'ADJ' },
  waste: { label: 'Waste', desc: 'Bahan terbuang: human error, kedaluwarsa, rusak', icon: Trash2, prefix: 'WST' },
  usage: { label: 'Pemakaian', desc: 'Dipakai untuk operasional: peralatan, kebersihan, makan karyawan', icon: Utensils, prefix: 'USG' },
  shrinkage: { label: 'Penyusutan', desc: 'Susut bahan baku, susut masak/produksi, penguapan', icon: Flame, prefix: 'SHR' },
  opname: { label: 'Stock Opname', desc: 'Hitung fisik & sesuaikan selisih', icon: ClipboardCheck, prefix: 'OPN' },
  transfer: { label: 'Transfer Gudang', desc: 'Pindah stok antar gudang', icon: Truck, prefix: 'TRF' },
};
const STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge-warning'], pending_approval: ['Menunggu persetujuan', 'badge-warning'], posted: ['Diposting', 'badge-success'], in_transit: ['Dalam perjalanan', 'badge-info'],
};

interface Warehouse { id: string; code?: string; name: string }
interface Item { id: string; code: string; name: string; inv_units?: { code: string } }
interface DocRow { id: string; type: DocType; number: string | null; date: string; status: string; note: string | null; posted_at: string | null; warehouse: string | null; purpose: string | null }

// Daftar dokumen stok + tombol buat dokumen per jenis
export default function StockDocuments({ companyId, warehouses, items }: { companyId: string; warehouses: Warehouse[]; items: Item[] }) {
  const { toast } = useFeedback();
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [filter, setFilter] = useState<'' | DocType>('');
  const [creating, setCreating] = useState<AdjustmentType | 'transfer' | null>(null);
  const [opname, setOpname] = useState<string | 'new' | null>(null);
  const [transfer, setTransfer] = useState<{ id: string; packageId?: string } | null>(null);

  const load = useCallback(async () => {
    const [adj, opn, trf] = await Promise.all([
      must(supabase.from('inv_stock_adjustments').select('*, inv_warehouses(name), inv_adjustment_purposes(name)').order('created_at', { ascending: false }).limit(60)),
      must(supabase.from('inv_stock_opnames').select('*, inv_warehouses(name)').order('created_at', { ascending: false }).limit(30)),
      must(supabase.from('inv_stock_transfers').select('*, from:inv_warehouses!inv_stock_transfers_from_warehouse_id_fkey(name), to:inv_warehouses!inv_stock_transfers_to_warehouse_id_fkey(name)').order('created_at', { ascending: false }).limit(30)),
    ]);
    type R = Record<string, unknown> & { inv_warehouses?: { name: string }; inv_adjustment_purposes?: { name: string } | null; from?: { name: string }; to?: { name: string } };
    setDocs([
      ...(adj as R[]).map((d) => ({ id: d.id as string, type: d.adjustment_type as DocType, number: d.adjustment_number as string | null, date: d.adjustment_date as string,
        status: d.status as string, note: d.note as string | null, posted_at: d.posted_at as string | null, warehouse: d.inv_warehouses?.name ?? null, purpose: d.inv_adjustment_purposes?.name ?? null })),
      ...(opn as R[]).map((d) => ({ id: d.id as string, type: 'opname' as DocType, number: d.opname_number as string | null, date: d.opname_date as string,
        status: d.status as string, note: d.note as string | null, posted_at: d.posted_at as string | null, warehouse: d.inv_warehouses?.name ?? null, purpose: null })),
      ...(trf as R[]).map((d) => ({ id: d.id as string, type: 'transfer' as DocType, number: d.transfer_number as string | null, date: d.transfer_date as string,
        status: d.status as string, note: d.note as string | null, posted_at: d.posted_at as string | null, warehouse: `${d.from?.name} → ${d.to?.name}`, purpose: null })),
    ].sort((a, b) => (b.posted_at ?? b.date).localeCompare(a.posted_at ?? a.date)));
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const shown = docs.filter((d) => !filter || d.type === filter);

  return (
    <>
      <div className="doc-type-grid">
        {(Object.keys(DOC_INFO) as DocType[]).map((t) => {
          const Icon = DOC_INFO[t].icon;
          const disabled = t === 'transfer' && warehouses.length < 2;
          return (
            <button key={t} className="doc-type-card" disabled={disabled} title={disabled ? 'Butuh minimal 2 gudang' : DOC_INFO[t].desc}
              onClick={() => (t === 'opname' ? setOpname('new') : setCreating(t as AdjustmentType | 'transfer'))}>
              <Icon size={22} />
              <span className="bold">{DOC_INFO[t].label}</span>
              <span className="muted small">{disabled ? 'Butuh minimal 2 gudang' : DOC_INFO[t].desc}</span>
            </button>
          );
        })}
      </div>

      <div className="card table-wrap">
        <div className="card-header">
          <h2>Riwayat Dokumen</h2>
          <ScanInput placeholder="Scan label koli untuk terima barang" style={{ flex: '1 1 240px', maxWidth: 340 }} onScan={async (code) => {
            try {
              const r = await resolveBarcode(code);
              if (r?.kind !== 'package') return toast(r ? 'Ini bukan label koli' : `Kode ${code} tidak dikenal`, 'error');
              setTransfer({ id: r.stock_transfer_id!, packageId: r.package_id });
            } catch (e) { toast(errorMessage(e), 'error'); }
          }} />
          <select value={filter} onChange={(e) => setFilter(e.target.value as DocType | '')}>
            <option value="">Semua jenis</option>
            {(Object.keys(DOC_INFO) as DocType[]).map((t) => <option key={t} value={t}>{DOC_INFO[t].label}</option>)}
          </select>
        </div>
        <table className="table">
          <thead><tr><th>Nomor</th><th>Jenis</th><th>Gudang</th><th>Purpose / catatan</th><th>Tanggal</th><th>Status</th></tr></thead>
          <tbody>
            {shown.map((d) => {
              const [label, badge] = STATUS[d.status] ?? [d.status, 'badge'];
              const openable = (d.type === 'opname' && d.status !== 'posted') || d.type === 'transfer';
              return (
                <tr key={d.id} onClick={openable ? () => (d.type === 'transfer' ? setTransfer({ id: d.id }) : setOpname(d.id)) : undefined} style={openable ? { cursor: 'pointer' } : undefined}>
                  <td className="bold">{d.number ?? '(draft)'}</td>
                  <td>{DOC_INFO[d.type]?.label ?? d.type}</td>
                  <td className="small">{d.warehouse}</td>
                  <td className="small">{d.purpose && <span className="badge" style={{ marginRight: 6 }}>{d.purpose}</span>}<span className="muted">{d.note}</span></td>
                  <td className="small">{d.posted_at ? formatDateTime(d.posted_at) : d.date}</td>
                  <td><span className={`badge ${badge}`}>{label}</span>{openable && d.status !== 'posted' && <span className="muted small"> · klik untuk lanjut</span>}</td>
                </tr>
              );
            })}
            {!shown.length && <tr><td colSpan={6} className="empty">Belum ada dokumen.</td></tr>}
          </tbody>
        </table>
      </div>

      {creating && creating !== 'transfer' && (
        <AdjustmentForm type={creating} companyId={companyId} warehouses={warehouses} items={items}
          onClose={() => setCreating(null)} onDone={() => { setCreating(null); load(); }} />
      )}
      {creating === 'transfer' && (
        <TransferForm companyId={companyId} warehouses={warehouses} items={items}
          onClose={() => setCreating(null)} onDone={(id) => { setCreating(null); load(); if (id) setTransfer({ id }); }} />
      )}
      {transfer && (
        <TransferDetail transferId={transfer.id} receivePackageId={transfer.packageId}
          onClose={() => { setTransfer(null); load(); }} />
      )}
      {opname && (
        <OpnameForm opnameId={opname === 'new' ? null : opname} companyId={companyId} warehouses={warehouses}
          onClose={() => { setOpname(null); load(); }} />
      )}
    </>
  );
}

// ---------------------------------------------------------------- Penyesuaian / waste / pemakaian / penyusutan
interface Purpose { id: string; adjustment_type: string; name: string; is_active: boolean; fin_accounts: { code: string; name: string } | null }
interface Line { item_id: string; quantity: string; purpose_id: string; note: string; batch_id: string }
const EMPTY: Line = { item_id: '', quantity: '', purpose_id: '', note: '', batch_id: '' };

function AdjustmentForm({ type, companyId, warehouses, items, onClose, onDone }: {
  type: AdjustmentType; companyId: string; warehouses: Warehouse[]; items: Item[]; onClose: () => void; onDone: () => void;
}) {
  const { toast } = useFeedback();
  const { outlet } = useAuth();
  const [warehouseId, setWarehouseId] = useState(warehouses.find((w) => (w as { outlet_id?: string }).outlet_id === outlet?.id)?.id ?? warehouses[0]?.id ?? '');
  const [purposes, setPurposes] = useState<Purpose[]>([]);
  const [purposeId, setPurposeId] = useState('');
  const [date, setDate] = useState(todayISO());
  const [note, setNote] = useState('');
  const [lines, setLines] = useState<Line[]>([EMPTY]);
  const [batches, setBatches] = useState<BatchOption[]>([]);
  const [costs, setCosts] = useState<Record<string, { cost: number; qty: number }>>({});
  const [busy, setBusy] = useState(false);
  const minusOnly = type !== 'adjustment';

  useEffect(() => {
    must(supabase.from('inv_adjustment_purposes').select('id, adjustment_type, name, is_active, fin_accounts(code, name)')
      .eq('adjustment_type', type).eq('is_active', true).order('sort_order'))
      .then((p) => setPurposes(p)).catch(() => setPurposes([]));
  }, [type]);

  // HPP rata-rata & stok saat ini di gudang terpilih (untuk estimasi nilai)
  useEffect(() => {
    if (!warehouseId) return;
    must(supabase.from('rpt_stock_balances').select('item_id, average_cost, quantity').eq('warehouse_id', warehouseId))
      .then((rows: { item_id: string; average_cost: number; quantity: number }[]) =>
        setCosts(Object.fromEntries(rows.map((r) => [r.item_id, { cost: Number(r.average_cost), qty: Number(r.quantity) }]))))
      .catch(() => setCosts({}));
    loadBatches(warehouseId).then(setBatches).catch(() => setBatches([]));
  }, [warehouseId]);

  // scan: label batch -> baris dengan batch itu; barcode produk -> tambah qty satuan yang discan
  const onScan = async (code: string) => {
    try {
      const r = await resolveBarcode(code, warehouseId);
      if (!r || r.kind === 'package') return toast(r ? 'Ini label koli, terima di dokumen transfer' : `Kode ${code} tidak dikenal`, 'error');
      if (!items.some((it) => it.id === r.item_id)) return toast(`${r.item_name} tidak ada di daftar produk stok`, 'error');
      if (r.kind === 'batch' && r.warehouse_id !== warehouseId) toast(`Batch ${r.batch_code} tercatat di gudang lain`, 'info');
      const batchId = r.kind === 'batch' && r.warehouse_id === warehouseId ? r.batch_id! : '';
      const add = r.kind === 'item' ? Number(r.qty) : 0;
      setLines((ls) => {
        const body = ls.filter((l) => l.item_id);
        const idx = body.findIndex((l) => l.item_id === r.item_id && l.batch_id === batchId);
        if (idx >= 0) body[idx] = { ...body[idx], quantity: add ? String(Number(body[idx].quantity || 0) + add) : body[idx].quantity };
        else body.push({ ...EMPTY, item_id: r.item_id!, batch_id: batchId, quantity: add ? String(add) : '' });
        return [...body, EMPTY];
      });
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const upd = (i: number, patch: Partial<Line>) => setLines((ls) => {
    const next = ls.map((l, j) => (j === i ? { ...l, ...patch } : l));
    if (next[next.length - 1].item_id) next.push(EMPTY);
    return next;
  });
  const valid = lines.filter((l) => l.item_id && Number(l.quantity) !== 0 && l.quantity !== '');
  const costOf = (l: Line) => Number(batches.find((b) => b.id === l.batch_id)?.unit_cost ?? costs[l.item_id]?.cost ?? 0);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const value = useMemo(() => valid.reduce((s, l) => s + Math.abs(Number(l.quantity)) * costOf(l), 0), [valid, costs, batches]);
  const needPurpose = minusOnly && !purposeId && valid.some((l) => !l.purpose_id);
  const unit = (id: string) => items.find((i) => i.id === id)?.inv_units?.code ?? '';

  const submit = async (post: boolean) => {
    setBusy(true);
    try {
      const doc = (await must(supabase.from('inv_stock_adjustments').insert({
        company_id: companyId, warehouse_id: warehouseId, adjustment_type: type, adjustment_date: date,
        purpose_id: purposeId || null, note: note.trim() || null,
      }).select('id').single())) as { id: string };
      await must(supabase.from('inv_stock_adjustment_items').insert(valid.map((l) => ({
        company_id: companyId, stock_adjustment_id: doc.id, item_id: l.item_id,
        quantity: minusOnly ? Math.abs(Number(l.quantity)) : Number(l.quantity),
        purpose_id: l.purpose_id || null, note: l.note.trim() || null, batch_id: l.batch_id || null,
      }))));
      if (post) {
        await rpc('inv_post_stock_adjustment', { p_id: doc.id });
        const st = await must(supabase.from('inv_stock_adjustments').select('status').eq('id', doc.id).single());
        toast(st.status === 'pending_approval' ? 'Dokumen dikirim ke atasan untuk disetujui' : `${DOC_INFO[type].label} diposting, stok sudah berubah`);
      } else {
        toast('Draft tersimpan');
      }
      onDone();
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <Modal title={DOC_INFO[type].label} onClose={onClose} large
      footer={<>
        <span className="bold" style={{ marginRight: 'auto' }}>Estimasi nilai: {formatRupiah(value)}</span>
        <button disabled={busy || !valid.length || needPurpose} onClick={() => submit(false)}>Simpan Draft</button>
        <button className="btn-primary" disabled={busy || !valid.length || needPurpose} onClick={() => submit(true)}>Simpan & Posting</button>
      </>}>
      <p className="muted small" style={{ marginTop: 0 }}>{DOC_INFO[type].desc}. {minusOnly ? 'Qty yang diisi akan MENGURANGI stok.' : 'Isi qty positif untuk menambah, negatif untuk mengurangi.'}</p>
      <div className="form-grid">
        <label className="field"><span>Gudang</span>
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
        <label className="field"><span>Purpose {minusOnly ? '*' : '(opsional)'}</span>
          <select value={purposeId} onChange={(e) => setPurposeId(e.target.value)}>
            <option value="">{minusOnly ? '— pilih —' : 'Tanpa purpose'}</option>
            {purposes.map((p) => <option key={p.id} value={p.id}>{p.name}{p.fin_accounts ? ` → ${p.fin_accounts.code}` : ''}</option>)}
          </select></label>
        <label className="field"><span>Tanggal</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>Catatan</span><input value={note} onChange={(e) => setNote(e.target.value)} /></label>
      </div>
      {!purposes.length && minusOnly && <div className="alert alert-info small" style={{ marginTop: 10 }}>Belum ada purpose untuk jenis ini. Tambahkan di tab <b>Purpose & Akun</b>.</div>}
      <ScanInput onScan={onScan} placeholder="Scan label batch / barcode produk" style={{ marginTop: 14 }} />
      <div className="table-wrap" style={{ marginTop: 10 }}>
        <table className="table">
          <thead><tr><th>Produk</th><th>Batch</th><th className="right">Stok</th><th>Qty</th><th>Purpose baris</th><th className="right">Nilai</th><th></th></tr></thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td><select style={{ width: '100%', minWidth: 170 }} value={l.item_id} onChange={(e) => upd(i, { item_id: e.target.value, batch_id: '' })}>
                  <option value="">— pilih produk —</option>
                  {items.map((it) => <option key={it.id} value={it.id}>{it.code} · {it.name}</option>)}
                </select></td>
                <td>{l.item_id && <BatchSelect batches={batches.filter((b) => b.item_id === l.item_id)} value={l.batch_id} onChange={(v) => upd(i, { batch_id: v })} />}</td>
                <td className="right small muted">{l.item_id ? `${formatNumber(costs[l.item_id]?.qty ?? 0)} ${unit(l.item_id)}` : ''}</td>
                <td><div className="row" style={{ flexWrap: 'nowrap' }}>
                  <input type="number" step="any" min={minusOnly ? 0 : undefined} style={{ width: 90 }} value={l.quantity} onChange={(e) => upd(i, { quantity: e.target.value })} />
                  <span className="muted small">{unit(l.item_id)}</span></div></td>
                <td><select value={l.purpose_id} onChange={(e) => upd(i, { purpose_id: e.target.value })}>
                  <option value="">Ikut dokumen</option>
                  {purposes.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select></td>
                <td className="right">{l.item_id && l.quantity ? formatRupiah(Math.abs(Number(l.quantity)) * costOf(l)) : ''}</td>
                <td>{l.item_id && <button className="icon-btn" onClick={() => setLines(lines.filter((_, j) => j !== i))} aria-label="Hapus"><Trash2 size={16} /></button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted small">Batch "Otomatis" mengambil yang kedaluwarsa duluan (FEFO), lalu yang masuk duluan. Nilai = harga batch yang terpakai. Jurnal: persediaan ↔ akun purpose (atau akun default jenisnya).</p>
    </Modal>
  );
}
