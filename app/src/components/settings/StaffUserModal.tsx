import { useState } from 'react';
import { Copy, RefreshCw } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { errorMessage } from '../../lib/format';
import { generatePassword, invokeStaffUsers, USERNAME_RE } from '../../lib/staff';
import { rpc } from '../../lib/supabase';
import BranchAccessPicker, { accessValid, type OutletScope } from './BranchAccessPicker';

interface Role { id: string; name: string; code: string; permissions: string[]; default_outlet_scope?: OutletScope }
interface Outlet { id: string; name: string; brand_id?: string }
interface Brand { id: string; name: string; is_active: boolean }

const copy = (text: string) => navigator.clipboard?.writeText(text).catch(() => undefined);

// Owner/admin membuat user staf: nama, username, password, role, outlet (tanpa email & tanpa daftar)
// defaultName/defaultRoleId/defaultOutletId: dipakai saat dibuat dari data karyawan (SDM); onCreated menerima id user baru
export function CreateStaffUserModal({ roles, outlets, brands = [], onClose, onDone, defaultName, defaultRoleId, defaultOutletId, onCreated }: {
  roles: Role[]; outlets: Outlet[]; brands?: Brand[]; onClose: () => void; onDone: (msg: string) => void;
  defaultName?: string; defaultRoleId?: string | null; defaultOutletId?: string | null; onCreated?: (userId: string) => Promise<void> | void;
}) {
  const { toast } = useFeedback();
  const staffRoles = roles.filter((r) => !r.permissions.includes('*'));
  const [fullName, setFullName] = useState(defaultName ?? '');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState(generatePassword());
  const [roleId, setRoleId] = useState((defaultRoleId && staffRoles.some((r) => r.id === defaultRoleId) ? defaultRoleId : null) ?? staffRoles.find((r) => r.code === 'cashier')?.id ?? staffRoles[0]?.id ?? '');
  const [outletIds, setOutletIds] = useState<string[]>(defaultOutletId ? [defaultOutletId] : outlets.length === 1 ? [outlets[0].id] : []);
  const [scope, setScope] = useState<OutletScope>(staffRoles.find((r) => r.id === roleId)?.default_outlet_scope ?? 'selected');
  const [brandIds, setBrandIds] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<{ username: string; password: string } | null>(null);
  const uname = username.trim().toLowerCase();
  const valid = fullName.trim() && USERNAME_RE.test(uname) && password.length >= 8 && roleId && accessValid(scope, outletIds, brandIds);

  const save = async () => {
    setBusy(true);
    try {
      const ids = scope === 'all' ? outlets.map((o) => o.id)
        : scope === 'brands' ? outlets.filter((o) => o.brand_id && brandIds.includes(o.brand_id)).map((o) => o.id) : outletIds;
      const r = await invokeStaffUsers<{ username: string; user_id: string }>({ action: 'create', username: uname, password, full_name: fullName.trim(), role_id: roleId, outlet_ids: ids });
      await rpc('sys_set_user_access', { p_user_id: r.user_id, p_role_id: roleId, p_outlet_scope: scope, p_outlet_ids: ids, p_is_active: true, p_brand_ids: scope === 'brands' ? brandIds : null });
      await onCreated?.(r.user_id);
      setCreated({ username: r.username, password });
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  if (created) {
    return (
      <Modal title="User berhasil dibuat" onClose={() => onDone(`User ${created.username} dibuat.`)}
        footer={<button className="btn-primary" onClick={() => onDone(`User ${created.username} dibuat.`)}>Selesai</button>}>
        <p style={{ marginTop: 0 }}>Berikan data login ini ke <b>{fullName}</b>. Password tidak bisa dilihat lagi setelah jendela ini ditutup.</p>
        <div className="credential-box">
          <div><span className="muted small">Username</span><b>{created.username}</b></div>
          <div><span className="muted small">Password</span><b>{created.password}</b></div>
        </div>
        <button className="btn-sm" style={{ marginTop: 10 }} onClick={() => { copy(`Username: ${created.username}\nPassword: ${created.password}`); toast('Disalin', 'info'); }}>
          <Copy size={14} /> Salin username & password</button>
        <p className="muted small">Staf login di halaman masuk dengan mengetik <b>username</b> (tanpa email). Password bisa diganti staf sendiri lewat menu Profil.</p>
      </Modal>
    );
  }

  return (
    <Modal title="Tambah User Staf" onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={!valid || busy} onClick={save}>{busy ? 'Membuat…' : 'Buat user'}</button></>}>
      <div className="form-grid">
        <label className="field"><span>Nama lengkap *</span><input value={fullName} autoFocus onChange={(e) => setFullName(e.target.value)} placeholder="mis. Andi Saputra" /></label>
        <label className="field"><span>Username *</span>
          <input value={username} autoCapitalize="none" autoCorrect="off" spellCheck={false} placeholder="mis. andi.pluit"
            onChange={(e) => setUsername(e.target.value.replace(/\s/g, '').toLowerCase())} />
          {username && !USERNAME_RE.test(uname) && <small style={{ color: 'var(--danger)' }}>3–32 karakter: huruf kecil, angka, titik, minus, garis bawah</small>}
        </label>
        <label className="field"><span>Password * (min. 8)</span>
          <div className="row" style={{ flexWrap: 'nowrap' }}>
            <input value={password} onChange={(e) => setPassword(e.target.value)} style={{ flex: 1 }} autoComplete="new-password" />
            <button type="button" className="btn-sm" title="Buat password acak" onClick={() => setPassword(generatePassword())}><RefreshCw size={14} /></button>
          </div></label>
        <label className="field"><span>Role *</span>
          <select value={roleId} onChange={(e) => { setRoleId(e.target.value); setScope(staffRoles.find((r) => r.id === e.target.value)?.default_outlet_scope ?? 'selected'); }}>
            {staffRoles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select></label>
      </div>
      <div style={{ marginTop: 12 }}>
        <BranchAccessPicker outlets={outlets} brands={brands.filter((b) => b.is_active)} scope={scope} outletIds={outletIds} brandIds={brandIds}
          onChange={(s, ids, bids) => { setScope(s); setOutletIds(ids); setBrandIds(bids); }} />
      </div>
      <p className="muted small">Tips: pakai pola <b>nama.outlet</b> supaya username unik, mis. <code>andi.pluit</code>. Role Owner tidak bisa diberikan ke staf.</p>
    </Modal>
  );
}

// Reset password user staf (username)
export function ResetPasswordModal({ user, onClose, onDone }: { user: { id: string; full_name: string; username: string }; onClose: () => void; onDone: (msg: string) => void }) {
  const { toast } = useFeedback();
  const [password, setPassword] = useState(generatePassword());
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  const save = async () => {
    setBusy(true);
    try {
      await invokeStaffUsers({ action: 'reset_password', user_id: user.id, password });
      setDone(true);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal title={`Reset password · ${user.full_name}`} onClose={onClose}
      footer={done
        ? <button className="btn-primary" onClick={() => onDone(`Password ${user.username} diganti.`)}>Selesai</button>
        : <><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || password.length < 8} onClick={save}>Simpan password baru</button></>}>
      {done ? (
        <>
          <div className="credential-box">
            <div><span className="muted small">Username</span><b>{user.username}</b></div>
            <div><span className="muted small">Password baru</span><b>{password}</b></div>
          </div>
          <button className="btn-sm" style={{ marginTop: 10 }} onClick={() => { copy(`Username: ${user.username}\nPassword: ${password}`); toast('Disalin', 'info'); }}>
            <Copy size={14} /> Salin</button>
        </>
      ) : (
        <label className="field"><span>Password baru (min. 8)</span>
          <div className="row" style={{ flexWrap: 'nowrap' }}>
            <input value={password} onChange={(e) => setPassword(e.target.value)} style={{ flex: 1 }} autoComplete="new-password" />
            <button type="button" className="btn-sm" onClick={() => setPassword(generatePassword())}><RefreshCw size={14} /></button>
          </div></label>
      )}
    </Modal>
  );
}
