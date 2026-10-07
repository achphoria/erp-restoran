import { useState } from 'react';
import { Camera } from 'lucide-react';
import Modal from './Modal';
import Avatar from './Avatar';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from './Feedback';
import { rpc, supabase } from '../lib/supabase';
import { uploadAvatar } from '../lib/image';
import { errorMessage } from '../lib/format';
import { STAFF_EMAIL_DOMAIN } from '../lib/staff';

// Edit profil: sendiri (tanpa userId) atau user lain (owner, butuh user.manage)
export default function ProfileModal({ onClose, user, onSaved }: {
  onClose: () => void;
  user?: { id: string; full_name: string; phone: string | null; avatar_url: string | null; email?: string | null };
  onSaved?: () => void;
}) {
  const { profile, refreshProfile } = useAuth();
  const { toast } = useFeedback();
  const self = !user || user.id === profile?.user_id;
  const target = user ?? { id: profile!.user_id, full_name: profile!.full_name, phone: profile!.phone, avatar_url: profile!.avatar_url, email: profile!.email };
  const [name, setName] = useState(target.full_name);
  const [phone, setPhone] = useState(target.phone ?? '');
  const [avatar, setAvatar] = useState(target.avatar_url ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');

  const changePassword = async () => {
    if (newPassword.length < 8) return setError('Password minimal 8 karakter');
    if (newPassword !== confirmPassword) return setError('Konfirmasi password tidak sama');
    setBusy(true);
    setError('');
    try {
      const { error: e } = await supabase.auth.updateUser({ password: newPassword });
      if (e) throw e;
      setNewPassword(''); setConfirmPassword('');
      toast('Password diganti');
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const onPhoto = async (file?: File) => {
    if (!file) return;
    setBusy(true);
    setError('');
    try {
      setAvatar(await uploadAvatar(profile!.company_id, target.id, file));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    setBusy(true);
    setError('');
    try {
      if (self) await rpc('sys_update_my_profile', { p_full_name: name, p_phone: phone, p_avatar_url: avatar });
      else await rpc('sys_update_user_profile', { p_user_id: target.id, p_full_name: name, p_phone: phone, p_avatar_url: avatar });
      if (self) await refreshProfile();
      toast('Profil disimpan');
      onSaved?.();
      onClose();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title={self ? 'Profil Saya' : `Profil ${target.full_name}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !name.trim()} onClick={save}>Simpan</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="row" style={{ gap: 16, marginBottom: 16, flexWrap: 'nowrap' }}>
        <Avatar name={name} src={avatar} size={84} />
        <div className="grid" style={{ gap: 8 }}>
          <label className="btn btn-sm" style={{ cursor: 'pointer' }}>
            <Camera size={16} /> {avatar ? 'Ganti foto' : 'Upload foto'}
            <input type="file" accept="image/*" hidden disabled={busy} onChange={(e) => onPhoto(e.target.files?.[0])} />
          </label>
          {avatar && <button className="btn-sm btn-danger" onClick={() => setAvatar('')}>Hapus foto</button>}
        </div>
      </div>
      <div className="grid">
        <label className="field"><span>Nama lengkap</span><input value={name} onChange={(e) => setName(e.target.value)} /></label>
        <label className="field"><span>Nomor HP / WhatsApp</span><input inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="0812…" /></label>
        {target.email && (target.email.endsWith(`@${STAFF_EMAIL_DOMAIN}`)
          ? <label className="field"><span>Username (login)</span><input value={target.email.split('@')[0]} disabled /></label>
          : <label className="field"><span>Email (login)</span><input value={target.email} disabled /></label>)}
        {self && <div className="muted small">Role: <b>{profile?.role_name}</b> · {profile?.company_name}</div>}
      </div>
      {self && (
        <details className="password-box">
          <summary>Ganti password</summary>
          <div className="form-grid" style={{ marginTop: 10 }}>
            <label className="field"><span>Password baru (min. 8)</span><input type="password" autoComplete="new-password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} /></label>
            <label className="field"><span>Ulangi password baru</span><input type="password" autoComplete="new-password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} /></label>
          </div>
          <button className="btn-sm" style={{ marginTop: 8 }} disabled={busy || !newPassword} onClick={changePassword}>Simpan password</button>
        </details>
      )}
    </Modal>
  );
}
