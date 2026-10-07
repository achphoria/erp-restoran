import { useCallback, useEffect, useMemo, useState } from 'react';
import { Factory, Plus, Scissors, Trash2, X } from 'lucide-react';
import Modal from './Modal';
import { useFeedback } from './Feedback';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah, todayISO } from '../lib/format';

type BomType = 'assembly' | 'disassembly';
interface Warehouse { id: string; name: string; outlet_id?: string | null }
interface RecipeItem { id: string; item_id: string; quantity: number; waste_pct: number; weight_factor: number | null; inv_items: { code: string; name: string; inv_units: { code: string } } }
interface Recipe {
  id: string; recipe_type: BomType; code: string | null; name: string | null; yield_qty: number; item_id: string;
  inv_items: { code: string; name: string; base_unit_id: string; shelf_life_days: number | null; inv_units: { code: string } };
  inv_recipe_items: RecipeItem[];
}
interface ItemUnit { item_id: string; unit_id: string; conversion_qty: number; inv_units: { code: string } }
interface Production {
  id: string; production_number: string | null; production_date: string; quantity: number; result_qty: number | null; status: string; posted_at: string | null;
  inv_recipes: { recipe_type: BomType; code: string | null; name: string | null; inv_items: { name: string; inv_units: { code: string } } } | null;
  origin: { name: string } | null; dest: { name: string } | null; inv_units: { code: string } | null;
}

const STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge-warning'], pending_approval: ['Menunggu persetujuan', 'badge-warning'], posted: ['Diposting', 'badge-success'],
};
const TYPE_LABEL: Record<BomType, string> = { assembly: 'Assembly', disassembly: 'Disassembly' };
const addDays = (iso: string, n: number) => { const d = new Date(`${iso}T00:00:00`); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };

// Simple Manufacturing (ala ESB): assembly / disassembly dari BOM, lokasi asal & tujuan, qty aktual bisa diubah
export default function ProductionTab({ warehouses }: { warehouses: Warehouse[] }) {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Production[]>([]);
  const [status, setStatus] = useState('');
  const [creating, setCreating] = useState<BomType | null>(null);
  const [detail, setDetail] = useState<string | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('inv_productions')
      .select('*, inv_recipes(recipe_type, code, name, inv_items(name, inv_units(code))), origin:inv_warehouses!inv_productions_warehouse_id_fkey(name), dest:inv_warehouses!inv_productions_dest_warehouse_id_fkey(name), inv_units(code)')
      .order('created_at', { ascending: false }).limit(100);
    if (status) q = q.eq('status', status);
    setRows(await must(q));
  }, [status]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" onClick={() => setCreating('assembly')}><Plus size={16} /> Assembly</button>
          <button onClick={() => setCreating('disassembly')}><Scissors size={16} /> Disassembly</button>
          <div className="choice-list" style={{ marginLeft: 'auto' }}>
            {[['', 'Semua'], ...Object.entries(STATUS).map(([k, [v]]) => [k, v])].map(([k, v]) => (
              <button key={k} className={status === k ? 'active' : ''} onClick={() => setStatus(k)}>{v}</button>
            ))}
          </div>
        </div>
        <p className="muted small" style={{ marginBottom: 0 }}>BOM dibuat di Master Produk → Resep (BOM) dengan tipe Assembly / Disassembly. Qty bahan & hasil terisi dari BOM dan bisa diubah sesuai kenyataan (actual costing).</p>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Nomor</th><th>Tanggal</th><th>Tipe</th><th>BOM</th><th>Lokasi</th><th className="right">Qty</th><th>Status</th></tr></thead>
          <tbody>
            {rows.map((p) => {
              const [label, cls] = STATUS[p.status] ?? [p.status, 'badge'];
              return (
                <tr key={p.id} style={{ cursor: 'pointer' }} onClick={() => setDetail(p.id)}>
                  <td className="bold">{p.production_number ?? '(draft)'}</td>
                  <td>{p.posted_at ? formatDateTime(p.posted_at) : p.production_date}</td>
                  <td><span className={`badge ${p.inv_recipes?.recipe_type === 'disassembly' ? 'badge-info' : 'badge-primary'}`}>{TYPE_LABEL[p.inv_recipes?.recipe_type ?? 'assembly']}</span></td>
                  <td>{p.inv_recipes?.name ?? p.inv_recipes?.inv_items.name}<div className="muted small">{p.inv_recipes?.code}</div></td>
                  <td className="small">{p.origin?.name}{p.dest && p.dest.name !== p.origin?.name ? ` → ${p.dest.name}` : ''}</td>
                  <td className="right">{formatNumber(p.quantity)} {p.inv_units?.code ?? p.inv_recipes?.inv_items.inv_units.code}</td>
                  <td><span className={`badge ${cls}`}>{label}</span></td>
                </tr>
              );
            })}
            {!rows.length && <tr><td colSpan={7} className="empty"><Factory size={32} style={{ color: 'var(--fresh)' }} /><div>Belum ada produksi.</div></td></tr>}
          </tbody>
        </table>
      </div>
      {creating && <ManufacturingForm type={creating} warehouses={warehouses} onClose={() => setCreating(null)} onDone={() => { setCreating(null); load(); }} />}
      {detail && <ManufacturingDetail id={detail} onClose={() => { setDetail(null); load(); }} />}
    </>
  );
}

