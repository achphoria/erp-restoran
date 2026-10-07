import { must, rpc, supabase } from '../../lib/supabase';
import { todayISO } from '../../lib/format';
import type { LabelData } from '../../lib/barcode';

export interface BatchOption {
  id: string; item_id: string; batch_code: string; lot_number: string | null; expiry_date: string | null;
  qty_remaining: number; unit_cost: number;
}

export interface ScanResult {
  kind: 'package' | 'delivery_package' | 'batch' | 'item';
  delivery_id?: string; delivery_number?: string; goods_receipt_id?: string | null;
  item_id?: string; item_code?: string; item_name?: string; unit_code?: string; qty?: number; scanned_unit?: string;
  batch_id?: string; batch_code?: string; warehouse_id?: string; qty_remaining?: number; expiry_date?: string | null; lot_number?: string | null;
  package_id?: string; package_code?: string; package_no?: number; status?: string; stock_transfer_id?: string; transfer_number?: string;
}

// Barcode -> koli / label batch / barcode produk / kode produk (null = tidak dikenal)
export const resolveBarcode = (code: string, warehouseId?: string) =>
  rpc<ScanResult | null>('inv_resolve_barcode', { p_code: code, p_warehouse_id: warehouseId || null });

// Batch yang masih ada sisa di gudang, urut FEFO (kedaluwarsa terdekat) lalu FIFO
export const loadBatches = (warehouseId: string): Promise<BatchOption[]> =>
  must(supabase.from('rpt_stock_batches').select('id, item_id, batch_code, lot_number, expiry_date, qty_remaining, unit_cost')
    .eq('warehouse_id', warehouseId).gt('qty_remaining', 0)
    .order('expiry_date', { ascending: true, nullsFirst: false }).order('received_at'));

export const daysLeft = (expiry: string | null | undefined) =>
  expiry ? Math.round((Date.parse(`${expiry}T00:00:00`) - Date.parse(`${todayISO()}T00:00:00`)) / 86400000) : null;

export const NEAR_EXPIRY_DAYS = 7;

// [teks, kelas badge] untuk status kedaluwarsa
export function expiryInfo(expiry: string | null | undefined): [string, string] {
  const d = daysLeft(expiry);
  if (d === null) return ['Tanpa kedaluwarsa', 'badge'];
  if (d < 0) return [`Kedaluwarsa ${-d} hari lalu`, 'badge-danger'];
  if (d === 0) return ['Kedaluwarsa hari ini', 'badge-danger'];
  if (d <= NEAR_EXPIRY_DAYS) return [`${d} hari lagi`, 'badge-warning'];
  return [`${d} hari lagi`, 'badge-success'];
}

export const formatDate = (d: string | null | undefined) =>
  d ? new Date(d.length === 10 ? `${d}T00:00:00` : d).toLocaleDateString('id-ID', { day: '2-digit', month: 'short', year: '2-digit' }) : '-';

export function batchLabel(b: { batch_code: string; item_name: string; lot_number?: string | null; expiry_date?: string | null; received_at?: string | null }): LabelData {
  return {
    code: b.batch_code,
    title: b.item_name,
    lines: [
      `EXP ${formatDate(b.expiry_date)}${b.lot_number ? ` · Lot ${b.lot_number}` : ''}`,
      b.received_at ? `Terima ${formatDate(b.received_at)}` : '',
    ],
  };
}
