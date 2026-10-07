import { useCallback, useEffect, useState } from 'react';
import { Package, Plus, SlidersHorizontal, Trash2 } from 'lucide-react';
import Modal from './Modal';
import MoneyInput from './MoneyInput';
import { useFeedback } from './Feedback';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah } from '../lib/format';

interface Option {
  id?: string; name: string; extra_price: number | string; sort_order: number; is_default: boolean;
  menu_item_id: string | null; item_id: string | null; item_qty: number | string | null;
}
interface Group { id: string; name: string; group_type: 'modifier' | 'package'; min_select: number; max_select: number; mst_modifiers: Option[] }

// Grup modifier biasa (level pedas, topping) & grup PAKET (isi = menu sungguhan, stok resepnya ikut terpotong)
export default function ModifierGroupsTab({ companyId }: { companyId: string }) {
  const { toast } = useFeedback();
  const [groups, setGroups] = useState<Group[]>([]);
  const [menus, setMenus] = useState<{ id: string; code: string; name: string }[]>([]);
  const [items, setItems] = useState<{ id: string; code: string; name: string; inv_units: { code: string } }[]>([]);
  const [usage, setUsage] = useState<Record<string, number>>({});
  const [editing, setEditing] = useState<Partial<Group> | null>(null);

  const load = useCallback(async () => {
    const [g, m, i, l] = await Promise.all([
      must(supabase.from('mst_modifier_groups').select('*, mst_modifiers(*)').order('group_type').order('name')),
      must(supabase.from('mst_menu_items').select('id, code, name').eq('is_active', true).order('name')),
      must(supabase.from('inv_items').select('id, code, name, inv_units(code)').eq('is_active', true).eq('approval_status', 'approved').order('name')).catch(() => []),
      must(supabase.from('mst_menu_item_modifier_groups').select('modifier_group_id')),
    ]);
    setGroups(g); setMenus(m); setItems(i);
    setUsage((l as { modifier_group_id: string }[]).reduce<Record<string, number>>((acc, x) => ({ ...acc, [x.modifier_group_id]: (acc[x.modifier_group_id] ?? 0) + 1 }), {}));
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const linkLabel = (o: Option) => o.menu_item_id ? `isi: ${menus.find((m) => m.id === o.menu_item_id)?.name ?? '?'}`
    : o.item_id ? `bahan: ${Number(o.item_qty)} ${items.find((i) => i.id === o.item_id)?.inv_units.code ?? ''} ${items.find((i) => i.id === o.item_id)?.name ?? ''}` : '';

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" onClick={() => setEditing({ group_type: 'modifier', min_select: 0, max_select: 1, mst_modifiers: [] })}><SlidersHorizontal size={16} /> Grup Modifier</button>
          <button onClick={() => setEditing({ group_type: 'package', min_select: 1, max_select: 1, mst_modifiers: [] })}><Package size={16} /> Grup Paket</button>
          <span className="muted small">Hubungkan grup ke menu lewat form Edit Menu → "Grup modifier yang berlaku".</span>
        </div>
      </div>
      <div className="grid grid-2">
        {groups.map((g) => (
          <div key={g.id} className="card" onClick={() => setEditing(g)} style={{ cursor: 'pointer' }}>
            <div className="card-header">
              <h3>{g.group_type === 'package' ? <Package size={16} style={{ verticalAlign: -3 }} /> : <SlidersHorizontal size={16} style={{ verticalAlign: -3 }} />} {g.name}</h3>
              <span className={`badge ${g.group_type === 'package' ? 'badge-primary' : 'badge-info'}`}>{g.group_type === 'package' ? 'Paket' : 'Modifier'}</span>
            </div>
            <div className="muted small" style={{ marginBottom: 8 }}>
              Pilih {g.min_select > 0 ? `min ${g.min_select}` : 'opsional'}, maks {g.max_select} · dipakai {usage[g.id] ?? 0} menu
            </div>
            {[...g.mst_modifiers].sort((a, b) => a.sort_order - b.sort_order).map((o) => (
              <div key={o.id} className="sum-row small" style={{ padding: '3px 0' }}>
                <span>{o.is_default && '★ '}{o.name} <span className="muted">{linkLabel(o)}</span></span>
                <span>{Number(o.extra_price) ? `+${formatRupiah(o.extra_price)}` : 'gratis'}</span>
              </div>
            ))}
            {!g.mst_modifiers.length && <div className="muted small">Belum ada pilihan.</div>}
          </div>
        ))}
      </div>
      {editing && <GroupForm companyId={companyId} group={editing} menus={menus} items={items}
        onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load(); }} />}
    </>
  );
}

