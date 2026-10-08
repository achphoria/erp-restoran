import { Suspense } from 'react';
import { lazyRetry } from './lib/lazyRetry';
import ErrorBoundary from './components/ErrorBoundary';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { AuthProvider, useAuth } from './context/AuthContext';
import Layout from './components/Layout';
import LoginPage from './pages/LoginPage';
import OnboardingPage from './pages/OnboardingPage';
const DashboardPage = lazyRetry(() => import('./pages/DashboardPage'));
const PosPage = lazyRetry(() => import('./pages/PosPage'));
const OrdersPage = lazyRetry(() => import('./pages/OrdersPage'));
const KitchenPage = lazyRetry(() => import('./pages/KitchenPage'));
const ShiftsPage = lazyRetry(() => import('./pages/ShiftsPage'));
const MenuPage = lazyRetry(() => import('./pages/MenuPage'));
const InventoryPage = lazyRetry(() => import('./pages/InventoryPage'));
const PurchasingPage = lazyRetry(() => import('./pages/PurchasingPage'));
const ReportsPage = lazyRetry(() => import('./pages/ReportsPage'));
const FinancePage = lazyRetry(() => import('./pages/FinancePage'));
const SettingsPage = lazyRetry(() => import('./pages/SettingsPage'));
const CustomersPage = lazyRetry(() => import('./pages/CustomersPage'));
const ProductsPage = lazyRetry(() => import('./pages/ProductsPage'));
const PublicOrderPage = lazyRetry(() => import('./pages/PublicOrderPage'));
const ApprovalsPage = lazyRetry(() => import('./pages/ApprovalsPage'));
const SalesPage = lazyRetry(() => import('./pages/SalesPage'));
const SettlementPage = lazyRetry(() => import('./pages/SettlementPage'));
const PaymentReturnPage = lazyRetry(() => import('./pages/PaymentReturnPage'));
const PlatformPage = lazyRetry(() => import('./pages/PlatformPage'));
const HrPage = lazyRetry(() => import('./pages/HrPage'));
const MyHomePage = lazyRetry(() => import('./pages/MyHomePage'));
const TasksPage = lazyRetry(() => import('./pages/TasksPage'));
const LandingPage = lazyRetry(() => import('./pages/LandingPage'));
import { FeedbackProvider } from './components/Feedback';
import { APPROVAL_DOCS } from './components/settings/approvalCatalog';

function Guard({ permission, children }: { permission: string | string[]; children: React.ReactNode }) {
  const { can } = useAuth();
  if (!can(permission)) {
    return <div className="card empty">Anda tidak punya akses ke halaman ini.</div>;
  }
  return <>{children}</>;
}

function Home() {
  const { can } = useAuth();
  if (can('report.view')) return <DashboardPage />;
  if (can('pos.order')) return <Navigate to="/pos" replace />;
  if (can('kds.update')) return <Navigate to="/kitchen" replace />;
  if (can(Object.keys(APPROVAL_DOCS).map((t) => `approval.${t}`))) return <Navigate to="/approvals" replace />;
  return <Navigate to="/saya" replace />;
}

function AppRoutes() {
  const { session, profile, loading } = useAuth();

  // belum login: beranda = landing page, alamat lain (mis. /login, /pos setelah keluar) = form masuk
  if (!session) {
    return (
      <Routes>
        <Route index element={<LandingPage />} />
        <Route path="*" element={<LoginPage />} />
      </Routes>
    );
  }
  if (loading) return <div className="auth-page"><div className="skeleton" style={{ width: 280, height: 160 }} /></div>;
  if (!profile) return <OnboardingPage />;

  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Home />} />
        <Route path="pos" element={<Guard permission="pos.order"><PosPage /></Guard>} />
        <Route path="orders" element={<Guard permission="pos.order"><OrdersPage /></Guard>} />
        <Route path="kitchen" element={<Guard permission="kds.update"><KitchenPage /></Guard>} />
        <Route path="shifts" element={<Guard permission="pos.pay"><ShiftsPage /></Guard>} />
        <Route path="menu" element={<Guard permission="master.manage"><MenuPage /></Guard>} />
        <Route path="products" element={<Guard permission="inventory.manage"><ProductsPage /></Guard>} />
        <Route path="inventory" element={<Guard permission="inventory.manage"><InventoryPage /></Guard>} />
        <Route path="purchasing" element={<Guard permission="purchasing.manage"><PurchasingPage /></Guard>} />
        <Route path="sales" element={<Guard permission={['sales.manage', 'finance.view', 'finance.manage']}><SalesPage /></Guard>} />
        <Route path="settlement" element={<Guard permission={['finance.view', 'finance.manage']}><SettlementPage /></Guard>} />
        <Route path="reports" element={<Guard permission="report.view"><ReportsPage /></Guard>} />
        <Route path="customers" element={<Guard permission="crm.manage"><CustomersPage /></Guard>} />
        <Route path="finance" element={<Guard permission={['finance.view', 'finance.manage']}><FinancePage /></Guard>} />
        <Route path="settings" element={<Guard permission="settings.manage"><SettingsPage section="settings" /></Guard>} />
        <Route path="users" element={<Guard permission={['user.manage', 'settings.manage', 'audit.view']}><SettingsPage section="users" /></Guard>} />
        <Route path="approvals" element={<ApprovalsPage />} />
        <Route path="platform" element={<PlatformPage />} />
        <Route path="saya" element={<MyHomePage />} />
        <Route path="tugas" element={<TasksPage />} />
        <Route path="hr" element={<Guard permission={['hr.view', 'hr.manage', 'hr.attendance', 'approval.leave']}><HrPage /></Guard>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export default function App() {
  return (
    <ErrorBoundary>
    <FeedbackProvider>
    <AuthProvider>
      <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, '') || '/'}>
        <Suspense fallback={<div className="main"><div className="skeleton" style={{ height: 200 }} /></div>}>
        <Routes>
          {/* publik, tanpa login: halaman pesan dari QR meja */}
          <Route path="/order/:token" element={<PublicOrderPage />} />
          <Route path="/payment-return" element={<PaymentReturnPage />} />
          <Route path="*" element={<AppRoutes />} />
        </Routes>
        </Suspense>
      </BrowserRouter>
    </AuthProvider>
    </FeedbackProvider>
    </ErrorBoundary>
  );
}
