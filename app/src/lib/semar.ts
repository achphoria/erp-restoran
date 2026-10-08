import { supabase } from './supabase';

// Panggil Edge Function semar-agent (agent AI Semar); pesan error dari fungsi diteruskan apa adanya
export async function invokeSemar<T = unknown>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('semar-agent', { body });
  if (error) {
    const ctx = (error as { context?: Response }).context;
    let msg = error.message;
    try { msg = (await ctx?.json())?.error ?? msg; } catch { /* bukan JSON */ }
    if (/Failed to send|Function not found|404/i.test(msg)) {
      msg = 'Edge Function "semar-agent" belum di-deploy. Lihat README bagian "Agent Semar".';
    }
    throw new Error(msg);
  }
  return data as T;
}

export interface Attachment { name: string; kind: 'text' | 'image' | 'pdf'; media_type?: string; data: string; info: string }

const MAX_TEXT = 60000;
const toBase64 = (buf: ArrayBuffer) => {
  let s = '';
  const bytes = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};

// Siapkan file untuk dikirim ke Semar: Excel/CSV -> teks CSV per sheet, gambar & PDF -> base64
export async function readAttachment(file: File): Promise<Attachment> {
  const name = file.name;
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  if (['xlsx', 'xls', 'xlsm', 'ods'].includes(ext)) {
    const XLSX = await import('xlsx');
    const wb = XLSX.read(await file.arrayBuffer(), { type: 'array' });
    const parts = wb.SheetNames.slice(0, 8).map((sn) => {
      const csv = XLSX.utils.sheet_to_csv(wb.Sheets[sn], { blankrows: false });
      return `--- Sheet "${sn}" (${csv ? csv.split('\n').length : 0} baris) ---\n${csv}`;
    });
    const data = parts.join('\n\n');
    return { name, kind: 'text', data, info: `${wb.SheetNames.length} sheet${data.length > MAX_TEXT ? ', akan dipotong' : ''}` };
  }
  if (['csv', 'txt', 'json', 'tsv', 'md'].includes(ext) || file.type.startsWith('text/')) {
    const data = await file.text();
    return { name, kind: 'text', data, info: `${data.split('\n').length} baris` };
  }
  if (file.type.startsWith('image/')) {
    if (file.size > 4.5 * 1024 * 1024) throw new Error(`Gambar ${name} terlalu besar (maks 4,5 MB)`);
    return { name, kind: 'image', media_type: file.type, data: toBase64(await file.arrayBuffer()), info: 'gambar' };
  }
  if (ext === 'pdf') {
    if (file.size > 8 * 1024 * 1024) throw new Error(`PDF ${name} terlalu besar (maks 8 MB)`);
    return { name, kind: 'pdf', media_type: 'application/pdf', data: toBase64(await file.arrayBuffer()), info: 'PDF' };
  }
  throw new Error(`Jenis file ${name} belum didukung. Pakai Excel, CSV, PDF, atau gambar.`);
}
