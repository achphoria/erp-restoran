import { useState } from 'react';
import { Plus } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { CATEGORY_TYPES, type Account, type Category, type MasterData } from './types';

const ACCOUNT_FIELDS: { key: keyof Category; label: string; types: string[]; hint: string }[] = [
  { key: 'inventory_account_id', label: 'Akun persediaan', types: ['asset'], hint: 'Nilai stok kategori ini' },
  { key: 'cogs_account_id', label: 'Akun HPP', types: ['cogs', 'expense'], hint: 'Saat bahan terpakai karena penjualan' },
  { key: 'adjustment_account_id', label: 'Akun selisih stok', types: ['cogs', 'expense'], hint: 'Penyesuaian & opname' },
  { key: 'sales_account_id', label: 'Akun penjualan', types: ['revenue'], hint: 'Untuk barang yang dijual langsung' },
];

// Kategori bertipe + akun COA per kategori (kosong = pakai akun default)
export default function CategoriesTab(md: MasterData) {
  const [editing, setEditing] = useState<Partial<Category> | null>(null);
  const acc = (id: string | null) => md.accounts.find((a) => a.id === id);

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <div>
          <h2>Kategori Produk</h2>
          <p className="muted small" style={{ margin: '4px 0 0' }}>Akun yang dikosongkan memakai akun default (Persediaan, HPP Bahan Baku, Selisih Stok, Penjualan).</p>
        </div>
        <button className="btn-primary" onClick={() => setEditing({ category_type: 'inventory', is_active: true })}><Plus size={16} /> Kategori</button>
      </div>
      <table className="table">
        <thead><tr><th>Kode</th><th>Nama</th><th>Tipe</th><th>Persediaan</th><th>HPP</th><th>Status</th></tr></thead>
        <tbody>
          {md.categories.map((c) => (
            <tr key={c.id} onClick={() => setEditing(c)} style={{ cursor: 'pointer' }}>
              <td>{c.code ?? '—'}</td>
              <td className="bold">{c.name}</td>
              <td><span className="badge badge-info">{CATEGORY_TYPES[c.category_type]}</span></td>
              <td className="small">{acc(c.inventory_account_id)?.name ?? <span className="muted">default</span>}</td>
              <td className="small">{acc(c.cogs_account_id)?.name ?? <span className="muted">default</span>}</td>
              <td>{c.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
            </tr>
          ))}
          {!md.categories.length && <tr><td colSpan={6} className="empty">Belum ada kategori.</td></tr>}
        </tbody>
      </table>
      {editing && <CategoryForm md={md} category={editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function CategoryForm({ md, category, onClose }: { md: MasterData; category: Partial<Category>; onClose: () => void }) {
  const { toast } = useFeedback();
  const [c, setC] = useState<Partial<Category>>(category);
  const set = (patch: Partial<Category>) => setC((x) => ({ ...x, ...patch }));
  const isStock = c.category_type === 'inventory';

  const save = async () => {
    try {
      const row = {
        company_id: md.companyId, name: c.name?.trim(), code: c.code?.trim() || null, category_type: c.category_type,
        notes: c.notes?.trim() || null, is_active: !!c.is_active,
        inventory_account_id: isStock ? c.inventory_account_id || null : null,
        cogs_account_id: isStock ? c.cogs_account_id || null : null,
        adjustment_account_id: isStock ? c.adjustment_account_id || null : null,
        sales_account_id: c.sales_account_id || null,
      };
      await must(c.id ? supabase.from('inv_item_categories').update(row).eq('id', c.id) : supabase.from('inv_item_categories').insert(row));
      toast('Kategori disimpan');
      await md.reload();
      onClose();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Nama / kode kategori sudah dipakai' : errorMessage(e), 'error');
    }
  };

  const options = (types: string[]) => md.accounts.filter((a: Account) => !a.is_header && types.includes(a.account_type));

  return (
    <Modal title={c.id ? `Edit ${c.name}` : 'Kategori Baru'} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={!c.name?.trim()} onClick={save}>Simpan</button></>}>
      <div className="form-grid">
        <label className="field"><span>Nama *</span><input value={c.name ?? ''} onChange={(e) => set({ name: e.target.value })} /></label>
        <label className="field"><span>Kode</span><input value={c.code ?? ''} onChange={(e) => set({ code: e.target.value.toUpperCase() })} /></label>
        <label className="field"><span>Tipe</span>
          <select value={c.category_type} onChange={(e) => set({ category_type: e.target.value })}>
            {Object.entries(CATEGORY_TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select></label>
      </div>
      <p className="muted small">
        {isStock ? 'Inventory: barang yang distok, dihitung HPP-nya, dan diopname.' : 'Non-inventory / aset: tidak dihitung sebagai stok bahan.'}
      </p>
      <div className="grid" style={{ marginTop: 8 }}>
        {ACCOUNT_FIELDS.filter((f) => isStock || f.key === 'sales_account_id').map((f) => (
          <label key={f.key} className="field"><span>{f.label} <span className="muted small">· {f.hint}</span></span>
            <select value={(c[f.key] as string) ?? ''} onChange={(e) => set({ [f.key]: e.target.value || null } as Partial<Category>)}>
              <option value="">Default</option>
              {options(f.types).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
            </select></label>
        ))}
        {!md.accounts.length && <div className="muted small">Akun keuangan tidak tampil karena Anda tidak punya akses Keuangan.</div>}
        <label className="field"><span>Catatan</span><input value={c.notes ?? ''} onChange={(e) => set({ notes: e.target.value })} maxLength={100} /></label>
        <label className="switch"><input type="checkbox" checked={!!c.is_active} onChange={(e) => set({ is_active: e.target.checked })} /><span>Aktif</span></label>
      </div>
    </Modal>
  );
}
