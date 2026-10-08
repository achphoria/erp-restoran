import { useCallback, useEffect, useState } from 'react';
import { Camera, ExternalLink, Link2, Plus, Trash2, Unlink, UserPlus } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { DOC_TYPES, EMPLOYMENT, MARITAL, RELIGIONS, hrFileUrl, uploadHrFile, type Employee } from '../../lib/hr';
import { CreateStaffUserModal } from '../settings/StaffUserModal';
import HrPhoto from './HrPhoto';

/* eslint-disable @typescript-eslint/no-explicit-any */
export interface Lookups {
  departments: { id: string; name: string }[];
  positions: { id: string; name: string; department_id: string | null; default_role_id: string | null }[];
  outlets: { id: string; name: string; brand_id?: string }[];
  roles: { id: string; name: string; code: string; permissions: string[] }[];
  employees: { id: string; full_name: string; user_id: string | null }[];
  users: { id: string; full_name: string; username: string | null; email: string | null; role_name: string }[];
}
type Section = 'pribadi' | 'identitas' | 'kontak' | 'pekerjaan' | 'riwayat' | 'dokumen' | 'akun';
const SECTIONS: [Section, string][] = [
  ['pribadi', 'Pribadi'], ['identitas', 'Identitas'], ['kontak', 'Kontak'], ['pekerjaan', 'Pekerjaan'],
  ['riwayat', 'Riwayat'], ['dokumen', 'Dokumen'], ['akun', 'Akun login'],
];
const blank = (): Partial<Employee> => ({ employment_status: 'permanent', is_active: true, education: [], experience: [], join_date: new Date().toISOString().slice(0, 10) });

