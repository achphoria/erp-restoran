import { getAppName } from './brand';
import { formatNumber, formatRupiah } from './format';

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export interface PrintDoc {
  title: string;                       // SURAT JALAN / INVOICE
  number: string;
  meta: [string, string][];            // pasangan label - nilai di kanan atas
  partyLabel: string;                  // Kepada / Penerima
  party: string[];                     // baris alamat
  columns: { label: string; right?: boolean }[];
  rows: (string | number)[][];
  totals?: [string, number][];
  notes?: string;
  signatures?: string[];               // kolom tanda tangan
}

// Dokumen A4 sederhana (surat jalan, invoice) lewat dialog print browser
export function printDocument(d: PrintDoc) {
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(d.title)} ${esc(d.number)}</title><style>
    @page { size: A4; margin: 14mm; }
    body { font-family: Arial, Helvetica, sans-serif; color: #111; font-size: 12px; }
    .head { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #111; padding-bottom: 10px; }
    h1 { margin: 0; font-size: 20px; letter-spacing: 1px; }
    .brand { font-weight: 700; font-size: 14px; }
    .meta td { padding: 1px 0 1px 12px; }
    .party { margin: 14px 0; }
    table.items { width: 100%; border-collapse: collapse; margin-top: 8px; }
    table.items th, table.items td { border: 1px solid #999; padding: 6px 8px; text-align: left; }
    table.items th { background: #f0f0f0; }
    .r { text-align: right !important; }
    .totals { margin-left: auto; margin-top: 8px; }
    .totals td { padding: 3px 0 3px 24px; } .totals tr:last-child td { font-weight: 700; border-top: 1px solid #111; }
    .sign { display: flex; gap: 24px; margin-top: 48px; } .sign div { flex: 1; text-align: center; } .sign .line { margin-top: 64px; border-top: 1px solid #111; }
  </style></head><body>
  <div class="head">
    <div><div class="brand">${esc(getAppName())}</div><h1>${esc(d.title)}</h1><div>${esc(d.number)}</div></div>
    <table class="meta">${d.meta.map(([k, v]) => `<tr><td>${esc(k)}</td><td><b>${esc(v)}</b></td></tr>`).join('')}</table>
  </div>
  <div class="party"><div>${esc(d.partyLabel)}:</div>${d.party.filter(Boolean).map((l, i) => i === 0 ? `<b>${esc(l)}</b>` : `<div>${esc(l)}</div>`).join('')}</div>
  <table class="items"><thead><tr><th>#</th>${d.columns.map((c) => `<th class="${c.right ? 'r' : ''}">${esc(c.label)}</th>`).join('')}</tr></thead>
  <tbody>${d.rows.map((r, i) => `<tr><td>${i + 1}</td>${r.map((v, j) => `<td class="${d.columns[j]?.right ? 'r' : ''}">${esc(v)}</td>`).join('')}</tr>`).join('')}</tbody></table>
  ${d.totals ? `<table class="totals">${d.totals.map(([k, v]) => `<tr><td>${esc(k)}</td><td class="r">${esc(formatRupiah(v))}</td></tr>`).join('')}</table>` : ''}
  ${d.notes ? `<p>${esc(d.notes)}</p>` : ''}
  ${d.signatures ? `<div class="sign">${d.signatures.map((s) => `<div>${esc(s)}<div class="line"></div></div>`).join('')}</div>` : ''}
  <script>window.onload=()=>{window.print();}</script></body></html>`;
  const win = window.open('', '_blank', 'width=900,height=700');
  if (!win) throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak.');
  win.document.write(html);
  win.document.close();
}

export const qty = (n: number | string, unit: string) => `${formatNumber(n)} ${unit}`;
