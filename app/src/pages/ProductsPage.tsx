import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import { must, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/format';
import type { MasterData } from '../components/products/types';
import ProductsTab from '../components/products/ProductsTab';
import CategoriesTab from '../components/products/CategoriesTab';
import SubCategoriesTab from '../components/products/SubCategoriesTab';
import UnitsTab from '../components/products/UnitsTab';
import StockLevelsTab from '../components/products/StockLevelsTab';
import RecipesTab from '../components/products/RecipesTab';
import FoodCostCalculator from '../components/products/FoodCostCalculator';
import CustomFieldsTab from '../components/products/CustomFieldsTab';

type Tab = 'products' | 'categories' | 'sub' | 'units' | 'levels' | 'recipes' | 'calculator' | 'fields';

const TABS: [Tab, string][] = [
  ['products', 'Produk'], ['categories', 'Kategori'], ['sub', 'Sub Kategori'], ['units', 'Satuan'],
  ['levels', 'Min/Max per Gudang'], ['recipes', 'Resep (BOM)'], ['calculator', 'Kalkulator Food Cost'], ['fields', 'Field Tambahan'],
];

// Master Produk ala ESB: produk/bahan, kategori bertipe + akun, satuan, min/max per gudang, BOM, kalkulator
export default function ProductsPage() {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [tab, setTab] = useState<Tab>('products');
  const [data, setData] = useState<Omit<MasterData, 'reload' | 'companyId'> | null>(null);

  const load = useCallback(async () => {
    try {
      const [units, categories, subCategories, accounts, warehouses, customFields] = await Promise.all([
        must(supabase.from('inv_units').select('*').order('code')),
        must(supabase.from('inv_item_categories').select('*').order('name')),
        must(supabase.from('inv_item_sub_categories').select('*').order('name')),
        must(supabase.from('fin_accounts').select('id, code, name, account_type, is_header').eq('is_active', true).order('code')).catch(() => []),
        must(supabase.from('inv_warehouses').select('id, code, name, outlet_id').eq('is_active', true).order('code')),
        must(supabase.from('inv_item_custom_fields').select('*').order('slot')),
      ]);
      setData({ units, categories, subCategories, accounts, warehouses, customFields });
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  }, [toast]);

  useEffect(() => { load(); }, [load]);

  const ctx: MasterData | null = data ? { ...data, companyId: profile!.company_id, reload: load } : null;

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Master Produk</h1>
          <p>Bahan baku, barang jadi, kemasan, satuan, kategori & akun, resep (BOM), dan biaya.</p>
        </div>
      </div>
      <div className="tabs">
        {TABS.map(([k, v]) => <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>)}
      </div>
      {!ctx ? (
        <div className="grid">{[1, 2, 3].map((i) => <div key={i} className="skeleton" style={{ height: 64 }} />)}</div>
      ) : (
        <>
          {tab === 'products' && <ProductsTab {...ctx} />}
          {tab === 'categories' && <CategoriesTab {...ctx} />}
          {tab === 'sub' && <SubCategoriesTab {...ctx} />}
          {tab === 'units' && <UnitsTab {...ctx} />}
          {tab === 'levels' && <StockLevelsTab {...ctx} />}
          {tab === 'recipes' && <RecipesTab {...ctx} />}
          {tab === 'calculator' && <FoodCostCalculator {...ctx} />}
          {tab === 'fields' && <CustomFieldsTab {...ctx} />}
        </>
      )}
    </>
  );
}
