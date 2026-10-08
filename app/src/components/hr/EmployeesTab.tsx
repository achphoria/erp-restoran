import { useMemo, useState } from 'react';
import { Cake, FileWarning, Search, UserPlus } from 'lucide-react';
import { useAuth } from '../../context/AuthContext';
import { EMPLOYMENT, type Employee } from '../../lib/hr';
import EmployeeForm, { type Lookups } from './EmployeeForm';
import HrPhoto from './HrPhoto';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Daftar karyawan (1 baris per orang) + pengingat kontrak & ulang tahun
export default function EmployeesTab({ employees, lookups, reminders, onChanged }: {
  employees: Employee[]; lookups: Lookups; reminders: { contracts?: any[]; birthdays?: any[] }; onChanged: (msg?: string) => void;
}) {
  const { can } = useAuth();
  const [q, setQ] = useState('');
  const [outlet, setOutlet] = useState('');
  const [status, setStatus] = useState<'active' | 'inactive' | 'all'>('active');
  const [editing, setEditing] = useState<Partial<Employee> | null | undefined>(undefined);
  const name = (list: { id: string; name: string }[], id: string | null) => list.find((x) => x.id === id)?.name ?? '';
  const userOf = (id: string | null) => lookups.users.find((u) => u.id === id);

  const shown = useMemo(() => employees.filter((e) => {
    if (status === 'active' && !e.is_active) return false;
    if (status === 'inactive' && e.is_active) return false;
    if (outlet && e.outlet_id !== outlet) return false;
    const s = q.trim().toLowerCase();
    return !s || [e.full_name, e.nickname, e.employee_number, e.phone, name(lookups.positions, e.position_id)].some((v) => v?.toLowerCase().includes(s));
  }), [employees, q, outlet, status, lookups.positions]);

  const daysLeft = (d: string | null) => (d ? Math.ceil((new Date(d).getTime() - Date.now()) / 86400000) : null);

  return (
    <>
      {((reminders.contracts?.length ?? 0) > 0 || (reminders.birthdays?.length ?? 0) > 0) && (
        <div className="hr-reminders">
          {reminders.contracts?.map((c) => (
            <button key={c.id} type="button" className="hr-reminder warn" onClick={() => setEditing(employees.find((e) => e.id === c.id))}>
              <FileWarning size={15} /> Kontrak <b>{c.full_name}</b> habis {new Date(c.contract_end_date).toLocaleDateString('id-ID', { day: 'numeric', month: 'short' })}
            </button>
          ))}
          {reminders.birthdays?.map((b) => (
            <span key={b.id} className="hr-reminder"><Cake size={15} /> {b.full_name} ulang tahun tgl {b.day}</span>
          ))}
        </div>
      )}
      <div className="card table-wrap">
        <div className="card-header" style={{ flexWrap: 'wrap', gap: 8 }}>
          <h2>Karyawan <span className="muted small">({shown.length})</span></h2>
          <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
            <div className="input-icon"><Search size={15} /><input placeholder="Cari nama, NIK, jabatan…" value={q} onChange={(e) => setQ(e.target.value)} /></div>
            <select value={outlet} onChange={(e) => setOutlet(e.target.value)} aria-label="Filter outlet">
              <option value="">Semua outlet</option>
              {lookups.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select>
            <select value={status} onChange={(e) => setStatus(e.target.value as typeof status)} aria-label="Filter status">
              <option value="active">Aktif</option><option value="inactive">Nonaktif</option><option value="all">Semua</option>
            </select>
            {can('hr.manage') && <button className="btn-primary" onClick={() => setEditing(null)}><UserPlus size={15} /> Karyawan</button>}
          </div>
        </div>
        <table className="table">
          <thead><tr><th>Karyawan</th><th>Jabatan</th><th>Outlet</th><th>Status</th><th>Akun login</th><th>Kontak</th><th></th></tr></thead>
          <tbody>
            {shown.map((e) => {
              const u = userOf(e.user_id);
              const left = daysLeft(e.contract_end_date);
              return (
                <tr key={e.id} className="clickable-row" onClick={() => setEditing(e)}>
                  <td>
                    <div className="row" style={{ flexWrap: 'nowrap', gap: 10 }}>
                      <HrPhoto path={e.photo_path} name={e.full_name} size={36} />
                      <span><b>{e.full_name}</b><div className="muted small">{e.employee_number}{e.nickname ? ` · ${e.nickname}` : ''}</div></span>
                    </div>
                  </td>
                  <td className="small">{name(lookups.positions, e.position_id) || '—'}<div className="muted">{name(lookups.departments, e.department_id)}</div></td>
                  <td className="small">{name(lookups.outlets, e.outlet_id) || <span className="muted">Pusat</span>}</td>
                  <td className="small">
                    <span className={`badge ${e.is_active ? 'badge-success' : ''}`}>{e.is_active ? EMPLOYMENT[e.employment_status] : 'Nonaktif'}</span>
                    {left !== null && left >= 0 && left <= 30 && <div style={{ color: 'var(--warning)' }}>kontrak {left} hari lagi</div>}
                  </td>
                  <td className="small">{u ? <><code>{u.username ?? u.email}</code><div className="muted">{u.role_name}</div></> : <span className="muted">Belum ada</span>}</td>
                  <td className="small nowrap">{e.phone ?? '—'}</td>
                  <td className="right"><button className="btn-sm" onClick={(ev) => { ev.stopPropagation(); setEditing(e); }}>Detail</button></td>
                </tr>
              );
            })}
            {!shown.length && <tr><td colSpan={7} className="empty">Belum ada karyawan. Klik <b>+ Karyawan</b>, atau minta Semar mengimpor dari Excel.</td></tr>}
          </tbody>
        </table>
      </div>
      {editing !== undefined && (
        <EmployeeForm employee={editing} lookups={lookups} onClose={() => { setEditing(undefined); onChanged(); }}
          onSaved={(msg) => { setEditing(undefined); onChanged(msg); }} />
      )}
    </>
  );
}
