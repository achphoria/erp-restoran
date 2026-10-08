import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { CheckCircle2, LogOut } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { authRedirect, rpc } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import Gunungan from '../components/Gunungan';
import { APP_LONG_NAME, APP_NAME } from '../lib/brand';
import '../styles/landing.css';

interface Invitation {
  id: string;
  company_name: string;
  role_name: string;
}

// Kerangka halaman setelah daftar/konfirmasi email: panel kelir di kiri, isian di kanan (serasi dengan halaman login)
function OnboardingShell({ children }: { children: ReactNode }) {
  const logo = `${import.meta.env.BASE_URL}favicon.svg`;
  return (
    <div className="login-split landing">
      <aside className="login-kelir">
        <div className="lp-blencong" />
        <div className="login-kelir-brand">
          <img src={logo} alt="" width={44} height={44} />
          <span><b>{APP_NAME}</b><small>{APP_LONG_NAME}</small></span>
        </div>
        <Gunungan className="login-gunungan" />
        <ol className="onb-steps">
          <li className="done"><b>Daftar & konfirmasi email</b><span>Akun Anda sudah aktif</span></li>
          <li className="now"><b>Siapkan usaha</b><span>Nama usaha & outlet pertama</span></li>
          <li><b>Mulai jualan</b><span>Atur menu, stok, dan akun kasir</span></li>
        </ol>
      </aside>
      <main className="login-panel">
        <div className="login-box">
          <div className="login-mobile-brand">
            <img src={logo} alt="" width={40} height={40} />
            <span><b>{APP_NAME}</b><small>{APP_LONG_NAME}</small></span>
          </div>
          {children}
        </div>
      </main>
    </div>
  );
}

export default function OnboardingPage() {
  const { refreshProfile, signOut, session } = useAuth();
  const [invitations, setInvitations] = useState<Invitation[] | null>(null);
  const [createNew, setCreateNew] = useState(false);
  const [companyName, setCompanyName] = useState('');
  const [outletName, setOutletName] = useState('');
  const [fullName, setFullName] = useState('');
  // data contoh hanya bila diminta (default kosong, supaya master data owner baru bersih)
  const [withDemo, setWithDemo] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const email = session?.user.email;

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

  // baru klik "Konfirmasi email saya" dari inbox
  const confirmed = authRedirect.type === 'signup' && (
    <div className="onb-confirmed">
      <CheckCircle2 size={22} />
      <span><b>Email berhasil dikonfirmasi</b><small>{email ? `${email} sudah aktif.` : 'Akun Anda sudah aktif.'} Tinggal satu langkah lagi.</small></span>
    </div>
  );

  const nameField = (
    <label className="field">
      <span>Nama Anda</span>
      <input required value={fullName} onChange={(e) => setFullName(e.target.value)} placeholder="mis. Andi Saputra" autoFocus />
    </label>
  );

  const footer = (
    <div className="onb-footer">
      <span className="muted small">Masuk sebagai <b>{email}</b></span>
      <button type="button" className="btn-sm" onClick={signOut}><LogOut size={14} /> Keluar</button>
    </div>
  );

  if (invitations === null) {
    return <OnboardingShell><div className="skeleton" style={{ height: 320 }} /></OnboardingShell>;
  }

  // Ada undangan: tawarkan bergabung
  if (invitations.length > 0 && !createNew) {
    return (
      <OnboardingShell>
        {confirmed}
        <h1>Anda diundang! 🎉</h1>
        <p className="muted" style={{ margin: 0 }}>Isi nama Anda, lalu terima undangan untuk bergabung dengan tim.</p>
        <div className="grid" style={{ marginTop: 20 }}>
          {error && <div className="alert alert-error">{error}</div>}
          {nameField}
          {invitations.map((inv) => (
            <div key={inv.id} className="onb-invite">
              <div><b>{inv.company_name}</b><div className="muted small">sebagai {inv.role_name}</div></div>
              <button className="btn-primary" disabled={busy || !fullName.trim()}
                onClick={() => run(() => rpc('sys_accept_invitation', { p_invitation_id: inv.id, p_full_name: fullName }))}>
                Terima & Bergabung
              </button>
            </div>
          ))}
          <button onClick={() => setCreateNew(true)}>Saya pemilik usaha, buat usaha baru</button>
          {footer}
        </div>
      </OnboardingShell>
    );
  }

  return (
    <OnboardingShell>
      {confirmed}
      <h1>Siapkan usaha Anda</h1>
      <p className="muted" style={{ margin: 0 }}>Cukup tiga isian. Nanti outlet, brand, dan tim bisa ditambah kapan saja.</p>
      <form onSubmit={submit}>
        {error && <div className="alert alert-error">{error}</div>}
        {nameField}
        <label className="field">
          <span>Nama usaha / perusahaan</span>
          <input required value={companyName} onChange={(e) => setCompanyName(e.target.value)} placeholder="mis. Warung Nusantara" />
        </label>
        <label className="field">
          <span>Nama outlet pertama</span>
          <input required value={outletName} onChange={(e) => setOutletName(e.target.value)} placeholder="mis. Cabang Kemang" />
        </label>
        <label className="onb-demo">
          <input type="checkbox" checked={withDemo} onChange={(e) => setWithDemo(e.target.checked)} />
          <span><b>Isi dengan data contoh (untuk mencoba)</b><small>Menu, meja, bahan baku, resep & supplier contoh. Biarkan kosong bila ingin langsung memasukkan data usaha sendiri.</small></span>
        </label>
        <button className="btn-primary btn-lg" disabled={busy}>
          {busy ? 'Menyiapkan usaha Anda…' : 'Mulai pakai SEMAR'}
        </button>
        {invitations.length > 0 && <button type="button" onClick={() => setCreateNew(false)}>← Lihat undangan</button>}
        <p className="muted small" style={{ margin: 0 }}>
          Staf restoran? Tidak perlu membuat usaha. Minta owner membuatkan akun (username) atau mengundang email Anda.
        </p>
        {footer}
      </form>
    </OnboardingShell>
  );
}