// Form karyawan lengkap (halaman lebar). Dokumen & akun login aktif setelah data pertama kali disimpan.
export default function EmployeeForm({ employee, lookups, onClose, onSaved }: {
  employee: Partial<Employee> | null; lookups: Lookups; onClose: () => void; onSaved: (msg: string) => void;
}) {
  const { profile, can } = useAuth();
  const { toast, confirm } = useFeedback();
  const [e, setE] = useState<Partial<Employee>>(employee ?? blank());
  const [section, setSection] = useState<Section>('pribadi');
  const [busy, setBusy] = useState(false);
  const [docs, setDocs] = useState<any[]>([]);
  const [creatingAccount, setCreatingAccount] = useState(false);
  const companyId = profile!.company_id;
  const set = (patch: Partial<Employee>) => setE((x) => ({ ...x, ...patch }));
  const saved = !!e.id;

  const loadDocs = useCallback(async () => {
    if (!e.id) return;
    setDocs(await must(supabase.from('hr_employee_documents').select('*').eq('employee_id', e.id).order('created_at', { ascending: false })));
  }, [e.id]);
  useEffect(() => { loadDocs().catch(() => undefined); }, [loadDocs]);

  const save = async (close = true) => {
    if (!e.full_name?.trim()) { toast('Nama lengkap wajib diisi', 'error'); setSection('pribadi'); return null; }
    setBusy(true);
    try {
      const { id: _id, company_id: _c, employee_number, user_id: _u, ...rest } = e as Employee;
      const values = { ...rest, employee_number: employee_number || null };
      const row = e.id
        ? await must(supabase.from('hr_employees').update(values).eq('id', e.id).select('*').single())
        : await must(supabase.from('hr_employees').insert({ ...values, company_id: companyId }).select('*').single());
      setE(row);
      if (close) onSaved(`Data ${row.full_name} disimpan.`);
      else toast('Tersimpan', 'success');
      return row as Employee;
    } catch (err) {
      toast(errorMessage(err), 'error');
      return null;
    } finally {
      setBusy(false);
    }
  };

  // simpan dulu bila belum ada id (foto/dokumen butuh id karyawan)
  const ensureId = async () => e.id ?? (await save(false))?.id ?? null;

  const onPhoto = async (file?: File) => {
    if (!file) return;
    const id = await ensureId();
    if (!id) return;
    try {
      const path = await uploadHrFile(companyId, id, file, 'photo');
      await must(supabase.from('hr_employees').update({ photo_path: path }).eq('id', id));
      set({ photo_path: path });
    } catch (err) { toast(errorMessage(err), 'error'); }
  };

  const onDoc = async (file: File | undefined, docType: string) => {
    if (!file) return;
    const id = await ensureId();
    if (!id) return;
    try {
      const path = await uploadHrFile(companyId, id, file, docType);
      await must(supabase.from('hr_employee_documents').insert({ company_id: companyId, employee_id: id, doc_type: docType, name: file.name, file_path: path, created_by: profile!.user_id }));
      await loadDocs();
    } catch (err) { toast(errorMessage(err), 'error'); }
  };

  const link = async (userId: string | null) => {
    try {
      await rpc('hr_link_user', { p_employee_id: e.id, p_user_id: userId });
      set({ user_id: userId });
      toast(userId ? 'Akun ditautkan' : 'Tautan akun dilepas', 'success');
    } catch (err) { toast(errorMessage(err), 'error'); }
  };

  const field = (key: keyof Employee, label: string, type = 'text', extra?: { placeholder?: string }) => (
    <label className="field"><span>{label}</span>
      <input type={type} value={(e[key] as string | null | undefined) ?? ''} placeholder={extra?.placeholder}
        onChange={(ev) => set({ [key]: ev.target.value || null } as Partial<Employee>)} />
    </label>
  );
  const select = (key: keyof Employee, label: string, options: [string, string][], empty = '—') => (
    <label className="field"><span>{label}</span>
      <select value={(e[key] as string | null | undefined) ?? ''} onChange={(ev) => set({ [key]: ev.target.value || null } as Partial<Employee>)}>
        <option value="">{empty}</option>
        {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
    </label>
  );

  const linkedUser = lookups.users.find((u) => u.id === e.user_id);
  const freeUsers = lookups.users.filter((u) => !lookups.employees.some((x) => x.user_id === u.id && x.id !== e.id));
  const position = lookups.positions.find((p) => p.id === e.position_id);

  return (
    <Modal title={saved ? `${e.full_name} · ${e.employee_number}` : 'Karyawan Baru'} onClose={onClose} large
      footer={<>
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy} onClick={() => save(true)}>{busy ? 'Menyimpan…' : 'Simpan'}</button>
      </>}>
      <div className="hr-form">
        <aside className="hr-form-side">
          <label className="hr-photo" title="Ganti foto">
            <HrPhoto path={e.photo_path} name={e.full_name ?? '?'} size={112} />
            <span className="hr-photo-btn"><Camera size={14} /> Foto</span>
            <input type="file" accept="image/*" hidden onChange={(ev) => onPhoto(ev.target.files?.[0])} />
          </label>
          <b>{e.full_name || 'Nama karyawan'}</b>
          <span className="muted small">{e.employee_number ?? 'Nomor otomatis setelah disimpan'}</span>
          <nav className="hr-form-nav">
            {SECTIONS.map(([k, v]) => (
              <button key={k} type="button" className={section === k ? 'active' : ''} onClick={() => setSection(k)}>{v}</button>
            ))}
          </nav>
        </aside>

        <div className="hr-form-main">
          {section === 'pribadi' && (
            <div className="form-grid">
              {field('full_name', 'Nama lengkap *')}
              {field('nickname', 'Nama panggilan')}
              {select('gender', 'Jenis kelamin', [['L', 'Laki-laki'], ['P', 'Perempuan']])}
              {field('birth_place', 'Tempat lahir')}
              {field('birth_date', 'Tanggal lahir', 'date')}
              {select('religion', 'Agama', RELIGIONS.map((r) => [r, r]))}
              {select('marital_status', 'Status pernikahan', Object.entries(MARITAL))}
              {select('blood_type', 'Golongan darah', ['A', 'B', 'AB', 'O'].map((b) => [b, b]))}
            </div>
          )}
          {section === 'identitas' && (
            <>
              <div className="alert alert-info small">Data identitas hanya terlihat oleh HR, owner, dan karyawan itu sendiri.</div>
              <div className="form-grid">
                {field('national_id', 'No. KTP (NIK)', 'text', { placeholder: '16 digit' })}
                {field('tax_number', 'NPWP')}
                {field('bpjs_kesehatan', 'No. BPJS Kesehatan')}
                {field('bpjs_ketenagakerjaan', 'No. BPJS Ketenagakerjaan')}
              </div>
            </>
          )}
          {section === 'kontak' && (
            <div className="form-grid">
              {field('phone', 'No. HP', 'tel')}
              {field('email', 'Email', 'email')}
              <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alamat sesuai KTP</span>
                <textarea rows={2} value={e.address_ktp ?? ''} onChange={(ev) => set({ address_ktp: ev.target.value || null })} /></label>
              <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alamat domisili</span>
                <textarea rows={2} value={e.address_domicile ?? ''} onChange={(ev) => set({ address_domicile: ev.target.value || null })} /></label>
              {field('emergency_name', 'Kontak darurat: nama')}
              {field('emergency_relation', 'Hubungan', 'text', { placeholder: 'mis. Ibu, Suami' })}
              {field('emergency_phone', 'Kontak darurat: No. HP', 'tel')}
            </div>
          )}
          {section === 'pekerjaan' && (
            <div className="form-grid">
              {select('department_id', 'Departemen', lookups.departments.map((d) => [d.id, d.name]))}
              {select('position_id', 'Jabatan', lookups.positions.filter((p) => !e.department_id || !p.department_id || p.department_id === e.department_id).map((p) => [p.id, p.name]))}
              {select('outlet_id', 'Penempatan outlet', lookups.outlets.map((o) => [o.id, o.name]), 'Kantor pusat / semua')}
              {select('manager_id', 'Atasan langsung', lookups.employees.filter((x) => x.id !== e.id).map((x) => [x.id, x.full_name]))}
              {select('employment_status', 'Status karyawan', Object.entries(EMPLOYMENT), 'Pilih')}
              {field('join_date', 'Tanggal masuk', 'date')}
              {field('contract_end_date', 'Akhir kontrak', 'date')}
              {field('resign_date', 'Tanggal keluar', 'date')}
              <label className="row" style={{ gridColumn: '1 / -1' }}>
                <input type="checkbox" checked={e.is_active ?? true} onChange={(ev) => set({ is_active: ev.target.checked })} /> Karyawan aktif
              </label>
            </div>
          )}
          {section === 'riwayat' && (
            <div className="grid">
              <RowsEditor title="Pendidikan" rows={e.education ?? []} onChange={(education) => set({ education })}
                cols={[['level', 'Jenjang', 'SMA/S1'], ['school', 'Sekolah / kampus', ''], ['major', 'Jurusan', ''], ['year', 'Lulus', '2020']]} />
              <RowsEditor title="Pengalaman kerja" rows={e.experience ?? []} onChange={(experience) => set({ experience })}
                cols={[['company', 'Perusahaan', ''], ['position', 'Posisi', ''], ['from', 'Dari', '2019'], ['to', 'Sampai', '2021']]} />
              <label className="field"><span>Catatan</span><textarea rows={3} value={e.notes ?? ''} onChange={(ev) => set({ notes: ev.target.value || null })} /></label>
            </div>
          )}
          {section === 'dokumen' && (
            <div className="grid">
              <div className="row" style={{ flexWrap: 'wrap', gap: 8 }}>
                {Object.entries(DOC_TYPES).map(([k, v]) => (
                  <label key={k} className="btn btn-sm" style={{ cursor: 'pointer' }}><Plus size={13} /> {v}
                    <input type="file" accept="image/*,application/pdf" hidden onChange={(ev) => { onDoc(ev.target.files?.[0], k); ev.target.value = ''; }} /></label>
                ))}
              </div>
              <table className="table">
                <thead><tr><th>Jenis</th><th>Nama file</th><th>Diunggah</th><th></th></tr></thead>
                <tbody>
                  {docs.map((d) => (
                    <tr key={d.id}>
                      <td><span className="badge">{DOC_TYPES[d.doc_type] ?? d.doc_type}</span></td>
                      <td className="small">{d.name}</td>
                      <td className="small muted">{new Date(d.created_at).toLocaleDateString('id-ID')}</td>
                      <td className="right">
                        <div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                          <button className="btn-sm" onClick={async () => { const u = await hrFileUrl(d.file_path); if (u) window.open(u, '_blank', 'noopener'); }}><ExternalLink size={13} /> Buka</button>
                          <button className="btn-sm btn-danger" onClick={async () => {
                            if (!(await confirm({ title: 'Hapus dokumen?', message: d.name, danger: true, confirmLabel: 'Hapus' }))) return;
                            await supabase.storage.from('hr-files').remove([d.file_path]);
                            await must(supabase.from('hr_employee_documents').delete().eq('id', d.id));
                            loadDocs();
                          }}><Trash2 size={13} /></button>
                        </div>
                      </td>
                    </tr>
                  ))}
                  {!docs.length && <tr><td colSpan={4} className="empty">Belum ada dokumen. Unggah KTP, kontrak, atau sertifikat.</td></tr>}
                </tbody>
              </table>
            </div>
          )}
          {section === 'akun' && (
            <div className="grid">
              <div className="alert alert-info small">
                Akun login dipakai karyawan untuk absen, melihat pengumuman & tugas, dan (sesuai role) membuka menu kasir/gudang.
                Role default mengikuti jabatan{position?.default_role_id ? <> (<b>{lookups.roles.find((r) => r.id === position.default_role_id)?.name}</b>)</> : ''}.
              </div>
              {!saved && <p className="muted">Simpan data karyawan dulu, lalu buatkan akun.</p>}
              {saved && linkedUser && (
                <div className="card" style={{ background: 'var(--surface-2)', boxShadow: 'none' }}>
                  <b>{linkedUser.full_name}</b>
                  <div className="small">{linkedUser.username ? <>Username: <code>{linkedUser.username}</code></> : linkedUser.email} · {linkedUser.role_name}</div>
                  {can('user.manage') && <button className="btn-sm" style={{ marginTop: 8 }} onClick={() => link(null)}><Unlink size={13} /> Lepas tautan akun</button>}
                </div>
              )}
              {saved && !linkedUser && can('user.manage') && (
                <>
                  <button className="btn-primary" style={{ justifySelf: 'start' }} onClick={() => setCreatingAccount(true)}><UserPlus size={15} /> Buatkan akun login</button>
                  {freeUsers.length > 0 && (
                    <label className="field"><span>…atau tautkan ke akun yang sudah ada</span>
                      <select value="" onChange={(ev) => ev.target.value && link(ev.target.value)}>
                        <option value="">Pilih akun</option>
                        {freeUsers.map((u) => <option key={u.id} value={u.id}>{u.full_name} · {u.username ?? u.email} · {u.role_name}</option>)}
                      </select>
                    </label>
                  )}
                </>
              )}
              {saved && !linkedUser && !can('user.manage') && <p className="muted">Minta owner/admin membuatkan akun login.</p>}
              {saved && !linkedUser && <p className="muted small"><Link2 size={12} /> Akun yang dibuat dari sini otomatis tertaut ke karyawan ini.</p>}
            </div>
          )}
        </div>
      </div>

      {creatingAccount && (
        <CreateStaffUserModal roles={lookups.roles} outlets={lookups.outlets} defaultName={e.full_name ?? ''}
          defaultRoleId={position?.default_role_id} defaultOutletId={e.outlet_id}
          onCreated={async (userId) => { await rpc('hr_link_user', { p_employee_id: e.id, p_user_id: userId }); set({ user_id: userId }); }}
          onClose={() => setCreatingAccount(false)}
          onDone={(msg) => { setCreatingAccount(false); onSaved(msg); }} />
      )}
    </Modal>
  );
}

function RowsEditor({ title, rows, cols, onChange }: {
  title: string; rows: Record<string, string | undefined>[]; cols: [string, string, string][]; onChange: (rows: any[]) => void;
}) {
  return (
    <div>
      <div className="row" style={{ justifyContent: 'space-between', marginBottom: 6 }}>
        <b>{title}</b>
        <button type="button" className="btn-sm" onClick={() => onChange([...rows, {}])}><Plus size={13} /> Tambah</button>
      </div>
      {rows.map((r, i) => (
        <div key={i} className="hr-rows">
          {cols.map(([k, l, ph]) => (
            <input key={k} aria-label={l} placeholder={ph || l} value={r[k] ?? ''} onChange={(ev) => onChange(rows.map((x, j) => (j === i ? { ...x, [k]: ev.target.value } : x)))} />
          ))}
          <button type="button" className="btn-sm btn-danger" aria-label="Hapus baris" onClick={() => onChange(rows.filter((_, j) => j !== i))}><Trash2 size={13} /></button>
        </div>
      ))}
      {!rows.length && <p className="muted small" style={{ margin: 0 }}>Belum ada data.</p>}
    </div>
  );
}
