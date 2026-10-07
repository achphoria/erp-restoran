import { useCallback, useEffect, useMemo, useState } from 'react';
import { Download, Plus, Trash2, Upload } from 'lucide-react';
import Modal from '../Modal';
import ImportDialog, { type ImportColumn } from '../ImportDialog';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatRupiah } from '../../lib/format';
import { downloadXlsx } from '../../lib/excel';
import { ITEM_TYPES, type ItemUnit, type MasterData, type Product } from './types';

const yesNo = (b: boolean) => (b ? 'YA' : 'TIDAK');

export const PRODUCT_IMPORT_COLUMNS: ImportColumn[] = [
  { key: 'kode', label: 'Kode', required: true, example: 'BB-001', hint: 'Unik per perusahaan' },
  { key: 'nama', label: 'Nama', required: true, example: 'Beras Premium' },
  { key: 'tipe', label: 'Tipe', example: 'bahan baku', hint: 'bahan baku / setengah jadi / barang jadi / kemasan / habis pakai' },
  { key: 'kategori', label: 'Kategori', required: true, example: 'Bahan Pokok' },
  { key: 'sub_kategori', label: 'Sub Kategori', example: 'Beras' },
  { key: 'satuan', label: 'Satuan', required: true, example: 'g', hint: 'Satuan stok terkecil (kode atau nama satuan)' },
  { key: 'satuan_beli', label: 'Satuan Beli', example: 'kg', hint: 'Opsional, satuan saat membeli' },
  { key: 'konversi_beli', label: 'Konversi Beli', example: '1000', hint: '1 satuan beli = berapa satuan stok' },
  { key: 'harga_beli', label: 'Harga Beli', example: '14', hint: 'Per satuan stok' },
  { key: 'stok_minimum', label: 'Stok Minimum', example: '5000', hint: 'Default; bisa diatur per gudang' },
  { key: 'dapat_dibeli', label: 'Dapat Dibeli', example: 'YA', hint: 'YA / TIDAK (default YA)' },
  { key: 'dapat_dijual', label: 'Dapat Dijual', example: 'TIDAK', hint: 'YA / TIDAK (default TIDAK)' },
  { key: 'dapat_direquest', label: 'Dapat Direquest', example: 'YA', hint: 'Bisa diminta outlet ke gudang pusat' },
  { key: 'kena_pajak', label: 'Kena Pajak', example: 'TIDAK', hint: 'Barang kena PPN' },
  { key: 'toleransi_terima', label: 'Toleransi Terima', example: '5', hint: '% kelebihan qty yang boleh diterima dari PO' },
  { key: 'barcode', label: 'Barcode', example: '' },
  { key: 'catatan', label: 'Catatan', example: '' },
  ...[1, 2, 3, 4, 5].map((n) => ({ key: `info_${n}`, label: `Info ${n}`, example: '', hint: `Nilai custom field slot ${n}` })),
];

