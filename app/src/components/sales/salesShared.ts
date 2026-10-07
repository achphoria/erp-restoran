import { must, supabase } from '../../lib/supabase';

export interface InvoiceRow {
  id: string; outlet_id: string; seller_name: string; sales_order_id: string; so_number: string | null;
  customer_type: 'internal' | 'external'; buyer_outlet_id: string | null; customer_id: string | null; customer_name: string;
  invoice_number: string; invoice_date: string; due_date: string; subtotal: number; tax_amount: number; grand_total: number;
  paid_amount: number; credited_amount: number; outstanding_amount: number; status: string; is_overdue: boolean;
}
export interface CashAccount { id: string; code: string; name: string }

export interface Customer {
  id: string; code: string; name: string; contact_name: string | null; phone: string | null; email: string | null; address: string | null;
  tax_number: string | null; payment_term_days: number; credit_limit: number; notes: string | null; is_active: boolean;
}
export interface SalesMaster {
  companyId: string;
  outlets: { id: string; code: string; name: string; address: string | null }[];
  warehouses: { id: string; code: string; name: string; outlet_id: string | null }[];
  items: { id: string; code: string; name: string; base_unit_id: string; inv_units: { code: string } }[];
  itemUnits: { item_id: string; unit_id: string; conversion_qty: number; inv_units: { code: string } }[];
  customers: Customer[];
  reload: () => void;
}

// satuan yang bisa dipakai sebuah produk (satuan dasar dulu)
export function unitOptions(m: SalesMaster, itemId: string) {
  const it = m.items.find((i) => i.id === itemId);
  if (!it) return [];
  return [{ unit_id: it.base_unit_id, code: it.inv_units.code, conversion: 1 },
    ...m.itemUnits.filter((u) => u.item_id === itemId && u.unit_id !== it.base_unit_id)
      .map((u) => ({ unit_id: u.unit_id, code: u.inv_units.code, conversion: Number(u.conversion_qty) }))];
}

export const INVOICE_STATUS: Record<string, [string, string]> = {
  unpaid: ['Belum bayar', 'badge-warning'], partial: ['Sebagian', 'badge-info'], paid: ['Lunas', 'badge-success'],
};

export const SO_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge'], new: ['Baru (perlu konfirmasi)', 'badge-warning'], pending_approval: ['Menunggu persetujuan', 'badge-warning'], confirmed: ['Dikonfirmasi', 'badge-info'],
  partially_delivered: ['Dikirim sebagian', 'badge-info'], delivered: ['Terkirim', 'badge-success'], closed: ['Ditutup', 'badge'],
  rejected: ['Ditolak', 'badge-danger'], cancelled: ['Batal', 'badge-danger'],
};

export const DELIVERY_STATUS: Record<string, [string, string]> = {
  draft: ['Draft', 'badge-warning'], shipped: ['Dikirim', 'badge-info'], received: ['Diterima pembeli', 'badge-success'], cancelled: ['Batal', 'badge-danger'],
};

// Akun kas & bank (untuk pembayaran / settlement); kosong bila user tidak punya akses Keuangan
export const loadCashAccounts = (): Promise<CashAccount[]> =>
  must(supabase.from('fin_accounts').select('id, code, name, system_key').eq('account_type', 'asset').eq('is_header', false)
    .eq('is_active', true).or('code.like.1-11%,code.like.1-12%').order('code')).catch(() => []);
