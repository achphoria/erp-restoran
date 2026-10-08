import { lazy, type ComponentType } from 'react';

// Setelah deploy baru, file halaman versi lama di server sudah dihapus. Tab yang masih terbuka
// gagal memuat halaman berikutnya -> dulu layar jadi putih. Sekarang: muat ulang sekali untuk mengambil versi terbaru.
const KEY = 'semar.chunk-reload';

export function isChunkError(e: unknown) {
  const msg = String((e as Error)?.message ?? e);
  return /dynamically imported module|Importing a module script failed|error loading dynamically imported|Unable to preload CSS|ChunkLoadError/i.test(msg);
}

// true = sedang memuat ulang; false = baru saja dicoba (hindari muat ulang berulang-ulang)
export function reloadForNewVersion() {
  try {
    if (Date.now() - Number(sessionStorage.getItem(KEY) || 0) < 15_000) return false;
    sessionStorage.setItem(KEY, String(Date.now()));
  } catch { /* storage diblokir: tetap coba muat ulang */ }
  window.location.reload();
  return true;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function lazyRetry<T extends ComponentType<any>>(factory: () => Promise<{ default: T }>) {
  return lazy(() => factory().catch((e) => {
    if (isChunkError(e) && reloadForNewVersion()) return new Promise<never>(() => undefined);
    throw e;
  }));
}
