const rupiah = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
const number = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 2 });

export const formatRupiah = (value: number | string | null | undefined) => rupiah.format(Number(value ?? 0));
export const formatNumber = (value: number | string | null | undefined) => number.format(Number(value ?? 0));

export const formatDateTime = (value: string | null | undefined) =>
  value ? new Date(value).toLocaleString('id-ID', { dateStyle: 'medium', timeStyle: 'short' }) : '-';

export const formatTime = (value: string | null | undefined) =>
  value ? new Date(value).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' }) : '-';

export const todayISO = () => {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
};

export const SALES_CHANNELS: Record<string, string> = {
  dine_in: 'Dine In',
  takeaway: 'Take Away',
  gofood: 'GoFood',
  grabfood: 'GrabFood',
};

export const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e));
