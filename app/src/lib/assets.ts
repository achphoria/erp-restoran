import QRCode from 'qrcode';
import { supabase } from './supabase';
import { resizeImage } from './image';
import type { LabelSize } from './barcode';

// Aset tetap: label, foto (bucket PRIVAT 'asset-files'), label QR untuk ditempel di aset.

/* eslint-disable @typescript-eslint/no-explicit-any */
export interface Opt { id: string; name: string }
export interface AssetOptions {
  categories: any[]; outlets: Opt[]; all_outlets: boolean; users: Opt[]; suppliers: Opt[];
  cash_accounts: (Opt & { key: string | null })[]; accounts: (Opt & { type: string; key: string | null })[];
  settings: { capitalization_threshold: number } | null; can_manage: boolean; can_depreciate: boolean;
}

export const METHOD_LABEL: Record<string, string> = { straight_line: 'Garis lurus', declining_balance: 'Saldo menurun' };
export const FUNDING: Record<string, { label: string; hint: string }> = {
  cash: { label: 'Dibayar tunai / transfer', hint: 'Jurnal: Aset bertambah, Kas/Bank berkurang' },
  payable: { label: 'Belum dibayar (hutang)', hint: 'Jurnal: Aset bertambah, Hutang Pembelian Aset bertambah. Bayar nanti dari detail aset.' },
  opening: { label: 'Aset lama (sebelum pakai SEMAR)', hint: 'Jurnal saldo awal: akumulasi penyusutan lama dihitung otomatis' },
  none: { label: 'Sudah dicatat di jurnal', hint: 'Tidak membuat jurnal perolehan (sudah dicatat manual sebelumnya)' },
};
export const DISPOSAL_TYPE: Record<string, string> = { sold: 'Dijual', scrapped: 'Rusak / dibuang', lost: 'Hilang', donated: 'Dihibahkan' };
export const REQ_STATUS: Record<string, [string, string]> = {
  pending_approval: ['Menunggu persetujuan', 'badge-warning'], completed: ['Selesai', 'badge-success'],
  rejected: ['Ditolak', 'badge-danger'], cancelled: ['Dibatalkan', ''],
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
export const fmtDate = (d: string | null | undefined) => {
  if (!d) return '-';
  const [y, m, dd] = d.slice(0, 10).split('-').map(Number);
  return `${dd} ${MONTHS[m - 1]} ${y}`;
};
export const fmtMonth = (d: string | null | undefined) => {
  if (!d) return '-';
  const [y, m] = d.slice(0, 7).split('-').map(Number);
  return `${MONTHS[m - 1]} ${y}`;
};
export const lifeLabel = (months: number) => (months % 12 === 0 ? `${months / 12} tahun` : `${months} bulan`);
// bulan (tgl 1) relatif terhadap bulan ini di WIB: 0 = bulan ini, -1 = bulan lalu
export const monthISO = (offset = 0) => {
  const now = new Date(Date.now() + 7 * 3600 * 1000);
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + offset, 1));
  return d.toISOString().slice(0, 10);
};

// asset-files/<company>/<asset_id | new>/<acak>.webp
export async function uploadAssetPhoto(companyId: string, assetId: string | null, file: File): Promise<string> {
  if (!file.type.startsWith('image/')) throw new Error('File harus foto');
  const path = `${companyId}/${assetId ?? 'new'}/${crypto.randomUUID().slice(0, 8)}.webp`;
  const body = await resizeImage(file, 1280);
  const { error } = await supabase.storage.from('asset-files').upload(path, body, { contentType: 'image/webp' });
  if (error) throw new Error(error.message);
  return path;
}
const cache = new Map<string, { url: string; until: number }>();
export async function assetPhotoUrl(path: string | null | undefined): Promise<string | null> {
  if (!path) return null;
  const hit = cache.get(path);
  if (hit && hit.until > Date.now()) return hit.url;
  const { data } = await supabase.storage.from('asset-files').createSignedUrl(path, 3600);
  if (!data?.signedUrl) return null;
  cache.set(path, { url: data.signedUrl, until: Date.now() + 50 * 60 * 1000 });
  return data.signedUrl;
}

// link yang dibuka saat QR di-scan kamera HP: langsung ke detail aset (perlu login)
export const assetUrl = (code: string) => `${window.location.origin}${import.meta.env.BASE_URL}assets?code=${encodeURIComponent(code)}`;

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export interface AssetLabel { code: string; name: string; company: string; lines: string[] }

// Label QR untuk printer thermal (1 label = 1 halaman seukuran stiker)
export async function printAssetLabels(labels: AssetLabel[], size: LabelSize) {
  const qrs = await Promise.all(labels.map((l) => QRCode.toDataURL(assetUrl(l.code), { margin: 0, width: 300, errorCorrectionLevel: 'M' })));
  const qr = Math.min(size.h - 4, size.w * 0.45);
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>Label aset</title><style>
    @page { size: ${size.w}mm ${size.h}mm; margin: 0; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: Arial, Helvetica, sans-serif; color: #000; }
    .label { width: ${size.w}mm; height: ${size.h}mm; padding: 2mm; display: flex; gap: 2mm; align-items: center; overflow: hidden; page-break-after: always; }
    .label:last-child { page-break-after: auto; }
    .qr { width: ${qr}mm; height: ${qr}mm; flex: none; }
    .info { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: 0.6mm; }
    .co { font-size: 6pt; text-transform: uppercase; letter-spacing: .5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .c { font-family: 'Courier New', monospace; font-weight: 700; font-size: ${size.h >= 40 ? 11 : 8.5}pt; }
    .n { font-weight: 700; font-size: ${size.h >= 40 ? 10 : 7.5}pt; line-height: 1.15; max-height: 2.4em; overflow: hidden; }
    .l { font-size: 6.5pt; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    @media screen { body { background: #ddd; padding: 8px; } .label { background: #fff; margin: 0 auto 8px; outline: 1px dashed #999; } }
  </style></head><body>
  ${labels.map((l, i) => `<div class="label"><img class="qr" src="${qrs[i]}" alt="">
    <div class="info"><div class="co">${esc(l.company)}</div><div class="c">${esc(l.code)}</div><div class="n">${esc(l.name)}</div>
    ${l.lines.filter(Boolean).map((x) => `<div class="l">${esc(x)}</div>`).join('')}</div></div>`).join('')}
  <script>window.onload=()=>{window.print();}</script>
  </body></html>`;
  const win = window.open('', '_blank', 'width=420,height=600');
  if (!win) throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak label.');
  win.document.write(html);
  win.document.close();
}
