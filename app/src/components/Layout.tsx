import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import QrOrderAlert from './QrOrderAlert';

const NAV = [
  { to: '/', label: 'Dashboard', icon: '📊', permission: 'report.view' },
  { to: '/pos', label: 'Kasir (POS)', icon: '🧾', permission: 'pos.order' },
  { to: '/orders', label: 'Daftar Order', icon: '📋', permission: 'pos.order' },
  { to: '/kitchen', label: 'Layar Dapur', icon: '👨‍🍳', permission: 'kds.update' },
  { to: '/shifts', label: 'Shift Kasir', icon: '⏱️', permission: 'pos.pay' },
  { to: '/menu', label: 'Menu', icon: '🍽️', permission: 'master.manage' },
  { to: '/inventory', label: 'Inventory', icon: '📦', permission: 'inventory.manage' },
  { to: '/purchasing', label: 'Pembelian', icon: '🚚', permission: 'purchasing.manage' },
  { to: '/customers', label: 'Pelanggan & Promo', icon: '🎁', permission: 'crm.manage' },
  { to: '/reports', label: 'Laporan', icon: '📈', permission: 'report.view' },
  { to: '/finance', label: 'Keuangan', icon: '💰', permission: ['finance.view', 'finance.manage'] },
  { to: '/settings', label: 'Pengaturan', icon: '⚙️', permission: ['user.manage', 'settings.manage'] },
];

export default function Layout() {
  const { profile, outlet, setOutletId, can, signOut } = useAuth();

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          🍜 ERP Resto
          <small>{profile?.company_name}</small>
        </div>
        {NAV.filter((n) => can(n.permission)).map((n) => (
          <NavLink key={n.to} to={n.to} end={n.to === '/'}>
            <span>{n.icon}</span>
            {n.label}
          </NavLink>
        ))}
        {outlet && can('pos.order') && <QrOrderAlert outletId={outlet.id} />}
        <div className="sidebar-footer">
          {profile && profile.outlets.length > 1 ? (
            <select value={outlet?.id} onChange={(e) => setOutletId(e.target.value)}>
              {profile.outlets.map((o) => (
                <option key={o.id} value={o.id}>{o.name}</option>
              ))}
            </select>
          ) : (
            <div className="sidebar-user">📍 {outlet?.name}</div>
          )}
          <div className="sidebar-user">
            <strong>{profile?.full_name}</strong>
            {profile?.role_name}
          </div>
          <button className="btn-sm" onClick={signOut}>Keluar</button>
        </div>
      </aside>
      <main className="main">
        <Outlet />
      </main>
    </div>
  );
}
