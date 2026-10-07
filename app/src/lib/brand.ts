// Identitas default aplikasi. Nama & logo bisa diganti per perusahaan di Pengaturan > Perusahaan & Logo.
export const APP_NAME = 'Santap ERP';
export const APP_TAGLINE = 'ERP & POS Restoran';

const NAME_KEY = 'santap.app_name';

// nama yang dipakai saat ini; diingat di browser supaya halaman login ikut memakai nama perusahaan
let currentName: string = (() => {
  try {
    return localStorage.getItem(NAME_KEY) || APP_NAME;
  } catch {
    return APP_NAME;
  }
})();

export const getAppName = () => currentName;

export function setAppName(name?: string | null) {
  currentName = name?.trim() || APP_NAME;
  try {
    if (name?.trim()) localStorage.setItem(NAME_KEY, currentName);
    else localStorage.removeItem(NAME_KEY);
  } catch {
    /* abaikan */
  }
}

export function setDocumentTitle(page?: string) {
  document.title = page ? `${page} · ${currentName}` : `${currentName} · ${APP_TAGLINE}`;
}
