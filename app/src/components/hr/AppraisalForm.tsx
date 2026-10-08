import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { Bot, Printer } from 'lucide-react';
import Modal from '../Modal';
import HrPhoto from './HrPhoto';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { GRADES, METRICS, SCALE, STATUS, previewScore, type Criterion, type Scores } from '../../lib/appraisal';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Satu form untuk semua peran: penilaian diri, penilaian atasan / HR, konfirmasi karyawan, dan lihat hasil
export default function AppraisalForm({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { toast, confirm } = useFeedback();
  const [a, setA] = useState<any | null>(null);
  const [scores, setScores] = useState<Scores>({});
  const [text, setText] = useState({ comment: '', strengths: '', improvements: '', goals: '' });
  const [busy, setBusy] = useState(false);
  const closeRef = useRef(onClose);
  useEffect(() => { closeRef.current = onClose; });

  const load = useCallback(async () => {
    const d = await rpc<any>('hr_appraisal_detail', { p_id: id });
    if (!d) { toast('Penilaian tidak ditemukan', 'error'); closeRef.current(); return; }
    setA(d);
    const mode = d.access === 'self' ? (d.status === 'self' ? 'self' : 'view') : d.status === 'manager' || (d.status === 'self' && d.access === 'hr') ? 'manager' : 'view';
    // atasan mulai dari kosong supaya penilaiannya tidak terpengaruh nilai diri karyawan
    setScores(mode === 'self' ? d.self_scores ?? {} : mode === 'manager' ? d.manager_scores ?? {} : {});
    setText({ comment: '', strengths: d.strengths ?? '', improvements: d.improvements ?? '', goals: d.goals ?? '' });
  }, [id, toast]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  if (!a) return null;
  const criteria: Criterion[] = a.criteria ?? [];
  const mode: 'self' | 'manager' | 'ack' | 'view' = a.access === 'self'
    ? (a.status === 'self' ? 'self' : a.status === 'acknowledge' ? 'ack' : 'view')
    : (a.status === 'manager' || (a.status === 'self' && a.access === 'hr')) ? 'manager' : 'view';
  const metrics = a.metrics ?? a.live_metrics;
  const showResult = !!a.grade && (mode === 'ack' || mode === 'view');
  const preview = mode === 'manager' ? previewScore(criteria, scores, metrics) : null;
  const ratingCount = criteria.filter((c) => c.kind !== 'auto').length;
  const filled = criteria.filter((c) => c.kind !== 'auto' && scores[c.key]?.score).length;
  const setScore = (k: string, v: number) => setScores((x) => ({ ...x, [k]: { ...x[k], score: v } }));
  const setNote = (k: string, v: string) => setScores((x) => ({ ...x, [k]: { ...x[k], note: v } }));

  const run = async (fn: () => Promise<unknown>, msg: string) => {
    setBusy(true);
    try { await fn(); toast(msg, 'success'); onChanged(); onClose(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  const submit = async () => {
    if (mode === 'self') {
      if (!(await confirm({ title: 'Kirim penilaian diri?', message: 'Setelah dikirim tidak bisa diubah. Atasan akan menilai berikutnya.', confirmLabel: 'Kirim' }))) return;
      run(() => rpc('hr_appraisal_submit_self', { p_id: id, p_scores: scores, p_comment: text.comment }), 'Penilaian diri terkirim');
    } else if (mode === 'manager') {
      if (!(await confirm({ title: 'Kirim penilaian?', message: <>Nilai akhir <b>{preview?.score ?? '-'}</b> (grade {preview?.grade ?? '-'}). Karyawan akan melihat hasil & catatan Anda.</>, confirmLabel: 'Kirim' }))) return;
      run(() => rpc('hr_appraisal_submit_manager', { p_id: id, p_scores: scores, p_strengths: text.strengths, p_improvements: text.improvements, p_goals: text.goals }), 'Penilaian terkirim');
    } else if (mode === 'ack') {
      run(() => rpc('hr_appraisal_acknowledge', { p_id: id, p_comment: text.comment }), 'Terima kasih, penilaian dikonfirmasi');
    }
  };
  const reopen = () => run(() => rpc('hr_appraisal_reopen', { p_id: id }), 'Penilaian dibuka kembali');

  const g = a.grade ? GRADES[a.grade] : null;
  return (
    <Modal large title={`Penilaian kinerja · ${a.period}`} onClose={onClose}
      footer={<>
        <button onClick={onClose}>Tutup</button>
        {(mode === 'view' || mode === 'ack') && <button onClick={() => window.print()}><Printer size={15} /> Cetak</button>}
        {a.access === 'hr' && (a.status === 'acknowledge' || a.status === 'done') && <button onClick={reopen}>Buka kembali</button>}
        {mode === 'self' && <button className="btn-primary" disabled={busy || filled < ratingCount} onClick={submit}>Kirim penilaian diri</button>}
        {mode === 'manager' && <button className="btn-primary" disabled={busy || filled < ratingCount} onClick={submit}>Kirim penilaian</button>}
        {mode === 'ack' && <button className="btn-primary" disabled={busy} onClick={submit}>Saya sudah membaca</button>}
      </>}>
      <div className="appr">
        <div className="appr-head">
          <HrPhoto path={a.photo_path} name={a.full_name} size={56} />
          <div>
            <h2>{a.full_name}</h2>
            <div className="muted small">{a.employee_number} · {a.position ?? '—'}{a.outlet ? ` · ${a.outlet}` : ''}</div>
            <div className="muted small">{a.template_name} · {fmt(a.start_date)} – {fmt(a.end_date)} · Penilai: {a.reviewer ?? 'HR'}</div>
          </div>
          <span className={`badge ${STATUS[a.status][1]}`}>{STATUS[a.status][0]}</span>
          {(showResult || preview?.grade) && (
            <div className="appr-grade" style={{ '--g': GRADES[(showResult ? a.grade : preview!.grade)!].color } as CSSProperties}>
              <b>{showResult ? a.grade : preview!.grade}</b>
              <span>{showResult ? Number(a.final_score).toFixed(2) : preview!.score?.toFixed(2)}</span>
              <small>{showResult ? g!.label : 'pratinjau'}</small>
            </div>
          )}
        </div>

        {mode === 'self' && <div className="alert alert-info small">Nilai diri Anda sendiri dengan jujur (1 = kurang, 5 = istimewa). Kriteria otomatis dihitung sistem dari absensi, tugas & SOP.</div>}
        {mode === 'manager' && a.status === 'self' && <div className="alert alert-info small">Karyawan belum mengisi penilaian diri. Sebagai HR Anda tetap bisa menilai langsung.</div>}

        <table className="table appr-table">
          <thead><tr><th>Kriteria</th><th className="right">Bobot</th>{(mode === 'manager' || showResult) && <th className="center">Diri</th>}<th>{mode === 'self' ? 'Nilai saya' : mode === 'manager' ? 'Nilai Anda' : 'Nilai'}</th></tr></thead>
          <tbody>
            {criteria.map((c) => {
              const auto = c.kind === 'auto';
              const m = auto ? metrics?.[c.metric!] : null;
              const self = a.self_scores?.[c.key];
              const final = auto ? m?.score : a.manager_scores?.[c.key]?.score;
              return (
                <tr key={c.key}>
                  <td>
                    <b>{c.name}</b> {auto && <span className="badge appr-auto"><Bot size={11} /> otomatis</span>}
                    {c.description && <div className="muted small">{c.description}</div>}
                    {auto && <div className="muted small">{METRICS[c.metric!]?.explain(m)}</div>}
                  </td>
                  <td className="right small">{c.weight}%</td>
                  {(mode === 'manager' || showResult) && <td className="center">{auto ? '—' : self?.score ? <span className="appr-dot">{self.score}</span> : <span className="muted">—</span>}
                    {self?.note && <div className="muted small appr-note">“{self.note}”</div>}</td>}
                  <td>
                    {auto ? (m?.score ? <span className="appr-dot strong">{m.score}</span> : <span className="muted small">tidak dihitung</span>)
                      : mode === 'self' || mode === 'manager' ? (
                        <>
                          <div className="appr-scale" role="radiogroup" aria-label={c.name}>
                            {[1, 2, 3, 4, 5].map((v) => (
                              <button key={v} type="button" role="radio" aria-checked={scores[c.key]?.score === v} title={SCALE[v]}
                                className={scores[c.key]?.score === v ? 'active' : ''} onClick={() => setScore(c.key, v)}>{v}</button>
                            ))}
                            <small className="muted">{SCALE[scores[c.key]?.score ?? 0] ?? ''}</small>
                          </div>
                          <input className="appr-note-input" value={scores[c.key]?.note ?? ''} placeholder="Catatan (opsional)" onChange={(e) => setNote(c.key, e.target.value)} />
                        </>
                      ) : final ? (
                        <><span className="appr-dot strong">{final}</span> <span className="small">{SCALE[final]}</span>
                          {a.manager_scores?.[c.key]?.note && <div className="muted small appr-note">“{a.manager_scores[c.key].note}”</div>}</>
                      ) : <span className="muted">—</span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>

        {mode === 'self' && <label className="field"><span>Catatan untuk atasan (opsional)</span><textarea rows={2} value={text.comment} placeholder="Pencapaian, kendala, harapan…" onChange={(e) => setText({ ...text, comment: e.target.value })} /></label>}
        {a.self_comment && mode !== 'self' && <p className="small"><b>Catatan karyawan:</b> {a.self_comment}</p>}

        {mode === 'manager' && (
          <div className="form-grid">
            <label className="field"><span>Kekuatan</span><textarea rows={2} value={text.strengths} onChange={(e) => setText({ ...text, strengths: e.target.value })} /></label>
            <label className="field"><span>Yang perlu ditingkatkan</span><textarea rows={2} value={text.improvements} onChange={(e) => setText({ ...text, improvements: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Target periode berikutnya</span><textarea rows={2} value={text.goals} onChange={(e) => setText({ ...text, goals: e.target.value })} /></label>
          </div>
        )}
        {showResult && (a.strengths || a.improvements || a.goals) && (
          <div className="appr-notes">
            {a.strengths && <div><b>Kekuatan</b><p>{a.strengths}</p></div>}
            {a.improvements && <div><b>Yang perlu ditingkatkan</b><p>{a.improvements}</p></div>}
            {a.goals && <div><b>Target berikutnya</b><p>{a.goals}</p></div>}
          </div>
        )}
        {mode === 'ack' && <label className="field"><span>Tanggapan Anda (opsional)</span><textarea rows={2} value={text.comment} onChange={(e) => setText({ ...text, comment: e.target.value })} /></label>}
        {a.employee_comment && <p className="small"><b>Tanggapan karyawan:</b> {a.employee_comment}</p>}
      </div>
    </Modal>
  );
}

const fmt = (iso: string) => new Date(`${iso}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