// ---------------------------------------------------------------- Form (1 dokumen, bisa beberapa BOM)
interface Line { item_id: string; code: string; name: string; unit: string; bom: number; system: number; actual: string; touched: boolean; wf: string }
interface Entry { key: number; recipe_id: string; unit_id: string; qty: string; result: string; resultTouched: boolean; expiry: string; notes: string; lines: Line[] }

function ManufacturingForm({ type, warehouses, onClose, onDone }: { type: BomType; warehouses: Warehouse[]; onClose: () => void; onDone: () => void }) {
  const { profile, outlet } = useAuth();
  const { toast } = useFeedback();
  const [recipes, setRecipes] = useState<Recipe[]>([]);
  const [itemUnits, setItemUnits] = useState<ItemUnit[]>([]);
  const [date, setDate] = useState(todayISO());
  const [outletId, setOutletId] = useState(outlet?.id ?? profile?.outlets[0]?.id ?? '');
  const whs = warehouses.filter((w) => !w.outlet_id || w.outlet_id === outletId);
  const [origin, setOrigin] = useState(whs[0]?.id ?? '');
  const [dest, setDest] = useState(whs[0]?.id ?? '');
  const [stock, setStock] = useState<Record<string, Record<string, number>>>({});
  const [entries, setEntries] = useState<Entry[]>([{ key: 1, recipe_id: '', unit_id: '', qty: '', result: '', resultTouched: false, expiry: '', notes: '', lines: [] }]);
  const [active, setActive] = useState(1);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    Promise.all([
      must(supabase.from('inv_recipes')
        .select('id, recipe_type, code, name, yield_qty, item_id, inv_items(code, name, base_unit_id, shelf_life_days, inv_units(code)), inv_recipe_items(id, item_id, quantity, waste_pct, weight_factor, inv_items(code, name, inv_units(code)))')
        .eq('recipe_type', type).eq('is_active', true).order('name')),
      must(supabase.from('inv_item_units').select('item_id, unit_id, conversion_qty, inv_units(code)')),
    ]).then(([r, u]) => { setRecipes(r); setItemUnits(u); }).catch((e) => toast(errorMessage(e), 'error'));
  }, [type, toast]);

  // stok di lokasi asal & tujuan
  useEffect(() => {
    const ids = [...new Set([origin, dest].filter(Boolean))];
    if (!ids.length) return;
    must(supabase.from('rpt_stock_balances').select('warehouse_id, item_id, quantity').in('warehouse_id', ids))
      .then((rows: { warehouse_id: string; item_id: string; quantity: number }[]) => {
        const m: Record<string, Record<string, number>> = {};
        for (const r of rows) (m[r.warehouse_id] ??= {})[r.item_id] = Number(r.quantity);
        setStock(m);
      }).catch(() => setStock({}));
  }, [origin, dest]);

  const units = (r?: Recipe) => r ? [{ unit_id: r.inv_items.base_unit_id, code: r.inv_items.inv_units.code, conv: 1 },
    ...itemUnits.filter((u) => u.item_id === r.item_id && u.unit_id !== r.inv_items.base_unit_id)
      .map((u) => ({ unit_id: u.unit_id, code: u.inv_units.code, conv: Number(u.conversion_qty) }))] : [];

  // hitung ulang baris dari BOM; qty yang sudah diubah user dipertahankan
  const recompute = (e: Entry): Entry => {
    const r = recipes.find((x) => x.id === e.recipe_id);
    if (!r) return { ...e, lines: [] };
    const conv = units(r).find((u) => u.unit_id === e.unit_id)?.conv ?? 1;
    const q = Number(e.qty || 0);
    const lines = r.inv_recipe_items.map((ri) => {
      const bom = (Number(ri.quantity) / Number(r.yield_qty)) * conv * (type === 'assembly' ? 1 + Number(ri.waste_pct) / 100 : 1);
      const prev = e.lines.find((l) => l.item_id === ri.item_id);
      const system = Math.round(bom * q * 10000) / 10000;
      return {
        item_id: ri.item_id, code: ri.inv_items.code, name: ri.inv_items.name, unit: ri.inv_items.inv_units.code, bom, system,
        actual: prev?.touched ? prev.actual : String(system), touched: !!prev?.touched,
        wf: prev?.wf ?? String(ri.weight_factor ?? 1),
      };
    });
    return { ...e, lines, result: e.resultTouched ? e.result : e.qty };
  };
  const update = (key: number, patch: Partial<Entry>) => setEntries((es) => es.map((e) => {
    if (e.key !== key) return e;
    let next = { ...e, ...patch };
    if (patch.recipe_id !== undefined) {
      const r = recipes.find((x) => x.id === patch.recipe_id);
      next = { ...next, unit_id: r?.inv_items.base_unit_id ?? '', lines: [], resultTouched: false,
        expiry: r?.inv_items.shelf_life_days ? addDays(date, r.inv_items.shelf_life_days) : '' };
    }
    return patch.recipe_id !== undefined || patch.unit_id !== undefined || patch.qty !== undefined ? recompute(next) : next;
  }));
  const setLine = (key: number, itemId: string, patch: Partial<Line>) => setEntries((es) => es.map((e) => e.key !== key ? e
    : { ...e, lines: e.lines.map((l) => (l.item_id === itemId ? { ...l, ...patch } : l)) }));

  const valid = entries.filter((e) => e.recipe_id && Number(e.qty) > 0);
  const cur = entries.find((e) => e.key === active) ?? entries[0];
  const curRecipe = recipes.find((r) => r.id === cur.recipe_id);

  const save = async (post: boolean) => {
    setBusy(true);
    const group = crypto.randomUUID();
    let pending = 0;
    try {
      const ids: string[] = [];
      for (const [i, e] of valid.entries()) {
        const r = recipes.find((x) => x.id === e.recipe_id)!;
        const conv = units(r).find((u) => u.unit_id === e.unit_id)?.conv ?? 1;
        const doc = (await must(supabase.from('inv_productions').insert({
          company_id: profile!.company_id, warehouse_id: origin, dest_warehouse_id: dest && dest !== origin ? dest : null, recipe_id: e.recipe_id,
          quantity: Number(e.qty), unit_id: e.unit_id || null, conversion_qty: conv, production_date: date, notes: e.notes.trim() || null,
          result_qty: type === 'assembly' ? Number(e.result || e.qty) : null, expiry_date: type === 'assembly' && e.expiry ? e.expiry : null,
          group_id: group, line_no: i + 1,
        }).select('id').single())) as { id: string };
        await must(supabase.from('inv_production_lines').insert(e.lines.map((l, j) => ({
          company_id: profile!.company_id, production_id: doc.id, line_type: type === 'assembly' ? 'material' : 'result', item_id: l.item_id,
          bom_qty: Math.round(l.bom * 10000) / 10000, system_qty: l.system, actual_qty: Math.max(0, Number(l.actual || 0)),
          weight_factor: type === 'disassembly' ? Number(l.wf || 1) : null, sort_order: j + 1,
        }))));
        ids.push(doc.id);
      }
      if (post) {
        for (const id of ids) {
          const r = await rpc<{ pending_approval?: boolean }>('inv_post_production', { p_id: id });
          if (r.pending_approval) pending++;
        }
      }
      toast(!post ? 'Draft tersimpan' : pending ? `${pending} produksi menunggu persetujuan` : `${ids.length} produksi diposting, stok sudah diperbarui`);
      onDone();
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  const stockOf = (wh: string, item: string) => stock[wh]?.[item] ?? 0;

  return (
    <Modal title={`Simple Manufacturing · ${TYPE_LABEL[type]}`} onClose={onClose} large
      footer={<>
        <span className="muted small" style={{ marginRight: 'auto' }}>{valid.length} BOM</span>
        <button disabled={busy || !valid.length || !origin} onClick={() => save(false)}>Simpan draft</button>
        <button className="btn-primary" disabled={busy || !valid.length || !origin} onClick={() => save(true)}>Simpan & posting</button>
      </>}>
      <div className="section-title" style={{ marginTop: 0 }}>Informasi</div>
      <div className="form-grid">
        <label className="field"><span>Tanggal</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>Branch</span>
          <select value={outletId} onChange={(e) => { setOutletId(e.target.value); const w = warehouses.find((x) => x.outlet_id === e.target.value); setOrigin(w?.id ?? ''); setDest(w?.id ?? ''); }}>
            {profile?.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select></label>
        <label className="field"><span>Lokasi asal (bahan)</span>
          <select value={origin} onChange={(e) => setOrigin(e.target.value)}>{whs.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
        <label className="field"><span>Lokasi tujuan (hasil)</span>
          <select value={dest} onChange={(e) => setDest(e.target.value)}>{whs.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
      </div>

      <div className="bom-tabs">
        {entries.map((e, i) => {
          const r = recipes.find((x) => x.id === e.recipe_id);
          return (
            <button key={e.key} type="button" className={e.key === cur.key ? 'active' : ''} onClick={() => setActive(e.key)}>
              {i + 1}. {r?.name ?? r?.inv_items.name ?? 'BOM baru'}
              {entries.length > 1 && <X size={13} onClick={(ev) => { ev.stopPropagation(); setEntries(entries.filter((x) => x.key !== e.key)); setActive(entries[0].key); }} />}
            </button>
          );
        })}
        <button type="button" className="add" onClick={() => { const k = Math.max(...entries.map((e) => e.key)) + 1;
          setEntries([...entries, { key: k, recipe_id: '', unit_id: '', qty: '', result: '', resultTouched: false, expiry: '', notes: '', lines: [] }]); setActive(k); }}>
          <Plus size={14} /> BOM</button>
      </div>

      <div className="form-grid">
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Bill of Material</span>
          <select value={cur.recipe_id} onChange={(e) => update(cur.key, { recipe_id: e.target.value })}>
            <option value="">— pilih BOM —</option>
            {recipes.map((r) => <option key={r.id} value={r.id}>{r.code ? `${r.code} · ` : ''}{r.name ?? r.inv_items.name}</option>)}
          </select></label>
        <label className="field"><span>{type === 'assembly' ? 'Manufacturing qty' : 'Qty dipotong'}</span>
          <div className="row" style={{ flexWrap: 'nowrap' }}>
            <input type="number" step="any" min={0} value={cur.qty} onChange={(e) => update(cur.key, { qty: e.target.value })} style={{ flex: 1 }} />
            <select value={cur.unit_id} onChange={(e) => update(cur.key, { unit_id: e.target.value })} disabled={!curRecipe}>
              {units(curRecipe).map((u) => <option key={u.unit_id} value={u.unit_id}>{u.code}{u.conv !== 1 ? ` (${formatNumber(u.conv)} ${curRecipe?.inv_items.inv_units.code})` : ''}</option>)}
            </select>
          </div></label>
        {type === 'assembly' && <>
          <label className="field"><span>Result qty (hasil aktual)</span>
            <input type="number" step="any" min={0} value={cur.result} onChange={(e) => update(cur.key, { result: e.target.value, resultTouched: true })} /></label>
          <label className="field"><span>Kedaluwarsa hasil</span><input type="date" value={cur.expiry} onChange={(e) => update(cur.key, { expiry: e.target.value })} /></label>
        </>}
        <label className="field"><span>Catatan</span><input value={cur.notes} onChange={(e) => update(cur.key, { notes: e.target.value })} /></label>
      </div>

      {curRecipe && (
        <>
          <div className="section-title">{type === 'assembly' ? 'Material' : 'Sumber'}</div>
          {type === 'disassembly' && (
            <div className="sum-row"><span><b>{curRecipe.inv_items.code}</b> · {curRecipe.inv_items.name}</span>
              <span>stok asal {formatNumber(stockOf(origin, curRecipe.item_id))} · keluar <b>{formatNumber(Number(cur.qty || 0) * (units(curRecipe).find((u) => u.unit_id === cur.unit_id)?.conv ?? 1))} {curRecipe.inv_items.inv_units.code}</b></span></div>
          )}
          {(type === 'assembly' || cur.lines.length > 0) && (
            <>
              {type === 'disassembly' && <div className="section-title">Hasil</div>}
              <div className="table-wrap">
                <table className="table">
                  <thead><tr><th>Produk</th><th>Satuan</th><th className="right">{type === 'assembly' ? 'Stok asal' : 'Stok tujuan'}</th><th className="right">Qty BOM</th>
                    <th className="right">Total by system</th><th>Total qty</th>{type === 'disassembly' && <th>Weight factor</th>}</tr></thead>
                  <tbody>
                    {cur.lines.map((l) => {
                      const st = stockOf(type === 'assembly' ? origin : dest, l.item_id);
                      const diff = Number(l.actual || 0) - l.system;
                      return (
                        <tr key={l.item_id}>
                          <td><b>{l.code}</b> · {l.name}</td>
                          <td>{l.unit}</td>
                          <td className="right" style={{ color: type === 'assembly' && st < Number(l.actual || 0) ? 'var(--danger)' : undefined }}>{formatNumber(st)}</td>
                          <td className="right">{formatNumber(Math.round(l.bom * 10000) / 10000)}</td>
                          <td className="right">{formatNumber(l.system)}</td>
                          <td><input type="number" step="any" min={0} style={{ width: 110 }} value={l.actual}
                            onChange={(e) => setLine(cur.key, l.item_id, { actual: e.target.value, touched: true })} />
                            {Math.abs(diff) > 0.0001 && <div className="small" style={{ color: diff > 0 ? 'var(--danger)' : 'var(--success)' }}>{diff > 0 ? '+' : ''}{formatNumber(diff)} vs BOM</div>}</td>
                          {type === 'disassembly' && <td><input type="number" step="any" min={0} style={{ width: 80 }} value={l.wf}
                            onChange={(e) => setLine(cur.key, l.item_id, { wf: e.target.value })} /></td>}
                        </tr>
                      );
                    })}
                    {!cur.lines.length && <tr><td colSpan={7} className="empty">Isi qty untuk menghitung kebutuhan bahan.</td></tr>}
                  </tbody>
                </table>
              </div>
            </>
          )}
          {type === 'assembly' && (
            <div className="sum-row" style={{ marginTop: 10 }}><span>Hasil: <b>{curRecipe.inv_items.code}</b> · {curRecipe.inv_items.name}</span>
              <span>stok tujuan {formatNumber(stockOf(dest, curRecipe.item_id))} · masuk <b>{formatNumber(Number(cur.result || 0))} {units(curRecipe).find((u) => u.unit_id === cur.unit_id)?.code}</b></span></div>
          )}
        </>
      )}
      <p className="muted small">HPP hasil = nilai bahan yang benar-benar terpakai (harga batch FIFO) + biaya tambahan BOM. {type === 'disassembly' && 'Nilai sumber dibagi ke hasil sesuai weight factor.'}</p>
    </Modal>
  );
}

// ---------------------------------------------------------------- Detail
interface Detail extends Production {
  unit_id: string | null; conversion_qty: number; expiry_date: string | null; notes: string | null; warehouse_id: string;
  inv_production_lines: { id: string; line_type: string; bom_qty: number; system_qty: number; actual_qty: number; weight_factor: number | null; sort_order: number;
    inv_items: { code: string; name: string; inv_units: { code: string } } }[];
}

function ManufacturingDetail({ id, onClose }: { id: string; onClose: () => void }) {
  const { toast, confirm } = useFeedback();
  const [d, setD] = useState<Detail | null>(null);
  const [value, setValue] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const x = await must(supabase.from('inv_productions')
      .select('*, inv_recipes(recipe_type, code, name, inv_items(name, inv_units(code))), origin:inv_warehouses!inv_productions_warehouse_id_fkey(name), dest:inv_warehouses!inv_productions_dest_warehouse_id_fkey(name), inv_units(code), inv_production_lines(id, line_type, bom_qty, system_qty, actual_qty, weight_factor, sort_order, inv_items(code, name, inv_units(code)))')
      .eq('id', id).single());
    setD(x);
    if (x.status === 'posted') {
      const mv = await must(supabase.from('inv_stock_movements').select('quantity, unit_cost').eq('reference_id', id).gt('quantity', 0));
      setValue(mv.reduce((t: number, m: { quantity: number; unit_cost: number }) => t + Number(m.quantity) * Number(m.unit_cost), 0));
    }
  }, [id]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const lines = useMemo(() => [...(d?.inv_production_lines ?? [])].sort((a, b) => a.sort_order - b.sort_order), [d]);
  if (!d) return <Modal title="Simple Manufacturing" onClose={onClose}><div className="empty">Memuat…</div></Modal>;
  const [label, cls] = STATUS[d.status] ?? [d.status, 'badge'];
  const type = d.inv_recipes?.recipe_type ?? 'assembly';
  const unit = d.inv_units?.code ?? d.inv_recipes?.inv_items.inv_units.code;

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try { await fn(); await load(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  return (
    <Modal title={`Simple Manufacturing ${d.production_number ?? '(draft)'}`} onClose={onClose} large
      footer={d.status === 'draft' ? <>
        <button className="btn-danger" style={{ marginRight: 'auto' }} disabled={busy} onClick={async () => {
          if (await confirm({ title: 'Hapus draft produksi?', danger: true, confirmLabel: 'Hapus' })) run(async () => { await must(supabase.from('inv_productions').delete().eq('id', d.id)); onClose(); });
        }}><Trash2 size={16} /> Hapus</button>
        <button className="btn-primary" disabled={busy} onClick={() => run(async () => {
          const r = await rpc<{ pending_approval?: boolean; production_number: string }>('inv_post_production', { p_id: d.id });
          toast(r.pending_approval ? 'Dikirim ke penyetuju' : `${r.production_number} diposting`);
        })}>Posting</button>
      </> : <button onClick={onClose}>Tutup</button>}>
      <div className="grid grid-4" style={{ marginBottom: 12 }}>
        <div><div className="stat-label">Tanggal</div><b>{d.production_date}</b></div>
        <div><div className="stat-label">Tipe BOM</div><b>{TYPE_LABEL[type]}</b></div>
        <div><div className="stat-label">Lokasi</div><b>{d.origin?.name}{d.dest ? ` → ${d.dest.name}` : ''}</b></div>
        <div><div className="stat-label">Status</div><span className={`badge ${cls}`}>{label}</span></div>
      </div>
      <div className="sum-row"><span>BOM: <b>{d.inv_recipes?.code ? `${d.inv_recipes.code} · ` : ''}{d.inv_recipes?.name}</b></span>
        <span>Manufacturing qty <b>{formatNumber(d.quantity)} {unit}</b>{type === 'assembly' && <> · hasil aktual <b>{formatNumber(d.result_qty ?? d.quantity)} {unit}</b></>}</span></div>
      {d.expiry_date && <div className="muted small">Kedaluwarsa hasil: {d.expiry_date}</div>}
      <div className="section-title">{type === 'assembly' ? 'Material' : 'Hasil'}</div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>Produk</th><th>Satuan</th><th className="right">Qty BOM</th><th className="right">Total by system</th><th className="right">Total qty</th><th className="right">Selisih</th>
            {type === 'disassembly' && <th className="right">Weight factor</th>}</tr></thead>
          <tbody>
            {lines.map((l) => {
              const diff = Number(l.actual_qty) - Number(l.system_qty);
              return (
                <tr key={l.id}>
                  <td><b>{l.inv_items.code}</b> · {l.inv_items.name}</td>
                  <td>{l.inv_items.inv_units.code}</td>
                  <td className="right">{formatNumber(l.bom_qty)}</td>
                  <td className="right">{formatNumber(l.system_qty)}</td>
                  <td className="right bold">{formatNumber(l.actual_qty)}</td>
                  <td className="right" style={{ color: diff > 0 ? 'var(--danger)' : diff < 0 ? 'var(--success)' : undefined }}>{diff ? `${diff > 0 ? '+' : ''}${formatNumber(diff)}` : '-'}</td>
                  {type === 'disassembly' && <td className="right">{formatNumber(l.weight_factor ?? 1)}</td>}
                </tr>
              );
            })}
            {!lines.length && <tr><td colSpan={7} className="empty">Baris dihitung dari BOM saat posting.</td></tr>}
          </tbody>
        </table>
      </div>
      {value !== null && <p className="small">Nilai hasil masuk stok: <b>{formatRupiah(value)}</b></p>}
      {d.notes && <p className="muted small">Catatan: {d.notes}</p>}
    </Modal>
  );
}
