import { lazy, Suspense } from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { AuthProvider, useAuth } from './context/AuthContext';
import Layout from './components/Layout';
import LoginPage from './pages/LoginPage';
import OnboardingPage from './pages/OnboardingPage';
const DashboardPage = lazy(() => import('./pages/DashboardPage'));
const PosPage = lazy(() => import('./pages/PosPage'));
const OrdersPage = lazy(() => import('./pages/OrdersPage'));
const KitchenPage = lazy(() => import('./pages/KitchenPage'));
const ShiftsPage = lazy(() => import('./pages/ShiftsPage'));
const MenuPage = lazy(() => import('./pages/MenuPage'));
const InventoryPage = lazy(() => import('./pages/InventoryPage'));
const PurchasingPage = lazy(() => import('./pages/PurchasingPage'));
const ReportsPage = lazy(() => import('./pages/ReportsPage'));
const FinancePage = lazy(() => import('./pages/FinancePage'));
const SettingsPage = lazy(() => import('./pages/SettingsPage'));
const CustomersPage = lazy(() => import('./pages/CustomersPage'));
const ProductsPage = lazy(() => import('./pages/ProductsPage'));
const PublicOrderPage = lazy(() => import('./pages/PublicOrderPage'));
const ApprovalsPage = lazy(() => import('./pages/ApprovalsPage'));
const SalesPage = lazy(() => import('./pages/SalesPage'));
const SettlementPage = lazy(() => import('./pages/SettlementPage'));
const PaymentReturnPage = lazy(() => import('./pages/PaymentReturnPage'));
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
  return <div className="card empty">Role Anda belum punya akses ke menu apa pun.</div>;
}

function AppRoutes() {
  const { session, profile, loading } = useAuth();

  if (!session) return <LoginPage />;
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
        <Route path="settings" element={<Guard permission={['user.manage', 'settings.manage', 'audit.view']}><SettingsPage /></Guard>} />
        <Route path="approvals" element={<ApprovalsPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export default function App() {
  return (
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
  );
}
