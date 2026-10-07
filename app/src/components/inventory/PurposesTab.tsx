import { useCallback, useEffect, useState } from 'react';
import { Plus } from 'lucide-react';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { DOC_INFO, type AdjustmentType } from './StockDocuments';

interface Purpose { id?: string; adjustment_type: AdjustmentType; code: string | null; name: string; account_id: string | null; is_active: boolean; sort_order: number; dirty?: boolean }
interface Account { id: string; code: string; name: string; account_type: string; is_header: boolean }

const DEFAULT_ACCOUNT: Record<AdjustmentType, string> = {
  adjustment: 'Selisih Stok kategori produk', waste: 'Bahan Terbuang (Waste)', usage: 'Pemakaian Bahan & Perlengkapan', shrinkage: 'Penyusutan Persediaan',
};

// Setting purpose (sub alasan) per jenis dokumen stok & akun COA tujuannya
export default function PurposesTab({ companyId }: { companyId: string }) {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Purpose[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);

  const load = useCallback(async () => {
    const [p, a] = await Promise.all([
      must(supabase.from('inv_adjustment_purposes').select('*').order('adjustment_type').order('sort_order')),
      must(supabase.from('fin_accounts').select('id, code, name, account_type, is_header').eq('is_active', true).order('code')).catch(() => []),
    ]);
    setRows(p); setAccounts(a);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const upd = (idx: number, patch: Partial<Purpose>) => setRows(rows.map((r, i) => (i === idx ? { ...r, ...patch, dirty: true } : r)));
  const dirty = rows.filter((r) => r.dirty && r.name.trim());
  const expenseAccounts = accounts.filter((a) => !a.is_header && ['cogs', 'expense'].includes(a.account_type));

  const save = async () => {
    try {
      for (const r of dirty) {
        const row = { company_id: companyId, adjustment_type: r.adjustment_type, code: r.code?.trim() || null, name: r.name.trim(),
          account_id: r.account_id || null, is_active: r.is_active, sort_order: r.sort_order };
        await must(r.id ? supabase.from('inv_adjustment_purposes').update(row).eq('id', r.id) : supabase.from('inv_adjustment_purposes').insert(row));
      }
      toast(`${dirty.length} purpose disimpan`);
      load();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Nama purpose dobel dalam jenis yang sama' : errorMessage(e), 'error');
    }
  };

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" disabled={!dirty.length} onClick={save}>Simpan perubahan {dirty.length ? `(${dirty.length})` : ''}</button>
          <span className="muted small">Akun dikosongkan = memakai akun default jenisnya. {!accounts.length && 'Akun tidak tampil karena Anda tidak punya akses Keuangan.'}</span>
        </div>
      </div>
      <div className="grid grid-2">
        {(Object.keys(DEFAULT_ACCOUNT) as AdjustmentType[]).map((t) => {
          const Icon = DOC_INFO[t].icon;
          return (
            <div key={t} className="card">
              <div className="card-header">
                <h3><Icon size={16} style={{ verticalAlign: -3 }} /> {DOC_INFO[t].label}</h3>
                <button className="btn-sm" onClick={() => setRows([...rows, { adjustment_type: t, code: null, name: '', account_id: null, is_active: true, sort_order: rows.filter((r) => r.adjustment_type === t).length + 1, dirty: true }])}>
                  <Plus size={14} /> Purpose
                </button>
              </div>
              <table className="table">
                <tbody>
                  {rows.map((r, i) => r.adjustment_type !== t ? null : (
                    <tr key={r.id ?? `new-${i}`} style={{ opacity: r.is_active ? 1 : 0.5 }}>
                      <td><input value={r.name} placeholder="Nama purpose" style={{ width: '100%', minWidth: 120 }} onChange={(e) => upd(i, { name: e.target.value })} /></td>
                      <td>
                        <select value={r.account_id ?? ''} style={{ width: '100%', minWidth: 150 }} onChange={(e) => upd(i, { account_id: e.target.value || null })}>
                          <option value="">Default: {DEFAULT_ACCOUNT[t]}</option>
                          {expenseAccounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
                        </select>
                      </td>
                      <td><label className="switch" title="Aktif"><input type="checkbox" checked={r.is_active} onChange={(e) => upd(i, { is_active: e.target.checked })} /></label></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          );
        })}
      </div>
    </>
  );
}
