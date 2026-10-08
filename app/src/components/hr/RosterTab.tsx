import { useCallback, useEffect, useMemo, useState } from 'react';
import { ChevronLeft, ChevronRight, Copy, Eraser, Moon, Plus, Save, Settings2 } from 'lucide-react';
import Modal from '../Modal';
import HrPhoto from './HrPhoto';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { addDays, hhmm, localDate, mondayOf } from '../../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Brush = { kind: 'shift'; id: string } | { kind: 'off' } | { kind: 'clear' };
interface Cell { shift_id: string | null; is_off: boolean }
const DAYS = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
const COLORS = ['#4ABDAC', '#F7B733', '#FC4A1A', '#6C63FF', '#2E86DE', '#8E44AD', '#27AE60', '#7F8C8D'];

// Jadwal shift mingguan: pilih "kuas" (template shift / libur / hapus) lalu klik sel untuk mengisi
export default function RosterTab({ companyId, outlets }: { companyId: string; outlets: { id: string; name: string }[] }) {
  const { toast, confirm } = useFeedback();
  const [week, setWeek] = useState(() => mondayOf(localDate()));
  const [outletId, setOutletId] = useState<string>('');
  const [board, setBoard] = useState<any>({ employees: [], rows: [], shifts: [] });
  const [draft, setDraft] = useState<Record<string, Cell | null>>({});   // key: employee|date ; null = hapus
  const [brush, setBrush] = useState<Brush | null>(null);
  const [templates, setTemplates] = useState(false);
  const [busy, setBusy] = useState(false);
  const days = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(week, i)), [week]);
  const today = localDate();

  const load = useCallback(async () => {
    const b = await rpc<any>('hr_roster_board', { p_from: week, p_to: addDays(week, 6), p_outlet_id: outletId || null });
    setBoard(b);
    setDraft({});
    setBrush((cur) => cur ?? (b.shifts[0] ? { kind: 'shift', id: b.shifts[0].id } : null));
  }, [week, outletId]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const saved = useMemo(() => {
    const m: Record<string, Cell> = {};
    for (const r of board.rows) m[`${r.employee_id}|${r.work_date}`] = { shift_id: r.shift_id, is_off: r.is_off };
    return m;
  }, [board.rows]);
  const cellOf = (emp: string, d: string): Cell | null => {
    const k = `${emp}|${d}`;
    return k in draft ? draft[k] : saved[k] ?? null;
  };
  const shiftById = (id: string | null) => board.shifts.find((s: any) => s.id === id);
  const paint = (emp: string, d: string) => {
    if (!brush) { toast('Buat template shift dulu', 'error'); return; }
    const v: Cell | null = brush.kind === 'clear' ? null : brush.kind === 'off' ? { shift_id: null, is_off: true } : { shift_id: brush.id, is_off: false };
    setDraft((x) => ({ ...x, [`${emp}|${d}`]: v }));
  };
  const changes = Object.entries(draft).filter(([k, v]) => {
    const s = saved[k] ?? null;
    return JSON.stringify(s) !== JSON.stringify(v);
  });

  const save = async () => {
    setBusy(true);
    try {
      const rows = changes.map(([k, v]) => {
        const [employee_id, work_date] = k.split('|');
        return { employee_id, work_date, shift_id: v?.shift_id ?? null, is_off: v?.is_off ?? false };
      });
      await rpc('hr_roster_save', { p_rows: rows });
      toast(`${rows.length} jadwal disimpan`, 'success');
      await load();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  const copyLastWeek = async () => {
    if (changes.length && !(await confirm({ title: 'Ada perubahan belum disimpan', message: 'Perubahan akan hilang. Lanjut salin?' }))) return;
    try {
      const n = await rpc<number>('hr_roster_copy_week', { p_from_week: addDays(week, -7), p_to_week: week, p_outlet_id: outletId || null, p_overwrite: false });
      toast(n ? `${n} jadwal disalin dari minggu lalu (sel yang sudah terisi tidak ditimpa)` : 'Minggu lalu belum ada jadwal', n ? 'success' : 'error');
      await load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const counts = (d: string) => board.employees.filter((e: any) => { const c = cellOf(e.id, d); return c && !c.is_off; }).length;
  const label = (iso: string) => new Date(`${iso}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', timeZone: 'UTC' });

  return (
    <div className="card">
      <div className="card-header roster-head">
        <div className="row" style={{ gap: 6 }}>
          <button className="btn-sm" onClick={() => setWeek(addDays(week, -7))} aria-label="Minggu sebelumnya"><ChevronLeft size={15} /></button>
          <b>{label(week)} – {label(addDays(week, 6))}</b>
          <button className="btn-sm" onClick={() => setWeek(addDays(week, 7))} aria-label="Minggu berikutnya"><ChevronRight size={15} /></button>
          {week !== mondayOf(today) && <button className="btn-sm" onClick={() => setWeek(mondayOf(today))}>Minggu ini</button>}
        </div>
        <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
          <select value={outletId} onChange={(e) => setOutletId(e.target.value)}>
            <option value="">Semua outlet</option>
            {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
          <button className="btn-sm" onClick={copyLastWeek}><Copy size={14} /> Salin minggu lalu</button>
          <button className="btn-sm" onClick={() => setTemplates(true)}><Settings2 size={14} /> Template shift</button>
        </div>
      </div>

      <div className="roster-brushes">
        <span className="muted small">Kuas:</span>
        {board.shifts.map((s: any) => (
          <button key={s.id} className={`roster-brush ${brush?.kind === 'shift' && brush.id === s.id ? 'active' : ''}`} style={{ '--c': s.color } as any}
            onClick={() => setBrush({ kind: 'shift', id: s.id })}>
            <b>{s.code}</b> {hhmm(s.start_time)}–{hhmm(s.end_time)}
          </button>
        ))}
        <button className={`roster-brush off ${brush?.kind === 'off' ? 'active' : ''}`} onClick={() => setBrush({ kind: 'off' })}><Moon size={13} /> Libur</button>
        <button className={`roster-brush clear ${brush?.kind === 'clear' ? 'active' : ''}`} onClick={() => setBrush({ kind: 'clear' })}><Eraser size={13} /> Hapus</button>
        {!board.shifts.length && <button className="btn-sm btn-primary" onClick={() => setTemplates(true)}><Plus size={14} /> Buat template shift</button>}
      </div>

      <div className="table-wrap">
        <table className="table roster-table">
          <thead>
            <tr>
              <th>Karyawan</th>
              {days.map((d, i) => <th key={d} className={d === today ? 'today' : ''}>{DAYS[i]}<small>{label(d)} · {counts(d)} org</small></th>)}
            </tr>
          </thead>
          <tbody>
            {board.employees.map((e: any) => (
              <tr key={e.id}>
                <td>
                  <button type="button" className="roster-emp" title="Klik untuk isi seminggu dengan kuas ini" onClick={() => days.forEach((d) => paint(e.id, d))}>
                    <HrPhoto path={e.photo_path} name={e.full_name} size={28} />
                    <span><b>{e.nickname || e.full_name}</b><small className="muted">{e.position ?? '—'}{!outletId && e.outlet ? ` · ${e.outlet}` : ''}</small></span>
                  </button>
                </td>
                {days.map((d) => {
                  const c = cellOf(e.id, d);
                  const s = c?.shift_id ? shiftById(c.shift_id) : null;
                  const dirty = `${e.id}|${d}` in draft && JSON.stringify(saved[`${e.id}|${d}`] ?? null) !== JSON.stringify(c);
                  return (
                    <td key={d} className={`roster-cell ${d === today ? 'today' : ''} ${dirty ? 'dirty' : ''}`} onClick={() => paint(e.id, d)}>
                      {c?.is_off ? <span className="roster-chip off">Libur</span>
                        : s ? <span className="roster-chip" style={{ '--c': s.color } as any}><b>{s.code}</b><small>{hhmm(s.start_time)}</small></span>
                          : <span className="roster-empty">+</span>}
                    </td>
                  );
                })}
              </tr>
            ))}
            {!board.employees.length && <tr><td colSpan={8} className="empty">Belum ada karyawan aktif{outletId ? ' di outlet ini' : ''}.</td></tr>}
          </tbody>
        </table>
      </div>

      {changes.length > 0 && (
        <div className="roster-savebar">
          <span>{changes.length} perubahan belum disimpan</span>
          <button onClick={() => setDraft({})}>Batalkan</button>
          <button className="btn-primary" disabled={busy} onClick={save}><Save size={15} /> Simpan jadwal</button>
        </div>
      )}
      <p className="muted small" style={{ margin: '10px 0 0' }}>Tips: pilih kuas, lalu klik sel. Klik nama karyawan untuk mengisi satu minggu sekaligus. Jadwal dipakai untuk menghitung telat & alpa.</p>

      {templates && <ShiftTemplates companyId={companyId} onClose={() => { setTemplates(false); load(); }} />}
    </div>
  );
}

function ShiftTemplates({ companyId, onClose }: { companyId: string; onClose: () => void }) {
  const { toast } = useFeedback();
  const [list, setList] = useState<any[]>([]);
  const [edit, setEdit] = useState<any | null>(null);
  const load = useCallback(async () => setList(await must(supabase.from('hr_shifts').select('*').order('start_time'))), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const save = async () => {
    try {
      const v = { code: edit.code?.trim().toUpperCase(), name: edit.name?.trim(), start_time: edit.start_time, end_time: edit.end_time,
        break_minutes: Number(edit.break_minutes ?? 0), color: edit.color, is_active: edit.is_active };
      if (!v.code || !v.name || !v.start_time || !v.end_time) throw new Error('Kode, nama, jam mulai & selesai wajib diisi');
      if (edit.id) await must(supabase.from('hr_shifts').update(v).eq('id', edit.id));
      else await must(supabase.from('hr_shifts').insert({ ...v, company_id: companyId }));
      setEdit(null);
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const starter = async () => {
    try {
      await must(supabase.from('hr_shifts').insert([
        { company_id: companyId, code: 'P', name: 'Pagi', start_time: '07:00', end_time: '15:00', color: '#4ABDAC' },
        { company_id: companyId, code: 'S', name: 'Siang', start_time: '11:00', end_time: '19:00', color: '#F7B733' },
        { company_id: companyId, code: 'M', name: 'Malam', start_time: '15:00', end_time: '23:00', color: '#6C63FF' },
      ]));
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const hours = (s: any) => {
    const [a, b] = [s.start_time, s.end_time].map((t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5)));
    return (((b - a + 1440) % 1440 || 1440) - Number(s.break_minutes ?? 0)) / 60;
  };

  return (
    <Modal title="Template shift" onClose={onClose}
      footer={edit ? <><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={save}>Simpan</button></>
        : <><button onClick={onClose}>Tutup</button><button className="btn-primary" onClick={() => setEdit({ color: COLORS[list.length % COLORS.length], break_minutes: 60, is_active: true })}><Plus size={14} /> Template</button></>}>
      {edit ? (
        <div className="form-grid">
          <label className="field"><span>Kode (singkat)</span><input value={edit.code ?? ''} maxLength={4} placeholder="P" onChange={(e) => setEdit({ ...edit, code: e.target.value })} /></label>
          <label className="field"><span>Nama</span><input value={edit.name ?? ''} placeholder="Pagi" onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
          <label className="field"><span>Jam mulai</span><input type="time" value={hhmm(edit.start_time)} onChange={(e) => setEdit({ ...edit, start_time: e.target.value })} /></label>
          <label className="field"><span>Jam selesai</span><input type="time" value={hhmm(edit.end_time)} onChange={(e) => setEdit({ ...edit, end_time: e.target.value })} />
            {edit.start_time && edit.end_time && edit.end_time <= edit.start_time && <small className="muted">Lewat tengah malam (selesai besoknya)</small>}</label>
          <label className="field"><span>Istirahat (menit)</span><input type="number" min={0} value={edit.break_minutes ?? 0} onChange={(e) => setEdit({ ...edit, break_minutes: e.target.value })} /></label>
          <div className="field"><span>Warna</span>
            <div className="row" style={{ gap: 6 }}>{COLORS.map((c) => (
              <button key={c} type="button" className={`color-dot ${edit.color === c ? 'active' : ''}`} style={{ background: c }} onClick={() => setEdit({ ...edit, color: c })} aria-label={c} />
            ))}</div>
          </div>
          {edit.id && <label className="row"><input type="checkbox" checked={edit.is_active} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} /> Aktif</label>}
        </div>
      ) : (
        <>
          <table className="table">
            <thead><tr><th>Shift</th><th>Jam</th><th className="right">Jam kerja</th><th></th></tr></thead>
            <tbody>
              {list.map((s) => (
                <tr key={s.id}>
                  <td><span className="roster-chip" style={{ '--c': s.color } as any}><b>{s.code}</b></span> <b>{s.name}</b> {!s.is_active && <span className="badge">Nonaktif</span>}</td>
                  <td>{hhmm(s.start_time)}–{hhmm(s.end_time)}</td>
                  <td className="right">{hours(s)} jam</td>
                  <td className="right"><button className="btn-sm" onClick={() => setEdit(s)}>Edit</button></td>
                </tr>
              ))}
            </tbody>
          </table>
          {!list.length && (
            <div className="empty">
              <p>Belum ada template shift.</p>
              <button className="btn-primary" onClick={starter}>Pakai contoh: Pagi, Siang, Malam</button>
            </div>
          )}
        </>
      )}
    </Modal>
  );
}
