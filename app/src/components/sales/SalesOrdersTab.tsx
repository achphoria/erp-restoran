import { useCallback, useEffect, useState } from 'react';
import { CheckCircle2, FileText, Lock, Plus, Trash2, Truck, XCircle } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatNumber, formatRupiah, todayISO } from '../../lib/format';
import DeliveryDetail from './DeliveryDetail';
import { DELIVERY_STATUS, INVOICE_STATUS, SO_STATUS, unitOptions, type SalesMaster } from './salesShared';

interface SoRow {
  id: string; so_number: string | null; so_date: string; expected_date: string | null; status: string; customer_type: string;
  grand_total: number; note: string | null; outlet_id: string; warehouse_id: string | null; tax_pct: number; reject_reason: string | null;
  seller: { name: string }; buyer: { name: string } | null; sal_customers: { name: string } | null; pur_purchase_orders: { po_number: string } | null;
}

const SO_SELECT = '*, seller:sys_outlets!sal_sales_orders_outlet_id_fkey(name), buyer:sys_outlets!sal_sales_orders_buyer_outlet_id_fkey(name), sal_customers(name), pur_purchase_orders(po_number)';

export default function SalesOrdersTab({ m }: { m: SalesMaster }) {
  const { toast } = useFeedback();
  const [seller, setSeller] = useState('');
  const [status, setStatus] = useState('open');
  const [rows, setRows] = useState<SoRow[]>([]);
  const [creating, setCreating] = useState(false);
  const [detail, setDetail] = useState<string | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('sal_sales_orders').select(SO_SELECT).order('created_at', { ascending: false }).limit(200);
    if (seller) q = q.eq('outlet_id', seller);
    if (status === 'open') q = q.in('status', ['draft', 'new', 'confirmed', 'partially_delivered']);
    else if (status) q = q.eq('status', status);
    setRows(await must(q));
  }, [seller, status]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const newCount = rows.filter((r) => r.status === 'new').length;

  return (
    <>
      <div className="card table-wrap">
        <div className="filter-bar">
          <select value={seller} onChange={(e) => setSeller(e.target.value)}>
            <option value="">Semua outlet penjual</option>
            {m.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="open">Masih berjalan</option>
            <option value="">Semua status</option>
            {Object.entries(SO_STATUS).map(([k, [v]]) => <option key={k} value={k}>{v}</option>)}
          </select>
          {newCount > 0 && <span className="badge badge-warning">{newCount} SO cabang menunggu konfirmasi</span>}
          <button className="btn-primary" style={{ marginLeft: 'auto' }} onClick={() => setCreating(true)} disabled={!m.customers.some((c) => c.is_active)}
            title={m.customers.length ? '' : 'Tambahkan pelanggan B2B dulu'}><Plus size={16} /> SO B2B</button>
        </div>
        <table className="table">
          <thead><tr><th>No. SO</th><th>Tanggal</th><th>Penjual</th><th>Pembeli</th><th>Status</th><th className="right">Total</th></tr></thead>
          <tbody>
            {rows.map((r) => {
              const [label, cls] = SO_STATUS[r.status] ?? [r.status, 'badge'];
              return (
                <tr key={r.id} style={{ cursor: 'pointer' }} onClick={() => setDetail(r.id)}>
                  <td className="bold">{r.so_number ?? '(draft)'}{r.pur_purchase_orders && <div className="muted small">PO {r.pur_purchase_orders.po_number}</div>}</td>
                  <td>{r.so_date}{r.expected_date && <div className="muted small">kirim {r.expected_date}</div>}</td>
                  <td>{r.seller?.name}</td>
                  <td>{r.customer_type === 'internal'
                    ? <><span className="badge badge-primary">Cabang</span> {r.buyer?.name}</>
                    : <><span className="badge">B2B</span> {r.sal_customers?.name}</>}</td>
                  <td><span className={`badge ${cls}`}>{label}</span></td>
                  <td className="right">{formatRupiah(r.grand_total)}</td>
                </tr>
              );
            })}
            {!rows.length && <tr><td colSpan={6} className="empty">Belum ada sales order. SO cabang muncul otomatis saat cabang lain menyetujui PO ke outlet ini.</td></tr>}
          </tbody>
        </table>
      </div>
      {creating && <SalesOrderForm m={m} onClose={() => setCreating(false)} onSaved={(id) => { setCreating(false); load(); setDetail(id); }} />}
      {detail && <SalesOrderDetail m={m} soId={detail} onClose={() => { setDetail(null); load(); }} />}
    </>
  );
}

