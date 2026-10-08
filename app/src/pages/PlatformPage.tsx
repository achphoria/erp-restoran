import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { LogIn, Plus, UserMinus, UserPlus } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import { rpc } from '../lib/supabase';
import { errorMessage, formatDateTime, formatNumber } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';

interface CompanyRow {
  id: string; code: string; name: string; is_active: boolean; created_at: string; group_id: string | null; group_name: string | null;
  users: number; outlets: number; brands: number; owners: string | null; orders_30d: number; last_activity: string | null;
}
interface GroupRow {
  id: string; code: string; name: string;
  companies: { id: string; name: string }[];
  members: { user_id: string; full_name: string; email: string | null; home_company: string }[];
}
type Tab = 'companies' | 'groups';

// Console Platform: khusus Platform Admin (developer). Status platform admin diberikan lewat SQL Editor.
export default function PlatformPage() {
  const { profile, switchCompany } = useAuth();
  const { toast, confirm, prompt } = useFeedback();
  const navigate = useNavigate();
  const [tab, setTab] = useTabParam<Tab>('companies', ['companies', 'groups']);
  const [companies, setCompanies] = useState<CompanyRow[]>([]);
  const [groups, setGroups] = useState<GroupRow[]>([]);
  const [search, setSearch] = useState('');

  const load = useCallback(async () => {
    const [c, g] = await Promise.all([rpc<CompanyRow[]>('sys_platform_companies'), rpc<GroupRow[]>('sys_platform_groups')]);
    setCompanies(c);
    setGroups(g);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const run = async (fn: () => Promise<unknown>, msg?: string) => {
    try {
      await fn();
      if (msg) toast(msg);
      await load();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  if (!profile?.is_platform_admin) return <div className="card empty">Halaman ini khusus Platform Admin.</div>;

  const enter = async (c: CompanyRow) => {
    if (c.id === profile.home_company_id) return toast('Ini perusahaan Anda sendiri.', 'info');
    if (!(await confirm({ title: `Masuk ke ${c.name}?`, confirmLabel: 'Masuk (mode support)',
      message: 'Anda akan melihat & bisa mengubah data PT ini dengan akses penuh seperti owner. Masuk dan semua perubahan dicatat di log aktivitas PT tersebut dengan tanda "(Platform support)".' }))) return;
    try {
      await switchCompany(c.id);
      navigate('/');
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  const toggleActive = async (c: CompanyRow) => {
    if (c.is_active && !(await confirm({ title: `Nonaktifkan ${c.name}?`, danger: true, confirmLabel: 'Nonaktifkan',
      message: 'Semua user PT ini tidak bisa masuk sampai diaktifkan lagi. Data tidak dihapus.' }))) return;
    run(() => rpc('sys_platform_set_company_active', { p_company_id: c.id, p_active: !c.is_active }), c.is_active ? 'Perusahaan dinonaktifkan.' : 'Perusahaan diaktifkan.');
  };

  const saveGroup = async (g?: GroupRow) => {
    const name = await prompt({ title: g ? 'Ubah grup usaha' : 'Grup usaha baru', label: 'Nama grup (mis. Achphoria Group)', defaultValue: g?.name, required: true, confirmLabel: 'Simpan' });
    if (!name) return;
    const code = g?.code ?? name.replace(/[^a-z0-9]/gi, '').slice(0, 10).toUpperCase() + String(Date.now()).slice(-3);
    run(() => rpc('sys_platform_save_group', { p_id: g?.id ?? null, p_code: code, p_name: name }), 'Grup disimpan.');
  };

  const addMember = async (g: GroupRow) => {
    const email = await prompt({ title: `Tambah pemilik grup · ${g.name}`, label: 'Email owner (atau username staf)', placeholder: 'owner@email.com', required: true, confirmLabel: 'Tambah' });
    if (email) run(() => rpc('sys_platform_add_group_member', { p_group_id: g.id, p_email: email }), 'Pemilik grup ditambahkan.');
  };

  const q = search.trim().toLowerCase();
  const shown = companies.filter((c) => !q || [c.name, c.code, c.owners, c.group_name].some((v) => v?.toLowerCase().includes(q)));

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Console Platform</h1>
          <p>Semua perusahaan (PT) yang memakai aplikasi, grup usaha, dan akses support.</p>
        </div>
      </div>
      <div className="tabs">
        <button className={tab === 'companies' ? 'active' : ''} onClick={() => setTab('companies')}>Semua Perusahaan ({companies.length})</button>
        <button className={tab === 'groups' ? 'active' : ''} onClick={() => setTab('groups')}>Grup Usaha ({groups.length})</button>
      </div>

      {tab === 'companies' && (
        <div className="card table-wrap">
          <div className="card-header">
            <h2>Perusahaan</h2>
            <input placeholder="Cari nama, owner, grup…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ maxWidth: 260 }} />
          </div>
          <table className="table">
            <thead><tr><th>Perusahaan</th><th>Owner</th><th>Grup usaha</th><th className="right">User</th><th className="right">Outlet</th><th className="right">Order 30 hari</th><th>Aktivitas terakhir</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {shown.map((c) => (
                <tr key={c.id}>
                  <td><b>{c.name}</b>{c.id === profile.home_company_id && <span className="muted"> (PT Anda)</span>}<div className="muted small">{c.brands} brand · sejak {formatDateTime(c.created_at)}</div></td>
                  <td className="small">{c.owners ?? '—'}</td>
                  <td>
                    <select value={c.group_id ?? ''} aria-label={`Grup ${c.name}`}
                      onChange={(e) => run(() => rpc('sys_platform_set_company_group', { p_company_id: c.id, p_group_id: e.target.value || null }), 'Grup diperbarui.')}>
                      <option value="">— Tanpa grup —</option>
                      {groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
                    </select>
                  </td>
                  <td className="right">{c.users}</td>
                  <td className="right">{c.outlets}</td>
                  <td className="right">{formatNumber(c.orders_30d)}</td>
                  <td className="small muted nowrap">{c.last_activity ? formatDateTime(c.last_activity) : '—'}</td>
                  <td>{c.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge badge-danger">Nonaktif</span>}</td>
                  <td className="right">
                    <div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                      {c.id !== profile.home_company_id && c.is_active && (
                        <button className="btn-sm btn-primary" onClick={() => enter(c)} title="Masuk ke PT ini (mode support)"><LogIn size={14} /> Masuk</button>
                      )}
                      {c.id !== profile.home_company_id && (
                        <button className={`btn-sm ${c.is_active ? 'btn-danger' : ''}`} onClick={() => toggleActive(c)}>{c.is_active ? 'Nonaktifkan' : 'Aktifkan'}</button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
              {!shown.length && <tr><td colSpan={9} className="empty">Tidak ada perusahaan.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === 'groups' && (
        <>
          <div className="alert alert-info small">
            <b>Grup usaha</b> = beberapa PT milik pemilik yang sama (mapping, data tiap PT tetap terpisah).
            Pemilik grup bisa pindah antar PT di grupnya lewat pilihan perusahaan di sidebar, dengan akses penuh seperti owner PT tersebut.
            Masukkan PT ke grup dari tab <b>Semua Perusahaan</b>.
          </div>
          <div className="row" style={{ marginBottom: 12 }}>
            <button className="btn-primary" onClick={() => saveGroup()}><Plus size={16} /> Grup baru</button>
          </div>
          <div className="grid" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(320px, 1fr))' }}>
            {groups.map((g) => (
              <div key={g.id} className="card">
                <div className="card-header">
                  <h2>{g.name}</h2>
                  <button className="btn-sm" onClick={() => saveGroup(g)}>Ubah nama</button>
                </div>
                <div className="muted small" style={{ marginBottom: 4 }}>Perusahaan ({g.companies.length})</div>
                <div className="row" style={{ gap: 6, marginBottom: 12 }}>
                  {g.companies.map((c) => <span key={c.id} className="badge badge-primary">🏢 {c.name}</span>)}
                  {!g.companies.length && <span className="muted small">Belum ada PT</span>}
                </div>
                <div className="muted small" style={{ marginBottom: 4 }}>Pemilik grup ({g.members.length})</div>
                <table className="table">
                  <tbody>
                    {g.members.map((m) => (
                      <tr key={m.user_id}>
                        <td><b>{m.full_name}</b><div className="muted small">{m.email ?? '—'} · PT {m.home_company}</div></td>
                        <td className="right">
                          <button className="btn-sm btn-danger" title="Keluarkan dari grup" onClick={async () => {
                            if (await confirm({ title: `Keluarkan ${m.full_name}?`, message: 'User tidak bisa lagi pindah ke PT lain di grup ini.', danger: true, confirmLabel: 'Keluarkan' }))
                              run(() => rpc('sys_platform_remove_group_member', { p_group_id: g.id, p_user_id: m.user_id }), 'Pemilik grup dikeluarkan.');
                          }}><UserMinus size={14} /></button>
                        </td>
                      </tr>
                    ))}
                    {!g.members.length && <tr><td colSpan={2} className="empty">Belum ada pemilik grup.</td></tr>}
                  </tbody>
                </table>
                <button className="btn-sm" style={{ marginTop: 8 }} onClick={() => addMember(g)}><UserPlus size={14} /> Tambah pemilik grup</button>
              </div>
            ))}
            {!groups.length && <div className="card empty">Belum ada grup usaha. Klik <b>Grup baru</b>.</div>}
          </div>
        </>
      )}
    </>
  );
}
