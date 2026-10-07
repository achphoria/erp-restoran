import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { useFeedback, useNotice } from '../components/Feedback';
import { errorMessage, formatDateTime, formatNumber, formatRupiah } from '../lib/format';
import Modal from '../components/Modal';
import MoneyInput from '../components/MoneyInput';
import PricelistTab from '../components/PricelistTab';
import LabelPrintModal from '../components/inventory/LabelPrintModal';
import { batchLabel } from '../components/inventory/batchUtils';
import type { LabelData } from '../lib/barcode';

type Tab = 'po' | 'receipts' | 'pricelist' | 'suppliers';

interface Supplier { id: string; code: string; name: string; contact_name: string | null; phone: string | null; payment_term_days: number }
interface Warehouse { id: string; name: string; outlet_id: string | null }
interface Item { id: string; code: string; name: string; base_unit_id: string; last_purchase_cost: number; inv_units: { code: string } }
interface ItemUnit { item_id: string; unit_id: string; conversion_qty: number; is_purchase_unit: boolean; inv_units: { code: string } }
interface PurchaseOrder {
  id: string; po_number: string | null; po_date: string; status: string; grand_total: number; note: string | null;
  pur_suppliers: { name: string }; inv_warehouses: { name: string };
  pur_purchase_order_items: { id: string; quantity: number; received_qty: number; unit_price: number; inv_items: { name: string }; inv_units: { code: string } }[];
}
interface GoodsReceipt {
  id: string; receipt_number: string | null; receipt_date: string; status: string; grand_total: number; posted_at: string | null;
  supplier_invoice_number: string | null;
  pur_suppliers: { name: string }; pur_purchase_orders: { po_number: string } | null;
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
  const [tab, setTab] = useState<Tab>('po');
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [items, setItems] = useState<Item[]>([]);
  const [itemUnits, setItemUnits] = useState<ItemUnit[]>([]);
  const [orders, setOrders] = useState<PurchaseOrder[]>([]);
  const [receipts, setReceipts] = useState<GoodsReceipt[]>([]);
  const [creatingPo, setCreatingPo] = useState(false);
  const [receivingId, setReceivingId] = useState<string | null>(null);
  const [editingSupplier, setEditingSupplier] = useState<Partial<Supplier> | null>(null);
  const [error, setError] = useState('');
  const setNotice = useNotice();
  const { confirm } = useFeedback();

