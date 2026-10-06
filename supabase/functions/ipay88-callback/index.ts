// Edge Function: ipay88-callback  (BackendURL iPay88)
// Deploy TANPA verifikasi JWT, karena dipanggil server iPay88:
//   supabase functions deploy ipay88-callback --no-verify-jwt
// Memverifikasi tanda tangan, lalu menandai order lunas lewat pos_complete_gateway_payment.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { formatAmount, responseSignatureString, safeEqual, sign } from '../_shared/ipay88.ts';

const text = (body: string, status = 200) => new Response(body, { status, headers: { 'Content-Type': 'text/plain' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return text('Method not allowed', 405);
  try {
    const form = await req.formData();
    const p = (k: string) => String(form.get(k) ?? '');
    const refNo = p('RefNo');
    if (!refNo) return text('RefNo kosong', 400);

    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: pr } = await admin.from('pos_payment_requests').select('id, gateway_id, amount, currency').eq('ref_no', refNo).single();
    if (!pr) return text('RefNo tidak dikenal', 404);

    const { data: gw } = await admin.from('sys_payment_gateways').select('merchant_code, signature_method').eq('id', pr.gateway_id).single();
    const { data: secret } = await admin.from('sys_payment_gateway_secrets').select('merchant_key').eq('gateway_id', pr.gateway_id).single();
    if (!gw || !secret) return text('Gateway tidak dikonfigurasi', 500);

    // Amount dari iPay88 bisa berformat "150000" atau "150000.00": samakan untuk tanda tangan & perbandingan
    const amountRaw = p('Amount');
    const expected = await sign(gw.signature_method, secret.merchant_key,
      responseSignatureString(secret.merchant_key, gw.merchant_code, p('PaymentId'), refNo, amountRaw, p('Currency'), p('Status')));
    if (p('MerchantCode') !== gw.merchant_code || !safeEqual(expected.toLowerCase(), p('Signature').toLowerCase())) {
      console.error('Tanda tangan iPay88 tidak valid', refNo);
      return text('Invalid signature', 400);
    }

    const raw: Record<string, string> = {};
    form.forEach((v, k) => { if (k !== 'Signature') raw[k] = String(v); });

    const { error } = await admin.rpc('pos_complete_gateway_payment', {
      p_ref_no: refNo,
      p_success: p('Status') === '1',
      p_amount: Number(formatAmount(amountRaw.replace(/,/g, ''))),
      p_trans_id: p('TransId') || null,
      p_auth_code: p('AuthCode') || null,
      p_error_desc: p('ErrDesc') || null,
      p_raw: raw,
    });
    if (error) {
      console.error(error);
      return text('Gagal memproses', 500);
    }
    // iPay88 mengharapkan balasan persis "RECEIVEOK" agar tidak mengirim ulang
    return text('RECEIVEOK');
  } catch (e) {
    console.error(e);
    return text('Error', 500);
  }
});
