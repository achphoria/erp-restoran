import { useCallback, useEffect, useMemo, useState } from 'react';
import { Info, Lock } from 'lucide-react';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { APPROVAL_DOCS, MODULE_PERMS } from './approvalCatalog';

interface Rule { id: string; document_type: string; min_amount: number; is_enabled: boolean }
interface Role { id: string; code: string; name: string; permissions: string[] }

// Satu tempat untuk mengatur approval tiap transaksi: aktif/tidak, batas nominal,
// role pembuat, dan role penyetuju (1 tingkat)
export default function ApprovalMatrixTab() {
  const { toast, confirm } = useFeedback();
  const { can } = useAuth();
  const [rules, setRules] = useState<Rule[]>([]);
  const [roles, setRoles] = useState<Role[]>([]);
  const [origRules, setOrigRules] = useState<Rule[]>([]);
  const [origRoles, setOrigRoles] = useState<Role[]>([]);
  const [busy, setBusy] = useState(false);
  const canRoles = can('user.manage');

  const load = useCallback(async () => {
    const [ru, ro] = await Promise.all([
      must(supabase.from('sys_approval_rules').select('id, document_type, min_amount, is_enabled')),
      must(supabase.from('sys_roles').select('id, code, name, permissions').order('created_at')),
    ]);
    setRules(ru); setOrigRules(ru); setRoles(ro); setOrigRoles(ro);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const isOwner = (r: Role) => r.permissions.includes('*');
  const has = (r: Role, perms: string[]) => isOwner(r) || perms.some((p) => r.permissions.includes(p));
  const togglePerm = (roleId: string, perm: string, on: boolean) => setRoles(roles.map((r) => r.id !== roleId ? r
    : { ...r, permissions: on ? [...new Set([...r.permissions, perm])] : r.permissions.filter((p) => p !== perm) }));
  const setRule = (type: string, patch: Partial<Rule>) => setRules(rules.map((r) => (r.document_type === type ? { ...r, ...patch } : r)));

  const dirtyRules = rules.filter((r) => { const o = origRules.find((x) => x.id === r.id); return o && (o.is_enabled !== r.is_enabled || Number(o.min_amount) !== Number(r.min_amount)); });
  const dirtyRoles = roles.filter((r) => { const o = origRoles.find((x) => x.id === r.id); return o && JSON.stringify([...o.permissions].sort()) !== JSON.stringify([...r.permissions].sort()); });
  const dirty = dirtyRules.length + dirtyRoles.length;

  // hak modul yang dicabut dari matriks: peringatkan karena berlaku untuk seluruh modul
  const revokedModules = useMemo(() => dirtyRoles.flatMap((r) => {
    const o = origRoles.find((x) => x.id === r.id)!;
    return o.permissions.filter((p) => MODULE_PERMS[p] && !r.permissions.includes(p)).map((p) => `${r.name}: ${MODULE_PERMS[p]}`);
  }), [dirtyRoles, origRoles]);

  const save = async () => {
    if (revokedModules.length && !(await confirm({
      title: 'Cabut akses modul?', confirmLabel: 'Ya, simpan',
      message: <>Hak "pembuat" berlaku untuk seluruh modul:<ul>{revokedModules.map((m) => <li key={m}>{m}</li>)}</ul></>,
    }))) return;
    setBusy(true);
    try {
      for (const r of dirtyRules) await must(supabase.from('sys_approval_rules').update({ is_enabled: r.is_enabled, min_amount: Number(r.min_amount) || 0 }).eq('id', r.id));
      for (const r of dirtyRoles) await must(supabase.from('sys_roles').update({ permissions: r.permissions }).eq('id', r.id));
      toast('Pengaturan approval disimpan');
      await load();
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  const groups = [...new Set(Object.values(APPROVAL_DOCS).map((d) => d.group))];

  return (
    <>
      <div className="card approval-help">
        <Info size={18} />
        <div className="small">
          <b>Cara kerja:</b> bila approval <b>aktif</b> dan nilai transaksi ≥ batas, transaksi dari <b>pembuat</b> masuk ke menu Persetujuan dan baru
          dijalankan setelah salah satu <b>penyetuju</b> menyetujui. Penyetuju tidak perlu akses modulnya.
          Role yang sekaligus pembuat & penyetuju langsung jalan tanpa approval. Owner selalu bisa semuanya.
          {!canRoles && <div style={{ color: 'var(--danger)' }}>Mengubah pembuat/penyetuju butuh hak "Kelola user & role".</div>}
        </div>
        <button className="btn-primary" style={{ marginLeft: 'auto', alignSelf: 'center' }} disabled={!dirty || busy} onClick={save}>Simpan perubahan {dirty ? `(${dirty})` : ''}</button>
      </div>

      {groups.map((g) => (
        <div key={g} className="card table-wrap">
          <div className="section-title" style={{ marginTop: 0 }}>{g}</div>
          <table className="table approval-matrix">
            <thead><tr><th style={{ width: '22%' }}>Transaksi</th><th style={{ width: 90 }}>Approval</th><th style={{ width: 170 }}>Batas nominal</th><th>Dibuat oleh</th><th>Disetujui oleh</th></tr></thead>
            <tbody>
              {Object.entries(APPROVAL_DOCS).filter(([, d]) => d.group === g).map(([type, d]) => {
                const rule = rules.find((r) => r.document_type === type);
                if (!rule) return null;
                const Icon = d.icon;
                const approvePerm = `approval.${type}`;
                const editableCreator = d.creatorPerms.length === 1;
                const both = roles.filter((r) => !isOwner(r) && has(r, d.creatorPerms) && r.permissions.includes(approvePerm));
                return (
                  <tr key={type} style={{ opacity: rule.is_enabled ? 1 : 0.7 }}>
                    <td><div className="row" style={{ flexWrap: 'nowrap', gap: 8 }}><Icon size={16} style={{ flexShrink: 0 }} /><b>{d.label}</b></div>
                      <div className="muted small">{d.desc}</div></td>
                    <td><label className="switch"><input type="checkbox" checked={rule.is_enabled} onChange={(e) => setRule(type, { is_enabled: e.target.checked })} /></label></td>
                    <td>{d.amountLabel
                      ? <><MoneyInput value={rule.min_amount} style={{ width: 150 }} disabled={!rule.is_enabled} onChange={(v) => setRule(type, { min_amount: Number(v || 0) })} />
                          <div className="muted small">{d.amountLabel}</div></>
                      : <span className="muted small">Semua</span>}</td>
                    <td>
                      <div className="chip-list">
                        {roles.map((r) => {
                          const on = has(r, d.creatorPerms);
                          return (
                            <button key={r.id} type="button" className={`role-chip ${on ? 'on' : ''}`} disabled={isOwner(r) || !editableCreator || !canRoles}
                              title={isOwner(r) ? 'Owner selalu punya akses' : !editableCreator ? 'Diatur dari hak akses modul di tab Role' : MODULE_PERMS[d.creatorPerms[0]]}
                              onClick={() => togglePerm(r.id, d.creatorPerms[0], !on)}>
                              {isOwner(r) && <Lock size={11} />}{r.name}
                            </button>
                          );
                        })}
                      </div>
                    </td>
                    <td>
                      <div className="chip-list">
                        {roles.map((r) => {
                          const on = isOwner(r) || r.permissions.includes(approvePerm);
                          return (
                            <button key={r.id} type="button" className={`role-chip approver ${on ? 'on' : ''}`} disabled={isOwner(r) || !canRoles}
                              onClick={() => togglePerm(r.id, approvePerm, !on)}>
                              {isOwner(r) && <Lock size={11} />}{r.name}
                            </button>
                          );
                        })}
                      </div>
                      {rule.is_enabled && !!both.length && <div className="small" style={{ color: 'var(--warning)', marginTop: 4 }}>
                        {both.map((r) => r.name).join(', ')}: pembuat sekaligus penyetuju → langsung jalan</div>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ))}
    </>
  );
}
