import { Suspense, useCallback, useEffect, useState } from 'react';
import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import {
  ArrowLeftRight, BadgeCheck, BarChart3, Banknote, Boxes, ChefHat, ChevronRight, ClipboardCheck, ClipboardList, FileText,
  Gift, HandCoins, LayoutDashboard, LogOut, Menu as MenuIcon, Package, PackageCheck, PackageOpen, Pin, PinOff, Receipt,
  IdCard, Megaphone, UserRound, Network, ScrollText, ServerCog, Settings, ShieldAlert, UserPlus, ShieldCheck, ShoppingCart, UserCog, History, Building2, CreditCard, DatabaseBackup, KeyRound, Store, Tags, Timer, Truck, Users, UtensilsCrossed, Wallet, Warehouse, X, type LucideIcon,
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { useFeedback } from './Feedback';
import { setDocumentTitle } from '../lib/brand';
import Logo from './Logo';
import { APPROVAL_DOCS } from './settings/approvalCatalog';
import Avatar from './Avatar';
import QrOrderAlert from './QrOrderAlert';
import ProfileModal from './ProfileModal';

// permission 'platform' = khusus Platform Admin (developer); 'self' = semua user yang login
interface NavItem { to: string; label: string; icon: LucideIcon; permission: string | string[]; badge?: 'approvals' | 'signups' }
interface NavGroup { group: string; icon: LucideIcon; items: NavItem[]; flat?: boolean }   // flat = tampil sebagai menu utama tanpa grup

// "to" boleh membawa ?tab=... supaya menu langsung membuka tab di halaman modul
const NAV: NavGroup[] = [
  {
    group: 'Ringkasan', icon: LayoutDashboard, flat: true,
    items: [
      { to: '/saya', label: 'Beranda Saya', icon: UserRound, permission: 'self' },
      { to: '/', label: 'Dashboard', icon: LayoutDashboard, permission: 'report.view' },
      { to: '/approvals', label: 'Persetujuan', icon: BadgeCheck, permission: ['pos.order', ...Object.keys(APPROVAL_DOCS).map((t) => `approval.${t}`)], badge: 'approvals' },
    ],
  },
  {
    group: 'Kasir & Outlet', icon: Receipt,
    items: [
      { to: '/pos', label: 'Kasir (POS)', icon: Receipt, permission: 'pos.order' },
      { to: '/orders', label: 'Daftar Order', icon: ClipboardList, permission: 'pos.order' },
      { to: '/kitchen', label: 'Layar Dapur', icon: ChefHat, permission: 'kds.update' },
      { to: '/shifts', label: 'Shift Kasir', icon: Timer, permission: 'pos.pay' },
      { to: '/settlement', label: 'Settlement POS', icon: Banknote, permission: ['finance.view', 'finance.manage'] },
      { to: '/customers', label: 'Member & Promo', icon: Gift, permission: 'crm.manage' },
    ],
  },
  {
    group: 'Penjualan', icon: ShoppingCart,
    items: [
      { to: '/sales?tab=orders', label: 'Sales Order', icon: ShoppingCart, permission: 'sales.manage' },
      { to: '/sales?tab=deliveries', label: 'Pengiriman', icon: Truck, permission: 'sales.manage' },
      { to: '/sales?tab=invoices', label: 'Invoice & Piutang', icon: FileText, permission: ['sales.manage', 'finance.view', 'finance.manage'] },
      { to: '/sales?tab=payments', label: 'Penerimaan Pembayaran', icon: HandCoins, permission: ['sales.manage', 'finance.view', 'finance.manage'] },
      { to: '/sales?tab=customers', label: 'Pelanggan B2B', icon: Users, permission: 'sales.manage' },
      { to: '/sales?tab=pricelists', label: 'Pricelist Jual', icon: Tags, permission: 'sales.manage' },
    ],
  },
  {
    group: 'Pembelian', icon: Truck,
    items: [
      { to: '/purchasing?tab=po', label: 'Purchase Order', icon: ScrollText, permission: 'purchasing.manage' },
      { to: '/purchasing?tab=receipts', label: 'Penerimaan Barang', icon: PackageCheck, permission: 'purchasing.manage' },
      { to: '/purchasing?tab=bills', label: 'Tagihan Cabang', icon: HandCoins, permission: ['purchasing.manage', 'finance.manage'] },
      { to: '/purchasing?tab=suppliers', label: 'Supplier', icon: Store, permission: 'purchasing.manage' },
      { to: '/purchasing?tab=pricelist', label: 'Pricelist Beli', icon: Tags, permission: 'purchasing.manage' },
    ],
  },
  {
    group: 'Persediaan', icon: Package,
    items: [
      { to: '/inventory?tab=stock', label: 'Stok', icon: Package, permission: 'inventory.manage' },
      { to: '/inventory?tab=documents', label: 'Dokumen Stok', icon: ClipboardCheck, permission: 'inventory.manage' },
      { to: '/inventory?tab=batches', label: 'Batch & Kedaluwarsa', icon: PackageOpen, permission: 'inventory.manage' },
      { to: '/inventory?tab=production', label: 'Produksi', icon: ChefHat, permission: 'inventory.manage' },
      { to: '/inventory?tab=movements', label: 'Kartu Stok', icon: ArrowLeftRight, permission: 'inventory.manage' },
      { to: '/inventory?tab=warehouses', label: 'Gudang & Lokasi', icon: Warehouse, permission: 'inventory.manage' },
    ],
  },
  {
    group: 'Master Data', icon: Boxes,
    items: [
      { to: '/products', label: 'Master Produk', icon: Boxes, permission: 'inventory.manage' },
      { to: '/menu', label: 'Menu', icon: UtensilsCrossed, permission: 'master.manage' },
    ],
  },
  {
    group: 'Keuangan & Laporan', icon: Wallet,
    items: [
      { to: '/finance', label: 'Keuangan', icon: Wallet, permission: ['finance.view', 'finance.manage'] },
      { to: '/reports', label: 'Laporan', icon: BarChart3, permission: 'report.view' },
    ],
  },
  {
    group: 'SDM / HR', icon: IdCard,
    items: [
      { to: '/hr?tab=employees', label: 'Karyawan', icon: Users, permission: ['hr.view', 'hr.manage'] },
      { to: '/hr?tab=structure', label: 'Jabatan & Departemen', icon: Network, permission: 'hr.manage' },
      { to: '/hr?tab=announcements', label: 'Pengumuman', icon: Megaphone, permission: 'hr.manage' },
    ],
  },
  {
    group: 'User Management', icon: UserCog,
    items: [
      { to: '/users?tab=users', label: 'User', icon: UserCog, permission: 'user.manage' },
      { to: '/users?tab=roles', label: 'Role & Hak Akses', icon: KeyRound, permission: 'user.manage' },
      { to: '/users?tab=approvals', label: 'Approval Transaksi', icon: ShieldCheck, permission: 'settings.manage' },
      { to: '/users?tab=logs', label: 'Log Aktivitas', icon: History, permission: ['audit.view', 'user.manage'] },
    ],
  },
  {
    group: 'Pengaturan', icon: Settings,
    items: [
      { to: '/settings?tab=company', label: 'Perusahaan & Logo', icon: Building2, permission: 'settings.manage' },
      { to: '/settings?tab=brands', label: 'Brand', icon: Tags, permission: 'settings.manage' },
      { to: '/settings?tab=outlets', label: 'Outlet', icon: Store, permission: 'settings.manage' },
      { to: '/settings?tab=payment', label: 'Pembayaran Online', icon: CreditCard, permission: 'settings.manage' },
      { to: '/settings?tab=data', label: 'Data & Backup', icon: DatabaseBackup, permission: '*' },
    ],
  },
  {
    group: 'Platform', icon: ServerCog,
    items: [
      { to: '/platform?tab=signups', label: 'Pendaftar', icon: UserPlus, permission: 'platform', badge: 'signups' },
      { to: '/platform?tab=companies', label: 'Semua Perusahaan', icon: Building2, permission: 'platform' },
      { to: '/platform?tab=groups', label: 'Grup Usaha', icon: Network, permission: 'platform' },
    ],
  },
];

// menu aktif: path sama & tab sama (tanpa ?tab = menu pertama dengan path itu)
function activeItem(pathname: string, search: string) {
  const items = NAV.flatMap((g) => g.items);
  const tab = new URLSearchParams(search).get('tab');
  const same = items.filter((i) => i.to.split('?')[0] === pathname);
  return same.find((i) => new URLSearchParams(i.to.split('?')[1] ?? '').get('tab') === tab) ?? same[0];
}

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

// Jumlah pendaftar baru untuk Platform Admin (cek berkala; event 'platform-signups-seen' = sudah dibuka)
function useNewSignups(enabled: boolean) {
  const [count, setCount] = useState(0);
  useEffect(() => {
    if (!enabled) { setCount(0); return; }
    const refresh = () => rpc<number>('sys_platform_new_signups').then(setCount).catch(() => setCount(0));
    refresh();
    const timer = window.setInterval(refresh, 120_000);
    window.addEventListener('platform-signups-seen', refresh);
    return () => { window.clearInterval(timer); window.removeEventListener('platform-signups-seen', refresh); };
  }, [enabled]);
  return count;
}

// Logo brand dari outlet aktif (fallback: logo perusahaan). Event 'brand-updated' = brand baru disimpan.
function useBrandLogo(brandId?: string) {
  const [logo, setLogo] = useState<string | null>(null);
  useEffect(() => {
    if (!brandId) { setLogo(null); return; }
    const load = () => { supabase.from('sys_brands').select('logo_url').eq('id', brandId).maybeSingle().then(({ data }) => setLogo(data?.logo_url ?? null)); };
    load();
    window.addEventListener('brand-updated', load);
    return () => window.removeEventListener('brand-updated', load);
  }, [brandId]);
  return logo;
}

export default function Layout() {
  const { profile, outlet, setOutletId, can, signOut, switchCompany } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const { toast } = useFeedback();
  const [pinned, setPinned] = useState(readPinned);
  // halaman lebar (page-sheet) menyesuaikan lebar sidebar
  useEffect(() => { document.body.classList.toggle('sidebar-pinned', pinned); }, [pinned]);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [editingProfile, setEditingProfile] = useState(false);
  const pending = usePendingApprovals(!!profile);
  const signups = useNewSignups(!!profile?.is_platform_admin);
  const logoSrc = useBrandLogo(outlet?.brand_id) ?? profile?.company_logo_url;
  const badgeCount = (b?: NavItem['badge']) => (b === 'approvals' ? pending : b === 'signups' ? signups : 0);
  const current = activeItem(location.pathname, location.search);
  const currentGroup = NAV.find((g) => g.items.includes(current!))?.group;
  // accordion: hanya 1 grup terbuka; default = grup halaman yang sedang dibuka
  const [open, setOpen] = useState<string | null>(currentGroup ?? null);

  // tutup drawer HP setiap pindah halaman, perbarui judul tab, buka grup menu yang aktif
  useEffect(() => {
    setDrawerOpen(false);
    setDocumentTitle(current?.label);
    if (currentGroup) setOpen(currentGroup);
  }, [current, currentGroup]);

  const toggleGroup = (g: string) => setOpen((o) => (o === g ? null : g));

  const togglePin = () => {
    setPinned((p) => {
      try { localStorage.setItem(PIN_KEY, p ? '0' : '1'); } catch { /* abaikan */ }
      return !p;
    });
  };

  const allowed = (i: NavItem) => (i.permission === 'self' ? !!profile : i.permission === 'platform' ? !!profile?.is_platform_admin : can(i.permission));
  const groups = NAV.map((g) => ({ ...g, items: g.items.filter(allowed) })).filter((g) => g.items.length);

  // PT yang bisa dipindah: PT sendiri + PT grup (+ PT yang sedang dimasuki mode support)
  const companies = [...(profile?.companies ?? [])];
  if (profile && !companies.some((c) => c.id === profile.company_id)) companies.push({ id: profile.company_id, name: profile.company_name, group_name: null });
  const changeCompany = async (id: string | null) => {
    try {
      await switchCompany(id === profile?.home_company_id ? null : id);
      navigate('/');
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <div className={`app-shell ${pinned ? 'sidebar-pinned' : ''} ${drawerOpen ? 'drawer-open' : ''}`}>
      {/* Topbar khusus HP / tablet */}
      <header className="topbar">
        <button className="icon-btn" onClick={() => setDrawerOpen(true)} aria-label="Buka menu"><MenuIcon size={22} /></button>
        <Logo src={logoSrc} size={32} withName subtitle={outlet?.name} />
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
          <Logo src={logoSrc} size={40} withName subtitle={profile?.company_name} textClassName="hide-collapsed" />
          <button className="icon-btn pin-btn hide-collapsed" onClick={togglePin} title={pinned ? 'Lepas pin (auto-hide)' : 'Pin sidebar'}>
            {pinned ? <PinOff size={16} /> : <Pin size={16} />}
          </button>
          <button className="icon-btn mobile-only" onClick={() => setDrawerOpen(false)} aria-label="Tutup menu"><X size={20} /></button>
        </div>

        <nav className="sidebar-nav">
          {groups.map((g) => {
            // menu utama tanpa grup (Dashboard, Persetujuan)
            if (g.flat) {
              return (
                <div key={g.group} className="nav-top">
                  {g.items.map((item) => {
                    const { to, label, icon: Icon, badge } = item;
                    return (
                      <Link key={to} to={to} className={`nav-link ${item === current ? 'active' : ''}`} title={label}
                        aria-current={item === current ? 'page' : undefined}>
                        <Icon size={20} />
                        <span className="hide-collapsed">{label}</span>
                        {badgeCount(badge) > 0 && <span className="nav-badge">{badgeCount(badge)}</span>}
                      </Link>
                    );
                  })}
                </div>
              );
            }
            const groupBadge = g.items.reduce((n, i) => n + badgeCount(i.badge), 0);
            const isOpen = open === g.group;
            const hasActive = g.group === currentGroup;
            return (
              <div key={g.group} className={`nav-section ${isOpen ? 'open' : ''} ${hasActive ? 'has-active' : ''}`}>
                <button type="button" className="nav-group-btn" onClick={() => toggleGroup(g.group)} aria-expanded={isOpen} title={g.group}>
                  <g.icon size={20} className="nav-group-icon" />
                  <span className="hide-collapsed">{g.group}</span>
                  {!isOpen && groupBadge > 0 && <span className="nav-badge">{groupBadge}</span>}
                  <ChevronRight size={16} className="nav-chevron hide-collapsed" />
                </button>
                {isOpen && (
                  <div className="nav-sub">
                    {g.items.map((item) => {
                      const { to, label, badge } = item;
                      return (
                        <Link key={to} to={to} className={`nav-sublink ${item === current ? 'active' : ''}`} title={label}
                          aria-current={item === current ? 'page' : undefined}>
                          <span>{label}</span>
                          {badgeCount(badge) > 0 && <span className="nav-badge">{badgeCount(badge)}</span>}
                        </Link>
                      );
                    })}
                  </div>
                )}
              </div>
            );
          })}
          {outlet && can('pos.order') && <QrOrderAlert outletId={outlet.id} />}
        </nav>

        <div className="sidebar-footer">
          {companies.length > 1 && (
            <select className="hide-collapsed" value={profile?.company_id} onChange={(e) => changeCompany(e.target.value)} aria-label="Perusahaan aktif">
              {companies.map((c) => <option key={c.id} value={c.id}>🏢 {c.name}{c.id === profile?.home_company_id ? ' (PT saya)' : ''}</option>)}
            </select>
          )}
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
          <button className="icon-btn logout-btn" onClick={signOut}>
            <LogOut size={20} /><span className="hide-collapsed">Keluar</span>
          </button>
        </div>
      </aside>

      <main className="main" key={profile?.company_id}>
        {profile?.acting_mode && (
          <div className={`acting-banner ${profile.acting_mode}`}>
            <ShieldAlert size={18} />
            <span>
              {profile.acting_mode === 'support'
                ? <>Mode support: Anda masuk ke <b>{profile.company_name}</b> sebagai Platform support. Semua perubahan dicatat di log aktivitas PT ini.</>
                : <>Anda di <b>{profile.company_name}</b>{profile.group_name ? ` (grup ${profile.group_name})` : ''} sebagai Pemilik grup.</>}
            </span>
            <button className="btn-sm" onClick={() => changeCompany(null)}>Kembali ke {profile.home_company_name ?? 'PT saya'}</button>
          </div>
        )}
        <Suspense fallback={<div className="grid">{[1, 2, 3].map((i) => <div key={i} className="skeleton" style={{ height: 90 }} />)}</div>}>
          <Outlet />
        </Suspense>
      </main>

      {editingProfile && <ProfileModal onClose={() => setEditingProfile(false)} />}
    </div>
  );
}
