import { useCallback, useEffect, useMemo, useState } from 'react';
import { Lock, Plus, Trash2 } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useAuth } from '../../context/AuthContext';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatNumber, formatRupiah } from '../../lib/format';
import type { MasterData } from './types';

type RecipeType = 'menu' | 'assembly' | 'disassembly';
const RECIPE_TYPES: Record<RecipeType, { label: string; desc: string }> = {
  menu: { label: 'Menu', desc: 'Resep menu POS: bahan terpotong otomatis saat menu terjual' },
  assembly: { label: 'Assembly', desc: 'Produksi: beberapa bahan diolah menjadi 1 produk (mis. bumbu dasar, saus)' },
  disassembly: { label: 'Disassembly', desc: 'Pemotongan: 1 bahan dipecah menjadi beberapa hasil (mis. ayam utuh → dada & paha)' },
};

interface RecipeRow {
  id: string; recipe_type: RecipeType; code: string | null; name: string | null; menu_item_id: string | null; item_id: string | null;
  yield_qty: number; access_level: string; is_active: boolean; notes: string | null;
}
interface CostRow { recipe_id: string; material_cost: number; extra_cost: number }
interface Line { item_id: string; quantity: string; waste_pct: string; weight_factor: string }
interface ExtraCost { description: string; account_id: string; amount: string }
interface ItemOpt { id: string; code: string; name: string; base_unit_id: string; last_purchase_cost: number; item_type: string }
interface MenuOpt { id: string; code: string; name: string; base_price: number }