// ---------------------------------------------------------------- SO B2B baru
interface Line { item_id: string; unit_id: string; quantity: string; unit_price: string }
const EMPTY: Line = { item_id: '', unit_id: '', quantity: '', unit_price: '' };

function SalesOrderForm({ m, onClose, onSaved }: { m: SalesMaster; onClose: () => void; onSaved: (id: string) => void }) {
  const { toast } = useFeedback();
  const active = m.customers.filter((c) => c.is_active);
  const [h, setH] = useState({ customer_id: active[0]?.id ?? '', outlet_id: m.outlets[0]?.id ?? '', warehouse_id: '', so_date: todayISO(),
    expected_date: '', tax_pct: '11', shipping_address: active[0]?.address ?? '', note: '' });
  const [lines, setLines] = useState<Line[]>([EMPTY]);
  const [busy, setBusy] = useState(false);
  const whs = m.warehouses.filter((w) => w.outlet_id === h.outlet_id);

  const price = async (l: Line): Promise<Line> => {
    if (!l.item_id || !l.unit_id) return l;
    try {
      const p = await rpc<number | null>('sal_get_price', { p_company_id: m.companyId, p_seller_outlet_id: h.outlet_id, p_buyer_outlet_id: null,
        p_customer_id: h.customer_id, p_item_id: l.item_id, p_unit_id: l.unit_id, p_date: h.so_date });
      return { ...l, unit_price: p === null ? l.unit_price : String(p) };
    } catch { return l; }
  };
  const upd = async (i: number, patch: Partial<Line>) => {
    let next = { ...lines[i], ...patch };
    if (patch.item_id !== undefined) next = { ...next, unit_id: unitOptions(m, patch.item_id)[0]?.unit_id ?? '', unit_price: '' };
    const all = lines.map((l, j) => (j === i ? next : l));
    if (all[all.length - 1].item_id) all.push(EMPTY);
    setLines(all);
    if (patch.item_id !== undefined || patch.unit_id !== undefined) {
      const p = await price(next);
      setLines((ls) => ls.map((l, j) => (j === i ? { ...p, quantity: l.quantity } : l)));
    }
  };
  // ganti pelanggan / penjual -> harga ikut pricelist yang berlaku
  useEffect(() => {
    if (!lines.some((l) => l.item_id)) return;
    Promise.all(lines.map(price)).then(setLines);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [h.customer_id, h.outlet_id]);

  const valid = lines.filter((l) => l.item_id && Number(l.quantity) > 0);
  const sub = valid.reduce((s, l) => s + Number(l.quantity) * Number(l.unit_price || 0), 0);
  const tax = Math.round(sub * Number(h.tax_pct || 0)) / 100;

  const save = async (confirmNow: boolean) => {
    setBusy(true);
    try {
      const so = (await must(supabase.from('sal_sales_orders').insert({
        company_id: m.companyId, outlet_id: h.outlet_id, warehouse_id: h.warehouse_id || whs[0]?.id || null, customer_type: 'external',
        customer_id: h.customer_id, so_date: h.so_date, expected_date: h.expected_date || null, tax_pct: Number(h.tax_pct || 0),
        shipping_address: h.shipping_address.trim() || null, note: h.note.trim() || null,
      }).select('id').single())) as { id: string };
      await must(supabase.from('sal_sales_order_items').insert(valid.map((l) => ({
        company_id: m.companyId, sales_order_id: so.id, item_id: l.item_id, unit_id: l.unit_id,
        quantity: Number(l.quantity), unit_price: Number(l.unit_price || 0),
      }))));
      if (confirmNow) await rpc('sal_confirm_sales_order', { p_id: so.id });
      toast(confirmNow ? 'Sales order dikonfirmasi' : 'Draft sales order tersimpan');
      onSaved(so.id);
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <Modal title="Sales Order B2B" onClose={onClose} large
      footer={<>
        <span className="bold" style={{ marginRight: 'auto' }}>Total {formatRupiah(sub + tax)}</span>
        <button disabled={busy || !valid.length} onClick={() => save(false)}>Simpan draft</button>
        <button className="btn-primary" disabled={busy || !valid.length} onClick={() => save(true)}>Simpan & konfirmasi</button>
      </>}>
      <div className="form-grid">
        <label className="field"><span>Pelanggan *</span>
          <select value={h.customer_id} onChange={(e) => setH({ ...h, customer_id: e.target.value, shipping_address: active.find((c) => c.id === e.target.value)?.address ?? '' })}>
            {active.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></label>
        <label className="field"><span>Outlet penjual</span>
          <select value={h.outlet_id} onChange={(e) => setH({ ...h, outlet_id: e.target.value, warehouse_id: '' })}>
            {m.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select></label>
        <label className="field"><span>Gudang kirim</span>
          <select value={h.warehouse_id || whs[0]?.id || ''} onChange={(e) => setH({ ...h, warehouse_id: e.target.value })}>
            {whs.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
        <label className="field"><span>Tanggal SO</span><input type="date" value={h.so_date} onChange={(e) => setH({ ...h, so_date: e.target.value })} /></label>
        <label className="field"><span>Tanggal kirim</span><input type="date" value={h.expected_date} onChange={(e) => setH({ ...h, expected_date: e.target.value })} /></label>
        <label className="field"><span>PPN (%)</span><input type="number" min={0} max={100} value={h.tax_pct} onChange={(e) => setH({ ...h, tax_pct: e.target.value })} /></label>
        <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alamat kirim</span><input value={h.shipping_address} onChange={(e) => setH({ ...h, shipping_address: e.target.value })} /></label>
      </div>
      <div className="table-wrap" style={{ marginTop: 14 }}>
        <table className="table">
          <thead><tr><th>Produk</th><th>Satuan</th><th>Qty</th><th>Harga</th><th className="right">Subtotal</th><th></th></tr></thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td><select style={{ width: '100%', minWidth: 170 }} value={l.item_id} onChange={(e) => upd(i, { item_id: e.target.value })}>
                  <option value="">— pilih produk —</option>
                  {m.items.map((it) => <option key={it.id} value={it.id}>{it.code} · {it.name}</option>)}
                </select></td>
                <td><select value={l.unit_id} onChange={(e) => upd(i, { unit_id: e.target.value })}>
                  {unitOptions(m, l.item_id).map((u) => <option key={u.unit_id} value={u.unit_id}>{u.code}</option>)}
                </select></td>
                <td><input type="number" step="any" min={0} style={{ width: 90 }} value={l.quantity} onChange={(e) => upd(i, { quantity: e.target.value })} /></td>
                <td><MoneyInput value={l.unit_price} style={{ width: 120 }} onChange={(v) => upd(i, { unit_price: v })} /></td>
                <td className="right">{formatRupiah(Number(l.quantity || 0) * Number(l.unit_price || 0))}</td>
                <td>{l.item_id && <button className="icon-btn" aria-label="Hapus" onClick={() => setLines(lines.filter((_, j) => j !== i))}><Trash2 size={16} /></button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted small">Harga otomatis dari Pricelist Jual (pelanggan ini → semua pelanggan), bisa diubah selama draft. PPN {formatRupiah(tax)}.</p>
    </Modal>
  );
}

// ---------------------------------------------------------------- Detail SO
interface SoItem { id: string; quantity: number; delivered_qty: number; unit_price: number; line_total: number; inv_items: { code: string; name: string }; inv_units: { code: string } }
interface DelRow { id: string; delivery_number: string | null; delivery_date: string; status: string; inv_warehouses: { name: string } }
interface InvRow { id: string; invoice_number: string; invoice_date: string; grand_total: number; status: string }

export function SalesOrderDetail({ m, soId, onClose }: { m: SalesMaster; soId: string; onClose: () => void }) {
  const { toast, confirm, prompt } = useFeedback();
  const [so, setSo] = useState<SoRow & { subtotal: number; tax_amount: number; shipping_address: string | null } | null>(null);
  const [items, setItems] = useState<SoItem[]>([]);
  const [dels, setDels] = useState<DelRow[]>([]);
  const [invs, setInvs] = useState<InvRow[]>([]);
  const [uninvoiced, setUninvoiced] = useState(0);
  const [delivery, setDelivery] = useState<string | null>(null);
  const [warehouse, setWarehouse] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const [s, i, d, v] = await Promise.all([
      must(supabase.from('sal_sales_orders').select(SO_SELECT).eq('id', soId).single()),
      must(supabase.from('sal_sales_order_items').select('id, quantity, delivered_qty, unit_price, line_total, inv_items(code, name), inv_units(code)').eq('sales_order_id', soId).order('created_at')),
      must(supabase.from('sal_deliveries').select('id, delivery_number, delivery_date, status, inv_warehouses(name), sal_delivery_items(quantity, invoiced_qty)').eq('sales_order_id', soId).order('created_at')),
      must(supabase.from('sal_invoices').select('id, invoice_number, invoice_date, grand_total, status').eq('sales_order_id', soId).order('created_at')),
    ]);
    setSo(s); setItems(i); setDels(d); setInvs(v);
    setWarehouse((w) => w || s.warehouse_id || m.warehouses.find((x) => x.outlet_id === s.outlet_id)?.id || '');
    setUninvoiced((d as (DelRow & { sal_delivery_items: { quantity: number; invoiced_qty: number }[] })[])
      .filter((x) => x.status === 'shipped' || x.status === 'received')
      .reduce((t, x) => t + x.sal_delivery_items.reduce((a, y) => a + Number(y.quantity) - Number(y.invoiced_qty), 0), 0));
  }, [soId, m.warehouses]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const run = async (fn: () => Promise<unknown>, msg?: string) => {
    setBusy(true);
    try { await fn(); if (msg) toast(msg); await load(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  if (!so) return <Modal title="Sales Order" onClose={onClose}><div className="empty">Memuat…</div></Modal>;
  const [label, cls] = SO_STATUS[so.status] ?? [so.status, 'badge'];
  const open = ['confirmed', 'partially_delivered'].includes(so.status);
  const remaining = items.some((i) => Number(i.delivered_qty) < Number(i.quantity));
  const sellerWhs = m.warehouses.filter((w) => w.outlet_id === so.outlet_id);

  return (
    <Modal title={`Sales Order ${so.so_number ?? '(draft)'}`} onClose={onClose} large
      footer={<>
        {['draft', 'new', 'confirmed'].includes(so.status) && !dels.length && (
          <button className="btn-danger" style={{ marginRight: 'auto' }} disabled={busy} onClick={async () => {
            const reason = await prompt({ title: so.customer_type === 'internal' ? 'Tolak SO cabang' : 'Batalkan SO', label: 'Alasan', required: true,
              placeholder: 'mis. stok kosong', confirmLabel: 'Tolak' });
            if (reason) run(() => rpc('sal_reject_sales_order', { p_id: so.id, p_reason: reason }), 'Sales order ditolak, PO pembeli dibatalkan');
          }}><XCircle size={16} /> {so.customer_type === 'internal' ? 'Tolak' : 'Batalkan'}</button>
        )}
        {open && (
          <button disabled={busy} onClick={async () => {
            const reason = await prompt({ title: 'Tutup sales order?', label: 'Alasan (opsional)', placeholder: 'mis. sisa tidak bisa dipenuhi', confirmLabel: 'Tutup SO' });
            if (reason !== null) run(() => rpc('sal_close_sales_order', { p_id: so.id, p_reason: reason }), 'Sales order ditutup');
          }}><Lock size={16} /> Tutup SO</button>
        )}
        {uninvoiced > 0 && (
          <button disabled={busy} onClick={async () => {
            if (await confirm({ title: 'Buat invoice?', message: 'Semua barang yang sudah dikirim & belum ditagih akan dimasukkan ke 1 invoice (qty dikirim).', confirmLabel: 'Buat invoice' })) {
              run(async () => { const r = await rpc<{ invoice_number: string }>('sal_create_invoice', { p_so_id: so.id }); toast(`Invoice ${r.invoice_number} dibuat`); });
            }
          }}><FileText size={16} /> Buat invoice</button>
        )}
        {['draft', 'new'].includes(so.status) && (
          <button className="btn-primary" disabled={busy} onClick={() => run(() => rpc('sal_confirm_sales_order', { p_id: so.id }), 'Sales order dikonfirmasi')}>
            <CheckCircle2 size={16} /> Konfirmasi</button>
        )}
        {open && remaining && (
          <button className="btn-primary" disabled={busy || !warehouse} onClick={() => run(async () => {
            setDelivery(await rpc<string>('sal_create_delivery', { p_so_id: so.id, p_warehouse_id: warehouse }));
          })}><Truck size={16} /> Buat pengiriman</button>
        )}
      </>}>
      <div className="row" style={{ gap: 10, marginBottom: 12 }}>
        <span className={`badge ${cls}`}>{label}</span>
        <b>{so.seller?.name} → {so.customer_type === 'internal' ? so.buyer?.name : so.sal_customers?.name}</b>
        <span className="muted small">{so.so_date}{so.pur_purchase_orders ? ` · dari PO ${so.pur_purchase_orders.po_number}` : ''}{so.expected_date ? ` · kirim ${so.expected_date}` : ''}</span>
      </div>
      {so.reject_reason && <div className="alert alert-error small">Alasan: {so.reject_reason}</div>}
      {so.status === 'new' && <div className="alert alert-info small">SO dari cabang. Cek stok lalu <b>Konfirmasi</b>, atau <b>Tolak</b> dengan alasan (PO pembeli otomatis batal).</div>}
      {open && remaining && sellerWhs.length > 1 && (
        <label className="field" style={{ maxWidth: 320 }}><span>Kirim dari gudang</span>
          <select value={warehouse} onChange={(e) => setWarehouse(e.target.value)}>
            {sellerWhs.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
      )}
      <div className="table-wrap" style={{ marginTop: 10 }}>
        <table className="table">
          <thead><tr><th>Produk</th><th className="right">Dipesan</th><th className="right">Dikirim</th><th className="right">Harga</th><th className="right">Subtotal</th></tr></thead>
          <tbody>
            {items.map((i) => (
              <tr key={i.id}>
                <td><b>{i.inv_items.code}</b> · {i.inv_items.name}</td>
                <td className="right">{formatNumber(i.quantity)} {i.inv_units.code}</td>
                <td className="right" style={{ color: Number(i.delivered_qty) >= Number(i.quantity) ? 'var(--success)' : undefined }}>{formatNumber(i.delivered_qty)}</td>
                <td className="right">{formatRupiah(i.unit_price)}</td>
                <td className="right">{formatRupiah(i.line_total)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="row" style={{ justifyContent: 'flex-end', gap: 18, marginTop: 6 }}>
        <span className="muted">Subtotal {formatRupiah(so.subtotal)}</span>
        {Number(so.tax_amount) > 0 && <span className="muted">PPN {formatRupiah(so.tax_amount)}</span>}
        <b>Total {formatRupiah(so.grand_total)}</b>
      </div>

      {!!dels.length && <>
        <div className="section-title">Pengiriman</div>
        {dels.map((d) => {
          const [dl, dc] = DELIVERY_STATUS[d.status] ?? [d.status, 'badge'];
          return (
            <div key={d.id} className="row list-row" onClick={() => setDelivery(d.id)}>
              <b>{d.delivery_number ?? '(draft)'}</b><span className="muted small">{d.delivery_date} · {d.inv_warehouses.name}</span>
              <span className={`badge ${dc}`} style={{ marginLeft: 'auto' }}>{dl}</span>
            </div>
          );
        })}
      </>}
      {!!invs.length && <>
        <div className="section-title">Invoice</div>
        {invs.map((v) => {
          const [il, ic] = INVOICE_STATUS[v.status] ?? [v.status, 'badge'];
          return (
            <div key={v.id} className="row list-row">
              <b>{v.invoice_number}</b><span className="muted small">{v.invoice_date}</span>
              <span style={{ marginLeft: 'auto' }}>{formatRupiah(v.grand_total)}</span><span className={`badge ${ic}`}>{il}</span>
            </div>
          );
        })}
      </>}
      {delivery && <DeliveryDetail m={m} deliveryId={delivery} onClose={() => { setDelivery(null); load(); }} />}
    </Modal>
  );
}
