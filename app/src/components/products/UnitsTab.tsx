import { useState } from 'react';
import { Plus } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { METRICS, type MasterData, type Unit } from './types';

export default function UnitsTab(md: MasterData) {
  const { toast } = useFeedback();
  const [editing, setEditing] = useState<Partial<Unit> | null>(null);

  const save = async () => {
    const u = editing!;
    try {
      const row = { company_id: md.companyId, code: u.code?.trim(), name: u.name?.trim(), metric: u.metric, notes: u.notes?.trim() || null };
      await must(u.id ? supabase.from('inv_units').update(row).eq('id', u.id) : supabase.from('inv_units').insert(row));
      toast('Satuan disimpan');
      setEditing(null);
      md.reload();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Kode satuan sudah dipakai' : errorMessage(e), 'error');
    }
  };

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>Satuan</h2>
        <button className="btn-primary" onClick={() => setEditing({ metric: 'unit' })}><Plus size={16} /> Satuan</button>
      </div>
      <table className="table">
        <thead><tr><th>Kode</th><th>Nama</th><th>Metrik</th><th>Catatan</th></tr></thead>
        <tbody>
          {md.units.map((u) => (
            <tr key={u.id} onClick={() => setEditing(u)} style={{ cursor: 'pointer' }}>
              <td className="bold">{u.code}</td><td>{u.name}</td><td><span className="badge">{METRICS[u.metric]}</span></td><td className="small muted">{u.notes}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {editing && (
        <Modal title={editing.id ? `Edit ${editing.code}` : 'Satuan Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button><button className="btn-primary" disabled={!editing.code?.trim() || !editing.name?.trim()} onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode *</span><input value={editing.code ?? ''} placeholder="dus" onChange={(e) => setEditing({ ...editing, code: e.target.value })} /></label>
            <label className="field"><span>Nama *</span><input value={editing.name ?? ''} placeholder="Dus" onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            <label className="field"><span>Metrik</span>
              <select value={editing.metric} onChange={(e) => setEditing({ ...editing, metric: e.target.value as Unit['metric'] })}>
                {Object.entries(METRICS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select></label>
            <label className="field"><span>Catatan</span><input maxLength={100} value={editing.notes ?? ''} onChange={(e) => setEditing({ ...editing, notes: e.target.value })} /></label>
          </div>
          <p className="muted small">Konversi antar satuan (mis. 1 dus = 24 pcs) diatur di masing-masing produk.</p>
        </Modal>
      )}
    </div>
  );
}
