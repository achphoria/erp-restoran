import { useState } from 'react';
import Modal from '../Modal';
import { must, supabase } from '../../lib/supabase';

export interface BrandRow { id: string; code: string; name: string; logo_url: string | null; is_active: boolean; created_at: string }

// Master Brand: 1 perusahaan (PT) bisa punya beberapa brand; tiap outlet masuk ke 1 brand
export default function BrandsTab({ companyId, brands, outlets, act }: {
  companyId: string; brands: BrandRow[]; outlets: { id: string; name: string; brand_id: string }[];
  act: (fn: () => Promise<string | void>) => Promise<void>;
}) {
  const [editing, setEditing] = useState<Partial<BrandRow> | null>(null);

  const save = () => act(async () => {
    const e = editing!;
    if (e.id) {
      await must(supabase.from('sys_brands').update({ name: e.name!.trim(), is_active: e.is_active }).eq('id', e.id));
    } else {
      await must(supabase.from('sys_brands').insert({ company_id: companyId, code: e.code!.trim().toUpperCase(), name: e.name!.trim() }));
    }
    setEditing(null);
    return 'Brand disimpan.';
  });

  return (
    <>
      <div className="alert alert-info small">
        Struktur: <b>Perusahaan (PT)</b> → <b>Brand</b> → <b>Outlet / branch</b>. Menu kasir mengikuti brand outlet,
        dan user bisa diberi akses <b>per brand</b> (otomatis termasuk outlet baru brand tersebut) di User Management.
      </div>
      <div className="card table-wrap">
        <div className="card-header">
          <h2>Brand</h2>
          <button className="btn-primary" onClick={() => setEditing({ is_active: true })}>+ Brand Baru</button>
        </div>
        <table className="table">
          <thead><tr><th>Kode</th><th>Nama brand</th><th>Outlet</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {brands.map((b) => {
              const list = outlets.filter((o) => o.brand_id === b.id);
              return (
                <tr key={b.id}>
                  <td>{b.code}</td>
                  <td className="bold">{b.name}</td>
                  <td className="small">{list.length ? list.map((o) => o.name).join(', ') : <span className="muted">Belum ada outlet</span>}</td>
                  <td>{b.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
                  <td className="right"><button className="btn-sm" onClick={() => setEditing(b)}>Edit</button></td>
                </tr>
              );
            })}
            {!brands.length && <tr><td colSpan={5} className="empty">Belum ada brand.</td></tr>}
          </tbody>
        </table>
      </div>

      {editing && (
        <Modal title={editing.id ? `Edit ${editing.name}` : 'Brand Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button>
            <button className="btn-primary" disabled={!editing.code?.trim() || !editing.name?.trim()} onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Kode (mis. BR02)</span>
              <input value={editing.code ?? ''} disabled={!!editing.id} onChange={(e) => setEditing({ ...editing, code: e.target.value })} /></label>
            <label className="field"><span>Nama brand</span>
              <input value={editing.name ?? ''} autoFocus onChange={(e) => setEditing({ ...editing, name: e.target.value })} placeholder="mis. Kopi Achphoria" /></label>
          </div>
          {editing.id && (
            <label className="row" style={{ marginTop: 12 }}>
              <input type="checkbox" checked={!!editing.is_active} onChange={(e) => setEditing({ ...editing, is_active: e.target.checked })} /> Brand aktif
            </label>
          )}
          {!editing.id && <p className="muted small">Setelah dibuat, pilih brand ini saat membuat / mengedit outlet di tab Outlet.</p>}
        </Modal>
      )}
    </>
  );
}
