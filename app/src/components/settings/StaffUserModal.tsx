import { useState } from 'react';
import { Copy, RefreshCw } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { errorMessage } from '../../lib/format';
import { generatePassword, invokeStaffUsers, USERNAME_RE } from '../../lib/staff';

interface Role { id: string; name: string; code: string; permissions: string[] }
interface Outlet { id: string; name: string }

const copy = (text: string) => navigator.clipboard?.writeText(text).catch(() => undefined);

// Owner/admin membuat user staf: nama, username, password, role, outlet (tanpa email & tanpa daftar)
export function CreateStaffUserModal({ roles, outlets, onClose, onDone }: { roles: Role[]; outlets: Outlet[]; onClose: () => void; onDone: (msg: string) => void }) {
  const { toast } = useFeedback();
  const staffRoles = roles.filter((r) => !r.permissions.includes('*'));
  const [fullName, setFullName] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState(generatePassword());
  const [roleId, setRoleId] = useState(staffRoles.find((r) => r.code === 'cashier')?.id ?? staffRoles[0]?.id ?? '');
  const [outletIds, setOutletIds] = useState<string[]>(outlets.length === 1 ? [outlets[0].id] : []);
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<{ username: string; password: string } | null>(null);
  const uname = username.trim().toLowerCase();
  const valid = fullName.trim() && USERNAME_RE.test(uname) && password.length >= 8 && roleId && outletIds.length;

  const save = async () => {
    setBusy(true);
    try {
      const r = await invokeStaffUsers<{ username: string }>({ action: 'create', username: uname, password, full_name: fullName.trim(), role_id: roleId, outlet_ids: outletIds });
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
          <select value={roleId} onChange={(e) => setRoleId(e.target.value)}>
            {staffRoles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select></label>
      </div>
      <div style={{ marginTop: 12 }}>
        <div className="muted small" style={{ marginBottom: 6 }}>Akses outlet *</div>
        <div className="choice-list">
          {outlets.map((o) => (
            <button key={o.id} type="button" className={outletIds.includes(o.id) ? 'active' : ''}
              onClick={() => setOutletIds((ids) => (ids.includes(o.id) ? ids.filter((x) => x !== o.id) : [...ids, o.id]))}>{o.name}</button>
          ))}
        </div>
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
