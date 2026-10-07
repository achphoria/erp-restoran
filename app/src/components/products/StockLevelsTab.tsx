import { useCallback, useEffect, useMemo, useState } from 'react';
import { Copy, Save } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatNumber } from '../../lib/format';
import type { MasterData } from './types';

interface Row { item_id: string; code: string; name: string; unit: string; default_min: number; qty: number; min: string; max: string; dirty: boolean }

// Min / max stok per gudang (Branch Product). Kosong = pakai stok minimum default produk.
export default function StockLevelsTab(md: MasterData) {
  const { toast } = useFeedback();
  const [warehouseId, setWarehouseId] = useState(md.warehouses[0]?.id ?? '');
  const [rows, setRows] = useState<Row[]>([]);
  const [search, setSearch] = useState('');
  const [onlyLow, setOnlyLow] = useState(false);
  const [copying, setCopying] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!warehouseId) return;
    const [items, levels, stocks] = await Promise.all([
      must(supabase.from('inv_items').select('id, code, name, min_stock, base_unit_id, item_type').eq('is_active', true).eq('approval_status', 'approved').order('code')),
      must(supabase.from('inv_item_stock_levels').select('item_id, min_qty, max_qty').eq('warehouse_id', warehouseId)),
      must(supabase.from('inv_stocks').select('item_id, quantity').eq('warehouse_id', warehouseId)),
    ]);
    const unit = (id: string) => md.units.find((u) => u.id === id)?.code ?? '';
    setRows((items as { id: string; code: string; name: string; min_stock: number; base_unit_id: string }[]).map((i) => {
      const l = (levels as { item_id: string; min_qty: number; max_qty: number | null }[]).find((x) => x.item_id === i.id);
      return {
        item_id: i.id, code: i.code, name: i.name, unit: unit(i.base_unit_id), default_min: Number(i.min_stock),
        qty: Number((stocks as { item_id: string; quantity: number }[]).find((s) => s.item_id === i.id)?.quantity ?? 0),
        min: l ? String(Number(l.min_qty)) : '', max: l?.max_qty !== null && l?.max_qty !== undefined ? String(Number(l.max_qty)) : '', dirty: false,
      };
    }));
  }, [warehouseId, md.units]);

  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const update = (id: string, patch: Partial<Row>) => setRows((rs) => rs.map((r) => (r.item_id === id ? { ...r, ...patch, dirty: true } : r)));
  const effMin = (r: Row) => (r.min === '' ? r.default_min : Number(r.min));
  const s = search.trim().toLowerCase();
  const shown = useMemo(() => rows.filter((r) => (!s || r.code.toLowerCase().includes(s) || r.name.toLowerCase().includes(s)) && (!onlyLow || r.qty <= effMin(r))), [rows, s, onlyLow]);
  const dirty = rows.filter((r) => r.dirty);

  const save = async () => {
    const bad = dirty.find((r) => r.max !== '' && Number(r.max) < effMin(r));
    if (bad) return toast(`${bad.name}: maksimal tidak boleh lebih kecil dari minimal`, 'error');
    setBusy(true);
    try {
      const clear = dirty.filter((r) => r.min === '' && r.max === '').map((r) => r.item_id);
      if (clear.length) await must(supabase.from('inv_item_stock_levels').delete().eq('warehouse_id', warehouseId).in('item_id', clear));
      const upserts = dirty.filter((r) => r.min !== '' || r.max !== '');
      if (upserts.length) {
        await must(supabase.from('inv_item_stock_levels').upsert(upserts.map((r) => ({
          company_id: md.companyId, warehouse_id: warehouseId, item_id: r.item_id,
          min_qty: r.min === '' ? r.default_min : Number(r.min), max_qty: r.max === '' ? null : Number(r.max),
        })), { onConflict: 'warehouse_id,item_id' }));
      }
      toast(`${dirty.length} produk disimpan`);
      await load();
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="card">
        <div className="filter-bar">
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            {md.warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
          <input type="search" placeholder="Cari produk…" value={search} onChange={(e) => setSearch(e.target.value)} />
          <label className="row"><input type="checkbox" checked={onlyLow} onChange={(e) => setOnlyLow(e.target.checked)} /> Hanya di bawah minimal</label>
        </div>
        <div className="row">
          <button className="btn-primary" disabled={!dirty.length || busy} onClick={save}><Save size={16} /> Simpan {dirty.length ? `(${dirty.length})` : ''}</button>
          <button disabled={md.warehouses.length < 2} onClick={() => setCopying(true)}><Copy size={16} /> Salin ke gudang lain</button>
          <span className="muted small">Kosongkan minimal untuk memakai stok minimum default produk.</span>
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Produk</th><th className="right">Stok</th><th>Minimal</th><th>Maksimal</th><th>Status</th></tr></thead>
          <tbody>
            {shown.map((r) => {
              const low = r.qty <= effMin(r);
              return (
                <tr key={r.item_id} style={r.dirty ? { background: 'var(--warning-soft)' } : undefined}>
                  <td><b>{r.code}</b> · {r.name}</td>
                  <td className="right">{formatNumber(r.qty)} {r.unit}</td>
                  <td><input type="number" min={0} step="any" style={{ width: 110 }} placeholder={`${formatNumber(r.default_min)} (default)`} value={r.min} onChange={(e) => update(r.item_id, { min: e.target.value })} /></td>
                  <td><input type="number" min={0} step="any" style={{ width: 110 }} value={r.max} onChange={(e) => update(r.item_id, { max: e.target.value })} /></td>
                  <td>{low ? <span className="badge badge-danger">Perlu beli {r.max ? formatNumber(Math.max(Number(r.max) - r.qty, 0)) : ''}</span> : <span className="badge badge-success">Aman</span>}</td>
                </tr>
              );
            })}
            {!shown.length && <tr><td colSpan={5} className="empty">Tidak ada produk.</td></tr>}
          </tbody>
        </table>
      </div>
      {copying && <CopyLevels md={md} from={warehouseId} onClose={() => setCopying(false)} />}
    </>
  );
}

function CopyLevels({ md, from, onClose }: { md: MasterData; from: string; onClose: () => void }) {
  const { toast } = useFeedback();
  const [to, setTo] = useState(md.warehouses.find((w) => w.id !== from)?.id ?? '');
  const [overwrite, setOverwrite] = useState(false);
  const run = async () => {
    try {
      const n = await rpc<number>('inv_copy_stock_levels', { p_from_warehouse_id: from, p_to_warehouse_id: to, p_overwrite: overwrite });
      toast(`${n} pengaturan min/max disalin`);
      onClose();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };
  return (
    <Modal title="Salin Min/Max" onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={!to} onClick={run}>Salin</button></>}>
      <div className="grid">
        <div>Dari: <b>{md.warehouses.find((w) => w.id === from)?.name}</b></div>
        <label className="field"><span>Ke gudang</span>
          <select value={to} onChange={(e) => setTo(e.target.value)}>
            {md.warehouses.filter((w) => w.id !== from).map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
        <label className="row"><input type="checkbox" checked={overwrite} onChange={(e) => setOverwrite(e.target.checked)} /> Timpa pengaturan yang sudah ada di gudang tujuan</label>
      </div>
    </Modal>
  );
}
