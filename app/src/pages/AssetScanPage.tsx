import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ClipboardCheck, ExternalLink, Wrench } from 'lucide-react';
import ScanInput from '../components/ScanInput';
import { useFeedback } from '../components/Feedback';
import { rpc } from '../lib/supabase';
import { errorMessage, formatDateTime } from '../lib/format';
import { REPAIR_STATUS, SEVERITY, assetPhotoUrl, fmtDate, parseAssetCode } from '../lib/assets';
import { ReportDamageDialog } from '../components/assets/MaintenanceDialogs';
import '../styles/assets.css';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Halaman yang terbuka saat label QR aset di-scan: semua karyawan bisa lapor kerusakan,
// petugas opname bisa langsung menandai aset ditemukan, pengelola aset bisa buka detail lengkap.
export default function AssetScanPage() {
  const { code = '' } = useParams();
  const navigate = useNavigate();
  const { toast } = useFeedback();
  const [d, setD] = useState<any | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [photo, setPhoto] = useState<string | null>(null);
  const [report, setReport] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const r = await rpc<any>('ast_scan_info', { p_code: code });
      setD(r); setErr(null);
      setPhoto(await assetPhotoUrl(r.photo_path));
    } catch (e) { setErr(errorMessage(e)); setD(null); }
  }, [code]);
  useEffect(() => { load(); }, [load]);

  const markFound = async (condition: 'good' | 'damaged') => {
    setBusy(true);
    try {
      await rpc('ast_audit_scan', { p_audit_id: d.open_audit.id, p_code: d.asset_number, p_condition: condition });
      toast(condition === 'good' ? 'Ditandai ditemukan di opname' : 'Ditandai rusak, laporan kerusakan dibuat', 'success');
      load();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  return (
    <div className="asset-scan">
      <ScanInput onScan={(c) => navigate(`/aset/${encodeURIComponent(parseAssetCode(c))}`)} placeholder="Scan label QR aset lain" />
      {err && <div className="card empty"><p>{err}</p></div>}
      {!d && !err && <div className="skeleton" style={{ height: 240 }} />}
      {d && (
        <>
          <div className="card asset-scan-card">
            {photo ? <img src={photo} alt="" className="asset-scan-photo" /> : <div className="asset-scan-photo empty-photo">{d.asset_number.split('-')[1]}</div>}
            <div>
              <div className="muted small">{d.asset_number} · {d.category}</div>
              <h2 style={{ margin: '2px 0 6px' }}>{d.name}</h2>
              <div className="small">{d.outlet}{d.location && ` · ${d.location}`}</div>
              {d.pic && <div className="small muted">Penanggung jawab: {d.pic}</div>}
              {(d.brand_model || d.serial_number) && <div className="small muted">{[d.brand_model, d.serial_number && `SN ${d.serial_number}`].filter(Boolean).join(' · ')}</div>}
              {d.next_maintenance && <div className="small" style={{ marginTop: 6 }}>🛠️ {d.next_maintenance.title}: {fmtDate(d.next_maintenance.due)}</div>}
              {d.warranty_until && <div className="small muted">Garansi sampai {fmtDate(d.warranty_until)}</div>}
              {d.status !== 'active' && <span className="badge badge-danger">Sudah dilepas</span>}
            </div>
          </div>

          {d.status === 'active' && (
            <div className="asset-scan-actions">
              <button className="btn-primary" onClick={() => setReport(true)}><Wrench size={18} /> Lapor kerusakan</button>
              {d.open_audit && <>
                <button disabled={busy} onClick={() => markFound('good')}><ClipboardCheck size={18} /> Ada & baik ({d.open_audit.number})</button>
                <button disabled={busy} onClick={() => markFound('damaged')}>Ada tapi rusak</button>
              </>}
              {d.can_view && <Link className="btn" to={`/assets?code=${encodeURIComponent(d.asset_number)}`}><ExternalLink size={18} /> Detail lengkap</Link>}
            </div>
          )}

          <div className="card">
            <h4 style={{ marginTop: 0 }}>Kerusakan yang sedang ditangani</h4>
            {d.repairs.map((r: any) => (
              <div key={r.id} className="asset-plan">
                <div style={{ flex: 1 }}>
                  <div><span className={`badge ${SEVERITY[r.severity]?.[1]}`}>{SEVERITY[r.severity]?.[0]}</span> <span className={`badge ${REPAIR_STATUS[r.status]?.[1]}`}>{REPAIR_STATUS[r.status]?.[0]}</span></div>
                  <div className="small" style={{ marginTop: 4 }}>{r.description}</div>
                  <small className="muted">{r.number} · {r.reported_by ?? '-'} · {formatDateTime(r.reported_at)}</small>
                </div>
              </div>
            ))}
            {!d.repairs.length && <p className="muted small" style={{ margin: 0 }}>Tidak ada laporan kerusakan yang terbuka.</p>}
          </div>
        </>
      )}
      {report && d && <ReportDamageDialog asset={d} onClose={() => setReport(false)} onDone={() => { setReport(false); load(); }} />}
    </div>
  );
}
