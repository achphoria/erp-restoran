import { useCallback, useEffect, useState } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import Modal from './Modal';
import MoneyInput from './MoneyInput';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from './Feedback';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../lib/format';

interface Supplier { id: string; name: string }
interface Item { id: string; code: string; name: string; base_unit_id: string; inv_units: { code: string } }
interface ItemUnit { item_id: string; unit_id: string; conversion_qty: number; is_purchase_unit: boolean; inv_units: { code: string } }
interface Pricelist {
  id: string; pricelist_number: string | null; supplier_id: string; outlet_id: string | null; effective_date: string; expiry_date: string | null;
  status: string; notes: string | null; pur_suppliers: { name: string };
  pur_pricelist_items: { id: string; item_id: string; unit_id: string; conversion_qty: number; price: number }[];
}
interface Line { item_id: string; unit_key: string; price: string }

const STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge'], pending_approval: ['Menunggu persetujuan', 'badge-warning'], approved: ['Berlaku', 'badge-success'], cancelled: ['Batal', 'badge-danger'],
};

// Pricelist supplier: harga beli per produk & satuan dengan masa berlaku (per outlet atau semua)
export default function PricelistTab({ suppliers, items, itemUnits }: { suppliers: Supplier[]; items: Item[]; itemUnits: ItemUnit[] }) {
  const { profile, can } = useAuth();
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Pricelist[]>([]);
  const [editing, setEditing] = useState<Partial<Pricelist> | null>(null);

  const load = useCallback(async () => {
    setRows(await must(supabase.from('pur_pricelists').select('*, pur_suppliers(name), pur_pricelist_items(*)').order('effective_date', { ascending: false }).limit(100)));
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const today = todayISO();
  const isExpired = (p: Pricelist) => !!p.expiry_date && p.expiry_date < today;
  const outletName = (id: string | null) => (id ? profile!.outlets.find((o) => o.id === id)?.name ?? '?' : 'Semua outlet');

  const approve = async (p: Pricelist) => {
    try {
      const r = await rpc<{ pricelist_number?: string; pending_approval?: boolean }>('pur_approve_pricelist', { p_id: p.id });
      toast(r.pending_approval ? 'Pricelist dikirim ke atasan untuk disetujui' : `Pricelist ${r.pricelist_number} berlaku`);
      load();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" onClick={() => setEditing({ effective_date: today, status: 'draft', pur_pricelist_items: [] })}><Plus size={16} /> Pricelist Baru</button>
          <span className="muted small">Harga di pricelist yang berlaku otomatis dipakai saat membuat PO ke supplier tersebut.</span>
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Nomor</th><th>Supplier</th><th>Outlet</th><th>Berlaku</th><th className="right">Item</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {rows.map((p) => {
              const [label, badge] = isExpired(p) && p.status === 'approved' ? ['Kedaluwarsa', 'badge'] : STATUS[p.status] ?? [p.status, 'badge'];
              return (
                <tr key={p.id}>
                  <td className="bold">{p.pricelist_number ?? '(draft)'}</td>
                  <td>{p.pur_suppliers.name}</td>
                  <td className="small">{outletName(p.outlet_id)}</td>
                  <td className="small">{p.effective_date} s/d {p.expiry_date ?? 'seterusnya'}</td>
                  <td className="right">{p.pur_pricelist_items.length}</td>
                  <td><span className={`badge ${badge}`}>{label}</span></td>
                  <td className="right">
                    <div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                      {p.status === 'draft' && <button className="btn-sm" onClick={() => setEditing(p)}>Edit</button>}
                      {(p.status === 'draft' || (p.status === 'pending_approval' && can('approval.pricelist'))) && <button className="btn-sm btn-primary" onClick={() => approve(p)}>Berlakukan</button>}
                      {p.status === 'approved' && <button className="btn-sm" onClick={() => setEditing({ ...p, id: undefined, pricelist_number: null, status: 'draft', effective_date: today, expiry_date: null })}>Salin</button>}
                    </div>
                  </td>
                </tr>
              );
            })}
            {!rows.length && <tr><td colSpan={7} className="empty">Belum ada pricelist.</td></tr>}
          </tbody>
        </table>
      </div>
      {editing && <PricelistForm pricelist={editing} suppliers={suppliers} items={items} itemUnits={itemUnits}
        onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load(); }} />}
    </>
  );
}

function PricelistForm({ pricelist, suppliers, items, itemUnits, onClose, onSaved }: {
  pricelist: Partial<Pricelist>; suppliers: Supplier[]; items: Item[]; itemUnits: ItemUnit[]; onClose: () => void; onSaved: () => void;
}) {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [p, setP] = useState<Partial<Pricelist>>({ supplier_id: suppliers[0]?.id, ...pricelist });
  const unitsOf = (itemId: string) => itemUnits.filter((u) => u.item_id === itemId)
    .sort((a, b) => Number(b.is_purchase_unit) - Number(a.is_purchase_unit));
  const [lines, setLines] = useState<Line[]>(() => (pricelist.pur_pricelist_items ?? []).map((i) => ({
    item_id: i.item_id, unit_key: `${i.unit_id}|${i.conversion_qty}`, price: String(Number(i.price)) })).concat([{ item_id: '', unit_key: '', price: '' }]));
  const [busy, setBusy] = useState(false);

  const upd = (idx: number, patch: Partial<Line>) => setLines((ls) => {
    const next = ls.map((l, i) => (i === idx ? { ...l, ...patch } : l));
    if (patch.item_id !== undefined) {
      const u = unitsOf(patch.item_id)[0];
      next[idx].unit_key = u ? `${u.unit_id}|${u.conversion_qty}` : '';
    }
    // selalu sisakan satu baris kosong di bawah
    if (next[next.length - 1].item_id) next.push({ item_id: '', unit_key: '', price: '' });
    return next;
  });

  const valid = lines.filter((l) => l.item_id && l.unit_key && l.price !== '');
  const dup = valid.find((l, i) => valid.findIndex((x) => x.item_id === l.item_id && x.unit_key === l.unit_key) !== i);

  const save = async () => {
    setBusy(true);
    try {
      const row = { company_id: profile!.company_id, supplier_id: p.supplier_id, outlet_id: p.outlet_id || null,
        effective_date: p.effective_date, expiry_date: p.expiry_date || null, notes: p.notes?.trim() || null };
      const saved = (await must(p.id
        ? supabase.from('pur_pricelists').update(row).eq('id', p.id).select('id').single()
        : supabase.from('pur_pricelists').insert(row).select('id').single())) as { id: string };
      await must(supabase.from('pur_pricelist_items').delete().eq('pricelist_id', saved.id));
      await must(supabase.from('pur_pricelist_items').insert(valid.map((l) => {
        const [unit_id, conv] = l.unit_key.split('|');
        return { company_id: profile!.company_id, pricelist_id: saved.id, item_id: l.item_id, unit_id, conversion_qty: Number(conv), price: Number(l.price) };
      })));
      toast('Pricelist disimpan sebagai draft. Klik "Berlakukan" untuk mengaktifkan.');
      onSaved();
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <Modal title={p.id ? 'Edit Pricelist' : 'Pricelist Baru'} onClose={onClose} large
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !valid.length || !!dup || !p.supplier_id} onClick={save}>Simpan Draft</button></>}>
      {dup && <div className="alert alert-error">Ada produk & satuan yang dobel.</div>}
      <div className="form-grid">
        <label className="field"><span>Supplier</span>
          <select value={p.supplier_id} onChange={(e) => setP({ ...p, supplier_id: e.target.value })}>
            {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select></label>
        <label className="field"><span>Outlet</span>
          <select value={p.outlet_id ?? ''} onChange={(e) => setP({ ...p, outlet_id: e.target.value || null })}>
            <option value="">Semua outlet</option>
            {profile!.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select></label>
        <label className="field"><span>Berlaku mulai</span><input type="date" value={p.effective_date ?? ''} onChange={(e) => setP({ ...p, effective_date: e.target.value })} /></label>
        <label className="field"><span>Sampai (kosong = seterusnya)</span><input type="date" min={p.effective_date} value={p.expiry_date ?? ''} onChange={(e) => setP({ ...p, expiry_date: e.target.value || null })} /></label>
      </div>
      <div className="table-wrap" style={{ marginTop: 14 }}>
        <table className="table">
          <thead><tr><th>Produk</th><th>Satuan</th><th>Harga</th><th></th></tr></thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td><select style={{ width: '100%', minWidth: 180 }} value={l.item_id} onChange={(e) => upd(i, { item_id: e.target.value })}>
                  <option value="">— pilih produk —</option>
                  {items.map((x) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}
                </select></td>
                <td><select value={l.unit_key} onChange={(e) => upd(i, { unit_key: e.target.value })}>
                  {unitsOf(l.item_id).map((u) => <option key={u.unit_id} value={`${u.unit_id}|${u.conversion_qty}`}>{u.inv_units.code}</option>)}
                </select></td>
                <td><MoneyInput value={l.price} onChange={(v) => upd(i, { price: v })} style={{ width: 130 }} /></td>
                <td>{l.item_id && <button className="icon-btn" onClick={() => setLines(lines.filter((_, j) => j !== i))} aria-label="Hapus"><Trash2 size={16} /></button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted small">Bila ada beberapa pricelist berlaku, yang khusus outlet didahulukan, lalu tanggal mulai terbaru. Total: {valid.length} produk · {formatRupiah(valid.reduce((s, l) => s + Number(l.price), 0))}</p>
    </Modal>
  );
}
