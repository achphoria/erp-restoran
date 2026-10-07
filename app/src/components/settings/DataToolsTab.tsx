import { useRef, useState } from 'react';
import { AlertTriangle, DatabaseBackup, Download, FlaskConical, RotateCcw, Upload } from 'lucide-react';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatNumber, todayISO } from '../../lib/format';

interface Backup { format: string; company_id: string; company_name: string; exported_at: string; exported_by: string | null; tables: Record<string, unknown[]> }

const addDays = (iso: string, n: number) => {
  const d = new Date(`${iso}T00:00:00`);
  d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};
const rowCount = (b: Backup) => Object.values(b.tables).reduce((s, rows) => s + rows.length, 0);
const LABELS: Record<string, string> = {
  pos_orders: 'Order POS', inv_items: 'Produk', mst_menu_items: 'Menu', fin_journals: 'Jurnal', pur_goods_receipts: 'Penerimaan',
  sal_invoices: 'Sales invoice', inv_stock_batches: 'Batch stok', crm_customers: 'Member',
};

// Pengaturan -> Data & Backup (khusus owner): data contoh, backup, restore, reset
export default function DataToolsTab() {
  const { profile } = useAuth();
  const { toast, confirm, prompt } = useFeedback();
  const company = profile!.company_name;
  const [outletId, setOutletId] = useState(profile?.outlets[0]?.id ?? '');
  const [days, setDays] = useState(14);
  const [perDay, setPerDay] = useState(20);
  const [progress, setProgress] = useState<{ done: number; total: number; label: string } | null>(null);
  const [restoreFile, setRestoreFile] = useState<Backup | null>(null);
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const askCompany = (title: string) =>
    prompt({ title, label: `Ketik nama perusahaan "${company}" untuk konfirmasi`, placeholder: company, required: true, confirmLabel: 'Lanjutkan' });

  // ---------- data contoh (per hari supaya tidak timeout & ada progres)
  const seed = async () => {
    if (!(await confirm({ title: 'Buat data contoh?', confirmLabel: 'Buat',
      message: `Sistem membuat pembelian, ${days} hari penjualan POS (±${perDay} order/hari), waste, biaya, Sales Order B2B & settlement di outlet terpilih. Data contoh bercampur dengan data asli; buat backup dulu bila perlu.` }))) return;
    setBusy(true);
    let orders = 0;
    try {
      const start = addDays(todayISO(), -(days - 1));
      setProgress({ done: 0, total: days + 2, label: 'Menyiapkan…' });
      const prep = await rpc<{ shift_id: string; shift_opened: boolean }>('sys_seed_demo_prepare', { p_outlet_id: outletId, p_start_date: start });
      for (let i = 0; i < days; i++) {
        const date = addDays(start, i);
        setProgress({ done: i + 1, total: days + 2, label: `Transaksi ${date}` });
        const r = await rpc<{ orders: number }>('sys_seed_demo_day', {
          p_outlet_id: outletId, p_date: date, p_orders: Math.max(1, Math.round(perDay * (0.7 + Math.random() * 0.6))), p_purchase: i % 4 === 0,
        });
        orders += r.orders;
      }
      setProgress({ done: days + 1, total: days + 2, label: 'Sales order B2B & settlement…' });
      const fin = await rpc<{ settlements: number }>('sys_seed_demo_finish', { p_outlet_id: outletId, p_shift_id: prep.shift_id, p_close_shift: prep.shift_opened });
      toast(`Data contoh selesai: ${formatNumber(orders)} order POS, ${fin.settlements} settlement.`);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setProgress(null);
      setBusy(false);
    }
  };

  // ---------- backup
  const downloadBackup = async () => {
    setBusy(true);
    try {
      const data = await rpc<Backup>('sys_export_company_data');
      const blob = new Blob([JSON.stringify(data)], { type: 'application/json' });
      const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `santap-backup-${company.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${stamp}.json`;
      a.click();
      URL.revokeObjectURL(a.href);
      toast(`Backup diunduh (${formatNumber(rowCount(data))} baris data)`);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  // ---------- restore
  const pickFile = async (f?: File) => {
    if (!f) return;
    try {
      const data = JSON.parse(await f.text()) as Backup;
      if (data.format !== 'santap-backup' || !data.tables) throw new Error('File bukan backup Santap ERP');
      if (data.company_id !== profile!.company_id) throw new Error(`Backup ini milik "${data.company_name}". Restore hanya untuk perusahaan yang sama.`);
      setRestoreFile(data);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      if (fileRef.current) fileRef.current.value = '';
    }
  };
  const restore = async () => {
    const typed = await askCompany('Restore backup?');
    if (!typed) return;
    setBusy(true);
    try {
      await rpc('sys_import_company_data', { p_backup: restoreFile, p_confirm: typed });
      toast('Restore selesai. Halaman dimuat ulang…');
      setTimeout(() => window.location.reload(), 1200);
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  // ---------- reset
  const reset = async (scope: 'transactions' | 'all') => {
    if (!(await confirm({ title: scope === 'all' ? 'Reset total?' : 'Hapus semua transaksi?', danger: true, confirmLabel: 'Saya mengerti',
      message: scope === 'all'
        ? 'Semua master (produk, menu, resep, supplier, pelanggan, promo, pricelist) DAN semua transaksi dihapus permanen. Perusahaan, outlet, gudang, user, role, COA, metode bayar & pengaturan tetap.'
        : 'Semua transaksi (order, pembelian, stok, batch, jurnal, sales order, invoice, settlement, log) dihapus permanen. Master data tetap. Stok kembali nol & nomor dokumen mulai dari awal.' }))) return;
    const typed = await askCompany(scope === 'all' ? 'Reset total' : 'Hapus semua transaksi');
    if (!typed) return;
    setBusy(true);
    try {
      await rpc('sys_reset_company_data', { p_scope: scope, p_confirm: typed });
      toast('Data direset. Halaman dimuat ulang…');
      setTimeout(() => window.location.reload(), 1200);
    } catch (e) {
      toast(errorMessage(e), 'error');
      setBusy(false);
    }
  };

  return (
    <div className="grid grid-2">
      <div className="card">
        <div className="card-header"><h3><FlaskConical size={17} style={{ verticalAlign: -3 }} /> Data contoh</h3></div>
        <p className="muted small" style={{ marginTop: 0 }}>Isi transaksi contoh supaya ada gambaran laporan, stok, batch, jurnal & settlement. Memakai menu, resep & produk yang sudah ada.</p>
        <div className="form-grid">
          <label className="field"><span>Outlet</span>
            <select value={outletId} onChange={(e) => setOutletId(e.target.value)}>{profile?.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
          <label className="field"><span>Jumlah hari ke belakang</span>
            <select value={days} onChange={(e) => setDays(Number(e.target.value))}>{[7, 14, 30].map((d) => <option key={d} value={d}>{d} hari</option>)}</select></label>
          <label className="field"><span>Order per hari (±)</span>
            <select value={perDay} onChange={(e) => setPerDay(Number(e.target.value))}>{[10, 20, 40].map((d) => <option key={d} value={d}>{d} order</option>)}</select></label>
        </div>
        {progress && (
          <div style={{ marginTop: 12 }}>
            <div className="progress"><div style={{ width: `${(progress.done / progress.total) * 100}%` }} /></div>
            <div className="muted small">{progress.label}</div>
          </div>
        )}
        <button className="btn-primary" style={{ marginTop: 12 }} disabled={busy || !outletId} onClick={seed}><FlaskConical size={16} /> Buat data contoh</button>
      </div>

      <div className="card">
        <div className="card-header"><h3><DatabaseBackup size={17} style={{ verticalAlign: -3 }} /> Backup & restore</h3></div>
        <p className="muted small" style={{ marginTop: 0 }}>Backup menyimpan semua data perusahaan ke 1 file .json (kecuali password & merchant key). Simpan di tempat aman.</p>
        <button className="btn-primary" disabled={busy} onClick={downloadBackup}><Download size={16} /> Download backup</button>
        <div className="section-title">Restore dari file</div>
        <input ref={fileRef} type="file" accept="application/json,.json" hidden onChange={(e) => pickFile(e.target.files?.[0])} />
        {!restoreFile ? (
          <button disabled={busy} onClick={() => fileRef.current?.click()}><Upload size={16} /> Pilih file backup…</button>
        ) : (
          <div className="restore-box">
            <div><b>{restoreFile.company_name}</b> · {new Date(restoreFile.exported_at).toLocaleString('id-ID')}{restoreFile.exported_by ? ` · oleh ${restoreFile.exported_by}` : ''}</div>
            <div className="chip-list" style={{ marginTop: 6 }}>
              {Object.entries(LABELS).map(([k, v]) => <span key={k} className="badge">{v}: {formatNumber(restoreFile.tables[k]?.length ?? 0)}</span>)}
            </div>
            <div className="alert alert-error small" style={{ marginTop: 8 }}>Semua master & transaksi saat ini akan <b>diganti</b> isi backup ini.</div>
            <div className="row">
              <button onClick={() => setRestoreFile(null)} disabled={busy}>Batal</button>
              <button className="btn-danger-solid" disabled={busy} onClick={restore}><RotateCcw size={16} /> Restore sekarang</button>
            </div>
          </div>
        )}
      </div>

      <div className="card danger-zone" style={{ gridColumn: '1 / -1' }}>
        <div className="card-header"><h3><AlertTriangle size={17} style={{ verticalAlign: -3 }} /> Reset data</h3></div>
        <p className="muted small" style={{ marginTop: 0 }}>Tidak bisa dibatalkan. <b>Download backup dulu</b> sebelum reset. Perusahaan, outlet, gudang, user, role, COA, metode bayar & pengaturan tidak ikut terhapus.</p>
        <div className="row">
          <button disabled={busy} onClick={downloadBackup}><Download size={16} /> Backup dulu</button>
          <button className="btn-danger" disabled={busy} onClick={() => reset('transactions')}>Hapus semua transaksi (master tetap)</button>
          <button className="btn-danger-solid" disabled={busy} onClick={() => reset('all')}>Reset total (master & transaksi)</button>
        </div>
      </div>
    </div>
  );
}
