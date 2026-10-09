import { useEffect, useState } from 'react';
import { Camera, X } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../../lib/format';
import { REPAIR_STATUS, SEVERITY, UNIT_LABEL, assetPhotoUrl, dayISO, uploadRepairPhoto, type Opt } from '../../lib/assets';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Dialog bersama untuk perawatan & kerusakan aset (dipakai di detail aset, tab Perawatan, dan halaman scan QR)

export function ReportDamageDialog({ asset, onClose, onDone }: { asset: { id: string; asset_number: string; name: string }; onClose: () => void; onDone: () => void }) {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [f, setF] = useState<any>({ severity: 'major', description: '', photo_path: null });
  const [photo, setPhoto] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const pick = async (file: File | undefined) => {
    if (!file) return;
    try {
      const path = await uploadRepairPhoto(profile!.company_id, asset.id, file);
      setF((x: any) => ({ ...x, photo_path: path }));
      setPhoto(URL.createObjectURL(file));
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const save = async () => {
    setBusy(true);
    try {
      const r = await rpc<any>('ast_report_damage', { p: { asset_id: asset.id, ...f } });
      toast(`Laporan ${r.repair_number} terkirim. Tugas perbaikan sudah dibuat.`, 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`Lapor kerusakan · ${asset.asset_number}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy} onClick={save}>{busy ? 'Mengirim…' : 'Kirim laporan'}</button></>}>
      <p className="small muted" style={{ marginTop: 0 }}><b>{asset.name}</b></p>
      <div className="field"><span>Seberapa parah?</span>
        <div className="asset-severity">
          {Object.entries(SEVERITY).map(([k, [label]]) => (
            <button key={k} type="button" className={`asset-sev-opt sev-${k} ${f.severity === k ? 'active' : ''}`} onClick={() => setF({ ...f, severity: k })}>{label}</button>
          ))}
        </div>
      </div>
      <label className="field"><span>Apa yang rusak? *</span>
        <textarea rows={3} value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} placeholder="mis. Kompor kiri tidak mau menyala, bau gas" /></label>
      <div className="asset-photo-row">
        <label className="asset-photo-pick">
          {photo ? <img src={photo} alt="" /> : <span><Camera size={22} /><br />Foto</span>}
          <input type="file" accept="image/*" capture="environment" hidden onChange={(e) => pick(e.target.files?.[0])} />
        </label>
        {f.photo_path && <button type="button" className="btn-sm" onClick={() => { setF({ ...f, photo_path: null }); setPhoto(null); }}><X size={14} /> Hapus foto</button>}
        <small className="muted">Foto membantu teknisi menyiapkan suku cadang.</small>
      </div>
    </Modal>
  );
}

export function PlanDialog({ assetId, initial, users, roles, onClose, onDone }: {
  assetId: string; initial?: any; users: Opt[]; roles: Opt[]; onClose: () => void; onDone: () => void;
}) {
  const { toast } = useFeedback();
  const [f, setF] = useState<any>(() => initial ? { ...initial, checklist_text: (initial.checklist ?? []).join('\n') } : {
    title: '', interval_value: 3, interval_unit: 'month', next_due_date: dayISO(30), lead_days: 3, assignee_user_id: '', assignee_role_id: '',
    checklist_text: '', requires_photo: false, vendor: '', estimated_cost: '', description: '',
  });
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      const { checklist_text, ...rest } = f;
      await rpc('ast_save_plan', { p: { ...rest, asset_id: assetId, interval_value: Number(f.interval_value), lead_days: Number(f.lead_days),
        assignee_user_id: f.assignee_user_id || null, assignee_role_id: f.assignee_role_id || null, estimated_cost: f.estimated_cost || null,
        checklist: String(checklist_text).split('\n').map((x) => x.trim()).filter(Boolean) } });
      toast('Jadwal perawatan disimpan', 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={initial ? `Ubah jadwal · ${initial.title}` : 'Jadwal perawatan baru'} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy} onClick={save}>Simpan</button></>}>
      <label className="field"><span>Perawatan *</span><input value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} placeholder="mis. Service AC, Kuras grease trap, Kalibrasi timbangan" /></label>
      <div className="form-grid" style={{ alignItems: 'start' }}>
        <label className="field"><span>Setiap</span>
          <div className="row" style={{ flexWrap: 'nowrap' }}>
            <input type="number" min={1} max={365} style={{ width: 80 }} value={f.interval_value} onChange={(e) => setF({ ...f, interval_value: e.target.value })} />
            <select value={f.interval_unit} onChange={(e) => setF({ ...f, interval_unit: e.target.value })}>
              {Object.entries(UNIT_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </div></label>
        <label className="field"><span>Jatuh tempo berikutnya</span><input type="date" value={f.next_due_date} onChange={(e) => setF({ ...f, next_due_date: e.target.value })} /></label>
        <label className="field"><span>Tugas dibuat</span>
          <div className="row" style={{ flexWrap: 'nowrap' }}><input type="number" min={0} max={60} style={{ width: 80 }} value={f.lead_days} onChange={(e) => setF({ ...f, lead_days: e.target.value })} /><span className="small muted">hari sebelumnya</span></div></label>
        <label className="field"><span>Dikerjakan oleh</span>
          <select value={f.assignee_user_id || (f.assignee_role_id ? `role:${f.assignee_role_id}` : '')}
            onChange={(e) => { const v = e.target.value; setF({ ...f, assignee_user_id: v.startsWith('role:') ? '' : v, assignee_role_id: v.startsWith('role:') ? v.slice(5) : '' }); }}>
            <option value="">Penanggung jawab aset</option>
            <optgroup label="Orang">{users.map((u) => <option key={u.id} value={u.id}>{u.name}</option>)}</optgroup>
            <optgroup label="Tim / role">{roles.map((r) => <option key={r.id} value={`role:${r.id}`}>Tim {r.name}</option>)}</optgroup>
          </select></label>
        <label className="field"><span>Vendor (opsional)</span><input value={f.vendor ?? ''} onChange={(e) => setF({ ...f, vendor: e.target.value })} /></label>
        <label className="field"><span>Perkiraan biaya</span><MoneyInput value={f.estimated_cost ?? ''} onChange={(v) => setF({ ...f, estimated_cost: v })} /></label>
      </div>
      <label className="field"><span>Checklist (1 baris = 1 langkah)</span><textarea rows={3} value={f.checklist_text} onChange={(e) => setF({ ...f, checklist_text: e.target.value })} placeholder={'Cuci filter\nCek tekanan freon'} /></label>
      <label className="row small"><input type="checkbox" checked={!!f.requires_photo} onChange={(e) => setF({ ...f, requires_photo: e.target.checked })} /> Wajib foto bukti</label>
      {initial && <label className="row small" style={{ marginTop: 6 }}><input type="checkbox" checked={f.is_active !== false} onChange={(e) => setF({ ...f, is_active: e.target.checked })} /> Jadwal aktif</label>}
    </Modal>
  );
}

// riwayat perawatan manual / isi biaya pada riwayat dari tugas
export function LogDialog({ assetId, initial, cashAccounts, onClose, onDone }: {
  assetId: string; initial?: any; cashAccounts: Opt[]; onClose: () => void; onDone: () => void;
}) {
  const { toast } = useFeedback();
  const [f, setF] = useState<any>(() => ({ title: initial?.title ?? '', performed_on: initial?.performed_on ?? todayISO(), vendor: initial?.vendor ?? '',
    cost: initial?.cost ? String(Math.round(Number(initial.cost))) : '', note: initial?.note ?? '', record_journal: !!initial?.journal_id,
    paid_from_account_id: cashAccounts[0]?.id ?? '' }));
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      await rpc('ast_save_log', { p: { ...f, id: initial?.id, asset_id: assetId, cost: Number(f.cost) || 0 } });
      toast('Riwayat perawatan disimpan', 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={initial ? `Riwayat · ${initial.title}` : 'Catat perawatan'} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy} onClick={save}>Simpan</button></>}>
      <label className="field"><span>Pekerjaan *</span><input value={f.title} disabled={!!initial && initial.kind !== 'manual'} onChange={(e) => setF({ ...f, title: e.target.value })} placeholder="mis. Ganti freon" /></label>
      <div className="form-grid" style={{ alignItems: 'start' }}>
        <label className="field"><span>Tanggal</span><input type="date" max={todayISO()} value={f.performed_on} onChange={(e) => setF({ ...f, performed_on: e.target.value })} /></label>
        <label className="field"><span>Vendor / teknisi</span><input value={f.vendor} onChange={(e) => setF({ ...f, vendor: e.target.value })} /></label>
        <label className="field"><span>Biaya</span><MoneyInput value={f.cost} onChange={(v) => setF({ ...f, cost: v })} /></label>
      </div>
      <CostJournal f={f} setF={setF} cashAccounts={cashAccounts} />
      <label className="field"><span>Catatan</span><input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
    </Modal>
  );
}

function CostJournal({ f, setF, cashAccounts }: { f: any; setF: (v: any) => void; cashAccounts: Opt[] }) {
  if (!(Number(f.cost) > 0)) return null;
  return (
    <div className="asset-preview" style={{ display: 'grid', gap: 8 }}>
      <label className="row small"><input type="checkbox" checked={!!f.record_journal} onChange={(e) => setF({ ...f, record_journal: e.target.checked })} />
        Catat ke jurnal (Beban Perbaikan & Perawatan)</label>
      {f.record_journal && (
        <label className="field" style={{ margin: 0 }}><span>Dibayar dari</span>
          <select value={f.paid_from_account_id} onChange={(e) => setF({ ...f, paid_from_account_id: e.target.value })}>
            {cashAccounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select></label>
      )}
      {!f.record_journal && <small className="muted">Biarkan tidak dicentang bila pembayarannya sudah dicatat di menu Keuangan.</small>}
    </div>
  );
}

export function RepairDialog({ repair, cashAccounts, onClose, onDone }: { repair: any; cashAccounts: Opt[]; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const [f, setF] = useState<any>(() => ({ status: repair.status, vendor: repair.vendor ?? '', resolution: repair.resolution ?? '',
    cost: repair.cost ? String(Math.round(Number(repair.cost))) : '', record_journal: !!repair.journal_id, paid_from_account_id: cashAccounts[0]?.id ?? '', cost_date: todayISO() }));
  const [photo, setPhoto] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { assetPhotoUrl(repair.photo_path).then(setPhoto); }, [repair.photo_path]);
  const save = async () => {
    setBusy(true);
    try {
      await rpc('ast_update_repair', { p: { ...f, id: repair.id, cost: Number(f.cost) || 0 } });
      toast('Perbaikan disimpan', 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${repair.repair_number ?? repair.number} · ${repair.asset ?? ''}`} onClose={onClose}
      footer={<><button onClick={onClose}>Tutup</button><button className="btn-primary" disabled={busy} onClick={save}>Simpan</button></>}>
      <div className="row" style={{ marginBottom: 8 }}>
        <span className={`badge ${SEVERITY[repair.severity]?.[1]}`}>{SEVERITY[repair.severity]?.[0]}</span>
        <span className="small muted">dilaporkan {repair.reported_by ?? repair.reported_by_name ?? '-'}{repair.task_number && ` · tugas ${repair.task_number}`}</span>
      </div>
      <p style={{ marginTop: 0, whiteSpace: 'pre-wrap' }}>{repair.description}</p>
      {photo && <img src={photo} alt="" className="asset-repair-photo" />}
      <div className="form-grid" style={{ alignItems: 'start' }}>
        <label className="field"><span>Status</span>
          <select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
            {Object.entries(REPAIR_STATUS).map(([k, [v]]) => <option key={k} value={k}>{v}</option>)}
          </select></label>
        <label className="field"><span>Vendor / teknisi</span><input value={f.vendor} onChange={(e) => setF({ ...f, vendor: e.target.value })} /></label>
        <label className="field"><span>Biaya perbaikan</span><MoneyInput value={f.cost} onChange={(v) => setF({ ...f, cost: v })} /></label>
      </div>
      <label className="field"><span>Tindakan / hasil</span><input value={f.resolution} onChange={(e) => setF({ ...f, resolution: e.target.value })} placeholder="mis. Ganti kapasitor" /></label>
      <CostJournal f={f} setF={setF} cashAccounts={cashAccounts} />
      {['done', 'cancelled'].includes(f.status) && repair.task_number && <p className="small muted">Tugas {repair.task_number} ikut ditutup.</p>}
      {Number(repair.cost) > 0 && <p className="small muted">Biaya tercatat sebelumnya {formatRupiah(repair.cost)}.</p>}
    </Modal>
  );
}
