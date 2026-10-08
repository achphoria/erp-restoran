import QRCode from 'qrcode';
import { rpc } from './supabase';
import { formatDateTime, formatRupiah, SALES_CHANNELS } from './format';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Struk thermal 80mm (area cetak ±72mm). Dicetak lewat iframe tersembunyi -> tidak diblokir popup,
// dan di mode kiosk Chrome (--kiosk-printing) langsung tercetak tanpa dialog.
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export const feedbackUrl = (token: string) => `${window.location.origin}${import.meta.env.BASE_URL}ulas/${token}`;

const AUTO_KEY = 'semar.receipt.auto_print';
export const getAutoPrint = () => { try { return localStorage.getItem(AUTO_KEY) === '1'; } catch { return false; } };
export const setAutoPrint = (v: boolean) => { try { localStorage.setItem(AUTO_KEY, v ? '1' : '0'); } catch { /* storage diblokir */ } };

export async function buildReceiptHtml(d: any, opts: { title?: string; queue?: string | null; copy?: boolean } = {}) {
  const o = d.order;
  const paid = o.status === 'paid';
  const qr = paid && d.feedback_token && d.outlet.show_feedback_qr
    ? await QRCode.toDataURL(feedbackUrl(d.feedback_token), { width: 300, margin: 0, errorCorrectionLevel: 'M' }) : null;
  const row = (l: string, r: string, cls = '') => `<div class="r ${cls}"><span>${l}</span><span>${r}</span></div>`;
  const money = (n: unknown) => { const v = Number(n ?? 0); return (v < 0 ? '-' : '') + formatRupiah(Math.abs(v)).replace('Rp', '').trim(); };
  const channel = o.order_source === 'kiosk' ? 'Kiosk · ' + (SALES_CHANNELS[o.sales_channel] ?? o.sales_channel) : SALES_CHANNELS[o.sales_channel] ?? o.sales_channel;
  const change = (d.payments ?? []).reduce((s: number, p: any) => s + Number(p.change ?? 0), 0);
  const logo = d.outlet.show_logo && d.brand?.logo_url ? `<img class="logo" src="${esc(d.brand.logo_url)}" alt="">` : '';
  const name = d.brand?.name && d.brand.name !== d.outlet.name ? `${esc(d.brand.name)}<small>${esc(d.outlet.name)}</small>` : esc(d.outlet.name);

  return `<!doctype html><html><head><meta charset="utf-8"><title>${esc(o.order_number)}</title>
<style>
  @page { size: 80mm auto; margin: 0; }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: #fff; color: #000; }
  body { width: 80mm; padding: 4mm 4mm 6mm; font: 12px/1.35 'Courier New', ui-monospace, monospace; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .c { text-align: center; }
  .logo { display: block; margin: 0 auto 2mm; max-width: 46mm; max-height: 22mm; object-fit: contain; filter: grayscale(1) contrast(1.6); }
  .name { font: 800 17px/1.15 Arial, Helvetica, sans-serif; text-align: center; letter-spacing: .3px; }
  .name small { display: block; font-weight: 600; font-size: 12px; margin-top: 1px; }
  .muted { font-size: 11px; }
  .hd { font: 700 11px Arial, sans-serif; text-align: center; margin-top: 1mm; }
  .sep { border: 0; border-top: 1px dashed #000; margin: 2mm 0; }
  .sep2 { border: 0; border-top: 2px solid #000; margin: 2mm 0; }
  .banner { margin: 2mm 0; padding: 1.5mm; border: 2px solid #000; border-radius: 2mm; text-align: center; font: 800 14px Arial, sans-serif; letter-spacing: .5px; }
  .banner small { display: block; font-weight: 600; font-size: 11px; }
  .queue { font: 900 44px/1 Arial, sans-serif; text-align: center; margin: 1mm 0; }
  .r { display: flex; justify-content: space-between; gap: 3mm; }
  .r > span:last-child { white-space: nowrap; text-align: right; }
  .it { margin: 1.2mm 0; }
  .it b { font-weight: 700; }
  .m { padding-left: 4mm; font-size: 11px; }
  .tot { font: 900 16px Arial, sans-serif; }
  .fb { margin-top: 3mm; padding: 2mm; border: 1px solid #000; border-radius: 2mm; display: flex; gap: 3mm; align-items: center; }
  .fb img { width: 24mm; height: 24mm; flex: none; }
  .fb b { font: 800 12px Arial, sans-serif; display: block; margin-bottom: 1mm; }
  .fb span { font-size: 10.5px; }
  .ft { font: 600 11px Arial, sans-serif; text-align: center; margin-top: 3mm; white-space: pre-line; }
  .pw { font-size: 9px; text-align: center; margin-top: 2mm; letter-spacing: .5px; }
  .copy { text-align: center; font: 800 11px Arial, sans-serif; border: 1px dashed #000; padding: 1mm; margin-bottom: 2mm; }
</style></head><body>
${opts.copy ? '<div class="copy">SALINAN / CETAK ULANG</div>' : ''}
${logo}
<div class="name">${name}</div>
${d.outlet.address ? `<div class="c muted">${esc(d.outlet.address)}</div>` : ''}
${d.outlet.phone ? `<div class="c muted">Telp ${esc(d.outlet.phone)}</div>` : ''}
${d.company?.tax_number ? `<div class="c muted">NPWP ${esc(d.company.tax_number)}</div>` : ''}
${d.outlet.header ? `<div class="hd">${esc(d.outlet.header)}</div>` : ''}
${opts.queue ? `<hr class="sep"><div class="c muted">NOMOR ANTREAN</div><div class="queue">${esc(opts.queue)}</div>` : ''}
<div class="banner">${esc(opts.title ?? (paid ? channel.toUpperCase() : 'TAGIHAN'))}${o.table ? `<small>Meja ${esc(o.table)}${o.guest_count > 1 ? ` · ${o.guest_count} tamu` : ''}</small>` : ''}</div>
${row('No.', esc(o.order_number))}
${row('Waktu', formatDateTime(o.paid_at ?? o.created_at))}
${o.cashier ? row('Kasir', esc(o.cashier)) : ''}
${o.customer_name ? row('Nama', esc(o.customer_name)) : ''}
<hr class="sep">
${(d.items ?? []).map((i: any) => `<div class="it">
  <div><b>${esc(i.name)}</b></div>
  ${(i.modifiers ?? []).map((m: string) => `<div class="m">+ ${esc(m)}</div>`).join('')}
  ${i.note ? `<div class="m">* ${esc(i.note)}</div>` : ''}
  ${row(`&nbsp;&nbsp;${Number(i.qty)} x ${money(Number(i.line_total) / Math.max(1, Number(i.qty)))}`, money(i.line_total))}
</div>`).join('')}
<hr class="sep">
${row('Subtotal', money(o.subtotal))}
${Number(o.discount_amount) ? row('Diskon', '-' + money(o.discount_amount)) : ''}
${Number(o.promotion_amount) ? row(esc(o.promotion ?? 'Promo'), '-' + money(o.promotion_amount)) : ''}
${Number(o.points_amount) ? row(`Tukar ${o.points_redeemed} poin`, '-' + money(o.points_amount)) : ''}
${Number(o.service_amount) ? row('Service', money(o.service_amount)) : ''}
${Number(o.tax_amount) ? row(`Pajak${d.outlet.tax_rate ? ` ${Number(d.outlet.tax_rate)}%` : ''}`, money(o.tax_amount)) : ''}
${Number(o.rounding_amount) ? row('Pembulatan', money(o.rounding_amount)) : ''}
<hr class="sep2">
${row('TOTAL', 'Rp ' + money(o.grand_total), 'tot')}
<hr class="sep2">
${(d.payments ?? []).map((p: any) => row(esc(p.method), money(p.amount))).join('')}
${change ? row('Kembali', money(change)) : ''}
${!paid ? '<div class="c muted" style="margin-top:2mm">Belum dibayar · tunjukkan ke kasir</div>' : ''}
${d.member ? `<hr class="sep">${row('Member', esc(d.member.name))}${o.points_earned ? row('Poin didapat', '+' + o.points_earned) : ''}${row('Saldo poin', String(d.member.points_balance))}` : ''}
${qr ? `<div class="fb"><img src="${qr}" alt=""><div><b>${esc(d.feedback?.title ?? 'Bagaimana pengalamanmu?')}</b><span>Scan untuk beri ulasan & saran (1 menit).${d.feedback?.incentive ? ' ' + esc(d.feedback.incentive) : ''}</span></div></div>` : ''}
${d.outlet.footer ? `<div class="ft">${esc(d.outlet.footer)}</div>` : ''}
<div class="pw">— powered by SEMAR —</div>
</body></html>`;
}

