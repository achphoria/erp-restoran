import { useCallback, useEffect, useMemo, useState } from 'react';
import { Check, ChevronLeft, ChevronRight, Download, Paperclip, Plus, Settings2, X } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { downloadXlsx } from '../../lib/excel';
import { LEAVE_POLICY, LEAVE_STATUS, addDays, dateRange, fmtDays, hrFileUrl, localDate } from '../../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
const COLORS = ['#4ABDAC', '#FC4A1A', '#F7B733', '#7F8C8D', '#8E44AD', '#34495E', '#2E86DE', '#27AE60'];
const monthStart = (iso: string) => `${iso.slice(0, 7)}-01`;
const monthEnd = (iso: string) => { const d = new Date(`${monthStart(iso)}T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + 1, 0); return d.toISOString().slice(0, 10); };
const shiftMonth = (iso: string, n: number) => { const d = new Date(`${monthStart(iso)}T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 10); };

// Cuti & izin untuk HR / penyetuju: menunggu keputusan, kalender tim, saldo, jenis cuti & aturan
export default function LeaveTab({ companyId, outlets }: { companyId: string; outlets: { id: string; name: string }[] }) {
  const { can } = useAuth();
  const { toast, prompt } = useFeedback();
  const [month, setMonth] = useState(() => monthStart(localDate()));
  const [outletId, setOutletId] = useState('');
  const [board, setBoard] = useState<any>({ requests: [], types: [] });
  const [balances, setBalances] = useState<any[] | null>(null);
  const [adjust, setAdjust] = useState<any | null>(null);
  const [types, setTypes] = useState(false);
  const canSeeBalances = can(['hr.view', 'hr.manage']);
  const year = Number(month.slice(0, 4));

  const load = useCallback(async () => {
    const [b, bal] = await Promise.all([
      rpc<any>('hr_leave_board', { p_from: month, p_to: monthEnd(month), p_outlet_id: outletId || null }),
      canSeeBalances ? rpc<any[]>('hr_leave_balances', { p_year: year, p_outlet_id: outletId || null }) : Promise.resolve(null),
    ]);
    setBoard(b ?? { requests: [], types: [] });
    setBalances(bal);
    window.dispatchEvent(new Event('hr-leave-changed'));
  }, [month, outletId, year, canSeeBalances]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const pending = board.requests.filter((r: any) => r.status === 'pending' && r.can_decide);
  const inMonth = board.requests.filter((r: any) => r.end_date >= month && r.start_date <= monthEnd(month) && (r.status === 'approved' || r.status === 'pending'));
  const days = useMemo(() => {
    const n = Number(monthEnd(month).slice(8, 10));
    return Array.from({ length: n }, (_, i) => addDays(month, i));
  }, [month]);
  const people = useMemo(() => {
    const m = new Map<string, { name: string; reqs: any[] }>();
    for (const r of inMonth) { const p = m.get(r.employee_id) ?? { name: r.full_name, reqs: [] as any[] }; p.reqs.push(r); m.set(r.employee_id, p); }
    return [...m.entries()].sort((a, b) => a[1].name.localeCompare(b[1].name));
  }, [inMonth]);
  const today = localDate();

  const decide = async (r: any, ok: boolean) => {
    const note = ok ? '' : await prompt({ title: 'Tolak pengajuan?', label: 'Alasan (dilihat karyawan)', required: true });
    if (!ok && note === null) return;
    try {
      await rpc('hr_decide_leave', { p_id: r.id, p_approve: ok, p_note: note || null });
      toast(ok ? 'Cuti disetujui' : 'Pengajuan ditolak', 'success');
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const openDoc = async (path: string) => {
    const url = await hrFileUrl(path);
    if (url) window.open(url, '_blank', 'noopener');
  };
  const saveAdjust = async () => {
    try {
      await must(supabase.from('hr_leave_adjustments').insert({ company_id: companyId, employee_id: adjust.employee_id, year, days: Number(adjust.days), note: adjust.note }));
      setAdjust(null);
      toast('Saldo disesuaikan', 'success');
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const exportXlsx = () => downloadXlsx(`saldo-cuti-${year}`, [{
    name: `Saldo ${year}`, widths: [14, 26, 18, 12, 10, 12, 10, 10, 8],
    rows: (balances ?? []).map((b) => ({ 'No. Karyawan': b.employee_number, Nama: b.full_name, Outlet: b.outlet ?? '', 'Tgl masuk': b.join_date ?? '',
      Hak: Number(b.entitlement), Penyesuaian: Number(b.adjustment), Terpakai: Number(b.used), Menunggu: Number(b.pending), Sisa: Number(b.remaining) })),
  }]);

  return (
    <>
      {pending.length > 0 && (
        <div className="card att-inbox">
          <div className="card-header"><h2>Menunggu keputusan <span className="badge badge-danger">{pending.length}</span></h2></div>
          {pending.map((r: any) => (
            <div key={r.id} className="att-inbox-row">
              <div>
                <b>{r.full_name}</b> <span className="muted small">· {r.position ?? ''}{r.outlet ? ` · ${r.outlet}` : ''}</span>
                <div className="small"><span className="shift-dot" style={{ background: r.color }} /> <b>{r.leave_type}</b> · {dateRange(r.start_date, r.end_date)} · {r.half_day ? 'setengah hari' : fmtDays(r.days)}
                  {!r.is_paid && <span className="badge" style={{ marginLeft: 6 }}>tidak dibayar</span>}</div>
                <div className="small muted">Alasan: {r.reason}</div>
                {r.attachment_path && <button className="btn-sm" style={{ marginTop: 4 }} onClick={() => openDoc(r.attachment_path)}><Paperclip size={13} /> Lihat lampiran</button>}
              </div>
              <div className="row" style={{ gap: 6 }}>
                <button className="btn-sm" onClick={() => decide(r, false)}><X size={14} /> Tolak</button>
                <button className="btn-sm btn-primary" onClick={() => decide(r, true)}><Check size={14} /> Setujui</button>
              </div>
            </div>
          ))}
        </div>
      )}

      <div className="card">
        <div className="card-header roster-head">
          <div className="row" style={{ gap: 6 }}>
            <button className="btn-sm" onClick={() => setMonth(shiftMonth(month, -1))} aria-label="Bulan sebelumnya"><ChevronLeft size={15} /></button>
            <b>{new Date(`${month}T00:00:00Z`).toLocaleDateString('id-ID', { month: 'long', year: 'numeric', timeZone: 'UTC' })}</b>
            <button className="btn-sm" onClick={() => setMonth(shiftMonth(month, 1))} aria-label="Bulan berikutnya"><ChevronRight size={15} /></button>
          </div>
          <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
            <select value={outletId} onChange={(e) => setOutletId(e.target.value)}>
              <option value="">Semua outlet</option>
              {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select>
            {can('hr.manage') && <button className="btn-sm" onClick={() => setTypes(true)}><Settings2 size={14} /> Jenis cuti & aturan</button>}
          </div>
        </div>
        <div className="table-wrap">
          <table className="table leave-cal">
            <thead>
              <tr><th>Karyawan</th>{days.map((d) => {
                const dow = new Date(`${d}T00:00:00Z`).getUTCDay();
                return <th key={d} className={`${d === today ? 'today' : ''} ${dow === 0 ? 'sun' : ''}`}>{Number(d.slice(8))}</th>;
              })}</tr>
            </thead>
            <tbody>
              {people.map(([id, p]) => (
                <tr key={id}>
                  <td className="bold small">{p.name}</td>
                  {days.map((d) => {
                    const r = p.reqs.find((x: any) => d >= x.start_date && d <= x.end_date);
                    return <td key={d} className={d === today ? 'today' : ''}>
                      {r && <span className={`leave-cell ${r.status}`} style={{ background: r.color }} title={`${r.leave_type} · ${LEAVE_STATUS[r.status][0]}${r.half_day ? ' · ½ hari' : ''}`}>{r.half_day ? '½' : ''}</span>}
                    </td>;
                  })}
                </tr>
              ))}
              {!people.length && <tr><td colSpan={days.length + 1} className="empty">Tidak ada yang cuti bulan ini.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="leave-legend small">
          {board.types.filter((t: any) => t.is_active).map((t: any) => <span key={t.id}><span className="shift-dot" style={{ background: t.color }} /> {t.name}</span>)}
          <span className="muted">· arsir = menunggu persetujuan</span>
        </div>
      </div>

      {balances && (
        <div className="card table-wrap">
          <div className="card-header"><h2>Saldo cuti tahunan {year}</h2><button className="btn-sm" onClick={exportXlsx} disabled={!balances.length}><Download size={14} /> Excel</button></div>
          <table className="table">
            <thead><tr><th>Karyawan</th><th>Masuk</th><th className="right">Hak</th><th className="right">Penyesuaian</th><th className="right">Terpakai</th><th className="right">Menunggu</th><th className="right">Sisa</th><th></th></tr></thead>
            <tbody>
              {balances.map((b) => (
                <tr key={b.employee_id}>
                  <td><b>{b.full_name}</b><div className="muted small">{b.position ?? ''}{b.outlet ? ` · ${b.outlet}` : ''}</div></td>
                  <td className="small">{b.join_date ? new Date(`${b.join_date}T00:00:00Z`).toLocaleDateString('id-ID', { timeZone: 'UTC' }) : '—'}
                    {Number(b.entitlement) === 0 && b.eligible_from && <div className="muted">berhak {new Date(`${b.eligible_from}T00:00:00Z`).toLocaleDateString('id-ID', { timeZone: 'UTC' })}</div>}</td>
                  <td className="right">{Number(b.entitlement)}</td>
                  <td className="right">{Number(b.adjustment) ? Number(b.adjustment) : '—'}</td>
                  <td className="right">{Number(b.used)}</td>
                  <td className="right">{Number(b.pending) || '—'}</td>
                  <td className="right bold">{Number(b.remaining)}</td>
                  <td className="right">{can('hr.manage') && <button className="btn-sm" onClick={() => setAdjust({ employee_id: b.employee_id, name: b.full_name, days: '', note: '' })}>Sesuaikan</button>}</td>
                </tr>
              ))}
              {!balances.length && <tr><td colSpan={8} className="empty">Belum ada karyawan aktif.</td></tr>}
            </tbody>
          </table>
          <p className="muted small" style={{ margin: '8px 0 0' }}>Penyesuaian untuk saldo awal (pindahan dari sistem lama), sisa tahun lalu, atau kompensasi. Nilai minus untuk mengurangi.</p>
        </div>
      )}

      {adjust && (
        <Modal title={`Sesuaikan saldo ${adjust.name} (${year})`} onClose={() => setAdjust(null)}
          footer={<><button onClick={() => setAdjust(null)}>Batal</button><button className="btn-primary" disabled={!Number(adjust.days) || !adjust.note.trim()} onClick={saveAdjust}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Jumlah hari (+ / −)</span><input type="number" step="0.5" value={adjust.days} placeholder="mis. 3 atau -1" onChange={(e) => setAdjust({ ...adjust, days: e.target.value })} /></label>
            <label className="field"><span>Keterangan</span><input value={adjust.note} placeholder="mis. Sisa cuti 2025" onChange={(e) => setAdjust({ ...adjust, note: e.target.value })} /></label>
          </div>
        </Modal>
      )}
      {types && <LeaveTypes companyId={companyId} onClose={() => { setTypes(false); load(); }} />}
    </>
  );
}

function LeaveTypes({ companyId, onClose }: { companyId: string; onClose: () => void }) {
  const { toast } = useFeedback();
  const [list, setList] = useState<any[]>([]);
  const [settings, setSettings] = useState<any | null>(null);
  const [edit, setEdit] = useState<any | null>(null);
  const load = useCallback(async () => {
    const [l, s] = await Promise.all([must(supabase.from('hr_leave_types').select('*').order('deducts_balance', { ascending: false }).order('name')), rpc<any>('hr_get_settings')]);
    setList(l);
    setSettings(s);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const saveSettings = async () => {
    try {
      await must(supabase.from('hr_settings').upsert({ company_id: companyId, annual_leave_days: Number(settings.annual_leave_days), leave_policy: settings.leave_policy, updated_at: new Date().toISOString() }));
      toast('Aturan cuti disimpan', 'success');
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const save = async () => {
    try {
      const v = { code: edit.code?.trim().toUpperCase(), name: edit.name?.trim(), deducts_balance: !!edit.deducts_balance, is_paid: edit.is_paid !== false,
        attachment_min_days: edit.attachment_min_days === '' || edit.attachment_min_days == null ? null : Number(edit.attachment_min_days),
        max_days: edit.max_days === '' || edit.max_days == null ? null : Number(edit.max_days), color: edit.color, is_active: edit.is_active !== false };
      if (!v.code || !v.name) throw new Error('Kode & nama wajib diisi');
      if (edit.id) await must(supabase.from('hr_leave_types').update(v).eq('id', edit.id));
      else await must(supabase.from('hr_leave_types').insert({ ...v, company_id: companyId }));
      setEdit(null);
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <Modal title="Jenis cuti & aturan" onClose={onClose}
      footer={edit ? <><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={save}>Simpan</button></>
        : <><button onClick={onClose}>Tutup</button><button className="btn-primary" onClick={() => setEdit({ color: COLORS[list.length % COLORS.length], is_paid: true, is_active: true })}><Plus size={14} /> Jenis cuti</button></>}>
      {edit ? (
        <div className="form-grid">
          <label className="field"><span>Kode</span><input value={edit.code ?? ''} placeholder="KHITAN" onChange={(e) => setEdit({ ...edit, code: e.target.value })} /></label>
          <label className="field"><span>Nama</span><input value={edit.name ?? ''} placeholder="Cuti khitanan anak" onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
          <label className="field"><span>Maks. hari per pengajuan</span><input type="number" min={1} value={edit.max_days ?? ''} placeholder="bebas" onChange={(e) => setEdit({ ...edit, max_days: e.target.value })} /></label>
          <label className="field"><span>Wajib lampiran mulai (hari)</span><input type="number" min={1} value={edit.attachment_min_days ?? ''} placeholder="tidak wajib" onChange={(e) => setEdit({ ...edit, attachment_min_days: e.target.value })} /></label>
          <div className="field"><span>Warna</span>
            <div className="row" style={{ gap: 6 }}>{COLORS.map((c) => <button key={c} type="button" className={`color-dot ${edit.color === c ? 'active' : ''}`} style={{ background: c }} onClick={() => setEdit({ ...edit, color: c })} aria-label={c} />)}</div>
          </div>
          <div className="grid" style={{ gridColumn: '1 / -1' }}>
            <label className="row"><input type="checkbox" checked={!!edit.deducts_balance} onChange={(e) => setEdit({ ...edit, deducts_balance: e.target.checked })} /> Memotong saldo cuti tahunan</label>
            <label className="row"><input type="checkbox" checked={edit.is_paid !== false} onChange={(e) => setEdit({ ...edit, is_paid: e.target.checked })} /> Tetap dibayar</label>
            {edit.id && <label className="row"><input type="checkbox" checked={edit.is_active !== false} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} /> Aktif</label>}
          </div>
        </div>
      ) : (
        <>
          {settings && (
            <div className="geo-box" style={{ marginTop: 0, marginBottom: 12 }}>
              <div className="form-grid">
                <label className="field"><span>Cuti tahunan (hari / tahun)</span><input type="number" min={0} max={60} value={settings.annual_leave_days} onChange={(e) => setSettings({ ...settings, annual_leave_days: e.target.value })} /></label>
                <label className="field"><span>Kapan berhak</span>
                  <select value={settings.leave_policy} onChange={(e) => setSettings({ ...settings, leave_policy: e.target.value })}>
                    {Object.entries(LEAVE_POLICY).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                  </select>
                </label>
              </div>
              <div className="row" style={{ justifyContent: 'space-between', marginTop: 8 }}>
                <small className="muted">UU Ketenagakerjaan: minimal 12 hari setelah 12 bulan kerja terus-menerus.</small>
                <button className="btn-sm btn-primary" onClick={saveSettings}>Simpan aturan</button>
              </div>
            </div>
          )}
          <table className="table">
            <thead><tr><th>Jenis</th><th>Aturan</th><th></th></tr></thead>
            <tbody>
              {list.map((t) => (
                <tr key={t.id}>
                  <td><span className="shift-dot" style={{ background: t.color }} /> <b>{t.name}</b> <span className="muted small">{t.code}</span> {!t.is_active && <span className="badge">Nonaktif</span>}</td>
                  <td className="small">{[t.deducts_balance && 'potong saldo', !t.is_paid && 'tidak dibayar', t.max_days && `maks ${t.max_days} hari`, t.attachment_min_days && `lampiran ≥ ${t.attachment_min_days} hari`].filter(Boolean).join(' · ') || '—'}</td>
                  <td className="right"><button className="btn-sm" onClick={() => setEdit(t)}>Edit</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </Modal>
  );
}
