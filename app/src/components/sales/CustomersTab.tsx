import { useState } from 'react';
import { Plus } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';
import type { Customer, SalesMaster } from './salesShared';

// Master pelanggan B2B (katering, reseller, kantor): termin & limit kredit
export default function CustomersTab({ m }: { m: SalesMaster }) {
  const { toast } = useFeedback();
  const [editing, setEditing] = useState<Partial<Customer> | null>(null);
  const [search, setSearch] = useState('');
  const q = search.trim().toLowerCase();
  const shown = m.customers.filter((c) => !q || c.name.toLowerCase().includes(q) || c.code.toLowerCase().includes(q));

  const save = async () => {
    try {
      const e = editing!;
      const row = { company_id: m.companyId, code: e.code!.trim().toUpperCase(), name: e.name!.trim(), contact_name: e.contact_name?.trim() || null,
        phone: e.phone?.trim() || null, email: e.email?.trim() || null, address: e.address?.trim() || null, tax_number: e.tax_number?.trim() || null,
        payment_term_days: Number(e.payment_term_days || 0), credit_limit: Number(e.credit_limit || 0), notes: e.notes?.trim() || null, is_active: e.is_active ?? true };
      await must(e.id ? supabase.from('sal_customers').update(row).eq('id', e.id) : supabase.from('sal_customers').insert(row));
      toast('Pelanggan disimpan');
      setEditing(null);
      m.reload();
    } catch (e) {
      toast(/duplicate/i.test(errorMessage(e)) ? 'Kode pelanggan sudah dipakai' : errorMessage(e), 'error');
    }
  };
  const set = (patch: Partial<Customer>) => setEditing({ ...editing, ...patch });

  return (
    <div className="card table-wrap">
      <div className="filter-bar">
        <input type="search" placeholder="Cari pelanggan…" value={search} onChange={(e) => setSearch(e.target.value)} />
        <button className="btn-primary" style={{ marginLeft: 'auto' }} onClick={() => setEditing({ code: `CUST${String(m.customers.length + 1).padStart(3, '0')}`, payment_term_days: 14, credit_limit: 0, is_active: true })}>
          <Plus size={16} /> Pelanggan B2B</button>
      </div>
      <table className="table">
        <thead><tr><th>Kode</th><th>Nama</th><th>Kontak</th><th>Termin</th><th className="right">Limit kredit</th><th></th></tr></thead>
        <tbody>
          {shown.map((c) => (
            <tr key={c.id} style={{ opacity: c.is_active ? 1 : 0.5 }}>
              <td>{c.code}</td>
              <td className="bold">{c.name}{c.tax_number && <div className="muted small">NPWP {c.tax_number}</div>}</td>
              <td className="small">{c.contact_name}{c.phone && <div className="muted">{c.phone}</div>}</td>
              <td>{c.payment_term_days ? `${c.payment_term_days} hari` : 'Tunai'}</td>
              <td className="right">{Number(c.credit_limit) ? formatRupiah(c.credit_limit) : <span className="muted">Tanpa limit</span>}</td>
              <td className="right"><button className="btn-sm" onClick={() => setEditing(c)}>Edit</button></td>
            </tr>
          ))}
          {!shown.length && <tr><td colSpan={6} className="empty">Belum ada pelanggan B2B. Cabang internal tidak perlu didaftarkan di sini.</td></tr>}
        </tbody>
      </table>
      {editing && (
        <Modal title={editing.id ? 'Edit Pelanggan' : 'Pelanggan B2B Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button>
            <button className="btn-primary" disabled={!editing.code?.trim() || !editing.name?.trim()} onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode *</span><input value={editing.code ?? ''} onChange={(e) => set({ code: e.target.value })} /></label>
            <label className="field"><span>Nama *</span><input value={editing.name ?? ''} onChange={(e) => set({ name: e.target.value })} /></label>
            <label className="field"><span>Kontak</span><input value={editing.contact_name ?? ''} onChange={(e) => set({ contact_name: e.target.value })} /></label>
            <label className="field"><span>Telepon</span><input value={editing.phone ?? ''} onChange={(e) => set({ phone: e.target.value })} /></label>
            <label className="field"><span>Email</span><input type="email" value={editing.email ?? ''} onChange={(e) => set({ email: e.target.value })} /></label>
            <label className="field"><span>NPWP</span><input value={editing.tax_number ?? ''} onChange={(e) => set({ tax_number: e.target.value })} /></label>
            <label className="field"><span>Termin bayar (hari)</span><input type="number" min={0} value={editing.payment_term_days ?? 0} onChange={(e) => set({ payment_term_days: Number(e.target.value) })} /></label>
            <label className="field"><span>Limit kredit (0 = tanpa limit)</span><MoneyInput value={editing.credit_limit ?? 0} onChange={(v) => set({ credit_limit: Number(v) })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Alamat kirim</span><input value={editing.address ?? ''} onChange={(e) => set({ address: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Catatan</span><input value={editing.notes ?? ''} onChange={(e) => set({ notes: e.target.value })} /></label>
          </div>
          <label className="switch" style={{ marginTop: 12 }}><input type="checkbox" checked={editing.is_active ?? true} onChange={(e) => set({ is_active: e.target.checked })} /><span>Aktif</span></label>
        </Modal>
      )}
    </div>
  );
}
