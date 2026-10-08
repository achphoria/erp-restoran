// Identitas sistem (tetap, tidak bisa diganti per perusahaan).
// SEMAR: tokoh punakawan yang tampak sebagai abdi, padahal dewa yang paling bijak. Sistem yang melayani juragan.
export const APP_NAME = 'SEMAR';
export const APP_LONG_NAME = 'Sistem ERP, Manajemen, Akuntansi & Restoran';
export const APP_TAGLINE = 'Abdi setia usaha kuliner';

// nama perusahaan yang sedang login (dipakai di dokumen cetak: surat jalan, invoice)
let companyName = '';
export const getCompanyName = () => companyName;
export function setCompanyName(name?: string | null) {
  companyName = name?.trim() ?? '';
}

export const getAppName = () => APP_NAME;

export function setDocumentTitle(page?: string) {
  document.title = page ? `${page} · ${APP_NAME}` : `${APP_NAME} · ${APP_TAGLINE}`;
}
