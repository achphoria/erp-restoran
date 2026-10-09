import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { useFeedback, useNotice } from '../components/Feedback';
import { errorMessage, formatDateTime, formatNumber, formatRupiah, todayISO } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import ScanInput from '../components/ScanInput';
import BranchBillsTab from '../components/purchasing/BranchBillsTab';
import { resolveBarcode } from '../components/inventory/batchUtils';
import Modal from '../components/Modal';
import MoneyInput from '../components/MoneyInput';
import PricelistTab from '../components/PricelistTab';
import LabelPrintModal from '../components/inventory/LabelPrintModal';
import { batchLabel } from '../components/inventory/batchUtils';
import type { LabelData } from '../lib/barcode';

type Tab = 'po' | 'receipts' | 'bills' | 'pricelist' | 'suppliers';
const TABS: Tab[] = ['po', 'receipts', 'bills', 'pricelist', 'suppliers'];

interface Supplier {
  id: string; code: string; name: string; contact_name: string | null; phone: string | null; payment_term_days: number;
  supplier_type: 'external' | 'internal' | 'intercompany'; linked_outlet_id: string | null; sys_outlets?: { name: string } | null;
}
interface Warehouse { id: string; name: string; outlet_id: string | null }
interface Item { id: string; code: string; name: string; base_unit_id: string; last_purchase_cost: number; inv_units: { code: string } }
interface ItemUnit { item_id: string; unit_id: string; conversion_qty: number; is_purchase_unit: boolean; inv_units: { code: string } }
interface PurchaseOrder {
  id: string; po_number: string | null; po_date: string; status: string; grand_total: number; note: string | null; sales_note: string | null;
  pur_suppliers: { name: string; supplier_type: string }; inv_warehouses: { name: string };
  pur_purchase_order_items: { id: string; quantity: number; received_qty: number; unit_price: number; inv_items: { name: string }; inv_units: { code: string } }[];
  expected_date?: string | null; approved_at?: string | null;
}
interface GoodsReceipt {
  id: string; receipt_number: string | null; receipt_date: string; status: string; grand_total: number; posted_at: string | null;
  supplier_invoice_number: string | null; delivery_id: string | null;
  pur_suppliers: { name: string }; pur_purchase_orders: { po_number: string } | null; sal_deliveries: { delivery_number: string } | null;
}

const PO_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge'],
  pending_approval: ['Menunggu Persetujuan', 'badge-warning'],
  approved: ['Disetujui', 'badge-info'],
  partially_received: ['Diterima Sebagian', 'badge-warning'],
  received: ['Selesai', 'badge-success'],
  cancelled: ['Batal', 'badge-danger'],
};

