export interface Outlet {
  id: string;
  code: string;
  name: string;
  brand_id?: string;
}

export interface Profile {
  user_id: string;
  full_name: string;
  phone: string | null;
  avatar_url: string | null;
  email: string;
  company_id: string;
  company_name: string;
  company_logo_url: string | null;
  company_app_name: string | null;
  role_code: string;
  role_name: string;
  permissions: string[];
  outlets: Outlet[];
  outlet_scope?: 'all' | 'selected' | 'brands';
  /** developer / pengelola platform (diberikan lewat SQL) */
  is_platform_admin?: boolean;
  /** null = di PT sendiri; 'group' = pemilik grup di PT lain; 'support' = platform admin di PT lain */
  acting_mode?: 'group' | 'support' | null;
  home_company_id?: string;
  home_company_name?: string;
  group_name?: string | null;
  /** PT yang bisa dipindah: PT sendiri + PT di grup usaha */
  companies?: { id: string; name: string; group_name: string | null }[];
}

export interface MenuCategory {
  id: string;
  name: string;
  sort_order: number;
  is_active: boolean;
}

export interface MenuItem {
  id: string;
  code: string;
  name: string;
  menu_category_id: string;
  base_price: number;
  station: string;
  is_active: boolean;
  description?: string | null;
  image_url?: string | null;
}

export interface Modifier {
  id: string;
  name: string;
  extra_price: number;
  sort_order: number;
  modifier_group_id: string;
  is_default?: boolean;
  menu_item_id?: string | null;
}

export interface ModifierGroup {
  id: string;
  name: string;
  min_select: number;
  max_select: number;
  group_type?: 'modifier' | 'package';
  mst_modifiers: Modifier[];
}

export interface DiningTable {
  id: string;
  code: string;
  status: string;
  capacity: number;
  table_area_id: string | null;
}

export interface PaymentMethod {
  id: string;
  code: string;
  name: string;
  type: string;
}

export interface OrderItem {
  id: string;
  order_id: string;
  menu_item_name: string;
  quantity: number;
  unit_price: number;
  modifier_amount: number;
  line_total: number;
  note: string | null;
  station: string;
  kitchen_status: string;
  is_void: boolean;
  created_at: string;
  pos_order_item_modifiers?: { modifier_name: string }[];
}

export interface Order {
  id: string;
  outlet_id: string;
  order_number: string;
  business_date: string;
  sales_channel: string;
  customer_name: string | null;
  guest_count: number;
  status: string;
  subtotal: number;
  discount_amount: number;
  service_amount: number;
  tax_amount: number;
  rounding_amount: number;
  grand_total: number;
  table_id: string | null;
  created_at: string;
  paid_at: string | null;
  customer_id: string | null;
  promotion_id: string | null;
  promotion_amount: number;
  points_redeemed: number;
  points_amount: number;
  points_earned: number;
  order_source: string;
  queue_number?: string | null;
  mst_tables?: { code: string } | null;
  pos_order_items?: OrderItem[];
}

export interface CustomerSummary {
  id: string;
  code: string;
  name: string;
  phone: string;
  points_balance: number;
  tier_name: string | null;
}

export interface Shift {
  id: string;
  outlet_id: string;
  business_date: string;
  opening_cash: number;
  closing_cash: number | null;
  expected_cash: number | null;
  opened_at: string;
  closed_at: string | null;
  status: string;
}
