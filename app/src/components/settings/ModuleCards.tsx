import { Check, Lock } from 'lucide-react';
import { MODULES, MODULE_BY_KEY, dependents, withRequired, type ModuleKey } from '../../lib/modules';
import '../../styles/modules.css';

const GROUPS = [...new Set(MODULES.map((m) => m.group))];
const CORE = ['Dashboard & Pendopo', 'Menu', 'Laporan penjualan', 'Persetujuan', 'User & role', 'Pengaturan', 'Beranda Saya'];

// Kartu modul yang bisa dicentang. Mencentang modul ikut mencentang modul pendukungnya;
// mematikan modul pendukung ikut mematikan modul yang bergantung padanya.
export default function ModuleCards({ value, onChange, note }: { value: ModuleKey[]; onChange: (v: ModuleKey[]) => void; note?: (k: ModuleKey) => string | null }) {
  const on = new Set(value);
  const toggle = (k: ModuleKey) => {
    if (on.has(k)) {
      const drop = new Set([k, ...dependents(k)]);
      onChange(value.filter((x) => !drop.has(x)));
    } else onChange(withRequired([...value, k]));
  };
  return (
    <div className="mod-picker">
      <div className="mod-core"><Lock size={14} /> <b>Selalu aktif:</b> {CORE.join(' · ')}</div>
      {GROUPS.map((g) => (
        <section key={g}>
          <h3 className="mod-group">{g}</h3>
          <div className="mod-grid">
            {MODULES.filter((m) => m.group === g).map((m) => {
              const active = on.has(m.key);
              const Icon = m.icon;
              const req = (m.requires ?? []).map((r) => MODULE_BY_KEY[r].name);
              const extra = note?.(m.key);
              return (
                <button key={m.key} type="button" className={`mod-card ${active ? 'on' : ''}`} aria-pressed={active} onClick={() => toggle(m.key)}>
                  <span className="mod-check">{active && <Check size={14} />}</span>
                  <span className="mod-icon"><Icon size={20} /></span>
                  <b>{m.name}</b>
                  <span className="mod-desc">{m.desc}</span>
                  <span className="mod-meta"><b>Dipakai:</b> {m.who}</span>
                  <span className="mod-meta"><b>Cocok bila:</b> {m.fits}</span>
                  {req.length > 0 && <span className="mod-req">Butuh modul {req.join(', ')} (ikut aktif)</span>}
                  {extra && <span className="mod-req">{extra}</span>}
                </button>
              );
            })}
          </div>
        </section>
      ))}
    </div>
  );
}
