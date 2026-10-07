import { useState } from 'react';
import { Plus } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import type { MasterData, SubCategory } from './types';

// Sub kategori: pengelompokan kedua yang bebas dipadukan dengan kategori mana pun
export default function SubCategoriesTab(md: MasterData) {
  const { toast } = useFeedback();
  const [editing, setEditing] = useState<Partial<SubCategory> | null>(null);

  const save = async () => {
    const s = editing!;
    try {
      const row = { company_id: md.companyId, name: s.name?.trim(), code: s.code?.trim() || null, notes: s.notes?.trim() || null, is_active: !!s.is_active };
      await must(s.id ? supabase.from('inv_item_sub_categories').update(row).eq('id', s.id) : supabase.from('inv_item_sub_categories').insert(row));
      toast('Sub kategori disimpan');
      setEditing(null);
      md.reload();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Nama sub kategori sudah dipakai' : errorMessage(e), 'error');
    }
  };

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>Sub Kategori</h2>
        <button className="btn-primary" onClick={() => setEditing({ is_active: true })}><Plus size={16} /> Sub Kategori</button>
      </div>
      <table className="table">
        <thead><tr><th>Kode</th><th>Nama</th><th>Catatan</th><th>Status</th></tr></thead>
        <tbody>
          {md.subCategories.map((s) => (
            <tr key={s.id} onClick={() => setEditing(s)} style={{ cursor: 'pointer' }}>
              <td>{s.code ?? '—'}</td><td className="bold">{s.name}</td><td className="small muted">{s.notes}</td>
              <td>{s.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
            </tr>
          ))}
          {!md.subCategories.length && <tr><td colSpan={4} className="empty">Belum ada sub kategori.</td></tr>}
        </tbody>
      </table>
      {editing && (
        <Modal title={editing.id ? `Edit ${editing.name}` : 'Sub Kategori Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button><button className="btn-primary" disabled={!editing.name?.trim()} onClick={save}>Simpan</button></>}>
          <div className="grid">
            <label className="field"><span>Nama *</span><input value={editing.name ?? ''} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            <label className="field"><span>Kode</span><input value={editing.code ?? ''} onChange={(e) => setEditing({ ...editing, code: e.target.value.toUpperCase() })} /></label>
            <label className="field"><span>Catatan</span><input maxLength={100} value={editing.notes ?? ''} onChange={(e) => setEditing({ ...editing, notes: e.target.value })} /></label>
            <label className="switch"><input type="checkbox" checked={!!editing.is_active} onChange={(e) => setEditing({ ...editing, is_active: e.target.checked })} /><span>Aktif</span></label>
          </div>
        </Modal>
      )}
    </div>
  );
}
