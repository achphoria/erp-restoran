// Identitas default aplikasi (logo perusahaan bisa diganti di Pengaturan > Perusahaan)
export const APP_NAME = 'Santap ERP';
export const APP_TAGLINE = 'ERP & POS Restoran';

export function setDocumentTitle(page?: string) {
  document.title = page ? `${page} · ${APP_NAME}` : `${APP_NAME} · ${APP_TAGLINE}`;
}
