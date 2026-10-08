import { useState } from 'react';
import { Plus } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Struktur organisasi: departemen & jabatan (jabatan bisa punya role default untuk akun login)
export default function StructureTab({ companyId, departments, positions, roles, employees, onChanged }: {
  companyId: string; departments: any[]; positions: any[]; roles: { id: string; name: string; permissions: string[] }[];
  employees: { position_id: string | null; department_id: string | null; is_active: boolean }[]; onChanged: () => void;
}) {
  const { toast } = useFeedback();
  const [dep, setDep] = useState<any | null>(null);
  const [pos, setPos] = useState<any | null>(null);
  const count = (key: 'position_id' | 'department_id', id: string) => employees.filter((e) => e.is_active && e[key] === id).length;

  const save = async (table: 'hr_departments' | 'hr_positions', row: any, close: () => void) => {
    try {
      const values = { ...row, code: row.code?.trim().toUpperCase(), name: row.name?.trim() };
      if (!values.code || !values.name) throw new Error('Kode & nama wajib diisi');
      if (row.id) await must(supabase.from(table).update(values).eq('id', row.id));
      else await must(supabase.from(table).insert({ ...values, company_id: companyId }));
      close();
      onChanged();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <div className="grid grid-2">
      <div className="card table-wrap">
        <div className="card-header"><h2>Departemen</h2><button className="btn-sm btn-primary" onClick={() => setDep({ is_active: true })}><Plus size={14} /> Departemen</button></div>
        <table className="table">
          <thead><tr><th>Kode</th><th>Nama</th><th className="right">Karyawan</th><th></th></tr></thead>
          <tbody>
            {departments.map((d) => (
              <tr key={d.id}><td>{d.code}</td><td className="bold">{d.name} {!d.is_active && <span className="badge">Nonaktif</span>}</td>
                <td className="right">{count('department_id', d.id)}</td><td className="right"><button className="btn-sm" onClick={() => setDep(d)}>Edit</button></td></tr>
            ))}
            {!departments.length && <tr><td colSpan={4} className="empty">Contoh: Operasional, Dapur, Gudang, Keuangan, HR.</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="card table-wrap">
        <div className="card-header"><h2>Jabatan</h2><button className="btn-sm btn-primary" onClick={() => setPos({ is_active: true })}><Plus size={14} /> Jabatan</button></div>
        <table className="table">
          <thead><tr><th>Jabatan</th><th>Departemen</th><th>Role akun default</th><th className="right">Orang</th><th></th></tr></thead>
          <tbody>
            {positions.map((p) => (
              <tr key={p.id}>
                <td><b>{p.name}</b><div className="muted small">{p.code}</div></td>
                <td className="small">{departments.find((d) => d.id === p.department_id)?.name ?? '—'}</td>
                <td className="small">{roles.find((r) => r.id === p.default_role_id)?.name ?? <span className="muted">—</span>}</td>
                <td className="right">{count('position_id', p.id)}</td>
                <td className="right"><button className="btn-sm" onClick={() => setPos(p)}>Edit</button></td>
              </tr>
            ))}
            {!positions.length && <tr><td colSpan={5} className="empty">Contoh: Kasir, Barista, Cook, Staf Gudang, Store Manager.</td></tr>}
          </tbody>
        </table>
      </div>

      {dep && (
        <Modal title={dep.id ? `Edit ${dep.name}` : 'Departemen baru'} onClose={() => setDep(null)}
          footer={<><button onClick={() => setDep(null)}>Batal</button><button className="btn-primary" onClick={() => save('hr_departments', { id: dep.id, code: dep.code, name: dep.name, is_active: dep.is_active }, () => setDep(null))}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode</span><input value={dep.code ?? ''} disabled={!!dep.id} onChange={(e) => setDep({ ...dep, code: e.target.value })} placeholder="OPS" /></label>
            <label className="field"><span>Nama</span><input value={dep.name ?? ''} autoFocus onChange={(e) => setDep({ ...dep, name: e.target.value })} placeholder="Operasional" /></label>
          </div>
          {dep.id && <label className="row" style={{ marginTop: 10 }}><input type="checkbox" checked={!!dep.is_active} onChange={(e) => setDep({ ...dep, is_active: e.target.checked })} /> Aktif</label>}
        </Modal>
      )}
      {pos && (
        <Modal title={pos.id ? `Edit ${pos.name}` : 'Jabatan baru'} onClose={() => setPos(null)}
          footer={<><button onClick={() => setPos(null)}>Batal</button><button className="btn-primary" onClick={() => save('hr_positions', {
            id: pos.id, code: pos.code, name: pos.name, department_id: pos.department_id || null, default_role_id: pos.default_role_id || null, is_active: pos.is_active,
          }, () => setPos(null))}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode</span><input value={pos.code ?? ''} disabled={!!pos.id} onChange={(e) => setPos({ ...pos, code: e.target.value })} placeholder="KSR" /></label>
            <label className="field"><span>Nama jabatan</span><input value={pos.name ?? ''} autoFocus onChange={(e) => setPos({ ...pos, name: e.target.value })} placeholder="Kasir" /></label>
            <label className="field"><span>Departemen</span>
              <select value={pos.department_id ?? ''} onChange={(e) => setPos({ ...pos, department_id: e.target.value })}>
                <option value="">—</option>{departments.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select></label>
            <label className="field"><span>Role akun default</span>
              <select value={pos.default_role_id ?? ''} onChange={(e) => setPos({ ...pos, default_role_id: e.target.value })}>
                <option value="">—</option>{roles.filter((r) => !r.permissions.includes('*')).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select></label>
          </div>
          <p className="muted small">Role default dipakai otomatis saat membuatkan akun login untuk karyawan dengan jabatan ini.</p>
          {pos.id && <label className="row"><input type="checkbox" checked={!!pos.is_active} onChange={(e) => setPos({ ...pos, is_active: e.target.checked })} /> Aktif</label>}
        </Modal>
      )}
    </div>
  );
}
