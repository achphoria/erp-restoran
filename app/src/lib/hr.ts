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

// ---------------------------------------------------------------- absensi
export interface GpsFix { lat: number; lng: number; accuracy: number }
// lokasi GPS akurasi tinggi (izin lokasi diminta browser)
export function getGps(timeout = 15000): Promise<GpsFix> {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) { reject(new Error('Perangkat ini tidak mendukung GPS')); return; }
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: Math.round(p.coords.accuracy) }),
      (e) => reject(new Error(e.code === 1 ? 'Izin lokasi ditolak. Aktifkan izin lokasi untuk situs ini di pengaturan browser.'
        : e.code === 3 ? 'GPS terlalu lama merespons. Coba di tempat terbuka.' : 'Lokasi tidak bisa didapat. Pastikan GPS aktif.')),
      { enableHighAccuracy: true, timeout, maximumAge: 0 });
  });
}

// jarak perkiraan di HP (yang menentukan tetap perhitungan server)
export function distanceM(lat1: number, lng1: number, lat2: number, lng2: number) {
  const r = (d: number) => (d * Math.PI) / 180;
  const a = Math.sin(r(lat2 - lat1) / 2) ** 2 + Math.cos(r(lat1)) * Math.cos(r(lat2)) * Math.sin(r(lng2 - lng1) / 2) ** 2;
  return Math.round(2 * 6371000 * Math.asin(Math.sqrt(a)));
}

// selfie absen -> hr-files/<company>/<employee>/attendance/<tanggal>-<in|out>-<acak>.jpg
export async function uploadAttendancePhoto(companyId: string, employeeId: string, workDate: string, kind: 'in' | 'out', blob: Blob): Promise<string> {
  const path = `${companyId}/${employeeId}/attendance/${workDate}-${kind}-${crypto.randomUUID().slice(0, 8)}.${blob.type === 'image/jpeg' ? 'jpg' : 'webp'}`;
  const { error } = await supabase.storage.from('hr-files').upload(path, blob, { contentType: blob.type || 'image/jpeg' });
  if (error) throw new Error(error.message);
  return path;
}

export const ATT_FLAGS: Record<string, string> = {
  outside_radius: 'Di luar radius', low_accuracy: 'GPS kurang akurat', day_off: 'Masuk di hari libur',
  no_geofence: 'Outlet belum punya titik lokasi', corrected: 'Hasil koreksi',
};
export const ATT_STATUS: Record<string, [string, string]> = {
  present: ['Hadir', 'badge-success'], late: ['Telat', 'badge-warning'], absent: ['Alpa', 'badge-danger'],
  off: ['Libur', ''], scheduled: ['Terjadwal', 'badge-info'],
};
export const fmtTime = (t: string | null | undefined) =>
  t ? new Date(t).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Jakarta' }) : '—';
export const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : '');
// tanggal lokal (WIB) dalam format YYYY-MM-DD
export const localDate = (d = new Date()) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(d);
export const addDays = (iso: string, n: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
// Senin dari minggu tanggal tsb
export const mondayOf = (iso: string) => addDays(iso, -((new Date(`${iso}T00:00:00Z`).getUTCDay() + 6) % 7));
