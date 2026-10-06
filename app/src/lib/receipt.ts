import { supabase } from './supabase';
import { formatDateTime, formatRupiah, SALES_CHANNELS } from './format';

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

// Cetak struk 58/80mm lewat dialog print browser
export async function printReceipt(orderId: string) {
  const { data: order, error } = await supabase
    .from('pos_orders')
    .select(`*, sys_outlets(name, address, phone), mst_tables(code), crm_customers(name, points_balance), crm_promotions(name),
             pos_order_items(menu_item_name, quantity, unit_price, modifier_amount, line_total, is_void,
                             pos_order_item_modifiers(modifier_name)),
             pos_payments(amount, change_amount, mst_payment_methods(name))`)
    .eq('id', orderId)
    .single();
  if (error || !order) throw new Error(error?.message ?? 'Order tidak ditemukan');

  const items = (order.pos_order_items as {
    menu_item_name: string; quantity: number; line_total: number; is_void: boolean;
    pos_order_item_modifiers: { modifier_name: string }[];
  }[]).filter((i) => !i.is_void);
  const payments = order.pos_payments as { amount: number; change_amount: number; mst_payment_methods: { name: string } }[];
  const row = (l: string, r: string, bold = false) =>
    `<div class="r${bold ? ' b' : ''}"><span>${l}</span><span>${r}</span></div>`;

  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(order.order_number)}</title>
  <style>
    body{font-family:monospace;font-size:12px;width:72mm;margin:0 auto;padding:8px}
    h3{text-align:center;margin:0}.c{text-align:center}.r{display:flex;justify-content:space-between;gap:8px}
    .b{font-weight:bold}hr{border:none;border-top:1px dashed #000}.m{padding-left:8px;font-size:11px}
  </style></head><body>
  <h3>${escapeHtml(order.sys_outlets.name)}</h3>
  <div class="c">${escapeHtml(order.sys_outlets.address ?? '')}</div>
  <hr>
  ${row('No', escapeHtml(order.order_number))}
  ${row('Waktu', formatDateTime(order.paid_at ?? order.created_at))}
  ${row('Tipe', SALES_CHANNELS[order.sales_channel] ?? order.sales_channel)}
  ${order.mst_tables ? row('Meja', escapeHtml(order.mst_tables.code)) : ''}
  <hr>
  ${items.map((i) => `
    <div>${escapeHtml(i.menu_item_name)}</div>
    ${i.pos_order_item_modifiers.map((m) => `<div class="m">+ ${escapeHtml(m.modifier_name)}</div>`).join('')}
    ${row(`&nbsp;&nbsp;${Number(i.quantity)} x`, formatRupiah(i.line_total))}`).join('')}
  <hr>
  ${row('Subtotal', formatRupiah(order.subtotal))}
  ${Number(order.discount_amount) ? row('Diskon', '-' + formatRupiah(order.discount_amount)) : ''}
  ${Number(order.promotion_amount) ? row(escapeHtml(order.crm_promotions?.name ?? 'Promo'), '-' + formatRupiah(order.promotion_amount)) : ''}
  ${Number(order.points_amount) ? row(`Tukar ${order.points_redeemed} poin`, '-' + formatRupiah(order.points_amount)) : ''}
  ${Number(order.service_amount) ? row('Service', formatRupiah(order.service_amount)) : ''}
  ${row('Pajak', formatRupiah(order.tax_amount))}
  ${Number(order.rounding_amount) ? row('Pembulatan', formatRupiah(order.rounding_amount)) : ''}
  ${row('TOTAL', formatRupiah(order.grand_total), true)}
  <hr>
  ${payments.map((p) => row(escapeHtml(p.mst_payment_methods.name), formatRupiah(p.amount))).join('')}
  ${payments.some((p) => Number(p.change_amount)) ? row('Kembali', formatRupiah(payments.reduce((s, p) => s + Number(p.change_amount), 0))) : ''}
  ${order.crm_customers ? `<hr>
  ${row('Member', escapeHtml(order.crm_customers.name))}
  ${row('Poin didapat', '+' + order.points_earned)}
  ${row('Saldo poin', String(order.crm_customers.points_balance))}` : ''}
  <hr><div class="c">Terima kasih 🙏</div>
  <script>window.onload=()=>{window.print();}</script>
  </body></html>`;

  const win = window.open('', '_blank', 'width=360,height=600');
  if (!win) throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak struk.');
  win.document.write(html);
  win.document.close();
}
