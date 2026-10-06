import { useEffect, useState, type FormEvent } from 'react';
import { useAuth } from '../context/AuthContext';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/format';

interface Invitation {
  id: string;
  company_name: string;
  role_name: string;
}

export default function OnboardingPage() {
  const { refreshProfile, signOut, session } = useAuth();
  const [invitations, setInvitations] = useState<Invitation[] | null>(null);
  const [createNew, setCreateNew] = useState(false);
  const [companyName, setCompanyName] = useState('');
  const [outletName, setOutletName] = useState('');
  const [fullName, setFullName] = useState('');
  const [withDemo, setWithDemo] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    rpc<Invitation[]>('sys_get_my_invitations')
      .then(setInvitations)
      .catch(() => setInvitations([]));
  }, []);

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError('');
    try {
      await fn();
      await refreshProfile();
    } catch (err) {
      setError(errorMessage(err));
      setBusy(false);
    }
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(() => rpc('sys_onboard_company', {
      p_company_name: companyName,
      p_outlet_name: outletName,
      p_full_name: fullName,
      p_with_demo_data: withDemo,
    }));
  };

  const nameField = (
    <label className="field">
      <span>Nama Anda</span>
      <input required value={fullName} onChange={(e) => setFullName(e.target.value)} placeholder="Andi" />
    </label>
  );

  if (invitations === null) {
    return <div className="auth-page"><p className="muted">Memuat…</p></div>;
  }

  // Ada undangan: tawarkan bergabung
  if (invitations.length > 0 && !createNew) {
    return (
      <div className="auth-page">
        <div className="card auth-card">
          <h1>Anda diundang! ✉️</h1>
          <p className="muted">Login sebagai {session?.user.email}</p>
          <div className="grid" style={{ marginTop: 16 }}>
            {error && <div className="alert alert-error">{error}</div>}
            {nameField}
            {invitations.map((inv) => (
              <div key={inv.id} className="card" style={{ background: 'var(--surface-2)' }}>
                <div className="bold">{inv.company_name}</div>
                <div className="muted small" style={{ marginBottom: 8 }}>sebagai {inv.role_name}</div>
                <button className="btn-primary btn-block" disabled={busy || !fullName.trim()}
                  onClick={() => run(() => rpc('sys_accept_invitation', { p_invitation_id: inv.id, p_full_name: fullName }))}>
                  Terima & Bergabung
                </button>
              </div>
            ))}
            <button onClick={() => setCreateNew(true)}>Buat restoran baru saja</button>
            <button onClick={signOut}>Keluar</button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="auth-page">
      <div className="card auth-card">
        <h1>Selamat datang! 👋</h1>
        <p className="muted">Siapkan restoran Anda. Login sebagai {session?.user.email}</p>
        <form onSubmit={submit}>
          {error && <div className="alert alert-error">{error}</div>}
          {nameField}
          <label className="field">
            <span>Nama Restoran / Perusahaan</span>
            <input required value={companyName} onChange={(e) => setCompanyName(e.target.value)} placeholder="Warung Nusantara" />
          </label>
          <label className="field">
            <span>Nama Outlet Pertama</span>
            <input required value={outletName} onChange={(e) => setOutletName(e.target.value)} placeholder="Cabang Kemang" />
          </label>
          <label className="row">
            <input type="checkbox" checked={withDemo} onChange={(e) => setWithDemo(e.target.checked)} />
            Isi dengan data contoh (menu, meja, bahan baku, resep, supplier)
          </label>
          <button className="btn-primary btn-lg" disabled={busy}>
            {busy ? 'Menyiapkan…' : 'Mulai'}
          </button>
          {invitations.length > 0 && <button type="button" onClick={() => setCreateNew(false)}>← Lihat undangan</button>}
          <button type="button" onClick={signOut}>Keluar</button>
          <p className="muted small">
            Staf restoran? Minta owner mengundang email Anda dari menu Pengaturan, lalu muat ulang halaman ini.
          </p>
        </form>
      </div>
    </div>
  );
}
