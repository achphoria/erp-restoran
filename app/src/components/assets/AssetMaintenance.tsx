import { useCallback, useEffect, useState } from 'react';
import { Pencil, Plus } from 'lucide-react';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';
import { REPAIR_STATUS, SEVERITY, UNIT_LABEL, dayISO, fmtDate, type AssetOptions, type Opt } from '../../lib/assets';
import { LogDialog, PlanDialog, RepairDialog } from './MaintenanceDialogs';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Tab Perawatan di detail aset: jadwal rutin, riwayat perawatan + biaya, laporan kerusakan
export default function AssetMaintenance({ asset, options, refreshKey, onChanged }: { asset: any; options: AssetOptions; refreshKey: number; onChanged: () => void }) {
  const { toast } = useFeedback();
  const [d, setD] = useState<any | null>(null);
  const [roles, setRoles] = useState<Opt[]>([]);
  const [plan, setPlan] = useState<any | 'new' | null>(null);
  const [log, setLog] = useState<any | 'new' | null>(null);
  const [repair, setRepair] = useState<any | null>(null);
  const manage = options.can_manage && asset.status === 'active';

  const load = useCallback(async () => setD(await rpc<any>('ast_maintenance_detail', { p_asset_id: asset.id })), [asset.id]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast, refreshKey]);
  useEffect(() => { if (manage) rpc<any>('hr_task_people').then((p) => setRoles(p?.roles ?? [])).catch(() => undefined); }, [manage]);
  const done = () => { setPlan(null); setLog(null); setRepair(null); load(); onChanged(); };
  if (!d) return <div className="skeleton" style={{ height: 160 }} />;
  const today = dayISO(0);

  return (
    <div className="grid">
      <div className="card">
        <div className="card-header"><h4 style={{ margin: 0 }}>Jadwal perawatan rutin</h4>{manage && <button className="btn-sm" onClick={() => setPlan('new')}><Plus size={14} /> Jadwal</button>}</div>
        {d.plans.map((p: any) => (
          <div key={p.id} className={`asset-plan ${p.is_active ? '' : 'inactive'}`}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <b>{p.title}</b> <span className="muted small">tiap {p.interval_value} {UNIT_LABEL[p.interval_unit]}</span>
              {!p.is_active && <span className="badge" style={{ marginLeft: 6 }}>nonaktif</span>}
              <div className="small">
                Berikutnya <b className={p.is_active && p.next_due_date < today ? 'text-danger' : ''}>{fmtDate(p.next_due_date)}</b>
                {p.assignee && ` · ${p.assignee}`}{p.last_done_on && <span className="muted"> · terakhir {fmtDate(p.last_done_on)}</span>}
              </div>
              {p.open_task_number && <div className="small muted">Tugas {p.open_task_number} sedang berjalan</div>}
            </div>
            {manage && <button className="btn-sm" onClick={() => setPlan(p)}><Pencil size={13} /></button>}
          </div>
        ))}
        {!d.plans.length && <p className="muted small" style={{ margin: 0 }}>Belum ada jadwal. Contoh: service AC tiap 3 bulan, kuras grease trap tiap bulan. Tugas otomatis muncul di menu Tugas menjelang jatuh tempo.</p>}
      </div>

      <div className="card table-wrap">
        <div className="card-header">
          <h4 style={{ margin: 0 }}>Kerusakan & perbaikan</h4>
          <span className="small muted">Total biaya perawatan + perbaikan: <b>{formatRupiah(d.total_cost)}</b></span>
        </div>
        <table className="table">
          <thead><tr><th>Laporan</th><th>Kerusakan</th><th>Status</th><th className="right">Biaya</th></tr></thead>
          <tbody>
            {d.repairs.map((r: any) => (
              <tr key={r.id} className={manage ? 'clickable-row' : ''} onClick={() => manage && setRepair({ ...r, asset: asset.name })}>
                <td className="small"><b>{r.repair_number}</b><div className="muted">{fmtDate(String(r.reported_at).slice(0, 10))} · {r.reported_by_name ?? '-'}</div></td>
                <td className="small"><span className={`badge ${SEVERITY[r.severity]?.[1]}`}>{SEVERITY[r.severity]?.[0]}</span> {r.description}
                  {r.resolution && <div className="muted">→ {r.resolution}</div>}</td>
                <td><span className={`badge ${REPAIR_STATUS[r.status]?.[1]}`}>{REPAIR_STATUS[r.status]?.[0]}</span>
                  <div className="small muted">{r.downtime_hours >= 24 ? `${Math.round(r.downtime_hours / 24)} hari` : `${r.downtime_hours} jam`}</div></td>
                <td className="right">{Number(r.cost) ? formatRupiah(r.cost) : '-'}</td>
              </tr>
            ))}
            {!d.repairs.length && <tr><td colSpan={4} className="empty">Belum pernah dilaporkan rusak.</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="card table-wrap">
        <div className="card-header"><h4 style={{ margin: 0 }}>Riwayat perawatan</h4>{manage && <button className="btn-sm" onClick={() => setLog('new')}><Plus size={14} /> Catat</button>}</div>
        <table className="table">
          <thead><tr><th>Tanggal</th><th>Pekerjaan</th><th>Oleh</th><th className="right">Biaya</th></tr></thead>
          <tbody>
            {d.logs.map((l: any) => (
              <tr key={l.id} className={manage ? 'clickable-row' : ''} onClick={() => manage && setLog(l)}>
                <td className="small">{fmtDate(l.performed_on)}</td>
                <td className="small"><b>{l.title}</b>{l.kind === 'skipped' && <span className="badge" style={{ marginLeft: 6 }}>dilewati</span>}
                  {l.task_number && <span className="muted"> · {l.task_number}</span>}{l.note && <div className="muted">{l.note}</div>}</td>
                <td className="small">{l.performed_by_name ?? '-'}{l.vendor && <div className="muted">{l.vendor}</div>}</td>
                <td className="right">{Number(l.cost) ? formatRupiah(l.cost) : manage && l.kind !== 'skipped' ? <span className="muted small">isi biaya</span> : '-'}
                  {l.journal_number && <div className="muted small">{l.journal_number}</div>}</td>
              </tr>
            ))}
            {!d.logs.length && <tr><td colSpan={4} className="empty">Belum ada riwayat perawatan.</td></tr>}
          </tbody>
        </table>
      </div>

      {plan && <PlanDialog assetId={asset.id} initial={plan === 'new' ? undefined : plan} users={options.users} roles={roles} onClose={() => setPlan(null)} onDone={done} />}
      {log && <LogDialog assetId={asset.id} initial={log === 'new' ? undefined : log} cashAccounts={options.cash_accounts} onClose={() => setLog(null)} onDone={done} />}
      {repair && <RepairDialog repair={repair} cashAccounts={options.cash_accounts} onClose={() => setRepair(null)} onDone={done} />}
    </div>
  );
}
