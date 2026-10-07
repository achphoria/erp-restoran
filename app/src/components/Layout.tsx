import { Suspense, useCallback, useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import {
  BadgeCheck, BarChart3, Boxes, ChefHat, ClipboardList, Gift, LayoutDashboard, LogOut, Menu as MenuIcon, Package,
  Pin, PinOff, Receipt, Settings, Timer, Truck, UtensilsCrossed, Wallet, X, type LucideIcon,
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { rpc, supabase } from '../lib/supabase';
import { setDocumentTitle } from '../lib/brand';
import Logo from './Logo';
import Avatar from './Avatar';
import QrOrderAlert from './QrOrderAlert';
import ProfileModal from './ProfileModal';

interface NavItem { to: string; label: string; icon: LucideIcon; permission: string | string[]; badge?: 'approvals' }

const NAV: { group: string; items: NavItem[] }[] = [
  {
    group: 'Operasional',
    items: [
      { to: '/', label: 'Dashboard', icon: LayoutDashboard, permission: 'report.view' },
      { to: '/pos', label: 'Kasir (POS)', icon: Receipt, permission: 'pos.order' },
      { to: '/orders', label: 'Daftar Order', icon: ClipboardList, permission: 'pos.order' },
      { to: '/kitchen', label: 'Layar Dapur', icon: ChefHat, permission: 'kds.update' },
      { to: '/shifts', label: 'Shift Kasir', icon: Timer, permission: 'pos.pay' },
    ],
  },
  {
    group: 'Back Office',
    items: [
      { to: '/menu', label: 'Menu', icon: UtensilsCrossed, permission: 'master.manage' },
      { to: '/products', label: 'Master Produk', icon: Boxes, permission: 'inventory.manage' },
      { to: '/inventory', label: 'Inventory', icon: Package, permission: 'inventory.manage' },
      { to: '/purchasing', label: 'Pembelian', icon: Truck, permission: 'purchasing.manage' },
      { to: '/customers', label: 'Pelanggan & Promo', icon: Gift, permission: 'crm.manage' },
    ],
  },
  {
    group: 'Manajemen',
    items: [
      { to: '/reports', label: 'Laporan', icon: BarChart3, permission: 'report.view' },
      { to: '/finance', label: 'Keuangan', icon: Wallet, permission: ['finance.view', 'finance.manage'] },
      { to: '/approvals', label: 'Persetujuan', icon: BadgeCheck, permission: 'pos.order', badge: 'approvals' },
      { to: '/settings', label: 'Pengaturan', icon: Settings, permission: ['user.manage', 'settings.manage', 'audit.view'] },
    ],
  },
];

const PIN_KEY = 'santap.sidebar_pinned';
const readPinned = () => {
  try { return localStorage.getItem(PIN_KEY) === '1'; } catch { return false; }
};

// Jumlah permintaan approval yang menunggu keputusan user ini (realtime)
function usePendingApprovals(enabled: boolean) {
  const [count, setCount] = useState(0);
  const refresh = useCallback(() => {
    rpc<number>('sys_count_my_pending_approvals').then(setCount).catch(() => setCount(0));
  }, []);
  useEffect(() => {
    if (!enabled) return;
    refresh();
    const ch = supabase.channel('approval-badge')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sys_approval_requests' }, refresh)
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [enabled, refresh]);
  return count;
}

export default function Layout() {
  const { profile, outlet, setOutletId, can, signOut } = useAuth();
  const location = useLocation();
  const [pinned, setPinned] = useState(readPinned);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [editingProfile, setEditingProfile] = useState(false);
  const pending = usePendingApprovals(!!profile);

  // tutup drawer HP setiap pindah halaman, perbarui judul tab
  useEffect(() => {
    setDrawerOpen(false);
    const item = NAV.flatMap((g) => g.items).find((i) => i.to === location.pathname);
    setDocumentTitle(item?.label);
  }, [location.pathname]);

  const togglePin = () => {
    setPinned((p) => {
      try { localStorage.setItem(PIN_KEY, p ? '0' : '1'); } catch { /* abaikan */ }
      return !p;
    });
  };

  const groups = NAV.map((g) => ({ ...g, items: g.items.filter((i) => can(i.permission)) })).filter((g) => g.items.length);

  return (
    <div className={`app-shell ${pinned ? 'sidebar-pinned' : ''} ${drawerOpen ? 'drawer-open' : ''}`}>
      {/* Topbar khusus HP / tablet */}
      <header className="topbar">
        <button className="icon-btn" onClick={() => setDrawerOpen(true)} aria-label="Buka menu"><MenuIcon size={22} /></button>
        <Logo src={profile?.company_logo_url} size={32} withName subtitle={outlet?.name} />
        {pending > 0 && (
          <NavLink to="/approvals" className="icon-btn btn" aria-label="Persetujuan">
            <BadgeCheck size={20} /><span className="nav-badge">{pending}</span>
          </NavLink>
        )}
        <button className="icon-btn" onClick={() => setEditingProfile(true)} aria-label="Profil">
          <Avatar name={profile?.full_name} src={profile?.avatar_url} size={32} />
        </button>
      </header>

      <div className="sidebar-backdrop" onClick={() => setDrawerOpen(false)} />

      <aside className="sidebar" aria-label="Navigasi utama">
        <div className="sidebar-head">
          <Logo src={profile?.company_logo_url} size={40} withName subtitle={profile?.company_name} textClassName="hide-collapsed" />
          <button className="icon-btn pin-btn hide-collapsed" onClick={togglePin} title={pinned ? 'Lepas pin (auto-hide)' : 'Pin sidebar'}>
            {pinned ? <PinOff size={16} /> : <Pin size={16} />}
          </button>
          <button className="icon-btn mobile-only" onClick={() => setDrawerOpen(false)} aria-label="Tutup menu"><X size={20} /></button>
        </div>

        <nav className="sidebar-nav">
          {groups.map((g) => (
            <div key={g.group}>
              <div className="nav-group hide-collapsed">{g.group}</div>
              {g.items.map(({ to, label, icon: Icon, badge }) => (
                <NavLink key={to} to={to} end={to === '/'} className="nav-link" title={label}>
                  <Icon size={20} />
                  <span className="hide-collapsed">{label}</span>
                  {badge === 'approvals' && pending > 0 && <span className="nav-badge">{pending}</span>}
                </NavLink>
              ))}
            </div>
          ))}
          {outlet && can('pos.order') && <QrOrderAlert outletId={outlet.id} />}
        </nav>

        <div className="sidebar-footer">
          {profile && profile.outlets.length > 1 && (
            <select className="hide-collapsed" value={outlet?.id} onChange={(e) => setOutletId(e.target.value)} aria-label="Outlet aktif">
              {profile.outlets.map((o) => <option key={o.id} value={o.id}>📍 {o.name}</option>)}
            </select>
          )}
          <button className="user-chip" onClick={() => setEditingProfile(true)} title="Profil saya">
            <Avatar name={profile?.full_name} src={profile?.avatar_url} size={40} />
            <span className="meta hide-collapsed">
              <strong>{profile?.full_name}</strong>
              <small>{profile?.role_name} · {outlet?.name}</small>
            </span>
          </button>
          <button className="nav-link-btn icon-btn" style={{ width: '100%', justifyContent: 'flex-start', gap: 14, padding: '0 14px', height: 40 }} onClick={signOut}>
            <LogOut size={20} /><span className="hide-collapsed">Keluar</span>
          </button>
        </div>
      </aside>

      <main className="main">
        <Suspense fallback={<div className="grid">{[1, 2, 3].map((i) => <div key={i} className="skeleton" style={{ height: 90 }} />)}</div>}>
          <Outlet />
        </Suspense>
      </main>

      {editingProfile && <ProfileModal onClose={() => setEditingProfile(false)} />}
    </div>
  );
}
