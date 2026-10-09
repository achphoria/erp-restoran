import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Check, Rocket, X } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from './Feedback';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { GUIDE_STEPS } from '../lib/modules';
import '../styles/modules.css';

// Panduan memulai di Dashboard (khusus owner): langkah sesuai modul aktif, tercentang otomatis dari data
export default function SetupGuide() {
  const { profile, hasModule, refreshProfile } = useAuth();
  const { toast } = useFeedback();
  const [done, setDone] = useState<Record<string, boolean> | null>(null);
  const show = !!profile?.permissions.includes('*') && !profile.acting_mode && !!profile.modules && !profile.modules.guide_dismissed_at;
  useEffect(() => { if (show) rpc<Record<string, boolean>>('sys_setup_progress').then(setDone).catch(() => setDone(null)); }, [show]);
  if (!show || !done) return null;

  const steps = GUIDE_STEPS.filter((s) => hasModule(s.module));
  const main = steps.filter((s) => !s.optional);
  const doneMain = main.filter((s) => done[s.key]).length;
  const pct = Math.round((doneMain / Math.max(main.length, 1)) * 100);
  const hide = async () => {
    try { await rpc('sys_dismiss_setup_guide', { p_dismiss: true }); await refreshProfile(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <div className="card guide" style={{ marginBottom: 16 }}>
      <div className="guide-head">
        <Rocket size={20} style={{ color: 'var(--accent)' }} />
        <h2>Panduan memulai</h2>
        <div className="guide-bar" title={`${pct}%`}><span style={{ width: `${pct}%` }} /></div>
        <b className="small">{doneMain}/{main.length} langkah utama</b>
        <button type="button" className="btn-sm" onClick={hide} title="Sembunyikan panduan"><X size={14} /> {pct === 100 ? 'Selesai' : 'Sembunyikan'}</button>
      </div>
      {pct === 100 && <p className="small" style={{ margin: 0 }}>🎉 Langkah utama sudah lengkap, Juragan. Langkah opsional di bawah bisa dicoba kapan saja.</p>}
      <ul className="guide-list">
        {steps.map((s) => (
          <li key={s.key}>
            <Link to={s.to} className={`guide-step ${done[s.key] ? 'done' : ''}`}>
              <span className="tick">{done[s.key] && <Check size={13} />}</span>
              <span>{s.optional && <span className="opt">Opsional</span>}<b>{s.title}</b><small>{s.desc}</small></span>
            </Link>
          </li>
        ))}
      </ul>
      <p className="small muted" style={{ margin: 0 }}>Modul bisa diubah kapan saja di <Link to="/settings?tab=modules">Pengaturan → Modul</Link>.
        {hasModule('ai') && ' Bingung? Tanya Semar di Pendopo di bawah.'}</p>
    </div>
  );
}
