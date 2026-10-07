import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import { must, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import SalesOrdersTab from '../components/sales/SalesOrdersTab';
import DeliveriesTab from '../components/sales/DeliveriesTab';
import InvoicesTab from '../components/sales/InvoicesTab';
import PaymentsTab from '../components/sales/PaymentsTab';
import CustomersTab from '../components/sales/CustomersTab';
import SalesPricelistsTab from '../components/sales/SalesPricelistsTab';
import type { SalesMaster } from '../components/sales/salesShared';

type Tab = 'orders' | 'deliveries' | 'invoices' | 'payments' | 'customers' | 'pricelists';
const TABS: [Tab, string][] = [
  ['orders', 'Sales Order'], ['deliveries', 'Pengiriman'], ['invoices', 'Invoice & Piutang'],
  ['payments', 'Penerimaan Pembayaran'], ['customers', 'Pelanggan B2B'], ['pricelists', 'Pricelist Jual'],
];

// Penjualan non-POS: Sales Order antar cabang (otomatis dari PO cabang) & pelanggan B2B
export default function SalesPage() {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [tab, setTab] = useTabParam<Tab>('orders', TABS.map(([k]) => k));
  const [master, setMaster] = useState<Omit<SalesMaster, 'reload'> | null>(null);

  const load = useCallback(async () => {
    const [o, w, i, iu, c] = await Promise.all([
      must(supabase.from('sys_outlets').select('id, code, name, address').order('code')),
      must(supabase.from('inv_warehouses').select('id, code, name, outlet_id').eq('is_active', true).order('code')),
      must(supabase.from('inv_items').select('id, code, name, base_unit_id, inv_units(code)').eq('is_active', true).eq('approval_status', 'approved').order('name')),
      must(supabase.from('inv_item_units').select('item_id, unit_id, conversion_qty, inv_units(code)')),
      must(supabase.from('sal_customers').select('*').order('name')),
    ]);
    setMaster({ companyId: profile!.company_id, outlets: o, warehouses: w, items: i, itemUnits: iu, customers: c });
  }, [profile]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const m: SalesMaster | null = master && { ...master, reload: () => { load().catch(() => undefined); } };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Penjualan</h1>
          <p>Sales Order antar cabang (otomatis dari PO cabang pembeli) & pelanggan B2B: pengiriman, invoice, dan pembayaran.</p>
        </div>
      </div>
      <div className="tabs">
        {TABS.map(([k, v]) => <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>)}
      </div>
      {!m ? <div className="skeleton" style={{ height: 200 }} /> : <>
        {tab === 'orders' && <SalesOrdersTab m={m} />}
        {tab === 'deliveries' && <DeliveriesTab m={m} />}
        {tab === 'invoices' && <InvoicesTab />}
        {tab === 'payments' && <PaymentsTab />}
        {tab === 'customers' && <CustomersTab m={m} />}
        {tab === 'pricelists' && <SalesPricelistsTab m={m} />}
      </>}
    </>
  );
}