export default function PurchasingPage() {
  const { profile, can } = useAuth();
  const companyId = profile!.company_id;
  const [tab, setTab] = useTabParam<Tab>('po', TABS);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [items, setItems] = useState<Item[]>([]);
  const [itemUnits, setItemUnits] = useState<ItemUnit[]>([]);
  const [orders, setOrders] = useState<PurchaseOrder[]>([]);
  const [receipts, setReceipts] = useState<GoodsReceipt[]>([]);
  const [creatingPo, setCreatingPo] = useState(false);
  const [poDetail, setPoDetail] = useState<string | null>(null);
  const [poSearch, setPoSearch] = useState('');
  const [poStatus, setPoStatus] = useState('');
  const [receivingId, setReceivingId] = useState<string | null>(null);
  const [editingSupplier, setEditingSupplier] = useState<Partial<Supplier> | null>(null);
  const [error, setError] = useState('');
  const setNotice = useNotice();
  const { confirm, toast } = useFeedback();

  const load = useCallback(async () => {
    try {
      const [s, w, i, iu, po, gr] = await Promise.all([
        must(supabase.from('pur_suppliers').select('*, sys_outlets(name)').eq('is_active', true).order('supplier_type').order('code')),
        must(supabase.from('inv_warehouses').select('id, name, outlet_id').eq('is_active', true).order('code')),
        must(supabase.from('inv_items').select('id, code, name, base_unit_id, last_purchase_cost, inv_units(code)').eq('is_active', true).eq('is_purchasable', true).eq('approval_status', 'approved').order('name')),
        must(supabase.from('inv_item_units').select('item_id, unit_id, conversion_qty, is_purchase_unit, inv_units(code)')),
        must(supabase.from('pur_purchase_orders')
          .select('*, pur_suppliers(name, supplier_type), inv_warehouses(name), pur_purchase_order_items(id, quantity, received_qty, unit_price, inv_items(name), inv_units(code))')
          .order('created_at', { ascending: false }).limit(50)),
        must(supabase.from('pur_goods_receipts')
          .select('*, pur_suppliers(name), pur_purchase_orders(po_number), sal_deliveries!pur_goods_receipts_delivery_id_fkey(delivery_number)')
          .order('created_at', { ascending: false }).limit(50)),
      ]);
      setSuppliers(s as Supplier[]);
      setWarehouses(w as Warehouse[]);
      setItems(i as unknown as Item[]);
      setItemUnits(iu as unknown as ItemUnit[]);
      setOrders(po as unknown as PurchaseOrder[]);
      setReceipts(gr as unknown as GoodsReceipt[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (fn: () => Promise<string | void>) => {
    setError('');
    setNotice('');
    try {
      const msg = await fn();
      if (msg) setNotice(msg);
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  // tombol aksi sesuai status (dipakai di daftar & halaman detail)
  const poActions = (po: PurchaseOrder, onDone?: () => void) => (
    <>
      {(po.status === 'draft' || (po.status === 'pending_approval' && can('approval.purchase_order'))) && (
        <button className="btn-sm btn-primary" onClick={() => act(async () => {
          const r = await rpc<{ po_number: string; pending_approval?: boolean }>('pur_approve_purchase_order', { p_id: po.id });
          onDone?.();
          return r.pending_approval ? 'PO dikirim ke atasan untuk disetujui.' : `PO ${r.po_number} disetujui.`;
        })}>Setujui</button>
      )}
      {po.status === 'draft' && (
        <button className="btn-sm btn-danger" onClick={async () => {
          if (await confirm({ title: 'Hapus draft PO ini?', danger: true, confirmLabel: 'Hapus' })) {
            act(() => must(supabase.from('pur_purchase_orders').delete().eq('id', po.id)).then(() => { onDone?.(); return 'Draft dihapus.'; }));
          }
        }}>Hapus</button>
      )}
      {['approved', 'partially_received'].includes(po.status) && po.pur_suppliers.supplier_type === 'external' && (
        <button className="btn-sm btn-success" onClick={() => { onDone?.(); startReceiving(po.id); }}>Terima</button>
      )}
    </>
  );

  const startReceiving = (poId: string) =>
    act(async () => {
      setReceivingId(await rpc<string>('pur_create_goods_receipt_from_po', { p_po_id: poId }));
    });

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Pembelian</h1>
          <p>Purchase Order ke supplier pihak ke-3 atau cabang internal, penerimaan barang, dan tagihan antar cabang.</p>
        </div>
        {tab === 'po' && <button className="btn-primary" onClick={() => setCreatingPo(true)}>+ Purchase Order</button>}
        {tab === 'suppliers' && <button className="btn-primary" onClick={() => setEditingSupplier({ payment_term_days: 0 })}>+ Supplier</button>}
      </div>
      <div className="tabs">
        {([['po', 'Purchase Order'], ['receipts', 'Penerimaan Barang'], ['bills', 'Tagihan Cabang'], ['pricelist', 'Pricelist Beli'], ['suppliers', 'Supplier']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      {tab === 'po' && (() => {
        const q = poSearch.trim().toLowerCase();
        const shown = orders.filter((po) => (!poStatus || po.status === poStatus)
          && (!q || (po.po_number ?? '').toLowerCase().includes(q) || po.pur_suppliers.name.toLowerCase().includes(q)));
        return (
          <div className="card table-wrap">
            <div className="filter-bar">
              <input type="search" placeholder="Cari no. PO / supplier…" value={poSearch} onChange={(e) => setPoSearch(e.target.value)} style={{ flex: '1 1 220px', maxWidth: 320 }} />
              <select value={poStatus} onChange={(e) => setPoStatus(e.target.value)}>
                <option value="">Semua status</option>
                {Object.entries(PO_STATUS).map(([k, [v]]) => <option key={k} value={k}>{v}</option>)}
              </select>
            </div>
            <table className="table">
              <thead><tr><th>No. PO</th><th>Tanggal</th><th>Supplier</th><th>Gudang</th><th>Item</th><th>Diterima</th><th>Status</th><th className="right">Total</th><th></th></tr></thead>
              <tbody>
                {shown.map((po) => {
                  const [label, badge] = PO_STATUS[po.status] ?? [po.status, 'badge'];
                  const qty = po.pur_purchase_order_items.reduce((t, i) => t + Number(i.quantity), 0);
                  const rec = po.pur_purchase_order_items.reduce((t, i) => t + Math.min(Number(i.received_qty), Number(i.quantity)), 0);
                  const pct = qty ? Math.round((rec / qty) * 100) : 0;
                  return (
                    <tr key={po.id} className="clickable-row" onClick={() => setPoDetail(po.id)}>
                      <td className="bold nowrap">{po.po_number ?? '(draft)'}</td>
                      <td className="nowrap">{po.po_date}</td>
                      <td>{po.pur_suppliers.name}{po.pur_suppliers.supplier_type === 'internal' && <span className="badge badge-primary" style={{ marginLeft: 6 }}>Cabang</span>}{po.pur_suppliers.supplier_type === 'intercompany' && <span className="badge badge-info" style={{ marginLeft: 6 }}>Antar-PT</span>}</td>
                      <td className="small">{po.inv_warehouses.name}</td>
                      <td className="nowrap">{po.pur_purchase_order_items.length} item</td>
                      <td style={{ minWidth: 110 }}>
                        <div className="progress" title={`${pct}% diterima`}><div style={{ width: `${pct}%` }} /></div>
                        <span className="muted small">{pct}%</span>
                      </td>
                      <td><span className={`badge ${badge}`} title={po.sales_note ?? ''}>{label}</span></td>
                      <td className="right nowrap">{formatRupiah(po.status === 'draft'
                        ? po.pur_purchase_order_items.reduce((t, i) => t + i.quantity * i.unit_price, 0)
                        : po.grand_total)}</td>
                      <td className="right" onClick={(e) => e.stopPropagation()}>
                        <div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                          <button className="btn-sm" onClick={() => setPoDetail(po.id)}>Detail</button>
                          {poActions(po)}
                        </div>
                      </td>
                    </tr>
                  );
                })}
                {!shown.length && <tr><td colSpan={9} className="empty">Belum ada purchase order.</td></tr>}
              </tbody>
            </table>
          </div>
        );
      })()}

      {tab === 'receipts' && (
        <div className="card table-wrap">
          <div className="filter-bar">
            <ScanInput placeholder="Scan label koli kiriman cabang" style={{ flex: '1 1 260px', maxWidth: 380 }} onScan={async (code) => {
              try {
                const r = await resolveBarcode(code);
                if (r?.kind !== 'delivery_package' || !r.goods_receipt_id) return toast(r ? 'Bukan label koli kiriman cabang' : `Kode ${code} tidak dikenal`, 'error');
                setReceivingId(r.goods_receipt_id);
              } catch (e) { toast(errorMessage(e), 'error'); }
            }} />
            <span className="muted small">Kiriman dari cabang otomatis muncul sebagai draft penerimaan.</span>
          </div>
          <table className="table">
            <thead><tr><th>No. Penerimaan</th><th>Waktu</th><th>Supplier</th><th>No. PO</th><th>No. Faktur</th><th>Status</th><th className="right">Total</th><th></th></tr></thead>
            <tbody>
              {receipts.map((gr) => (
                <tr key={gr.id}>
                  <td className="bold">{gr.receipt_number ?? '(draft)'}</td>
                  <td>{gr.posted_at ? formatDateTime(gr.posted_at) : gr.receipt_date}</td>
                  <td>{gr.pur_suppliers.name}{gr.sal_deliveries && <div className="muted small">Kiriman {gr.sal_deliveries.delivery_number}</div>}</td>
                  <td>{gr.pur_purchase_orders?.po_number ?? '-'}</td>
                  <td>{gr.supplier_invoice_number ?? '-'}</td>
                  <td><span className={`badge ${gr.status === 'posted' ? 'badge-success' : 'badge-warning'}`}>{gr.status === 'posted' ? 'Diterima' : gr.delivery_id ? 'Dalam perjalanan' : 'Draft'}</span></td>
                  <td className="right">{formatRupiah(gr.grand_total)}</td>
                  <td className="right">{gr.status === 'draft' && <button className={`btn-sm ${gr.delivery_id ? 'btn-success' : ''}`} onClick={() => setReceivingId(gr.id)}>{gr.delivery_id ? 'Terima kiriman' : 'Lanjutkan'}</button>}</td>
                </tr>
              ))}
              {!receipts.length && <tr><td colSpan={8} className="empty">Belum ada penerimaan barang.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === 'bills' && <BranchBillsTab />}
      {tab === 'pricelist' && <PricelistTab suppliers={suppliers.filter((x) => x.supplier_type === 'external')} items={items} itemUnits={itemUnits} />}

      {tab === 'suppliers' && (
        <div className="card table-wrap">
          <table className="table">
            <thead><tr><th>Kode</th><th>Nama</th><th>Tipe</th><th>Kontak</th><th>Telepon</th><th>Termin</th><th></th></tr></thead>
            <tbody>
              {suppliers.map((s) => (
                <tr key={s.id}>
                  <td>{s.code}</td><td className="bold">{s.name}</td>
                  <td>{s.supplier_type === 'internal' ? <span className="badge badge-primary">Cabang: {s.sys_outlets?.name}</span> : s.supplier_type === 'intercompany' ? <span className="badge badge-info">PT dalam grup</span> : <span className="badge">Pihak ke-3</span>}</td>
                  <td>{s.contact_name}</td><td>{s.phone}</td>
                  <td>{s.payment_term_days ? `${s.payment_term_days} hari` : 'Tunai'}</td>
                  <td className="right"><button className="btn-sm" onClick={() => setEditingSupplier(s)}>Edit</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {creatingPo && (
        <PurchaseOrderForm companyId={companyId} suppliers={suppliers} warehouses={warehouses} items={items} itemUnits={itemUnits}
          onClose={() => setCreatingPo(false)}
          onSaved={(msg) => {
            setCreatingPo(false);
            setNotice(msg);
            load();
          }} />
      )}

      {poDetail && (() => {
        const po = orders.find((x) => x.id === poDetail);
        return po ? <PurchaseOrderDetail po={po} actions={poActions(po, () => setPoDetail(null))} onClose={() => setPoDetail(null)} /> : null;
      })()}

      {receivingId && (
        <GoodsReceiptForm receiptId={receivingId}
          onClose={() => {
            setReceivingId(null);
            load();
          }}
          onPosted={(msg) => {
            setReceivingId(null);
            setNotice(msg);
            load();
          }} />
      )}

      {editingSupplier && (
        <Modal title={editingSupplier.id ? 'Edit Supplier' : 'Supplier Baru'} onClose={() => setEditingSupplier(null)}
          footer={<>
            <button onClick={() => setEditingSupplier(null)}>Batal</button>
            <button className="btn-primary" disabled={!editingSupplier.code || !editingSupplier.name} onClick={() => act(async () => {
              const { id, code, name, contact_name, phone, payment_term_days } = editingSupplier;
              const row = { company_id: companyId, code, name, contact_name, phone, payment_term_days };
              await must(id ? supabase.from('pur_suppliers').update(row).eq('id', id) : supabase.from('pur_suppliers').insert(row));
              setEditingSupplier(null);
            })}>Simpan</button>
          </>}>
          {editingSupplier.supplier_type === 'internal' && (
            <div className="alert alert-info small">Supplier internal = outlet <b>{editingSupplier.sys_outlets?.name}</b>. PO ke supplier ini otomatis menjadi Sales Order di outlet tersebut, harga dari Pricelist Jual.</div>
          )}
          <div className="form-grid">
            {([['code', 'Kode'], ['name', 'Nama'], ['contact_name', 'Kontak'], ['phone', 'Telepon']] as [keyof Supplier, string][]).map(([k, label]) => (
              <label key={k} className="field"><span>{label}</span>
                <input value={(editingSupplier[k] as string) ?? ''} onChange={(e) => setEditingSupplier({ ...editingSupplier, [k]: e.target.value })} /></label>
            ))}
            <label className="field"><span>Termin bayar (hari)</span>
              <input type="number" value={editingSupplier.payment_term_days ?? 0} onChange={(e) => setEditingSupplier({ ...editingSupplier, payment_term_days: Number(e.target.value) })} /></label>
          </div>
        </Modal>
      )}
    </>
  );
}

interface PoLine { item_id: string; unit_key: string; quantity: string; unit_price: string; hint?: { pricelist?: number; pricelistNo?: string; last?: number; internal?: boolean; missing?: boolean } }

function PurchaseOrderForm({ companyId, suppliers, warehouses, items, itemUnits, onClose, onSaved }: {
  companyId: string; suppliers: Supplier[]; warehouses: Warehouse[]; items: Item[]; itemUnits: ItemUnit[];
  onClose: () => void; onSaved: (msg: string) => void;
}) {
  const [supplierId, setSupplierId] = useState(suppliers[0]?.id ?? '');
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? '');
  const [expectedDate, setExpectedDate] = useState('');
  const [note, setNote] = useState('');
  const [lines, setLines] = useState<PoLine[]>([{ item_id: '', unit_key: '', quantity: '', unit_price: '' }]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  // Pilihan satuan produk (satuan beli default di urutan pertama)
  const unitOptions = (itemId: string) => {
    const item = items.find((i) => i.id === itemId);
    if (!item) return [];
    const rows = itemUnits.filter((u) => u.item_id === itemId)
      .sort((a, b) => Number(b.is_purchase_unit) - Number(a.is_purchase_unit) || Number(a.conversion_qty) - Number(b.conversion_qty));
    const opts = rows.map((u) => ({ key: `${u.unit_id}|${u.conversion_qty}`, label: u.inv_units.code, conversion: Number(u.conversion_qty) }));
    return opts.length ? opts : [{ key: `${item.base_unit_id}|1`, label: item.inv_units.code, conversion: 1 }];
  };

  // Harga: pricelist supplier yang berlaku, kalau tidak ada pakai harga beli terakhir
  const outletOf = (whId: string) => warehouses.find((w) => w.id === whId)?.outlet_id ?? null;
  const lookupPrice = async (line: PoLine, supplier = supplierId): Promise<PoLine> => {
    const item = items.find((x) => x.id === line.item_id);
    if (!item || !line.unit_key) return line;
    const [unitId, conv] = line.unit_key.split('|');
    const sup = suppliers.find((x) => x.id === supplier);
    if (sup?.supplier_type === 'internal') {
      try {
        const price = await rpc<number | null>('sal_get_price', { p_company_id: companyId, p_seller_outlet_id: sup.linked_outlet_id, p_buyer_outlet_id: outletOf(warehouseId),
          p_customer_id: null, p_item_id: item.id, p_unit_id: unitId, p_date: todayISO() });
        return { ...line, unit_price: price === null ? '' : String(price), hint: { internal: true, missing: price === null } };
      } catch {
        return line;
      }
    }
    try {
      const p = await rpc<{ pricelist: { price: number; pricelist_number: string } | null; last: { price: number } | null }>('pur_get_item_price', {
        p_supplier_id: supplier, p_item_id: item.id, p_unit_id: unitId, p_outlet_id: outletOf(warehouseId) });
      const fallback = Math.round(Number(item.last_purchase_cost) * Number(conv));
      return { ...line, unit_price: String(p.pricelist ? Number(p.pricelist.price) : p.last ? Number(p.last.price) : fallback),
        hint: { pricelist: p.pricelist ? Number(p.pricelist.price) : undefined, pricelistNo: p.pricelist?.pricelist_number, last: p.last ? Number(p.last.price) : undefined } };
    } catch {
      return line;
    }
  };

  const updateLine = async (idx: number, patch: Partial<PoLine>) => {
    let next = { ...lines[idx], ...patch };
    if (patch.item_id !== undefined) next = { ...next, unit_key: unitOptions(patch.item_id)[0]?.key ?? '', unit_price: '', hint: undefined };
    setLines((ls) => ls.map((l, i) => (i === idx ? next : l)));
    if (patch.item_id !== undefined || patch.unit_key !== undefined) {
      const priced = await lookupPrice(next);
      setLines((ls) => ls.map((l, i) => (i === idx ? { ...priced, quantity: l.quantity } : l)));
    }
  };

  // ganti supplier/gudang -> harga ikut pricelist supplier baru
  useEffect(() => {
    if (!lines.some((l) => l.item_id)) return;
    Promise.all(lines.map((l) => lookupPrice(l))).then(setLines);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [supplierId, warehouseId]);

  const valid = lines.filter((l) => l.item_id && Number(l.quantity) > 0);
  const total = valid.reduce((s, l) => s + Number(l.quantity) * Number(l.unit_price || 0), 0);
  const internal = suppliers.find((x) => x.id === supplierId)?.supplier_type === 'internal';
  const intercompany = suppliers.find((x) => x.id === supplierId)?.supplier_type === 'intercompany';
  const missingPrice = internal && valid.some((l) => l.hint?.missing);

  const save = async (approve: boolean) => {
    setBusy(true);
    setError('');
    try {
      const po = (await must(supabase.from('pur_purchase_orders').insert({
        company_id: companyId, supplier_id: supplierId, warehouse_id: warehouseId,
        expected_date: expectedDate || null, note: note || null,
      }).select('id').single())) as { id: string };
      await must(supabase.from('pur_purchase_order_items').insert(valid.map((l) => {
        const [unit_id, conversion] = l.unit_key.split('|');
        return {
          company_id: companyId, purchase_order_id: po.id, item_id: l.item_id, unit_id,
          conversion_qty: Number(conversion), quantity: Number(l.quantity), unit_price: Number(l.unit_price || 0),
          line_total: Number(l.quantity) * Number(l.unit_price || 0),
        };
      })));
      if (approve) {
        const r = await rpc<{ po_number: string; pending_approval?: boolean }>('pur_approve_purchase_order', { p_id: po.id });
        onSaved(r.pending_approval ? 'PO dibuat & dikirim ke atasan untuk disetujui.' : `PO ${r.po_number} dibuat & disetujui.`);
      } else {
        onSaved('Draft PO tersimpan.');
      }
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title="Purchase Order Baru" onClose={onClose} large
      footer={<>
        <span className="bold" style={{ marginRight: 'auto' }}>Total: {formatRupiah(total)}</span>
        <button disabled={busy || !valid.length || missingPrice} onClick={() => save(false)}>Simpan Draft</button>
        <button className="btn-primary" disabled={busy || !valid.length || missingPrice} onClick={() => save(true)}>Simpan & Setujui</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      {internal && <div className="alert alert-info small">PO ke cabang internal: harga dikunci dari <b>Pricelist Jual</b> cabang penjual. Setelah disetujui, PO otomatis menjadi Sales Order di cabang penjual.</div>}
      {intercompany && <div className="alert alert-info small">PO ke <b>PT lain dalam grup</b>: barang dicocokkan lewat <b>kode barang yang sama</b> di kedua PT; harga dari Pricelist Jual PT penjual bila ada. Setelah disetujui, PO otomatis menjadi Sales Order di PT penjual, dan penerimaan barang dibuat otomatis saat PT penjual mengirim.</div>}
      <div className="form-grid">
        <label className="field"><span>Supplier</span>
          <select value={supplierId} onChange={(e) => setSupplierId(e.target.value)}>
            <optgroup label="Pihak ke-3">{suppliers.filter((x) => x.supplier_type === 'external').map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</optgroup>
            <optgroup label="Cabang internal">{suppliers.filter((x) => x.supplier_type === 'internal').map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</optgroup>
            {suppliers.some((x) => x.supplier_type === 'intercompany') && <optgroup label="PT dalam grup">{suppliers.filter((x) => x.supplier_type === 'intercompany').map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</optgroup>}
          </select>
        </label>
        <label className="field"><span>Kirim ke gudang</span>
          <select value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
        </label>
        <label className="field"><span>Tanggal diharapkan</span><input type="date" value={expectedDate} onChange={(e) => setExpectedDate(e.target.value)} /></label>
        <label className="field"><span>Catatan</span><input value={note} onChange={(e) => setNote(e.target.value)} /></label>
      </div>
      <table className="table" style={{ marginTop: 16 }}>
        <thead><tr><th>Bahan</th><th>Satuan</th><th>Qty</th><th>Harga / satuan</th><th className="right">Subtotal</th><th></th></tr></thead>
        <tbody>
          {lines.map((l, idx) => (
            <tr key={idx}>
              <td>
                <select value={l.item_id} onChange={(e) => updateLine(idx, { item_id: e.target.value })} style={{ width: '100%' }}>
                  <option value="">— pilih —</option>
                  {items.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
                </select>
              </td>
              <td>
                <select value={l.unit_key} onChange={(e) => updateLine(idx, { unit_key: e.target.value })}>
                  {unitOptions(l.item_id).map((u) => <option key={u.key} value={u.key}>{u.label}</option>)}
                </select>
              </td>
              <td><input type="number" value={l.quantity} onChange={(e) => updateLine(idx, { quantity: e.target.value })} style={{ width: 90 }} /></td>
              <td>
                <MoneyInput value={l.unit_price} disabled={internal} onChange={(v) => updateLine(idx, { unit_price: v })} style={{ width: 130 }} />
                {l.hint?.internal && (l.hint.missing
                  ? <div className="small" style={{ color: 'var(--danger)' }}>Belum ada di Pricelist Jual cabang</div>
                  : <div className="muted small">Pricelist Jual cabang</div>)}
                {l.hint?.pricelist !== undefined && (
                  <div className={`small ${Number(l.unit_price) > l.hint.pricelist ? '' : 'muted'}`} style={Number(l.unit_price) > l.hint.pricelist ? { color: 'var(--danger)' } : undefined}>
                    Pricelist {l.hint.pricelistNo}: {formatRupiah(l.hint.pricelist)}{Number(l.unit_price) > l.hint.pricelist && ' · di atas pricelist!'}
                  </div>
                )}
                {l.hint?.last !== undefined && <div className="muted small">Terakhir: {formatRupiah(l.hint.last)}</div>}
              </td>
              <td className="right">{formatRupiah(Number(l.quantity || 0) * Number(l.unit_price || 0))}</td>
              <td><button className="btn-sm btn-danger" onClick={() => setLines(lines.filter((_, i) => i !== idx))}>✕</button></td>
            </tr>
          ))}
        </tbody>
      </table>
      <button className="btn-sm" onClick={() => setLines([...lines, { item_id: '', unit_key: '', quantity: '', unit_price: '' }])}>+ Baris</button>
    </Modal>
  );
}

function GoodsReceiptForm({ receiptId, onClose, onPosted }: { receiptId: string; onClose: () => void; onPosted: (msg: string) => void }) {
  const [lines, setLines] = useState<{
    id: string; quantity: number; unit_price: number; lot_number: string | null; expiry_date: string | null; shipped_qty: number | null;
    inv_items: { name: string; track_batch: boolean; shelf_life_days: number | null }; inv_units: { code: string };
  }[]>([]);
  const [delivery, setDelivery] = useState<{ delivery_number: string; seller: string } | null>(null);
  const internal = !!delivery;
  const [invoice, setInvoice] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [labels, setLabels] = useState<{ labels: LabelData[]; msg: string } | null>(null);

  useEffect(() => {
    must(supabase.from('pur_goods_receipt_items')
      .select('id, quantity, unit_price, lot_number, expiry_date, shipped_qty, inv_items(name, track_batch, shelf_life_days), inv_units(code)')
      .eq('goods_receipt_id', receiptId).order('created_at'))
      .then((r) => setLines(r as unknown as typeof lines))
      .catch((e) => setError(errorMessage(e)));
    must(supabase.from('pur_goods_receipts').select('delivery_id, pur_suppliers(name), sal_deliveries!pur_goods_receipts_delivery_id_fkey(delivery_number)').eq('id', receiptId).single())
      .then((g: { delivery_id: string | null; pur_suppliers: { name: string }; sal_deliveries: { delivery_number: string } | null }) =>
        setDelivery(g.delivery_id ? { delivery_number: g.sal_deliveries?.delivery_number ?? '', seller: g.pur_suppliers.name } : null))
      .catch(() => setDelivery(null));
  }, [receiptId]);

  const post = async () => {
    setBusy(true);
    setError('');
    try {
      for (const l of lines) {
        if (internal) {
          await must(supabase.from('pur_goods_receipt_items').update({ quantity: Math.max(0, Number(l.quantity) || 0) }).eq('id', l.id));
        } else if (Number(l.quantity) > 0) {
          await must(supabase.from('pur_goods_receipt_items').update({
            quantity: l.quantity, unit_price: l.unit_price, lot_number: l.lot_number?.trim() || null, expiry_date: l.expiry_date || null,
          }).eq('id', l.id));
        } else {
          await must(supabase.from('pur_goods_receipt_items').delete().eq('id', l.id));
        }
      }
      await must(supabase.from('pur_goods_receipts').update({ supplier_invoice_number: invoice || null }).eq('id', receiptId));
      const r = await rpc<{ receipt_number: string }>('pur_post_goods_receipt', { p_id: receiptId });
      const short = internal ? lines.reduce((t, l) => t + Math.max(0, Number(l.shipped_qty) - Number(l.quantity)) * Number(l.unit_price), 0) : 0;
      const msg = `Penerimaan ${r.receipt_number} diposting. Stok sudah bertambah.` + (short > 0 ? ` Kekurangan ${formatRupiah(short)} dicatat sebagai selisih kiriman (minta nota kredit ke penjual).` : '');
      // produk lacak batch: tawarkan cetak label batch yang baru dibuat
      if (lines.some((l) => l.inv_items.track_batch && Number(l.quantity) > 0)) {
        const b = await must(supabase.from('rpt_stock_batches').select('batch_code, item_name, lot_number, expiry_date, received_at, track_batch')
          .eq('reference_type', 'pur_goods_receipts').eq('reference_number', r.receipt_number).eq('track_batch', true));
        if (b.length) return setLabels({ labels: b.map(batchLabel), msg });
      }
      onPosted(msg);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title={internal ? `Terima Kiriman ${delivery.delivery_number}` : 'Penerimaan Barang'} onClose={onClose} large
      footer={<><button onClick={onClose}>Simpan sebagai Draft</button><button className="btn-success" disabled={busy} onClick={post}>Terima & Posting ke Stok</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      {internal
        ? <div className="alert alert-info small">Kiriman dari <b>{delivery.seller}</b>. Isi qty yang benar-benar diterima. Tagihan mengikuti qty dikirim, kekurangan dicatat sebagai selisih kiriman sampai penjual memberi nota kredit. Batch & kedaluwarsa ikut dari penjual.</div>
        : <label className="field" style={{ maxWidth: 300 }}><span>No. faktur supplier</span><input value={invoice} onChange={(e) => setInvoice(e.target.value)} /></label>}
      <table className="table" style={{ marginTop: 16 }}>
        <thead><tr><th>Bahan</th>{internal && <th className="right">Dikirim</th>}<th>Qty diterima</th><th>Harga / satuan</th>{!internal && <th>Lot & kedaluwarsa</th>}<th className="right">Subtotal</th></tr></thead>
        <tbody>
          {lines.map((l, idx) => (
            <tr key={l.id}>
              <td>{l.inv_items.name}{l.inv_items.track_batch && <div><span className="badge badge-info">Lacak batch</span></div>}</td>
              {internal && <td className="right">{formatNumber(l.shipped_qty)} {l.inv_units.code}</td>}
              <td className="row">
                <input type="number" value={l.quantity} onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, quantity: Number(e.target.value) } : x))} style={{ width: 90 }} />
                {l.inv_units.code}
              </td>
              <td><MoneyInput value={l.unit_price} disabled={internal} onChange={(v) => setLines(lines.map((x, i) => i === idx ? { ...x, unit_price: Number(v) } : x))} style={{ width: 120 }} /></td>
              {!internal && <td>
                <div className="row" style={{ flexWrap: 'nowrap', gap: 6 }}>
                  <input placeholder="No. lot" style={{ width: 90 }} value={l.lot_number ?? ''} onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, lot_number: e.target.value } : x))} />
                  <input type="date" style={{ width: 140 }} value={l.expiry_date ?? ''} title="Tanggal kedaluwarsa"
                    onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, expiry_date: e.target.value || null } : x))} />
                </div>
                {l.inv_items.track_batch && !l.expiry_date && (l.inv_items.shelf_life_days
                  ? <div className="muted small">Kosong = otomatis {l.inv_items.shelf_life_days} hari dari hari ini</div>
                  : <div className="small" style={{ color: 'var(--danger)' }}>Wajib diisi</div>)}
              </td>}
              <td className="right">{formatRupiah(l.quantity * l.unit_price)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {!internal && <p className="muted small">Isi 0 untuk barang yang tidak datang. Sisa PO bisa diterima di penerimaan berikutnya.
        Setiap baris menjadi 1 batch stok (dipakai FEFO: kedaluwarsa duluan keluar duluan).</p>}
      {labels && <LabelPrintModal title="Cetak Label Batch" labels={labels.labels} onClose={() => onPosted(labels.msg)} />}
    </Modal>
  );
}

interface PoLineDetail {
  id: string; quantity: number; received_qty: number; unit_price: number; line_total: number; conversion_qty: number;
  inv_items: { code: string; name: string }; inv_units: { code: string };
}
interface PoReceipt { id: string; receipt_number: string | null; receipt_date: string; status: string; grand_total: number }

// Detail PO: info header, item (dipesan / diterima / sisa), penerimaan terkait
function PurchaseOrderDetail({ po, actions, onClose }: { po: PurchaseOrder; actions: React.ReactNode; onClose: () => void }) {
  const { toast } = useFeedback();
  const [lines, setLines] = useState<PoLineDetail[]>([]);
  const [receipts, setReceipts] = useState<PoReceipt[]>([]);
  useEffect(() => {
    Promise.all([
      must(supabase.from('pur_purchase_order_items').select('id, quantity, received_qty, unit_price, line_total, conversion_qty, inv_items(code, name), inv_units(code)')
        .eq('purchase_order_id', po.id).order('created_at')),
      must(supabase.from('pur_goods_receipts').select('id, receipt_number, receipt_date, status, grand_total').eq('purchase_order_id', po.id).order('created_at')),
    ]).then(([l, r]) => { setLines(l); setReceipts(r); }).catch((e) => toast(errorMessage(e), 'error'));
  }, [po.id, toast]);

  const [label, badge] = PO_STATUS[po.status] ?? [po.status, 'badge'];
  const total = lines.reduce((t, l) => t + Number(l.quantity) * Number(l.unit_price), 0);
  return (
    <Modal title={`Purchase Order ${po.po_number ?? '(draft)'}`} onClose={onClose} large
      footer={<><button onClick={onClose} style={{ marginRight: 'auto' }}>Tutup</button>{actions}</>}>
      <div className="grid grid-4" style={{ marginBottom: 14 }}>
        <div><div className="stat-label">Supplier</div><b>{po.pur_suppliers.name}</b>{po.pur_suppliers.supplier_type === 'internal' && <span className="badge badge-primary" style={{ marginLeft: 6 }}>Cabang</span>}</div>
        <div><div className="stat-label">Kirim ke</div><b>{po.inv_warehouses.name}</b></div>
        <div><div className="stat-label">Tanggal / diharapkan</div><b>{po.po_date}</b>{po.expected_date && <span className="muted"> → {po.expected_date}</span>}</div>
        <div><div className="stat-label">Status</div><span className={`badge ${badge}`}>{label}</span></div>
      </div>
      {po.sales_note && <div className="alert alert-info small">{po.sales_note}</div>}
      {po.note && <p className="muted small">Catatan: {po.note}</p>}
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>Produk</th><th>Satuan</th><th className="right">Dipesan</th><th className="right">Diterima</th><th className="right">Sisa</th><th className="right">Harga</th><th className="right">Subtotal</th></tr></thead>
          <tbody>
            {lines.map((l) => {
              const sisa = Math.max(0, Number(l.quantity) - Number(l.received_qty));
              return (
                <tr key={l.id}>
                  <td><b>{l.inv_items.code}</b> · {l.inv_items.name}</td>
                  <td>{l.inv_units.code}</td>
                  <td className="right">{formatNumber(l.quantity)}</td>
                  <td className="right" style={{ color: Number(l.received_qty) >= Number(l.quantity) ? 'var(--success)' : undefined }}>{formatNumber(l.received_qty)}</td>
                  <td className="right">{sisa ? formatNumber(sisa) : '-'}</td>
                  <td className="right">{formatRupiah(l.unit_price)}</td>
                  <td className="right">{formatRupiah(Number(l.quantity) * Number(l.unit_price))}</td>
                </tr>
              );
            })}
            {!lines.length && <tr><td colSpan={7} className="empty">Memuat…</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="row" style={{ justifyContent: 'flex-end', marginTop: 8 }}><b>Total {formatRupiah(po.status === 'draft' ? total : po.grand_total)}</b></div>
      {!!receipts.length && <>
        <div className="section-title">Penerimaan barang</div>
        {receipts.map((r) => (
          <div key={r.id} className="row list-row" style={{ cursor: 'default' }}>
            <b>{r.receipt_number ?? '(draft)'}</b><span className="muted small">{r.receipt_date}</span>
            <span style={{ marginLeft: 'auto' }}>{formatRupiah(r.grand_total)}</span>
            <span className={`badge ${r.status === 'posted' ? 'badge-success' : 'badge-warning'}`}>{r.status === 'posted' ? 'Diterima' : 'Draft'}</span>
          </div>
        ))}
      </>}
    </Modal>
  );
}
