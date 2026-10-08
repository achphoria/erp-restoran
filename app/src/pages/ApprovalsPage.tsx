import { useCallback, useEffect, useState } from 'react';
import { BadgeCheck, CalendarHeart, Check, X } from 'lucide-react';
import { APPROVAL_DOCS } from '../components/settings/approvalCatalog';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime, formatRupiah } from '../lib/format';

interface ApprovalRequest {
  id: string; document_type: string; document_id: string | null; title: string; amount: number; payload: Record<string, unknown>;
  status: string; requested_by: string; requested_at: string; decided_by: string | null; decided_at: string | null; decision_note: string | null;
  requester: { full_name: string; avatar_url: string | null } | null;
  decider: { full_name: string } | null;
}

// cuti & izin: penyetuju diatur di Role & Hak Akses (approval.leave), jumlahnya hari, bukan rupiah
const DOC_TYPES: Record<string, { label: string; icon: typeof BadgeCheck }> = { ...APPROVAL_DOCS, leave: { label: 'Cuti & Izin', icon: CalendarHeart } };
const amountText = (r: { document_type: string; amount: number }) => (r.document_type === 'leave' ? `${Number(r.amount).toLocaleString('id-ID')} hari` : formatRupiah(r.amount));

const STATUS: Record<string, [string, string]> = {
  pending: ['Menunggu', 'badge-warning'],
  approved: ['Disetujui', 'badge-success'],
  rejected: ['Ditolak', 'badge-danger'],
  cancelled: ['Dibatalkan', 'badge'],
};

type Tab = 'inbox' | 'mine' | 'history';

export default function ApprovalsPage() {
  const { profile, can } = useAuth();
  const { toast, confirm, prompt } = useFeedback();
  const [tab, setTab] = useState<Tab>('inbox');
  const [rows, setRows] = useState<ApprovalRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const isApprover = (type: string) => can(`approval.${type}`);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      let q = supabase.from('sys_approval_requests')
        .select('*, requester:sys_users!sys_approval_requests_requested_by_fkey(full_name, avatar_url), decider:sys_users!sys_approval_requests_decided_by_fkey(full_name)')
        .order('requested_at', { ascending: false }).limit(100);
      if (tab === 'inbox') q = q.eq('status', 'pending');
      if (tab === 'mine') q = q.eq('requested_by', profile!.user_id);
      if (tab === 'history') q = q.neq('status', 'pending');
      let data = (await must(q)) as ApprovalRequest[];
      if (tab === 'inbox') data = data.filter((r) => isApprover(r.document_type) && (r.requested_by !== profile!.user_id || can('*')));
      setRows(data);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, profile]);

  useEffect(() => {
    load();
    const ch = supabase.channel('approvals-page')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sys_approval_requests' }, () => load())
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [load]);

  const decide = async (r: ApprovalRequest, approve: boolean) => {
    let note: string | null = null;
    if (approve) {
      if (!(await confirm({ title: 'Setujui permintaan?', message: <>{r.title}<br /><b>{amountText(r)}</b><br />Aksi akan langsung dijalankan.</>, confirmLabel: 'Setujui' }))) return;
    } else {
      note = await prompt({ title: 'Tolak permintaan', label: 'Alasan penolakan', placeholder: 'contoh: harga terlalu tinggi' });
      if (note === null) return;
    }
    try {
      await rpc('sys_decide_approval', { p_request_id: r.id, p_approve: approve, p_note: note });
      toast(approve ? 'Disetujui & dijalankan' : 'Permintaan ditolak', approve ? 'success' : 'info');
      load();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  const cancel = async (r: ApprovalRequest) => {
    if (!(await confirm({ title: 'Batalkan pengajuan?', message: r.title, danger: true, confirmLabel: 'Batalkan' }))) return;
    try {
      await rpc('sys_cancel_approval', { p_request_id: r.id });
      toast('Pengajuan dibatalkan', 'info');
      load();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Persetujuan</h1>
          <p>PO, biaya, penyesuaian stok, dan refund yang perlu disetujui atasan.</p>
        </div>
      </div>
      <div className="tabs">
        {([['inbox', 'Perlu Keputusan Saya'], ['mine', 'Pengajuan Saya'], ['history', 'Riwayat']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>

      {loading ? (
        <div className="grid">{[1, 2, 3].map((i) => <div key={i} className="skeleton" style={{ height: 88 }} />)}</div>
      ) : !rows.length ? (
        <div className="card empty">
          <BadgeCheck size={40} style={{ color: 'var(--fresh)' }} />
          <p>{tab === 'inbox' ? 'Tidak ada yang menunggu keputusan Anda. 🎉' : 'Belum ada data.'}</p>
        </div>
      ) : (
        <div className="grid">
          {rows.map((r) => {
            const type = DOC_TYPES[r.document_type] ?? { label: r.document_type, icon: BadgeCheck };
            const Icon = type.icon;
            const [label, badge] = STATUS[r.status] ?? [r.status, 'badge'];
            return (
              <div key={r.id} className="card approval-card">
                <div className="approval-icon"><Icon size={22} /></div>
                <div className="approval-body">
                  <div className="row" style={{ justifyContent: 'space-between' }}>
                    <span className="muted small bold">{type.label}</span>
                    <span className={`badge ${badge}`}>{label}</span>
                  </div>
                  <div className="bold" style={{ fontSize: 15, margin: '4px 0' }}>{r.title}</div>
                  <div className="stat-value" style={{ fontSize: 20, margin: 0 }}>{amountText(r)}</div>
                  <div className="muted small" style={{ marginTop: 6 }}>
                    Diajukan {r.requester?.full_name ?? '-'} · {formatDateTime(r.requested_at)}
                    {r.decided_at && <> · {label} oleh {r.decider?.full_name ?? '-'} {formatDateTime(r.decided_at)}</>}
                  </div>
                  {r.decision_note && <div className="small" style={{ marginTop: 4 }}>📝 {r.decision_note}</div>}
                </div>
                {r.status === 'pending' && (
                  <div className="approval-actions">
                    {isApprover(r.document_type) && (r.requested_by !== profile!.user_id || can('*')) && (
                      <>
                        <button className="btn-danger" onClick={() => decide(r, false)}><X size={16} /> Tolak</button>
                        <button className="btn-primary" onClick={() => decide(r, true)}><Check size={16} /> Setujui</button>
                      </>
                    )}
                    {r.requested_by === profile!.user_id && <button onClick={() => cancel(r)}>Batalkan</button>}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
