import { useCallback, useEffect, useRef, useState } from 'react';
import { Camera, CheckSquare, ExternalLink, Link2, Plus, Send, Square, Trash2, X } from 'lucide-react';
import { Link } from 'react-router-dom';
import Modal from '../Modal';
import Avatar from '../Avatar';
import { useFeedback } from '../Feedback';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatDateTime } from '../../lib/format';
import { PRIORITY, STATUS_LABEL, taskFileUrl, uploadTaskFile, type ChecklistItem, type Task, type TaskStatus } from '../../lib/tasks';

/* eslint-disable @typescript-eslint/no-explicit-any */
export interface People { users: { id: string; full_name: string; role: string | null }[]; roles: { id: string; name: string }[] }

// Detail / buat tugas. Pembuat & manajer mengubah semua isi; penerima mencentang checklist, foto bukti, komentar & geser status.
export default function TaskModal({ taskId, companyId, people, outlets, defaults, onClose, onChanged }: {
  taskId: string | null; companyId: string; people: People; outlets: { id: string; name: string }[];
  defaults?: Partial<Task>; onClose: () => void; onChanged: () => void;
}) {
  const { toast, prompt } = useFeedback();
  const [task, setTask] = useState<Task | null>(null);
  const [form, setForm] = useState<any>(() => ({ title: '', description: '', priority: 'normal', assignee: '', outlet_id: '', due_date: '',
    labels: '', checklist: [] as ChecklistItem[], requires_photo: false, link_label: '', link_url: '', ...defaults }));
  const [newItem, setNewItem] = useState('');
  const [comment, setComment] = useState('');
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const closeRef = useRef(onClose);
  useEffect(() => { closeRef.current = onClose; });

  const load = useCallback(async () => {
    if (!taskId) return;
    const t = await rpc<Task>('hr_task_detail', { p_id: taskId });
    if (!t) { toast('Tugas tidak ditemukan', 'error'); closeRef.current(); return; }
    setTask(t);
    setForm({ title: t.title, description: t.description, priority: t.priority, outlet_id: t.outlet_id ?? '', due_date: t.due_date ?? '',
      assignee: t.assignee_id ? `u:${t.assignee_id}` : t.assignee_role_id ? `r:${t.assignee_role_id}` : '',
      labels: t.labels.join(', '), checklist: t.checklist, requires_photo: t.requires_photo, link_label: t.link_label ?? '', link_url: t.link_url ?? '' });
  }, [taskId, toast]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const isNew = !taskId;
  const canEdit = isNew || !!task?.roles.manager;
  const canCheck = canEdit || !!task?.roles.doer;
  const payload = (checklist = form.checklist) => ({
    id: task?.id, title: form.title, description: form.description, priority: form.priority, outlet_id: form.outlet_id || null, due_date: form.due_date || null,
    assignee_id: form.assignee.startsWith('u:') ? form.assignee.slice(2) : null, assignee_role_id: form.assignee.startsWith('r:') ? form.assignee.slice(2) : null,
    labels: String(form.labels).split(',').map((s: string) => s.trim()).filter(Boolean), checklist, requires_photo: form.requires_photo,
    link_label: form.link_label, link_url: form.link_url || null,
  });

  const save = async () => {
    setBusy(true);
    try {
      await rpc('hr_task_save', { p: payload() });
      toast(isNew ? 'Tugas dibuat' : 'Tugas disimpan', 'success');
      onChanged();
      onClose();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  // centang checklist langsung tersimpan (untuk tugas yang sudah ada)
  const toggle = async (i: number) => {
    const checklist = form.checklist.map((c: ChecklistItem, j: number) => (j === i ? { ...c, done: !c.done } : c));
    setForm({ ...form, checklist });
    if (isNew) return;
    try { await rpc('hr_task_save', { p: { ...payload(checklist), ...(canEdit ? {} : { title: task!.title }) } }); onChanged(); } catch (e) { toast(errorMessage(e), 'error'); load(); }
  };
  const move = async (status: TaskStatus) => {
    let note: string | null = null;
    if (task?.status === 'review' && (status === 'in_progress' || status === 'new') && !task.roles.self_task) {
      note = await prompt({ title: 'Kembalikan tugas', label: 'Apa yang perlu diperbaiki?', required: true, confirmLabel: 'Kembalikan' });
      if (note === null) return;
    }
    try {
      await rpc('hr_task_move', { p_id: task!.id, p_status: status, p_note: note });
      toast(`Dipindah ke ${STATUS_LABEL[status]}`, 'success');
      onChanged();
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const addPhoto = async (f: File | undefined) => {
    if (!f || !task) return;
    setBusy(true);
    try {
      const path = await uploadTaskFile(companyId, 'tasks', task.id, f);
      await rpc('hr_task_photo', { p_id: task.id, p_path: path });
      onChanged();
      load();
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };
  const removePhoto = async (path: string) => {
    try { await rpc('hr_task_photo', { p_id: task!.id, p_path: path, p_remove: true }); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const send = async () => {
    if (!comment.trim()) return;
    try { await rpc('hr_task_comment', { p_id: task!.id, p_body: comment }); setComment(''); onChanged(); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  // tombol pindah status sesuai peran
  const actions: { to: TaskStatus; label: string; primary?: boolean }[] = [];
  if (task) {
    const { manager, doer, self_task } = task.roles;
    const s = task.status;
    if (s === 'new' && (doer || manager)) actions.push({ to: 'in_progress', label: task.assignee_id ? 'Mulai kerjakan' : 'Ambil & kerjakan', primary: true });
    if (s === 'in_progress' && (doer || manager)) {
      if (self_task) actions.push({ to: 'done', label: 'Tandai selesai', primary: true });
      else actions.push({ to: 'review', label: 'Ajukan review', primary: true });
    }
    if (s === 'review' && manager) { actions.push({ to: 'in_progress', label: 'Kembalikan' }); actions.push({ to: 'done', label: 'Setujui selesai', primary: true }); }
    if ((s === 'done' || s === 'new') && manager) actions.push({ to: 'archived', label: 'Arsipkan' });
    if (s === 'archived' && manager) actions.push({ to: 'new', label: 'Pulihkan' });
    if (s === 'done' && manager) actions.push({ to: 'in_progress', label: 'Buka lagi' });
  }
  const doneCount = form.checklist.filter((c: ChecklistItem) => c.done).length;

  return (
    <Modal large title={isNew ? 'Tugas baru' : `${task?.task_number ?? ''} · ${STATUS_LABEL[task?.status ?? 'new']}`} onClose={onClose}
      footer={<>
        <button onClick={onClose}>Tutup</button>
        {!isNew && actions.map((a) => <button key={a.to} className={a.primary ? 'btn-primary' : ''} onClick={() => move(a.to)}>{a.label}</button>)}
        {canEdit && <button className={isNew ? 'btn-primary' : ''} disabled={busy || !form.title.trim()} onClick={save}>{isNew ? 'Buat tugas' : 'Simpan perubahan'}</button>}
      </>}>
      <div className="task-detail">
        <div className="task-main">
          {canEdit
            ? <input className="task-title-input" value={form.title} placeholder="Judul tugas, mis. Cek suhu chiller" onChange={(e) => setForm({ ...form, title: e.target.value })} />
            : <h2 className="task-title">{task?.title}</h2>}
          {canEdit
            ? <textarea rows={3} value={form.description} placeholder="Detail / cara mengerjakan (opsional)" onChange={(e) => setForm({ ...form, description: e.target.value })} />
            : task?.description && <p className="task-desc">{task.description}</p>}

          <div className="task-section">
            <div className="task-section-title"><CheckSquare size={15} /> Checklist {form.checklist.length > 0 && <span className="muted">{doneCount}/{form.checklist.length}</span>}</div>
            {form.checklist.map((c: ChecklistItem, i: number) => (
              <div key={i} className={`task-check ${c.done ? 'done' : ''}`}>
                <button type="button" className="task-check-box" disabled={!canCheck} onClick={() => toggle(i)} aria-label={c.done ? 'Batal centang' : 'Centang'}>
                  {c.done ? <CheckSquare size={18} /> : <Square size={18} />}
                </button>
                <span>{c.text}</span>
                {canEdit && <button type="button" className="btn-sm task-check-del" onClick={() => setForm({ ...form, checklist: form.checklist.filter((_: ChecklistItem, j: number) => j !== i) })} aria-label="Hapus item"><X size={13} /></button>}
              </div>
            ))}
            {canEdit && (
              <div className="row" style={{ gap: 6 }}>
                <input value={newItem} placeholder="Tambah langkah…" onChange={(e) => setNewItem(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && newItem.trim()) { e.preventDefault(); setForm({ ...form, checklist: [...form.checklist, { text: newItem.trim(), done: false }] }); setNewItem(''); } }} />
                <button type="button" className="btn-sm" disabled={!newItem.trim()} onClick={() => { setForm({ ...form, checklist: [...form.checklist, { text: newItem.trim(), done: false }] }); setNewItem(''); }}><Plus size={14} /></button>
              </div>
            )}
          </div>

          {!isNew && (task?.requires_photo || (task?.photo_paths.length ?? 0) > 0 || canCheck) && (
            <div className="task-section">
              <div className="task-section-title"><Camera size={15} /> Foto bukti {task?.requires_photo && <span className="badge badge-warning">wajib</span>}</div>
              <div className="task-photos">
                {task?.photo_paths.map((p) => <TaskPhoto key={p} path={p} onRemove={canEdit || task.roles.doer ? () => removePhoto(p) : undefined} />)}
                {canCheck && task?.status !== 'done' && task?.status !== 'archived' && (
                  <button type="button" className="task-photo-add" disabled={busy} onClick={() => fileRef.current?.click()}><Camera size={20} /><span>{busy ? 'Mengunggah…' : 'Ambil foto'}</span></button>
                )}
              </div>
              <input ref={fileRef} type="file" accept="image/*" capture="environment" hidden onChange={(e) => { addPhoto(e.target.files?.[0]); e.target.value = ''; }} />
            </div>
          )}

          {!isNew && task && (
            <div className="task-section">
              <div className="task-section-title">Komentar & riwayat</div>
              <div className="task-thread">
                {task.comments?.map((c) => c.kind === 'event'
                  ? <div key={c.id} className="task-event"><b>{c.user ?? 'Sistem'}</b> {c.body} <span className="muted">· {formatDateTime(c.created_at)}</span></div>
                  : <div key={c.id} className="task-comment"><Avatar name={c.user ?? '?'} src={c.avatar_url} size={26} /><div><b>{c.user}</b> <span className="muted small">{formatDateTime(c.created_at)}</span><p>{c.body}</p></div></div>)}
              </div>
              <div className="row" style={{ gap: 6 }}>
                <input value={comment} placeholder="Tulis komentar…" onChange={(e) => setComment(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); send(); } }} />
                <button type="button" className="btn-sm btn-primary" disabled={!comment.trim()} onClick={send} aria-label="Kirim"><Send size={14} /></button>
              </div>
            </div>
          )}
        </div>

        <aside className="task-side">
          <label className="field"><span>Untuk</span>
            {canEdit ? (
              <select value={form.assignee} onChange={(e) => setForm({ ...form, assignee: e.target.value })}>
                <option value="">Saya sendiri / belum ditentukan</option>
                <optgroup label="Tim (semua anggota role)">{people.roles.map((r) => <option key={r.id} value={`r:${r.id}`}>Tim {r.name}</option>)}</optgroup>
                <optgroup label="Orang">{people.users.map((u) => <option key={u.id} value={`u:${u.id}`}>{u.full_name}{u.role ? ` · ${u.role}` : ''}</option>)}</optgroup>
              </select>
            ) : <b>{task?.assignee ?? (task?.assignee_role ? `Tim ${task.assignee_role}` : '—')}</b>}
          </label>
          <label className="field"><span>Prioritas</span>
            {canEdit ? (
              <select value={form.priority} onChange={(e) => setForm({ ...form, priority: e.target.value })}>
                {Object.entries(PRIORITY).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
              </select>
            ) : <b style={{ color: PRIORITY[task?.priority ?? 'normal'].color }}>{PRIORITY[task?.priority ?? 'normal'].label}</b>}
          </label>
          <label className="field"><span>Tenggat</span>
            {canEdit ? <input type="date" value={form.due_date} onChange={(e) => setForm({ ...form, due_date: e.target.value })} />
              : <b>{task?.due_date ? new Date(`${task.due_date}T00:00:00Z`).toLocaleDateString('id-ID', { dateStyle: 'medium', timeZone: 'UTC' }) : '—'}</b>}
          </label>
          <label className="field"><span>Outlet</span>
            {canEdit ? (
              <select value={form.outlet_id} onChange={(e) => setForm({ ...form, outlet_id: e.target.value })}>
                <option value="">Semua / kantor pusat</option>
                {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
              </select>
            ) : <b>{task?.outlet ?? '—'}</b>}
          </label>
          <label className="field"><span>Label</span>
            {canEdit ? <input value={form.labels} placeholder="kebersihan, dapur" onChange={(e) => setForm({ ...form, labels: e.target.value })} />
              : <div className="task-labels">{task?.labels.map((l) => <span key={l} className="task-label">{l}</span>)}{!task?.labels.length && '—'}</div>}
          </label>
          {canEdit && <label className="row"><input type="checkbox" checked={form.requires_photo} onChange={(e) => setForm({ ...form, requires_photo: e.target.checked })} /> Wajib foto bukti</label>}
          <div className="field"><span><Link2 size={13} /> Tautan dokumen</span>
            {canEdit ? (
              <>
                <input value={form.link_label} placeholder="mis. PO/20261009/0003" onChange={(e) => setForm({ ...form, link_label: e.target.value })} />
                <input value={form.link_url} placeholder="/purchasing?tab=po (opsional)" onChange={(e) => setForm({ ...form, link_url: e.target.value })} />
              </>
            ) : task?.link_label ? (task.link_url ? <Link to={task.link_url} onClick={onClose}><ExternalLink size={13} /> {task.link_label}</Link> : <b>{task.link_label}</b>) : '—'}
          </div>
          {task && <p className="muted small" style={{ margin: 0 }}>Dibuat {task.creator ?? '—'} · {formatDateTime(task.created_at)}</p>}
        </aside>
      </div>
    </Modal>
  );
}

function TaskPhoto({ path, onRemove }: { path: string; onRemove?: () => void }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    taskFileUrl(path).then((u) => { if (alive) setUrl(u); }).catch(() => undefined);
    return () => { alive = false; };
  }, [path]);
  return (
    <div className="task-photo">
      {url ? <a href={url} target="_blank" rel="noreferrer"><img src={url} alt="Foto bukti" /></a> : <div className="task-photo-empty" />}
      {onRemove && <button type="button" className="btn-sm" onClick={onRemove} aria-label="Hapus foto"><Trash2 size={12} /></button>}
    </div>
  );
}
