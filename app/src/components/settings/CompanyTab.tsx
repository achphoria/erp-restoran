import { useEffect, useState } from 'react';
import { ImagePlus, Trash2 } from 'lucide-react';
import { useAuth } from '../../context/AuthContext';
import { useFeedback } from '../Feedback';
import { must, supabase } from '../../lib/supabase';
import { uploadCompanyLogo } from '../../lib/image';
import { errorMessage } from '../../lib/format';
import Logo from '../Logo';
import { APP_NAME } from '../../lib/brand';

interface Company { id: string; name: string; app_name: string | null; logo_url: string | null; phone: string | null; email: string | null; address: string | null; tax_number: string | null }

// Identitas perusahaan & logo (tampil di sidebar, struk, dan halaman login karyawan)
export default function CompanyTab() {
  const { profile, refreshProfile } = useAuth();
  const { toast } = useFeedback();
  const [c, setC] = useState<Company | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    must(supabase.from('sys_companies').select('id, name, app_name, logo_url, phone, email, address, tax_number').single())
      .then(setC).catch((e) => toast(errorMessage(e), 'error'));
  }, [toast]);

  if (!c) return <div className="skeleton" style={{ height: 240 }} />;

  const set = (patch: Partial<Company>) => setC({ ...c, ...patch });

  const onLogo = async (file?: File) => {
    if (!file) return;
    setBusy(true);
    try {
      set({ logo_url: await uploadCompanyLogo(profile!.company_id, file) });
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    setBusy(true);
    try {
      await must(supabase.from('sys_companies').update({
        name: c.name, app_name: c.app_name?.trim() || null, logo_url: c.logo_url, phone: c.phone || null, email: c.email || null,
        address: c.address || null, tax_number: c.tax_number || null,
      }).eq('id', c.id));
      await refreshProfile();
      toast('Data perusahaan disimpan');
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid grid-2">
      <div className="card">
        <h2 style={{ marginBottom: 14 }}>Logo</h2>
        <div className="row" style={{ gap: 18, flexWrap: 'nowrap' }}>
          <div className="menu-photo" style={{ width: 112, height: 112 }}>
            {c.logo_url ? <img src={c.logo_url} alt="Logo" /> : <Logo size={72} />}
          </div>
          <div className="grid" style={{ gap: 8 }}>
            <label className="btn" style={{ cursor: 'pointer' }}>
              <ImagePlus size={16} /> {busy ? 'Mengunggah…' : c.logo_url ? 'Ganti logo' : 'Upload logo'}
              <input type="file" accept="image/png,image/jpeg,image/webp" hidden disabled={busy} onChange={(e) => onLogo(e.target.files?.[0])} />
            </label>
            {c.logo_url && <button className="btn-sm btn-danger" onClick={() => set({ logo_url: null })}><Trash2 size={14} /> Pakai logo default</button>}
            <span className="muted small">PNG/JPG persegi, min. 256×256 px. Tampil di sidebar & struk.</span>
          </div>
        </div>
        <div className="card" style={{ marginTop: 16, background: 'var(--surface-2)', boxShadow: 'none' }}>
          <div className="muted small" style={{ marginBottom: 8 }}>Pratinjau sidebar</div>
          <Logo src={c.logo_url} name={c.app_name?.trim() || APP_NAME} size={40} withName subtitle={c.name} />
        </div>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 14 }}>Identitas Perusahaan</h2>
        <div className="grid">
          <label className="field"><span>Nama aplikasi (tampil di sidebar, login & judul tab)</span>
            <input value={c.app_name ?? ''} maxLength={40} placeholder={APP_NAME} onChange={(e) => set({ app_name: e.target.value })} /></label>
          <label className="field"><span>Nama perusahaan / brand</span><input value={c.name} onChange={(e) => set({ name: e.target.value })} /></label>
          <label className="field"><span>Telepon</span><input inputMode="tel" value={c.phone ?? ''} onChange={(e) => set({ phone: e.target.value })} /></label>
          <label className="field"><span>Email</span><input type="email" value={c.email ?? ''} onChange={(e) => set({ email: e.target.value })} /></label>
          <label className="field"><span>Alamat</span><textarea rows={2} value={c.address ?? ''} onChange={(e) => set({ address: e.target.value })} /></label>
          <label className="field"><span>NPWP</span><input value={c.tax_number ?? ''} onChange={(e) => set({ tax_number: e.target.value })} /></label>
          <button className="btn-primary" disabled={busy || !c.name.trim()} onClick={save}>Simpan</button>
        </div>
      </div>
    </div>
  );
}
