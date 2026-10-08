import { useEffect, useMemo, useState } from 'react';
import { useParams } from 'react-router-dom';
import { ArrowLeft, Check, Star } from 'lucide-react';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { APP_NAME } from '../lib/brand';
import '../styles/feedback.css';

/* eslint-disable @typescript-eslint/no-explicit-any */
const STAR_TEXT = ['', 'Kecewa', 'Kurang', 'Biasa', 'Puas', 'Sangat puas'];

// Form ulasan publik dari QR di struk: satu pertanyaan per layar, tombol besar, < 1 menit
export default function FeedbackPage() {
  const { token = '' } = useParams();
  const [form, setForm] = useState<any | null>(null);
  const [step, setStep] = useState(0);
  const [answers, setAnswers] = useState<Record<string, any>>({});
  const [contact, setContact] = useState({ name: '', phone: '', ok: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState<any | null>(null);

  useEffect(() => {
    document.title = `Ulasan · ${APP_NAME}`;
    rpc<any>('public_feedback_form', { p_token: token }).then(setForm).catch((e) => setError(errorMessage(e)));
  }, [token]);

  const questions: any[] = useMemo(() => form?.questions ?? [], [form]);
  const screens = questions.length + (form?.settings?.ask_contact ? 1 : 0);
  const q = questions[step];
  const isContact = step === questions.length;
  const set = (id: string, v: any) => setAnswers((a) => ({ ...a, [id]: v }));
  const canNext = !q || !q.required || answers[q.id] != null;
  const next = () => (step < screens - 1 ? setStep(step + 1) : submit());

  const submit = async () => {
    setBusy(true);
    setError('');
    try {
      setDone(await rpc('public_submit_feedback', { p_token: token, p_answers: answers, p_contact: contact }));
    } catch (e) { setError(errorMessage(e)); } finally { setBusy(false); }
  };

  const brand = form?.brand;
  const head = (
    <header className="fb-head">
      {brand?.logo_url ? <img src={brand.logo_url} alt="" /> : <div className="fb-mono">{(brand?.name ?? form?.outlet ?? 'S').slice(0, 1)}</div>}
      <div><b>{brand?.name ?? form?.outlet}</b>{form?.outlet && brand?.name !== form.outlet && <small>{form.outlet}</small>}</div>
    </header>
  );

  if (!form) return <div className="fb-page"><div className="fb-card">{error || 'Memuat…'}</div></div>;
  if (form.state !== 'open' && !done) {
    const msg: Record<string, string> = {
      invalid: 'Link ulasan tidak valid. Pastikan QR dipindai dari struk asli.',
      done: 'Ulasan untuk kunjungan ini sudah kami terima. Terima kasih! 🙏',
      expired: 'Batas waktu ulasan untuk struk ini sudah lewat. Sampai jumpa di kunjungan berikutnya!',
      disabled: 'Form ulasan sedang tidak aktif.',
    };
    return <div className="fb-page"><div className="fb-card">{form.state !== 'invalid' && head}<p className="fb-center">{msg[form.state] ?? msg.invalid}</p></div></div>;
  }
  if (done) {
    return (
      <div className="fb-page">
        <div className="fb-card fb-done">
          {head}
          <div className="fb-check"><Check size={36} /></div>
          <h1>{done.thank_you}</h1>
          {done.incentive && <div className="fb-incentive">🎁 {done.incentive}</div>}
          {done.google_review_url && (
            <a className="fb-google" href={done.google_review_url} target="_blank" rel="noreferrer">
              <Star size={18} fill="currentColor" /> Bantu kami dengan ulasan di Google Maps
            </a>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="fb-page">
      <div className="fb-card">
        {head}
        {step === 0 && <div className="fb-intro"><h1>{form.settings.title}</h1>{form.settings.intro && <p>{form.settings.intro}</p>}</div>}
        <div className="fb-progress"><span style={{ width: `${((step + 1) / screens) * 100}%` }} /></div>

        {q && (
          <section className="fb-q" key={q.id}>
            <h2>{q.label}{q.required && <span className="fb-req"> *</span>}</h2>
            {q.help && <p className="fb-help">{q.help}</p>}

            {q.kind === 'stars' && (
              <>
                <div className="fb-stars" role="radiogroup" aria-label={q.label}>
                  {[1, 2, 3, 4, 5].map((v) => (
                    <button key={v} type="button" role="radio" aria-checked={answers[q.id] === v} aria-label={`${v} bintang`}
                      className={answers[q.id] >= v ? 'on' : ''} onClick={() => { set(q.id, v); if (q.is_overall) setTimeout(() => setStep((s) => Math.min(s + 1, screens - 1)), 350); }}>
                      <Star size={40} fill="currentColor" />
                    </button>
                  ))}
                </div>
                <div className="fb-star-text">{STAR_TEXT[answers[q.id] ?? 0]}</div>
              </>
            )}

            {q.kind === 'aspects' && (
              <div className="fb-aspects">
                {q.options.map((a: string) => (
                  <div key={a} className="fb-aspect">
                    <span>{a}</span>
                    <div className="fb-mini-stars">
                      {[1, 2, 3, 4, 5].map((v) => (
                        <button key={v} type="button" aria-label={`${a} ${v} bintang`} className={(answers[q.id]?.[a] ?? 0) >= v ? 'on' : ''}
                          onClick={() => set(q.id, { ...(answers[q.id] ?? {}), [a]: v })}><Star size={24} fill="currentColor" /></button>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {q.kind === 'nps' && (
              <>
                <div className="fb-nps">
                  {Array.from({ length: 11 }, (_, v) => (
                    <button key={v} type="button" className={`${answers[q.id] === v ? 'on' : ''} ${v <= 6 ? 'lo' : v <= 8 ? 'mid' : 'hi'}`} onClick={() => set(q.id, v)}>{v}</button>
                  ))}
                </div>
                <div className="fb-nps-legend"><span>Tidak mungkin</span><span>Sangat mungkin</span></div>
              </>
            )}

            {q.kind === 'choice' && (
              <div className="fb-chips">
                {q.options.map((o: string) => {
                  const on = (answers[q.id] ?? []).includes(o);
                  return <button key={o} type="button" className={on ? 'on' : ''} onClick={() => set(q.id, on ? answers[q.id].filter((x: string) => x !== o) : [...(answers[q.id] ?? []), o])}>{on && <Check size={15} />} {o}</button>;
                })}
              </div>
            )}

            {q.kind === 'text' && (
              <textarea className="fb-text" rows={4} maxLength={1000} placeholder="Tulis di sini…" value={answers[q.id] ?? ''} onChange={(e) => set(q.id, e.target.value || null)} />
            )}
          </section>
        )}

        {isContact && (
          <section className="fb-q">
            <h2>Boleh kami hubungi?</h2>
            <p className="fb-help">Opsional. Supaya kami bisa menindaklanjuti masukanmu.</p>
            <input className="fb-input" placeholder="Nama" value={contact.name} onChange={(e) => setContact({ ...contact, name: e.target.value })} />
            <input className="fb-input" placeholder="No. WhatsApp" inputMode="tel" value={contact.phone} onChange={(e) => setContact({ ...contact, phone: e.target.value })} />
            <label className="fb-consent"><input type="checkbox" checked={contact.ok} onChange={(e) => setContact({ ...contact, ok: e.target.checked })} /> Saya bersedia dihubungi terkait ulasan ini</label>
          </section>
        )}

        {error && <div className="fb-error">{error}</div>}
        <div className="fb-nav">
          {step > 0 ? <button type="button" className="fb-back" onClick={() => setStep(step - 1)} aria-label="Kembali"><ArrowLeft size={20} /></button> : <span />}
          <button type="button" className="fb-next" disabled={!canNext || busy} onClick={next}>
            {busy ? 'Mengirim…' : step === screens - 1 ? 'Kirim ulasan' : q && !q.required && answers[q.id] == null ? 'Lewati' : 'Lanjut'}
          </button>
        </div>
      </div>
      <p className="fb-powered">powered by {APP_NAME}</p>
    </div>
  );
}
