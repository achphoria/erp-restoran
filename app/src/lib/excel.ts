// Baca & tulis Excel (SheetJS, dimuat saat dibutuhkan supaya aplikasi tetap ringan)
type Row = Record<string, string | number | boolean | null | undefined>;

const load = () => import('xlsx');

// Judul kolom -> kunci: "Satuan Beli" -> "satuan_beli", "Info 1" -> "info_1"
export const normalizeHeader = (h: string) =>
  h.toString().trim().toLowerCase().replace(/\*/g, '').replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');

export async function downloadXlsx(filename: string, sheets: { name: string; rows: Row[]; widths?: number[] }[]) {
  const XLSX = await load();
  const wb = XLSX.utils.book_new();
  for (const s of sheets) {
    const ws = XLSX.utils.json_to_sheet(s.rows);
    if (s.widths) ws['!cols'] = s.widths.map((wch) => ({ wch }));
    XLSX.utils.book_append_sheet(wb, ws, s.name.slice(0, 31));
  }
  XLSX.writeFile(wb, filename.endsWith('.xlsx') ? filename : `${filename}.xlsx`);
}

// Baca sheet pertama; semua nilai jadi teks (tanpa format angka lokal), baris kosong dibuang
export async function readXlsxRows(file: File): Promise<Record<string, string>[]> {
  const XLSX = await load();
  const wb = XLSX.read(await file.arrayBuffer(), { type: 'array' });
  const ws = wb.Sheets[wb.SheetNames[0]];
  const raw = XLSX.utils.sheet_to_json<Record<string, unknown>>(ws, { defval: '', raw: true });
  return raw
    .map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [normalizeHeader(k), v === null || v === undefined ? '' : String(v).trim()])))
    .filter((r) => Object.values(r).some((v) => v !== ''));
}
