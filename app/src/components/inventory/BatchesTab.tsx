import { useCallback, useEffect, useMemo, useState } from 'react';
import { History, Printer } from 'lucide-react';
import Modal from '../Modal';
import ScanInput from '../ScanInput';
import LabelPrintModal from './LabelPrintModal';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah } from '../../lib/format';
import { batchLabel, daysLeft, expiryInfo, formatDate, NEAR_EXPIRY_DAYS, resolveBarcode } from './batchUtils';

interface Warehouse { id: string; name: string }
interface Batch {
  id: string; warehouse_id: string; warehouse_name: string; item_id: string; item_code: string; item_name: string; unit_code: string;
  track_batch: boolean; batch_code: string; lot_number: string | null; expiry_date: string | null; received_at: string;
  qty_in: number; qty_remaining: number; unit_cost: number; stock_value: number; reference_type: string | null; reference_number: string | null;
}
type Filter = 'active' | 'near' | 'expired' | 'all';

// Daftar batch per gudang, status kedaluwarsa, jejak pergerakan & cetak label
export default function BatchesTab({ warehouses }: { warehouses: Warehouse[] }) {
  const { toast } = useFeedback();
  const [warehouseId, setWarehouseId] = useState('');
  const [filter, setFilter] = useState<Filter>('active');
  const [onlyTracked, setOnlyTracked] = useState(false);
  const [search, setSearch] = useState('');
  const [rows, setRows] = useState<Batch[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [detail, setDetail] = useState<Batch | null>(null);
  const [printing, setPrinting] = useState<Batch[] | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('rpt_stock_batches').select('*').order('expiry_date', { ascending: true, nullsFirst: false }).order('received_at').limit(1000);
    if (warehouseId) q = q.eq('warehouse_id', warehouseId);
    if (filter !== 'all') q = q.gt('qty_remaining', 0);
    setRows(await must(q));
  }, [warehouseId, filter]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const s = search.trim().toLowerCase();
  const shown = rows.filter((b) => {
    const d = daysLeft(b.expiry_date);
    return (!onlyTracked || b.track_batch)
      && (!s || b.item_name.toLowerCase().includes(s) || b.item_code.toLowerCase().includes(s) || b.batch_code.toLowerCase().includes(s) || (b.lot_number ?? '').toLowerCase().includes(s))
      && (filter !== 'near' || (d !== null && d >= 0 && d <= NEAR_EXPIRY_DAYS))
      && (filter !== 'expired' || (d !== null && d < 0));
  });

  const stats = useMemo(() => {
    const active = rows.filter((b) => Number(b.qty_remaining) > 0);
    const sum = (xs: Batch[]) => xs.reduce((t, b) => t + Number(b.stock_value), 0);
    const expired = active.filter((b) => (daysLeft(b.expiry_date) ?? 1) < 0);
    const near = active.filter((b) => { const d = daysLeft(b.expiry_date); return d !== null && d >= 0 && d <= NEAR_EXPIRY_DAYS; });
    return { expired: expired.length, expiredValue: sum(expired), near: near.length, nearValue: sum(near), value: sum(active) };
  }, [rows]);

  const onScan = async (code: string) => {
    try {
      const r = await resolveBarcode(code, warehouseId);
      if (r?.kind !== 'batch') return toast(r ? 'Bukan label batch' : `Kode ${code} tidak dikenal`, 'error');
      const b = (await must(supabase.from('rpt_stock_batches').select('*').eq('id', r.batch_id!).single())) as Batch;
      setDetail(b);
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const toggle = (id: string) => setSelected((x) => { const n = new Set(x); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  return (
    <>
      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <div className={`card stat-card stat-card-link ${filter === 'expired' ? 'active' : ''}`} role="button" tabIndex={0}
          style={{ '--stat-color': 'var(--danger)' } as React.CSSProperties}
          onClick={() => setFilter('expired')} onKeyDown={(e) => e.key === 'Enter' && setFilter('expired')}>
          <div className="stat-label">Sudah kedaluwarsa</div>
          <div className="stat-value" style={{ color: stats.expired ? 'var(--danger)' : undefined }}>{stats.expired} batch</div>
          <div className="muted small">{formatRupiah(stats.expiredValue)}{stats.expired ? ' · segera buat dokumen Waste' : ''}</div>
        </div>
        <div className={`card stat-card stat-card-link ${filter === 'near' ? 'active' : ''}`} role="button" tabIndex={0}
          style={{ '--stat-color': 'var(--warning)' } as React.CSSProperties}
          onClick={() => setFilter('near')} onKeyDown={(e) => e.key === 'Enter' && setFilter('near')}>
          <div className="stat-label">Kedaluwarsa ≤ {NEAR_EXPIRY_DAYS} hari</div>
          <div className="stat-value" style={{ color: stats.near ? 'var(--warning)' : undefined }}>{stats.near} batch</div>
          <div className="muted small">{formatRupiah(stats.nearValue)}{stats.near ? ' · pakai duluan' : ''}</div>
        </div>
        <div className="card stat-card">
          <div className="stat-label">Nilai stok (harga batch / FIFO)</div>
          <div className="stat-value">{formatRupiah(stats.value)}</div>
          <div className="muted small">{warehouseId ? warehouses.find((w) => w.id === warehouseId)?.name : 'Semua gudang'}</div>
        </div>
      </div>

      <div className="card table-wrap">
        <div className="filter-bar">
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            <option value="">Semua gudang</option>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
          <div className="choice-list">
            {([['active', 'Ada stok'], ['near', 'Hampir kedaluwarsa'], ['expired', 'Kedaluwarsa'], ['all', 'Semua (termasuk habis)']] as const).map(([k, v]) => (
              <button key={k} className={filter === k ? 'active' : ''} onClick={() => setFilter(k)}>{v}</button>
            ))}
          </div>
          <label className="switch"><input type="checkbox" checked={onlyTracked} onChange={(e) => setOnlyTracked(e.target.checked)} /><span>Hanya produk lacak batch</span></label>
        </div>
        <div className="filter-bar">
          <input type="search" placeholder="Cari produk / kode batch / lot…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ flex: '1 1 200px' }} />
          <ScanInput onScan={onScan} placeholder="Scan label batch" style={{ flex: '1 1 220px', maxWidth: 320 }} />
          <button disabled={!selected.size} onClick={() => setPrinting(rows.filter((b) => selected.has(b.id)))}><Printer size={16} /> Cetak label ({selected.size})</button>
        </div>
        <table className="table">
          <thead><tr>
            <th style={{ width: 28 }}><input type="checkbox" aria-label="Pilih semua" checked={!!shown.length && shown.every((b) => selected.has(b.id))}
              onChange={(e) => setSelected(e.target.checked ? new Set(shown.map((b) => b.id)) : new Set())} /></th>
            <th>Batch</th><th>Produk</th><th>Gudang</th><th>Kedaluwarsa</th><th className="right">Sisa / Masuk</th><th className="right">Harga</th><th className="right">Nilai</th>
          </tr></thead>
          <tbody>
            {shown.map((b) => {
              const [label, cls] = expiryInfo(b.expiry_date);
              return (
                <tr key={b.id} style={{ cursor: 'pointer', opacity: Number(b.qty_remaining) > 0 ? 1 : 0.55 }} onClick={() => setDetail(b)}>
                  <td onClick={(e) => e.stopPropagation()}><input type="checkbox" checked={selected.has(b.id)} onChange={() => toggle(b.id)} /></td>
                  <td><code className="bold">{b.batch_code}</code>{b.lot_number && <div className="muted small">Lot {b.lot_number}</div>}</td>
                  <td><b>{b.item_code}</b> · {b.item_name}<div className="muted small">Terima {formatDate(b.received_at)} · {b.reference_number ?? '-'}</div></td>
                  <td className="small">{b.warehouse_name}</td>
                  <td>{b.expiry_date ? <>{formatDate(b.expiry_date)}<div><span className={`badge ${cls}`}>{label}</span></div></> : <span className="muted small">-</span>}</td>
                  <td className="right">{formatNumber(b.qty_remaining)} / {formatNumber(b.qty_in)} {b.unit_code}</td>
                  <td className="right small">{formatRupiah(b.unit_cost)}/{b.unit_code}</td>
                  <td className="right">{formatRupiah(b.stock_value)}</td>
                </tr>
              );
            })}
            {!shown.length && <tr><td colSpan={8} className="empty">Tidak ada batch.</td></tr>}
          </tbody>
        </table>
      </div>

      {detail && <BatchDetail batch={detail} onClose={() => { setDetail(null); load(); }} onPrint={(b) => setPrinting([b])} />}
      {printing && (
        <LabelPrintModal title="Cetak Label Batch" onClose={() => { setPrinting(null); setSelected(new Set()); }}
          labels={printing.map((b) => batchLabel(b))} />
      )}
    </>
  );
}

interface Trace { id: string; seq: number; warehouse_name: string; movement_type: string; movement_at: string; reference_number: string | null; note: string | null; quantity: number; unit_cost: number; is_backfill: boolean }
const TYPE: Record<string, string> = {
  sales: 'Penjualan', purchase_receipt: 'Penerimaan', adjustment: 'Penyesuaian', waste: 'Waste', usage: 'Pemakaian', shrinkage: 'Penyusutan',
  production_in: 'Hasil produksi', production_out: 'Bahan produksi', sales_return: 'Retur penjualan', opname: 'Opname',
  transfer_in: 'Transfer masuk', transfer_out: 'Transfer keluar',
};

function BatchDetail({ batch, onClose, onPrint }: { batch: Batch; onClose: () => void; onPrint: (b: Batch) => void }) {
  const { toast } = useFeedback();
  const { can } = useAuth();
  const [trace, setTrace] = useState<Trace[]>([]);
  const [siblings, setSiblings] = useState<Batch[]>([]);
  const [lot, setLot] = useState(batch.lot_number ?? '');
  const [expiry, setExpiry] = useState(batch.expiry_date ?? '');
  const changed = lot !== (batch.lot_number ?? '') || expiry !== (batch.expiry_date ?? '');

  useEffect(() => {
    Promise.all([
      must(supabase.from('rpt_batch_movements').select('*').eq('batch_code', batch.batch_code).eq('item_id', batch.item_id).order('seq')),
      must(supabase.from('rpt_stock_batches').select('*').eq('batch_code', batch.batch_code).eq('item_id', batch.item_id)),
    ]).then(([t, s]) => { setTrace(t); setSiblings(s); }).catch((e) => toast(errorMessage(e), 'error'));
  }, [batch, toast]);

  const save = async () => {
    try {
      await rpc('inv_update_batch', { p_batch_id: batch.id, p_lot_number: lot, p_expiry_date: expiry || null });
      toast('Batch diperbarui');
      onClose();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <Modal title={`Batch ${batch.batch_code}`} onClose={onClose} large
      footer={<>
        <button onClick={() => onPrint(batch)} style={{ marginRight: 'auto' }}><Printer size={16} /> Cetak label</button>
        {can('inventory.manage') && <button className="btn-primary" disabled={!changed} onClick={save}>Simpan perubahan</button>}
        <button onClick={onClose}>Tutup</button>
      </>}>
      <div className="row" style={{ gap: 10, marginBottom: 12 }}>
        <b>{batch.item_code} · {batch.item_name}</b>
        <span className={`badge ${expiryInfo(batch.expiry_date)[1]}`}>{expiryInfo(batch.expiry_date)[0]}</span>
        <span className="muted small">Harga {formatRupiah(batch.unit_cost)}/{batch.unit_code} · masuk {formatDateTime(batch.received_at)}</span>
      </div>
      <div className="form-grid">
        <label className="field"><span>No. lot supplier</span><input value={lot} disabled={!can('inventory.manage')} onChange={(e) => setLot(e.target.value)} /></label>
        <label className="field"><span>Tanggal kedaluwarsa</span><input type="date" value={expiry} disabled={!can('inventory.manage')} onChange={(e) => setExpiry(e.target.value)} /></label>
      </div>

      <div className="section-title">Sisa per gudang</div>
      <div className="row" style={{ gap: 8 }}>
        {siblings.map((x) => <span key={x.id} className="badge">{x.warehouse_name}: {formatNumber(x.qty_remaining)} {x.unit_code}</span>)}
      </div>

      <div className="section-title"><History size={15} style={{ verticalAlign: -2 }} /> Jejak batch</div>
      <div className="table-wrap" style={{ maxHeight: '40vh', overflowY: 'auto' }}>
        <table className="table">
          <thead><tr><th>Waktu</th><th>Jenis</th><th>Gudang</th><th>Referensi</th><th className="right">Qty</th></tr></thead>
          <tbody>
            {batch.reference_type === 'opening' && (
              <tr><td className="small muted">-</td><td>Saldo awal</td><td className="small">{batch.warehouse_name}</td><td className="muted small">Saat fitur batch diaktifkan</td>
                <td className="right bold" style={{ color: 'var(--success)' }}>+{formatNumber(batch.qty_in)}</td></tr>
            )}
            {trace.map((t) => (
              <tr key={t.id}>
                <td className="small">{formatDateTime(t.movement_at)}</td>
                <td>{t.is_backfill ? 'Menutup stok minus' : TYPE[t.movement_type] ?? t.movement_type}</td>
                <td className="small">{t.warehouse_name}</td>
                <td className="small muted">{t.reference_number}{t.note ? ` · ${t.note}` : ''}</td>
                <td className="right bold" style={{ color: Number(t.quantity) < 0 ? 'var(--danger)' : 'var(--success)' }}>
                  {Number(t.quantity) > 0 ? '+' : ''}{formatNumber(t.quantity)} {batch.unit_code}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}
