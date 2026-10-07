import { useEffect, useMemo, useState } from 'react';
import { Calculator, Plus, Save, Trash2 } from 'lucide-react';
import { useFeedback } from '../Feedback';
import MoneyInput from '../MoneyInput';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';
import type { MasterData } from './types';

interface ItemCost { item_id: string; code: string; name: string; unit_code: string; last_purchase_cost: number; average_cost: number }
interface Line { item_id: string; quantity: string; waste_pct: string }

// Simulasi: bahan + waste + biaya lain -> HPP -> harga jual (target food cost % atau markup %), lalu simpan jadi resep
export default function FoodCostCalculator(md: MasterData) {
  const { toast, confirm } = useFeedback();
  const [items, setItems] = useState<ItemCost[]>([]);
  const [menus, setMenus] = useState<{ id: string; code: string; name: string; base_price: number }[]>([]);
  const [lines, setLines] = useState<Line[]>([{ item_id: '', quantity: '', waste_pct: '0' }]);
  const [other, setOther] = useState('');
  const [source, setSource] = useState<'last' | 'average'>('last');
  const [mode, setMode] = useState<'foodcost' | 'markup'>('foodcost');
  const [target, setTarget] = useState('30');
  const [rounding, setRounding] = useState(500);
  const [menuId, setMenuId] = useState('');
  const [updatePrice, setUpdatePrice] = useState(true);

  useEffect(() => {
    Promise.all([
      must(supabase.from('rpt_item_costs').select('item_id, code, name, unit_code, last_purchase_cost, average_cost').order('name')),
      must(supabase.from('mst_menu_items').select('id, code, name, base_price').eq('is_active', true).order('name')),
    ]).then(([i, m]) => { setItems(i); setMenus(m); }).catch((e) => toast(errorMessage(e), 'error'));
  }, [toast]);

  const costOf = (id: string) => {
    const it = items.find((x) => x.item_id === id);
    return Number(source === 'last' ? it?.last_purchase_cost : it?.average_cost) || 0;
  };
  const material = useMemo(() => lines.reduce((s, l) => s + Number(l.quantity || 0) * (1 + Number(l.waste_pct || 0) / 100) * costOf(l.item_id), 0),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [lines, items, source]);
  const hpp = material + Number(other || 0);
  const t = Number(target) || 0;
  const rawPrice = mode === 'foodcost' ? (t > 0 ? hpp / (t / 100) : 0) : hpp * (1 + t / 100);
  const price = rounding > 1 ? Math.ceil(rawPrice / rounding) * rounding : Math.round(rawPrice);
  const foodCostPct = price ? (hpp / price) * 100 : 0;
  const menu = menus.find((m) => m.id === menuId);

  const saveAsRecipe = async () => {
    const valid = lines.filter((l) => l.item_id && Number(l.quantity) > 0);
    if (!menu || !valid.length) return;
    try {
      const existing = (await must(supabase.from('inv_recipes').select('id').eq('menu_item_id', menu.id).maybeSingle())) as { id: string } | null;
      if (existing && !(await confirm({ title: `Timpa resep ${menu.name}?`, message: 'Bahan resep lama akan diganti dengan hasil kalkulator.', danger: true, confirmLabel: 'Timpa' }))) return;
      const recipeId = existing?.id ?? ((await must(supabase.from('inv_recipes')
        .insert({ company_id: md.companyId, menu_item_id: menu.id, recipe_type: 'menu', name: menu.name, yield_qty: 1 }).select('id').single())) as { id: string }).id;
      await must(supabase.from('inv_recipe_items').delete().eq('recipe_id', recipeId));
      await must(supabase.from('inv_recipe_items').insert(valid.map((l) => ({
        company_id: md.companyId, recipe_id: recipeId, item_id: l.item_id, quantity: Number(l.quantity), waste_pct: Number(l.waste_pct || 0) }))));
      if (updatePrice && price > 0) await must(supabase.from('mst_menu_items').update({ base_price: price }).eq('id', menu.id));
      toast(`Resep ${menu.name} disimpan${updatePrice ? ` & harga jadi ${formatRupiah(price)}` : ''}`);
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <div className="grid" style={{ gridTemplateColumns: 'minmax(0, 3fr) minmax(280px, 2fr)' }}>
      <div className="card">
        <div className="card-header">
          <h2><Calculator size={18} style={{ verticalAlign: -3 }} /> Bahan per porsi</h2>
          <select value={source} onChange={(e) => setSource(e.target.value as 'last' | 'average')}>
            <option value="last">Harga beli terakhir</option><option value="average">HPP rata-rata stok</option>
          </select>
        </div>
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>Bahan</th><th>Qty</th><th>Waste %</th><th className="right">Biaya</th><th></th></tr></thead>
            <tbody>
              {lines.map((l, i) => {
                const it = items.find((x) => x.item_id === l.item_id);
                const upd = (patch: Partial<Line>) => setLines(lines.map((x, j) => (j === i ? { ...x, ...patch } : x)));
                return (
                  <tr key={i}>
                    <td><select style={{ width: '100%', minWidth: 160 }} value={l.item_id} onChange={(e) => upd({ item_id: e.target.value })}>
                      <option value="">— pilih bahan —</option>
                      {items.map((x) => <option key={x.item_id} value={x.item_id}>{x.name} ({formatRupiah(source === 'last' ? x.last_purchase_cost : x.average_cost)}/{x.unit_code})</option>)}
                    </select></td>
                    <td><div className="row" style={{ flexWrap: 'nowrap' }}><input type="number" step="any" min={0} style={{ width: 80 }} value={l.quantity} onChange={(e) => upd({ quantity: e.target.value })} /><span className="muted small">{it?.unit_code}</span></div></td>
                    <td><input type="number" step="any" min={0} max={100} style={{ width: 64 }} value={l.waste_pct} onChange={(e) => upd({ waste_pct: e.target.value })} /></td>
                    <td className="right">{formatRupiah(Number(l.quantity || 0) * (1 + Number(l.waste_pct || 0) / 100) * costOf(l.item_id))}</td>
                    <td><button className="icon-btn" onClick={() => setLines(lines.filter((_, j) => j !== i))} aria-label="Hapus"><Trash2 size={16} /></button></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <button className="btn-sm" onClick={() => setLines([...lines, { item_id: '', quantity: '', waste_pct: '0' }])}><Plus size={14} /> Bahan</button>
        <label className="field" style={{ marginTop: 14, maxWidth: 260 }}><span>Biaya lain per porsi (kemasan, gas…)</span><MoneyInput value={other} onChange={setOther} /></label>
      </div>

      <div className="card" style={{ alignSelf: 'start' }}>
        <h2 style={{ marginBottom: 12 }}>Hasil</h2>
        <div className="choice-list" style={{ marginBottom: 10 }}>
          <button className={mode === 'foodcost' ? 'active' : ''} onClick={() => { setMode('foodcost'); setTarget('30'); }}>Target food cost %</button>
          <button className={mode === 'markup' ? 'active' : ''} onClick={() => { setMode('markup'); setTarget('200'); }}>Markup %</button>
        </div>
        <div className="form-grid">
          <label className="field"><span>{mode === 'foodcost' ? 'Target food cost (%)' : 'Markup dari HPP (%)'}</span>
            <input type="number" min={0} step="any" value={target} onChange={(e) => setTarget(e.target.value)} /></label>
          <label className="field"><span>Bulatkan ke atas</span>
            <select value={rounding} onChange={(e) => setRounding(Number(e.target.value))}>
              {[1, 100, 500, 1000, 5000].map((v) => <option key={v} value={v}>{v === 1 ? 'Tidak' : formatRupiah(v)}</option>)}
            </select></label>
        </div>
        <div className="grid" style={{ gap: 6, marginTop: 12 }}>
          <div className="sum-row"><span>HPP per porsi</span><b>{formatRupiah(hpp)}</b></div>
          <div className="sum-row total"><span>Saran harga jual</span><span style={{ color: 'var(--accent)' }}>{formatRupiah(price)}</span></div>
          <div className="sum-row"><span>Food cost</span><span className={`badge ${foodCostPct > 40 ? 'badge-danger' : foodCostPct > 30 ? 'badge-warning' : 'badge-success'}`}>{foodCostPct.toFixed(1)}%</span></div>
          <div className="sum-row"><span>Laba kotor per porsi</span><b>{formatRupiah(price - hpp)}</b></div>
          <div className="muted small">Harga di atas sebelum pajak & service. Food cost ideal restoran umumnya 25–35%.</div>
        </div>
        <div className="section-title">Simpan sebagai resep menu</div>
        <div className="grid">
          <select value={menuId} onChange={(e) => setMenuId(e.target.value)}>
            <option value="">— pilih menu —</option>
            {menus.map((m) => <option key={m.id} value={m.id}>{m.code} · {m.name} ({formatRupiah(m.base_price)})</option>)}
          </select>
          <label className="row"><input type="checkbox" checked={updatePrice} onChange={(e) => setUpdatePrice(e.target.checked)} /> Ubah harga menu menjadi {formatRupiah(price)}</label>
          <button className="btn-primary" disabled={!menu || !lines.some((l) => l.item_id && Number(l.quantity) > 0)} onClick={saveAsRecipe}><Save size={16} /> Simpan resep</button>
        </div>
      </div>
    </div>
  );
}