export default function RecipesTab(md: MasterData) {
  const { toast } = useFeedback();
  const [recipes, setRecipes] = useState<RecipeRow[]>([]);
  const [costs, setCosts] = useState<CostRow[]>([]);
  const [items, setItems] = useState<ItemOpt[]>([]);
  const [menus, setMenus] = useState<MenuOpt[]>([]);
  const [type, setType] = useState<'' | RecipeType>('');
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState<Partial<RecipeRow> | null>(null);

  const load = useCallback(async () => {
    const [r, c, i, m] = await Promise.all([
      must(supabase.from('inv_recipes').select('*').order('recipe_type').order('code')),
      must(supabase.from('rpt_recipe_costs').select('recipe_id, material_cost, extra_cost')),
      must(supabase.from('inv_items').select('id, code, name, base_unit_id, last_purchase_cost, item_type').eq('is_active', true).eq('approval_status', 'approved').order('name')),
      must(supabase.from('mst_menu_items').select('id, code, name, base_price').order('name')),
    ]);
    setRecipes(r); setCosts(c); setItems(i); setMenus(m);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const outputName = (r: RecipeRow) => r.menu_item_id ? menus.find((m) => m.id === r.menu_item_id)?.name : items.find((i) => i.id === r.item_id)?.name;
  const s = search.trim().toLowerCase();
  const shown = recipes.filter((r) => (!type || r.recipe_type === type)
    && (!s || `${r.code} ${r.name} ${outputName(r)}`.toLowerCase().includes(s)));

  // menu yang belum punya resep, agar mudah dibuatkan
  const menusWithout = menus.filter((m) => !recipes.some((r) => r.menu_item_id === m.id));

  return (
    <>
      <div className="card">
        <div className="filter-bar">
          <input type="search" placeholder="Cari resep / menu / produk…" value={search} onChange={(e) => setSearch(e.target.value)} />
          <select value={type} onChange={(e) => setType(e.target.value as RecipeType | '')}>
            <option value="">Semua tipe</option>
            {Object.entries(RECIPE_TYPES).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
          </select>
        </div>
        <div className="row">
          {(Object.keys(RECIPE_TYPES) as RecipeType[]).map((t) => (
            <button key={t} className={t === 'menu' ? 'btn-primary' : ''} onClick={() => setEditing({ recipe_type: t, yield_qty: 1, access_level: 'general', is_active: true })}>
              <Plus size={16} /> BOM {RECIPE_TYPES[t].label}
            </button>
          ))}
          {menusWithout.length > 0 && <span className="badge badge-warning">{menusWithout.length} menu belum punya resep</span>}
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Kode / Nama</th><th>Tipe</th><th>Hasil</th><th className="right">Yield</th><th className="right">Biaya / unit</th><th>Status</th></tr></thead>
          <tbody>
            {shown.map((r) => {
              const c = costs.find((x) => x.recipe_id === r.id);
              return (
                <tr key={r.id} onClick={() => setEditing(r)} style={{ cursor: 'pointer' }}>
                  <td><b>{r.code ?? '—'}</b> {r.name && <span className="muted">· {r.name}</span>} {r.access_level === 'restricted' && <Lock size={13} style={{ verticalAlign: -2 }} />}</td>
                  <td><span className="badge badge-info">{RECIPE_TYPES[r.recipe_type].label}</span></td>
                  <td>{outputName(r) ?? '—'}</td>
                  <td className="right">{formatNumber(r.yield_qty)}</td>
                  <td className="right">{r.recipe_type === 'disassembly' ? '—' : formatRupiah(Number(c?.material_cost ?? 0) + Number(c?.extra_cost ?? 0))}</td>
                  <td>{r.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
                </tr>
              );
            })}
            {!shown.length && <tr><td colSpan={6} className="empty">Belum ada resep.</td></tr>}
          </tbody>
        </table>
      </div>
      {editing && (
        <RecipeForm md={md} recipe={editing} items={items} menus={menus} recipes={recipes}
          onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load(); }} />
      )}
    </>
  );
}

// ---------------------------------------------------------------- Form BOM
function RecipeForm({ md, recipe, items, menus, recipes, onClose, onSaved }: {
  md: MasterData; recipe: Partial<RecipeRow>; items: ItemOpt[]; menus: MenuOpt[]; recipes: RecipeRow[];
  onClose: () => void; onSaved: () => void;
}) {
  const { can } = useAuth();
  const { toast, confirm } = useFeedback();
  const [r, setR] = useState<Partial<RecipeRow>>(recipe);
  const [lines, setLines] = useState<Line[]>([]);
  const [extras, setExtras] = useState<ExtraCost[]>([]);
  const [access, setAccess] = useState<string[]>([]);
  const [users, setUsers] = useState<{ id: string; full_name: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const t = r.recipe_type as RecipeType;
  const set = (patch: Partial<RecipeRow>) => setR((x) => ({ ...x, ...patch }));

  useEffect(() => {
    if (recipe.id) {
      Promise.all([
        must(supabase.from('inv_recipe_items').select('item_id, quantity, waste_pct, weight_factor').eq('recipe_id', recipe.id)),
        must(supabase.from('inv_recipe_costs').select('description, account_id, amount').eq('recipe_id', recipe.id)),
        must(supabase.from('inv_recipe_access').select('user_id').eq('recipe_id', recipe.id)).catch(() => []),
      ]).then(([l, c, a]) => {
        setLines((l as { item_id: string; quantity: number; waste_pct: number; weight_factor: number | null }[]).map((x) => ({
          item_id: x.item_id, quantity: String(Number(x.quantity)), waste_pct: String(Number(x.waste_pct)), weight_factor: x.weight_factor ? String(Number(x.weight_factor)) : '' })));
        setExtras((c as { description: string; account_id: string; amount: number }[]).map((x) => ({ ...x, amount: String(Number(x.amount)) })));
        setAccess((a as { user_id: string }[]).map((x) => x.user_id));
      }).catch((e) => toast(errorMessage(e), 'error'));
    }
    rpc<{ id: string; full_name: string }[]>('sys_list_users').then(setUsers).catch(() => setUsers([]));
  }, [recipe.id, toast]);

  const item = (id: string) => items.find((i) => i.id === id);
  const unit = (id?: string) => md.units.find((u) => u.id === id)?.code ?? '';
  const output = t === 'menu' ? undefined : item(r.item_id ?? '');
  const yieldQty = Number(r.yield_qty) || 1;

  const material = useMemo(() => t === 'disassembly' ? 0 : lines.reduce((s, l) =>
    s + Number(l.quantity || 0) * (1 + Number(l.waste_pct || 0) / 100) * Number(item(l.item_id)?.last_purchase_cost ?? 0), 0),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [lines, t, items]);
  const extraTotal = extras.reduce((s, e) => s + Number(e.amount || 0), 0);
  const perUnit = (material + extraTotal) / yieldQty;
  const menuPrice = Number(menus.find((m) => m.id === r.menu_item_id)?.base_price ?? 0);
  const expenseAccounts = md.accounts.filter((a) => !a.is_header && ['expense', 'cogs'].includes(a.account_type));

  const save = async () => {
    setBusy(true);
    try {
      const row = {
        company_id: md.companyId, recipe_type: t, code: r.code?.trim() || null, name: r.name?.trim() || null,
        menu_item_id: t === 'menu' ? r.menu_item_id : null, item_id: t === 'menu' ? null : r.item_id,
        yield_qty: yieldQty, access_level: r.access_level, is_active: !!r.is_active, notes: r.notes?.trim() || null,
      };
      const saved = (await must(r.id
        ? supabase.from('inv_recipes').update(row).eq('id', r.id).select('id').single()
        : supabase.from('inv_recipes').insert(row).select('id').single())) as { id: string };

      await must(supabase.from('inv_recipe_items').delete().eq('recipe_id', saved.id));
      const valid = lines.filter((l) => l.item_id && Number(l.quantity) > 0);
      if (valid.length) {
        await must(supabase.from('inv_recipe_items').insert(valid.map((l) => ({
          company_id: md.companyId, recipe_id: saved.id, item_id: l.item_id, quantity: Number(l.quantity),
          waste_pct: Number(l.waste_pct || 0), weight_factor: t === 'disassembly' && l.weight_factor ? Number(l.weight_factor) : null,
        }))));
      }
      await must(supabase.from('inv_recipe_costs').delete().eq('recipe_id', saved.id));
      const validExtras = extras.filter((e) => e.description.trim() && e.account_id && Number(e.amount) > 0);
      if (validExtras.length) {
        await must(supabase.from('inv_recipe_costs').insert(validExtras.map((e) => ({
          company_id: md.companyId, recipe_id: saved.id, description: e.description.trim(), account_id: e.account_id, amount: Number(e.amount) }))));
      }
      if (row.access_level === 'restricted') {
        await must(supabase.from('inv_recipe_access').delete().eq('recipe_id', saved.id));
        if (access.length) await must(supabase.from('inv_recipe_access').insert(access.map((u) => ({ recipe_id: saved.id, user_id: u, company_id: md.companyId }))));
      }
      toast('Resep disimpan');
      onSaved();
    } catch (e) {
      toast(/duplicate key.*code/i.test(errorMessage(e)) ? 'Kode BOM sudah dipakai'
        : /uq_inv_recipes_item_type|menu_item_id_key/.test(errorMessage(e)) ? 'Hasil ini sudah punya BOM dengan tipe yang sama' : errorMessage(e), 'error');
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!(await confirm({ title: 'Hapus resep ini?', danger: true, confirmLabel: 'Hapus' }))) return;
    try {
      await must(supabase.from('inv_recipes').delete().eq('id', r.id!));
      toast('Resep dihapus', 'info');
      onSaved();
    } catch {
      toast('Resep sudah dipakai di produksi. Nonaktifkan saja.', 'error');
    }
  };

  const outputs = t === 'menu'
    ? menus.filter((m) => m.id === r.menu_item_id || !recipes.some((x) => x.menu_item_id === m.id))
    : items.filter((i) => i.id === r.item_id || !recipes.some((x) => x.item_id === i.id && x.recipe_type === t));
  const valid = (t === 'menu' ? r.menu_item_id : r.item_id) && yieldQty > 0;

  return (
    <Modal title={`${r.id ? 'Edit' : 'Buat'} BOM ${RECIPE_TYPES[t].label}`} onClose={onClose} large
      footer={<>
        {r.id && <button className="btn-danger" style={{ marginRight: 'auto' }} onClick={remove}><Trash2 size={16} /> Hapus</button>}
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || !valid} onClick={save}>{busy ? 'Menyimpan…' : 'Simpan'}</button>
      </>}>
      <p className="muted small" style={{ marginTop: 0 }}>{RECIPE_TYPES[t].desc}</p>
      <div className="form-grid">
        <label className="field"><span>Kode BOM</span><input value={r.code ?? ''} onChange={(e) => set({ code: e.target.value.toUpperCase() })} placeholder="BOM-001" /></label>
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Nama BOM</span><input value={r.name ?? ''} onChange={(e) => set({ name: e.target.value })} /></label>
        <label className="field"><span>{t === 'menu' ? 'Menu *' : t === 'assembly' ? 'Produk hasil *' : 'Bahan sumber *'}</span>
          <select value={(t === 'menu' ? r.menu_item_id : r.item_id) ?? ''} disabled={!!r.id}
            onChange={(e) => set(t === 'menu' ? { menu_item_id: e.target.value } : { item_id: e.target.value })}>
            <option value="">— pilih —</option>
            {outputs.map((o) => <option key={o.id} value={o.id}>{o.code} · {o.name}</option>)}
          </select></label>
        <label className="field"><span>{t === 'disassembly' ? 'Per jumlah sumber' : 'Hasil (yield)'} {output && `(${unit(output.base_unit_id)})`}</span>
          <input type="number" step="any" min={0} value={r.yield_qty ?? 1} onChange={(e) => set({ yield_qty: Number(e.target.value) })} /></label>
        <label className="switch" style={{ alignSelf: 'end' }}><input type="checkbox" checked={!!r.is_active} onChange={(e) => set({ is_active: e.target.checked })} /><span>Aktif</span></label>
      </div>

      <div className="section-title">{t === 'disassembly' ? 'Hasil potongan' : 'Bahan'}</div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>{t === 'disassembly' ? 'Produk hasil' : 'Bahan'}</th><th>Qty</th>{t !== 'disassembly' && <th>Waste %</th>}{t === 'disassembly' && <th>Bobot</th>}<th className="right">Biaya</th><th></th></tr></thead>
          <tbody>
            {lines.map((l, i) => {
              const it = item(l.item_id);
              const cost = Number(l.quantity || 0) * (1 + Number(l.waste_pct || 0) / 100) * Number(it?.last_purchase_cost ?? 0);
              const upd = (patch: Partial<Line>) => setLines(lines.map((x, j) => (j === i ? { ...x, ...patch } : x)));
              return (
                <tr key={i}>
                  <td><select value={l.item_id} style={{ width: '100%', minWidth: 180 }} onChange={(e) => upd({ item_id: e.target.value })}>
                    <option value="">— pilih —</option>
                    {items.filter((x) => x.id !== r.item_id).map((x) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}
                  </select></td>
                  <td><div className="row" style={{ flexWrap: 'nowrap' }}><input type="number" step="any" min={0} style={{ width: 90 }} value={l.quantity} onChange={(e) => upd({ quantity: e.target.value })} /><span className="muted small">{unit(it?.base_unit_id)}</span></div></td>
                  {t !== 'disassembly' && <td><input type="number" min={0} max={100} step="any" style={{ width: 70 }} value={l.waste_pct} onChange={(e) => upd({ waste_pct: e.target.value })} /></td>}
                  {t === 'disassembly' && <td><input type="number" min={0} step="any" style={{ width: 70 }} placeholder="1" value={l.weight_factor} onChange={(e) => upd({ weight_factor: e.target.value })} /></td>}
                  <td className="right">{t === 'disassembly' ? '—' : formatRupiah(cost)}</td>
                  <td><button className="icon-btn" onClick={() => setLines(lines.filter((_, j) => j !== i))} aria-label="Hapus"><Trash2 size={16} /></button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <button className="btn-sm" onClick={() => setLines([...lines, { item_id: '', quantity: '', waste_pct: '0', weight_factor: '' }])}><Plus size={14} /> Baris</button>
      {t === 'disassembly' && <p className="muted small">Nilai bahan sumber dibagi ke tiap hasil sesuai bobot (mis. dada bobot 2, paha bobot 1 → dada menanggung 2/3 biaya).</p>}

      <div className="section-title">Biaya tambahan</div>
      {extras.map((e, i) => {
        const upd = (patch: Partial<ExtraCost>) => setExtras(extras.map((x, j) => (j === i ? { ...x, ...patch } : x)));
        return (
          <div key={i} className="row" style={{ marginBottom: 6 }}>
            <input style={{ flex: 2, minWidth: 140 }} placeholder="Keterangan (gas, tenaga kerja…)" value={e.description} onChange={(ev) => upd({ description: ev.target.value })} />
            <select style={{ flex: 2, minWidth: 160 }} value={e.account_id} onChange={(ev) => upd({ account_id: ev.target.value })}>
              <option value="">— akun —</option>
              {expenseAccounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
            </select>
            <MoneyInput value={e.amount} onChange={(v) => upd({ amount: v })} className="flex-1" />
            <button className="icon-btn" onClick={() => setExtras(extras.filter((_, j) => j !== i))} aria-label="Hapus"><Trash2 size={16} /></button>
          </div>
        );
      })}
      <button className="btn-sm" onClick={() => setExtras([...extras, { description: '', account_id: '', amount: '' }])}><Plus size={14} /> Biaya</button>

      {t !== 'disassembly' && (
        <div className="card" style={{ marginTop: 16, background: 'var(--surface-2)', boxShadow: 'none' }}>
          <div className="sum-row"><span>Bahan (+waste)</span><span>{formatRupiah(material)}</span></div>
          <div className="sum-row"><span>Biaya tambahan</span><span>{formatRupiah(extraTotal)}</span></div>
          <div className="sum-row total"><span>HPP per {t === 'menu' ? 'porsi' : unit(output?.base_unit_id) || 'unit'}</span><span>{formatRupiah(perUnit)}</span></div>
          {t === 'menu' && menuPrice > 0 && (
            <div className="sum-row"><span>Harga jual {formatRupiah(menuPrice)} → food cost</span>
              <span className={`badge ${perUnit / menuPrice > 0.4 ? 'badge-danger' : perUnit / menuPrice > 0.3 ? 'badge-warning' : 'badge-success'}`}>{((perUnit / menuPrice) * 100).toFixed(1)}%</span></div>
          )}
        </div>
      )}

      <div className="section-title">Akses resep</div>
      <div className="row">
        <label className="row"><input type="radio" checked={r.access_level === 'general'} onChange={() => set({ access_level: 'general' })} /> Umum (semua yang punya akses inventory)</label>
        <label className="row"><input type="radio" checked={r.access_level === 'restricted'} onChange={() => set({ access_level: 'restricted' })} /> <Lock size={14} /> Rahasia</label>
      </div>
      {r.access_level === 'restricted' && (
        users.length ? (
          <div className="choice-list" style={{ marginTop: 8 }}>
            {users.map((u) => (
              <button key={u.id} className={access.includes(u.id) ? 'active' : ''}
                onClick={() => setAccess(access.includes(u.id) ? access.filter((x) => x !== u.id) : [...access, u.id])}>{u.full_name}</button>
            ))}
          </div>
        ) : <p className="muted small">{can('user.manage') ? 'Belum ada user lain.' : 'Hanya pengelola user yang bisa memilih siapa yang boleh melihat.'} Owner selalu bisa melihat.</p>
      )}
    </Modal>
  );
}
