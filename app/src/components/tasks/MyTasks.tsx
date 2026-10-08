import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ClipboardCheck, ListTodo } from 'lucide-react';
import { rpc } from '../../lib/supabase';
import { localDate } from '../../lib/hr';
import { PRIORITY, STATUS_LABEL, dueLabel, type Task } from '../../lib/tasks';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Beranda Saya: tugas terdekat untuk saya + progres SOP hari ini
export default function MyTasks() {
  const [tasks, setTasks] = useState<Task[] | null>(null);
  const [sops, setSops] = useState<any[]>([]);
  useEffect(() => {
    Promise.all([rpc<Task[]>('hr_task_board', { p_scope: 'mine', p_outlet_id: null, p_include_archived: false }), rpc<any[]>('hr_my_sops')])
      .then(([t, s]) => { setTasks(t.filter((x) => x.status === 'new' || x.status === 'in_progress' || (x.status === 'review' && x.roles.manager && !x.roles.self_task))); setSops(s ?? []); })
      .catch(() => setTasks([]));
  }, []);
  if (!tasks) return null;
  const today = localDate();
  const open = sops.reduce((n, r) => n + r.items.filter((i: any) => !i.done).length, 0);

  return (
    <div className="card me-tasks">
      <div className="me-card-title" style={{ justifyContent: 'space-between' }}>
        <span><ListTodo size={16} /> Tugas saya {tasks.length > 0 && <span className="badge">{tasks.length}</span>}</span>
        <Link className="btn-sm" to="/tugas">Buka papan</Link>
      </div>
      {sops.length > 0 && (
        <Link to="/tugas?tab=sop" className={`me-sop-link ${open ? '' : 'done'}`}>
          <ClipboardCheck size={16} /> <span>{open ? <>SOP hari ini: <b>{open} langkah</b> belum dicentang</> : 'SOP hari ini sudah lengkap ✓'}</span>
        </Link>
      )}
      <div className="me-hist">
        {tasks.slice(0, 4).map((t) => {
          const due = dueLabel(t.due_date, today);
          return (
            <Link key={t.id} to="/tugas" className="me-hist-row me-task-row" style={{ borderLeft: `3px solid ${PRIORITY[t.priority].color}` }}>
              <span><b>{t.title}</b><br /><small className="muted">{STATUS_LABEL[t.status]}{t.assignee_role && !t.assignee ? ` · Tim ${t.assignee_role}` : ''}</small></span>
              {due && <span className={`task-due ${due.tone}`}>{due.text}</span>}
            </Link>
          );
        })}
        {!tasks.length && <p className="muted small" style={{ margin: 0 }}>Tidak ada tugas yang menunggu. 🎉</p>}
      </div>
    </div>
  );
}
