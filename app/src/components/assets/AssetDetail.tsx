import { useCallback, useEffect, useState } from 'react';
import { ArrowLeftRight, HandCoins, Pencil, Printer, Trash2, Wrench, XCircle } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatRupiah, todayISO } from '../../lib/format';
import { LABEL_SIZES, getLabelSizeKey } from '../../lib/barcode';
import {
  DISPOSAL_TYPE, FUNDING, METHOD_LABEL, REQ_STATUS, assetPhotoUrl, fmtDate, fmtMonth, lifeLabel, printAssetLabels, type AssetOptions,
} from '../../lib/assets';
import AssetForm from './AssetForm';
import AssetMaintenance from './AssetMaintenance';
import { ReportDamageDialog } from './MaintenanceDialogs';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Tab = 'info' | 'depreciation' | 'maintenance' | 'history';

export default function AssetDetail({ id, options, onClose, onChanged }: {
  id: string; options: AssetOptions; onClose: () => void; onChanged: () => void;
}) {
  const { profile } = useAuth();
  const { toast, confirm } = useFeedback();
  const [d, setD] = useState<any | null>(null);
  const [photo, setPhoto] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>('info');
  const [dialog, setDialog] = useState<'edit' | 'transfer' | 'dispose' | 'pay' | 'damage' | null>(null);
  const [mKey, setMKey] = useState(0);

  const load = useCallback(async () => {
    try {
      const r = await rpc<any>('ast_asset_detail', { p_id: id });
      setD(r);
      setPhoto(await assetPhotoUrl(r.photo_path));
    } catch (e) { toast(errorMessage(e), 'error'); onClose(); }
  }, [id, toast, onClose]);
  useEffect(() => { load(); }, [load]);
  const changed = () => { setDialog(null); load(); onChanged(); };

  if (!d) return <Modal large title="Aset" onClose={onClose}><div className="skeleton" style={{ height: 240 }} /></Modal>;
  const active = d.status === 'active';
  const pending = [...d.transfers, ...d.disposals].find((x: any) => x.status === 'pending_approval');
  const manage = options.can_manage && active;
  const unpaid = d.funding === 'payable' ? Number(d.acquisition_cost) - Number(d.paid_amount) : 0;
  const pct = Math.min(100, (Number(d.accumulated_depreciation) / Math.max(1, Number(d.acquisition_cost) - Number(d.residual_value))) * 100);

  const print = async () => {
    try {
      const size = (LABEL_SIZES.find((s) => s.key === getLabelSizeKey('asset', '50x30')) ?? LABEL_SIZES[0]).size;
      await printAssetLabels([{ code: d.asset_number, name: d.name, company: profile!.company_name,
        lines: [[d.outlet_name, d.location].filter(Boolean).join(' · '), d.serial_number ? `SN ${d.serial_number}` : ''] }], size);
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const remove = async () => {
    if (!(await confirm({ title: `Hapus ${d.asset_number}?`, message: 'Untuk aset yang salah input. Jurnal perolehannya ikut dihapus.', danger: true, confirmLabel: 'Hapus' }))) return;
    try { await rpc('ast_delete_asset', { p_id: d.id }); toast('Aset dihapus', 'success'); onChanged(); onClose(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const cancelReq = async (kind: 'transfer' | 'disposal', reqId: string) => {
    if (!(await confirm({ title: 'Batalkan pengajuan?', message: 'Pengajuan ditarik dari menu Persetujuan.', confirmLabel: 'Batalkan pengajuan' }))) return;
    try { await rpc('ast_cancel_request', { p_kind: kind, p_id: reqId }); changed(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <Modal large title={`${d.asset_number} · ${d.name}`} onClose={onClose}
      footer={<>
        <button onClick={print}><Printer size={16} /> Label QR</button>
        {active && <button onClick={() => setDialog('damage')}><Wrench size={16} /> Lapor kerusakan</button>}
        {manage && !pending && <button onClick={() => setDialog('transfer')}><ArrowLeftRight size={16} /> Mutasi</button>}
        {manage && unpaid > 0 && <button onClick={() => setDialog('pay')}><HandCoins size={16} /> Bayar hutang</button>}
        {manage && !pending && <button className="btn-danger" onClick={() => setDialog('dispose')}><XCircle size={16} /> Lepas aset</button>}
        {manage && <button className="btn-primary" onClick={() => setDialog('edit')}><Pencil size={16} /> Ubah</button>}
      </>}>
      <div className="asset-head card">
        {photo ? <img className="asset-head-photo" src={photo} alt="" /> : <div className="asset-head-photo empty-photo">{d.category?.code}</div>}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="row">
            <span className="badge">{d.category?.name}</span>
            {active ? <span className="badge badge-success">Aktif</span> : <span className="badge badge-danger">Sudah dilepas</span>}
            {pending && <span className="badge badge-warning">{pending.number} menunggu persetujuan</span>}
          </div>
          <div className="muted small" style={{ marginTop: 6 }}>{d.outlet_name ?? 'Kantor pusat'}{d.location && ` · ${d.location}`}{d.pic_name && ` · PJ ${d.pic_name}`}</div>
          <div className="asset-values">
            <div><small className="muted">Harga perolehan</small><b>{formatRupiah(d.acquisition_cost)}</b></div>
            <div><small className="muted">Akumulasi penyusutan</small><b>{formatRupiah(d.accumulated_depreciation)}</b></div>
            <div><small className="muted">Nilai buku</small><b className="asset-book">{formatRupiah(d.book_value)}</b></div>
          </div>
          <div className="asset-bar" title={`${Math.round(pct)}% tersusutkan`}><span style={{ width: `${pct}%` }} /></div>
          <small className="muted">{d.months_depreciated} dari {d.useful_life_months} bulan · sisa {lifeLabel(d.remaining_months)}{active && Number(d.monthly_depreciation) > 0 && ` · bulan depan ${formatRupiah(d.monthly_depreciation)}`}</small>
        </div>
      </div>

      <div className="tabs">
        {([['info', 'Info'], ['depreciation', 'Penyusutan'], ['maintenance', 'Perawatan'], ['history', 'Riwayat']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>

      {tab === 'info' && (
        <div className="card">
          <dl className="asset-dl">
            <dt>Tanggal beli</dt><dd>{fmtDate(d.acquisition_date)}</dd>
            <dt>Cara perolehan</dt><dd>{FUNDING[d.funding]?.label}{d.paid_from_account && ` · ${d.paid_from_account}`}</dd>
            {d.funding === 'payable' && <><dt>Hutang</dt><dd>dibayar {formatRupiah(d.paid_amount)} · sisa <b>{formatRupiah(unpaid)}</b></dd></>}
            {d.funding === 'opening' && <><dt>Akumulasi lama</dt><dd>{formatRupiah(d.opening_accumulated)} ({d.opening_months} bulan sebelum SEMAR)</dd></>}
            <dt>Penyusutan</dt><dd>{METHOD_LABEL[d.method]} · {lifeLabel(d.useful_life_months)} · mulai {fmtMonth(d.depreciation_start)}{Number(d.residual_value) > 0 && ` · nilai sisa ${formatRupiah(d.residual_value)}`}</dd>
            <dt>Merek / model</dt><dd>{d.brand_model ?? '-'}</dd>
            <dt>Nomor seri</dt><dd>{d.serial_number ?? '-'}</dd>
            <dt>Supplier</dt><dd>{d.supplier_name ?? '-'}</dd>
            <dt>Garansi</dt><dd>{d.warranty_until ? <>{fmtDate(d.warranty_until)}{d.warranty_until < todayISO() && <span className="badge" style={{ marginLeft: 6 }}>habis</span>}</> : '-'}</dd>
            {d.notes && <><dt>Catatan</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{d.notes}</dd></>}
          </dl>
          {d.payments.length > 0 && (
            <>
              <h4>Pembayaran hutang</h4>
              <table className="table"><tbody>{d.payments.map((p: any, i: number) => (
                <tr key={i}><td>{fmtDate(p.date)}</td><td className="small">{p.account}{p.note && ` · ${p.note}`}</td><td className="right">{formatRupiah(p.amount)}</td></tr>))}</tbody></table>
            </>
          )}
          {manage && !pending && d.depreciation.length === 0 && Number(d.paid_amount) === 0 && (
            <button className="btn-sm asset-link-danger" style={{ marginTop: 12 }} onClick={remove}><Trash2 size={14} /> Hapus (salah input)</button>
          )}
        </div>
      )}

      {tab === 'depreciation' && (
        <div className="grid grid-2 asset-dep-grid">
          <div className="card table-wrap">
            <h4 style={{ marginTop: 0 }}>Sudah dijurnal</h4>
            <table className="table">
              <thead><tr><th>Periode</th><th>Jurnal</th><th className="right">Penyusutan</th></tr></thead>
              <tbody>
                {d.depreciation.map((x: any, i: number) => (
                  <tr key={i}><td>{x.months > 1 ? `${fmtMonth(x.period_from)} – ${fmtMonth(x.period_to)}` : fmtMonth(x.period_to)}{x.months > 1 && <div className="muted small">{x.months} bulan (susulan)</div>}</td>
                    <td className="small">{x.journal_number ?? '-'}</td><td className="right">{formatRupiah(x.amount)}</td></tr>
                ))}
                {Number(d.opening_accumulated) > 0 && <tr><td>Sebelum SEMAR</td><td className="small muted">saldo awal</td><td className="right">{formatRupiah(d.opening_accumulated)}</td></tr>}
                {!d.depreciation.length && !Number(d.opening_accumulated) && <tr><td colSpan={3} className="empty">Belum ada penyusutan. Jalankan di tab Penyusutan halaman Aset.</td></tr>}
              </tbody>
            </table>
          </div>
          <div className="card table-wrap">
            <h4 style={{ marginTop: 0 }}>Proyeksi ke depan</h4>
            <table className="table">
              <thead><tr><th>Tahun</th><th className="right">Penyusutan</th><th className="right">Nilai buku akhir</th></tr></thead>
              <tbody>
                {d.schedule.map((x: any) => <tr key={x.tahun}><td>{x.tahun}</td><td className="right">{formatRupiah(x.penyusutan)}</td><td className="right">{formatRupiah(x.nilai_buku_akhir)}</td></tr>)}
                {!d.schedule.length && <tr><td colSpan={3} className="empty">{active ? 'Sudah habis disusutkan.' : 'Aset sudah dilepas.'}</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === 'maintenance' && <AssetMaintenance asset={d} options={options} refreshKey={mKey} onChanged={() => { load(); onChanged(); }} />}

      {tab === 'history' && (
        <div className="card">
          {[...d.transfers.map((t: any) => ({ ...t, kind: 'transfer' })), ...d.disposals.map((x: any) => ({ ...x, kind: 'disposal' }))]
            .filter((x) => x.status === 'pending_approval').map((x) => (
              <div key={x.id} className="asset-pending">
                <b>{x.number}</b> {x.kind === 'transfer' ? `Mutasi ${x.from} → ${x.to}` : `${DISPOSAL_TYPE[x.type]} · nilai buku ${formatRupiah(x.book_value)}`}
                <span className="badge badge-warning">Menunggu persetujuan</span>
                {(x.mine || options.can_manage) && <button className="btn-sm" onClick={() => cancelReq(x.kind, x.id)}>Batalkan</button>}
              </div>
            ))}
          <ul className="asset-timeline">
            {d.events.map((e: any, i: number) => (
              <li key={i}><div>{e.description}</div><small className="muted">{formatDateTime(e.at)}{e.by && ` · ${e.by}`}</small></li>
            ))}
          </ul>
          {[...d.transfers, ...d.disposals].filter((x: any) => ['rejected', 'cancelled'].includes(x.status)).map((x: any) => (
            <div key={x.id} className="small muted">{x.number}: <span className={`badge ${REQ_STATUS[x.status][1]}`}>{REQ_STATUS[x.status][0]}</span>{x.decision_note && ` · ${x.decision_note}`}</div>
          ))}
        </div>
      )}

      {dialog === 'edit' && <AssetForm initial={d} options={options} onClose={() => setDialog(null)} onSaved={() => { toast('Aset disimpan', 'success'); changed(); }} />}
      {dialog === 'transfer' && <TransferDialog asset={d} options={options} onClose={() => setDialog(null)} onDone={changed} />}
      {dialog === 'dispose' && <DisposeDialog asset={d} options={options} onClose={() => setDialog(null)} onDone={changed} />}
      {dialog === 'damage' && <ReportDamageDialog asset={d} onClose={() => setDialog(null)} onDone={() => { setDialog(null); setTab('maintenance'); setMKey((k) => k + 1); load(); onChanged(); }} />}
      {dialog === 'pay' && <PayDialog asset={d} unpaid={unpaid} options={options} onClose={() => setDialog(null)} onDone={changed} />}
    </Modal>
  );
}

function TransferDialog({ asset, options, onClose, onDone }: { asset: any; options: AssetOptions; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const [f, setF] = useState<any>({ to_outlet_id: asset.outlet_id ?? '', to_location: asset.location ?? '', to_pic_user_id: asset.pic_user_id ?? '', reason: '', transfer_date: todayISO() });
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      const r = await rpc<any>('ast_request_transfer', { p: { asset_id: asset.id, ...f, to_outlet_id: f.to_outlet_id || null, to_pic_user_id: f.to_pic_user_id || null } });
      toast(r.status === 'completed' ? 'Aset dipindahkan' : 'Mutasi diajukan, menunggu persetujuan', 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`Mutasi ${asset.asset_number}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy} onClick={save}>Pindahkan</button></>}>
      <p className="small muted" style={{ marginTop: 0 }}>Sekarang: <b>{asset.outlet_name ?? 'Kantor pusat'}</b>{asset.location && ` · ${asset.location}`}. Bila matriks approval aktif, mutasi menunggu persetujuan dulu.</p>
      <label className="field"><span>Outlet tujuan</span>
        <select value={f.to_outlet_id} onChange={(e) => setF({ ...f, to_outlet_id: e.target.value })}>
          {options.all_outlets && <option value="">Kantor pusat / tanpa outlet</option>}
          {options.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
        </select></label>
      <label className="field"><span>Lokasi baru</span><input value={f.to_location} onChange={(e) => setF({ ...f, to_location: e.target.value })} /></label>
      <label className="field"><span>Penanggung jawab baru</span>
        <select value={f.to_pic_user_id} onChange={(e) => setF({ ...f, to_pic_user_id: e.target.value })}>
          <option value="">-</option>{options.users.map((u) => <option key={u.id} value={u.id}>{u.name}</option>)}
        </select></label>
      <label className="field"><span>Tanggal</span><input type="date" value={f.transfer_date} max={todayISO()} onChange={(e) => setF({ ...f, transfer_date: e.target.value })} /></label>
      <label className="field"><span>Alasan</span><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} placeholder="mis. Outlet baru buka" /></label>
    </Modal>
  );
}

function DisposeDialog({ asset, options, onClose, onDone }: { asset: any; options: AssetOptions; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const [f, setF] = useState<any>({ disposal_type: 'scrapped', proceeds: '', cash_account_id: options.cash_accounts[0]?.id ?? '', reason: '', disposal_date: todayISO() });
  const [busy, setBusy] = useState(false);
  const book = Number(asset.book_value);
  const gl = f.disposal_type === 'sold' ? (Number(f.proceeds) || 0) - book : -book;
  const save = async () => {
    setBusy(true);
    try {
      const r = await rpc<any>('ast_request_disposal', { p: { asset_id: asset.id, ...f, proceeds: f.disposal_type === 'sold' ? Number(f.proceeds) || 0 : 0 } });
      toast(r.status === 'completed' ? 'Aset dilepas & dijurnal' : 'Pelepasan diajukan, menunggu persetujuan', 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`Lepas ${asset.asset_number}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-danger" disabled={busy} onClick={save}>Lepas aset</button></>}>
      <p className="small muted" style={{ marginTop: 0 }}>Jalankan penyusutan sampai bulan lalu dulu supaya nilai bukunya tepat. Nilai buku sekarang <b>{formatRupiah(book)}</b>.</p>
      <label className="field"><span>Jenis</span>
        <select value={f.disposal_type} onChange={(e) => setF({ ...f, disposal_type: e.target.value })}>
          {Object.entries(DISPOSAL_TYPE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select></label>
      {f.disposal_type === 'sold' && (
        <div className="form-grid">
          <label className="field"><span>Harga jual</span><MoneyInput value={f.proceeds} onChange={(v) => setF({ ...f, proceeds: v })} /></label>
          <label className="field"><span>Uang masuk ke</span>
            <select value={f.cash_account_id} onChange={(e) => setF({ ...f, cash_account_id: e.target.value })}>
              {options.cash_accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select></label>
        </div>
      )}
      <label className="field"><span>Tanggal</span><input type="date" value={f.disposal_date} max={todayISO()} onChange={(e) => setF({ ...f, disposal_date: e.target.value })} /></label>
      <label className="field"><span>Alasan *</span><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} placeholder="mis. Rusak tidak bisa diperbaiki" /></label>
      <div className={`asset-preview ${gl < 0 ? 'loss' : ''}`}>{gl === 0 ? 'Tidak ada laba / rugi.' : gl > 0 ? <>Laba pelepasan <b>{formatRupiah(gl)}</b></> : <>Rugi pelepasan <b>{formatRupiah(-gl)}</b></>}</div>
    </Modal>
  );
}

function PayDialog({ asset, unpaid, options, onClose, onDone }: { asset: any; unpaid: number; options: AssetOptions; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const [f, setF] = useState<any>({ amount: String(unpaid), account_id: options.cash_accounts.find((a) => a.key === 'bank')?.id ?? options.cash_accounts[0]?.id ?? '', date: todayISO(), note: '' });
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      await rpc('ast_record_payment', { p_asset_id: asset.id, p_account_id: f.account_id, p_amount: Number(f.amount), p_date: f.date, p_note: f.note });
      toast('Pembayaran dicatat', 'success');
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  return (
    <Modal title={`Bayar hutang ${asset.asset_number}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy} onClick={save}>Simpan pembayaran</button></>}>
      <p className="small muted" style={{ marginTop: 0 }}>Sisa hutang {formatRupiah(unpaid)}.</p>
      <div className="form-grid">
        <label className="field"><span>Nominal</span><MoneyInput value={f.amount} onChange={(v) => setF({ ...f, amount: v })} /></label>
        <label className="field"><span>Dibayar dari</span>
          <select value={f.account_id} onChange={(e) => setF({ ...f, account_id: e.target.value })}>
            {options.cash_accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select></label>
        <label className="field"><span>Tanggal</span><input type="date" value={f.date} max={todayISO()} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
      </div>
      <label className="field"><span>Catatan</span><input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></label>
    </Modal>
  );
}
