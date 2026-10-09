import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { MODULE_BY_KEY, type ModuleKey } from '../lib/modules';

// Ditampilkan bila halaman milik modul yang dimatikan (Pengaturan -> Modul)
export default function ModuleOff({ module }: { module: ModuleKey }) {
  const { can } = useAuth();
  const m = MODULE_BY_KEY[module];
  const Icon = m.icon;
  return (
    <div className="card empty" style={{ maxWidth: 520, margin: '40px auto' }}>
      <Icon size={40} style={{ color: 'var(--fresh)' }} />
      <h2 style={{ margin: '12px 0 6px', color: 'var(--text)' }}>Modul {m.name} belum aktif</h2>
      <p style={{ margin: '0 0 16px' }}>{m.desc}</p>
      {can('settings.manage')
        ? <Link to="/settings?tab=modules" className="btn btn-primary">Aktifkan di Pengaturan → Modul</Link>
        : <p className="small">Minta owner mengaktifkan modul ini bila dibutuhkan.</p>}
    </div>
  );
}
