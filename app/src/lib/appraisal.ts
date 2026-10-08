// Penilaian kinerja: skala 1-5, kriteria 'rating' (dinilai) & 'auto' (dihitung dari data)
export interface Criterion { key: string; name: string; description?: string; weight: number; kind: 'rating' | 'auto'; metric?: MetricKey }
export type MetricKey = 'attendance' | 'punctuality' | 'tasks' | 'sop';
export type Scores = Record<string, { score?: number; note?: string }>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Metrics = Record<MetricKey, any>;

export const SCALE: Record<number, string> = { 1: 'Kurang', 2: 'Perlu perbaikan', 3: 'Cukup', 4: 'Baik', 5: 'Istimewa' };
export const GRADES: Record<string, { label: string; color: string }> = {
  A: { label: 'Istimewa', color: '#1f9d6b' }, B: { label: 'Baik', color: '#4ABDAC' }, C: { label: 'Cukup', color: '#F7B733' },
  D: { label: 'Perlu perbaikan', color: '#FC4A1A' }, E: { label: 'Kurang', color: '#b3261e' },
};
export const METRICS: Record<MetricKey, { label: string; explain: (m: any) => string }> = { // eslint-disable-line @typescript-eslint/no-explicit-any
  attendance: { label: 'Kehadiran', explain: (m) => (m?.scheduled ? `${m.present}/${m.scheduled} hari terjadwal hadir` : 'Belum ada jadwal shift di periode ini') },
  punctuality: { label: 'Ketepatan waktu', explain: (m) => (m?.present ? `${m.on_time}/${m.present} hari tidak telat` : 'Belum ada data absen') },
  tasks: { label: 'Tugas selesai tepat waktu', explain: (m) => (m && m.done + m.overdue > 0 ? `${m.on_time} tepat waktu dari ${m.done} selesai${m.overdue ? `, ${m.overdue} lewat tenggat` : ''}` : 'Belum ada tugas dengan data') },
  sop: { label: 'Kepatuhan SOP', explain: (m) => (m?.runs ? `rata-rata ${Math.round(Number(m.rate) * 100)}% dari ${m.runs} checklist` : 'Belum ada SOP harian') },
};
export const STATUS: Record<string, [string, string]> = {
  self: ['Penilaian diri', 'badge-info'], manager: ['Dinilai atasan', 'badge-warning'], acknowledge: ['Menunggu konfirmasi', 'badge-info'], done: ['Selesai', 'badge-success'],
};
export const SAMPLE_CRITERIA: Criterion[] = [
  { key: 'hadir', name: 'Kehadiran', kind: 'auto', metric: 'attendance', weight: 15 },
  { key: 'tepat', name: 'Ketepatan waktu', kind: 'auto', metric: 'punctuality', weight: 15 },
  { key: 'tugas', name: 'Penyelesaian tugas', kind: 'auto', metric: 'tasks', weight: 15 },
  { key: 'sop', name: 'Kepatuhan SOP', kind: 'auto', metric: 'sop', weight: 10 },
  { key: 'kualitas', name: 'Kualitas kerja', description: 'Hasil kerja rapi, sesuai standar resep / SOP', kind: 'rating', weight: 15 },
  { key: 'layanan', name: 'Pelayanan pelanggan', description: 'Ramah, cepat, menangani keluhan dengan baik', kind: 'rating', weight: 10 },
  { key: 'tim', name: 'Kerja sama tim', description: 'Membantu rekan, komunikasi baik', kind: 'rating', weight: 10 },
  { key: 'inisiatif', name: 'Inisiatif & tanggung jawab', description: 'Proaktif, jujur, menjaga aset', kind: 'rating', weight: 10 },
];

// sama dengan hr_appraisal_score di server (untuk pratinjau)
export function previewScore(criteria: Criterion[], scores: Scores, metrics: Metrics | null | undefined) {
  let sum = 0;
  let w = 0;
  for (const c of criteria) {
    const s = c.kind === 'auto' ? metrics?.[c.metric!]?.score : scores[c.key]?.score;
    if (s == null || s === 0) continue;
    sum += Number(c.weight) * Number(s);
    w += Number(c.weight);
  }
  if (!w) return { score: null as number | null, grade: null as string | null };
  const score = Math.round((sum / w) * 100) / 100;
  return { score, grade: score >= 4.5 ? 'A' : score >= 3.75 ? 'B' : score >= 3 ? 'C' : score >= 2 ? 'D' : 'E' };
}
