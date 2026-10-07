import { useCallback, useEffect, useState } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../../lib/format';
import { unitOptions, type SalesMaster } from './salesShared';

interface Pricelist {
  id: string; name: string; seller_outlet_id: string | null; buyer_outlet_id: string | null; customer_id: string | null;
  valid_from: string; valid_to: string | null; notes: string | null; is_active: boolean; sal_pricelist_items: { count: number }[];
}
interface PItem { id?: string; item_id: string; unit_id: string; price: string }

// Harga jual untuk Sales Order: per penjual, per cabang pembeli / pelanggan B2B, dengan masa berlaku
export default function SalesPricelistsTab({ m }: { m: SalesMaster }) {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Pricelist[]>([]);
  const [editing, setEditing] = useState<Partial<Pricelist> | null>(null);

  const load = useCallback(async () => {
    setRows(await must(supabase.from('sal_pricelists').select('*, sal_pricelist_items(count)').order('is_active', { ascending: false }).order('valid_from', { ascending: false })));
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const outlet = (id: string | null) => m.outlets.find((o) => o.id === id)?.name;
  const scope = (p: Partial<Pricelist>) => p.buyer_outlet_id ? `Cabang ${outlet(p.buyer_outlet_id)}` : p.customer_id ? m.customers.find((c) => c.id === p.customer_id)?.name : 'Semua pembeli';

  return (
    <div className="card table-wrap">
      <div className="filter-bar">
        <span className="muted small">Harga dipilih dari pricelist paling spesifik (pembeli tertentu → semua pembeli) yang masih berlaku. PO cabang memakai harga ini & tidak bisa diubah pembeli.</span>
        <button className="btn-primary" style={{ marginLeft: 'auto' }} onClick={() => setEditing({ name: '', valid_from: todayISO(), is_active: true, seller_outlet_id: null })}>
          <Plus size={16} /> Pricelist</button>
      </div>
      <table className="table">
        <thead><tr><th>Nama</th><th>Penjual</th><th>Berlaku untuk</th><th>Periode</th><th className="right">Produk</th><th></th></tr></thead>
        <tbody>
          {rows.map((p) => (
            <tr key={p.id} style={{ opacity: p.is_active ? 1 : 0.5, cursor: 'pointer' }} onClick={() => setEditing(p)}>
              <td className="bold">{p.name}</td>
              <td>{outlet(p.seller_outlet_id) ?? 'Semua outlet'}</td>
              <td>{scope(p)}</td>
              <td className="small">{p.valid_from} – {p.valid_to ?? 'seterusnya'}</td>
              <td className="right">{p.sal_pricelist_items[0]?.count ?? 0}</td>
              <td>{!p.is_active && <span className="badge">Nonaktif</span>}</td>
            </tr>
          ))}
          {!rows.length && <tr><td colSpan={6} className="empty">Belum ada pricelist jual. Buat dulu supaya cabang lain bisa membuat PO ke outlet penjual.</td></tr>}
        </tbody>
      </table>
      {editing && <PricelistEditor m={m} pricelist={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load(); }} />}
    </div>
  );
}

function PricelistEditor({ m, pricelist, onClose, onSaved }: { m: SalesMaster; pricelist: Partial<Pricelist>; onClose: () => void; onSaved: () => void }) {
  const { toast } = useFeedback();
  const [h, setH] = useState(pricelist);
  const [target, setTarget] = useState(pricelist.buyer_outlet_id ? `o:${pricelist.buyer_outlet_id}` : pricelist.customer_id ? `c:${pricelist.customer_id}` : '');
  const [items, setItems] = useState<PItem[]>([{ item_id: '', unit_id: '', price: '' }]);
  const [removed, setRemoved] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!pricelist.id) return;
    must(supabase.from('sal_pricelist_items').select('id, item_id, unit_id, price').eq('pricelist_id', pricelist.id))
      .then((r: { id: string; item_id: string; unit_id: string; price: number }[]) =>
        setItems([...r.map((x) => ({ ...x, price: String(Number(x.price)) })), { item_id: '', unit_id: '', price: '' }]))
      .catch((e) => toast(errorMessage(e), 'error'));
  }, [pricelist.id, toast]);

  const upd = (i: number, patch: Partial<PItem>) => setItems((ls) => {
    const next = ls.map((l, j) => (j === i ? { ...l, ...patch, ...(patch.item_id !== undefined ? { unit_id: unitOptions(m, patch.item_id)[0]?.unit_id ?? '' } : {}) } : l));
    if (next[next.length - 1].item_id) next.push({ item_id: '', unit_id: '', price: '' });
    return next;
  });
  const valid = items.filter((l) => l.item_id && l.unit_id && l.price !== '');

  const save = async () => {
    setBusy(true);
    try {
      const row = { company_id: m.companyId, name: h.name!.trim(), seller_outlet_id: h.seller_outlet_id || null,
        buyer_outlet_id: target.startsWith('o:') ? target.slice(2) : null, customer_id: target.startsWith('c:') ? target.slice(2) : null,
        valid_from: h.valid_from, valid_to: h.valid_to || null, notes: h.notes?.trim() || null, is_active: h.is_active ?? true };
      const p = (await must(h.id ? supabase.from('sal_pricelists').update(row).eq('id', h.id).select('id').single()
        : supabase.from('sal_pricelists').insert(row).select('id').single())) as { id: string };
      if (removed.length) await must(supabase.from('sal_pricelist_items').delete().in('id', removed));
      for (const l of valid) {
        const r = { company_id: m.companyId, pricelist_id: p.id, item_id: l.item_id, unit_id: l.unit_id, price: Number(l.price) };
        await must(l.id ? supabase.from('sal_pricelist_items').update(r).eq('id', l.id) : supabase.from('sal_pricelist_items').insert(r));
      }
      toast('Pricelist disimpan');
      onSaved();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Produk + satuan yang sama muncul dua kali' : errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <Modal title={h.id ? `Pricelist: ${h.name}` : 'Pricelist Jual Baru'} onClose={onClose} large
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !h.name?.trim() || !h.valid_from} onClick={save}>Simpan</button></>}>
      <div className="form-grid">
        <label className="field"><span>Nama *</span><input value={h.name ?? ''} placeholder="mis. Harga Supply Chain 2026" onChange={(e) => setH({ ...h, name: e.target.value })} /></label>
        <label className="field"><span>Outlet penjual</span>
          <select value={h.seller_outlet_id ?? ''} onChange={(e) => setH({ ...h, seller_outlet_id: e.target.value || null })}>
            <option value="">Semua outlet</option>
            {m.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select></label>
        <label className="field"><span>Berlaku untuk</span>
          <select value={target} onChange={(e) => setTarget(e.target.value)}>
            <option value="">Semua pembeli</option>
            <optgroup label="Cabang tertentu">{m.outlets.map((o) => <option key={o.id} value={`o:${o.id}`}>{o.name}</option>)}</optgroup>
            <optgroup label="Pelanggan B2B">{m.customers.map((c) => <option key={c.id} value={`c:${c.id}`}>{c.name}</option>)}</optgroup>
          </select></label>
        <label className="field"><span>Berlaku dari</span><input type="date" value={h.valid_from ?? ''} onChange={(e) => setH({ ...h, valid_from: e.target.value })} /></label>
        <label className="field"><span>Sampai (kosong = seterusnya)</span><input type="date" value={h.valid_to ?? ''} onChange={(e) => setH({ ...h, valid_to: e.target.value || null })} /></label>
        <label className="field"><span>Catatan</span><input value={h.notes ?? ''} onChange={(e) => setH({ ...h, notes: e.target.value })} /></label>
      </div>
      <label className="switch" style={{ marginTop: 10 }}><input type="checkbox" checked={h.is_active ?? true} onChange={(e) => setH({ ...h, is_active: e.target.checked })} /><span>Aktif</span></label>
      <div className="table-wrap" style={{ marginTop: 12, maxHeight: '45vh', overflowY: 'auto' }}>
        <table className="table">
          <thead><tr><th>Produk</th><th>Satuan</th><th>Harga jual</th><th></th></tr></thead>
          <tbody>
            {items.map((l, i) => (
              <tr key={l.id ?? `n${i}`}>
                <td><select style={{ width: '100%', minWidth: 170 }} value={l.item_id} onChange={(e) => upd(i, { item_id: e.target.value })}>
                  <option value="">— pilih produk —</option>
                  {m.items.map((it) => <option key={it.id} value={it.id}>{it.code} · {it.name}</option>)}
                </select></td>
                <td><select value={l.unit_id} onChange={(e) => upd(i, { unit_id: e.target.value })}>
                  {unitOptions(m, l.item_id).map((u) => <option key={u.unit_id} value={u.unit_id}>{u.code}{u.conversion !== 1 ? ` (${u.conversion})` : ''}</option>)}
                </select></td>
                <td><MoneyInput value={l.price} style={{ width: 130 }} onChange={(v) => upd(i, { price: v })} /></td>
                <td>{l.item_id && <button className="icon-btn" aria-label="Hapus" onClick={() => { if (l.id) setRemoved([...removed, l.id]); setItems(items.filter((_, j) => j !== i)); }}><Trash2 size={16} /></button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted small">Cukup isi 1 satuan per produk; satuan lain dihitung otomatis dari konversi (mis. harga per kg → per gram). {valid.length} produk, contoh: {valid[0] ? formatRupiah(Number(valid[0].price)) : '-'}.</p>
    </Modal>
  );
}
