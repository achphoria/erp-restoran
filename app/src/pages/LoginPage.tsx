import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import Logo from '../components/Logo';
import { APP_TAGLINE } from '../lib/brand';
import { errorMessage } from '../lib/format';
import { toLoginEmail } from '../lib/staff';

export default function LoginPage() {
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');

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
    <div className="auth-page">
      <div className="auth-card">
        <Logo size={52} withName subtitle={APP_TAGLINE} />
        <h1>{mode === 'login' ? 'Selamat datang kembali' : 'Buat akun baru'}</h1>
        <p className="muted">{mode === 'login' ? 'Masuk ke akun Anda' : 'Daftar khusus pemilik usaha. Staf dibuatkan akun oleh owner.'}</p>
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
            <input
              type="password" required minLength={6} value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
            />
          </label>
          <button className="btn-primary btn-lg" disabled={busy}>
            {busy ? 'Memproses…' : mode === 'login' ? 'Masuk' : 'Daftar'}
          </button>
          <button type="button" onClick={() => setMode(mode === 'login' ? 'register' : 'login')}>
            {mode === 'login' ? 'Belum punya akun? Daftar' : 'Sudah punya akun? Masuk'}
          </button>
        </form>
      </div>
    </div>
  );
}
