import { useState, type FormEvent } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { ArrowLeft, Eye, EyeOff } from 'lucide-react';
import { supabase } from '../lib/supabase';
import Gunungan from '../components/Gunungan';
import { APP_LONG_NAME, APP_NAME } from '../lib/brand';
import { errorMessage } from '../lib/format';
import { toLoginEmail } from '../lib/staff';
import '../styles/landing.css';

export default function LoginPage() {
  const [params] = useSearchParams();
  const [mode, setMode] = useState<'login' | 'register'>(params.get('daftar') ? 'register' : 'login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPass, setShowPass] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const logo = `${import.meta.env.BASE_URL}favicon.svg`;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    setInfo('');
    try {
      if (mode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({ email: toLoginEmail(email), password });
        if (error) throw error;
      } else {
        const { data, error } = await supabase.auth.signUp({ email, password });
        if (error) throw error;
        if (!data.session) {
          setInfo('Pendaftaran berhasil. Cek email Anda untuk konfirmasi, lalu masuk.');
          setMode('login');
        }
      }
    } catch (err) {
      const msg = errorMessage(err);
      setError(msg === 'Invalid login credentials' ? (mode === 'login' ? 'Email/username atau password salah' : msg) : msg);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login-split landing">
      {/* panel kelir */}
      <aside className="login-kelir">
        <div className="lp-blencong" />
        <Link to="/" className="login-kelir-brand">
          <img src={logo} alt="" width={44} height={44} />
          <span><b>{APP_NAME}</b><small>{APP_LONG_NAME}</small></span>
        </Link>
        <Gunungan className="login-gunungan" />
        <div className="login-quote">
          <b>“Urip iku urup.”</b>
          <span>Hidup itu menyala: memberi terang bagi sekitarnya.</span>
        </div>
      </aside>

      {/* form */}
      <main className="login-panel">
        <div className="login-box">
          <Link to="/" className="login-back"><ArrowLeft size={15} /> Beranda</Link>
          <div className="login-mobile-brand">
            <img src={logo} alt="" width={40} height={40} />
            <span><b>{APP_NAME}</b><small>{APP_LONG_NAME}</small></span>
          </div>
          <h1>{mode === 'login' ? 'Sugeng rawuh 🙏' : 'Daftarkan usaha Anda'}</h1>
          <p className="muted" style={{ margin: 0 }}>
            {mode === 'login' ? `Selamat datang kembali. Masuk untuk melanjutkan ke ${APP_NAME}.`
              : 'Khusus pemilik usaha. Akun kasir & staf nanti dibuatkan oleh owner dari aplikasi.'}
          </p>
          <form onSubmit={submit}>
            {error && <div className="alert alert-error">{error}</div>}
            {info && <div className="alert alert-success">{info}</div>}
            <label className="field">
              <span>{mode === 'login' ? 'Email atau username' : 'Email (pemilik usaha)'}</span>
              <input type={mode === 'login' ? 'text' : 'email'} required value={email} onChange={(e) => setEmail(e.target.value)}
                autoComplete="username" autoCapitalize="none" autoCorrect="off" spellCheck={false}
                placeholder={mode === 'login' ? 'email@usaha.com atau andi.pluit' : 'email@usaha.com'} />
            </label>
            <label className="field">
              <span>Password</span>
              <div className="login-pass">
                <input
                  type={showPass ? 'text' : 'password'} required minLength={6} value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
                />
                <button type="button" onClick={() => setShowPass((v) => !v)} aria-label={showPass ? 'Sembunyikan password' : 'Lihat password'}>
                  {showPass ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>
            </label>
            <button className="btn-primary btn-lg" disabled={busy}>
              {busy ? 'Memproses…' : mode === 'login' ? 'Masuk' : 'Daftar'}
            </button>
            <div className="login-switch">
              {mode === 'login' ? 'Belum punya akun usaha?' : 'Sudah punya akun?'}
              <button type="button" onClick={() => { setMode(mode === 'login' ? 'register' : 'login'); setError(''); setInfo(''); }}>
                {mode === 'login' ? 'Daftar' : 'Masuk'}
              </button>
            </div>
            {mode === 'login' && <p className="muted small" style={{ margin: 0, textAlign: 'center' }}>Staf: masuk dengan username dari owner, tanpa email.</p>}
          </form>
        </div>
      </main>
    </div>
  );
}
