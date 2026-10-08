import { useCallback, useEffect, useState } from 'react';
import { CalendarDays, CheckCircle2, Clock, History, LogIn, LogOut } from 'lucide-react';
import Modal from '../Modal';
import ClockDialog from './ClockDialog';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { ATT_FLAGS, addDays, fmtTime, hhmm, localDate, mondayOf } from '../../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
const DAYS = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab'];
const dayName = (iso: string) => DAYS[new Date(`${iso}T00:00:00Z`).getUTCDay()];
const dmy = (iso: string) => new Date(`${iso}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', timeZone: 'UTC' });

// Kartu absensi di Beranda Saya: status hari ini, tombol absen, jadwal minggu ini, riwayat & koreksi
export default function MyAttendance({ companyId }: { companyId: string }) {
  const { toast } = useFeedback();
  const [today, setToday] = useState<any | null | undefined>(undefined);
  const [roster, setRoster] = useState<any[]>([]);
  const [clock, setClock] = useState<'in' | 'out' | null>(null);
  const [history, setHistory] = useState<any | null>(null);

  const load = useCallback(async () => {
    const mon = mondayOf(localDate());
    const [t, r] = await Promise.all([rpc<any>('hr_attendance_today'), rpc<any[]>('hr_my_roster', { p_from: mon, p_to: addDays(mon, 6) })]);
    setToday(t ?? null);
    setRoster(r ?? []);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const openHistory = async () => {
    try {
      const to = localDate();
      setHistory(await rpc<any>('hr_my_attendance', { p_from: addDays(to, -31), p_to: to }));
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  if (today === undefined) return <div className="card me-attend"><div className="me-card-title"><Clock size={16} /> Absensi hari ini</div><p className="muted small">Memuat…</p></div>;
  if (today === null) return (
    <div className="card me-attend">
      <div className="me-card-title"><Clock size={16} /> Absensi hari ini</div>
      <p className="muted small" style={{ margin: '4px 0 0' }}>Absen bisa dipakai setelah akun Anda ditautkan ke data karyawan.</p>
    </div>
  );

  const s = today.schedule ?? {};
  const a = today.attendance;
  const done = a?.check_in_at && a?.check_out_at;
  const todayIso = localDate();

  return (
    <div className="card me-attend">
      <div className="me-card-title" style={{ justifyContent: 'space-between' }}>
        <span><Clock size={16} /> Absensi {today.work_date === todayIso ? 'hari ini' : dmy(today.work_date)}</span>
        <button className="btn-sm" onClick={openHistory}><History size={13} /> Riwayat</button>
      </div>
      <div className="me-shift">
        {s.leave && <span className="badge badge-info">{s.leave.leave_type}{s.leave.half_day ? ' (½ hari)' : ''}</span>}
        {s.leave && !s.leave.half_day ? null : s.is_off ? <span className="badge">Libur terjadwal</span>
          : s.shift ? <><span className="shift-dot" style={{ background: s.shift_color }} /> Shift <b>{s.shift}</b> {hhmm(s.start_time)}–{hhmm(s.end_time)}</>
            : <span className="muted">Tidak ada jadwal shift</span>}
        {s.outlet && <span className="muted"> · {s.outlet}</span>}
      </div>
      <div className="me-att-times">
        <div><small className="muted">Masuk</small><b>{fmtTime(a?.check_in_at)}</b>{a?.late_minutes > 0 && <span className="badge badge-warning">telat {a.late_minutes} mnt</span>}</div>
        <div><small className="muted">Pulang</small><b>{fmtTime(a?.check_out_at)}</b>{a?.early_leave_minutes > 0 && <span className="badge badge-warning">cepat {a.early_leave_minutes} mnt</span>}</div>
      </div>
      {a?.flags?.length > 0 && (
        <div className="me-flags">
          {a.flags.map((f: string) => <span key={f} className="badge">{ATT_FLAGS[f] ?? f}</span>)}
          {a.review_status === 'pending' && <span className="badge badge-info">menunggu review</span>}
          {a.review_status === 'approved' && <span className="badge badge-success">disetujui</span>}
          {a.review_status === 'rejected' && <span className="badge badge-danger">ditolak</span>}
        </div>
      )}
      <div className="me-attend-btns">
        {done ? <div className="me-done"><CheckCircle2 size={18} /> Absen hari ini lengkap. Terima kasih!</div> : <>
          <button className="btn-primary btn-lg" disabled={!!a?.check_in_at} onClick={() => setClock('in')}><LogIn size={18} /> Absen Masuk</button>
          <button className="btn-lg" disabled={!a?.check_in_at} onClick={() => setClock('out')}><LogOut size={18} /> Absen Pulang</button>
        </>}
      </div>

      {roster.length > 0 && (
        <div className="me-week">
          <div className="muted small" style={{ marginBottom: 6 }}><CalendarDays size={13} style={{ verticalAlign: -2 }} /> Jadwal minggu ini</div>
          <div className="me-week-grid">
            {roster.map((r) => (
              <div key={r.work_date} className={`me-day ${r.work_date === todayIso ? 'today' : ''}`}>
                <small>{dayName(r.work_date)}</small>
                <b>{new Date(`${r.work_date}T00:00:00Z`).getUTCDate()}</b>
                {r.leave ? <span className="me-day-off" style={{ color: r.leave.color }}>Cuti</span> : r.is_off ? <span className="me-day-off">Libur</span>
                  : r.shift ? <span className="me-day-shift" style={{ borderColor: r.shift_color }} title={`${hhmm(r.start_time)}–${hhmm(r.end_time)}`}>{hhmm(r.start_time)}</span>
                    : <span className="muted">—</span>}
              </div>
            ))}
          </div>
        </div>
      )}

      {clock && (
        <ClockDialog kind={clock} companyId={companyId} today={today} onClose={() => setClock(null)}
          onDone={(att) => {
            setClock(null);
            toast(`${clock === 'in' ? 'Absen masuk' : 'Absen pulang'} tercatat pukul ${fmtTime(clock === 'in' ? att.check_in_at : att.check_out_at)}`
              + (att.review_status === 'pending' ? ' (akan direview)' : ''), 'success');
            load();
          }} />
      )}
      {history && <HistoryModal data={history} onClose={() => setHistory(null)} onChanged={openHistory} />}
    </div>
  );
}

function HistoryModal({ data, onClose, onChanged }: { data: any; onClose: () => void; onChanged: () => void }) {
  const { toast, confirm } = useFeedback();
  const [form, setForm] = useState<{ date: string; in: string; out: string; reason: string } | null>(null);
  const corr: any[] = data.corrections ?? [];

  const submit = async () => {
    const f = form!;
    const ts = (d: string, t: string) => (t ? `${d}T${t}:00+07:00` : null);
    // jam pulang lebih kecil dari jam masuk = keesokan harinya (shift malam)
    const outDate = f.in && f.out && f.out < f.in ? addDays(f.date, 1) : f.date;
    try {
      await rpc('hr_request_correction', { p_work_date: f.date, p_check_in: ts(f.date, f.in), p_check_out: ts(outDate, f.out), p_reason: f.reason });
      toast('Pengajuan koreksi terkirim ke atasan / HR', 'success');
      setForm(null);
      onChanged();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const cancel = async (id: string) => {
    if (!(await confirm({ title: 'Batalkan pengajuan?', message: 'Pengajuan koreksi ini akan dibatalkan.' }))) return;
    await rpc('hr_cancel_correction', { p_id: id }).catch((e) => toast(errorMessage(e), 'error'));
    onChanged();
  };
  const STATUS: Record<string, [string, string]> = { pending: ['Menunggu', 'badge-info'], approved: ['Disetujui', 'badge-success'], rejected: ['Ditolak', 'badge-danger'], cancelled: ['Dibatalkan', ''] };

  return (
    <Modal title="Riwayat absen saya" onClose={onClose}
      footer={form ? <><button onClick={() => setForm(null)}>Batal</button><button className="btn-primary" disabled={!form.reason.trim() || (!form.in && !form.out)} onClick={submit}>Kirim pengajuan</button></>
        : <><button onClick={onClose}>Tutup</button><button className="btn-primary" onClick={() => setForm({ date: addDays(localDate(), -1), in: '', out: '', reason: '' })}>Ajukan koreksi</button></>}>
      {form ? (
        <div className="form-grid">
          <label className="field" style={{ gridColumn: '1 / -1' }}><span>Tanggal kerja</span>
            <input type="date" value={form.date} max={localDate()} min={addDays(localDate(), -31)} onChange={(e) => setForm({ ...form, date: e.target.value })} /></label>
          <label className="field"><span>Jam masuk sebenarnya</span><input type="time" value={form.in} onChange={(e) => setForm({ ...form, in: e.target.value })} /></label>
          <label className="field"><span>Jam pulang sebenarnya</span><input type="time" value={form.out} onChange={(e) => setForm({ ...form, out: e.target.value })} /></label>
          <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alasan</span>
            <textarea rows={2} placeholder="mis. HP mati / lupa absen pulang" value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} /></label>
          <p className="muted small" style={{ gridColumn: '1 / -1', margin: 0 }}>Isi salah satu atau keduanya. Koreksi berlaku setelah disetujui atasan / HR.</p>
        </div>
      ) : (
        <>
          {corr.length > 0 && (
            <>
              <h3 className="small bold" style={{ margin: '0 0 6px' }}>Pengajuan koreksi</h3>
              <div className="me-hist">
                {corr.map((c) => (
                  <div key={c.id} className="me-hist-row">
                    <span><b>{dayName(c.work_date)}, {dmy(c.work_date)}</b> <small className="muted">{fmtTime(c.check_in_at)} – {fmtTime(c.check_out_at)} · {c.reason}</small>
                      {c.review_note && <small className="muted"><br />Catatan: {c.review_note}</small>}</span>
                    <span className="row" style={{ gap: 6 }}>
                      <span className={`badge ${STATUS[c.status][1]}`}>{STATUS[c.status][0]}</span>
                      {c.status === 'pending' && <button className="btn-sm" onClick={() => cancel(c.id)}>Batal</button>}
                    </span>
                  </div>
                ))}
              </div>
            </>
          )}
          <h3 className="small bold" style={{ margin: '12px 0 6px' }}>31 hari terakhir</h3>
          <div className="me-hist">
            {(data.attendances ?? []).map((a: any) => (
              <div key={a.id} className="me-hist-row">
                <span><b>{dayName(a.work_date)}, {dmy(a.work_date)}</b> <small className="muted">{a.shift ?? 'tanpa jadwal'}</small></span>
                <span className="small">{fmtTime(a.check_in_at)} – {fmtTime(a.check_out_at)}
                  {a.late_minutes > 0 && <span className="badge badge-warning" style={{ marginLeft: 6 }}>telat {a.late_minutes}m</span>}
                  {a.review_status === 'pending' && <span className="badge badge-info" style={{ marginLeft: 6 }}>review</span>}
                </span>
              </div>
            ))}
            {!data.attendances?.length && <p className="muted small">Belum ada riwayat absen.</p>}
          </div>
        </>
      )}
    </Modal>
  );
}
