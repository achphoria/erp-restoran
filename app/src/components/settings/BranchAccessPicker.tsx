import { Building2, Lock, MapPin, Tags } from 'lucide-react';

export type OutletScope = 'all' | 'selected' | 'brands';

// Pilih cakupan branch user: semua branch, branch tertentu (1 branch = terkunci), atau per brand
export default function BranchAccessPicker({ outlets, brands = [], scope, outletIds, brandIds = [], onChange, ownerRole }: {
  outlets: { id: string; name: string; brand_id?: string }[]; brands?: { id: string; name: string }[];
  scope: OutletScope; outletIds: string[]; brandIds?: string[];
  onChange: (scope: OutletScope, outletIds: string[], brandIds: string[]) => void; ownerRole?: boolean;
}) {
  if (ownerRole) return <div className="alert alert-info small">Role Owner otomatis bisa mengakses semua branch.</div>;
  const toggle = (id: string) => onChange('selected', outletIds.includes(id) ? outletIds.filter((x) => x !== id) : [...outletIds, id], brandIds);
  const toggleBrand = (id: string) => onChange('brands', outletIds, brandIds.includes(id) ? brandIds.filter((x) => x !== id) : [...brandIds, id]);
  const one = outlets.find((o) => o.id === outletIds[0]);
  const brandOutlets = outlets.filter((o) => o.brand_id && brandIds.includes(o.brand_id));

  return (
    <div className="branch-picker">
      <div className="muted small" style={{ marginBottom: 6 }}>Akses branch *</div>
      <div className="branch-options">
        <button type="button" className={`branch-option ${scope === 'all' ? 'active' : ''}`} onClick={() => onChange('all', outletIds, brandIds)}>
          <Building2 size={18} />
          <span><b>Semua branch</b><small>Termasuk branch baru nanti. Untuk Head Office (GM, Finance, Purchasing…)</small></span>
        </button>
        {brands.length > 0 && (
          <button type="button" className={`branch-option ${scope === 'brands' ? 'active' : ''}`} onClick={() => onChange('brands', outletIds, brandIds)}>
            <Tags size={18} />
            <span><b>Per brand</b><small>Semua branch milik brand tertentu, termasuk branch baru brand itu. Untuk Area / Brand Manager</small></span>
          </button>
        )}
        <button type="button" className={`branch-option ${scope === 'selected' ? 'active' : ''}`} onClick={() => onChange('selected', outletIds, brandIds)}>
          <MapPin size={18} />
          <span><b>Branch tertentu</b><small>Pilih 1 branch (terkunci) atau beberapa branch</small></span>
        </button>
      </div>
      {scope === 'brands' && (
        <>
          <div className="choice-list" style={{ marginTop: 10 }}>
            {brands.map((b) => (
              <button key={b.id} type="button" className={brandIds.includes(b.id) ? 'active' : ''} onClick={() => toggleBrand(b.id)}>{b.name}</button>
            ))}
          </div>
          <div className="small" style={{ marginTop: 6, color: brandIds.length ? 'var(--text-muted)' : 'var(--danger)' }}>
            {brandIds.length === 0 ? 'Pilih minimal 1 brand'
              : `Akses ${brandOutlets.length} branch saat ini${brandOutlets.length ? `: ${brandOutlets.map((o) => o.name).join(', ')}` : ''}.`}
          </div>
        </>
      )}
      {scope === 'selected' && (
        <>
          <div className="choice-list" style={{ marginTop: 10 }}>
            {outlets.map((o) => (
              <button key={o.id} type="button" className={outletIds.includes(o.id) ? 'active' : ''} onClick={() => toggle(o.id)}>{o.name}</button>
            ))}
          </div>
          <div className="small" style={{ marginTop: 6, color: outletIds.length ? 'var(--text-muted)' : 'var(--danger)' }}>
            {outletIds.length === 0 && 'Pilih minimal 1 branch'}
            {outletIds.length === 1 && <><Lock size={12} style={{ verticalAlign: -1 }} /> Terkunci di <b>{one?.name}</b>: hanya melihat & mengubah data branch ini.</>}
            {outletIds.length > 1 && `Bisa pindah antar ${outletIds.length} branch lewat pilihan outlet di sidebar.`}
          </div>
        </>
      )}
    </div>
  );
}

// valid bila cakupan punya pilihan yang cukup
export function accessValid(scope: OutletScope, outletIds: string[], brandIds: string[]) {
  return scope === 'all' || (scope === 'selected' ? outletIds.length > 0 : brandIds.length > 0);
}
