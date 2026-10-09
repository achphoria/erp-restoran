import { useCallback, useEffect, useMemo, useState, type CSSProperties } from 'react';
import { Camera, CheckSquare, MessageSquare, Plus, Search } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import Avatar from '../components/Avatar';
import TaskModal, { type People } from '../components/tasks/TaskModal';
import SopTab from '../components/tasks/SopTab';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import { localDate } from '../lib/hr';
import { PRIORITY, STATUSES, STATUS_LABEL, dueLabel, type Task, type TaskStatus } from '../lib/tasks';

type Tab = 'board' | 'sop';
type Scope = 'mine' | 'created' | 'all';

// Tugas: papan kanban (Baru -> Dikerjakan -> Review -> Selesai -> Arsip) & SOP harian
export default function TasksPage() {
  const { profile, can } = useAuth();
  const { toast } = useFeedback();
  const [tab, setTab] = useTabParam<Tab>('board', ['board', 'sop']);
  const [scope, setScope] = useState<Scope>('mine');
  const [outletId, setOutletId] = useState('');
  const [q, setQ] = useState('');
  const [archived, setArchived] = useState(false);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [people, setPeople] = useState<People>({ users: [], roles: [] });
  const [outlets, setOutlets] = useState<{ id: string; name: string }[]>([]);
  const [open, setOpen] = useState<string | 'new' | null>(null);
  const [dragging, setDragging] = useState<string | null>(null);
  const [over, setOver] = useState<TaskStatus | null>(null);
  const today = localDate();

  const load = useCallback(async () => {
    setTasks(await rpc<Task[]>('hr_task_board', { p_scope: scope, p_outlet_id: outletId || null, p_include_archived: archived }));
    window.dispatchEvent(new Event('tasks-changed'));
  }, [scope, outletId, archived]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);
  // tugas perawatan aset yang mendekati jatuh tempo dibuat dulu, lalu papan dimuat ulang
  useEffect(() => { rpc<number>('ast_sync_maintenance').then((n) => { if (n > 0) load(); }).catch(() => undefined); }, [load]);
  useEffect(() => {
    Promise.all([rpc<People>('hr_task_people'), must(supabase.from('sys_outlets').select('id, name').eq('is_active', true).order('name'))])
      .then(([p, o]) => { setPeople(p); setOutlets(o); }).catch(() => undefined);
  }, []);

  const shown = useMemo(() => tasks.filter((t) => !q || `${t.title} ${t.task_number} ${t.labels.join(' ')} ${t.assignee ?? ''}`.toLowerCase().includes(q.toLowerCase())), [tasks, q]);
  const columns = STATUSES.filter((s) => s.key !== 'archived' || archived);

  const drop = async (status: TaskStatus) => {
    const t = tasks.find((x) => x.id === dragging);
    setDragging(null);
    setOver(null);
    if (!t || t.status === status) return;
    // pengembalian dari Review butuh catatan -> buka detail
    if (t.status === 'review' && (status === 'in_progress' || status === 'new') && !t.roles.self_task) { setOpen(t.id); return; }
    try {
      setTasks((xs) => xs.map((x) => (x.id === t.id ? { ...x, status } : x)));
      await rpc('hr_task_move', { p_id: t.id, p_status: status });
      toast(`${t.title} → ${STATUS_LABEL[status]}`, 'success');
    } catch (e) { toast(errorMessage(e), 'error'); }
    load();
  };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Tugas</h1>
          <p>Kerjakan, ajukan review, selesai. Plus checklist SOP harian tim.</p>
        </div>
        {tab === 'board' && <button className="btn-primary" onClick={() => setOpen('new')}><Plus size={16} /> Tugas baru</button>}
      </div>
      <div className="tabs">
        <button className={tab === 'board' ? 'active' : ''} onClick={() => setTab('board')}>Papan tugas</button>
        <button className={tab === 'sop' ? 'active' : ''} onClick={() => setTab('sop')}>SOP harian</button>
      </div>

      {tab === 'board' && (
        <>
          <div className="task-toolbar">
            <div className="seg">
              {([['mine', 'Untuk saya'], ['created', 'Saya buat'], ['all', can('task.manage') ? 'Semua' : 'Semua yang terlihat']] as [Scope, string][]).map(([k, l]) => (
                <button key={k} className={scope === k ? 'active' : ''} onClick={() => setScope(k)}>{l}</button>
              ))}
            </div>
            <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
              <label className="task-search"><Search size={14} /><input value={q} placeholder="Cari tugas / label / orang" onChange={(e) => setQ(e.target.value)} /></label>
              {outlets.length > 1 && (
                <select value={outletId} onChange={(e) => setOutletId(e.target.value)}>
                  <option value="">Semua outlet</option>
                  {outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
                </select>
              )}
              <label className="row small"><input type="checkbox" checked={archived} onChange={(e) => setArchived(e.target.checked)} /> Arsip</label>
            </div>
          </div>

          <div className="kanban">
            {columns.map((col) => {
              const items = shown.filter((t) => t.status === col.key);
              return (
                <section key={col.key} className={`kanban-col ${col.key} ${over === col.key ? 'over' : ''}`}
                  onDragOver={(e) => { if (dragging) { e.preventDefault(); setOver(col.key); } }}
                  onDragLeave={() => setOver((o) => (o === col.key ? null : o))}
                  onDrop={(e) => { e.preventDefault(); drop(col.key); }}>
                  <header>
                    <b>{col.label}</b><span className="kanban-count">{items.length}</span>
                    {col.key === 'new' && <button className="btn-sm" onClick={() => setOpen('new')} aria-label="Tambah tugas"><Plus size={13} /></button>}
                  </header>
                  <small className="muted kanban-hint">{col.hint}</small>
                  <div className="kanban-list">
                    {items.map((t) => {
                      const due = t.status !== 'done' && t.status !== 'archived' ? dueLabel(t.due_date, today) : null;
                      const done = t.checklist.filter((c) => c.done).length;
                      return (
                        <article key={t.id} className={`task-card ${dragging === t.id ? 'dragging' : ''}`} draggable onDragStart={() => setDragging(t.id)} onDragEnd={() => { setDragging(null); setOver(null); }}
                          onClick={() => setOpen(t.id)} style={{ '--p': PRIORITY[t.priority].color } as CSSProperties}>
                          <div className="task-card-top">
                            <span className="muted small">{t.task_number}</span>
                            {t.priority !== 'normal' && <span className="task-prio">{PRIORITY[t.priority].label}</span>}
                          </div>
                          <b className="task-card-title">{t.title}</b>
                          {t.labels.length > 0 && <div className="task-labels">{t.labels.map((l) => <span key={l} className="task-label">{l}</span>)}</div>}
                          <div className="task-card-meta">
                            {due && <span className={`task-due ${due.tone}`}>{due.text}</span>}
                            {t.checklist.length > 0 && <span className={done === t.checklist.length ? 'ok' : ''}><CheckSquare size={12} /> {done}/{t.checklist.length}</span>}
                            {t.requires_photo && <span className={t.photo_paths.length ? 'ok' : ''}><Camera size={12} /> {t.photo_paths.length || '!'}</span>}
                            {Number(t.comment_count) > 0 && <span><MessageSquare size={12} /> {t.comment_count}</span>}
                            <span className="task-assignee">
                              {t.assignee ? <><Avatar name={t.assignee} src={t.assignee_avatar} size={20} /> {t.assignee.split(' ')[0]}</> : t.assignee_role ? <span className="task-team">Tim {t.assignee_role}</span> : null}
                            </span>
                          </div>
                          {t.outlet && !outletId && <small className="muted">{t.outlet}</small>}
                        </article>
                      );
                    })}
                    {!items.length && <div className="kanban-empty">{col.key === 'new' ? 'Belum ada tugas' : 'Kosong'}</div>}
                  </div>
                </section>
              );
            })}
          </div>
          <p className="muted small">Geser kartu ke kolom lain untuk memindahkan status (di HP: buka kartu lalu pilih tombolnya). Tugas untuk orang lain diajukan ke <b>Review</b> dulu; pembuat tugas yang menandai selesai.</p>
        </>
      )}

      {tab === 'sop' && profile && <SopTab companyId={profile.company_id} outlets={outlets} roles={people.roles} />}

      {open && profile && (
        <TaskModal taskId={open === 'new' ? null : open} companyId={profile.company_id} people={people} outlets={outlets}
          defaults={open === 'new' ? ({ outlet_id: outletId } as unknown as Partial<Task>) : undefined}
          onClose={() => setOpen(null)} onChanged={load} />
      )}
    </>
  );
}
