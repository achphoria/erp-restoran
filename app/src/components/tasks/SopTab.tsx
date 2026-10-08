import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Camera, CheckSquare, ChevronLeft, ChevronRight, ClipboardCheck, Plus, Square, X } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { addDays, localDate } from '../../lib/hr';
import { taskFileUrl, uploadTaskFile } from '../../lib/tasks';

/* eslint-disable @typescript-eslint/no-explicit-any */
// SOP harian: checklist hari ini untuk role saya; manajer mengatur template & melihat kepatuhan
export default function SopTab({ companyId, outlets, roles }: { companyId: string; outlets: { id: string; name: string }[]; roles: { id: string; name: string }[] }) {
  const { can } = useAuth();
  const { toast } = useFeedback();
  const [runs, setRuns] = useState<any[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const pending = useRef<{ run: string; index: number } | null>(null);

  const load = useCallback(async () => setRuns(await rpc<any[]>('hr_my_sops')), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const check = async (run: any, index: number, done: boolean, photo: string | null = null) => {
    setBusy(`${run.id}-${index}`);
    try {
      const r = await rpc<any>('hr_sop_check', { p_run_id: run.id, p_index: index, p_done: done, p_photo: photo });
      setRuns((xs) => xs!.map((x) => (x.id === run.id ? { ...x, items: r.items, completed_at: r.completed_at } : x)));
      if (r.completed_at && !run.completed_at) toast(`${run.name} selesai. Mantap!`, 'success');
      window.dispatchEvent(new Event('tasks-changed'));
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(null); }
  };
  const tap = (run: any, index: number) => {
    const it = run.items[index];
    if (!it.done && it.photo) { pending.current = { run: run.id, index }; fileRef.current?.click(); return; }
    check(run, index, !it.done);
  };
  const onPhoto = async (f: File | undefined) => {
    const p = pending.current;
    pending.current = null;
    if (!f || !p) return;
    const run = runs!.find((r) => r.id === p.run);
    setBusy(`${p.run}-${p.index}`);
    try {
      const path = await uploadTaskFile(companyId, 'sop', p.run, f);
      await check(run, p.index, true, path);
    } catch (e) { toast(errorMessage(e), 'error'); setBusy(null); }
  };

  return (
    <>
      <div className="sop-grid">
        {runs?.map((run) => {
          const done = run.items.filter((i: any) => i.done).length;
          const pct = Math.round((done / Math.max(1, run.items.length)) * 100);
          return (
            <div key={run.id} className={`card sop-card ${run.completed_at ? 'complete' : ''}`}>
              <div className="me-card-title" style={{ justifyContent: 'space-between' }}>
                <span><ClipboardCheck size={16} /> {run.name}</span>
                <span className="muted small">{run.outlet ?? ''}</span>
              </div>
              <div className="sop-progress"><span style={{ width: `${pct}%` }} /></div>
              <small className="muted">{done}/{run.items.length} selesai{run.completed_at ? ' · lengkap ✓' : ''}</small>
              <div className="sop-items">
                {run.items.map((it: any, i: number) => (
                  <button key={i} type="button" className={`sop-item ${it.done ? 'done' : ''}`} disabled={busy === `${run.id}-${i}`} onClick={() => tap(run, i)}>
                    {it.done ? <CheckSquare size={20} /> : <Square size={20} />}
                    <span>
                      <span className="sop-text">{it.text}</span>
                      {it.photo && !it.done && <small className="sop-photo-tag"><Camera size={11} /> wajib foto</small>}
                      {it.done && <small className="muted">{it.by_name} · {new Date(it.at).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' })}</small>}
                    </span>
                    {it.photo_path && <SopThumb path={it.photo_path} />}
                  </button>
                ))}
              </div>
            </div>
          );
        })}
        {runs && !runs.length && <div className="card empty">Belum ada SOP harian untuk role Anda.{can('task.manage') ? ' Buat template di bawah.' : ''}</div>}
      </div>
      <input ref={fileRef} type="file" accept="image/*" capture="environment" hidden onChange={(e) => { onPhoto(e.target.files?.[0]); e.target.value = ''; }} />
      {can('task.manage') && <SopManager companyId={companyId} outlets={outlets} roles={roles} onChanged={load} />}
    </>
  );
}

function SopThumb({ path }: { path: string }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => { let alive = true; taskFileUrl(path).then((u) => { if (alive) setUrl(u); }); return () => { alive = false; }; }, [path]);
  return url ? <a href={url} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}><img className="sop-thumb" src={url} alt="Foto SOP" /></a> : null;
}

// Template & rekap kepatuhan 7 hari (manajer)
function SopManager({ companyId, outlets, roles, onChanged }: { companyId: string; outlets: { id: string; name: string }[]; roles: { id: string; name: string }[]; onChanged: () => void }) {
  const { toast } = useFeedback();
  const [end, setEnd] = useState(localDate());
  const [rep, setRep] = useState<any>({ templates: [], runs: [] });
  const [edit, setEdit] = useState<any | null>(null);
  const [newItem, setNewItem] = useState('');
  const days = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(end, i - 6)), [end]);

  const load = useCallback(async () => setRep(await rpc<any>('hr_sop_report', { p_from: addDays(end, -6), p_to: end, p_outlet_id: null })), [end]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const save = async () => {
    try {
      const v = { name: edit.name?.trim(), role_id: edit.role_id || null, outlet_id: edit.outlet_id || null, items: edit.items, is_active: edit.is_active !== false, updated_at: new Date().toISOString() };
      if (!v.name || !v.items.length) throw new Error('Nama & minimal satu langkah wajib diisi');
      if (edit.id) await must(supabase.from('hr_sop_templates').update(v).eq('id', edit.id));
      else await must(supabase.from('hr_sop_templates').insert({ ...v, company_id: companyId }));
      setEdit(null);
      load();
      onChanged();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const addStep = () => { if (newItem.trim()) { setEdit({ ...edit, items: [...edit.items, { text: newItem.trim(), photo: false }] }); setNewItem(''); } };
  // satu baris per template x outlet yang punya catatan
  const rows = useMemo(() => {
    const m = new Map<string, { tpl: any; outlet: string | null; cells: Record<string, any> }>();
    for (const t of rep.templates.filter((x: any) => x.is_active)) m.set(`${t.id}|${t.outlet_id ?? ''}`, { tpl: t, outlet: t.outlet, cells: {} });
    for (const r of rep.runs) {
      const k = `${r.template_id}|${r.outlet_id ?? ''}`;
      const tpl = rep.templates.find((x: any) => x.id === r.template_id);
      if (!tpl) continue;
      const row = m.get(k) ?? { tpl, outlet: r.outlet, cells: {} as Record<string, any> };
      if (!m.has(k)) m.delete(`${tpl.id}|`);
      row.outlet = r.outlet;
      row.cells[r.run_date] = r;
      m.set(k, row);
    }
    return [...m.values()];
  }, [rep]);

  return (
    <div className="card table-wrap" style={{ marginTop: 14 }}>
      <div className="card-header roster-head">
        <h2>Kepatuhan SOP</h2>
        <div className="row" style={{ gap: 6 }}>
          <button className="btn-sm" onClick={() => setEnd(addDays(end, -7))} aria-label="Minggu sebelumnya"><ChevronLeft size={15} /></button>
          <button className="btn-sm" disabled={end >= localDate()} onClick={() => setEnd(addDays(end, 7))} aria-label="Minggu berikutnya"><ChevronRight size={15} /></button>
          <button className="btn-sm btn-primary" onClick={() => setEdit({ name: '', role_id: '', outlet_id: '', items: [], is_active: true })}><Plus size={14} /> Template SOP</button>
        </div>
      </div>
      <table className="table sop-table">
        <thead><tr><th>SOP</th>{days.map((d) => <th key={d}>{new Date(`${d}T00:00:00Z`).toLocaleDateString('id-ID', { weekday: 'short', day: 'numeric', timeZone: 'UTC' })}</th>)}<th></th></tr></thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i}>
              <td><b>{r.tpl.name}</b><div className="muted small">{r.tpl.role ? `Role ${r.tpl.role}` : 'Semua role'}{r.outlet ? ` · ${r.outlet}` : ''} · {r.tpl.items.length} langkah</div></td>
              {days.map((d) => {
                const c = r.cells[d];
                const pct = c ? Math.round((Number(c.done) / Math.max(1, Number(c.total))) * 100) : null;
                return <td key={d} className="center"><span className={`sop-pct ${pct === null ? 'none' : pct === 100 ? 'full' : pct > 0 ? 'part' : 'zero'}`}
                  title={c ? `${c.done}/${c.total} langkah` : 'Belum dibuka'}>{pct === null ? '—' : `${pct}%`}</span></td>;
              })}
              <td className="right"><button className="btn-sm" onClick={() => setEdit({ ...r.tpl, role_id: r.tpl.role_id ?? '', outlet_id: r.tpl.outlet_id ?? '' })}>Edit</button></td>
            </tr>
          ))}
          {!rows.length && <tr><td colSpan={9} className="empty">Contoh SOP: <b>Buka toko</b> (nyalakan mesin, cek kas awal, foto etalase), <b>Tutup toko</b>, <b>Cek suhu chiller</b>.</td></tr>}
        </tbody>
      </table>
      <p className="muted small" style={{ margin: '8px 0 0' }}>— = belum dibuka hari itu. Checklist dibuat otomatis setiap hari saat anggota role membuka Tugas → SOP harian.</p>

      {edit && (
        <Modal title={edit.id ? 'Edit template SOP' : 'Template SOP baru'} onClose={() => setEdit(null)}
          footer={<><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Nama</span><input value={edit.name} placeholder="Buka toko" onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
            <label className="field"><span>Untuk role</span>
              <select value={edit.role_id} onChange={(e) => setEdit({ ...edit, role_id: e.target.value })}>
                <option value="">Semua role</option>
                {roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select></label>
            <label className="field"><span>Outlet</span>
              <select value={edit.outlet_id} onChange={(e) => setEdit({ ...edit, outlet_id: e.target.value })}>
                <option value="">Semua outlet (per outlet karyawan)</option>
                {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
              </select></label>
          </div>
          <div className="task-section" style={{ marginTop: 10 }}>
            <div className="task-section-title">Langkah</div>
            {edit.items.map((it: any, i: number) => (
              <div key={i} className="task-check">
                <span className="muted small">{i + 1}.</span>
                <span>{it.text}</span>
                <label className="row small"><input type="checkbox" checked={!!it.photo} onChange={(e) => setEdit({ ...edit, items: edit.items.map((x: any, j: number) => (j === i ? { ...x, photo: e.target.checked } : x)) })} /> foto</label>
                <button type="button" className="btn-sm" onClick={() => setEdit({ ...edit, items: edit.items.filter((_: any, j: number) => j !== i) })} aria-label="Hapus langkah"><X size={13} /></button>
              </div>
            ))}
            <div className="row" style={{ gap: 6 }}>
              <input value={newItem} placeholder="mis. Cek kas awal Rp 500.000" onChange={(e) => setNewItem(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addStep(); } }} />
              <button type="button" className="btn-sm" disabled={!newItem.trim()} onClick={addStep}><Plus size={14} /></button>
            </div>
          </div>
          {edit.id && <label className="row" style={{ marginTop: 8 }}><input type="checkbox" checked={edit.is_active !== false} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} /> Aktif</label>}
          <p className="muted small">Perubahan langkah berlaku mulai checklist hari berikutnya.</p>
        </Modal>
      )}
    </div>
  );
}
