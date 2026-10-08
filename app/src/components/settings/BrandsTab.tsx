import { useState } from 'react';
import { ImagePlus, Trash2 } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { uploadCompanyLogo } from '../../lib/image';
import { errorMessage } from '../../lib/format';

export interface BrandRow {
  id: string; code: string; name: string; logo_url: string | null; is_active: boolean; show_on_landing: boolean; created_at: string;
}

// Master Brand: 1 perusahaan (PT) bisa punya beberapa brand; tiap outlet masuk ke 1 brand.
// Logo brand tampil di sidebar outlet brand itu & (bila diizinkan) di halaman depan SEMAR.
export default function BrandsTab({ companyId, brands, outlets, act }: {
  companyId: string; brands: BrandRow[]; outlets: { id: string; name: string; brand_id: string }[];
  act: (fn: () => Promise<string | void>) => Promise<void>;
}) {
  const { toast } = useFeedback();
  const [editing, setEditing] = useState<Partial<BrandRow> | null>(null);
  const [uploading, setUploading] = useState(false);

  const save = () => act(async () => {
    const e = editing!;
    const values = { name: e.name!.trim(), is_active: e.is_active ?? true, logo_url: e.logo_url ?? null, show_on_landing: e.show_on_landing ?? true };
    if (e.id) await must(supabase.from('sys_brands').update(values).eq('id', e.id));
    else await must(supabase.from('sys_brands').insert({ ...values, company_id: companyId, code: e.code!.trim().toUpperCase() }));
    setEditing(null);
    window.dispatchEvent(new Event('brand-updated'));
    return 'Brand disimpan.';
  });

  const onLogo = async (file?: File) => {
    if (!file) return;
    setUploading(true);
    try {
      setEditing((x) => ({ ...x, logo_url: null }));
      const url = await uploadCompanyLogo(companyId, file);
      setEditing((x) => ({ ...x, logo_url: url }));
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setUploading(false);
    }
  };

  return (
    <>
      <div className="alert alert-info small">
        Struktur: <b>Perusahaan (PT)</b> → <b>Brand</b> → <b>Outlet / branch</b>. Menu kasir mengikuti brand outlet, logo brand tampil di sidebar
        outlet brand tersebut, dan user bisa diberi akses <b>per brand</b> di User Management.
      </div>
      <div className="card table-wrap">
        <div className="card-header">
          <h2>Brand</h2>
          <button className="btn-primary" onClick={() => setEditing({ is_active: true, show_on_landing: true })}>+ Brand Baru</button>
        </div>
        <table className="table">
          <thead><tr><th>Logo</th><th>Kode</th><th>Nama brand</th><th>Outlet</th><th>Halaman depan SEMAR</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {brands.map((b) => {
              const list = outlets.filter((o) => o.brand_id === b.id);
              return (
                <tr key={b.id}>
                  <td>{b.logo_url ? <img src={b.logo_url} alt="" className="brand-logo-thumb" /> : <span className="brand-logo-thumb empty">{b.name[0]}</span>}</td>
                  <td>{b.code}</td>
                  <td className="bold">{b.name}</td>
                  <td className="small">{list.length ? list.map((o) => o.name).join(', ') : <span className="muted">Belum ada outlet</span>}</td>
                  <td className="small">{!b.logo_url ? <span className="muted">Butuh logo</span> : b.show_on_landing ? <span className="badge badge-success">Tampil</span> : <span className="badge">Disembunyikan</span>}</td>
                  <td>{b.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
                  <td className="right"><button className="btn-sm" onClick={() => setEditing(b)}>Edit</button></td>
                </tr>
              );
            })}
            {!brands.length && <tr><td colSpan={7} className="empty">Belum ada brand.</td></tr>}
          </tbody>
        </table>
      </div>

      {editing && (
        <Modal title={editing.id ? `Edit ${editing.name}` : 'Brand Baru'} onClose={() => setEditing(null)}
          footer={<><button onClick={() => setEditing(null)}>Batal</button>
            <button className="btn-primary" disabled={uploading || !editing.code?.trim() || !editing.name?.trim()} onClick={save}>Simpan</button></>}>
          <div className="brand-logo-edit">
            <div className="brand-logo-preview">
              {editing.logo_url ? <img src={editing.logo_url} alt="Logo brand" /> : <span>{uploading ? '…' : editing.name?.[0] ?? '?'}</span>}
            </div>
            <div className="grid" style={{ gap: 8 }}>
              <label className="btn" style={{ cursor: 'pointer' }}>
                <ImagePlus size={16} /> {uploading ? 'Mengunggah…' : editing.logo_url ? 'Ganti logo' : 'Upload logo'}
                <input type="file" accept="image/png,image/jpeg,image/webp" hidden disabled={uploading} onChange={(e) => onLogo(e.target.files?.[0])} />
              </label>
              {editing.logo_url && <button type="button" className="btn-sm btn-danger" onClick={() => setEditing({ ...editing, logo_url: null })}><Trash2 size={14} /> Hapus logo</button>}
              <span className="muted small">PNG/JPG persegi, min. 256×256 px.</span>
            </div>
          </div>
          <div className="form-grid" style={{ marginTop: 12 }}>
            <label className="field"><span>Kode (mis. BR02)</span>
              <input value={editing.code ?? ''} disabled={!!editing.id} onChange={(e) => setEditing({ ...editing, code: e.target.value })} /></label>
            <label className="field"><span>Nama brand</span>
              <input value={editing.name ?? ''} autoFocus onChange={(e) => setEditing({ ...editing, name: e.target.value })} placeholder="mis. Kopi Achphoria" /></label>
          </div>
          <div className="grid" style={{ marginTop: 12, gap: 8 }}>
            <label className="row"><input type="checkbox" checked={editing.show_on_landing ?? true} onChange={(e) => setEditing({ ...editing, show_on_landing: e.target.checked })} />
              Tampilkan logo & nama brand di halaman depan SEMAR <span className="muted small">(bagian "Brand yang sudah bersama SEMAR")</span></label>
            {editing.id && (
              <label className="row"><input type="checkbox" checked={!!editing.is_active} onChange={(e) => setEditing({ ...editing, is_active: e.target.checked })} /> Brand aktif</label>
            )}
          </div>
          {!editing.id && <p className="muted small">Setelah dibuat, pilih brand ini saat membuat / mengedit outlet di tab Outlet.</p>}
        </Modal>
      )}
    </>
  );
}
