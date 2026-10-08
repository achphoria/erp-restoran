import { supabase } from './supabase';
import { resizeImage } from './image';

// Tugas (kanban) & SOP harian. File bukti disimpan di bucket PRIVAT 'task-files'.
export type TaskStatus = 'new' | 'in_progress' | 'review' | 'done' | 'archived';
export interface ChecklistItem { text: string; done: boolean }
export interface Task {
  id: string; task_number: string; title: string; description: string; status: TaskStatus;
  priority: 'low' | 'normal' | 'high' | 'urgent'; outlet_id: string | null; outlet?: string | null;
  assignee_id: string | null; assignee?: string | null; assignee_avatar?: string | null;
  assignee_role_id: string | null; assignee_role?: string | null; creator?: string | null; created_by: string | null;
  due_date: string | null; labels: string[]; checklist: ChecklistItem[]; requires_photo: boolean; photo_paths: string[];
  link_label: string | null; link_url: string | null; comment_count?: number; done_at: string | null; created_at: string;
  roles: { manager: boolean; doer: boolean; self_task: boolean };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  comments?: any[];
}

export const STATUSES: { key: TaskStatus; label: string; hint: string }[] = [
  { key: 'new', label: 'Baru', hint: 'Belum dikerjakan' },
  { key: 'in_progress', label: 'Dikerjakan', hint: 'Sedang berjalan' },
  { key: 'review', label: 'Review', hint: 'Menunggu dicek pembuat' },
  { key: 'done', label: 'Selesai', hint: '30 hari terakhir' },
  { key: 'archived', label: 'Arsip', hint: 'Disimpan' },
];
export const STATUS_LABEL = Object.fromEntries(STATUSES.map((s) => [s.key, s.label])) as Record<TaskStatus, string>;
export const PRIORITY: Record<Task['priority'], { label: string; color: string }> = {
  urgent: { label: 'Mendesak', color: '#FC4A1A' },
  high: { label: 'Tinggi', color: '#F7B733' },
  normal: { label: 'Normal', color: '#4ABDAC' },
  low: { label: 'Rendah', color: '#9aa3ad' },
};

// task-files/<company>/tasks/<task_id>/<acak>.webp  atau  <company>/sop/<run_id>/<acak>.webp
export async function uploadTaskFile(companyId: string, kind: 'tasks' | 'sop', id: string, file: File | Blob): Promise<string> {
  if (!file.type.startsWith('image/')) throw new Error('File harus foto');
  const path = `${companyId}/${kind}/${id}/${crypto.randomUUID().slice(0, 8)}.webp`;
  const body = await resizeImage(file as File, 1280);
  const { error } = await supabase.storage.from('task-files').upload(path, body, { contentType: 'image/webp' });
  if (error) throw new Error(error.message);
  return path;
}

const cache = new Map<string, { url: string; until: number }>();
export async function taskFileUrl(path: string | null | undefined): Promise<string | null> {
  if (!path) return null;
  const hit = cache.get(path);
  if (hit && hit.until > Date.now()) return hit.url;
  const { data } = await supabase.storage.from('task-files').createSignedUrl(path, 3600);
  if (!data?.signedUrl) return null;
  cache.set(path, { url: data.signedUrl, until: Date.now() + 50 * 60 * 1000 });
  return data.signedUrl;
}

// tenggat: "Hari ini", "Besok", "Lewat 2 hari", "12 Okt"
export function dueLabel(due: string | null, today: string): { text: string; tone: '' | 'warn' | 'late' } | null {
  if (!due) return null;
  const diff = Math.round((Date.parse(due) - Date.parse(today)) / 864e5);
  if (diff < 0) return { text: `Lewat ${-diff} hari`, tone: 'late' };
  if (diff === 0) return { text: 'Hari ini', tone: 'warn' };
  if (diff === 1) return { text: 'Besok', tone: 'warn' };
  return { text: new Date(`${due}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', timeZone: 'UTC' }), tone: '' };
}
