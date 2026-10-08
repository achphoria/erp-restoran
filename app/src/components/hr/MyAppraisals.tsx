import { useCallback, useEffect, useState } from 'react';
import { Award } from 'lucide-react';
import AppraisalForm from './AppraisalForm';
import { rpc } from '../../lib/supabase';
import { GRADES } from '../../lib/appraisal';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Beranda Saya: penilaian diri, hasil penilaian saya, dan bawahan yang perlu saya nilai
export default function MyAppraisals() {
  const [list, setList] = useState<any[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const load = useCallback(async () => setList(await rpc<any[]>('hr_my_appraisals')), []);
  useEffect(() => { load().catch(() => undefined); }, [load]);
  if (!list.length) return null;

  const action = (a: any): [string, boolean] => {
    if (a.access === 'self') return a.status === 'self' ? ['Isi penilaian diri', true] : a.status === 'acknowledge' ? ['Lihat hasil & konfirmasi', true] : a.status === 'done' ? ['Lihat hasil', false] : ['Menunggu atasan', false];
    return a.status === 'manager' ? ['Nilai sekarang', true] : a.status === 'self' ? ['Menunggu penilaian diri', false] : ['Lihat', false];
  };
  const todo = list.filter((a) => action(a)[1]).length;

  return (
    <div className={`card me-appr ${todo ? 'todo' : ''}`}>
      <div className="me-card-title"><Award size={16} /> Penilaian kinerja {todo > 0 && <span className="badge badge-danger">{todo}</span>}</div>
      <div className="me-hist">
        {list.slice(0, 6).map((a) => {
          const [label, primary] = action(a);
          return (
            <div key={a.id} className="me-hist-row">
              <span><b>{a.access === 'self' ? 'Penilaian saya' : a.full_name}</b><br /><small className="muted">{a.period}</small></span>
              <span className="row">
                {a.grade && <span className="appr-grade-chip" style={{ background: GRADES[a.grade].color }} title={GRADES[a.grade].label}>{a.grade}</span>}
                <button className={`btn-sm ${primary ? 'btn-primary' : ''}`} onClick={() => setOpen(a.id)}>{label}</button>
              </span>
            </div>
          );
        })}
      </div>
      {open && <AppraisalForm id={open} onClose={() => setOpen(null)} onChanged={() => { load(); window.dispatchEvent(new Event('appraisal-changed')); }} />}
    </div>
  );
}
