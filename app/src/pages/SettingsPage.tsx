import { Fragment, useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { useFeedback, useNotice } from '../components/Feedback';
import { errorMessage, formatDateTime } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import Modal from '../components/Modal';
import Avatar from '../components/Avatar';
import ProfileModal from '../components/ProfileModal';
import CompanyTab from '../components/settings/CompanyTab';
import ApprovalMatrixTab from '../components/settings/ApprovalMatrixTab';
import PaymentGatewayTab from '../components/settings/PaymentGatewayTab';
import ActivityLogTab from '../components/settings/ActivityLogTab';
import DataToolsTab from '../components/settings/DataToolsTab';
import { CreateStaffUserModal, ResetPasswordModal } from '../components/settings/StaffUserModal';
import BranchAccessPicker, { accessValid, type OutletScope } from '../components/settings/BranchAccessPicker';
import BrandsTab, { type BrandRow } from '../components/settings/BrandsTab';

type Tab = 'company' | 'users' | 'roles' | 'brands' | 'outlets' | 'approvals' | 'payment' | 'logs' | 'data';

interface Role { id: string; code: string; name: string; permissions: string[]; default_outlet_scope?: OutletScope }
interface OutletRow {
  id: string; code: string; name: string; address: string | null; phone: string | null; brand_id: string;
  tax_rate: number; service_charge_rate: number; rounding_unit: number; is_active: boolean;
  is_qr_order_enabled: boolean; qr_requires_confirmation: boolean;
}
interface UserRow {
  id: string; full_name: string; username: string | null; email: string | null; is_active: boolean; phone: string | null; avatar_url: string | null; last_login_at: string | null;
  role_id: string; role_name: string; role_code: string; outlet_ids: string[]; brand_ids: string[]; outlet_scope: OutletScope; created_at: string;
}
interface Invitation { id: string; email: string; role_id: string; outlet_ids: string[]; status: string; created_at: string }

const PERMISSIONS: { key: string; label: string; group: string }[] = [
  { key: 'pos.order', label: 'Membuat order', group: 'Kasir' },
  { key: 'pos.pay', label: 'Menerima pembayaran & shift', group: 'Kasir' },
  { key: 'pos.discount', label: 'Memberi diskon', group: 'Kasir' },
  { key: 'pos.void', label: 'Void order / item', group: 'Kasir' },
  { key: 'pos.refund', label: 'Refund order yang sudah dibayar', group: 'Kasir' },
  { key: 'kds.update', label: 'Layar dapur', group: 'Dapur' },
  { key: 'master.manage', label: 'Kelola menu, harga, meja', group: 'Operasional' },
  { key: 'inventory.manage', label: 'Kelola stok & resep', group: 'Operasional' },
  { key: 'purchasing.manage', label: 'Pembelian & supplier', group: 'Operasional' },
  { key: 'sales.manage', label: 'Sales order, pengiriman, invoice & pelanggan B2B', group: 'Operasional' },
  { key: 'crm.manage', label: 'Pelanggan, promo & voucher', group: 'Operasional' },
  { key: 'report.view', label: 'Dashboard & laporan penjualan', group: 'Laporan' },
  { key: 'finance.view', label: 'Lihat laporan keuangan', group: 'Keuangan' },
  { key: 'finance.manage', label: 'Input biaya, jurnal, bayar supplier, settlement POS', group: 'Keuangan' },
  { key: 'user.manage', label: 'Kelola user & role', group: 'Admin' },
  { key: 'settings.manage', label: 'Kelola perusahaan, outlet, approval & pembayaran online', group: 'Admin' },
  { key: 'audit.view', label: 'Lihat log aktivitas', group: 'Admin' },
  { key: 'hr.view', label: 'Lihat data karyawan', group: 'SDM / HR' },
  { key: 'hr.manage', label: 'Kelola karyawan, jabatan & pengumuman', group: 'SDM / HR' },
  { key: 'approval.purchase_order', label: 'Menyetujui purchase order', group: 'Persetujuan' },
  { key: 'approval.expense', label: 'Menyetujui biaya operasional', group: 'Persetujuan' },
  { key: 'approval.stock_adjustment', label: 'Menyetujui penyesuaian stok & waste', group: 'Persetujuan' },
  { key: 'approval.stock_opname', label: 'Menyetujui stock opname', group: 'Persetujuan' },
  { key: 'approval.refund', label: 'Menyetujui refund', group: 'Persetujuan' },
  { key: 'approval.product', label: 'Menyetujui produk baru', group: 'Persetujuan' },
  { key: 'approval.pricelist', label: 'Menyetujui pricelist supplier', group: 'Persetujuan' },
];

// section 'users' = modul User Management, 'settings' = Pengaturan perusahaan
export default function SettingsPage({ section = 'settings' }: { section?: 'settings' | 'users' }) {
  const { profile, can, refreshProfile } = useAuth();
  const companyId = profile!.company_id;
  const tabs: [Tab, string, boolean, 'settings' | 'users'][] = [
    ['users', 'User', can('user.manage'), 'users'],
    ['roles', 'Role & Hak Akses', can('user.manage'), 'users'],
    ['approvals', 'Approval Transaksi', can('settings.manage'), 'users'],
    ['logs', 'Log Aktivitas', can(['audit.view', 'user.manage']), 'users'],
    ['company', 'Perusahaan & Logo', can('settings.manage'), 'settings'],
    ['brands', 'Brand', can('settings.manage'), 'settings'],
    ['outlets', 'Outlet', can('settings.manage'), 'settings'],
    ['payment', 'Pembayaran Online', can('settings.manage'), 'settings'],
    ['data', 'Data & Backup', !!profile?.permissions.includes('*'), 'settings'],
  ];
  const visible = tabs.filter(([, , ok, sec]) => ok && sec === section);
  const [tab, setTab] = useTabParam<Tab>(visible[0]?.[0] ?? 'company', visible.map(([k]) => k));
  const [roles, setRoles] = useState<Role[]>([]);
  const [outlets, setOutlets] = useState<OutletRow[]>([]);
  const [brands, setBrands] = useState<BrandRow[]>([]);
  const [users, setUsers] = useState<UserRow[]>([]);
  const [staff, setStaff] = useState<{ full_name: string; employee_number: string; user_id: string }[]>([]);
  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [error, setError] = useState('');
  const setNotice = useNotice();

  const load = useCallback(async () => {
    try {
      const [r, o, b] = await Promise.all([
        must(supabase.from('sys_roles').select('*').order('created_at')),
        must(supabase.from('sys_outlets').select('*').order('code')),
        must(supabase.from('sys_brands').select('*').order('created_at')),
      ]);
      setRoles(r as Role[]);
      setOutlets(o as OutletRow[]);
      setBrands(b as BrandRow[]);
      if (section === 'users' && can('user.manage')) {
        const [u, i] = await Promise.all([
          rpc<UserRow[]>('sys_list_users'),
          must(supabase.from('sys_user_invitations').select('*').eq('status', 'pending').order('created_at', { ascending: false })),
        ]);
        setUsers(u);
        // karyawan yang tertaut ke akun (data orang dikelola di SDM / HR)
        if (can(['hr.view', 'hr.manage'])) setStaff(await must(supabase.from('hr_employees').select('full_name, employee_number, user_id').not('user_id', 'is', null)));
        setInvitations(i as Invitation[]);
      }
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [can, section]);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (fn: () => Promise<string | void>) => {
    setError('');
    setNotice('');
    try {
      const msg = await fn();
      if (msg) setNotice(msg);
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>{section === 'users' ? 'User Management' : 'Pengaturan'}</h1>
          <p>{section === 'users' ? 'User & akses branch, role & hak akses, approval transaksi, dan log aktivitas.' : `Perusahaan, brand, outlet, pembayaran online & data · ${profile?.company_name}`}</p>
        </div>
      </div>
      <div className="tabs">
        {visible.map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      {tab === 'users' && (
        <UsersTab companyId={companyId} users={users} staff={staff} invitations={invitations} roles={roles} outlets={outlets} brands={brands}
          currentUserId={profile!.user_id} act={act} />
      )}
      {tab === 'roles' && <RolesTab companyId={companyId} roles={roles} act={act} />}
      {tab === 'brands' && <BrandsTab companyId={companyId} brands={brands} outlets={outlets} act={act} />}
      {tab === 'outlets' && <OutletsTab outlets={outlets} brands={brands} act={act} onCreated={refreshProfile} />}
      {tab === 'company' && <CompanyTab />}
      {tab === 'approvals' && <ApprovalMatrixTab />}
      {tab === 'payment' && <PaymentGatewayTab />}
      {tab === 'logs' && <ActivityLogTab />}
      {tab === 'data' && <DataToolsTab />}
    </>
  );
}

type Act = (fn: () => Promise<string | void>) => Promise<void>;

// ---------------------------------------------------------------- User & undangan
function UsersTab({ companyId, users, staff = [], invitations, roles, outlets, brands, currentUserId, act }: {
  staff?: { full_name: string; employee_number: string; user_id: string }[];
  companyId: string; users: UserRow[]; invitations: Invitation[]; roles: Role[]; outlets: OutletRow[]; brands: BrandRow[];
  currentUserId: string; act: Act;
}) {
  const [inviting, setInviting] = useState(false);
  const [creating, setCreating] = useState(false);
  const [resetting, setResetting] = useState<UserRow | null>(null);
  const [editing, setEditing] = useState<UserRow | null>(null);
  const [editingProfile, setEditingProfile] = useState<UserRow | null>(null);
  const roleName = (id: string) => roles.find((r) => r.id === id)?.name ?? '-';
  const outletNames = (ids: string[]) => ids.map((id) => outlets.find((o) => o.id === id)?.name).filter(Boolean).join(', ');

  return (
    <>
      <div className="card table-wrap">
        <div className="card-header">
          <h2>User</h2>
          <div className="row">
            <button onClick={() => setInviting(true)} title="Untuk staf yang ingin login dengan email sendiri">Undang via email</button>
            <button className="btn-primary" onClick={() => setCreating(true)}>+ Tambah User</button>
          </div>
        </div>
        <table className="table">
          <thead><tr><th>User</th><th>Kontak</th><th>Role</th><th>Branch</th><th>Login terakhir</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id}>
                <td>
                  <div className="row" style={{ flexWrap: 'nowrap' }}>
                    <Avatar name={u.full_name} src={u.avatar_url} size={36} />
                    <span>
                      <b>{u.full_name}{u.id === currentUserId && <span className="muted"> (Anda)</span>}</b>
                      {(() => { const st = staff.find((x) => x.user_id === u.id); return st ? <div className="muted small">👤 {st.employee_number} · data karyawan</div> : null; })()}
                    </span>
                  </div>
                </td>
                <td className="small">{u.username ? <><code>{u.username}</code> <span className="muted">(username)</span></> : u.email}<div className="muted">{u.phone ?? '—'}</div></td>
                <td><span className="badge badge-primary">{u.role_name}</span></td>
                <td className="small">{u.outlet_scope === 'all' ? <span className="badge badge-primary">Semua branch</span>
                  : u.outlet_scope === 'brands' ? <span className="badge badge-primary">Brand: {u.brand_ids.map((id) => brands.find((b) => b.id === id)?.name).filter(Boolean).join(', ')}</span>
                  : u.outlet_ids.length === 1 ? <span title="Terkunci di 1 branch">🔒 {outletNames(u.outlet_ids)}</span> : outletNames(u.outlet_ids) || '-'}</td>
                <td className="small muted">{u.last_login_at ? formatDateTime(u.last_login_at) : 'Belum pernah'}</td>
                <td>{u.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
                <td className="right">
                  <div className="row" style={{ justifyContent: 'flex-end', flexWrap: 'nowrap' }}>
                    <button className="btn-sm" onClick={() => setEditingProfile(u)}>Profil</button>
                    {u.id !== currentUserId && <button className="btn-sm" onClick={() => setEditing(u)}>Akses</button>}
                    {u.username && <button className="btn-sm" onClick={() => setResetting(u)}>Reset password</button>}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card table-wrap">
        <h2 style={{ marginBottom: 12 }}>Undangan Email Menunggu</h2>
        <table className="table">
          <thead><tr><th>Email</th><th>Role</th><th>Outlet</th><th>Dikirim</th><th></th></tr></thead>
          <tbody>
            {invitations.map((i) => (
              <tr key={i.id}>
                <td className="bold">{i.email}</td>
                <td>{roleName(i.role_id)}</td>
                <td className="small">{outletNames(i.outlet_ids)}</td>
                <td>{formatDateTime(i.created_at)}</td>
                <td className="right">
                  <button className="btn-sm btn-danger" onClick={() => act(async () => {
                    await must(supabase.from('sys_user_invitations').update({ status: 'cancelled' }).eq('id', i.id));
                    return 'Undangan dibatalkan.';
                  })}>Batalkan</button>
                </td>
              </tr>
            ))}
            {!invitations.length && <tr><td colSpan={5} className="empty">Tidak ada undangan yang menunggu.</td></tr>}
          </tbody>
        </table>
        <div className="alert alert-info small" style={{ marginTop: 12, marginBottom: 0 }}>
          <b>Cara utama:</b> klik <b>+ Tambah User</b>, isi username & password, lalu berikan ke staf. Staf tidak perlu daftar.
          Undangan email hanya untuk staf yang ingin login dengan email pribadinya (staf mendaftar dengan email tersebut lalu menerima undangan).
        </div>
      </div>

      {inviting && (
        <UserAccessModal title="Undang Staf" roles={roles} outlets={outlets} withEmail
          initial={{ role_id: roles.find((r) => r.code === 'cashier')?.id ?? roles[0]?.id, outlet_ids: outlets.map((o) => o.id), is_active: true }}
          onClose={() => setInviting(false)}
          onSave={async ({ email, role_id, outlet_ids }) => {
            await act(async () => {
              await must(supabase.from('sys_user_invitations').insert({
                company_id: companyId, email: email!.trim().toLowerCase(), role_id, outlet_ids, invited_by: currentUserId,
              }));
              setInviting(false);
              return `Undangan untuk ${email} dibuat. Minta staf mendaftar dengan email tersebut.`;
            });
          }} />
      )}

      {creating && <CreateStaffUserModal roles={roles} outlets={outlets} brands={brands} onClose={() => setCreating(false)}
        onDone={(msg) => { setCreating(false); act(async () => msg); }} />}
      {resetting && <ResetPasswordModal user={{ id: resetting.id, full_name: resetting.full_name, username: resetting.username! }}
        onClose={() => setResetting(null)} onDone={(msg) => { setResetting(null); act(async () => msg); }} />}

      {editingProfile && (
        <ProfileModal user={editingProfile} onClose={() => setEditingProfile(null)} onSaved={() => act(async () => undefined)} />
      )}

      {editing && (
        <UserAccessModal title={`Edit ${editing.full_name}`} roles={roles} outlets={outlets} brands={brands} withActive withScope
          initial={editing}
          onClose={() => setEditing(null)}
          onSave={async ({ role_id, outlet_ids, brand_ids, is_active, outlet_scope }) => {
            await act(async () => {
              await rpc('sys_set_user_access', {
                p_user_id: editing.id, p_role_id: role_id, p_outlet_scope: outlet_scope ?? 'selected', p_outlet_ids: outlet_ids,
                p_is_active: is_active, p_brand_ids: outlet_scope === 'brands' ? brand_ids : null,
              });
              setEditing(null);
              return 'User diperbarui.';
            });
          }} />
      )}
    </>
  );
}

function UserAccessModal({ title, roles, outlets, brands = [], initial, withEmail, withActive, withScope, onClose, onSave }: {
  title: string; roles: Role[]; outlets: OutletRow[]; brands?: BrandRow[];
  initial: { role_id?: string; outlet_ids: string[]; brand_ids?: string[]; is_active: boolean; outlet_scope?: OutletScope };
  withEmail?: boolean; withActive?: boolean; withScope?: boolean;
  onClose: () => void;
  onSave: (v: { email?: string; role_id: string; outlet_ids: string[]; brand_ids: string[]; is_active: boolean; outlet_scope?: OutletScope }) => Promise<void>;
}) {
  const [brandIds, setBrandIds] = useState<string[]>(initial.brand_ids ?? []);
  const [email, setEmail] = useState('');
  const [roleId, setRoleId] = useState(initial.role_id ?? '');
  const [outletIds, setOutletIds] = useState<string[]>(initial.outlet_ids);
  const [isActive, setIsActive] = useState(initial.is_active);
  const [scope, setScope] = useState<OutletScope>(initial.outlet_scope ?? 'selected');
  const [busy, setBusy] = useState(false);
  const isOwnerRole = roles.find((r) => r.id === roleId)?.permissions.includes('*');

  return (
    <Modal title={title} onClose={onClose}
      footer={<>
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || !roleId || (withEmail && !/^\S+@\S+\.\S+$/.test(email)) || (!isOwnerRole && (withScope ? !accessValid(scope, outletIds, brandIds) : !outletIds.length))}
          onClick={async () => {
            setBusy(true);
            await onSave({ email, role_id: roleId, outlet_ids: outletIds, brand_ids: brandIds, is_active: isActive, outlet_scope: withScope ? scope : 'selected' });
            setBusy(false);
          }}>Simpan</button>
      </>}>
      <div className="grid">
        {withEmail && (
          <label className="field"><span>Email staf</span>
            <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="kasir@email.com" autoFocus /></label>
        )}
        <label className="field"><span>Role</span>
          <select value={roleId} onChange={(e) => setRoleId(e.target.value)}>
            {roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select>
        </label>
        {withScope ? (
          <BranchAccessPicker outlets={outlets} brands={brands.filter((b) => b.is_active)} scope={scope} outletIds={outletIds} brandIds={brandIds} ownerRole={isOwnerRole}
            onChange={(s, ids, bids) => { setScope(s); setOutletIds(ids); setBrandIds(bids); }} />
        ) : (
          <div>
            <div className="muted small" style={{ marginBottom: 6 }}>Akses outlet {isOwnerRole && '(owner otomatis bisa akses semua)'}</div>
            <div className="choice-list">
              {outlets.map((o) => (
                <button key={o.id} className={outletIds.includes(o.id) ? 'active' : ''}
                  onClick={() => setOutletIds((ids) => ids.includes(o.id) ? ids.filter((x) => x !== o.id) : [...ids, o.id])}>
                  {o.name}
                </button>
              ))}
            </div>
          </div>
        )}
        {withActive && (
          <label className="row"><input type="checkbox" checked={isActive} onChange={(e) => setIsActive(e.target.checked)} /> Akun aktif (bisa login)</label>
        )}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- Role
function RolesTab({ companyId, roles, act }: { companyId: string; roles: Role[]; act: Act }) {
  const { prompt } = useFeedback();
  const groups = [...new Set(PERMISSIONS.map((p) => p.group))];

  const toggle = (role: Role, key: string) =>
    act(async () => {
      const permissions = role.permissions.includes(key) ? role.permissions.filter((p) => p !== key) : [...role.permissions, key];
      await must(supabase.from('sys_roles').update({ permissions }).eq('id', role.id));
    });

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>Hak Akses per Role</h2>
        <div className="row">
        <button title="GM, Finance, Purchasing, Cost Control, Sales B2B, Marketing, Admin, Head Chef, Gudang, Store Manager, Supervisor" onClick={() => act(async () => {
          const n = await rpc<number>('sys_create_role_templates');
          return n ? `${n} role template dibuat. Atur hak aksesnya di tabel ini atau di Approval Transaksi.` : 'Semua role template sudah ada.';
        })}>Buat role template</button>
        <button onClick={async () => {
          const name = await prompt({ title: 'Role baru', label: 'Nama role', placeholder: 'contoh: Supervisor' });
          if (name?.trim()) {
            act(async () => {
              await must(supabase.from('sys_roles').insert({
                company_id: companyId, name: name.trim(),
                code: name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_'), permissions: [],
              }));
              return `Role ${name} dibuat.`;
            });
          }
        }}>+ Role Baru</button>
        </div>
      </div>
      <table className="table">
        <thead>
          <tr>
            <th>Hak akses</th>
            {roles.map((r) => <th key={r.id} className="right" style={{ textTransform: 'none' }}>{r.name}</th>)}
          </tr>
        </thead>
        <tbody>
          {groups.map((g) => (
            <Fragment key={g}>
              <tr><td colSpan={roles.length + 1} className="bold small" style={{ background: 'var(--surface-2)' }}>{g}</td></tr>
              {PERMISSIONS.filter((p) => p.group === g).map((p) => (
                <tr key={p.key}>
                  <td>{p.label}</td>
                  {roles.map((r) => {
                    const isOwner = r.permissions.includes('*');
                    return (
                      <td key={r.id} className="right">
                        <input type="checkbox" checked={isOwner || r.permissions.includes(p.key)} disabled={isOwner}
                          onChange={() => toggle(r, p.key)} />
                      </td>
                    );
                  })}
                </tr>
              ))}
            </Fragment>
          ))}
        </tbody>
      </table>
      <p className="muted small">Owner selalu punya semua akses. Perubahan berlaku saat user memuat ulang aplikasi.</p>
    </div>
  );
}

// ---------------------------------------------------------------- Outlet
function OutletsTab({ outlets, brands, act, onCreated }: { outlets: OutletRow[]; brands: BrandRow[]; act: Act; onCreated: () => Promise<void> }) {
  const [editing, setEditing] = useState<Partial<OutletRow> | null>(null);

  const save = () => act(async () => {
    const e = editing!;
    if (e.id) {
      await must(supabase.from('sys_outlets').update({
        name: e.name, brand_id: e.brand_id, address: e.address, phone: e.phone, tax_rate: e.tax_rate,
        service_charge_rate: e.service_charge_rate, rounding_unit: e.rounding_unit, is_active: e.is_active,
        is_qr_order_enabled: e.is_qr_order_enabled, qr_requires_confirmation: e.qr_requires_confirmation,
      }).eq('id', e.id));
    } else {
      const o = await rpc<OutletRow>('sys_create_outlet', { p_code: e.code, p_name: e.name, p_address: e.address ?? null, p_brand_id: e.brand_id ?? null });
      await must(supabase.from('sys_outlets').update({
        phone: e.phone, tax_rate: e.tax_rate, service_charge_rate: e.service_charge_rate, rounding_unit: e.rounding_unit,
      }).eq('id', o.id));
    }
    await onCreated();
    setEditing(null);
    return 'Outlet disimpan.';
  });

  const field = (key: keyof OutletRow, label: string, type = 'text', disabled = false) => (
    <label className="field"><span>{label}</span>
      <input type={type} disabled={disabled} value={(editing?.[key] as string | number | undefined) ?? ''}
        onChange={(e) => setEditing({ ...editing, [key]: type === 'number' ? Number(e.target.value) : e.target.value })} />
    </label>
  );

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>Outlet</h2>
        <button className="btn-primary" onClick={() => setEditing({ tax_rate: 10, service_charge_rate: 0, rounding_unit: 100, is_active: true, brand_id: brands[0]?.id })}>+ Outlet Baru</button>
      </div>
      <table className="table">
        <thead><tr><th>Kode</th><th>Nama</th><th>Brand</th><th>Alamat</th><th className="right">PB1</th><th className="right">Service</th><th className="right">Pembulatan</th><th></th></tr></thead>
        <tbody>
          {outlets.map((o) => (
            <tr key={o.id}>
              <td>{o.code}</td>
              <td className="bold">{o.name} {!o.is_active && <span className="badge">Nonaktif</span>}</td>
              <td className="small">{brands.find((b) => b.id === o.brand_id)?.name ?? '—'}</td>
              <td className="small">{o.address}</td>
              <td className="right">{Number(o.tax_rate)}%</td>
              <td className="right">{Number(o.service_charge_rate)}%</td>
              <td className="right">Rp {o.rounding_unit}</td>
              <td className="right"><button className="btn-sm" onClick={() => setEditing(o)}>Edit</button></td>
            </tr>
          ))}
        </tbody>
      </table>

      {editing && (
        <Modal title={editing.id ? `Edit ${editing.name}` : 'Outlet Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button><button className="btn-primary" disabled={!editing.code || !editing.name} onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            {field('code', 'Kode (mis. OUT02)', 'text', !!editing.id)}
            {field('name', 'Nama outlet')}
            <label className="field"><span>Brand</span>
              <select value={editing.brand_id ?? ''} onChange={(ev) => setEditing({ ...editing, brand_id: ev.target.value })}>
                {brands.filter((b) => b.is_active || b.id === editing.brand_id).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
              </select>
              {editing.id && <small className="muted">Menu yang tampil di kasir mengikuti brand outlet.</small>}
            </label>
            {field('address', 'Alamat')}
            {field('phone', 'Telepon')}
            {field('tax_rate', 'Pajak PB1 (%)', 'number')}
            {field('service_charge_rate', 'Service charge (%)', 'number')}
            {field('rounding_unit', 'Pembulatan (Rp)', 'number')}
          </div>
          {editing.id ? (
            <div className="grid" style={{ marginTop: 12 }}>
              <label className="row"><input type="checkbox" checked={!!editing.is_qr_order_enabled}
                onChange={(ev) => setEditing({ ...editing, is_qr_order_enabled: ev.target.checked })} /> Tamu bisa pesan lewat QR meja</label>
              <label className="row"><input type="checkbox" checked={!!editing.qr_requires_confirmation}
                onChange={(ev) => setEditing({ ...editing, qr_requires_confirmation: ev.target.checked })} /> Pesanan QR harus dikonfirmasi kasir sebelum ke dapur</label>
            </div>
          ) : <p className="muted small">Gudang untuk outlet ini dibuat otomatis.</p>}
        </Modal>
      )}
    </div>
  );
}
