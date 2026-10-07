import { useCallback, useEffect, useState } from 'react';
import { useFeedback } from '../Feedback';
import Avatar from '../Avatar';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, todayISO } from '../../lib/format';

interface LogRow {
  id: number; user_id: string | null; user_name: string | null; action: string; entity_type: string;
  entity_id: string | null; entity_label: string | null; changes: Record<string, [unknown, unknown]> | null; created_at: string;
}

const ENTITY: Record<string, string> = {
  sys_users: 'User', sys_roles: 'Role', sys_outlets: 'Outlet', sys_companies: 'Perusahaan', sys_user_invitations: 'Undangan',
  mst_menu_items: 'Menu', mst_menu_prices: 'Harga ojol', mst_menu_categories: 'Kategori', mst_modifiers: 'Modifier',
  mst_payment_methods: 'Metode bayar', mst_tables: 'Meja', inv_items: 'Bahan baku', inv_recipe_items: 'Resep',
  inv_warehouses: 'Gudang', inv_stock_adjustments: 'Penyesuaian stok', inv_stock_opnames: 'Stock opname',
  inv_stock_transfers: 'Transfer stok', pur_suppliers: 'Supplier', pur_purchase_orders: 'Purchase order',
  pur_goods_receipts: 'Penerimaan barang', crm_promotions: 'Promo', crm_settings: 'Aturan poin',
  crm_membership_tiers: 'Level member', fin_accounts: 'Akun', pos_shifts: 'Shift', pos_orders: 'Order',
  pos_order_items: 'Item order', inv_item_sub_categories: 'Sub kategori', inv_item_categories: 'Kategori produk',
  inv_units: 'Satuan', inv_item_units: 'Satuan produk', inv_item_stock_levels: 'Min/max stok', inv_recipes: 'Resep (BOM)',
  inv_recipe_costs: 'Biaya resep', inv_productions: 'Produksi', pur_pricelists: 'Pricelist', pur_pricelist_items: 'Item pricelist',
  mst_price_schedules: 'Jadwal harga', mst_price_schedule_items: 'Harga jadwal', mst_modifier_groups: 'Grup modifier', sys_approval_requests: 'Persetujuan', sys_payment_gateways: 'Payment gateway',
};
const ACTION: Record<string, [string, string]> = {
  login: ['Login', 'badge-info'], insert: ['Tambah', 'badge-success'], update: ['Ubah', 'badge'], delete: ['Hapus', 'badge-danger'],
  paid: ['Lunas', 'badge-success'], void: ['Void', 'badge-danger'], refunded: ['Refund', 'badge-danger'], merged: ['Gabung', 'badge'],
  posted: ['Posting', 'badge-success'], approved: ['Disetujui', 'badge-success'], rejected: ['Ditolak', 'badge-danger'],
  pending_approval: ['Minta persetujuan', 'badge-warning'], request_approval: ['Minta persetujuan', 'badge-warning'],
  cancelled: ['Batal', 'badge'], import: ['Import Excel', 'badge-info'], open: ['Buka', 'badge-info'], closed: ['Tutup', 'badge'], update_secret: ['Ganti kunci', 'badge-warning'],
};

const fmt = (v: unknown) => (v === null || v === undefined ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v));

export default function ActivityLogTab() {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<LogRow[]>([]);
  const [date, setDate] = useState(todayISO());
  const [entity, setEntity] = useState('');
  const [search, setSearch] = useState('');
  const [expanded, setExpanded] = useState<number | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('sys_activity_logs').select('*')
      .gte('created_at', new Date(`${date}T00:00:00`).toISOString()).lte('created_at', new Date(`${date}T23:59:59.999`).toISOString())
      .order('id', { ascending: false }).limit(300);
    if (entity) q = q.eq('entity_type', entity);
    setRows((await must(q)) as LogRow[]);
  }, [date, entity]);

  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const s = search.trim().toLowerCase();
  const shown = rows.filter((r) => !s || `${r.user_name} ${r.entity_label} ${r.action}`.toLowerCase().includes(s));

  return (
    <div className="card">
      <div className="row" style={{ marginBottom: 12 }}>
        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        <select value={entity} onChange={(e) => setEntity(e.target.value)}>
          <option value="">Semua data</option>
          {Object.entries(ENTITY).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <input placeholder="Cari user / data…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ flex: 1, minWidth: 160 }} />
      </div>
      <div className="log-list">
        {shown.map((r) => {
          const [label, badge] = ACTION[r.action] ?? [r.action, 'badge'];
          const changes = r.changes ? Object.entries(r.changes) : [];
          return (
            <div key={r.id} className="log-item" onClick={() => changes.length && setExpanded(expanded === r.id ? null : r.id)}>
              <Avatar name={r.user_name ?? 'Sistem'} size={34} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div className="row" style={{ gap: 6 }}>
                  <b>{r.user_name ?? 'Sistem'}</b>
                  <span className={`badge ${badge}`}>{label}</span>
                  <span className="muted">{ENTITY[r.entity_type] ?? r.entity_type}</span>
                  {r.entity_label && <span className="bold" style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.entity_label}</span>}
                </div>
                <div className="muted small">{formatDateTime(r.created_at)}{changes.length > 0 && ` · ${changes.length} perubahan ${expanded === r.id ? '▾' : '▸'}`}</div>
                {expanded === r.id && (
                  <table className="table" style={{ marginTop: 6 }}>
                    <tbody>
                      {changes.map(([k, [a, b]]) => (
                        <tr key={k}>
                          <td className="muted small">{k}</td>
                          <td className="small" style={{ textDecoration: 'line-through', color: 'var(--danger)' }}>{fmt(a)}</td>
                          <td className="small" style={{ color: 'var(--success)' }}>{fmt(b)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
            </div>
          );
        })}
        {!shown.length && <div className="empty">Tidak ada aktivitas pada tanggal ini.</div>}
      </div>
    </div>
  );
}
