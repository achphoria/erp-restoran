import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { useNotice } from '../components/Feedback';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import type { Employee } from '../lib/hr';
import EmployeesTab from '../components/hr/EmployeesTab';
import StructureTab from '../components/hr/StructureTab';
import AnnouncementsTab from '../components/hr/AnnouncementsTab';
import RosterTab from '../components/hr/RosterTab';
import AttendanceTab from '../components/hr/AttendanceTab';
import type { Lookups } from '../components/hr/EmployeeForm';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Tab = 'employees' | 'roster' | 'attendance' | 'structure' | 'announcements';

// Modul SDM / HR: data karyawan, jadwal shift, absensi, struktur organisasi, pengumuman
export default function HrPage() {
  const { profile, can } = useAuth();
  const setNotice = useNotice();
  const tabs: [Tab, string, boolean][] = [
    ['employees', 'Karyawan', can(['hr.view', 'hr.manage'])],
    ['roster', 'Jadwal Shift', can(['hr.manage', 'hr.attendance'])],
    ['attendance', 'Absensi', can(['hr.view', 'hr.manage', 'hr.attendance'])],
    ['structure', 'Jabatan & Departemen', can('hr.manage')],
    ['announcements', 'Pengumuman', can('hr.manage')],
  ];
  const visible = tabs.filter(([, , ok]) => ok);
  const [tab, setTab] = useTabParam<Tab>(visible[0]?.[0] ?? 'employees', visible.map(([k]) => k));
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [lookups, setLookups] = useState<Lookups>({ departments: [], positions: [], outlets: [], roles: [], employees: [], users: [] });
  const [reminders, setReminders] = useState<any>({});
  const [ann, setAnn] = useState<any[]>([]);
  const [stats, setStats] = useState<Record<string, number>>({});
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      const [emp, dep, pos, out, rol, rem] = await Promise.all([
        must(supabase.from('hr_employees').select('*').order('full_name')),
        must(supabase.from('hr_departments').select('*').order('name')),
        must(supabase.from('hr_positions').select('*').order('name')),
        must(supabase.from('sys_outlets').select('id, name, brand_id').eq('is_active', true).order('name')),
        must(supabase.from('sys_roles').select('id, name, code, permissions').order('name')),
        rpc<any>('hr_reminders'),
      ]);
      const users = can('user.manage') ? await rpc<any[]>('sys_list_users') : [];
      setEmployees(emp);
      setLookups({ departments: dep, positions: pos, outlets: out, roles: rol, employees: emp, users });
      setReminders(rem ?? {});
      if (can('hr.manage')) {
        const [a, st] = await Promise.all([must(supabase.from('hr_announcements').select('*').order('published_at', { ascending: false })), rpc<Record<string, number>>('hr_announcement_stats')]);
        setAnn(a);
        setStats(st ?? {});
      }
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [can]);
  useEffect(() => { load(); }, [load]);

  const changed = (msg?: string) => { if (msg) setNotice(msg); load(); };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>SDM / HR</h1>
          <p>Karyawan, jadwal shift, absensi & pengumuman · {profile?.company_name}</p>
        </div>
      </div>
      <div className="tabs">{visible.map(([k, v]) => <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>)}</div>
      {error && <div className="alert alert-error">{error}</div>}
      {tab === 'employees' && <EmployeesTab employees={employees} lookups={lookups} reminders={reminders} onChanged={changed} />}
      {tab === 'roster' && <RosterTab companyId={profile!.company_id} outlets={lookups.outlets} />}
      {tab === 'attendance' && <AttendanceTab companyId={profile!.company_id} outlets={lookups.outlets} />}
      {tab === 'structure' && <StructureTab companyId={profile!.company_id} departments={lookups.departments} positions={lookups.positions} roles={lookups.roles} employees={employees} onChanged={load} />}
      {tab === 'announcements' && <AnnouncementsTab companyId={profile!.company_id} items={ann} stats={stats} outlets={lookups.outlets} roles={lookups.roles} onChanged={load} />}
    </>
  );
}
