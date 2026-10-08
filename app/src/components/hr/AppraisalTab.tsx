import { useCallback, useEffect, useMemo, useState, type CSSProperties } from 'react';
import { Bot, Download, Lock, Plus, Play, Settings2, Trash2, Unlock } from 'lucide-react';
import Modal from '../Modal';
import AppraisalForm from './AppraisalForm';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { downloadXlsx } from '../../lib/excel';
import { GRADES, METRICS, SAMPLE_CRITERIA, STATUS, type Criterion, type MetricKey } from '../../lib/appraisal';

/* eslint-disable @typescript-eslint/no-explicit-any */
const quarter = () => {
  const d = new Date(Date.now() + 7 * 3600e3);
  const q = Math.floor(d.getUTCMonth() / 3);
  const y = d.getUTCFullYear();
  const end = new Date(Date.UTC(y, q * 3 + 3, 0));
  return { name: `Q${q + 1} ${y}`, start_date: `${y}-${String(q * 3 + 1).padStart(2, '0')}-01`, end_date: end.toISOString().slice(0, 10), self_assessment: true };
};

// Penilaian kinerja (HR): periode, mulai penilaian, rekap & grade, template per role / jabatan
export default function AppraisalTab({ companyId, roles, positions }: { companyId: string; roles: { id: string; name: string }[]; positions: { id: string; name: string }[] }) {
  const { toast, confirm } = useFeedback();
  const [periods, setPeriods] = useState<any[]>([]);
  const [periodId, setPeriodId] = useState('');
  const [rows, setRows] = useState<any[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [newPeriod, setNewPeriod] = useState<any | null>(null);
  const [templates, setTemplates] = useState(false);

  const loadPeriods = useCallback(async () => {
    const p = await must(supabase.from('hr_appraisal_periods').select('*').order('start_date', { ascending: false }));
    setPeriods(p);
    setPeriodId((cur) => cur || p[0]?.id || '');
  }, []);
  const loadRows = useCallback(async () => setRows(periodId ? await rpc<any[]>('hr_appraisal_overview', { p_period_id: periodId }) : []), [periodId]);
  useEffect(() => { loadPeriods().catch((e) => toast(errorMessage(e), 'error')); }, [loadPeriods, toast]);
  useEffect(() => { loadRows().catch((e) => toast(errorMessage(e), 'error')); }, [loadRows, toast]);

  const period = periods.find((p) => p.id === periodId);
  const dist = useMemo(() => Object.keys(GRADES).map((g) => [g, rows.filter((r) => r.grade === g && (r.status === 'done' || r.status === 'acknowledge')).length] as const), [rows]);
  const byStatus = (s: string) => rows.filter((r) => r.status === s).length;

  const createPeriod = async () => {
    try {
      const p = await must(supabase.from('hr_appraisal_periods').insert({ ...newPeriod, company_id: companyId }).select().single());
      setNewPeriod(null);
      await loadPeriods();
      setPeriodId(p.id);
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const start = async () => {
    try {
      const r = await rpc<any>('hr_appraisal_start', { p_period_id: periodId });
      toast(`${r.created} penilaian dibuat${r.skipped?.length ? `. Tanpa template: ${r.skipped.join(', ')}` : ''}`, r.created ? 'success' : 'error');
      loadRows();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const toggleClose = async () => {
    const closing = period.status === 'open';
    if (closing && !(await confirm({ title: 'Tutup periode?', message: 'Penilaian baru tidak bisa dimulai lagi di periode ini. Penilaian yang sedang berjalan tetap bisa diselesaikan.' }))) return;
    try { await must(supabase.from('hr_appraisal_periods').update({ status: closing ? 'closed' : 'open' }).eq('id', periodId)); loadPeriods(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const exportXlsx = () => downloadXlsx(`penilaian-${period?.name ?? ''}`, [{
    name: period?.name ?? 'Penilaian', widths: [14, 26, 18, 20, 16, 18, 10, 8],
    rows: rows.map((r) => ({ 'No. Karyawan': r.employee_number, Nama: r.full_name, Jabatan: r.position ?? '', Outlet: r.outlet ?? '', Template: r.template_name,
      Status: STATUS[r.status][0], Nilai: r.final_score != null ? Number(r.final_score) : '', Grade: r.grade ?? '' })),
  }]);

  return (
    <>
      <div className="card">
        <div className="card-header roster-head">
          <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
            <select value={periodId} onChange={(e) => setPeriodId(e.target.value)}>
              {!periods.length && <option value="">Belum ada periode</option>}
              {periods.map((p) => <option key={p.id} value={p.id}>{p.name}{p.status === 'closed' ? ' (ditutup)' : ''}</option>)}
            </select>
            <button className="btn-sm" onClick={() => setNewPeriod(quarter())}><Plus size={14} /> Periode</button>
            {period && <button className="btn-sm" onClick={toggleClose}>{period.status === 'open' ? <><Lock size={13} /> Tutup</> : <><Unlock size={13} /> Buka</>}</button>}
          </div>
          <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
            <button className="btn-sm" onClick={() => setTemplates(true)}><Settings2 size={14} /> Template penilaian</button>
            <button className="btn-sm" disabled={!rows.length} onClick={exportXlsx}><Download size={14} /> Excel</button>
            {period?.status === 'open' && <button className="btn-sm btn-primary" onClick={start}><Play size={14} /> Mulai penilaian</button>}
          </div>
        </div>
        {period && (
          <div className="appr-summary">
            <div><small className="muted">Periode</small><b>{new Date(`${period.start_date}T00:00:00Z`).toLocaleDateString('id-ID', { timeZone: 'UTC' })} – {new Date(`${period.end_date}T00:00:00Z`).toLocaleDateString('id-ID', { timeZone: 'UTC' })}</b></div>
            {(['self', 'manager', 'acknowledge', 'done'] as const).map((s) => <div key={s}><small className="muted">{STATUS[s][0]}</small><b>{byStatus(s)}</b></div>)}
            <div className="appr-dist">{dist.map(([g, n]) => <span key={g} style={{ '--g': GRADES[g].color } as CSSProperties} title={GRADES[g].label}><b>{g}</b>{n}</span>)}</div>
          </div>
        )}
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>Karyawan</th><th>Template</th><th>Penilai</th><th>Status</th><th className="right">Nilai</th><th className="center">Grade</th><th></th></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td><b>{r.full_name}</b><div className="muted small">{r.position ?? ''}{r.outlet ? ` · ${r.outlet}` : ''}</div></td>
                  <td className="small">{r.template_name}</td>
                  <td className="small">{r.reviewer ?? <span className="muted">HR</span>}</td>
                  <td><span className={`badge ${STATUS[r.status][1]}`}>{STATUS[r.status][0]}</span></td>
                  <td className="right">{r.final_score != null ? Number(r.final_score).toFixed(2) : '—'}</td>
                  <td className="center">{r.grade ? <span className="appr-grade-chip" style={{ background: GRADES[r.grade].color }}>{r.grade}</span> : '—'}</td>
                  <td className="right"><button className="btn-sm" onClick={() => setOpen(r.id)}>{r.status === 'manager' || r.status === 'self' ? 'Nilai' : 'Lihat'}</button></td>
                </tr>
              ))}
              {!rows.length && <tr><td colSpan={7} className="empty">{period ? 'Belum ada penilaian. Siapkan template, lalu klik "Mulai penilaian".' : 'Buat periode penilaian dulu, mis. per kuartal.'}</td></tr>}
            </tbody>
          </table>
        </div>
        <p className="muted small" style={{ margin: '8px 0 0' }}>Alur: karyawan menilai diri → atasan langsung (kolom Atasan di data karyawan) atau HR menilai → karyawan membaca & konfirmasi. Grade: A ≥ 4,5 · B ≥ 3,75 · C ≥ 3 · D ≥ 2 · E.</p>
      </div>

      {newPeriod && (
        <Modal title="Periode penilaian baru" onClose={() => setNewPeriod(null)}
          footer={<><button onClick={() => setNewPeriod(null)}>Batal</button><button className="btn-primary" disabled={!newPeriod.name.trim()} onClick={createPeriod}>Buat</button></>}>
          <div className="form-grid">
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Nama</span><input value={newPeriod.name} onChange={(e) => setNewPeriod({ ...newPeriod, name: e.target.value })} /></label>
            <label className="field"><span>Mulai</span><input type="date" value={newPeriod.start_date} onChange={(e) => setNewPeriod({ ...newPeriod, start_date: e.target.value })} /></label>
            <label className="field"><span>Selesai</span><input type="date" value={newPeriod.end_date} min={newPeriod.start_date} onChange={(e) => setNewPeriod({ ...newPeriod, end_date: e.target.value })} /></label>
          </div>
          <label className="row" style={{ marginTop: 10 }}><input type="checkbox" checked={newPeriod.self_assessment} onChange={(e) => setNewPeriod({ ...newPeriod, self_assessment: e.target.checked })} /> Karyawan menilai diri sendiri dulu</label>
          <p className="muted small">Kriteria otomatis (kehadiran, tepat waktu, tugas, SOP) dihitung dari data dalam rentang tanggal ini.</p>
        </Modal>
      )}
      {templates && <Templates companyId={companyId} roles={roles} positions={positions} onClose={() => setTemplates(false)} />}
      {open && <AppraisalForm id={open} onClose={() => setOpen(null)} onChanged={() => { loadRows(); window.dispatchEvent(new Event('appraisal-changed')); }} />}
    </>
  );
}

function Templates({ companyId, roles, positions, onClose }: { companyId: string; roles: { id: string; name: string }[]; positions: { id: string; name: string }[]; onClose: () => void }) {
  const { toast } = useFeedback();
  const [list, setList] = useState<any[]>([]);
  const [edit, setEdit] = useState<any | null>(null);
  const load = useCallback(async () => setList(await must(supabase.from('hr_appraisal_templates').select('*').order('name'))), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const total = edit ? edit.criteria.reduce((n: number, c: Criterion) => n + Number(c.weight || 0), 0) : 0;
  const setC = (i: number, patch: Partial<Criterion>) => setEdit({ ...edit, criteria: edit.criteria.map((c: Criterion, j: number) => (j === i ? { ...c, ...patch } : c)) });
  const save = async () => {
    try {
      if (!edit.name?.trim() || !edit.criteria.length) throw new Error('Nama & minimal satu kriteria wajib diisi');
      if (edit.criteria.some((c: Criterion) => !c.name.trim())) throw new Error('Nama kriteria wajib diisi');
      if (total !== 100) throw new Error(`Total bobot harus 100% (sekarang ${total}%)`);
      const v = { name: edit.name.trim(), role_id: edit.role_id || null, position_id: edit.position_id || null, is_active: edit.is_active !== false,
        criteria: edit.criteria.map((c: Criterion) => ({ ...c, weight: Number(c.weight) })), updated_at: new Date().toISOString() };
      if (edit.id) await must(supabase.from('hr_appraisal_templates').update(v).eq('id', edit.id));
      else await must(supabase.from('hr_appraisal_templates').insert({ ...v, company_id: companyId }));
      setEdit(null);
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const blank = (sample: boolean) => setEdit({ name: sample ? 'Penilaian umum' : '', role_id: '', position_id: '', is_active: true, criteria: sample ? SAMPLE_CRITERIA.map((c) => ({ ...c })) : [] });

  return (
    <Modal large title="Template penilaian" onClose={onClose}
      footer={edit ? <><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={save}>Simpan</button></>
        : <><button onClick={onClose}>Tutup</button><button onClick={() => blank(true)}>Pakai contoh</button><button className="btn-primary" onClick={() => blank(false)}><Plus size={14} /> Template</button></>}>
      {edit ? (
        <>
          <div className="form-grid">
            <label className="field"><span>Nama</span><input value={edit.name} placeholder="Penilaian kasir" onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
            <label className="field"><span>Untuk role</span>
              <select value={edit.role_id ?? ''} onChange={(e) => setEdit({ ...edit, role_id: e.target.value })}>
                <option value="">Semua role</option>{roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select></label>
            <label className="field"><span>Untuk jabatan</span>
              <select value={edit.position_id ?? ''} onChange={(e) => setEdit({ ...edit, position_id: e.target.value })}>
                <option value="">Semua jabatan</option>{positions.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select></label>
          </div>
          <table className="table appr-crit" style={{ marginTop: 10 }}>
            <thead><tr><th>Kriteria</th><th>Jenis</th><th className="right">Bobot %</th><th></th></tr></thead>
            <tbody>
              {edit.criteria.map((c: Criterion, i: number) => (
                <tr key={i}>
                  <td><input value={c.name} placeholder="Nama kriteria" onChange={(e) => setC(i, { name: e.target.value })} />
                    {c.kind === 'rating' && <input className="appr-note-input" value={c.description ?? ''} placeholder="Penjelasan (opsional)" onChange={(e) => setC(i, { description: e.target.value })} />}</td>
                  <td>
                    <select value={c.kind === 'auto' ? c.metric : 'rating'} onChange={(e) => setC(i, e.target.value === 'rating' ? { kind: 'rating', metric: undefined } : { kind: 'auto', metric: e.target.value as MetricKey })}>
                      <option value="rating">Dinilai (1–5)</option>
                      {(Object.keys(METRICS) as MetricKey[]).map((k) => <option key={k} value={k}>Otomatis: {METRICS[k].label}</option>)}
                    </select>
                  </td>
                  <td className="right"><input type="number" min={0} max={100} style={{ width: 70 }} value={c.weight} onChange={(e) => setC(i, { weight: Number(e.target.value) })} /></td>
                  <td className="right"><button className="btn-sm" onClick={() => setEdit({ ...edit, criteria: edit.criteria.filter((_: Criterion, j: number) => j !== i) })} aria-label="Hapus kriteria"><Trash2 size={13} /></button></td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td colSpan={2}><button className="btn-sm" onClick={() => setEdit({ ...edit, criteria: [...edit.criteria, { key: `k${Date.now().toString(36)}`, name: '', kind: 'rating', weight: 0 }] })}><Plus size={13} /> Kriteria</button></td>
              <td className={`right bold ${total === 100 ? 'text-success' : 'text-danger'}`}>{total}%</td><td></td></tr></tfoot>
          </table>
          {edit.id && <label className="row"><input type="checkbox" checked={edit.is_active !== false} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} /> Aktif</label>}
          <p className="muted small">Karyawan memakai template yang paling cocok: jabatan + role → jabatan → role → umum. Perubahan berlaku untuk penilaian yang dimulai setelahnya.</p>
        </>
      ) : (
        <table className="table">
          <thead><tr><th>Template</th><th>Untuk</th><th>Kriteria</th><th></th></tr></thead>
          <tbody>
            {list.map((t) => (
              <tr key={t.id}>
                <td><b>{t.name}</b> {!t.is_active && <span className="badge">Nonaktif</span>}</td>
                <td className="small">{[roles.find((r) => r.id === t.role_id)?.name && `Role ${roles.find((r) => r.id === t.role_id)!.name}`, positions.find((p) => p.id === t.position_id)?.name].filter(Boolean).join(' · ') || 'Semua karyawan'}</td>
                <td className="small">{t.criteria.length} kriteria · <Bot size={11} /> {t.criteria.filter((c: Criterion) => c.kind === 'auto').length} otomatis</td>
                <td className="right"><button className="btn-sm" onClick={() => setEdit({ ...t, role_id: t.role_id ?? '', position_id: t.position_id ?? '' })}>Edit</button></td>
              </tr>
            ))}
            {!list.length && <tr><td colSpan={4} className="empty">Belum ada template. Klik <b>Pakai contoh</b> untuk mulai dari kriteria standar restoran.</td></tr>}
          </tbody>
        </table>
      )}
    </Modal>
  );
}
