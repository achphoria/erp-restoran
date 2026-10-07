import { useCallback, useEffect, useState } from 'react';
import { Plus, Star } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';

interface Wh { id: string; outlet_id: string | null; code: string; name: string; warehouse_type: string; address: string | null; notes: string | null; is_active: boolean }
interface Outlet { id: string; code: string; name: string; default_warehouse_id: string | null }

const WAREHOUSE_TYPES: Record<string, string> = {
  store: 'Gudang toko', central_kitchen: 'Central Kitchen', warehouse: 'Warehouse / Gudang pusat', bar: 'Bar', other: 'Lainnya',
};

// Lokasi penyimpanan per toko: 1 toko bisa punya beberapa gudang (mis. Central Kitchen + Warehouse)
export default function WarehousesTab({ companyId, onChanged }: { companyId: string; onChanged: () => void }) {
  const { toast } = useFeedback();
  const { can } = useAuth();
  const [rows, setRows] = useState<Wh[]>([]);
  const [outlets, setOutlets] = useState<Outlet[]>([]);
  const [editing, setEditing] = useState<Partial<Wh> | null>(null);

  const load = useCallback(async () => {
    const [w, o] = await Promise.all([
      must(supabase.from('inv_warehouses').select('*').order('code')),
      must(supabase.from('sys_outlets').select('id, code, name, default_warehouse_id').order('code')),
    ]);
    setRows(w); setOutlets(o);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const save = async () => {
    try {
      const e = editing!;
      const row = { company_id: companyId, outlet_id: e.outlet_id || null, code: e.code!.trim().toUpperCase(), name: e.name!.trim(),
        warehouse_type: e.warehouse_type ?? 'store', address: e.address?.trim() || null, notes: e.notes?.trim() || null, is_active: e.is_active ?? true };
      await must(e.id ? supabase.from('inv_warehouses').update(row).eq('id', e.id) : supabase.from('inv_warehouses').insert(row));
      toast('Gudang disimpan');
      setEditing(null);
      load(); onChanged();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Kode gudang sudah dipakai' : errorMessage(e), 'error');
    }
  };

  const setDefault = async (o: Outlet, whId: string) => {
    try {
      await must(supabase.from('sys_outlets').update({ default_warehouse_id: whId }).eq('id', o.id));
      toast(`Gudang POS ${o.name} diganti`);
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const groups: { key: string; title: string; outlet: Outlet | null; items: Wh[] }[] = [
    ...outlets.map((o) => ({ key: o.id, title: o.name, outlet: o, items: rows.filter((w) => w.outlet_id === o.id) })),
    { key: 'none', title: 'Tanpa outlet (gudang pusat)', outlet: null, items: rows.filter((w) => !w.outlet_id) },
  ].filter((g) => g.outlet || g.items.length);

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" onClick={() => setEditing({ warehouse_type: 'store', is_active: true, outlet_id: outlets[0]?.id ?? null })}><Plus size={16} /> Gudang / lokasi</button>
          <span className="muted small">Gudang bertanda ★ dipakai POS outlet untuk memotong stok penjualan. Pengiriman Sales Order bisa memilih gudang mana saja di outlet penjual.</span>
        </div>
      </div>
      <div className="grid grid-2">
        {groups.map((g) => (
          <div key={g.key} className="card">
            <div className="card-header"><h3>{g.title}</h3><span className="muted small">{g.items.length} lokasi</span></div>
            <table className="table">
              <tbody>
                {g.items.map((w) => {
                  const isDefault = g.outlet?.default_warehouse_id === w.id;
                  return (
                    <tr key={w.id} style={{ opacity: w.is_active ? 1 : 0.5 }}>
                      <td><b>{w.code}</b> · {w.name}{isDefault && <Star size={14} style={{ color: 'var(--sunshine, #F7B733)', verticalAlign: -2, marginLeft: 6 }} fill="currentColor" />}
                        <div className="muted small">{WAREHOUSE_TYPES[w.warehouse_type] ?? w.warehouse_type}{w.address ? ` · ${w.address}` : ''}</div></td>
                      <td className="right">
                        <div className="row" style={{ justifyContent: 'flex-end' }}>
                          {g.outlet && !isDefault && w.is_active && can('settings.manage') && (
                            <button className="btn-sm" onClick={() => setDefault(g.outlet!, w.id)}>Jadikan gudang POS</button>
                          )}
                          <button className="btn-sm" onClick={() => setEditing(w)}>Edit</button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
                {!g.items.length && <tr><td className="empty">Belum ada gudang.</td></tr>}
              </tbody>
            </table>
          </div>
        ))}
      </div>

      {editing && (
        <Modal title={editing.id ? 'Edit Gudang' : 'Gudang / Lokasi Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button>
            <button className="btn-primary" disabled={!editing.code?.trim() || !editing.name?.trim()} onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode *</span><input value={editing.code ?? ''} placeholder="mis. CK-SC" onChange={(e) => setEditing({ ...editing, code: e.target.value })} /></label>
            <label className="field"><span>Nama *</span><input value={editing.name ?? ''} placeholder="mis. Central Kitchen" onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            <label className="field"><span>Outlet / toko</span>
              <select value={editing.outlet_id ?? ''} onChange={(e) => setEditing({ ...editing, outlet_id: e.target.value || null })}>
                <option value="">Tanpa outlet (gudang pusat)</option>
                {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
              </select></label>
            <label className="field"><span>Jenis lokasi</span>
              <select value={editing.warehouse_type ?? 'store'} onChange={(e) => setEditing({ ...editing, warehouse_type: e.target.value })}>
                {Object.entries(WAREHOUSE_TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select></label>
            <label className="field"><span>Alamat</span><input value={editing.address ?? ''} onChange={(e) => setEditing({ ...editing, address: e.target.value })} /></label>
            <label className="field"><span>Catatan</span><input value={editing.notes ?? ''} onChange={(e) => setEditing({ ...editing, notes: e.target.value })} /></label>
          </div>
          <label className="switch" style={{ marginTop: 12 }}><input type="checkbox" checked={editing.is_active ?? true} onChange={(e) => setEditing({ ...editing, is_active: e.target.checked })} /><span>Aktif</span></label>
        </Modal>
      )}
    </>
  );
}
