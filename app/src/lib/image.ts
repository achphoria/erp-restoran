import { supabase } from './supabase';

// Perkecil foto di browser (maks 800px, WebP) supaya ringan dibuka dari HP tamu
export async function resizeImage(file: File, maxSize = 800): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxSize / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext('2d')!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Gagal memproses gambar'))), 'image/webp', 0.82));
}

async function uploadImage(bucket: string, path: string, file: File, maxSize: number): Promise<string> {
  if (!file.type.startsWith('image/')) throw new Error('File harus berupa gambar');
  const blob = await resizeImage(file, maxSize);
  const { error } = await supabase.storage.from(bucket).upload(path, blob, { contentType: 'image/webp' });
  if (error) throw new Error(error.message);
  return supabase.storage.from(bucket).getPublicUrl(path).data.publicUrl;
}

// menu-images/<company_id>/<acak>.webp
export const uploadMenuImage = (companyId: string, file: File) =>
  uploadImage('menu-images', `${companyId}/${crypto.randomUUID()}.webp`, file, 800);

// company-assets/<company_id>/logo/<acak>.webp
export const uploadCompanyLogo = (companyId: string, file: File) =>
  uploadImage('company-assets', `${companyId}/logo/${crypto.randomUUID()}.webp`, file, 512);

// company-assets/<company_id>/avatars/<user_id>-<acak>.webp
export const uploadAvatar = (companyId: string, userId: string, file: File) =>
  uploadImage('company-assets', `${companyId}/avatars/${userId}-${crypto.randomUUID().slice(0, 8)}.webp`, file, 400);
