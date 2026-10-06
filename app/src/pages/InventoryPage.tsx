import { useCallback, useEffect, useMemo, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah } from '../lib/format';
import Modal from '../components/Modal';

type Tab = 'stock' | 'items' | 'recipes' | 'documents' | 'movements';

interface Unit { id: string; code: string; name: string }
interface ItemCategory { id: string; name: string }
interface Warehouse { id: string; code: string; name: string }
interface InvItem {
  id: string; code: string; name: string; item_category_id: string | null; base_unit_id: string;
  min_stock: number; last_purchase_cost: number; is_active: boolean; inv_units?: { code: string };
}
interface StockBalance {
  warehouse_id: string; warehouse_name: string; item_id: string; item_code: string; item_name: string;
  unit_code: string; quantity: number; average_cost: number; stock_value: number; min_stock: number; is_low_stock: boolean;
}
interface FoodCost { menu_item_id: string; code: string; name: string; base_price: number; food_cost: number; food_cost_pct: number | null; has_recipe: boolean }

export default function InventoryPage() {
  const { profile } = useAuth();
  const companyId = profile!.company_id;
  const [tab, setTab] = useState<Tab>('stock');
  const [units, setUnits] = useState<Unit[]>([]);
  const [categories, setCategories] = useState<ItemCategory[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [items, setItems] = useState<InvItem[]>([]);
  const [error, setError] = useState('');

  const loadMaster = useCallback(async () => {
    try {
      const [u, c, w, i] = await Promise.all([
        must(supabase.from('inv_units').select('*').order('code')),
        must(supabase.from('inv_item_categories').select('*').order('name')),
        must(supabase.from('inv_warehouses').select('*').eq('is_active', true).order('code')),
        must(supabase.from('inv_items').select('*, inv_units(code)').order('code')),
      ]);
      setUnits(u as Unit[]);
      setCategories(c as ItemCategory[]);
      setWarehouses(w as Warehouse[]);
      setItems(i as InvItem[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);

  useEffect(() => {
    loadMaster();
  }, [loadMaster]);

  const ctx = { companyId, units, categories, warehouses, items, reload: loadMaster, setError };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Inventory</h1>
          <p>Stok bahan baku, resep & HPP, serta penyesuaian stok.</p>
        </div>
      </div>
      <div className="tabs">
        {([['stock', 'Stok'], ['items', 'Bahan Baku'], ['recipes', 'Resep & HPP'], ['documents', 'Penyesuaian / Opname / Transfer'], ['movements', 'Kartu Stok']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      {tab === 'stock' && <StockTab {...ctx} />}
      {tab === 'items' && <ItemsTab {...ctx} />}
      {tab === 'recipes' && <RecipesTab {...ctx} />}
      {tab === 'documents' && <DocumentsTab {...ctx} />}
      {tab === 'movements' && <MovementsTab {...ctx} />}
    </>
  );
}

interface Ctx {
  companyId: string;
  units: Unit[];
  categories: ItemCategory[];
  warehouses: Warehouse[];
  items: InvItem[];
  reload: () => Promise<void>;
  setError: (msg: string) => void;
}

// ---------------------------------------------------------------- Stok
function StockTab({ warehouses, setError }: Ctx) {
  const [warehouseId, setWarehouseId] = useState('');
  const [rows, setRows] = useState<StockBalance[]>([]);
  const [onlyLow, setOnlyLow] = useState(false);

  useEffect(() => {
    if (!warehouseId && warehouses[0]) setWarehouseId(warehouses[0].id);
  }, [warehouses, warehouseId]);

  useEffect(() => {
    if (!warehouseId) return;
    must(supabase.from('rpt_stock_balances').select('*').eq('warehouse_id', warehouseId).order('item_code'))
      .then((r) => setRows(r as StockBalance[]))
      .catch((e) => setError(errorMessage(e)));
  }, [warehouseId, setError]);

  const shown = rows.filter((r) => !onlyLow || r.is_low_stock);
  const totalValue = rows.reduce((s, r) => s + Number(r.stock_value), 0);

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <div className="row">
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
          <label className="row"><input type="checkbox" checked={onlyLow} onChange={(e) => setOnlyLow(e.target.checked)} /> Hanya stok menipis</label>
        </div>
        <div>Nilai stok: <b>{formatRupiah(totalValue)}</b></div>
      </div>
      <table className="table">
        <thead>
          <tr><th>Kode</th><th>Bahan</th><th className="right">Stok</th><th className="right">Min</th><th className="right">HPP Rata-rata</th><th className="right">Nilai</th><th></th></tr>
        </thead>
        <tbody>
          {shown.map((r) => (
            <tr key={r.item_id}>
              <td>{r.item_code}</td>
              <td className="bold">{r.item_name}</td>
              <td className="right">{formatNumber(r.quantity)} {r.unit_code}</td>
              <td className="right muted">{formatNumber(r.min_stock)}</td>
              <td className="right">{formatRupiah(r.average_cost)}/{r.unit_code}</td>
              <td className="right">{formatRupiah(r.stock_value)}</td>
              <td>{r.is_low_stock && <span className="badge badge-danger">Menipis</span>}</td>
            </tr>
          ))}
          {!shown.length && <tr><td colSpan={7} className="empty">Tidak ada data stok.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------- Bahan baku
function ItemsTab({ companyId, units, categories, items, reload, setError }: Ctx) {
  const [editing, setEditing] = useState<Partial<InvItem> | null>(null);

  const save = async () => {
    if (!editing) return;
    try {
      const { id, code, name, item_category_id, base_unit_id, min_stock, last_purchase_cost, is_active } = editing;
      const row = { company_id: companyId, code, name, item_category_id, base_unit_id, min_stock, last_purchase_cost, is_active };
      await must(id ? supabase.from('inv_items').update(row).eq('id', id) : supabase.from('inv_items').insert(row));
      setEditing(null);
      await reload();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>Bahan Baku</h2>
        <button className="btn-primary" onClick={() => setEditing({ base_unit_id: units[0]?.id, item_category_id: categories[0]?.id, min_stock: 0, last_purchase_cost: 0, is_active: true })}>
          + Bahan Baru
        </button>
      </div>
      <table className="table">
        <thead><tr><th>Kode</th><th>Nama</th><th>Kategori</th><th>Satuan</th><th className="right">Stok Min</th><th className="right">Harga Beli Terakhir</th><th></th></tr></thead>
        <tbody>
          {items.map((i) => (
            <tr key={i.id}>
              <td>{i.code}</td>
              <td className="bold">{i.name}</td>
              <td>{categories.find((c) => c.id === i.item_category_id)?.name}</td>
              <td>{i.inv_units?.code}</td>
              <td className="right">{formatNumber(i.min_stock)}</td>
              <td className="right">{formatRupiah(i.last_purchase_cost)}/{i.inv_units?.code}</td>
              <td className="right"><button className="btn-sm" onClick={() => setEditing(i)}>Edit</button></td>
            </tr>
          ))}
        </tbody>
      </table>

      {editing && (
        <Modal title={editing.id ? `Edit ${editing.name}` : 'Bahan Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button><button className="btn-primary" disabled={!editing.code || !editing.name} onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode</span><input value={editing.code ?? ''} onChange={(e) => setEditing({ ...editing, code: e.target.value })} /></label>
            <label className="field"><span>Nama</span><input value={editing.name ?? ''} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            <label className="field"><span>Kategori</span>
              <select value={editing.item_category_id ?? ''} onChange={(e) => setEditing({ ...editing, item_category_id: e.target.value })}>
                {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </label>
            <label className="field"><span>Satuan stok (terkecil)</span>
              <select value={editing.base_unit_id} disabled={!!editing.id} onChange={(e) => setEditing({ ...editing, base_unit_id: e.target.value })}>
                {units.map((u) => <option key={u.id} value={u.id}>{u.name} ({u.code})</option>)}
              </select>
            </label>
            <label className="field"><span>Stok minimum</span><input type="number" value={editing.min_stock ?? 0} onChange={(e) => setEditing({ ...editing, min_stock: Number(e.target.value) })} /></label>
            <label className="field"><span>Harga per satuan stok</span><input type="number" value={editing.last_purchase_cost ?? 0} onChange={(e) => setEditing({ ...editing, last_purchase_cost: Number(e.target.value) })} /></label>
          </div>
        </Modal>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Resep
function RecipesTab({ companyId, items, setError }: Ctx) {
  const [costs, setCosts] = useState<FoodCost[]>([]);
  const [selected, setSelected] = useState<FoodCost | null>(null);
  const [lines, setLines] = useState<{ id: string; item_id: string; quantity: number }[]>([]);
  const [recipeId, setRecipeId] = useState<string | null>(null);
  const [newItemId, setNewItemId] = useState('');
  const [newQty, setNewQty] = useState('');

  const loadCosts = useCallback(async () => {
    setCosts((await must(supabase.from('rpt_menu_food_costs').select('*').order('code'))) as FoodCost[]);
  }, []);

  const loadRecipe = useCallback(async (menuItemId: string) => {
    const recipe = (await must(supabase.from('inv_recipes').select('id, inv_recipe_items(id, item_id, quantity)').eq('menu_item_id', menuItemId).maybeSingle())) as
      { id: string; inv_recipe_items: { id: string; item_id: string; quantity: number }[] } | null;
    setRecipeId(recipe?.id ?? null);
    setLines(recipe?.inv_recipe_items ?? []);
  }, []);

  useEffect(() => {
    loadCosts().catch((e) => setError(errorMessage(e)));
  }, [loadCosts, setError]);

  const select = (fc: FoodCost) => {
    setSelected(fc);
    loadRecipe(fc.menu_item_id).catch((e) => setError(errorMessage(e)));
  };

  const run = async (fn: () => Promise<unknown>) => {
    try {
      await fn();
      if (selected) await loadRecipe(selected.menu_item_id);
      await loadCosts();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const addLine = () => run(async () => {
    let rid = recipeId;
    if (!rid) {
      rid = ((await must(supabase.from('inv_recipes').insert({ company_id: companyId, menu_item_id: selected!.menu_item_id }).select('id').single())) as { id: string }).id;
    }
    await must(supabase.from('inv_recipe_items').upsert(
      { company_id: companyId, recipe_id: rid, item_id: newItemId, quantity: Number(newQty) },
      { onConflict: 'recipe_id,item_id' },
    ));
    setNewItemId('');
    setNewQty('');
  });

  const itemById = (id: string) => items.find((i) => i.id === id);
  const current = costs.find((c) => c.menu_item_id === selected?.menu_item_id);

  return (
    <div className="grid grid-2">
      <div className="card table-wrap">
        <h2 style={{ marginBottom: 12 }}>HPP per Menu</h2>
        <table className="table">
          <thead><tr><th>Menu</th><th className="right">Harga</th><th className="right">HPP</th><th className="right">Food Cost</th></tr></thead>
          <tbody>
            {costs.map((c) => {
              const pct = Number(c.food_cost_pct ?? 0);
              return (
                <tr key={c.menu_item_id} onClick={() => select(c)} style={{ cursor: 'pointer', background: selected?.menu_item_id === c.menu_item_id ? 'var(--primary-soft)' : undefined }}>
                  <td className="bold">{c.name}</td>
                  <td className="right">{formatRupiah(c.base_price)}</td>
                  <td className="right">{c.has_recipe ? formatRupiah(c.food_cost) : <span className="badge badge-warning">Belum ada resep</span>}</td>
                  <td className="right">
                    {c.has_recipe && <span className={`badge ${pct > 40 ? 'badge-danger' : pct > 30 ? 'badge-warning' : 'badge-success'}`}>{pct}%</span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <p className="muted small">Food cost ideal restoran umumnya 25–35%. HPP dihitung dari harga beli terakhir.</p>
      </div>

      <div className="card">
        {!selected ? (
          <div className="empty">← Pilih menu untuk melihat / mengatur resepnya</div>
        ) : (
          <>
            <div className="card-header">
              <h2>Resep: {selected.name}</h2>
              {current && <span className="bold">HPP {formatRupiah(current.food_cost)}</span>}
            </div>
            <table className="table">
              <thead><tr><th>Bahan</th><th className="right">Takaran / porsi</th><th className="right">Biaya</th><th></th></tr></thead>
              <tbody>
                {lines.map((l) => {
                  const it = itemById(l.item_id);
                  return (
                    <tr key={l.id}>
                      <td>{it?.name}</td>
                      <td className="right">{formatNumber(l.quantity)} {it?.inv_units?.code}</td>
                      <td className="right">{formatRupiah(Number(l.quantity) * Number(it?.last_purchase_cost ?? 0))}</td>
                      <td className="right"><button className="btn-sm btn-danger" onClick={() => run(() => must(supabase.from('inv_recipe_items').delete().eq('id', l.id)))}>Hapus</button></td>
                    </tr>
                  );
                })}
                {!lines.length && <tr><td colSpan={4} className="empty">Belum ada bahan.</td></tr>}
              </tbody>
            </table>
            <div className="row" style={{ marginTop: 12 }}>
              <select value={newItemId} onChange={(e) => setNewItemId(e.target.value)} style={{ flex: 1 }}>
                <option value="">— pilih bahan —</option>
                {items.map((i) => <option key={i.id} value={i.id}>{i.name} ({i.inv_units?.code})</option>)}
              </select>
              <input type="number" placeholder="Qty" value={newQty} onChange={(e) => setNewQty(e.target.value)} style={{ width: 90 }} />
              <button className="btn-primary" disabled={!newItemId || !(Number(newQty) > 0)} onClick={addLine}>Tambah</button>
            </div>
            <p className="muted small">Stok bahan otomatis terpotong sesuai resep setiap menu terjual.</p>
          </>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Dokumen stok
type DocType = 'adjustment' | 'waste' | 'opname' | 'transfer';
const DOC_LABEL: Record<DocType, string> = {
  adjustment: 'Penyesuaian (+/−)', waste: 'Waste / Rusak', opname: 'Stock Opname (hitung fisik)', transfer: 'Transfer Gudang',
};

interface DocRow { id: string; type: DocType; number: string | null; date: string; status: string; note: string | null; posted_at: string | null }

function DocumentsTab({ companyId, warehouses, items, setError }: Ctx) {
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [creating, setCreating] = useState<DocType | null>(null);

  const load = useCallback(async () => {
    const [adj, opn, trf] = await Promise.all([
      must(supabase.from('inv_stock_adjustments').select('*').order('created_at', { ascending: false }).limit(30)),
      must(supabase.from('inv_stock_opnames').select('*').order('created_at', { ascending: false }).limit(30)),
      must(supabase.from('inv_stock_transfers').select('*').order('created_at', { ascending: false }).limit(30)),
    ]);
    type R = Record<string, string | null>;
    setDocs([
      ...(adj as R[]).map((d) => ({ id: d.id!, type: d.adjustment_type as DocType, number: d.adjustment_number, date: d.adjustment_date!, status: d.status!, note: d.note, posted_at: d.posted_at })),
      ...(opn as R[]).map((d) => ({ id: d.id!, type: 'opname' as DocType, number: d.opname_number, date: d.opname_date!, status: d.status!, note: d.note, posted_at: d.posted_at })),
      ...(trf as R[]).map((d) => ({ id: d.id!, type: 'transfer' as DocType, number: d.transfer_number, date: d.transfer_date!, status: d.status!, note: d.note, posted_at: d.posted_at })),
    ].sort((a, b) => (b.posted_at ?? '').localeCompare(a.posted_at ?? '')));
  }, []);

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
  }, [load, setError]);

  return (
    <>
      <div className="card">
        <div className="row">
          <span className="bold">Buat dokumen:</span>
          {(Object.keys(DOC_LABEL) as DocType[]).map((t) => (
            <button key={t} disabled={t === 'transfer' && warehouses.length < 2} onClick={() => setCreating(t)}>{DOC_LABEL[t]}</button>
          ))}
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Nomor</th><th>Jenis</th><th>Tanggal</th><th>Catatan</th><th>Status</th></tr></thead>
          <tbody>
            {docs.map((d) => (
              <tr key={d.id}>
                <td className="bold">{d.number ?? '(draft)'}</td>
                <td>{DOC_LABEL[d.type]}</td>
                <td>{d.posted_at ? formatDateTime(d.posted_at) : d.date}</td>
                <td className="muted">{d.note}</td>
                <td><span className={`badge ${d.status === 'posted' ? 'badge-success' : 'badge-warning'}`}>{({ posted: 'Diposting', draft: 'Draft', pending_approval: 'Menunggu persetujuan' } as Record<string, string>)[d.status] ?? d.status}</span></td>
              </tr>
            ))}
            {!docs.length && <tr><td colSpan={5} className="empty">Belum ada dokumen.</td></tr>}
          </tbody>
        </table>
      </div>
      {creating && (
        <StockDocumentForm type={creating} companyId={companyId} warehouses={warehouses} items={items}
          onClose={() => setCreating(null)}
          onDone={() => {
            setCreating(null);
            load().catch((e) => setError(errorMessage(e)));
          }} />
      )}
    </>
  );
}

function StockDocumentForm({ type, companyId, warehouses, items, onClose, onDone }: {
  type: DocType; companyId: string; warehouses: Warehouse[]; items: InvItem[]; onClose: () => void; onDone: () => void;
}) {
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? '');
  const [toWarehouseId, setToWarehouseId] = useState(warehouses[1]?.id ?? '');
  const [note, setNote] = useState('');
  const [lines, setLines] = useState<{ item_id: string; quantity: string }[]>([{ item_id: '', quantity: '' }]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const qtyLabel = { adjustment: 'Qty (+ tambah / − kurang)', waste: 'Qty terbuang', opname: 'Qty hasil hitung fisik', transfer: 'Qty dikirim' }[type];
  const validLines = lines.filter((l) => l.item_id && l.quantity !== '');

  const submit = async () => {
    setBusy(true);
    setError('');
    try {
      const qtyLines = validLines.map((l) => ({ company_id: companyId, item_id: l.item_id, quantity: Number(l.quantity) }));
      if (type === 'opname') {
        const doc = (await must(supabase.from('inv_stock_opnames').insert({ company_id: companyId, warehouse_id: warehouseId, note }).select('id').single())) as { id: string };
        await must(supabase.from('inv_stock_opname_items').insert(
          qtyLines.map(({ quantity, ...rest }) => ({ ...rest, stock_opname_id: doc.id, counted_qty: quantity }))));
        await rpc('inv_post_stock_opname', { p_id: doc.id });
      } else if (type === 'transfer') {
        const doc = (await must(supabase.from('inv_stock_transfers').insert({ company_id: companyId, from_warehouse_id: warehouseId, to_warehouse_id: toWarehouseId, note }).select('id').single())) as { id: string };
        await must(supabase.from('inv_stock_transfer_items').insert(qtyLines.map((l) => ({ ...l, stock_transfer_id: doc.id }))));
        await rpc('inv_post_stock_transfer', { p_id: doc.id });
      } else {
        const doc = (await must(supabase.from('inv_stock_adjustments').insert({ company_id: companyId, warehouse_id: warehouseId, adjustment_type: type, note }).select('id').single())) as { id: string };
        await must(supabase.from('inv_stock_adjustment_items').insert(qtyLines.map((l) => ({ ...l, stock_adjustment_id: doc.id }))));
        await rpc('inv_post_stock_adjustment', { p_id: doc.id });
      }
      onDone();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title={DOC_LABEL[type]} onClose={onClose} large
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !validLines.length} onClick={submit}>{busy ? 'Memproses…' : 'Simpan & Posting'}</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field"><span>{type === 'transfer' ? 'Dari gudang' : 'Gudang'}</span>
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
        </label>
        {type === 'transfer' && (
          <label className="field"><span>Ke gudang</span>
            <select value={toWarehouseId} onChange={(e) => setToWarehouseId(e.target.value)}>
              {warehouses.filter((w) => w.id !== warehouseId).map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
            </select>
          </label>
        )}
        <label className="field"><span>Catatan</span><input value={note} onChange={(e) => setNote(e.target.value)} /></label>
      </div>
      <table className="table" style={{ marginTop: 16 }}>
        <thead><tr><th>Bahan</th><th>{qtyLabel}</th><th></th></tr></thead>
        <tbody>
          {lines.map((l, idx) => (
            <tr key={idx}>
              <td>
                <select value={l.item_id} onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, item_id: e.target.value } : x))} style={{ width: '100%' }}>
                  <option value="">— pilih bahan —</option>
                  {items.map((i) => <option key={i.id} value={i.id}>{i.code} · {i.name} ({i.inv_units?.code})</option>)}
                </select>
              </td>
              <td><input type="number" value={l.quantity} onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, quantity: e.target.value } : x))} /></td>
              <td><button className="btn-sm btn-danger" onClick={() => setLines(lines.filter((_, i) => i !== idx))}>✕</button></td>
            </tr>
          ))}
        </tbody>
      </table>
      <button className="btn-sm" onClick={() => setLines([...lines, { item_id: '', quantity: '' }])}>+ Baris</button>
      {type === 'opname' && <p className="muted small">Sistem akan menghitung selisih dengan stok di sistem dan menyesuaikannya otomatis.</p>}
    </Modal>
  );
}

// ---------------------------------------------------------------- Kartu stok
interface Movement {
  id: string; movement_type: string; quantity: number; unit_cost: number | null; balance_after: number | null;
  reference_number: string | null; note: string | null; movement_at: string;
  inv_items: { name: string; inv_units: { code: string } }; inv_warehouses: { name: string };
}

function MovementsTab({ items, setError }: Ctx) {
  const [itemId, setItemId] = useState('');
  const [rows, setRows] = useState<Movement[]>([]);

  useEffect(() => {
    let q = supabase.from('inv_stock_movements')
      .select('*, inv_items(name, inv_units(code)), inv_warehouses(name)')
      .order('movement_at', { ascending: false }).limit(200);
    if (itemId) q = q.eq('item_id', itemId);
    must(q).then((r) => setRows(r as Movement[])).catch((e) => setError(errorMessage(e)));
  }, [itemId, setError]);

  const typeLabel = useMemo<Record<string, string>>(() => ({
    sales: 'Penjualan', purchase_receipt: 'Pembelian', adjustment: 'Penyesuaian', waste: 'Waste',
    opname: 'Opname', transfer_in: 'Transfer Masuk', transfer_out: 'Transfer Keluar',
  }), []);

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>Kartu Stok</h2>
        <select value={itemId} onChange={(e) => setItemId(e.target.value)}>
          <option value="">Semua bahan</option>
          {items.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
        </select>
      </div>
      <table className="table">
        <thead><tr><th>Waktu</th><th>Bahan</th><th>Gudang</th><th>Jenis</th><th>Referensi</th><th className="right">Qty</th><th className="right">Saldo</th></tr></thead>
        <tbody>
          {rows.map((m) => (
            <tr key={m.id}>
              <td>{formatDateTime(m.movement_at)}</td>
              <td>{m.inv_items.name}</td>
              <td className="muted">{m.inv_warehouses.name}</td>
              <td>{typeLabel[m.movement_type] ?? m.movement_type}</td>
              <td className="muted">{m.reference_number}</td>
              <td className="right bold" style={{ color: Number(m.quantity) < 0 ? 'var(--danger)' : 'var(--success)' }}>
                {Number(m.quantity) > 0 ? '+' : ''}{formatNumber(m.quantity)} {m.inv_items.inv_units.code}
              </td>
              <td className="right">{formatNumber(m.balance_after)}</td>
            </tr>
          ))}
          {!rows.length && <tr><td colSpan={7} className="empty">Belum ada pergerakan stok.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
