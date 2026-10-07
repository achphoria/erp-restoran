export interface Unit { id: string; code: string; name: string; metric: 'unit' | 'weight' | 'volume'; notes: string | null }
export interface Category {
  id: string; code: string | null; name: string; category_type: string; notes: string | null; is_active: boolean;
  inventory_account_id: string | null; cogs_account_id: string | null; sales_account_id: string | null; adjustment_account_id: string | null;
}
export interface SubCategory { id: string; code: string | null; name: string; notes: string | null; is_active: boolean }
export interface Account { id: string; code: string; name: string; account_type: string; is_header: boolean }
export interface Warehouse { id: string; code: string; name: string; outlet_id: string | null }
export interface CustomField { slot: number; label: string; is_active: boolean }
export interface ItemUnit {
  id?: string; unit_id: string; conversion_qty: number; sku: string | null; barcode: string | null;
  weight_kg: number | null; volume_cm3: number | null;
  is_purchase_unit: boolean; is_transfer_unit: boolean; is_sales_unit: boolean;
}
export interface Product {
  id: string; code: string; name: string; item_type: string; item_category_id: string | null; sub_category_id: string | null;
  base_unit_id: string; min_stock: number; last_purchase_cost: number; is_active: boolean;
  is_purchasable: boolean; is_saleable: boolean; is_requestable: boolean; is_taxable: boolean;
  receipt_tolerance_pct: number; track_batch: boolean; shelf_life_days: number | null; notes: string | null; custom_fields: Record<string, string>; approval_status: string;
  inv_item_units?: ItemUnit[];
}

export interface MasterData {
  companyId: string;
  units: Unit[];
  categories: Category[];
  subCategories: SubCategory[];
  accounts: Account[];
  warehouses: Warehouse[];
  customFields: CustomField[];
  reload: () => Promise<void>;
}

export const ITEM_TYPES: Record<string, string> = {
  raw: 'Bahan baku', semi_finished: 'Setengah jadi', finished: 'Barang jadi', packaging: 'Kemasan', consumable: 'Habis pakai',
};
export const CATEGORY_TYPES: Record<string, string> = {
  inventory: 'Inventory', non_inventory: 'Non Inventory', asset: 'Asset', non_depreciated_asset: 'Asset Tidak Disusutkan',
};
export const METRICS: Record<string, string> = { unit: 'Unit / pcs', weight: 'Berat', volume: 'Volume' };
