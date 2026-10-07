import { useCallback, useEffect, useMemo, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah } from '../lib/format';
import ProductionTab from '../components/ProductionTab';
import StockDocuments from '../components/inventory/StockDocuments';
import PurposesTab from '../components/inventory/PurposesTab';

type Tab = 'stock' | 'production' | 'documents' | 'movements' | 'purposes';

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
          <p>Stok per gudang, produksi, penyesuaian, waste, pemakaian, penyusutan & opname. Data produk, resep & HPP ada di <b>Master Produk</b>.</p>
        </div>
      </div>
      <div className="tabs">
        {([['stock', 'Stok'], ['production', 'Produksi'], ['documents', 'Dokumen Stok'], ['movements', 'Kartu Stok'], ['purposes', 'Purpose & Akun']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      {tab === 'stock' && <StockTab {...ctx} />}
      {tab === 'production' && <ProductionTab warehouses={warehouses} />}
      {tab === 'documents' && <StockDocuments companyId={companyId} warehouses={warehouses} items={items} />}
      {tab === 'movements' && <MovementsTab {...ctx} />}
      {tab === 'purposes' && <PurposesTab companyId={companyId} />}
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
    sales: 'Penjualan', purchase_receipt: 'Pembelian', adjustment: 'Penyesuaian', waste: 'Waste', usage: 'Pemakaian', shrinkage: 'Penyusutan',
    production_in: 'Hasil Produksi', production_out: 'Bahan Produksi', sales_return: 'Retur Penjualan',
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
