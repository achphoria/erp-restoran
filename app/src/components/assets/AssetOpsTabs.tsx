import { useCallback, useEffect, useState } from 'react';
import { ArrowLeft, CheckCircle2, ClipboardCheck, Plus } from 'lucide-react';
import Modal from '../Modal';
import ScanInput from '../ScanInput';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatRupiah } from '../../lib/format';
import { AUDIT_RESULT, REPAIR_STATUS, SEVERITY, UNIT_LABEL, dayISO, fmtDate, parseAssetCode, type AssetOptions } from '../../lib/assets';
import { RepairDialog } from './MaintenanceDialogs';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Tab "Perawatan & kerusakan": jadwal yang jatuh tempo, tiket kerusakan, aset dengan biaya perawatan terbesar
export function MaintenanceOverview({ options, onOpen }: { options: AssetOptions; onOpen: (assetId: string) => void }) {
  const { toast } = useFeedback();
  const [d, setD] = useState<any | null>(null);
  const [repair, setRepair] = useState<any | null>(null);
  const [showDone, setShowDone] = useState(false);
  const load = useCallback(async () => setD(await rpc<any>('ast_maintenance_overview')), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);
  if (!d) return <div className="skeleton" style={{ height: 200 }} />;
  const soon = dayISO(14);
  const plans = d.plans.filter((p: any) => p.next_due_date <= soon);
  const repairs = d.repairs.filter((r: any) => showDone || !['done', 'cancelled'].includes(r.status));

  return (
    <div className="grid">
      <div className="card table-wrap">
        <div className="card-header"><h3 style={{ margin: 0 }}>Laporan kerusakan</h3>
          <label className="row small"><input type="checkbox" checked={showDone} onChange={(e) => setShowDone(e.target.checked)} /> Tampilkan yang selesai (60 hari)</label></div>
        <table className="table">
          <thead><tr><th>Laporan</th><th>Aset</th><th>Kerusakan</th><th>Status</th><th className="right">Biaya</th></tr></thead>
          <tbody>
            {repairs.map((r: any) => (
              <tr key={r.id} className="clickable-row" onClick={() => options.can_manage ? setRepair(r) : onOpen(r.asset_id)}>
                <td className="small"><b>{r.number}</b><div className="muted">{formatDateTime(r.reported_at)}</div><div className="muted">{r.reported_by ?? '-'}</div></td>
                <td className="small"><b>{r.asset}</b><div className="muted">{r.asset_number} · {r.outlet}</div></td>
                <td className="small"><span className={`badge ${SEVERITY[r.severity]?.[1]}`}>{SEVERITY[r.severity]?.[0]}</span> {r.description}</td>
                <td><span className={`badge ${REPAIR_STATUS[r.status]?.[1]}`}>{REPAIR_STATUS[r.status]?.[0]}</span>
                  <div className="small muted">{r.downtime_hours >= 24 ? `${Math.round(r.downtime_hours / 24)} hari` : `${r.downtime_hours} jam`}{r.task_number && ` · ${r.task_number}`}</div></td>
                <td className="right">{Number(r.cost) ? formatRupiah(r.cost) : '-'}</td>
              </tr>
            ))}
            {!repairs.length && <tr><td colSpan={5} className="empty">Tidak ada kerusakan yang terbuka. 👍<br /><small>Karyawan melapor dengan scan label QR di aset, atau dari Beranda Saya.</small></td></tr>}
          </tbody>
        </table>
      </div>

      <div className="grid grid-2 asset-dep-grid">
        <div className="card table-wrap">
          <h3 style={{ marginTop: 0 }}>Perawatan 14 hari ke depan</h3>
          <table className="table">
            <thead><tr><th>Jatuh tempo</th><th>Perawatan</th><th>Tugas</th></tr></thead>
            <tbody>
              {plans.map((p: any) => (
                <tr key={p.id} className="clickable-row" onClick={() => onOpen(p.asset_id)}>
                  <td className={`small ${p.overdue ? 'text-danger' : ''}`}><b>{fmtDate(p.next_due_date)}</b>{p.overdue && <div>terlambat</div>}</td>
                  <td className="small"><b>{p.title}</b> <span className="muted">tiap {p.interval_value} {UNIT_LABEL[p.interval_unit]}</span>
                    <div className="muted">{p.asset} · {p.outlet}</div></td>
                  <td className="small">{p.open_task_number ?? <span className="muted">belum dibuat</span>}<div className="muted">{p.assignee ?? 'PJ aset'}</div></td>
                </tr>
              ))}
              {!plans.length && <tr><td colSpan={3} className="empty">Tidak ada perawatan yang jatuh tempo.<br /><small>{d.plans.length} jadwal aktif. Tambah jadwal di detail aset → tab Perawatan.</small></td></tr>}
            </tbody>
          </table>
        </div>
        <div className="card table-wrap">
          <h3 style={{ marginTop: 0 }}>Biaya perawatan terbesar (12 bulan)</h3>
          <table className="table">
            <thead><tr><th>Aset</th><th className="right">Biaya</th><th className="right">Nilai buku</th></tr></thead>
            <tbody>
              {d.top_cost.map((x: any) => {
                const heavy = Number(x.total) > Number(x.book_value) * 0.5;
                return (
                  <tr key={x.asset_id} className="clickable-row" onClick={() => onOpen(x.asset_id)}>
                    <td className="small"><b>{x.asset}</b><div className="muted">{x.asset_number} · {x.count}× servis</div>
                      {heavy && <div className="text-danger">Biaya &gt; 50% nilai buku, pertimbangkan ganti baru</div>}</td>
                    <td className="right"><b>{formatRupiah(x.total)}</b></td>
                    <td className="right small">{formatRupiah(x.book_value)}</td>
                  </tr>
                );
              })}
              {!d.top_cost.length && <tr><td colSpan={3} className="empty">Belum ada biaya perawatan tercatat.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
      {repair && <RepairDialog repair={repair} cashAccounts={options.cash_accounts} onClose={() => setRepair(null)} onDone={() => { setRepair(null); load(); }} />}
    </div>
  );
}

// Tab "Opname": daftar opname per outlet & sesi scan
export function AuditTab({ options, canAudit, onOpen }: { options: AssetOptions; canAudit: boolean; onOpen: (assetId: string) => void }) {
  const { toast, confirm } = useFeedback();
  const [list, setList] = useState<any[] | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [starting, setStarting] = useState<any | null>(null);
  const load = useCallback(async () => setList(await rpc<any[]>('ast_audit_list')), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const start = async () => {
    try {
      const r = await rpc<any>('ast_audit_start', { p_outlet_id: starting.outlet_id || null, p_note: starting.note });
      setStarting(null); load(); setOpenId(r.id);
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  if (openId) return <AuditSession id={openId} canAudit={canAudit} onBack={() => { setOpenId(null); load(); }} onOpen={onOpen} confirm={confirm} />;
  return (
    <div className="card table-wrap">
      <div className="card-header"><h3 style={{ margin: 0 }}>Opname aset</h3>
        {canAudit && <button className="btn-primary btn-sm" onClick={() => setStarting({ outlet_id: options.outlets[0]?.id ?? '', note: '' })}><Plus size={14} /> Mulai opname</button>}</div>
      <p className="small muted" style={{ marginTop: 0 }}>Cek fisik aset per outlet: scan label QR satu per satu pakai HP / scanner. Yang tidak ter-scan saat ditutup dianggap hilang.</p>
      <table className="table">
        <thead><tr><th>Nomor</th><th>Outlet</th><th>Mulai</th><th>Hasil</th><th>Status</th></tr></thead>
        <tbody>
          {(list ?? []).map((x) => (
            <tr key={x.id} className="clickable-row" onClick={() => setOpenId(x.id)}>
              <td><b className="small">{x.audit_number}</b>{x.note && <div className="muted small">{x.note}</div>}</td>
              <td className="small">{x.outlet}</td>
              <td className="small">{formatDateTime(x.started_at)}<div className="muted">{x.started_by}</div></td>
              <td className="small">{x.found}/{x.total} ditemukan{x.missing > 0 && <span className="text-danger"> · {x.missing} hilang</span>}{x.unexpected > 0 && ` · ${x.unexpected} salah lokasi`}</td>
              <td>{x.status === 'open' ? <span className="badge badge-warning">Berjalan</span> : <span className="badge badge-success">Selesai</span>}</td>
            </tr>
          ))}
          {list && !list.length && <tr><td colSpan={5} className="empty">Belum pernah opname aset.</td></tr>}
        </tbody>
      </table>
      {starting && (
        <Modal title="Mulai opname aset" onClose={() => setStarting(null)}
          footer={<><button onClick={() => setStarting(null)}>Batal</button><button className="btn-primary" onClick={start}>Mulai</button></>}>
          <label className="field"><span>Outlet</span>
            <select value={starting.outlet_id} onChange={(e) => setStarting({ ...starting, outlet_id: e.target.value })}>
              {options.all_outlets && <option value="">Kantor pusat</option>}
              {options.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select></label>
          <label className="field"><span>Catatan</span><input value={starting.note} onChange={(e) => setStarting({ ...starting, note: e.target.value })} placeholder="mis. Opname akhir tahun" /></label>
        </Modal>
      )}
    </div>
  );
}

function AuditSession({ id, canAudit, onBack, onOpen, confirm }: {
  id: string; canAudit: boolean; onBack: () => void; onOpen: (assetId: string) => void; confirm: (o: any) => Promise<boolean>;
}) {
  const { toast } = useFeedback();
  const [d, setD] = useState<any | null>(null);
  const [damaged, setDamaged] = useState(false);
  const [location, setLocation] = useState('');
  const [last, setLast] = useState<any | null>(null);
  const load = useCallback(async () => setD(await rpc<any>('ast_audit_detail', { p_audit_id: id })), [id]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);
  const open = d?.status === 'open' && canAudit;

  const scan = async (raw: string) => {
    try {
      const r = await rpc<any>('ast_audit_scan', { p_audit_id: id, p_code: parseAssetCode(raw), p_condition: damaged ? 'damaged' : 'good', p_location: location || null });
      setLast(r); setDamaged(false);
      toast(r.result === 'unexpected' ? `${r.name}: terdaftar di ${r.registered_outlet ?? 'Kantor pusat'} (salah lokasi)` : `${r.name} ditemukan`, r.result === 'unexpected' ? 'info' : 'success');
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const close = async () => {
    if (!(await confirm({ title: `Tutup ${d.audit_number}?`, message: `${d.summary.pending} aset belum di-scan akan dicatat HILANG.`, confirmLabel: 'Tutup opname', danger: d.summary.pending > 0 }))) return;
    try { await rpc('ast_audit_close', { p_audit_id: id }); toast('Opname ditutup', 'success'); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  if (!d) return <div className="skeleton" style={{ height: 240 }} />;
  const pct = d.summary.total ? Math.round((d.summary.found / d.summary.total) * 100) : 0;

  return (
    <div className="grid">
      <div className="card">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <button className="btn-sm" onClick={onBack}><ArrowLeft size={14} /> Daftar opname</button>
          {open && <button className="btn-primary btn-sm" onClick={close}><CheckCircle2 size={14} /> Tutup opname</button>}
        </div>
        <h3 style={{ margin: '12px 0 4px' }}>{d.audit_number} · {d.outlet}</h3>
        <div className="small muted">Mulai {formatDateTime(d.started_at)} oleh {d.started_by_name ?? '-'}{d.closed_at && ` · ditutup ${formatDateTime(d.closed_at)}`}</div>
        <div className="asset-bar" style={{ height: 10, marginTop: 12 }}><span style={{ width: `${pct}%` }} /></div>
        <div className="small"><b>{d.summary.found}</b> dari {d.summary.total} ditemukan · {d.summary.pending} belum · {d.summary.missing} hilang · {d.summary.unexpected} salah lokasi · {d.summary.damaged} rusak</div>
        {open && (
          <div className="asset-audit-scan">
            <ScanInput onScan={scan} placeholder="Scan label QR / ketik kode aset" autoFocus />
            <input value={location} onChange={(e) => setLocation(e.target.value)} placeholder="Lokasi ditemukan (opsional)" />
            <label className="row small"><input type="checkbox" checked={damaged} onChange={(e) => setDamaged(e.target.checked)} /> Kondisi rusak (otomatis buat laporan kerusakan)</label>
            {last && <div className="small muted"><ClipboardCheck size={13} /> Terakhir: {last.asset_number} {last.name}</div>}
          </div>
        )}
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Aset</th><th>Terdaftar di</th><th>Hasil</th><th>Di-scan</th></tr></thead>
          <tbody>
            {d.items.map((i: any) => (
              <tr key={i.id} className="clickable-row" onClick={() => onOpen(i.asset_id)}>
                <td className="small"><b>{i.name}</b><div className="muted">{i.asset_number} · {i.category}</div></td>
                <td className="small">{i.registered_outlet}{i.location && <div className="muted">{i.location}</div>}</td>
                <td><span className={`badge ${AUDIT_RESULT[i.result]?.[1]}`}>{AUDIT_RESULT[i.result]?.[0]}</span>
                  {i.condition === 'damaged' && <span className="badge badge-danger" style={{ marginLeft: 4 }}>Rusak</span>}
                  {i.found_location && <div className="small muted">di {i.found_location}</div>}
                  {d.status === 'closed' && i.result === 'missing' && i.asset_status === 'active' && <div className="small text-danger">Cari dulu; bila benar hilang, Lepas aset (Hilang)</div>}
                  {d.status === 'closed' && i.result === 'unexpected' && <div className="small">Mutasi aset ke {d.outlet} bila memang dipindah</div>}</td>
                <td className="small">{i.scanned_at ? <>{formatDateTime(i.scanned_at)}<div className="muted">{i.scanned_by}</div></> : '-'}</td>
              </tr>
            ))}
            {!d.items.length && <tr><td colSpan={4} className="empty">Tidak ada aset tercatat di lokasi ini.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
