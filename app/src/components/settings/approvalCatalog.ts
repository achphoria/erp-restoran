import {
  ArrowLeftRight, Banknote, BookOpen, Boxes, ClipboardList, FileMinus, HandCoins, PackageX, Receipt, ShoppingCart, Tags, Truck, Wallet,
  type LucideIcon,
} from 'lucide-react';

export interface ApprovalDoc {
  label: string; group: string; icon: LucideIcon; desc: string;
  amountLabel: string | null;          // null = tanpa batas nominal
  creatorPerms: string[];              // hak akses modul untuk membuat dokumen
}

// Katalog semua transaksi yang bisa diberi approval (urutan = urutan tampil)
export const APPROVAL_DOCS: Record<string, ApprovalDoc> = {
  sales_order:      { label: 'Sales Order', group: 'Penjualan', icon: ShoppingCart, desc: 'Konfirmasi SO cabang & B2B', amountLabel: 'Total SO minimal', creatorPerms: ['sales.manage'] },
  credit_note:      { label: 'Nota Kredit', group: 'Penjualan', icon: FileMinus, desc: 'Pengurang tagihan / piutang', amountLabel: 'Nominal minimal', creatorPerms: ['sales.manage'] },
  sales_payment:    { label: 'Pembayaran Invoice', group: 'Penjualan', icon: HandCoins, desc: 'Terima pembayaran B2B & bayar tagihan cabang', amountLabel: 'Nominal minimal', creatorPerms: ['sales.manage', 'finance.manage', 'purchasing.manage'] },
  refund:           { label: 'Refund POS', group: 'Kasir', icon: Receipt, desc: 'Refund order yang sudah dibayar', amountLabel: 'Nominal minimal', creatorPerms: ['pos.refund'] },
  pos_settlement:   { label: 'Settlement POS', group: 'Kasir', icon: Banknote, desc: 'Setoran / pencairan dengan selisih', amountLabel: 'Selisih minimal', creatorPerms: ['finance.manage'] },
  purchase_order:   { label: 'Purchase Order', group: 'Pembelian', icon: Truck, desc: 'PO ke supplier & cabang', amountLabel: 'Total PO minimal', creatorPerms: ['purchasing.manage'] },
  pricelist:        { label: 'Pricelist Supplier', group: 'Pembelian', icon: Tags, desc: 'Harga beli baru berlaku', amountLabel: null, creatorPerms: ['purchasing.manage'] },
  supplier_payment: { label: 'Bayar Supplier', group: 'Pembelian', icon: Wallet, desc: 'Pembayaran hutang supplier', amountLabel: 'Nominal minimal', creatorPerms: ['finance.manage'] },
  stock_adjustment: { label: 'Penyesuaian / Waste', group: 'Persediaan', icon: PackageX, desc: 'Termasuk pemakaian & penyusutan', amountLabel: 'Nilai minimal', creatorPerms: ['inventory.manage'] },
  stock_opname:     { label: 'Stock Opname', group: 'Persediaan', icon: ClipboardList, desc: 'Posting selisih hitung fisik', amountLabel: 'Nilai selisih minimal', creatorPerms: ['inventory.manage'] },
  stock_transfer:   { label: 'Transfer Gudang', group: 'Persediaan', icon: ArrowLeftRight, desc: 'Kirim barang antar gudang', amountLabel: 'Nilai barang minimal', creatorPerms: ['inventory.manage'] },
  product:          { label: 'Produk Baru', group: 'Persediaan', icon: Boxes, desc: 'Produk baru bisa dipakai', amountLabel: null, creatorPerms: ['inventory.manage'] },
  expense:          { label: 'Biaya Operasional', group: 'Keuangan', icon: Wallet, desc: 'Pencatatan biaya', amountLabel: 'Nominal minimal', creatorPerms: ['finance.manage'] },
  manual_journal:   { label: 'Jurnal Manual', group: 'Keuangan', icon: BookOpen, desc: 'Jurnal umum buatan user', amountLabel: 'Total debit minimal', creatorPerms: ['finance.manage'] },
};

// Ringkas: hak akses modul & cakupannya (untuk peringatan saat diubah dari matriks)
export const MODULE_PERMS: Record<string, string> = {
  'sales.manage': 'Penjualan (SO, pengiriman, invoice, pelanggan B2B, pricelist jual)',
  'purchasing.manage': 'Pembelian (PO, penerimaan, supplier, pricelist beli)',
  'inventory.manage': 'Persediaan (stok, dokumen stok, transfer, produksi, produk)',
  'finance.manage': 'Keuangan (biaya, jurnal, bayar supplier, settlement)',
  'pos.refund': 'Refund POS',
};
