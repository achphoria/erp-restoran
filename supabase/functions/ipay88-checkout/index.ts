// Edge Function: ipay88-checkout
// Dipanggil aplikasi kasir (dengan JWT user) setelah pos_create_gateway_payment.
// Mengembalikan URL + field form yang sudah ditandatangani untuk dibuka di halaman iPay88.
//
// Secret yang dibutuhkan (Supabase > Edge Functions > Secrets):
//   APP_URL  = https://achphoria.github.io/semar-erp   (untuk ResponseURL)
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY tersedia otomatis.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeaders, ENTRY_URL, formatAmount, requestSignatureString, sign } from '../_shared/ipay88.ts';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const { request_id } = await req.json();
    if (!request_id) return json({ error: 'request_id wajib' }, 400);

    // 1) baca permintaan sebagai user yang login (RLS memastikan milik perusahaannya)
    const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    });
    const { data: pr, error } = await userClient
      .from('pos_payment_requests')
      .select('id, ref_no, amount, currency, status, payment_id, gateway_id, order_id, pos_orders(order_number, customer_name)')
      .eq('id', request_id)
      .single();
    if (error || !pr) return json({ error: 'Permintaan pembayaran tidak ditemukan' }, 404);
    if (pr.status !== 'pending') return json({ error: `Status permintaan: ${pr.status}` }, 400);

    // 2) ambil konfigurasi & merchant key dengan service role
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: gw } = await admin.from('sys_payment_gateways').select('*').eq('id', pr.gateway_id).single();
    const { data: secret } = await admin.from('sys_payment_gateway_secrets').select('merchant_key').eq('gateway_id', pr.gateway_id).single();
    if (!gw?.is_active || !gw.merchant_code || !secret?.merchant_key) return json({ error: 'Gateway belum dikonfigurasi lengkap' }, 400);

    const amount = formatAmount(pr.amount);
    const signature = await sign(gw.signature_method, secret.merchant_key,
      requestSignatureString(secret.merchant_key, gw.merchant_code, pr.ref_no, amount, pr.currency));

    const appUrl = (Deno.env.get('APP_URL') ?? '').replace(/\/$/, '');
    const order = pr.pos_orders as unknown as { order_number: string; customer_name: string | null } | null;

    return json({
      action_url: ENTRY_URL[gw.environment as 'sandbox' | 'production'],
      fields: {
        MerchantCode: gw.merchant_code,
        PaymentId: pr.payment_id ?? '',
        RefNo: pr.ref_no,
        Amount: amount,
        Currency: pr.currency,
        ProdDesc: `Pesanan ${order?.order_number ?? pr.ref_no}`,
        UserName: order?.customer_name || 'Pelanggan',
        UserEmail: 'pelanggan@example.com',
        UserContact: '',
        Remark: pr.id,
        Lang: 'UTF-8',
        SignatureType: gw.signature_method === 'sha256' ? 'SHA256' : 'HMACSHA512',
        Signature: signature,
        ResponseURL: `${appUrl}/payment-return`,
        BackendURL: `${Deno.env.get('SUPABASE_URL')}/functions/v1/ipay88-callback`,
      },
    });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
