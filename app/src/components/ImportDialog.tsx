import { useState } from 'react';
import { Download, FileSpreadsheet, Upload } from 'lucide-react';
import Modal from './Modal';
import { downloadXlsx, readXlsxRows } from '../lib/excel';
import { errorMessage } from '../lib/format';

export interface ImportColumn { key: string; label: string; required?: boolean; example: string; hint?: string }
interface ImportResult { inserted: number; errors: { row: number; code?: string; message: string }[] }

// Dialog import Excel: unduh template -> pilih file -> validasi server (semua-atau-tidak) -> laporan error per baris
export default function ImportDialog({ title, columns, templateName, onImport, onClose, onDone }: {
  title: string;
  columns: ImportColumn[];
  templateName: string;
  onImport: (rows: Record<string, string>[], createMissing: boolean) => Promise<ImportResult>;
  onClose: () => void;
  onDone: (inserted: number) => void;
}) {
  const [file, setFile] = useState<File | null>(null);
  const [createMissing, setCreateMissing] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState<ImportResult | null>(null);
  const [rows, setRows] = useState<Record<string, string>[]>([]);

  const template = () => downloadXlsx(templateName, [
    { name: 'Data', rows: [Object.fromEntries(columns.map((c) => [c.label, c.example]))], widths: columns.map((c) => Math.max(14, c.label.length + 2)) },
    { name: 'Petunjuk', rows: columns.map((c) => ({ Kolom: c.label, Wajib: c.required ? 'YA' : '', Keterangan: c.hint ?? '', Contoh: c.example })), widths: [22, 8, 60, 24] },
  ]);

  // label kolom template -> kunci yang dikirim ke server
  const keyOf = (header: string) => columns.find((c) => c.label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '') === header)?.key ?? header;

  const run = async () => {
    if (!file) return;
    setBusy(true);
    setError('');
    setResult(null);
    try {
      const parsed = (await readXlsxRows(file)).map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [keyOf(k), v])));
      if (!parsed.length) throw new Error('Tidak ada baris data di file');
      setRows(parsed);
      const res = await onImport(parsed, createMissing);
      setResult(res);
      if (res.inserted > 0 && !res.errors.length) onDone(res.inserted);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const downloadErrors = () => downloadXlsx(`error-${templateName}`, [{
    name: 'Error',
    rows: (result?.errors ?? []).map((e) => ({ Baris: e.row + 1, Kode: e.code ?? '', Error: e.message, ...Object.fromEntries(Object.entries(rows[e.row - 1] ?? {})) })),
  }]);

  return (
    <Modal title={title} onClose={onClose} large
      footer={<>
        <button onClick={onClose}>Tutup</button>
        <button className="btn-primary" disabled={busy || !file} onClick={run}><Upload size={16} /> {busy ? 'Memproses…' : 'Upload & Validasi'}</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      <ol className="steps">
        <li>
          Unduh template, isi mulai baris ke-2 (hapus baris contoh).
          <div style={{ marginTop: 6 }}><button className="btn-sm" onClick={template}><Download size={14} /> Unduh template</button></div>
        </li>
        <li>
          Pilih file Excel (.xlsx) yang sudah diisi.
          <label className="file-drop">
            <FileSpreadsheet size={22} />
            <span>{file ? file.name : 'Klik untuk memilih file'}</span>
            <input type="file" accept=".xlsx,.xls,.csv" hidden onChange={(e) => { setFile(e.target.files?.[0] ?? null); setResult(null); }} />
          </label>
        </li>
        <li>
          <label className="row"><input type="checkbox" checked={createMissing} onChange={(e) => setCreateMissing(e.target.checked)} />
            Buat otomatis kategori / satuan yang belum ada</label>
        </li>
      </ol>

      {result && result.errors.length > 0 && (
        <div style={{ marginTop: 16 }}>
          <div className="alert alert-error">
            {result.errors.length} baris bermasalah. <b>Tidak ada data yang disimpan</b>: perbaiki lalu upload ulang.
            <button className="btn-sm" style={{ marginLeft: 8 }} onClick={downloadErrors}><Download size={14} /> Unduh daftar error</button>
          </div>
          <div className="table-wrap" style={{ maxHeight: 260, overflowY: 'auto' }}>
            <table className="table">
              <thead><tr><th>Baris Excel</th><th>Kode</th><th>Masalah</th></tr></thead>
              <tbody>
                {result.errors.map((e) => (
                  <tr key={e.row}><td>{e.row + 1}</td><td className="bold">{e.code}</td><td>{e.message}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {result && !result.errors.length && <div className="alert alert-success" style={{ marginTop: 16 }}>{result.inserted} data berhasil disimpan.</div>}

      <details style={{ marginTop: 16 }}>
        <summary className="muted small" style={{ cursor: 'pointer' }}>Lihat daftar kolom</summary>
        <table className="table" style={{ marginTop: 8 }}>
          <tbody>
            {columns.map((c) => (
              <tr key={c.key}><td className="bold">{c.label}{c.required && ' *'}</td><td className="small muted">{c.hint}</td><td className="small">{c.example}</td></tr>
            ))}
          </tbody>
        </table>
      </details>
    </Modal>
  );
}
