import { useState } from 'react';
import { Megaphone, Pin } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime } from '../../lib/format';

/* eslint-disable @typescript-eslint/no-explicit-any */
const AUDIENCE: Record<string, string> = { all: 'Semua karyawan', outlet: 'Outlet tertentu', role: 'Role tertentu' };

// Pengumuman untuk karyawan: semua / per outlet / per role, dengan jumlah yang sudah membaca
export default function AnnouncementsTab({ companyId, items, stats, outlets, roles, onChanged }: {
  companyId: string; items: any[]; stats: Record<string, number>; outlets: { id: string; name: string }[];
  roles: { id: string; name: string }[]; onChanged: () => void;
}) {
  const { toast, confirm } = useFeedback();
  const [editing, setEditing] = useState<any | null>(null);

  const save = async () => {
    const a = editing;
    try {
      if (!a.title?.trim()) throw new Error('Judul wajib diisi');
      const values = {
        title: a.title.trim(), body: a.body ?? '', audience: a.audience ?? 'all', pinned: !!a.pinned,
        outlet_ids: a.audience === 'outlet' ? a.outlet_ids ?? [] : [], role_ids: a.audience === 'role' ? a.role_ids ?? [] : [],
        expires_at: a.expires_at ? new Date(`${a.expires_at}T23:59:59`).toISOString() : null,
      };
      if (a.audience === 'outlet' && !values.outlet_ids.length) throw new Error('Pilih minimal 1 outlet');
      if (a.audience === 'role' && !values.role_ids.length) throw new Error('Pilih minimal 1 role');
      if (a.id) await must(supabase.from('hr_announcements').update(values).eq('id', a.id));
      else await must(supabase.from('hr_announcements').insert({ ...values, company_id: companyId }));
      setEditing(null);
      onChanged();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };
  const toggle = (key: 'outlet_ids' | 'role_ids', id: string) => {
    const list: string[] = editing[key] ?? [];
    setEditing({ ...editing, [key]: list.includes(id) ? list.filter((x) => x !== id) : [...list, id] });
  };
  const target = (a: any) => (a.audience === 'outlet' ? outlets.filter((o) => a.outlet_ids.includes(o.id)).map((o) => o.name).join(', ')
    : a.audience === 'role' ? roles.filter((r) => a.role_ids.includes(r.id)).map((r) => r.name).join(', ') : 'Semua karyawan');

  return (
    <div className="card table-wrap">
      <div className="card-header"><h2>Pengumuman</h2><button className="btn-primary" onClick={() => setEditing({ audience: 'all' })}><Megaphone size={15} /> Buat pengumuman</button></div>
      <table className="table">
        <thead><tr><th>Judul</th><th>Untuk</th><th>Terbit</th><th className="right">Dibaca</th><th></th></tr></thead>
        <tbody>
          {items.map((a) => (
            <tr key={a.id}>
              <td><b>{a.pinned && <Pin size={12} style={{ verticalAlign: -1, color: 'var(--accent)' }} />} {a.title}</b><div className="muted small hr-clip">{a.body}</div></td>
              <td className="small">{target(a)}</td>
              <td className="small nowrap">{formatDateTime(a.published_at)}{a.expires_at && <div className="muted">s/d {new Date(a.expires_at).toLocaleDateString('id-ID')}</div>}</td>
              <td className="right">{stats[a.id] ?? 0} orang</td>
              <td className="right">
                <div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                  <button className="btn-sm" onClick={() => setEditing({ ...a, expires_at: a.expires_at?.slice(0, 10) })}>Edit</button>
                  <button className="btn-sm btn-danger" onClick={async () => {
                    if (await confirm({ title: `Hapus "${a.title}"?`, danger: true, confirmLabel: 'Hapus' })) { await must(supabase.from('hr_announcements').delete().eq('id', a.id)); onChanged(); }
                  }}>Hapus</button>
                </div>
              </td>
            </tr>
          ))}
          {!items.length && <tr><td colSpan={5} className="empty">Belum ada pengumuman. Contoh: jadwal libur, SOP baru, promo minggu ini.</td></tr>}
        </tbody>
      </table>

      {editing && (
        <Modal title={editing.id ? 'Edit pengumuman' : 'Pengumuman baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button><button className="btn-primary" onClick={save}>Terbitkan</button></>}>
          <div className="grid">
            <label className="field"><span>Judul</span><input autoFocus value={editing.title ?? ''} onChange={(e) => setEditing({ ...editing, title: e.target.value })} placeholder="mis. Jadwal libur Lebaran" /></label>
            <label className="field"><span>Isi</span><textarea rows={5} value={editing.body ?? ''} onChange={(e) => setEditing({ ...editing, body: e.target.value })} /></label>
            <label className="field"><span>Ditujukan untuk</span>
              <select value={editing.audience} onChange={(e) => setEditing({ ...editing, audience: e.target.value })}>
                {Object.entries(AUDIENCE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select></label>
            {editing.audience === 'outlet' && <div className="choice-list">{outlets.map((o) => <button key={o.id} type="button" className={(editing.outlet_ids ?? []).includes(o.id) ? 'active' : ''} onClick={() => toggle('outlet_ids', o.id)}>{o.name}</button>)}</div>}
            {editing.audience === 'role' && <div className="choice-list">{roles.map((r) => <button key={r.id} type="button" className={(editing.role_ids ?? []).includes(r.id) ? 'active' : ''} onClick={() => toggle('role_ids', r.id)}>{r.name}</button>)}</div>}
            <div className="form-grid">
              <label className="field"><span>Tampil sampai (opsional)</span><input type="date" value={editing.expires_at ?? ''} onChange={(e) => setEditing({ ...editing, expires_at: e.target.value })} /></label>
              <label className="row" style={{ alignSelf: 'end' }}><input type="checkbox" checked={!!editing.pinned} onChange={(e) => setEditing({ ...editing, pinned: e.target.checked })} /> Sematkan di atas</label>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
