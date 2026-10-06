// Utilitas bersama iPay88.
//
// ⚠️ VERIFIKASI DENGAN DOKUMEN TEKNIS iPay88 YANG ANDA TERIMA SAAT DAFTAR MERCHANT.
// iPay88 memiliki beberapa versi API (Malaysia/Indonesia, legacy/v2) dan sejak 31 Jan 2025
// mewajibkan HMAC-SHA512. Format string tanda tangan di bawah mengikuti pola umum iPay88;
// bila dokumen Anda berbeda, cukup ubah fungsi requestSignatureString / responseSignatureString.

export type SignatureMethod = 'hmac_sha512' | 'sha256';

export const ENTRY_URL = {
  // Bisa ditimpa dengan secret IPAY88_ENTRY_URL_SANDBOX / IPAY88_ENTRY_URL_PRODUCTION
  sandbox: Deno.env.get('IPAY88_ENTRY_URL_SANDBOX') ?? 'https://sandbox.ipay88.co.id/epayment/entry.asp',
  production: Deno.env.get('IPAY88_ENTRY_URL_PRODUCTION') ?? 'https://payment.ipay88.co.id/epayment/entry.asp',
};

// Nominal IDR tanpa desimal & tanpa pemisah, mis. 150000
export const formatAmount = (amount: number | string) => String(Math.round(Number(amount)));

export const requestSignatureString = (merchantKey: string, merchantCode: string, refNo: string, amount: string, currency: string) =>
  `||${merchantKey}||${merchantCode}||${refNo}||${amount}||${currency}||`;

export const responseSignatureString = (
  merchantKey: string, merchantCode: string, paymentId: string, refNo: string, amount: string, currency: string, status: string,
) => `||${merchantKey}||${merchantCode}||${paymentId}||${refNo}||${amount}||${currency}||${status}||`;

const toHex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

export async function sign(method: SignatureMethod, merchantKey: string, data: string): Promise<string> {
  const enc = new TextEncoder();
  if (method === 'sha256') {
    return toHex(await crypto.subtle.digest('SHA-256', enc.encode(data)));
  }
  const key = await crypto.subtle.importKey('raw', enc.encode(merchantKey), { name: 'HMAC', hash: 'SHA-512' }, false, ['sign']);
  return toHex(await crypto.subtle.sign('HMAC', key, enc.encode(data)));
}

// Perbandingan waktu-konstan agar tanda tangan tidak bisa ditebak lewat timing
export function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
