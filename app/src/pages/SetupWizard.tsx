import { useState } from 'react';
import { ArrowLeft, ArrowRight, Check } from 'lucide-react';
import { useFeedback } from '../components/Feedback';
import ModuleCards from '../components/settings/ModuleCards';
import { useAuth } from '../context/AuthContext';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { APP_NAME } from '../lib/brand';
import { BUSINESS_TYPES, GUIDE_STEPS, MODULE_BY_KEY, MODULE_KEYS, type BusinessType, type ModuleKey } from '../lib/modules';
import '../styles/modules.css';

// Wizard pertama kali untuk owner baru: tipe usaha -> pilih modul -> langkah awal.
// Pilihan bisa diubah kapan saja di Pengaturan -> Modul.
export default function SetupWizard() {
  const { profile, refreshProfile } = useAuth();
  const { toast } = useFeedback();
  const [step, setStep] = useState(0);
  const [type, setType] = useState<BusinessType | null>(null);
  const [mods, setMods] = useState<ModuleKey[]>([]);
  const [busy, setBusy] = useState(false);

  const pickType = (t: BusinessType) => { setType(t); setMods(BUSINESS_TYPES.find((x) => x.key === t)!.modules); };
  const finish = async (all = false) => {
    setBusy(true);
    try {
      await rpc('sys_save_modules', { p_modules: all || MODULE_KEYS.every((k) => mods.includes(k)) ? null : mods, p_business_type: type, p_finish: true });
      await refreshProfile();   // App otomatis pindah ke Dashboard (wizard selesai)
    } catch (e) { toast(errorMessage(e), 'error'); setBusy(false); }
  };
  const has = (k?: ModuleKey) => !k || mods.includes(k);
  const firstSteps = GUIDE_STEPS.filter((s) => has(s.module) && !s.optional);
  const STEPS = ['Tipe usaha', 'Pilih modul', 'Siap mulai'];

  return (
    <div className="setup-wrap">
      <header className="setup-head">
        <img src={`${import.meta.env.BASE_URL}favicon.svg`} alt="" width={32} height={32} />
        <b>{APP_NAME}</b>
        <ol className="setup-steps">
          {STEPS.map((s, i) => <li key={s} className={i === step ? 'now' : i < step ? 'done' : ''}><span>{i < step ? <Check size={12} /> : i + 1}</span><b>{s}</b></li>)}
        </ol>
      </header>

      <main className="setup-body">
        {step === 0 && (
          <>
            <h1>Sugeng rawuh, {profile?.full_name?.split(' ')[0]} 🙏</h1>
            <p className="lead">Usaha <b>{profile?.company_name}</b> seperti apa? Kami siapkan modul yang cocok, Anda tetap bisa menambah atau mengurangi nanti.</p>
            <div className="setup-types">
              {BUSINESS_TYPES.map((t) => (
                <button key={t.key} type="button" className={`setup-type ${type === t.key ? 'on' : ''}`} onClick={() => pickType(t.key)}>
                  <span className="emoji">{t.emoji}</span>
                  <b>{t.name}</b>
                  <small>{t.desc}</small>
                  <span className="chips">{t.modules.slice(0, 6).map((k) => <span key={k}>{MODULE_BY_KEY[k].name}</span>)}{t.modules.length > 6 && <span>+{t.modules.length - 6}</span>}</span>
                </button>
              ))}
            </div>
          </>
        )}

        {step === 1 && (
          <>
            <h1>Modul yang Anda pakai</h1>
            <p className="lead">Sudah kami centang sesuai tipe usaha. Klik kartu untuk menyalakan / mematikan. Modul yang tidak dipakai tidak muncul di menu, supaya tim tidak bingung.</p>
            <ModuleCards value={mods} onChange={setMods} />
          </>
        )}

        {step === 2 && (
          <>
            <h1>Siap mulai! 🎉</h1>
            <p className="lead">{mods.length} modul aktif: {mods.map((k) => MODULE_BY_KEY[k].name).join(', ') || 'modul inti saja'}.</p>
            <div className="card">
              <h3 style={{ marginTop: 0 }}>Langkah pertama Anda</h3>
              <p className="muted small" style={{ marginTop: 0 }}>Checklist ini juga muncul di Dashboard dan tercentang otomatis saat dikerjakan.</p>
              <ol className="guide-list" style={{ listStyle: 'none' }}>
                {firstSteps.map((s, i) => (
                  <li key={s.key} className="guide-step"><span className="tick">{i + 1}</span><span><b>{s.title}</b><small>{s.desc}</small></span></li>
                ))}
              </ol>
            </div>
          </>
        )}
      </main>

      <footer className="setup-foot">
        {step > 0 && <button type="button" onClick={() => setStep(step - 1)}><ArrowLeft size={16} /> Kembali</button>}
        <button type="button" className="btn-ghost-link" disabled={busy} onClick={() => finish(true)}>Lewati, aktifkan semua modul</button>
        <span className="spacer" />
        <small>Bisa diubah kapan saja di Pengaturan → Modul</small>
        {step < 2
          ? <button type="button" className="btn-primary" disabled={step === 0 && !type} onClick={() => setStep(step + 1)}>Lanjut <ArrowRight size={16} /></button>
          : <button type="button" className="btn-primary" disabled={busy} onClick={() => finish()}>{busy ? 'Menyimpan…' : 'Mulai pakai SEMAR'} <ArrowRight size={16} /></button>}
      </footer>
    </div>
  );
}