  const load = useCallback(async () => {
    try {
      const [s, w, i, iu, po, gr] = await Promise.all([
        must(supabase.from('pur_suppliers').select('*').eq('is_active', true).order('code')),
        must(supabase.from('inv_warehouses').select('id, name, outlet_id').eq('is_active', true).order('code')),
        must(supabase.from('inv_items').select('id, code, name, base_unit_id, last_purchase_cost, inv_units(code)').eq('is_active', true).eq('is_purchasable', true).eq('approval_status', 'approved').order('name')),
        must(supabase.from('inv_item_units').select('item_id, unit_id, conversion_qty, is_purchase_unit, inv_units(code)')),
        must(supabase.from('pur_purchase_orders')
          .select('*, pur_suppliers(name), inv_warehouses(name), pur_purchase_order_items(id, quantity, received_qty, unit_price, inv_items(name), inv_units(code))')
          .order('created_at', { ascending: false }).limit(50)),
        must(supabase.from('pur_goods_receipts')
          .select('*, pur_suppliers(name), pur_purchase_orders(po_number)')
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

  const startReceiving = (poId: string) =>
    act(async () => {
      setReceivingId(await rpc<string>('pur_create_goods_receipt_from_po', { p_po_id: poId }));
    });

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Pembelian</h1>
          <p>Purchase Order ke supplier dan penerimaan barang ke gudang.</p>
        </div>
        {tab === 'po' && <button className="btn-primary" onClick={() => setCreatingPo(true)}>+ Purchase Order</button>}
        {tab === 'suppliers' && <button className="btn-primary" onClick={() => setEditingSupplier({ payment_term_days: 0 })}>+ Supplier</button>}
      </div>
      <div className="tabs">
        {([['po', 'Purchase Order'], ['receipts', 'Penerimaan Barang'], ['pricelist', 'Pricelist'], ['suppliers', 'Supplier']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      {tab === 'po' && (
        <div className="card table-wrap">
          <table className="table">
            <thead><tr><th>No. PO</th><th>Tanggal</th><th>Supplier</th><th>Item</th><th>Status</th><th className="right">Total</th><th></th></tr></thead>
            <tbody>
              {orders.map((po) => {
                const [label, badge] = PO_STATUS[po.status] ?? [po.status, 'badge'];
                return (
                  <tr key={po.id}>
                    <td className="bold">{po.po_number ?? '(draft)'}</td>
                    <td>{po.po_date}</td>
                    <td>{po.pur_suppliers.name}</td>
                    <td className="small">
                      {po.pur_purchase_order_items.map((i) => (
                        <div key={i.id}>{i.inv_items.name}: {formatNumber(i.received_qty)}/{formatNumber(i.quantity)} {i.inv_units.code}</div>
                      ))}
                    </td>
                    <td><span className={`badge ${badge}`}>{label}</span></td>
                    <td className="right">{formatRupiah(po.status === 'draft'
                      ? po.pur_purchase_order_items.reduce((s, i) => s + i.quantity * i.unit_price, 0)
                      : po.grand_total)}</td>
                    <td className="right">
                      <div className="row" style={{ justifyContent: 'flex-end' }}>
                        {(po.status === 'draft' || (po.status === 'pending_approval' && can('approval.purchase_order'))) && (
                          <button className="btn-sm btn-primary" onClick={() => act(async () => {
                            const r = await rpc<{ po_number: string; pending_approval?: boolean }>('pur_approve_purchase_order', { p_id: po.id });
                            return r.pending_approval ? 'PO dikirim ke atasan untuk disetujui.' : `PO ${r.po_number} disetujui.`;
                          })}>Setujui</button>
                        )}
                        {po.status === 'draft' && (
                          <button className="btn-sm btn-danger" onClick={async () => {
                            if (await confirm({ title: 'Hapus draft PO ini?', danger: true, confirmLabel: 'Hapus' })) {
                              act(() => must(supabase.from('pur_purchase_orders').delete().eq('id', po.id)).then(() => 'Draft dihapus.'));
                            }
                          }}>Hapus</button>
                        )}
                        {['approved', 'partially_received'].includes(po.status) && (
                          <button className="btn-sm btn-success" onClick={() => startReceiving(po.id)}>Terima Barang</button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
              {!orders.length && <tr><td colSpan={7} className="empty">Belum ada purchase order.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === 'receipts' && (
        <div className="card table-wrap">
          <table className="table">
            <thead><tr><th>No. Penerimaan</th><th>Waktu</th><th>Supplier</th><th>No. PO</th><th>No. Faktur</th><th>Status</th><th className="right">Total</th><th></th></tr></thead>
            <tbody>
              {receipts.map((gr) => (
                <tr key={gr.id}>
                  <td className="bold">{gr.receipt_number ?? '(draft)'}</td>
                  <td>{gr.posted_at ? formatDateTime(gr.posted_at) : gr.receipt_date}</td>
                  <td>{gr.pur_suppliers.name}</td>
                  <td>{gr.pur_purchase_orders?.po_number ?? '-'}</td>
                  <td>{gr.supplier_invoice_number ?? '-'}</td>
                  <td><span className={`badge ${gr.status === 'posted' ? 'badge-success' : 'badge-warning'}`}>{gr.status}</span></td>
                  <td className="right">{formatRupiah(gr.grand_total)}</td>
                  <td className="right">{gr.status === 'draft' && <button className="btn-sm" onClick={() => setReceivingId(gr.id)}>Lanjutkan</button>}</td>
                </tr>
              ))}
              {!receipts.length && <tr><td colSpan={8} className="empty">Belum ada penerimaan barang.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === 'pricelist' && <PricelistTab suppliers={suppliers} items={items} itemUnits={itemUnits} />}

      {tab === 'suppliers' && (
        <div className="card table-wrap">
          <table className="table">
            <thead><tr><th>Kode</th><th>Nama</th><th>Kontak</th><th>Telepon</th><th>Termin</th><th></th></tr></thead>
            <tbody>
              {suppliers.map((s) => (
                <tr key={s.id}>
                  <td>{s.code}</td><td className="bold">{s.name}</td><td>{s.contact_name}</td><td>{s.phone}</td>
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

interface PoLine { item_id: string; unit_key: string; quantity: string; unit_price: string; hint?: { pricelist?: number; pricelistNo?: string; last?: number } }

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
        <button disabled={busy || !valid.length} onClick={() => save(false)}>Simpan Draft</button>
        <button className="btn-primary" disabled={busy || !valid.length} onClick={() => save(true)}>Simpan & Setujui</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field"><span>Supplier</span>
          <select value={supplierId} onChange={(e) => setSupplierId(e.target.value)}>
            {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
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
                <MoneyInput value={l.unit_price} onChange={(v) => updateLine(idx, { unit_price: v })} style={{ width: 130 }} />
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
    id: string; quantity: number; unit_price: number; lot_number: string | null; expiry_date: string | null;
    inv_items: { name: string; track_batch: boolean; shelf_life_days: number | null }; inv_units: { code: string };
  }[]>([]);
  const [invoice, setInvoice] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [labels, setLabels] = useState<{ labels: LabelData[]; msg: string } | null>(null);

  useEffect(() => {
    must(supabase.from('pur_goods_receipt_items')
      .select('id, quantity, unit_price, lot_number, expiry_date, inv_items(name, track_batch, shelf_life_days), inv_units(code)')
      .eq('goods_receipt_id', receiptId).order('created_at'))
      .then((r) => setLines(r as unknown as typeof lines))
      .catch((e) => setError(errorMessage(e)));
  }, [receiptId]);

  const post = async () => {
    setBusy(true);
    setError('');
    try {
      for (const l of lines) {
        if (Number(l.quantity) > 0) {
          await must(supabase.from('pur_goods_receipt_items').update({
            quantity: l.quantity, unit_price: l.unit_price, lot_number: l.lot_number?.trim() || null, expiry_date: l.expiry_date || null,
          }).eq('id', l.id));
        } else {
          await must(supabase.from('pur_goods_receipt_items').delete().eq('id', l.id));
        }
      }
      await must(supabase.from('pur_goods_receipts').update({ supplier_invoice_number: invoice || null }).eq('id', receiptId));
      const r = await rpc<{ receipt_number: string }>('pur_post_goods_receipt', { p_id: receiptId });
      const msg = `Penerimaan ${r.receipt_number} diposting. Stok sudah bertambah.`;
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
    <Modal title="Penerimaan Barang" onClose={onClose} large
      footer={<><button onClick={onClose}>Simpan sebagai Draft</button><button className="btn-success" disabled={busy} onClick={post}>Terima & Posting ke Stok</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      <label className="field" style={{ maxWidth: 300 }}><span>No. faktur supplier</span><input value={invoice} onChange={(e) => setInvoice(e.target.value)} /></label>
      <table className="table" style={{ marginTop: 16 }}>
        <thead><tr><th>Bahan</th><th>Qty diterima</th><th>Harga / satuan</th><th>Lot & kedaluwarsa</th><th className="right">Subtotal</th></tr></thead>
        <tbody>
          {lines.map((l, idx) => (
            <tr key={l.id}>
              <td>{l.inv_items.name}{l.inv_items.track_batch && <div><span className="badge badge-info">Lacak batch</span></div>}</td>
              <td className="row">
                <input type="number" value={l.quantity} onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, quantity: Number(e.target.value) } : x))} style={{ width: 90 }} />
                {l.inv_units.code}
              </td>
              <td><MoneyInput value={l.unit_price} onChange={(v) => setLines(lines.map((x, i) => i === idx ? { ...x, unit_price: Number(v) } : x))} style={{ width: 120 }} /></td>
              <td>
                <div className="row" style={{ flexWrap: 'nowrap', gap: 6 }}>
                  <input placeholder="No. lot" style={{ width: 90 }} value={l.lot_number ?? ''} onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, lot_number: e.target.value } : x))} />
                  <input type="date" style={{ width: 140 }} value={l.expiry_date ?? ''} title="Tanggal kedaluwarsa"
                    onChange={(e) => setLines(lines.map((x, i) => i === idx ? { ...x, expiry_date: e.target.value || null } : x))} />
                </div>
                {l.inv_items.track_batch && !l.expiry_date && (l.inv_items.shelf_life_days
                  ? <div className="muted small">Kosong = otomatis {l.inv_items.shelf_life_days} hari dari hari ini</div>
                  : <div className="small" style={{ color: 'var(--danger)' }}>Wajib diisi</div>)}
              </td>
              <td className="right">{formatRupiah(l.quantity * l.unit_price)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="muted small">Isi 0 untuk barang yang tidak datang. Sisa PO bisa diterima di penerimaan berikutnya.
        Setiap baris menjadi 1 batch stok (dipakai FEFO: kedaluwarsa duluan keluar duluan).</p>
      {labels && <LabelPrintModal title="Cetak Label Batch" labels={labels.labels} onClose={() => onPosted(labels.msg)} />}
    </Modal>
  );
}
