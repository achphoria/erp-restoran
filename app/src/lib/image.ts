import { supabase } from './supabase';

// Perkecil foto di browser (maks 800px, WebP) supaya ringan dibuka dari HP tamu
async function resizeImage(file: File, maxSize = 800): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxSize / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext('2d')!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Gagal memproses gambar'))), 'image/webp', 0.82));
}

// Upload ke bucket menu-images/<company_id>/..., kembalikan URL publik
export async function uploadMenuImage(companyId: string, file: File): Promise<string> {
  if (!file.type.startsWith('image/')) throw new Error('File harus berupa gambar');
  const blob = await resizeImage(file);
  const path = `${companyId}/${crypto.randomUUID()}.webp`;
  const { error } = await supabase.storage.from('menu-images').upload(path, blob, { contentType: 'image/webp' });
  if (error) throw new Error(error.message);
  return supabase.storage.from('menu-images').getPublicUrl(path).data.publicUrl;
}
