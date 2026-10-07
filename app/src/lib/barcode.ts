import JsBarcode from 'jsbarcode';

export interface LabelData { code: string; title: string; lines: string[] }
export interface LabelSize { w: number; h: number }

export const LABEL_SIZES: { key: string; label: string; size: LabelSize }[] = [
  { key: '50x30', label: '50 × 30 mm', size: { w: 50, h: 30 } },
  { key: '40x30', label: '40 × 30 mm', size: { w: 40, h: 30 } },
  { key: '58x40', label: '58 × 40 mm', size: { w: 58, h: 40 } },
  { key: '80x50', label: '80 × 50 mm (koli)', size: { w: 80, h: 50 } },
];

// ukuran stiker diingat per jenis label (batch / koli) di perangkat ini
export const getLabelSizeKey = (kind: string, fallback = '50x30') => {
  try { return localStorage.getItem(`santap-label-size-${kind}`) ?? fallback; } catch { return fallback; }
};
export const setLabelSizeKey = (kind: string, key: string) => {
  try { localStorage.setItem(`santap-label-size-${kind}`, key); } catch { /* abaikan */ }
};

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

// SVG barcode Code128 (tanpa teks; teks ditulis terpisah supaya bisa diatur ukurannya)
export function barcodeSvg(code: string, height = 40): string {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  JsBarcode(svg, code, { format: 'CODE128', displayValue: false, margin: 0, height, width: 2 });
  svg.setAttribute('preserveAspectRatio', 'none');
  return svg.outerHTML;
}

// Cetak label ke printer thermal (1 label = 1 halaman seukuran stiker)
export function printLabels(labels: LabelData[], size: LabelSize) {
  const big = size.h >= 45;
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>Label</title><style>
    @page { size: ${size.w}mm ${size.h}mm; margin: 0; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: Arial, Helvetica, sans-serif; color: #000; }
    .label { width: ${size.w}mm; height: ${size.h}mm; padding: 1.5mm 2mm; display: flex; flex-direction: column; overflow: hidden; page-break-after: always; }
    .label:last-child { page-break-after: auto; }
    .t { font-weight: 700; font-size: ${big ? 13 : 9}pt; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .bc { flex: 1; min-height: 0; margin: 1mm 0 0.5mm; }
    .bc svg { width: 100%; height: 100%; display: block; }
    .c { font-family: 'Courier New', monospace; font-weight: 700; font-size: ${big ? 12 : 8}pt; text-align: center; letter-spacing: 0.5px; }
    .l { font-size: ${big ? 9 : 6.5}pt; line-height: 1.2; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    @media screen { body { background: #ddd; padding: 8px; } .label { background: #fff; margin: 0 auto 8px; outline: 1px dashed #999; } }
  </style></head><body>
  ${labels.map((l) => `<div class="label">
    <div class="t">${esc(l.title)}</div>
    <div class="bc">${barcodeSvg(l.code)}</div>
    <div class="c">${esc(l.code)}</div>
    ${l.lines.filter(Boolean).map((x) => `<div class="l">${esc(x)}</div>`).join('')}
  </div>`).join('')}
  <script>window.onload=()=>{window.print();}</script>
  </body></html>`;

  const win = window.open('', '_blank', 'width=420,height=600');
  if (!win) throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak label.');
  win.document.write(html);
  win.document.close();
}
