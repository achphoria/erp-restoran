import { Building2, Lock, MapPin } from 'lucide-react';

export type OutletScope = 'all' | 'selected';

// Pilih cakupan branch user: semua branch, atau branch tertentu (1 branch = terkunci)
export default function BranchAccessPicker({ outlets, scope, outletIds, onChange, ownerRole }: {
  outlets: { id: string; name: string }[]; scope: OutletScope; outletIds: string[];
  onChange: (scope: OutletScope, outletIds: string[]) => void; ownerRole?: boolean;
}) {
  if (ownerRole) return <div className="alert alert-info small">Role Owner otomatis bisa mengakses semua branch.</div>;
  const toggle = (id: string) => onChange('selected', outletIds.includes(id) ? outletIds.filter((x) => x !== id) : [...outletIds, id]);
  const one = outlets.find((o) => o.id === outletIds[0]);

  return (
    <div className="branch-picker">
      <div className="muted small" style={{ marginBottom: 6 }}>Akses branch *</div>
      <div className="branch-options">
        <button type="button" className={`branch-option ${scope === 'all' ? 'active' : ''}`} onClick={() => onChange('all', outletIds)}>
          <Building2 size={18} />
          <span><b>Semua branch</b><small>Termasuk branch baru nanti. Untuk Head Office (GM, Finance, Purchasing…)</small></span>
        </button>
        <button type="button" className={`branch-option ${scope === 'selected' ? 'active' : ''}`} onClick={() => onChange('selected', outletIds)}>
          <MapPin size={18} />
          <span><b>Branch tertentu</b><small>Pilih 1 branch (terkunci) atau beberapa branch</small></span>
        </button>
      </div>
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
