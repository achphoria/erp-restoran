import { supabase } from './supabase';
import { resizeImage } from './image';

// File HR disimpan di bucket PRIVAT 'hr-files' (<company>/<employee>/<file>) dan dibuka lewat signed URL
export async function uploadHrFile(companyId: string, employeeId: string, file: File, prefix = 'doc'): Promise<string> {
  const isImage = file.type.startsWith('image/');
  if (!isImage && file.type !== 'application/pdf') throw new Error('File harus gambar (JPG/PNG/WebP) atau PDF');
  if (file.size > 5 * 1024 * 1024 && !isImage) throw new Error('PDF maksimal 5 MB');
  const path = `${companyId}/${employeeId}/${prefix}-${crypto.randomUUID().slice(0, 8)}.${isImage ? 'webp' : 'pdf'}`;
  const body = isImage ? await resizeImage(file, prefix === 'photo' ? 480 : 1600) : file;
  const { error } = await supabase.storage.from('hr-files').upload(path, body, { contentType: isImage ? 'image/webp' : 'application/pdf' });
  if (error) throw new Error(error.message);
  return path;
}

const cache = new Map<string, { url: string; until: number }>();
export async function hrFileUrl(path: string | null | undefined): Promise<string | null> {
  if (!path) return null;
  const hit = cache.get(path);
  if (hit && hit.until > Date.now()) return hit.url;
  const { data } = await supabase.storage.from('hr-files').createSignedUrl(path, 3600);
  if (!data?.signedUrl) return null;
  cache.set(path, { url: data.signedUrl, until: Date.now() + 50 * 60 * 1000 });
  return data.signedUrl;
}

export const EMPLOYMENT: Record<string, string> = {
  permanent: 'Tetap', contract: 'Kontrak', probation: 'Masa percobaan', intern: 'Magang', daily: 'Harian',
};
export const MARITAL: Record<string, string> = { single: 'Belum menikah', married: 'Menikah', divorced: 'Cerai hidup', widowed: 'Cerai mati' };
export const RELIGIONS = ['Islam', 'Kristen', 'Katolik', 'Hindu', 'Buddha', 'Konghucu', 'Lainnya'];
export const DOC_TYPES: Record<string, string> = { ktp: 'KTP', kk: 'Kartu Keluarga', kontrak: 'Kontrak kerja', ijazah: 'Ijazah', sertifikat: 'Sertifikat', npwp: 'NPWP', bpjs: 'Kartu BPJS', lainnya: 'Lainnya' };

export interface Employee {
  id: string; company_id: string; employee_number: string; user_id: string | null;
  full_name: string; nickname: string | null; photo_path: string | null; gender: 'L' | 'P' | null;
  birth_place: string | null; birth_date: string | null; religion: string | null; marital_status: string | null; blood_type: string | null;
  national_id: string | null; tax_number: string | null; bpjs_kesehatan: string | null; bpjs_ketenagakerjaan: string | null;
  phone: string | null; email: string | null; address_ktp: string | null; address_domicile: string | null;
  emergency_name: string | null; emergency_relation: string | null; emergency_phone: string | null;
  department_id: string | null; position_id: string | null; outlet_id: string | null; manager_id: string | null;
  employment_status: string; join_date: string | null; contract_end_date: string | null; resign_date: string | null; is_active: boolean;
  education: { level?: string; school?: string; major?: string; year?: string }[];
  experience: { company?: string; position?: string; from?: string; to?: string }[];
  notes: string | null;
}
