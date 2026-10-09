import { useCallback, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { CalendarCheck, Plus, Printer, Search, Undo2 } from 'lucide-react';
import Modal from '../components/Modal';
import MoneyInput from '../components/MoneyInput';
import ScanInput from '../components/ScanInput';
import { useFeedback } from '../components/Feedback';
import { useAuth } from '../context/AuthContext';
import { rpc } from '../lib/supabase';
import { errorMessage, formatDateTime, formatRupiah } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import { LABEL_SIZES, getLabelSizeKey, setLabelSizeKey } from '../lib/barcode';
import { METHOD_LABEL, REQ_STATUS, fmtDate, fmtMonth, lifeLabel, monthISO, printAssetLabels, type AssetOptions } from '../lib/assets';
import AssetForm from '../components/assets/AssetForm';
import AssetDetail from '../components/assets/AssetDetail';
import '../styles/assets.css';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Tab = 'list' | 'depreciation' | 'requests' | 'categories';

// Aset tetap: daftar & nilai buku, penyusutan bulanan, mutasi & pelepasan, kategori.
export default function AssetsPage() {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [tab, setTab] = useTabParam<Tab>('list', ['list', 'depreciation', 'requests', 'categories']);
  const [params, setParams] = useSearchParams();
  const [options, setOptions] = useState<AssetOptions | null>(null);
  const [summary, setSummary] = useState<any | null>(null);
  const [rows, setRows] = useState<any[]>([]);
  const [status, setStatus] = useState<'active' | 'disposed' | 'all'>('active');
  const [q, setQ] = useState('');
  const [cat, setCat] = useState('');
  const [outlet, setOutlet] = useState('');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [creating, setCreating] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);

  const loadOptions = useCallback(async () => {
    await rpc('ast_setup');
    setOptions(await rpc<AssetOptions>('ast_options'));
  }, []);
  const loadList = useCallback(async () => {
    const [list, s] = await Promise.all([rpc<any[]>('ast_list', { p_status: status }), rpc<any>('ast_summary')]);
    setRows(list); setSummary(s);
  }, [status]);
  useEffect(() => { loadOptions().catch((e) => toast(errorMessage(e), 'error')); }, [loadOptions, toast]);
  useEffect(() => { loadList().catch((e) => toast(errorMessage(e), 'error')); }, [loadList, toast]);

  // dibuka dari scan QR label: /assets?code=AST-DPR-0001
  const openCode = useCallback(async (code: string) => {
    try {
      const id = await rpc<string | null>('ast_find_by_code', { p_code: code });
      if (id) setOpenId(id); else toast(`Aset ${code} tidak ditemukan`, 'error');
    } catch (e) { toast(errorMessage(e), 'error'); }
  }, [toast]);
  useEffect(() => {
    const code = params.get('code');
    if (!code) return;
    openCode(code);
    setParams((p) => { const n = new URLSearchParams(p); n.delete('code'); return n; }, { replace: true });
  }, [params, setParams, openCode]);

  const filtered = useMemo(() => {
    const s = q.trim().toLowerCase();
    return rows.filter((r) => (!cat || r.category_id === cat) && (!outlet || (outlet === '-' ? !r.outlet_id : r.outlet_id === outlet))
      && (!s || [r.asset_number, r.name, r.serial_number, r.brand_model, r.location, r.pic].some((x) => x && String(x).toLowerCase().includes(s))));
  }, [rows, q, cat, outlet]);

  const printSelected = async () => {
    try {
      const size = (LABEL_SIZES.find((s) => s.key === getLabelSizeKey('asset', '50x30')) ?? LABEL_SIZES[0]).size;
      await printAssetLabels(filtered.filter((r) => selected.has(r.id)).map((r) => ({ code: r.asset_number, name: r.name, company: profile!.company_name,
        lines: [[r.outlet, r.location].filter(Boolean).join(' · '), r.serial_number ? `SN ${r.serial_number}` : ''] })), size);
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const toggle = (id: string) => setSelected((p) => { const n = new Set(p); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  if (!options) return <div className="skeleton" style={{ height: 240 }} />;
  return (
    <>
      <div className="page-header">
        <div><h1>Aset</h1><p>Peralatan, mesin, furnitur & kendaraan beserta penyusutannya.</p></div>
        {options.can_manage && tab === 'list' && <button className="btn-primary" onClick={() => setCreating(true)}><Plus size={16} /> Aset baru</button>}
      </div>
      <div className="tabs">
        {([['list', 'Daftar aset'], ['depreciation', 'Penyusutan'], ['requests', 'Mutasi & pelepasan'], ['categories', 'Kategori & pengaturan']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}
            {k === 'requests' && summary?.pengajuan_menunggu > 0 && <span className="badge badge-warning" style={{ marginLeft: 6 }}>{summary.pengajuan_menunggu}</span>}
            {k === 'depreciation' && summary?.perlu_disusutkan > 0 && <span className="badge badge-warning" style={{ marginLeft: 6 }}>!</span>}
          </button>
        ))}
      </div>

      {tab === 'list' && (
        <>
          {summary && (
            <div className="grid grid-4 asset-stats">
              <div className="card stat-card"><div className="stat-label">Aset aktif</div><div className="stat-value">{summary.aktif}</div></div>
              <div className="card stat-card" style={{ ['--stat-color' as string]: 'var(--sunshine)' }}><div className="stat-label">Harga perolehan</div><div className="stat-value">{formatRupiah(summary.harga_perolehan)}</div></div>
              <div className="card stat-card" style={{ ['--stat-color' as string]: 'var(--vermillion)' }}><div className="stat-label">Akumulasi penyusutan</div><div className="stat-value">{formatRupiah(summary.akumulasi)}</div></div>
              <div className="card stat-card"><div className="stat-label">Nilai buku</div><div className="stat-value">{formatRupiah(summary.nilai_buku)}</div></div>
            </div>
          )}
          {summary && (summary.perlu_disusutkan > 0 || summary.garansi_habis_30_hari.length > 0 || Number(summary.hutang_aset) > 0) && (
            <div className="card asset-alerts">
              {summary.perlu_disusutkan > 0 && <div>📅 {summary.perlu_disusutkan} aset belum disusutkan sampai {fmtMonth(monthISO(-1))}. <button className="btn-sm" onClick={() => setTab('depreciation')}>Jalankan penyusutan</button></div>}
              {summary.garansi_habis_30_hari.map((g: any) => <div key={g.id}>🛡️ Garansi <button className="asset-link" onClick={() => setOpenId(g.id)}>{g.kode} {g.nama}</button> habis {fmtDate(g.garansi)}</div>)}
              {Number(summary.hutang_aset) > 0 && <div>💳 Hutang pembelian aset belum dibayar {formatRupiah(summary.hutang_aset)}</div>}
            </div>
          )}
          <div className="card">
            <div className="asset-toolbar">
              <label className="task-search"><Search size={14} /><input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Cari kode, nama, nomor seri, lokasi…" /></label>
              <ScanInput onScan={openCode} placeholder="Scan label QR / kode aset" style={{ minWidth: 220 }} />
              <select value={cat} onChange={(e) => setCat(e.target.value)}>
                <option value="">Semua kategori</option>{options.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
              <select value={outlet} onChange={(e) => setOutlet(e.target.value)}>
                <option value="">Semua outlet</option>{options.all_outlets && <option value="-">Kantor pusat</option>}
                {options.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
              </select>
              <select value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
                <option value="active">Aktif</option><option value="disposed">Sudah dilepas</option><option value="all">Semua</option>
              </select>
              {selected.size > 0 && <button onClick={printSelected}><Printer size={16} /> Cetak {selected.size} label</button>}
            </div>
            <div className="table-wrap">
              <table className="table asset-table">
                <thead><tr>
                  <th style={{ width: 28 }}><input type="checkbox" checked={filtered.length > 0 && filtered.every((r) => selected.has(r.id))}
                    onChange={(e) => setSelected(e.target.checked ? new Set(filtered.map((r) => r.id)) : new Set())} /></th>
                  <th>Aset</th><th>Kategori</th><th>Lokasi</th><th>Dibeli</th><th className="right">Harga</th><th className="right">Nilai buku</th><th>Umur</th>
                </tr></thead>
                <tbody>
                  {filtered.map((r) => {
                    const pct = Math.min(100, (r.months_depreciated / Math.max(1, r.useful_life_months)) * 100);
                    return (
                      <tr key={r.id} className="clickable-row" onClick={() => setOpenId(r.id)}>
                        <td onClick={(e) => e.stopPropagation()}><input type="checkbox" checked={selected.has(r.id)} onChange={() => toggle(r.id)} /></td>
                        <td><b>{r.name}</b><div className="muted small">{r.asset_number}{r.serial_number && ` · SN ${r.serial_number}`}</div>
                          {r.status === 'disposed' && <span className="badge badge-danger">Dilepas</span>}{r.pending && <span className="badge badge-warning">Menunggu persetujuan</span>}</td>
                        <td className="small">{r.category}</td>
                        <td className="small">{r.outlet ?? 'Kantor pusat'}{r.location && <div className="muted">{r.location}</div>}{r.pic && <div className="muted">PJ {r.pic}</div>}</td>
                        <td className="small">{fmtDate(r.acquisition_date)}</td>
                        <td className="right">{formatRupiah(r.acquisition_cost)}</td>
                        <td className="right"><b>{formatRupiah(r.book_value)}</b></td>
                        <td style={{ minWidth: 110 }}><div className="asset-bar small-bar"><span style={{ width: `${pct}%` }} /></div>
                          <small className="muted">{r.months_depreciated}/{r.useful_life_months} bln</small></td>
                      </tr>
                    );
                  })}
                  {!filtered.length && <tr><td colSpan={8} className="empty">{rows.length ? 'Tidak ada aset yang cocok.' : <>Belum ada aset. {options.can_manage && <>Klik <b>Aset baru</b> untuk mulai mencatat.</>}<br /><small>Barang di bawah {formatRupiah(options.settings?.capitalization_threshold)} dicatat sebagai biaya, bukan aset.</small></>}</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {tab === 'depreciation' && <DepreciationTab options={options} onChanged={loadList} />}
      {tab === 'requests' && <RequestsTab onOpen={setOpenId} />}
      {tab === 'categories' && <CategoriesTab options={options} onChanged={loadOptions} />}

      {creating && <AssetForm initial={null} options={options} onClose={() => setCreating(false)}
        onSaved={(a) => { toast(`${a.asset_number} disimpan`, 'success'); setCreating(false); loadList(); setOpenId(a.id); }} />}
      {openId && <AssetDetail id={openId} options={options} onClose={() => setOpenId(null)} onChanged={loadList} />}
    </>
  );
}

function DepreciationTab({ options, onChanged }: { options: AssetOptions; onChanged: () => void }) {
  const { toast, confirm } = useFeedback();
  const [period, setPeriod] = useState(monthISO(-1));
  const [pv, setPv] = useState<any | null>(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => setPv(await rpc<any>('ast_depreciation_preview', { p_period: period })), [period]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);
  const total = (pv?.items ?? []).reduce((s: number, x: any) => s + Number(x.amount), 0);

  const run = async () => {
    if (!(await confirm({ title: `Jurnal penyusutan ${fmtMonth(period)}?`, message: `${pv.items.length} aset, total ${formatRupiah(total)}. Jurnal dibuat per outlet.`, confirmLabel: 'Jalankan' }))) return;
    setBusy(true);
    try { const r = await rpc<any>('ast_run_depreciation', { p_period: period }); toast(`Penyusutan ${fmtMonth(r.period)}: ${r.assets} aset, ${formatRupiah(r.total)}`, 'success'); load(); onChanged(); }
    catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  const undo = async () => {
    if (!(await confirm({ title: `Batalkan penyusutan ${fmtMonth(pv.last_period)}?`, message: 'Jurnal penyusutan bulan itu dihapus dan akumulasi aset dikembalikan.', danger: true, confirmLabel: 'Batalkan' }))) return;
    try { await rpc('ast_void_depreciation', { p_period: pv.last_period }); toast('Penyusutan dibatalkan', 'success'); load(); onChanged(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <div className="card">
      <div className="asset-toolbar">
        <label className="field" style={{ margin: 0 }}><span>Susutkan sampai bulan</span>
          <input type="month" value={period.slice(0, 7)} max={monthISO(0).slice(0, 7)} onChange={(e) => e.target.value && setPeriod(`${e.target.value}-01`)} /></label>
        <div style={{ flex: 1 }} />
        {pv?.last_period && <span className="small muted">Terakhir dijalankan: <b>{fmtMonth(pv.last_period)}</b></span>}
        {options.can_depreciate && pv?.last_period && <button onClick={undo}><Undo2 size={16} /> Batalkan {fmtMonth(pv.last_period)}</button>}
        {options.can_depreciate && <button className="btn-primary" disabled={busy || !pv?.items.length} onClick={run}><CalendarCheck size={16} /> Jalankan penyusutan</button>}
      </div>
      {!options.can_depreciate && <p className="small muted">Penyusutan dijalankan oleh user dengan izin kelola aset / keuangan dan akses semua outlet.</p>}
      <p className="small muted">Jalankan setiap awal bulan untuk bulan sebelumnya. Aset yang tertinggal beberapa bulan otomatis disusulkan. Jurnal: <b>Beban Penyusutan</b> (debit) / <b>Akumulasi Penyusutan</b> (kredit).</p>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>Aset</th><th>Outlet</th><th>Bulan</th><th className="right">Penyusutan</th><th className="right">Nilai buku setelahnya</th></tr></thead>
          <tbody>
            {(pv?.items ?? []).map((x: any) => (
              <tr key={x.asset_id}><td><b>{x.name}</b><div className="muted small">{x.asset_number} · {x.category}</div></td><td className="small">{x.outlet ?? 'Kantor pusat'}</td>
                <td className="small">{x.months > 1 ? `${fmtMonth(x.period_from)} – ${fmtMonth(period)} (${x.months} bln)` : fmtMonth(period)}</td>
                <td className="right">{formatRupiah(x.amount)}</td><td className="right">{formatRupiah(x.book_value_after)}</td></tr>
            ))}
            {pv && !pv.items.length && <tr><td colSpan={5} className="empty">Tidak ada aset yang perlu disusutkan sampai {fmtMonth(period)}.</td></tr>}
          </tbody>
          {total > 0 && <tfoot><tr><td colSpan={3} className="right bold">Total</td><td className="right bold">{formatRupiah(total)}</td><td /></tr></tfoot>}
        </table>
      </div>
    </div>
  );
}

function RequestsTab({ onOpen }: { onOpen: (id: string) => void }) {
  const { toast } = useFeedback();
  const [status, setStatus] = useState('pending_approval');
  const [rows, setRows] = useState<any[] | null>(null);
  useEffect(() => { rpc<any[]>('ast_requests', { p_status: status }).then(setRows).catch((e) => toast(errorMessage(e), 'error')); }, [status, toast]);
  return (
    <div className="card">
      <div className="asset-toolbar">
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="pending_approval">Menunggu persetujuan</option><option value="all">Semua</option>
        </select>
        <span className="small muted">Persetujuan diputuskan di menu <b>Persetujuan</b>.</span>
      </div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>Nomor</th><th>Aset</th><th>Detail</th><th>Diajukan</th><th>Status</th></tr></thead>
          <tbody>
            {(rows ?? []).map((r) => (
              <tr key={r.id} className="clickable-row" onClick={() => onOpen(r.asset_id)}>
                <td><b className="small">{r.number}</b><div className="muted small">{r.kind === 'transfer' ? 'Mutasi' : 'Pelepasan'} · {fmtDate(r.date)}</div></td>
                <td><b>{r.asset}</b><div className="muted small">{r.asset_number}</div></td>
                <td className="small">{r.detail}{r.reason && <div className="muted">{r.reason}</div>}</td>
                <td className="small">{r.requested_by ?? '-'}<div className="muted">{formatDateTime(r.created_at)}</div></td>
                <td><span className={`badge ${REQ_STATUS[r.status]?.[1] ?? ''}`}>{REQ_STATUS[r.status]?.[0] ?? r.status}</span>{r.decision_note && <div className="small muted">{r.decision_note}</div>}</td>
              </tr>
            ))}
            {rows && !rows.length && <tr><td colSpan={5} className="empty">Tidak ada pengajuan.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function CategoriesTab({ options, onChanged }: { options: AssetOptions; onChanged: () => Promise<void> }) {
  const { toast } = useFeedback();
  const [edit, setEdit] = useState<any | null>(null);
  const [threshold, setThreshold] = useState(String(options.settings?.capitalization_threshold ?? 1000000));
  const [labelSize, setLabelSize] = useState(getLabelSizeKey('asset', '50x30'));
  const assetAcc = options.accounts.filter((a) => a.type === 'asset');
  const expAcc = options.accounts.filter((a) => a.type !== 'asset');
  const accName = (id: string) => options.accounts.find((a) => a.id === id)?.name ?? '-';

  const saveCat = async () => {
    try { await rpc('ast_save_category', { p: { ...edit, useful_life_months: Number(edit.useful_life_months) } }); setEdit(null); await onChanged(); toast('Kategori disimpan', 'success'); }
    catch (e) { toast(errorMessage(e), 'error'); }
  };
  const saveThreshold = async () => {
    try { await rpc('ast_save_settings', { p_threshold: Number(threshold) || 0 }); await onChanged(); toast('Batas nilai aset disimpan', 'success'); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const newCat = () => {
    const ref = options.categories[0];
    setEdit({ code: '', name: '', useful_life_months: 48, method: 'straight_line', asset_account_id: ref?.asset_account_id, accum_account_id: ref?.accum_account_id, expense_account_id: ref?.expense_account_id, is_active: true });
  };

  return (
    <>
      <div className="card">
        <h3 style={{ marginTop: 0 }}>Pengaturan</h3>
        <div className="form-grid" style={{ alignItems: 'start' }}>
          <label className="field"><span>Batas nilai aset</span><MoneyInput disabled={!options.can_manage} value={threshold} onChange={setThreshold} />
            <small className="muted">Barang di bawah ini dicatat sebagai biaya / perlengkapan, tidak disusutkan</small></label>
          <label className="field"><span>Ukuran label QR (perangkat ini)</span>
            <select value={labelSize} onChange={(e) => { setLabelSize(e.target.value); setLabelSizeKey('asset', e.target.value); }}>
              {LABEL_SIZES.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
            </select></label>
        </div>
        {options.can_manage && <button className="btn-primary" style={{ marginTop: 12 }} onClick={saveThreshold}>Simpan pengaturan</button>}
      </div>
      <div className="card table-wrap">
        <div className="card-header"><h3 style={{ margin: 0 }}>Kategori aset</h3>{options.can_manage && <button className="btn-sm" onClick={newCat}><Plus size={14} /> Kategori</button>}</div>
        <table className="table">
          <thead><tr><th>Kode</th><th>Kategori</th><th>Umur</th><th>Metode</th><th>Akun aset</th><th>Akun beban</th></tr></thead>
          <tbody>
            {options.categories.map((c) => (
              <tr key={c.id} className={options.can_manage ? 'clickable-row' : ''} onClick={() => options.can_manage && setEdit({ ...c })}>
                <td><b>{c.code}</b></td><td>{c.name}{!c.is_active && <span className="badge" style={{ marginLeft: 6 }}>nonaktif</span>}{c.description && <div className="muted small">{c.description}</div>}</td>
                <td>{lifeLabel(c.useful_life_months)}</td><td className="small">{METHOD_LABEL[c.method]}</td>
                <td className="small">{accName(c.asset_account_id)}</td><td className="small">{accName(c.expense_account_id)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {edit && (
        <Modal title={edit.id ? `Ubah kategori ${edit.code}` : 'Kategori baru'} onClose={() => setEdit(null)}
          footer={<><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={saveCat}>Simpan</button></>}>
          <div className="form-grid" style={{ alignItems: 'start' }}>
            <label className="field"><span>Kode (2-6 huruf)</span><input value={edit.code} maxLength={6} onChange={(e) => setEdit({ ...edit, code: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '') })} /></label>
            <label className="field"><span>Nama</span><input value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
            <label className="field"><span>Umur manfaat (bulan)</span><input type="number" min={1} max={600} value={edit.useful_life_months} onChange={(e) => setEdit({ ...edit, useful_life_months: e.target.value })} />
              <small className="muted">Pajak: kelompok 1 = 48, kelompok 2 = 96, bangunan = 240</small></label>
            <label className="field"><span>Metode</span>
              <select value={edit.method} onChange={(e) => setEdit({ ...edit, method: e.target.value })}>
                <option value="straight_line">Garis lurus</option><option value="declining_balance">Saldo menurun</option>
              </select></label>
            <label className="field"><span>Akun aset</span><select value={edit.asset_account_id ?? ''} onChange={(e) => setEdit({ ...edit, asset_account_id: e.target.value })}>{assetAcc.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            <label className="field"><span>Akun akumulasi penyusutan</span><select value={edit.accum_account_id ?? ''} onChange={(e) => setEdit({ ...edit, accum_account_id: e.target.value })}>{assetAcc.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            <label className="field"><span>Akun beban penyusutan</span><select value={edit.expense_account_id ?? ''} onChange={(e) => setEdit({ ...edit, expense_account_id: e.target.value })}>{expAcc.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            {edit.id && <label className="field"><span>Status</span><select value={edit.is_active ? '1' : '0'} onChange={(e) => setEdit({ ...edit, is_active: e.target.value === '1' })}><option value="1">Aktif</option><option value="0">Nonaktif</option></select></label>}
          </div>
          <label className="field"><span>Keterangan</span><input value={edit.description ?? ''} onChange={(e) => setEdit({ ...edit, description: e.target.value })} /></label>
        </Modal>
      )}
    </>
  );
}
