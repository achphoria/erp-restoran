import { useEffect, useMemo, useState } from 'react';
import { Camera, X } from 'lucide-react';
import Modal from '../Modal';
import MoneyInput from '../MoneyInput';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { rpc } from '../../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../../lib/format';
import { FUNDING, METHOD_LABEL, assetPhotoUrl, lifeLabel, monthISO, uploadAssetPhoto, type AssetOptions } from '../../lib/assets';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Tambah / ubah aset. Data keuangan (harga, umur, sumber dana) terkunci setelah ada penyusutan / pembayaran.
export default function AssetForm({ initial, options, onClose, onSaved }: {
  initial: any | null; options: AssetOptions; onClose: () => void; onSaved: (asset: any) => void;
}) {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const isNew = !initial?.id;
  const locked = !isNew && (Number(initial.months_depreciated) > Number(initial.opening_months ?? 0) || Number(initial.paid_amount ?? 0) > 0);
  const firstCat = options.categories.find((c) => c.is_active);
  const [f, setF] = useState<any>(() => initial ? { ...initial, opening_custom: initial.funding === 'opening' } : {
    name: '', category_id: firstCat?.id ?? '', outlet_id: options.outlets.length === 1 || !options.all_outlets ? options.outlets[0]?.id ?? '' : '',
    acquisition_date: todayISO(), acquisition_cost: '', residual_value: '', funding: 'cash',
    paid_from_account_id: options.cash_accounts.find((a) => a.key === 'bank')?.id ?? options.cash_accounts[0]?.id ?? '',
    depreciation_start: '', useful_life_months: '', method: '',
  });
  const [photo, setPhoto] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: unknown) => setF((p: any) => ({ ...p, [k]: v }));
  const cat = options.categories.find((c) => c.id === f.category_id);
  const life = Number(f.useful_life_months) || cat?.useful_life_months || 0;
  const method = f.method || cat?.method || 'straight_line';
  const cost = Number(f.acquisition_cost) || 0;
  const threshold = Number(options.settings?.capitalization_threshold ?? 0);

  useEffect(() => { assetPhotoUrl(f.photo_path).then(setPhoto); }, [f.photo_path]);

  // pratinjau penyusutan bulanan (garis lurus) & akumulasi aset lama
  const preview = useMemo(() => {
    if (!cost || !life) return null;
    const dep = cost - (Number(f.residual_value) || 0);
    const monthly = dep / life;
    if (f.funding !== 'opening') return { monthly };
    const start = (f.depreciation_start || monthISO(0)).slice(0, 7).split('-').map(Number);
    const acq = String(f.acquisition_date).slice(0, 7).split('-').map(Number);
    const used = (start[0] - acq[0]) * 12 + start[1] - acq[1];
    return { monthly, used, acc: Math.min(dep, Math.round(monthly * 100) / 100 * used) };
  }, [cost, life, f.residual_value, f.funding, f.depreciation_start, f.acquisition_date]);

  const pick = async (file: File | undefined) => {
    if (!file) return;
    try { set('photo_path', await uploadAssetPhoto(profile!.company_id, initial?.id ?? null, file)); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const save = async () => {
    setBusy(true);
    try {
      const p: any = {
        id: initial?.id, name: f.name, category_id: f.category_id, outlet_id: f.outlet_id || null, location: f.location, pic_user_id: f.pic_user_id || null,
        brand_model: f.brand_model, serial_number: f.serial_number, supplier_id: f.supplier_id || null, warranty_until: f.warranty_until || null,
        photo_path: f.photo_path || null, notes: f.notes,
      };
      if (!locked) Object.assign(p, {
        acquisition_date: f.acquisition_date, acquisition_cost: cost, residual_value: Number(f.residual_value) || 0,
        useful_life_months: f.useful_life_months ? Number(f.useful_life_months) : null, method: f.method || null, funding: f.funding,
        paid_from_account_id: f.funding === 'cash' ? f.paid_from_account_id : null, depreciation_start: f.depreciation_start || null,
        opening_accumulated: f.funding === 'opening' && f.opening_accumulated !== '' && f.opening_accumulated != null && f.opening_custom ? Number(f.opening_accumulated) : null,
      });
      onSaved(await rpc('ast_save_asset', { p }));
    } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  return (
    <Modal large title={isNew ? 'Aset baru' : `Ubah ${initial.asset_number}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy} onClick={save}>{busy ? 'Menyimpan…' : 'Simpan aset'}</button></>}>
      <div className="asset-form">
        <section className="card">
          <h3>Identitas</h3>
          <div className="asset-photo-row">
            <label className="asset-photo-pick">
              {photo ? <img src={photo} alt="" /> : <span><Camera size={22} /><br />Foto aset</span>}
              <input type="file" accept="image/*" capture="environment" hidden onChange={(e) => pick(e.target.files?.[0])} />
            </label>
            {f.photo_path && <button type="button" className="btn-sm" onClick={() => set('photo_path', null)}><X size={14} /> Hapus foto</button>}
          </div>
          <div className="form-grid">
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Nama aset *</span>
              <input value={f.name ?? ''} onChange={(e) => set('name', e.target.value)} placeholder="mis. Kompor 4 tungku Rinnai" /></label>
            <label className="field"><span>Kategori *</span>
              <select value={f.category_id} disabled={locked} onChange={(e) => set('category_id', e.target.value)}>
                {options.categories.filter((c) => c.is_active || c.id === f.category_id).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select></label>
            <label className="field"><span>Outlet</span>
              <select value={f.outlet_id ?? ''} disabled={!isNew} onChange={(e) => set('outlet_id', e.target.value)}>
                {options.all_outlets && <option value="">Kantor pusat / tanpa outlet</option>}
                {options.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
              </select>
              {!isNew && <small className="muted">Pindah outlet lewat tombol Mutasi</small>}</label>
            <label className="field"><span>Lokasi</span><input value={f.location ?? ''} onChange={(e) => set('location', e.target.value)} placeholder="mis. Dapur panas, Bar" /></label>
            <label className="field"><span>Penanggung jawab</span>
              <select value={f.pic_user_id ?? ''} onChange={(e) => set('pic_user_id', e.target.value)}>
                <option value="">-</option>
                {options.users.map((u) => <option key={u.id} value={u.id}>{u.name}</option>)}
              </select></label>
            <label className="field"><span>Merek / model</span><input value={f.brand_model ?? ''} onChange={(e) => set('brand_model', e.target.value)} /></label>
            <label className="field"><span>Nomor seri</span><input value={f.serial_number ?? ''} onChange={(e) => set('serial_number', e.target.value)} /></label>
            <label className="field"><span>Supplier</span>
              <select value={f.supplier_id ?? ''} onChange={(e) => set('supplier_id', e.target.value)}>
                <option value="">-</option>
                {options.suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </select></label>
            <label className="field"><span>Garansi sampai</span><input type="date" value={f.warranty_until ?? ''} onChange={(e) => set('warranty_until', e.target.value)} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Catatan</span><textarea rows={2} value={f.notes ?? ''} onChange={(e) => set('notes', e.target.value)} /></label>
          </div>
        </section>

        <section className="card">
          <h3>Perolehan & penyusutan</h3>
          {locked && <p className="small muted" style={{ marginTop: 0 }}>🔒 Sudah ada penyusutan / pembayaran, data keuangan tidak bisa diubah. Bila salah, batalkan penyusutan periode terakhir dulu.</p>}
          <div className="form-grid">
            <label className="field"><span>Tanggal beli *</span><input type="date" disabled={locked} value={f.acquisition_date ?? ''} max={todayISO()} onChange={(e) => set('acquisition_date', e.target.value)} /></label>
            <label className="field"><span>Harga perolehan *</span><MoneyInput disabled={locked} value={f.acquisition_cost} onChange={(v) => set('acquisition_cost', v)} />
              {cost > 0 && cost < threshold && <small className="text-danger">Di bawah batas aset {formatRupiah(threshold)}. Catat sebagai biaya / perlengkapan.</small>}
              <small className="muted">Termasuk ongkir & pemasangan</small></label>
            <label className="field"><span>Nilai sisa (residu)</span><MoneyInput disabled={locked} value={f.residual_value} onChange={(v) => set('residual_value', v)} />
              <small className="muted">Perkiraan harga jual di akhir umur. Biasanya 0.</small></label>
            <label className="field"><span>Umur manfaat (bulan)</span><input type="number" min={1} max={600} disabled={locked} value={f.useful_life_months ?? ''}
              placeholder={cat ? `${cat.useful_life_months} (${lifeLabel(cat.useful_life_months)})` : ''} onChange={(e) => set('useful_life_months', e.target.value)} />
              <small className="muted">Kosong = ikut kategori</small></label>
            <label className="field"><span>Metode</span>
              <select disabled={locked} value={f.method ?? ''} onChange={(e) => set('method', e.target.value)}>
                <option value="">Ikut kategori ({METHOD_LABEL[cat?.method ?? 'straight_line']})</option>
                <option value="straight_line">Garis lurus</option>
                <option value="declining_balance">Saldo menurun</option>
              </select></label>
          </div>

          <div className="field" style={{ marginTop: 12 }}><span>Cara perolehan *</span>
            <div className="asset-funding">
              {Object.entries(FUNDING).map(([k, v]) => (
                <label key={k} className={`asset-funding-opt ${f.funding === k ? 'active' : ''} ${locked ? 'disabled' : ''}`}>
                  <input type="radio" name="funding" disabled={locked} checked={f.funding === k} onChange={() => set('funding', k)} />
                  <b>{v.label}</b><small className="muted">{v.hint}</small>
                </label>
              ))}
            </div>
          </div>

          <div className="form-grid" style={{ marginTop: 12 }}>
            {f.funding === 'cash' && (
              <label className="field"><span>Dibayar dari *</span>
                <select disabled={locked} value={f.paid_from_account_id ?? ''} onChange={(e) => set('paid_from_account_id', e.target.value)}>
                  {options.cash_accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
                </select></label>
            )}
            <label className="field"><span>{f.funding === 'opening' ? 'Mulai disusutkan di SEMAR' : 'Mulai disusutkan'}</span>
              <input type="month" disabled={locked} value={(f.depreciation_start ?? '').slice(0, 7)}
                placeholder={f.funding === 'opening' ? monthISO(0).slice(0, 7) : String(f.acquisition_date).slice(0, 7)}
                onChange={(e) => set('depreciation_start', e.target.value ? `${e.target.value}-01` : '')} />
              <small className="muted">{f.funding === 'opening' ? 'Kosong = bulan ini' : 'Kosong = bulan pembelian'}</small></label>
            {f.funding === 'opening' && (
              <label className="field"><span>Akumulasi penyusutan lama</span>
                <MoneyInput disabled={locked} value={f.opening_custom ? f.opening_accumulated : preview?.acc != null ? Math.round(preview.acc) : ''}
                  onChange={(v) => setF((p: any) => ({ ...p, opening_accumulated: v, opening_custom: v !== '' }))} />
                <small className="muted">{f.opening_custom ? 'Diisi manual' : `Otomatis: ${preview?.used ?? 0} bulan × garis lurus`}</small></label>
            )}
          </div>
          {preview && (
            <div className="asset-preview">
              Penyusutan ± <b>{formatRupiah(Math.round(preview.monthly))}</b> / bulan selama {lifeLabel(life)}
              {method === 'declining_balance' && ' (saldo menurun: lebih besar di awal, makin kecil tiap bulan)'}
            </div>
          )}
        </section>
      </div>
    </Modal>
  );
}
