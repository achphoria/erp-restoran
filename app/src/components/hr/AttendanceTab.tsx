import { useCallback, useEffect, useMemo, useState } from 'react';
import { Check, Download, ExternalLink, Image as ImageIcon, Settings2, X } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { downloadXlsx } from '../../lib/excel';
import { ATT_FLAGS, ATT_STATUS, addDays, fmtTime, hrFileUrl, localDate, mondayOf } from '../../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Filter = 'all' | 'late' | 'absent' | 'review';
const dmy = (iso: string) => new Date(`${iso}T00:00:00Z`).toLocaleDateString('id-ID', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });
const fmtDist = (m: number | null) => (m == null ? '' : m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${m} m`);

// Rekap absensi: hadir / telat / alpa, foto selfie, review absen yang ditandai, pengajuan koreksi, export Excel
export default function AttendanceTab({ companyId, outlets }: { companyId: string; outlets: { id: string; name: string }[] }) {
  const { can } = useAuth();
  const { toast, prompt } = useFeedback();
  const today = localDate();
  const [from, setFrom] = useState(() => mondayOf(today));
  const [to, setTo] = useState(today);
  const [outletId, setOutletId] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<any[]>([]);
  const [inbox, setInbox] = useState<any[]>([]);
  const [detail, setDetail] = useState<any | null>(null);
  const [settings, setSettings] = useState<any | null>(null);
  const canReview = can(['hr.manage', 'hr.attendance']);

  const load = useCallback(async () => {
    const [r, c] = await Promise.all([
      rpc<any[]>('hr_attendance_recap', { p_from: from, p_to: to, p_outlet_id: outletId || null }),
      rpc<any[]>('hr_correction_inbox', { p_status: 'pending' }),
    ]);
    setRows(r ?? []);
    setInbox(c ?? []);
    window.dispatchEvent(new Event('hr-attendance-changed'));
  }, [from, to, outletId]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const shown = useMemo(() => rows.filter((r) =>
    (filter === 'all' || (filter === 'late' && r.status === 'late') || (filter === 'absent' && r.status === 'absent') || (filter === 'review' && r.review_status === 'pending'))
    && (!q || r.full_name.toLowerCase().includes(q.toLowerCase()) || r.employee_number?.toLowerCase().includes(q.toLowerCase()))), [rows, filter, q]);
  const sum = useMemo(() => ({
    present: rows.filter((r) => r.status === 'present' || r.status === 'late').length,
    late: rows.filter((r) => r.status === 'late').length,
    absent: rows.filter((r) => r.status === 'absent').length,
    review: rows.filter((r) => r.review_status === 'pending').length,
  }), [rows]);

  const review = async (r: any, approve: boolean) => {
    const note = approve ? '' : await prompt({ title: 'Tolak absen ini?', label: 'Alasan (dilihat karyawan)', required: true });
    if (!approve && note === null) return;
    try {
      await rpc('hr_review_attendance', { p_id: r.attendance_id, p_approve: approve, p_note: note || null });
      setDetail(null);
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const decide = async (c: any, approve: boolean) => {
    const note = approve ? '' : await prompt({ title: 'Tolak pengajuan koreksi?', label: 'Alasan', required: true });
    if (!approve && note === null) return;
    try {
      await rpc('hr_review_correction', { p_id: c.id, p_approve: approve, p_note: note || null });
      toast(approve ? 'Koreksi disetujui, absen diperbarui' : 'Pengajuan ditolak', 'success');
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  const exportXlsx = () => {
    const per = new Map<string, any>();
    for (const r of rows) {
      const p = per.get(r.employee_id) ?? { 'No. Karyawan': r.employee_number, Nama: r.full_name, Jabatan: r.position ?? '', Hadir: 0, Telat: 0, 'Total telat (mnt)': 0, Alpa: 0, Libur: 0, Cuti: 0, 'Pulang cepat (mnt)': 0 };
      if (r.status === 'present' || r.status === 'late') p.Hadir++;
      if (r.status === 'late') { p.Telat++; p['Total telat (mnt)'] += r.late_minutes; }
      if (r.status === 'absent') p.Alpa++;
      if (r.status === 'off') p.Libur++;
      if (r.status === 'leave') p.Cuti++;
      p['Pulang cepat (mnt)'] += r.early_leave_minutes;
      per.set(r.employee_id, p);
    }
    downloadXlsx(`absensi-${from}-sd-${to}`, [
      { name: 'Ringkasan', rows: [...per.values()], widths: [14, 26, 18, 8, 8, 16, 8, 8, 18] },
      { name: 'Detail', widths: [12, 14, 26, 16, 10, 8, 8, 10, 10, 10, 30, 14], rows: rows.map((r) => ({
        Tanggal: r.work_date, 'No. Karyawan': r.employee_number, Nama: r.full_name, Outlet: r.outlet ?? '', Shift: r.shift ?? '',
        Masuk: r.check_in_at ? fmtTime(r.check_in_at) : '', Pulang: r.check_out_at ? fmtTime(r.check_out_at) : '',
        Status: r.status === 'leave' ? r.leave_type : ATT_STATUS[r.status]?.[0] ?? r.status, 'Telat (mnt)': r.late_minutes, 'Jarak masuk (m)': r.check_in_distance_m ?? '',
        Catatan: (r.flags ?? []).map((f: string) => ATT_FLAGS[f] ?? f).join(', '), Review: r.review_status === 'none' ? '' : r.review_status,
      })) },
    ]);
  };
  const openSettings = async () => {
    try { setSettings(await rpc<any>('hr_get_settings')); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const saveSettings = async () => {
    try {
      await must(supabase.from('hr_settings').upsert({ company_id: companyId, late_tolerance_minutes: Number(settings.late_tolerance_minutes),
        require_photo: settings.require_photo, require_gps: settings.require_gps, max_gps_accuracy_m: Number(settings.max_gps_accuracy_m), updated_at: new Date().toISOString() }));
      setSettings(null);
      toast('Aturan absensi disimpan', 'success');
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <>
      {canReview && inbox.length > 0 && (
        <div className="card att-inbox">
          <div className="card-header"><h2>Pengajuan koreksi absen <span className="badge badge-danger">{inbox.length}</span></h2></div>
          {inbox.map((c) => (
            <div key={c.id} className="att-inbox-row">
              <div>
                <b>{c.full_name}</b> <span className="muted small">· {dmy(c.work_date)}{c.outlet ? ` · ${c.outlet}` : ''}</span>
                <div className="small">Diajukan: masuk <b>{fmtTime(c.check_in_at)}</b>, pulang <b>{fmtTime(c.check_out_at)}</b>
                  {c.current && <span className="muted"> (tercatat {fmtTime(c.current.check_in_at)} – {fmtTime(c.current.check_out_at)})</span>}</div>
                <div className="small muted">Alasan: {c.reason}</div>
              </div>
              <div className="row" style={{ gap: 6 }}>
                <button className="btn-sm" onClick={() => decide(c, false)}><X size={14} /> Tolak</button>
                <button className="btn-sm btn-primary" onClick={() => decide(c, true)}><Check size={14} /> Setujui</button>
              </div>
            </div>
          ))}
        </div>
      )}

      <div className="att-stats">
        {([['all', 'Hadir', sum.present, ''], ['late', 'Telat', sum.late, 'warning'], ['absent', 'Alpa', sum.absent, 'danger'], ['review', 'Perlu review', sum.review, 'info']] as const).map(([k, l, n, tone]) => (
          <button key={k} type="button" className={`card att-stat ${tone} ${filter === k ? 'active' : ''}`} onClick={() => setFilter(filter === k ? 'all' : k)}>
            <span className="muted small">{l}</span><b>{n}</b>
          </button>
        ))}
      </div>

      <div className="card table-wrap">
        <div className="card-header att-head">
          <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
            <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />
            <span className="muted">s/d</span>
            <input type="date" value={to} min={from} max={addDays(from, 62)} onChange={(e) => setTo(e.target.value)} />
            <select value={outletId} onChange={(e) => setOutletId(e.target.value)}>
              <option value="">Semua outlet</option>
              {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select>
            <input placeholder="Cari nama…" value={q} onChange={(e) => setQ(e.target.value)} style={{ width: 150 }} />
          </div>
          <div className="row" style={{ gap: 6 }}>
            <button className="btn-sm" onClick={exportXlsx} disabled={!rows.length}><Download size={14} /> Excel</button>
            {can('hr.manage') && <button className="btn-sm" onClick={openSettings}><Settings2 size={14} /> Aturan</button>}
          </div>
        </div>
        <table className="table att-table">
          <thead><tr><th>Tanggal</th><th>Karyawan</th><th>Shift</th><th>Masuk</th><th>Pulang</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {shown.map((r) => (
              <tr key={`${r.employee_id}-${r.work_date}`} className={r.review_status === 'pending' ? 'att-pending' : ''}>
                <td className="small">{dmy(r.work_date)}</td>
                <td><b>{r.full_name}</b><div className="muted small">{r.position ?? ''}{!outletId && r.outlet ? ` · ${r.outlet}` : ''}</div></td>
                <td className="small">{r.shift ? <><span className="shift-dot" style={{ background: r.shift_color }} /> {r.shift}</> : r.is_off ? 'Libur' : <span className="muted">—</span>}</td>
                <td className="small">{fmtTime(r.check_in_at)}{r.check_in_distance_m != null && <div className="muted">{fmtDist(r.check_in_distance_m)}</div>}</td>
                <td className="small">{fmtTime(r.check_out_at)}{r.check_out_distance_m != null && <div className="muted">{fmtDist(r.check_out_distance_m)}</div>}</td>
                <td>
                  <span className={`badge ${ATT_STATUS[r.status]?.[1] ?? ''}`}>{r.status === 'leave' ? r.leave_type : ATT_STATUS[r.status]?.[0] ?? r.status}{r.status === 'late' ? ` ${r.late_minutes}m` : ''}</span>
                  {(r.flags ?? []).filter((f: string) => f !== 'no_geofence').map((f: string) => <span key={f} className="badge att-flag">{ATT_FLAGS[f] ?? f}</span>)}
                  {r.review_status === 'pending' && <span className="badge badge-info">review</span>}
                  {r.review_status === 'rejected' && <span className="badge badge-danger">ditolak</span>}
                </td>
                <td className="right">{r.attendance_id && <button className="btn-sm" onClick={() => setDetail(r)}><ImageIcon size={14} /> Lihat</button>}</td>
              </tr>
            ))}
            {!shown.length && <tr><td colSpan={7} className="empty">{rows.length ? 'Tidak ada yang cocok dengan filter.' : 'Belum ada jadwal / absen pada rentang ini.'}</td></tr>}
          </tbody>
        </table>
      </div>

      {detail && (
        <Modal title={`${detail.full_name} · ${dmy(detail.work_date)}`} onClose={() => setDetail(null)}
          footer={detail.review_status === 'pending' && canReview
            ? <><button onClick={() => review(detail, false)}><X size={14} /> Tolak</button><button className="btn-primary" onClick={() => review(detail, true)}><Check size={14} /> Setujui</button></>
            : <button onClick={() => setDetail(null)}>Tutup</button>}>
          <div className="att-photos">
            <AttShot label="Masuk" at={detail.check_in_at} path={detail.check_in_photo} dist={detail.check_in_distance_m} />
            <AttShot label="Pulang" at={detail.check_out_at} path={detail.check_out_photo} dist={detail.check_out_distance_m} />
          </div>
          {(detail.flags ?? []).length > 0 && <p className="small">Catatan sistem: {(detail.flags as string[]).map((f) => ATT_FLAGS[f] ?? f).join(', ')}</p>}
          {detail.review_note && <p className="small muted">Review: {detail.review_note}</p>}
          {detail.check_in_lat && (
            <a className="small" href={`https://www.google.com/maps?q=${detail.check_in_lat},${detail.check_in_lng}`} target="_blank" rel="noreferrer">
              <ExternalLink size={13} style={{ verticalAlign: -2 }} /> Lihat lokasi absen masuk di peta</a>
          )}
        </Modal>
      )}

      {settings && (
        <Modal title="Aturan absensi" onClose={() => setSettings(null)}
          footer={<><button onClick={() => setSettings(null)}>Batal</button><button className="btn-primary" onClick={saveSettings}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Toleransi telat (menit)</span><input type="number" min={0} max={240} value={settings.late_tolerance_minutes}
              onChange={(e) => setSettings({ ...settings, late_tolerance_minutes: e.target.value })} /></label>
            <label className="field"><span>Batas akurasi GPS (meter)</span><input type="number" min={10} value={settings.max_gps_accuracy_m}
              onChange={(e) => setSettings({ ...settings, max_gps_accuracy_m: e.target.value })} /><small className="muted">Lebih dari ini = ditandai untuk review.</small></label>
          </div>
          <div className="grid" style={{ marginTop: 10 }}>
            <label className="row"><input type="checkbox" checked={settings.require_photo} onChange={(e) => setSettings({ ...settings, require_photo: e.target.checked })} /> Wajib foto selfie</label>
            <label className="row"><input type="checkbox" checked={settings.require_gps} onChange={(e) => setSettings({ ...settings, require_gps: e.target.checked })} /> Wajib lokasi GPS</label>
          </div>
          <p className="muted small">Titik lokasi & radius tiap outlet diatur di <b>Pengaturan → Outlet</b>.</p>
        </Modal>
      )}
    </>
  );
}

function AttShot({ label, at, path, dist }: { label: string; at: string | null; path: string | null; dist: number | null }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    hrFileUrl(path).then((u) => { if (alive) setUrl(u); }).catch(() => undefined);
    return () => { alive = false; };
  }, [path]);
  return (
    <figure className="att-shot">
      {url ? <a href={url} target="_blank" rel="noreferrer"><img src={url} alt={`Selfie ${label}`} /></a> : <div className="att-shot-empty">{at ? 'Tanpa foto' : 'Belum absen'}</div>}
      <figcaption><b>{label}</b> {fmtTime(at)}{dist != null ? ` · ${fmtDist(dist)} dari outlet` : ''}</figcaption>
    </figure>
  );
}
