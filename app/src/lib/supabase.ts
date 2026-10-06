import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

if (!url || !anonKey) {
  throw new Error('VITE_SUPABASE_URL dan VITE_SUPABASE_ANON_KEY belum diisi di file .env.local');
}

export const supabase = createClient(url, anonKey);

// Panggil fungsi database (RPC) dan lempar error dengan pesan yang jelas
export async function rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

// Ambil hasil query, lempar error bila gagal.
// Hasilnya sengaja `any` karena belum memakai tipe hasil generate (`supabase gen types`);
// pemanggil meng-cast ke interface di lib/types.ts.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function must(query: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<any> {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data;
}
