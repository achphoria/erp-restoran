import { supabase } from './supabase';

// Staf login dengan username; di Supabase Auth disimpan sebagai email sintetis
export const STAFF_EMAIL_DOMAIN = 'staff.santap.local';
export const toLoginEmail = (input: string) => {
  const v = input.trim().toLowerCase();
  return v.includes('@') ? v : `${v}@${STAFF_EMAIL_DOMAIN}`;
};
export const USERNAME_RE = /^[a-z0-9][a-z0-9._-]{2,31}$/;

// Panggil Edge Function staff-users; pesan error dari fungsi diteruskan apa adanya
export async function invokeStaffUsers<T = unknown>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('staff-users', { body });
  if (error) {
    const ctx = (error as { context?: Response }).context;
    let msg = error.message;
    try { msg = (await ctx?.json())?.error ?? msg; } catch { /* bukan JSON */ }
    if (/Failed to send|Function not found|404/i.test(msg)) {
      msg = 'Edge Function "staff-users" belum di-deploy. Lihat README bagian "User staf".';
    }
    throw new Error(msg);
  }
  return data as T;
}

// Password acak yang mudah dibaca (tanpa karakter mirip: 0/O, 1/l)
export function generatePassword(length = 10) {
  const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
  const arr = new Uint32Array(length);
  crypto.getRandomValues(arr);
  return [...arr].map((n) => chars[n % chars.length]).join('');
}
