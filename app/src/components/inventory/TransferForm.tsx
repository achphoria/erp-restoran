import { useEffect, useState } from 'react';
import { Package, Plus, Send, Trash2, Truck } from 'lucide-react';
import Modal from '../Modal';
import ScanInput from '../ScanInput';
import BatchSelect from './BatchSelect';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatNumber } from '../../lib/format';
import { loadBatches, resolveBarcode, type BatchOption } from './batchUtils';

interface Warehouse { id: string; name: string }
interface Item { id: string; code: string; name: string; inv_units?: { code: string } }
interface TLine { item_id: string; batch_id: string; quantity: string }
const EMPTY: TLine = { item_id: '', batch_id: '', quantity: '' };

// Transfer gudang per koli: isi barang per koli (scan), lalu kirim (dalam perjalanan) atau langsung terima
export default function TransferForm({ companyId, warehouses, items, onClose, onDone }: {
  companyId: string; warehouses: Warehouse[]; items: Item[]; onClose: () => void; onDone: (transferId?: string) => void;
}) {
  const { toast } = useFeedback();
  const [from, setFrom] = useState(warehouses[0]?.id ?? '');
  const [to, setTo] = useState(warehouses[1]?.id ?? '');
  const [note, setNote] = useState('');
  const [koli, setKoli] = useState<TLine[][]>([[EMPTY]]);
  const [active, setActive] = useState(0);
  const [batches, setBatches] = useState<BatchOption[]>([]);
  const [stock, setStock] = useState<Record<string, number>>({});
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!from) return;
    loadBatches(from).then(setBatches).catch(() => setBatches([]));
    must(supabase.from('rpt_stock_balances').select('item_id, quantity').eq('warehouse_id', from))
      .then((r: { item_id: string; quantity: number }[]) => setStock(Object.fromEntries(r.map((x) => [x.item_id, Number(x.quantity)]))))
      .catch(() => setStock({}));
  }, [from]);

  const unit = (id: string) => items.find((i) => i.id === id)?.inv_units?.code ?? '';
  const withBlank = (ls: TLine[]) => (ls.length && !ls[ls.length - 1].item_id ? ls : [...ls, EMPTY]);
  const setLines = (k: number, fn: (ls: TLine[]) => TLine[]) => setKoli((all) => all.map((ls, i) => (i === k ? withBlank(fn(ls)) : ls)));
  const valid = (ls: TLine[]) => ls.filter((l) => l.item_id && Number(l.quantity) > 0);
  const total = koli.reduce((s, ls) => s + valid(ls).length, 0);

  const onScan = async (code: string) => {
    try {
      const r = await resolveBarcode(code, from);
      if (!r || r.kind === 'package' || r.kind === 'delivery_package') return toast(r ? 'Ini label koli, bukan barang' : `Kode ${code} tidak dikenal`, 'error');
      if (!items.some((i) => i.id === r.item_id)) return toast(`${r.item_name} tidak ada di daftar produk stok`, 'error');
      if (r.kind === 'batch' && r.warehouse_id !== from) return toast(`Batch ${r.batch_code} tidak ada di gudang asal`, 'error');
      const batchId = r.kind === 'batch' ? r.batch_id! : '';
      const add = r.kind === 'item' ? Number(r.qty) : 1;
      setLines(active, (ls) => {
        const body = ls.filter((l) => l.item_id);
        const idx = body.findIndex((l) => l.item_id === r.item_id && l.batch_id === batchId);
        if (idx >= 0) body[idx] = { ...body[idx], quantity: String(Number(body[idx].quantity || 0) + add) };
        else body.push({ item_id: r.item_id!, batch_id: batchId, quantity: String(add) });
        return body;
      });
      toast(`${r.item_name} +${formatNumber(add)} ke koli ${active + 1}`, 'info');
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const submit = async (mode: 'draft' | 'ship' | 'post') => {
    setBusy(true);
    try {
      const doc = (await must(supabase.from('inv_stock_transfers').insert({
        company_id: companyId, from_warehouse_id: from, to_warehouse_id: to, note: note.trim() || null,
      }).select('id').single())) as { id: string };
      let no = 0;
      for (const ls of koli) {
        const lines = valid(ls);
        if (!lines.length) continue;
        const pkg = (await must(supabase.from('inv_transfer_packages').insert({ company_id: companyId, stock_transfer_id: doc.id, package_no: ++no })
          .select('id').single())) as { id: string };
        await must(supabase.from('inv_stock_transfer_items').insert(lines.map((l) => ({
          company_id: companyId, stock_transfer_id: doc.id, package_id: pkg.id, item_id: l.item_id,
          batch_id: l.batch_id || null, quantity: Number(l.quantity),
        }))));
      }
      if (mode === 'ship') await rpc('inv_ship_stock_transfer', { p_id: doc.id });
      if (mode === 'post') await rpc('inv_post_stock_transfer', { p_id: doc.id });
      const st = mode === 'draft' ? null : (await must(supabase.from('inv_stock_transfers').select('status').eq('id', doc.id).single())).status;
      if (st === 'pending_approval') toast('Transfer menunggu persetujuan. Barang dikirim setelah disetujui.', 'info');
      else toast(mode === 'draft' ? 'Draft transfer tersimpan' : mode === 'ship'
        ? `${no} koli dikirim. Cetak label koli lalu tempel di tiap koli.` : 'Transfer selesai, stok sudah pindah');
      onDone(doc.id);
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  const disabled = busy || !total || !from || !to || from === to;
  return (
    <Modal title="Transfer Gudang" onClose={onClose} large
      footer={<>
        <button onClick={onClose} style={{ marginRight: 'auto' }}>Batal</button>
        <button disabled={disabled} onClick={() => submit('draft')}>Simpan draft</button>
        <button disabled={disabled} onClick={() => submit('post')} title="Untuk gudang di lokasi yang sama"><Send size={16} /> Kirim & langsung terima</button>
        <button className="btn-primary" disabled={disabled} onClick={() => submit('ship')}><Truck size={16} /> Kirim (dalam perjalanan)</button>
      </>}>
      <div className="form-grid">
        <label className="field"><span>Dari gudang</span>
          <select value={from} onChange={(e) => { setFrom(e.target.value); setKoli(koli.map((ls) => ls.map((l) => ({ ...l, batch_id: '' })))); }}>
            {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
        <label className="field"><span>Ke gudang</span>
          <select value={to} onChange={(e) => setTo(e.target.value)}>
            <option value="">— pilih —</option>
            {warehouses.filter((w) => w.id !== from).map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select></label>
        <label className="field"><span>Catatan / kendaraan</span><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="mis. Motor box - Andi" /></label>
      </div>

      <ScanInput onScan={onScan} placeholder={`Scan barcode / label batch → masuk Koli ${active + 1}`} style={{ marginTop: 14 }} />

      {koli.map((ls, k) => (
        <div key={k} className={`koli-card ${k === active ? 'active' : ''}`} onClick={() => setActive(k)}>
          <div className="koli-head">
            <b><Package size={16} style={{ verticalAlign: -3 }} /> Koli {k + 1}</b>
            <span className="muted small">{valid(ls).length} barang{k === active ? ' · scan masuk ke sini' : ''}</span>
            {koli.length > 1 && (
              <button className="icon-btn" style={{ marginLeft: 'auto' }} aria-label="Hapus koli"
                onClick={(e) => { e.stopPropagation(); setKoli(koli.filter((_, i) => i !== k)); setActive(0); }}><Trash2 size={16} /></button>
            )}
          </div>
          <div className="table-wrap">
            <table className="table">
              <tbody>
                {ls.map((l, i) => {
                  const avail = stock[l.item_id] ?? 0;
                  const over = l.item_id && Number(l.quantity) > avail;
                  return (
                    <tr key={i}>
                      <td><select style={{ width: '100%', minWidth: 170 }} value={l.item_id}
                        onChange={(e) => setLines(k, (x) => x.map((y, j) => (j === i ? { ...y, item_id: e.target.value, batch_id: '' } : y)))}>
                        <option value="">— pilih produk —</option>
                        {items.map((it) => <option key={it.id} value={it.id}>{it.code} · {it.name}</option>)}
                      </select>
                        {l.item_id && <div className="small" style={{ color: over ? 'var(--danger)' : undefined }}>stok asal {formatNumber(avail)} {unit(l.item_id)}</div>}</td>
                      <td>{l.item_id && <BatchSelect batches={batches.filter((b) => b.item_id === l.item_id)} value={l.batch_id}
                        onChange={(v) => setLines(k, (x) => x.map((y, j) => (j === i ? { ...y, batch_id: v } : y)))} />}</td>
                      <td><div className="row" style={{ flexWrap: 'nowrap' }}>
                        <input type="number" step="any" min={0} style={{ width: 90 }} value={l.quantity}
                          onChange={(e) => setLines(k, (x) => x.map((y, j) => (j === i ? { ...y, quantity: e.target.value } : y)))} />
                        <span className="muted small">{unit(l.item_id)}</span></div></td>
                      <td>{l.item_id && <button className="icon-btn" aria-label="Hapus"
                        onClick={() => setLines(k, (x) => x.filter((_, j) => j !== i))}><Trash2 size={16} /></button>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      ))}
      <button className="btn-sm" style={{ marginTop: 10 }} onClick={() => { setKoli([...koli, [EMPTY]]); setActive(koli.length); }}><Plus size={14} /> Tambah koli</button>
      <p className="muted small">Batch "Otomatis" = FEFO (kedaluwarsa duluan). Batch, lot, kedaluwarsa & harga ikut pindah ke gudang tujuan.
        "Kirim" membuat stok berstatus <b>dalam perjalanan</b> sampai gudang tujuan scan & terima tiap koli.</p>
    </Modal>
  );
}