export default function ProductsTab(md: MasterData) {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('');
  const [type, setType] = useState('');
  const [status, setStatus] = useState('active');
  const [editing, setEditing] = useState<Partial<Product> | null>(null);
  const [importing, setImporting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setRows((await must(supabase.from('inv_items').select('*, inv_item_units(*)').order('code'))) as Product[]);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setLoading(false);
    }
  }, [toast]);
  useEffect(() => { load(); }, [load]);

  const unitCode = (id: string) => md.units.find((u) => u.id === id)?.code ?? '?';
  const catName = (id: string | null) => md.categories.find((c) => c.id === id)?.name ?? '-';
  const subName = (id: string | null) => md.subCategories.find((c) => c.id === id)?.name;

  const s = search.trim().toLowerCase();
  const shown = useMemo(() => rows.filter((p) =>
    (!s || p.code.toLowerCase().includes(s) || p.name.toLowerCase().includes(s)
      || p.inv_item_units?.some((u) => u.barcode?.includes(s) || u.sku?.toLowerCase().includes(s)))
    && (!category || p.item_category_id === category)
    && (!type || p.item_type === type)
    && (status === 'all' || (status === 'active' && p.is_active && p.approval_status === 'approved')
        || (status === 'inactive' && !p.is_active) || (status === 'pending' && p.approval_status !== 'approved'))), [rows, s, category, type, status]);

  const exportXlsx = () => downloadXlsx('produk', [{
    name: 'Produk',
    rows: shown.map((p) => {
      const purchase = p.inv_item_units?.find((u) => u.is_purchase_unit && u.unit_id !== p.base_unit_id);
      const base = p.inv_item_units?.find((u) => u.unit_id === p.base_unit_id);
      return {
        Kode: p.code, Nama: p.name, Tipe: ITEM_TYPES[p.item_type]?.toLowerCase() ?? p.item_type, Kategori: catName(p.item_category_id),
        'Sub Kategori': subName(p.sub_category_id) ?? '', Satuan: unitCode(p.base_unit_id),
        'Satuan Beli': purchase ? unitCode(purchase.unit_id) : '', 'Konversi Beli': purchase ? Number(purchase.conversion_qty) : '',
        'Harga Beli': Number(p.last_purchase_cost), 'Stok Minimum': Number(p.min_stock),
        'Dapat Dibeli': yesNo(p.is_purchasable), 'Dapat Dijual': yesNo(p.is_saleable), 'Dapat Direquest': yesNo(p.is_requestable),
        'Kena Pajak': yesNo(p.is_taxable), 'Toleransi Terima': Number(p.receipt_tolerance_pct), Barcode: base?.barcode ?? '',
        Catatan: p.notes ?? '', ...Object.fromEntries([1, 2, 3, 4, 5].map((n) => [`Info ${n}`, p.custom_fields?.[n] ?? ''])),
        Status: p.is_active ? 'Aktif' : 'Nonaktif',
      };
    }),
  }]);

  return (
    <>
      <div className="card">
        <div className="filter-bar">
          <input type="search" placeholder="Cari kode, nama, barcode, SKU…" value={search} onChange={(e) => setSearch(e.target.value)} />
          <select value={category} onChange={(e) => setCategory(e.target.value)}>
            <option value="">Semua kategori</option>
            {md.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <select value={type} onChange={(e) => setType(e.target.value)}>
            <option value="">Semua tipe</option>
            {Object.entries(ITEM_TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="active">Aktif</option><option value="inactive">Nonaktif</option>
            <option value="pending">Menunggu / ditolak</option><option value="all">Semua</option>
          </select>
        </div>
        <div className="row">
          <button className="btn-primary" onClick={() => setEditing({ item_type: 'raw', is_active: true, is_purchasable: true, is_requestable: true, receipt_tolerance_pct: 0, min_stock: 0, last_purchase_cost: 0, custom_fields: {} })}>
            <Plus size={16} /> Produk Baru
          </button>
          <button onClick={() => setImporting(true)}><Upload size={16} /> Import Excel</button>
          <button onClick={exportXlsx} disabled={!shown.length}><Download size={16} /> Export Excel</button>
          <span className="spacer" />
          <span className="muted small">{shown.length} dari {rows.length} produk</span>
        </div>
      </div>

      <div className="card table-wrap">
        {loading ? <div className="skeleton" style={{ height: 160 }} /> : (
          <table className="table">
            <thead><tr><th>Kode</th><th>Nama</th><th>Kategori</th><th>Tipe</th><th>Satuan</th><th>Flag</th><th className="right">Harga beli</th><th>Status</th></tr></thead>
            <tbody>
              {shown.map((p) => (
                <tr key={p.id} onClick={() => setEditing(p)} style={{ cursor: 'pointer' }}>
                  <td className="bold">{p.code}</td>
                  <td>{p.name}</td>
                  <td className="small">{catName(p.item_category_id)}{subName(p.sub_category_id) && <div className="muted">{subName(p.sub_category_id)}</div>}</td>
                  <td className="small">{ITEM_TYPES[p.item_type] ?? p.item_type}</td>
                  <td className="small">{p.inv_item_units?.map((u) => unitCode(u.unit_id)).join(' · ')}</td>
                  <td>
                    <span className="flag-dots">
                      <span className={`flag-dot ${p.is_purchasable ? 'on' : ''}`} title="Dapat dibeli">B</span>
                      <span className={`flag-dot ${p.is_saleable ? 'on' : ''}`} title="Dapat dijual">J</span>
                      <span className={`flag-dot ${p.is_requestable ? 'on' : ''}`} title="Dapat direquest outlet">R</span>
                      <span className={`flag-dot ${p.is_taxable ? 'on' : ''}`} title="Kena PPN">P</span>
                    </span>
                  </td>
                  <td className="right">{formatRupiah(p.last_purchase_cost)}<span className="muted small">/{unitCode(p.base_unit_id)}</span></td>
                  <td>
                    {p.approval_status === 'pending' ? <span className="badge badge-warning">Menunggu persetujuan</span>
                      : p.approval_status === 'rejected' ? <span className="badge badge-danger">Ditolak</span>
                      : p.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}
                  </td>
                </tr>
              ))}
              {!shown.length && <tr><td colSpan={8} className="empty">Belum ada produk. Tambah satu per satu atau import dari Excel.</td></tr>}
            </tbody>
          </table>
        )}
      </div>

      {editing && <ProductForm md={md} product={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load(); md.reload(); }} />}
      {importing && (
        <ImportDialog title="Import Produk dari Excel" columns={PRODUCT_IMPORT_COLUMNS} templateName="template-produk"
          onImport={(r, create) => rpc('inv_import_items', { p_rows: r, p_create_missing: create })}
          onClose={() => setImporting(false)}
          onDone={(n) => { toast(`${n} produk berhasil diimport`); setImporting(false); load(); md.reload(); }} />
      )}
    </>
  );
}

// ---------------------------------------------------------------- Form produk
function ProductForm({ md, product, onClose, onSaved }: { md: MasterData; product: Partial<Product>; onClose: () => void; onSaved: () => void }) {
  const { toast, confirm } = useFeedback();
  const isNew = !product.id;
  const [p, setP] = useState<Partial<Product>>({ ...product, custom_fields: { ...(product.custom_fields ?? {}) } });
  const [units, setUnits] = useState<ItemUnit[]>(() => {
    const existing = [...(product.inv_item_units ?? [])].sort((a, b) => Number(a.conversion_qty) - Number(b.conversion_qty));
    return existing.length ? existing : [];
  });
  const [busy, setBusy] = useState(false);
  const set = (patch: Partial<Product>) => setP((x) => ({ ...x, ...patch }));

  // baris satuan dasar selalu ada & di atas
  const baseUnitId = p.base_unit_id ?? '';
  const allUnits: ItemUnit[] = useMemo(() => {
    const base = units.find((u) => u.unit_id === baseUnitId);
    const others = units.filter((u) => u.unit_id !== baseUnitId);
    const baseRow: ItemUnit = base ?? { unit_id: baseUnitId, conversion_qty: 1, sku: null, barcode: null, weight_kg: null, volume_cm3: null,
      is_purchase_unit: !others.some((u) => u.is_purchase_unit), is_transfer_unit: !others.some((u) => u.is_transfer_unit), is_sales_unit: !others.some((u) => u.is_sales_unit) };
    return baseUnitId ? [{ ...baseRow, conversion_qty: 1 }, ...others] : others;
  }, [units, baseUnitId]);

  const updateUnit = (unitId: string, patch: Partial<ItemUnit>) =>
    setUnits(() => {
      const list = allUnits.map((u) => (u.unit_id === unitId ? { ...u, ...patch } : u));
      // peran unit hanya boleh satu per produk
      for (const flag of ['is_purchase_unit', 'is_transfer_unit', 'is_sales_unit'] as const) {
        if (patch[flag]) list.forEach((u) => { if (u.unit_id !== unitId) u[flag] = false; });
      }
      return list;
    });

  const addUnit = () => {
    const free = md.units.find((u) => !allUnits.some((x) => x.unit_id === u.id));
    if (!free) return toast('Semua satuan sudah dipakai. Tambah satuan baru di tab Satuan.', 'info');
    setUnits([...allUnits, { unit_id: free.id, conversion_qty: 1, sku: null, barcode: null, weight_kg: null, volume_cm3: null, is_purchase_unit: false, is_transfer_unit: false, is_sales_unit: false }]);
  };

  const save = async () => {
    setBusy(true);
    try {
      const row = {
        company_id: md.companyId, code: p.code?.trim().toUpperCase(), name: p.name?.trim(), item_type: p.item_type,
        item_category_id: p.item_category_id || null, sub_category_id: p.sub_category_id || null, base_unit_id: p.base_unit_id,
        min_stock: Number(p.min_stock || 0), last_purchase_cost: Number(p.last_purchase_cost || 0), is_active: !!p.is_active,
        is_purchasable: !!p.is_purchasable, is_saleable: !!p.is_saleable, is_requestable: !!p.is_requestable, is_taxable: !!p.is_taxable,
        receipt_tolerance_pct: Number(p.receipt_tolerance_pct || 0), notes: p.notes?.trim() || null,
        custom_fields: Object.fromEntries(Object.entries(p.custom_fields ?? {}).filter(([, v]) => v)),
      };
      const saved = (await must(isNew
        ? supabase.from('inv_items').insert(row).select('id, approval_status').single()
        : supabase.from('inv_items').update(row).eq('id', p.id!).select('id, approval_status').single())) as { id: string; approval_status: string };

      // sinkron satuan: hapus yang dibuang, reset peran, lalu upsert
      const keep = allUnits.map((u) => u.unit_id);
      const existing = (await must(supabase.from('inv_item_units').select('unit_id').eq('item_id', saved.id))) as { unit_id: string }[];
      const removed = existing.map((e) => e.unit_id).filter((id) => !keep.includes(id) && id !== row.base_unit_id);
      if (removed.length) await must(supabase.from('inv_item_units').delete().eq('item_id', saved.id).in('unit_id', removed));
      await must(supabase.from('inv_item_units').update({ is_purchase_unit: false, is_transfer_unit: false, is_sales_unit: false }).eq('item_id', saved.id));
      await must(supabase.from('inv_item_units').upsert(allUnits.map((u) => ({
        company_id: md.companyId, item_id: saved.id, unit_id: u.unit_id, conversion_qty: u.unit_id === row.base_unit_id ? 1 : Number(u.conversion_qty),
        sku: u.sku?.trim() || null, barcode: u.barcode?.trim() || null,
        weight_kg: u.weight_kg === null || u.weight_kg === undefined || String(u.weight_kg) === '' ? null : Number(u.weight_kg),
        volume_cm3: u.volume_cm3 === null || u.volume_cm3 === undefined || String(u.volume_cm3) === '' ? null : Number(u.volume_cm3),
        is_purchase_unit: u.is_purchase_unit, is_transfer_unit: u.is_transfer_unit, is_sales_unit: u.is_sales_unit,
      })), { onConflict: 'item_id,unit_id' }));

      toast(saved.approval_status === 'pending' ? 'Produk disimpan & menunggu persetujuan atasan' : 'Produk disimpan');
      onSaved();
    } catch (e) {
      const msg = errorMessage(e);
      toast(/duplicate key.*barcode/i.test(msg) ? 'Barcode sudah dipakai produk lain' : /duplicate key.*sku/i.test(msg) ? 'SKU sudah dipakai produk lain'
        : /duplicate key.*code/i.test(msg) ? 'Kode produk sudah dipakai' : msg, 'error');
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!(await confirm({ title: `Hapus ${p.name}?`, message: 'Produk yang sudah punya transaksi tidak bisa dihapus; nonaktifkan saja.', danger: true, confirmLabel: 'Hapus' }))) return;
    try {
      await must(supabase.from('inv_items').delete().eq('id', p.id!));
      toast('Produk dihapus', 'info');
      onSaved();
    } catch {
      toast('Produk sudah dipakai di transaksi/resep. Nonaktifkan saja.', 'error');
    }
  };

  const activeFields = md.customFields.filter((f) => f.is_active);
  const valid = p.code?.trim() && p.name?.trim() && p.item_category_id && p.base_unit_id && allUnits.every((u) => Number(u.conversion_qty) > 0);

  return (
    <Modal title={isNew ? 'Produk Baru' : `${p.code} · ${p.name}`} onClose={onClose} large
      footer={<>
        {!isNew && <button className="btn-danger" onClick={remove} style={{ marginRight: 'auto' }}><Trash2 size={16} /> Hapus</button>}
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || !valid} onClick={save}>{busy ? 'Menyimpan…' : 'Simpan'}</button>
      </>}>
      {p.approval_status === 'pending' && <div className="alert alert-info">Produk ini menunggu persetujuan atasan dan belum bisa dipakai di PO / resep.</div>}
      {p.approval_status === 'rejected' && <div className="alert alert-error">Produk ini ditolak atasan.</div>}

      <div className="section-title" style={{ marginTop: 0 }}>Informasi</div>
      <div className="form-grid">
        <label className="field"><span>Kode *</span><input value={p.code ?? ''} onChange={(e) => set({ code: e.target.value.toUpperCase() })} /></label>
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Nama *</span><input value={p.name ?? ''} onChange={(e) => set({ name: e.target.value })} /></label>
        <label className="field"><span>Tipe</span>
          <select value={p.item_type} onChange={(e) => set({ item_type: e.target.value, ...(e.target.value === 'finished' ? { is_saleable: true } : {}) })}>
            {Object.entries(ITEM_TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select></label>
        <label className="field"><span>Kategori *</span>
          <select value={p.item_category_id ?? ''} onChange={(e) => set({ item_category_id: e.target.value })}>
            <option value="">— pilih —</option>
            {md.categories.filter((c) => c.is_active || c.id === p.item_category_id).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></label>
        <label className="field"><span>Sub kategori</span>
          <select value={p.sub_category_id ?? ''} onChange={(e) => set({ sub_category_id: e.target.value || null })}>
            <option value="">—</option>
            {md.subCategories.filter((c) => c.is_active || c.id === p.sub_category_id).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select></label>
      </div>

      <div className="section-title">Pengaturan</div>
      <div className="row" style={{ gap: 18 }}>
        {([['is_purchasable', 'Dapat dibeli'], ['is_saleable', 'Dapat dijual'], ['is_requestable', 'Dapat direquest outlet'], ['is_taxable', 'Kena PPN'], ['is_active', 'Aktif']] as const).map(([k, label]) => (
          <label key={k} className="switch"><input type="checkbox" checked={!!p[k]} onChange={(e) => set({ [k]: e.target.checked } as Partial<Product>)} /><span>{label}</span></label>
        ))}
      </div>
      <div className="form-grid" style={{ marginTop: 12 }}>
        <label className="field"><span>Harga beli terakhir (per satuan stok)</span>
          <input type="number" step="any" min={0} value={p.last_purchase_cost ?? 0} onChange={(e) => set({ last_purchase_cost: Number(e.target.value) })} /></label>
        <label className="field"><span>Stok minimum default</span>
          <input type="number" step="any" min={0} value={p.min_stock ?? 0} onChange={(e) => set({ min_stock: Number(e.target.value) })} /></label>
        <label className="field"><span>Toleransi terima (%)</span>
          <input type="number" min={0} max={100} value={p.receipt_tolerance_pct ?? 0} onChange={(e) => set({ receipt_tolerance_pct: Number(e.target.value) })} /></label>
      </div>

      <div className="section-title">Satuan, SKU & Barcode</div>
      <label className="field" style={{ maxWidth: 280, marginBottom: 10 }}><span>Satuan stok (terkecil) *</span>
        <select value={p.base_unit_id ?? ''} disabled={!isNew} onChange={(e) => { set({ base_unit_id: e.target.value }); setUnits(units.filter((u) => u.unit_id !== e.target.value)); }}>
          <option value="">— pilih —</option>
          {md.units.map((u) => <option key={u.id} value={u.id}>{u.name} ({u.code})</option>)}
        </select>
      </label>
      {!isNew && <div className="muted small" style={{ marginTop: -6, marginBottom: 10 }}>Satuan stok tidak bisa diganti setelah produk dibuat.</div>}
      {baseUnitId && (
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>Satuan</th><th>Konversi</th><th>SKU</th><th>Barcode</th><th>Berat (kg)</th><th>Vol (cm³)</th><th>Beli</th><th>Transfer</th><th>Jual</th><th></th></tr></thead>
            <tbody>
              {allUnits.map((u) => {
                const isBase = u.unit_id === baseUnitId;
                return (
                  <tr key={u.unit_id}>
                    <td>
                      {isBase ? <b>{md.units.find((x) => x.id === u.unit_id)?.code}</b> : (
                        <select value={u.unit_id} onChange={(e) => setUnits(allUnits.map((x) => (x.unit_id === u.unit_id ? { ...x, unit_id: e.target.value } : x)))}>
                          {md.units.filter((x) => x.id === u.unit_id || !allUnits.some((a) => a.unit_id === x.id)).map((x) => <option key={x.id} value={x.id}>{x.code}</option>)}
                        </select>
                      )}
                    </td>
                    <td>{isBase ? <span className="muted">1 (dasar)</span> : (
                      <input type="number" step="any" min={0} value={u.conversion_qty} style={{ width: 90 }} onChange={(e) => updateUnit(u.unit_id, { conversion_qty: Number(e.target.value) })} />
                    )}</td>
                    <td><input value={u.sku ?? ''} style={{ width: 110 }} onChange={(e) => updateUnit(u.unit_id, { sku: e.target.value })} /></td>
                    <td><input value={u.barcode ?? ''} inputMode="numeric" style={{ width: 140 }} onChange={(e) => updateUnit(u.unit_id, { barcode: e.target.value })} /></td>
                    <td><input type="number" step="any" min={0} value={u.weight_kg ?? ''} style={{ width: 80 }} onChange={(e) => updateUnit(u.unit_id, { weight_kg: e.target.value === '' ? null : Number(e.target.value) })} /></td>
                    <td><input type="number" step="any" min={0} value={u.volume_cm3 ?? ''} style={{ width: 80 }} onChange={(e) => updateUnit(u.unit_id, { volume_cm3: e.target.value === '' ? null : Number(e.target.value) })} /></td>
                    {(['is_purchase_unit', 'is_transfer_unit', 'is_sales_unit'] as const).map((f) => (
                      <td key={f}><input type="radio" name={f} checked={u[f]} onChange={() => updateUnit(u.unit_id, { [f]: true })} /></td>
                    ))}
                    <td>{!isBase && <button className="icon-btn" onClick={() => setUnits(allUnits.filter((x) => x.unit_id !== u.unit_id))} aria-label="Hapus satuan"><Trash2 size={16} /></button>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <button className="btn-sm" onClick={addUnit}><Plus size={14} /> Satuan lain</button>
          <div className="muted small" style={{ marginTop: 6 }}>
            Konversi = isi 1 satuan dalam satuan stok (mis. 1 kg = 1000 g). Kolom Beli/Transfer/Jual menentukan satuan default di PO, transfer, dan penjualan.
          </div>
        </div>
      )}

      {activeFields.length > 0 && (
        <>
          <div className="section-title">Field tambahan</div>
          <div className="form-grid">
            {activeFields.map((f) => (
              <label key={f.slot} className="field"><span>{f.label}</span>
                <input value={p.custom_fields?.[f.slot] ?? ''} onChange={(e) => set({ custom_fields: { ...(p.custom_fields ?? {}), [f.slot]: e.target.value } })} /></label>
            ))}
          </div>
        </>
      )}

      <div className="section-title">Catatan</div>
      <textarea rows={2} style={{ width: '100%' }} value={p.notes ?? ''} onChange={(e) => set({ notes: e.target.value })} />
      {!isNew && <div className="muted small" style={{ marginTop: 8 }}>Stok saat ini dilihat di Inventory → Stok. Nilai stok dihitung dari HPP rata-rata, bukan dari harga beli terakhir.</div>}
    </Modal>
  );
}
