import { useCallback, useEffect, useState } from 'react';
import { Factory, Plus } from 'lucide-react';
import Modal from './Modal';
import { useFeedback } from './Feedback';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, todayISO } from '../lib/format';

interface Warehouse { id: string; name: string }
interface Recipe {
  id: string; recipe_type: 'assembly' | 'disassembly'; code: string | null; name: string | null; yield_qty: number; item_id: string;
  inv_items: { name: string; inv_units: { code: string } } | null;
  inv_recipe_items: { item_id: string; quantity: number; waste_pct: number; inv_items: { name: string; inv_units: { code: string } } }[];
}
interface Production {
  id: string; production_number: string | null; production_date: string; quantity: number; status: string; notes: string | null; posted_at: string | null;
  inv_recipes: { recipe_type: string; name: string | null; inv_items: { name: string; inv_units: { code: string } } | null } | null;
  inv_warehouses: { name: string } | null;
}

// Produksi bahan setengah jadi (assembly) & pemotongan (disassembly) — fondasi central kitchen
export default function ProductionTab({ warehouses }: { warehouses: Warehouse[] }) {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Production[]>([]);
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    setRows(await must(supabase.from('inv_productions')
      .select('*, inv_recipes(recipe_type, name, inv_items(name, inv_units(code))), inv_warehouses(name)')
      .order('created_at', { ascending: false }).limit(50)));
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" onClick={() => setCreating(true)}><Plus size={16} /> Produksi Baru</button>
          <span className="muted small">Resep produksi dibuat di Master Produk → Resep (BOM) dengan tipe Assembly / Disassembly.</span>
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Nomor</th><th>Tanggal</th><th>Resep</th><th>Gudang</th><th className="right">Jumlah</th><th>Status</th></tr></thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.id}>
                <td className="bold">{p.production_number ?? '(draft)'}</td>
                <td>{p.posted_at ? formatDateTime(p.posted_at) : p.production_date}</td>
                <td>{p.inv_recipes?.name ?? p.inv_recipes?.inv_items?.name} <span className="badge">{p.inv_recipes?.recipe_type === 'disassembly' ? 'Pemotongan' : 'Produksi'}</span></td>
                <td>{p.inv_warehouses?.name}</td>
                <td className="right">{formatNumber(p.quantity)} {p.inv_recipes?.inv_items?.inv_units.code}</td>
                <td><span className={`badge ${p.status === 'posted' ? 'badge-success' : 'badge-warning'}`}>{p.status === 'posted' ? 'Diposting' : 'Draft'}</span></td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={6} className="empty"><Factory size={32} style={{ color: 'var(--fresh)' }} /><div>Belum ada produksi.</div></td></tr>}
          </tbody>
        </table>
      </div>
      {creating && <ProductionForm warehouses={warehouses} onClose={() => setCreating(false)} onDone={() => { setCreating(false); load(); }} />}
    </>
  );
}

function ProductionForm({ warehouses, onClose, onDone }: { warehouses: Warehouse[]; onClose: () => void; onDone: () => void }) {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [recipes, setRecipes] = useState<Recipe[]>([]);
  const [recipeId, setRecipeId] = useState('');
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? '');
  const [qty, setQty] = useState('');
  const [date, setDate] = useState(todayISO());
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    must(supabase.from('inv_recipes')
      .select('id, recipe_type, code, name, yield_qty, item_id, inv_items(name, inv_units(code)), inv_recipe_items(item_id, quantity, waste_pct, inv_items(name, inv_units(code)))')
      .in('recipe_type', ['assembly', 'disassembly']).eq('is_active', true).order('name'))
      .then(setRecipes).catch((e) => toast(errorMessage(e), 'error'));
  }, [toast]);

  const r = recipes.find((x) => x.id === recipeId);
  const factor = r ? Number(qty || 0) / Number(r.yield_qty) : 0;

  const post = async () => {
    setBusy(true);
    try {
      const doc = (await must(supabase.from('inv_productions').insert({
        company_id: profile!.company_id, warehouse_id: warehouseId, recipe_id: recipeId, quantity: Number(qty), production_date: date, notes: notes || null,
      }).select('id').single())) as { id: string };
      const res = await rpc<{ production_number: string }>('inv_post_production', { p_id: doc.id });
      toast(`Produksi ${res.production_number} diposting, stok sudah diperbarui`);
      onDone();
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <Modal title="Produksi Baru" onClose={onClose} large
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !r || !(Number(qty) > 0) || !warehouseId} onClick={post}>{busy ? 'Memproses…' : 'Posting Produksi'}</button></>}>
      <div className="form-grid">
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Resep (BOM)</span>
          <select value={recipeId} onChange={(e) => setRecipeId(e.target.value)}>
            <option value="">— pilih resep —</option>
            {recipes.map((x) => <option key={x.id} value={x.id}>{x.recipe_type === 'disassembly' ? '✂ ' : ''}{x.code ? `${x.code} · ` : ''}{x.name ?? x.inv_items?.name}</option>)}
          </select></label>
        <label className="field"><span>Gudang</span>
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
        <label className="field"><span>{r?.recipe_type === 'disassembly' ? 'Jumlah bahan dipotong' : 'Jumlah hasil'} {r && `(${r.inv_items?.inv_units.code})`}</span>
          <input type="number" step="any" min={0} value={qty} onChange={(e) => setQty(e.target.value)} /></label>
        <label className="field"><span>Tanggal</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>Catatan</span><input value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
      </div>
      {r && factor > 0 && (
        <div className="grid grid-2" style={{ marginTop: 16 }}>
          <div className="card" style={{ background: 'var(--danger-soft)', boxShadow: 'none' }}>
            <div className="bold" style={{ marginBottom: 6 }}>Keluar dari stok</div>
            {r.recipe_type === 'assembly'
              ? r.inv_recipe_items.map((i) => (
                <div key={i.item_id} className="sum-row"><span>{i.inv_items.name}</span><span>{formatNumber(i.quantity * factor * (1 + i.waste_pct / 100))} {i.inv_items.inv_units.code}</span></div>))
              : <div className="sum-row"><span>{r.inv_items?.name}</span><span>{formatNumber(Number(qty))} {r.inv_items?.inv_units.code}</span></div>}
          </div>
          <div className="card" style={{ background: 'var(--success-soft)', boxShadow: 'none' }}>
            <div className="bold" style={{ marginBottom: 6 }}>Masuk ke stok</div>
            {r.recipe_type === 'assembly'
              ? <div className="sum-row"><span>{r.inv_items?.name}</span><span>{formatNumber(Number(qty))} {r.inv_items?.inv_units.code}</span></div>
              : r.inv_recipe_items.map((i) => (
                <div key={i.item_id} className="sum-row"><span>{i.inv_items.name}</span><span>{formatNumber(i.quantity * factor)} {i.inv_items.inv_units.code}</span></div>))}
          </div>
        </div>
      )}
      <p className="muted small">HPP hasil = nilai bahan (HPP rata-rata) + biaya tambahan di resep. Jurnal persediaan dibuat otomatis.</p>
    </Modal>
  );
}
