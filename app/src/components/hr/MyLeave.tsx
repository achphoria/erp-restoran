import { useCallback, useEffect, useRef, useState } from 'react';
import { CalendarHeart, Check, Paperclip, Plus, Users, X } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { LEAVE_STATUS, addDays, dateRange, fmtDays, fmtTime, localDate, uploadLeaveAttachment } from '../../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Kartu cuti di Beranda Saya: sisa saldo, ajukan cuti / izin, status pengajuan, rekan yang sedang cuti
export default function MyLeave({ companyId }: { companyId: string }) {
  const { toast, confirm } = useFeedback();
  const [data, setData] = useState<any | null | undefined>(undefined);
  const [form, setForm] = useState<any | null>(null);
  const [showAll, setShowAll] = useState(false);

  const load = useCallback(async () => setData((await rpc<any>('hr_my_leave')) ?? null), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  if (!data) return null;
  const b = data.balance ?? {};
  const reqs: any[] = data.requests ?? [];
  const shown = showAll ? reqs : reqs.slice(0, 3);

  const cancel = async (r: any) => {
    if (!(await confirm({ title: 'Batalkan pengajuan?', message: `${r.leave_type} · ${dateRange(r.start_date, r.end_date)}`, danger: true, confirmLabel: 'Batalkan' }))) return;
    try { await rpc('hr_cancel_leave', { p_id: r.id }); toast('Pengajuan dibatalkan', 'success'); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <div className="card me-leave">
      <div className="me-card-title" style={{ justifyContent: 'space-between' }}>
        <span><CalendarHeart size={16} /> Cuti & izin</span>
        <button className="btn-sm btn-primary" onClick={() => setForm({ leave_type_id: data.types[0]?.id ?? '', start_date: addDays(localDate(), 1), end_date: addDays(localDate(), 1), half_day: false, reason: '', file: null })}>
          <Plus size={13} /> Ajukan
        </button>
      </div>
      <div className="me-leave-balance">
        <div><b>{Number(b.remaining ?? 0).toLocaleString('id-ID')}</b><small>sisa cuti {b.year}</small></div>
        <div className="muted small">
          Hak {Number(b.entitlement ?? 0)}{Number(b.adjustment) ? ` ${Number(b.adjustment) > 0 ? '+' : ''}${Number(b.adjustment)}` : ''} · terpakai {Number(b.used ?? 0)}
          {Number(b.pending) > 0 && <> · menunggu {Number(b.pending)}</>}
          {Number(b.entitlement) === 0 && b.eligible_from && <div>Berhak cuti tahunan mulai {new Date(`${b.eligible_from}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' })}</div>}
        </div>
      </div>
      {shown.length > 0 && (
        <div className="me-hist">
          {shown.map((r) => (
            <div key={r.id} className="me-hist-row">
              <span>
                <span className="shift-dot" style={{ background: r.color }} /> <b>{r.leave_type}</b>
                <small className="muted"> · {dateRange(r.start_date, r.end_date)} · {r.half_day ? 'setengah hari' : fmtDays(r.days)}</small>
                {r.decision_note && <small className="muted"><br />{r.decider ? `${r.decider}: ` : ''}{r.decision_note}</small>}
              </span>
              <span className="row" style={{ gap: 6 }}>
                <span className={`badge ${LEAVE_STATUS[r.status][1]}`}>{LEAVE_STATUS[r.status][0]}</span>
                {(r.status === 'pending' || (r.status === 'approved' && r.start_date > localDate())) && <button className="btn-sm" onClick={() => cancel(r)}>Batal</button>}
              </span>
            </div>
          ))}
          {reqs.length > 3 && <button className="btn-sm" onClick={() => setShowAll(!showAll)}>{showAll ? 'Ringkas' : `Lihat semua (${reqs.length})`}</button>}
        </div>
      )}
      {data.team?.length > 0 && (
        <div className="me-team">
          <div className="muted small"><Users size={13} style={{ verticalAlign: -2 }} /> Rekan yang cuti 2 minggu ke depan</div>
          {data.team.map((t: any, i: number) => (
            <div key={i} className="small"><span className="shift-dot" style={{ background: t.color }} /> <b>{t.full_name}</b> <span className="muted">· {t.leave_type} · {dateRange(t.start_date, t.end_date)}</span></div>
          ))}
        </div>
      )}
      {form && <LeaveForm companyId={companyId} employeeId={data.employee_id} types={data.types} balance={b} form={form} setForm={setForm}
        onDone={() => { setForm(null); toast('Pengajuan terkirim, menunggu persetujuan', 'success'); load(); }} />}
    </div>
  );
}

function LeaveForm({ companyId, employeeId, types, balance, form, setForm, onDone }: {
  companyId: string; employeeId: string; types: any[]; balance: any; form: any; setForm: (f: any) => void; onDone: () => void;
}) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const t = types.find((x) => x.id === form.leave_type_id);
  const single = form.start_date === form.end_date;
  // perkiraan (server mengurangi hari libur di jadwal)
  const est = form.half_day && single ? 0.5 : Math.max(0, Math.round((Date.parse(form.end_date) - Date.parse(form.start_date)) / 864e5) + 1);
  const needDoc = t?.attachment_min_days != null && est >= t.attachment_min_days;
  const set = (k: string, v: any) => {
    const f = { ...form, [k]: v };
    if (k === 'start_date' && f.end_date < v) f.end_date = v;
    if (f.start_date !== f.end_date) f.half_day = false;
    setForm(f);
  };

  const submit = async () => {
    setBusy(true);
    setError('');
    try {
      const path = form.file ? await uploadLeaveAttachment(companyId, employeeId, form.file) : null;
      await rpc('hr_request_leave', { p: { leave_type_id: form.leave_type_id, start_date: form.start_date, end_date: form.end_date,
        half_day: form.half_day && single, reason: form.reason, attachment_path: path } });
      onDone();
    } catch (e) { setError(errorMessage(e)); setBusy(false); }
  };

  return (
    <Modal title="Ajukan cuti / izin" onClose={() => setForm(null)}
      footer={<><button onClick={() => setForm(null)}>Batal</button>
        <button className="btn-primary" disabled={busy || !form.leave_type_id || !form.reason.trim() || (needDoc && !form.file)} onClick={submit}>{busy ? 'Mengirim…' : 'Kirim pengajuan'}</button></>}>
      <div className="form-grid">
        <label className="field" style={{ gridColumn: '1 / -1' }}><span>Jenis</span>
          <select value={form.leave_type_id} onChange={(e) => set('leave_type_id', e.target.value)}>
            {types.map((x) => <option key={x.id} value={x.id}>{x.name}{x.deducts_balance ? ` (sisa ${Number(balance.remaining ?? 0)} hari)` : ''}{x.max_days ? ` · maks ${x.max_days} hari` : ''}</option>)}
          </select>
          {t && <small className="muted">{t.deducts_balance ? 'Memotong saldo cuti tahunan.' : 'Tidak memotong saldo cuti.'}{!t.is_paid ? ' Tidak dibayar.' : ''}
            {t.attachment_min_days != null ? ` Lampiran wajib mulai ${t.attachment_min_days} hari.` : ''}</small>}
        </label>
        <label className="field"><span>Mulai</span><input type="date" value={form.start_date} min={addDays(localDate(), -30)} onChange={(e) => set('start_date', e.target.value)} /></label>
        <label className="field"><span>Sampai</span><input type="date" value={form.end_date} min={form.start_date} onChange={(e) => set('end_date', e.target.value)} /></label>
        {single && <label className="row" style={{ gridColumn: '1 / -1' }}><input type="checkbox" checked={form.half_day} onChange={(e) => set('half_day', e.target.checked)} /> Setengah hari</label>}
        <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alasan</span>
          <textarea rows={2} value={form.reason} placeholder="mis. acara keluarga di kampung" onChange={(e) => set('reason', e.target.value)} /></label>
        <div className="field" style={{ gridColumn: '1 / -1' }}>
          <span>Lampiran {needDoc ? <b className="text-danger">(wajib)</b> : <span className="muted">(opsional)</span>}</span>
          <div className="row" style={{ gap: 8 }}>
            <button type="button" onClick={() => fileRef.current?.click()}><Paperclip size={14} /> {form.file ? 'Ganti file' : 'Foto / PDF'}</button>
            {form.file && <span className="small">{form.file.name} <button type="button" className="btn-sm" onClick={() => set('file', null)} aria-label="Hapus lampiran"><X size={12} /></button></span>}
          </div>
          <input ref={fileRef} type="file" accept="image/*,application/pdf" hidden onChange={(e) => set('file', e.target.files?.[0] ?? null)} />
        </div>
      </div>
      <p className="muted small" style={{ margin: '8px 0 0' }}>± {fmtDays(est)}. Hari libur di jadwal shift Anda tidak dihitung.</p>
      {error && <div className="alert alert-error small">{error}</div>}
    </Modal>
  );
}

// Untuk atasan langsung: pengajuan cuti & koreksi absen dari bawahan yang menunggu keputusan
export function TeamInbox() {
  const { toast, prompt } = useFeedback();
  const [leaves, setLeaves] = useState<any[]>([]);
  const [corr, setCorr] = useState<any[]>([]);
  const load = useCallback(async () => {
    const today = localDate();
    const [b, c] = await Promise.all([rpc<any>('hr_leave_board', { p_from: today, p_to: today, p_outlet_id: null }), rpc<any[]>('hr_correction_inbox', { p_status: 'pending' })]);
    setLeaves((b?.requests ?? []).filter((r: any) => r.can_decide));
    setCorr(c ?? []);
  }, []);
  useEffect(() => { load().catch(() => undefined); }, [load]);
  if (!leaves.length && !corr.length) return null;

  const decideLeave = async (r: any, ok: boolean) => {
    const note = ok ? '' : await prompt({ title: 'Tolak pengajuan?', label: 'Alasan', required: true });
    if (!ok && note === null) return;
    try { await rpc('hr_decide_leave', { p_id: r.id, p_approve: ok, p_note: note || null }); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const decideCorr = async (c: any, ok: boolean) => {
    const note = ok ? '' : await prompt({ title: 'Tolak koreksi?', label: 'Alasan', required: true });
    if (!ok && note === null) return;
    try { await rpc('hr_review_correction', { p_id: c.id, p_approve: ok, p_note: note || null }); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <div className="card me-inbox">
      <div className="me-card-title"><Users size={16} /> Persetujuan tim <span className="badge badge-danger">{leaves.length + corr.length}</span></div>
      {leaves.map((r) => (
        <div key={r.id} className="me-hist-row">
          <span><b>{r.full_name}</b> · {r.leave_type}<br /><small className="muted">{dateRange(r.start_date, r.end_date)} · {r.half_day ? 'setengah hari' : fmtDays(r.days)} · {r.reason}</small></span>
          <span className="row" style={{ gap: 4 }}>
            <button className="btn-sm" onClick={() => decideLeave(r, false)} aria-label="Tolak"><X size={14} /></button>
            <button className="btn-sm btn-primary" onClick={() => decideLeave(r, true)} aria-label="Setujui"><Check size={14} /></button>
          </span>
        </div>
      ))}
      {corr.map((c) => (
        <div key={c.id} className="me-hist-row">
          <span><b>{c.full_name}</b> · koreksi absen<br /><small className="muted">{dateRange(c.work_date, c.work_date)} · {fmtTime(c.check_in_at)} – {fmtTime(c.check_out_at)} · {c.reason}</small></span>
          <span className="row" style={{ gap: 4 }}>
            <button className="btn-sm" onClick={() => decideCorr(c, false)} aria-label="Tolak"><X size={14} /></button>
            <button className="btn-sm btn-primary" onClick={() => decideCorr(c, true)} aria-label="Setujui"><Check size={14} /></button>
          </span>
        </div>
      ))}
    </div>
  );
}