function GroupForm({ companyId, group, menus, items, onClose, onSaved }: {
  companyId: string; group: Partial<Group>; menus: { id: string; code: string; name: string }[];
  items: { id: string; code: string; name: string; inv_units: { code: string } }[]; onClose: () => void; onSaved: () => void;
}) {
  const { toast, confirm } = useFeedback();
  const [g, setG] = useState<Partial<Group>>(group);
  const [opts, setOpts] = useState<Option[]>(() => [...(group.mst_modifiers ?? [])].sort((a, b) => a.sort_order - b.sort_order));
  const [busy, setBusy] = useState(false);
  const isPackage = g.group_type === 'package';
  const upd = (i: number, patch: Partial<Option>) => setOpts(opts.map((o, j) => {
    if (j === i) return { ...o, ...patch };
    // grup pilih-satu: hanya satu default
    if (patch.is_default && Number(g.max_select) === 1) return { ...o, is_default: false };
    return o;
  }));

  const save = async () => {
    if (Number(g.max_select) < Number(g.min_select)) return toast('Maksimal tidak boleh lebih kecil dari minimal', 'error');
    if (isPackage && opts.some((o) => o.name.trim() && !o.menu_item_id)) return toast('Setiap pilihan paket harus memilih menu isinya', 'error');
    setBusy(true);
    try {
      const row = { company_id: companyId, name: g.name?.trim(), group_type: g.group_type, min_select: Number(g.min_select), max_select: Number(g.max_select) };
      const saved = (await must(g.id ? supabase.from('mst_modifier_groups').update(row).eq('id', g.id).select('id').single()
        : supabase.from('mst_modifier_groups').insert(row).select('id').single())) as { id: string };
      const keep = opts.filter((o) => o.name.trim());
      const removed = (group.mst_modifiers ?? []).filter((o) => o.id && !keep.some((k) => k.id === o.id)).map((o) => o.id!);
      if (removed.length) await must(supabase.from('mst_modifiers').delete().in('id', removed));
      for (const [i, o] of keep.entries()) {
        const r = {
          company_id: companyId, modifier_group_id: saved.id, name: o.name.trim(), extra_price: Number(o.extra_price || 0), sort_order: i + 1,
          is_default: o.is_default, menu_item_id: isPackage ? o.menu_item_id : null,
          item_id: !isPackage && o.item_id ? o.item_id : null, item_qty: !isPackage && o.item_id ? Number(o.item_qty || 0) || 1 : null,
        };
        await must(o.id ? supabase.from('mst_modifiers').update(r).eq('id', o.id) : supabase.from('mst_modifiers').insert(r));
      }
      toast('Grup disimpan');
      onSaved();
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!(await confirm({ title: `Hapus grup ${g.name}?`, message: 'Grup akan dilepas dari semua menu.', danger: true, confirmLabel: 'Hapus' }))) return;
    try {
      await must(supabase.from('mst_modifier_groups').delete().eq('id', g.id!));
      onSaved();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <Modal title={`${g.id ? 'Edit' : 'Buat'} ${isPackage ? 'Grup Paket' : 'Grup Modifier'}`} onClose={onClose} large
      footer={<>
        {g.id && <button className="btn-danger" style={{ marginRight: 'auto' }} onClick={remove}><Trash2 size={16} /> Hapus</button>}
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || !g.name?.trim()} onClick={save}>Simpan</button>
      </>}>
      <p className="muted small" style={{ marginTop: 0 }}>
        {isPackage
          ? 'Contoh: menu "Paket Hemat" punya grup "Pilih Minuman" berisi Es Teh / Es Jeruk (+Rp 3.000). Stok resep minuman yang dipilih ikut terpotong.'
          : 'Contoh: "Level Pedas", "Extra Topping". Pilihan bisa memotong bahan langsung, mis. Extra Telur = 1 pcs telur.'}
      </p>
      <div className="form-grid">
        <label className="field"><span>Nama grup</span><input value={g.name ?? ''} onChange={(e) => setG({ ...g, name: e.target.value })} placeholder={isPackage ? 'Pilih Minuman' : 'Level Pedas'} /></label>
        <label className="field"><span>Minimal dipilih</span><input type="number" min={0} value={g.min_select ?? 0} onChange={(e) => setG({ ...g, min_select: Number(e.target.value) })} /></label>
        <label className="field"><span>Maksimal dipilih</span><input type="number" min={1} value={g.max_select ?? 1} onChange={(e) => setG({ ...g, max_select: Number(e.target.value) })} /></label>
      </div>
      <div className="table-wrap" style={{ marginTop: 14 }}>
        <table className="table">
          <thead><tr><th>Nama pilihan</th><th>{isPackage ? 'Menu isi *' : 'Potong bahan (opsional)'}</th>{!isPackage && <th>Qty</th>}<th>Harga tambahan</th><th title="Terpilih otomatis">Default</th><th></th></tr></thead>
          <tbody>
            {opts.map((o, i) => (
              <tr key={o.id ?? i}>
                <td><input value={o.name} onChange={(e) => upd(i, { name: e.target.value })} style={{ minWidth: 120 }} /></td>
                <td>
                  {isPackage ? (
                    <select value={o.menu_item_id ?? ''} style={{ minWidth: 160 }} onChange={(e) => upd(i, { menu_item_id: e.target.value || null, name: o.name || (menus.find((m) => m.id === e.target.value)?.name ?? '') })}>
                      <option value="">— pilih menu —</option>
                      {menus.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
                    </select>
                  ) : (
                    <select value={o.item_id ?? ''} style={{ minWidth: 160 }} onChange={(e) => upd(i, { item_id: e.target.value || null, item_qty: e.target.value ? o.item_qty ?? 1 : null })}>
                      <option value="">— tidak —</option>
                      {items.map((it) => <option key={it.id} value={it.id}>{it.name} ({it.inv_units.code})</option>)}
                    </select>
                  )}
                </td>
                {!isPackage && <td><input type="number" step="any" min={0} style={{ width: 70 }} disabled={!o.item_id} value={o.item_qty ?? ''} onChange={(e) => upd(i, { item_qty: e.target.value })} /></td>}
                <td><MoneyInput value={o.extra_price} onChange={(v) => upd(i, { extra_price: v })} style={{ width: 110 }} /></td>
                <td><input type="checkbox" checked={o.is_default} onChange={(e) => upd(i, { is_default: e.target.checked })} /></td>
                <td><button className="icon-btn" onClick={() => setOpts(opts.filter((_, j) => j !== i))} aria-label="Hapus"><Trash2 size={16} /></button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <button className="btn-sm" onClick={() => setOpts([...opts, { name: '', extra_price: 0, sort_order: opts.length + 1, is_default: false, menu_item_id: null, item_id: null, item_qty: null }])}>
        <Plus size={14} /> Pilihan
      </button>
    </Modal>
  );
}
