import { useEffect, useState } from 'react';
import { useFeedback } from '../Feedback';
import MoneyInput from '../MoneyInput';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';

interface Rule { id: string; document_type: string; min_amount: number; is_enabled: boolean }

const INFO: Record<string, { label: string; desc: string; amountLabel: string }> = {
  purchase_order: { label: 'Purchase Order', desc: 'PO dengan total ≥ batas harus disetujui sebelum dikirim ke supplier.', amountLabel: 'Total PO minimal' },
  expense: { label: 'Biaya Operasional', desc: 'Pencatatan biaya ≥ batas menunggu persetujuan sebelum dijurnal.', amountLabel: 'Nominal minimal' },
  stock_adjustment: { label: 'Penyesuaian Stok & Waste', desc: 'Nilai (qty × HPP) ≥ batas harus disetujui sebelum stok berubah.', amountLabel: 'Nilai minimal' },
  stock_opname: { label: 'Stock Opname', desc: 'Selisih nilai opname ≥ batas harus disetujui sebelum stok disesuaikan.', amountLabel: 'Nilai selisih minimal' },
  refund: { label: 'Refund', desc: 'Kasir tanpa izin refund bisa mengajukan; refund ≥ batas oleh siapa pun butuh persetujuan.', amountLabel: 'Nominal minimal' },
};

export default function ApprovalRulesTab() {
  const { toast } = useFeedback();
  const [rules, setRules] = useState<Rule[]>([]);

  useEffect(() => {
    must(supabase.from('sys_approval_rules').select('*').order('document_type'))
      .then(setRules).catch((e) => toast(errorMessage(e), 'error'));
  }, [toast]);

  const update = (id: string, patch: Partial<Rule>) => setRules(rules.map((r) => (r.id === id ? { ...r, ...patch } : r)));

  const save = async (r: Rule) => {
    try {
      await must(supabase.from('sys_approval_rules').update({ is_enabled: r.is_enabled, min_amount: Number(r.min_amount) || 0 }).eq('id', r.id));
      toast(`Aturan ${INFO[r.document_type]?.label ?? r.document_type} disimpan`);
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <>
      <div className="alert alert-info small">
        Siapa yang boleh menyetujui diatur di tab <b>Role & Hak Akses</b> → grup <b>Persetujuan</b>. Owner selalu bisa menyetujui.
        Pengaju tidak bisa menyetujui permintaannya sendiri.
      </div>
      <div className="grid grid-2">
        {rules.map((r) => {
          const info = INFO[r.document_type] ?? { label: r.document_type, desc: '', amountLabel: 'Nominal minimal' };
          return (
            <div key={r.id} className="card" style={{ opacity: r.is_enabled ? 1 : 0.75 }}>
              <div className="card-header">
                <h3>{info.label}</h3>
                <label className="switch">
                  <input type="checkbox" checked={r.is_enabled} onChange={(e) => update(r.id, { is_enabled: e.target.checked })} />
                  <span>{r.is_enabled ? 'Aktif' : 'Nonaktif'}</span>
                </label>
              </div>
              <p className="muted small" style={{ marginTop: 0 }}>{info.desc}</p>
              <div className="row" style={{ flexWrap: 'nowrap' }}>
                <label className="field" style={{ flex: 1 }}>
                  <span>{info.amountLabel}</span>
                  <MoneyInput value={r.min_amount} onChange={(v) => update(r.id, { min_amount: Number(v || 0) })} />
                </label>
                <button className="btn-primary" style={{ alignSelf: 'end' }} onClick={() => save(r)}>Simpan</button>
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
}