// cetak lewat iframe tersembunyi; tunggu logo & QR selesai dimuat
export function printHtml(html: string) {
  return new Promise<void>((resolve) => {
    const f = document.createElement('iframe');
    f.setAttribute('aria-hidden', 'true');
    f.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
    document.body.appendChild(f);
    const doc = f.contentDocument!;
    doc.open();
    doc.write(html);
    doc.close();
    const imgs = Array.from(doc.images);
    const ready = Promise.all(imgs.map((img) => (img.complete ? Promise.resolve() : new Promise((r) => { img.onload = r; img.onerror = r; }))));
    Promise.race([ready, new Promise((r) => setTimeout(r, 2500))]).then(() => {
      f.contentWindow!.focus();
      f.contentWindow!.print();
      setTimeout(() => { f.remove(); resolve(); }, 1500);
    });
  });
}

// cetak struk (atau tagihan bila belum dibayar) untuk order
export async function printReceipt(orderId: string, opts: { copy?: boolean } = {}) {
  const d = await rpc<any>('pos_receipt_data', { p_order_id: orderId });
  await printHtml(await buildReceiptHtml(d, opts));
}

// contoh struk untuk pratinjau pengaturan outlet
export function sampleReceipt(outlet: any, brand: { name?: string; logo_url?: string | null } | null, company: any) {
  return {
    order: { order_number: 'INV/OUT01/20261009/0042', status: 'paid', sales_channel: 'dine_in', order_source: 'pos', table: 'A3', guest_count: 2,
      cashier: 'Andi', created_at: new Date().toISOString(), paid_at: new Date().toISOString(), subtotal: 98000, discount_amount: 0, promotion_amount: 0,
      points_amount: 0, service_amount: 0, tax_amount: 9800, rounding_amount: -800, grand_total: 107000 },
    outlet: { ...outlet, show_logo: outlet.receipt_show_logo, show_feedback_qr: outlet.receipt_show_feedback_qr, header: outlet.receipt_header, footer: outlet.receipt_footer },
    brand, company, feedback: { title: 'Bagaimana pengalamanmu?' }, feedback_token: '0'.repeat(32),
    items: [
      { name: 'Kopi Susu Gula Aren', qty: 2, line_total: 44000, modifiers: ['Less sugar', 'Oat milk'] },
      { name: 'Nasi Goreng Kampung', qty: 1, line_total: 38000, modifiers: [], note: 'Tidak pedas' },
      { name: 'Pisang Goreng Keju', qty: 1, line_total: 16000, modifiers: [] },
    ],
    payments: [{ method: 'Tunai', amount: 110000, change: 3000 }],
  };
}
