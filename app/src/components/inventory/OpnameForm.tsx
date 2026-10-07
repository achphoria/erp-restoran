import { useCallback, useEffect, useMemo, useState } from 'react';
import { Camera, ClipboardCheck, RefreshCw, Save } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { must, rpc, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatNumber, formatRupiah, todayISO } from '../../lib/format';

interface Warehouse { id: string; name: string }
interface Opname { id: string; warehouse_id: string; item_category_id: string | null; opname_date: string; note: string | null; status: string; snapshot_at: string | null }
interface Row {
  id: string; item_id: string; system_qty: number; counted_qty: number | null; unit_cost: number | null;
  inv_items: { code: string; name: string; inv_units: { code: string }; inv_item_categories: { name: string } | null };
}

// Stock opname bertahap: potret stok -> isi hasil hitung (draft) -> review selisih -> posting
export default function OpnameForm({ opnameId, companyId, warehouses, onClose }: {
  opnameId: string | null; companyId: string; warehouses: Warehouse[]; onClose: () => void;
}) {
  const { toast, confirm } = useFeedback();
  const [doc, setDoc] = useState<Opname | null>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [counts, setCounts] = useState<Record<string, string>>({});   // id baris -> qty fisik (teks)
  const [categories, setCategories] = useState<{ id: string; name: string }[]>([]);
  const [setup, setSetup] = useState({ warehouse_id: warehouses[0]?.id ?? '', item_category_id: '', opname_date: todayISO(), note: '' });
  const [filter, setFilter] = useState<'all' | 'todo' | 'diff'>('all');
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (id: string) => {
    const [d, r] = await Promise.all([
      must(supabase.from('inv_stock_opnames').select('*').eq('id', id).single()),
      must(supabase.from('inv_stock_opname_items')
        .select('id, item_id, system_qty, counted_qty, unit_cost, inv_items(code, name, inv_units(code), inv_item_categories(name))')
        .eq('stock_opname_id', id)),
    ]);
    setDoc(d);
    const sorted = (r as Row[]).sort((a, b) => a.inv_items.code.localeCompare(b.inv_items.code));
    setRows(sorted);
    setCounts(Object.fromEntries(sorted.map((x) => [x.id, x.counted_qty === null ? '' : String(Number(x.counted_qty))])));
  }, []);

  useEffect(() => {
    if (opnameId) load(opnameId).catch((e) => toast(errorMessage(e), 'error'));
    must(supabase.from('inv_item_categories').select('id, name').eq('category_type', 'inventory').eq('is_active', true).order('name'))
      .then(setCategories).catch(() => setCategories([]));
  }, [opnameId, load, toast]);

  const start = async () => {
    setBusy(true);
    try {
      const d = (await must(supabase.from('inv_stock_opnames').insert({
        company_id: companyId, warehouse_id: setup.warehouse_id, item_category_id: setup.item_category_id || null,
        opname_date: setup.opname_date, note: setup.note.trim() || null,
      }).select('id').single())) as { id: string };
      const n = await rpc<number>('inv_generate_opname_items', { p_opname_id: d.id });
      toast(`${n} produk masuk daftar, stok sistem sudah dipotret`);
      await load(d.id);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setBusy(false);
    }
  };

  const diffOf = (r: Row) => (counts[r.id] === '' || counts[r.id] === undefined ? null : Number(counts[r.id]) - Number(r.system_qty));
  const dirty = rows.filter((r) => (counts[r.id] ?? '') !== (r.counted_qty === null ? '' : String(Number(r.counted_qty))));

  const saveCounts = async () => {
    for (const r of dirty) {
      await must(supabase.from('inv_stock_opname_items').update({ counted_qty: counts[r.id] === '' ? null : Number(counts[r.id]) }).eq('id', r.id));
    }
  };

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); } catch (e) { toast(errorMessage(e), 'error'); } finally { setBusy(false); }
  };

  const summary = useMemo(() => {
    let counted = 0; let plus = 0; let minus = 0;
    for (const r of rows) {
      const d = diffOf(r);
      if (d === null) continue;
      counted++;
      const v = d * Number(r.unit_cost ?? 0);
      if (v > 0) plus += v; else minus += v;
    }
    return { counted, plus, minus };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, counts]);

  const q = search.trim().toLowerCase();
  const shown = rows.filter((r) => {
    const d = diffOf(r);
    return (!q || r.inv_items.name.toLowerCase().includes(q) || r.inv_items.code.toLowerCase().includes(q))
      && (filter === 'all' || (filter === 'todo' && d === null) || (filter === 'diff' && d !== null && d !== 0));
  });
  const editable = doc?.status === 'draft';

  // ---------- langkah 1: setup ----------
  if (!doc) {
    return (
      <Modal title="Stock Opname Baru" onClose={onClose}
        footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !setup.warehouse_id} onClick={start}><Camera size={16} /> Buat daftar & potret stok</button></>}>
        <ol className="steps" style={{ marginTop: 0 }}>
          <li><b>Potret</b>: sistem mencatat qty stok saat ini sebagai pembanding.</li>
          <li><b>Hitung fisik</b> & isi qty. Bisa disimpan sebagai draft dan dilanjutkan nanti.</li>
          <li><b>Review selisih</b>, lalu <b>posting</b>. Stok dikoreksi sebesar selisih terhadap potret, jadi penjualan setelah penghitungan tetap aman.</li>
        </ol>
        <div className="form-grid" style={{ marginTop: 12 }}>
          <label className="field"><span>Gudang</span>
            <select value={setup.warehouse_id} onChange={(e) => setSetup({ ...setup, warehouse_id: e.target.value })}>
              {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
            </select></label>
          <label className="field"><span>Kategori (opsional)</span>
            <select value={setup.item_category_id} onChange={(e) => setSetup({ ...setup, item_category_id: e.target.value })}>
              <option value="">Semua produk stok</option>
              {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select></label>
          <label className="field"><span>Tanggal</span><input type="date" value={setup.opname_date} onChange={(e) => setSetup({ ...setup, opname_date: e.target.value })} /></label>
          <label className="field"><span>Catatan</span><input value={setup.note} onChange={(e) => setSetup({ ...setup, note: e.target.value })} placeholder="mis. opname akhir bulan" /></label>
        </div>
      </Modal>
    );
  }

  // ---------- langkah 2-4: hitung, review, posting ----------
  return (
    <Modal title={`Stock Opname · ${warehouses.find((w) => w.id === doc.warehouse_id)?.name ?? ''}`} onClose={onClose} large
      footer={editable ? <>
        <button style={{ marginRight: 'auto' }} disabled={busy} onClick={async () => {
          if (await confirm({ title: 'Potret ulang stok sistem?', message: 'Pakai bila penghitungan dilakukan di waktu lain. Qty fisik yang sudah diisi tetap tersimpan.', confirmLabel: 'Potret ulang' })) {
            run(async () => { await saveCounts(); await rpc('inv_refresh_opname_snapshot', { p_opname_id: doc.id }); await load(doc.id); toast('Stok sistem dipotret ulang', 'info'); });
          }
        }}><RefreshCw size={16} /> Potret ulang</button>
        <button disabled={busy || !dirty.length} onClick={() => run(async () => { await saveCounts(); await load(doc.id); toast('Draft tersimpan'); })}><Save size={16} /> Simpan draft</button>
        <button className="btn-primary" disabled={busy || !summary.counted} onClick={async () => {
          if (!(await confirm({ title: 'Posting opname?', message: <>{summary.counted} produk dihitung. Selisih + {formatRupiah(summary.plus)} / − {formatRupiah(Math.abs(summary.minus))} akan dikoreksi ke stok & jurnal. Produk yang belum dihitung tidak diubah.</>, confirmLabel: 'Posting' }))) return;
          run(async () => {
            await saveCounts();
            await rpc('inv_post_stock_opname', { p_id: doc.id });
            const st = await must(supabase.from('inv_stock_opnames').select('status').eq('id', doc.id).single());
            toast(st.status === 'pending_approval' ? 'Opname dikirim ke atasan untuk disetujui' : 'Opname diposting, stok sudah disesuaikan');
            onClose();
          });
        }}><ClipboardCheck size={16} /> Posting</button>
      </> : <button onClick={onClose}>Tutup</button>}>
      {doc.status === 'pending_approval' && <div className="alert alert-info">Opname ini menunggu persetujuan atasan.</div>}
      <div className="grid grid-3" style={{ marginBottom: 12 }}>
        <div className="card" style={{ boxShadow: 'none' }}><div className="stat-label">Sudah dihitung</div><div className="stat-value" style={{ fontSize: 20 }}>{summary.counted} / {rows.length}</div></div>
        <div className="card" style={{ boxShadow: 'none' }}><div className="stat-label">Selisih lebih</div><div className="stat-value" style={{ fontSize: 20, color: 'var(--success)' }}>{formatRupiah(summary.plus)}</div></div>
        <div className="card" style={{ boxShadow: 'none' }}><div className="stat-label">Selisih kurang</div><div className="stat-value" style={{ fontSize: 20, color: 'var(--danger)' }}>{formatRupiah(Math.abs(summary.minus))}</div></div>
      </div>
      <div className="filter-bar">
        <input type="search" placeholder="Cari produk…" value={search} onChange={(e) => setSearch(e.target.value)} />
        <div className="choice-list">
          {([['all', 'Semua'], ['todo', 'Belum dihitung'], ['diff', 'Ada selisih']] as const).map(([k, v]) => (
            <button key={k} className={filter === k ? 'active' : ''} onClick={() => setFilter(k)}>{v}</button>
          ))}
        </div>
      </div>
      <div className="muted small" style={{ marginBottom: 8 }}>Potret stok: {doc.snapshot_at ? formatDateTime(doc.snapshot_at) : '-'}</div>
      <div className="table-wrap" style={{ maxHeight: '48vh', overflowY: 'auto' }}>
        <table className="table">
          <thead><tr><th>Produk</th><th className="right">Sistem</th><th>Fisik</th><th className="right">Selisih</th><th className="right">Nilai</th></tr></thead>
          <tbody>
            {shown.map((r) => {
              const d = diffOf(r);
              const color = d === null || d === 0 ? undefined : d > 0 ? 'var(--success)' : 'var(--danger)';
              return (
                <tr key={r.id}>
                  <td><b>{r.inv_items.code}</b> · {r.inv_items.name}<div className="muted small">{r.inv_items.inv_item_categories?.name}</div></td>
                  <td className="right">{formatNumber(r.system_qty)} {r.inv_items.inv_units.code}</td>
                  <td><input type="number" step="any" min={0} inputMode="decimal" disabled={!editable} style={{ width: 100 }}
                    value={counts[r.id] ?? ''} placeholder="—" onChange={(e) => setCounts({ ...counts, [r.id]: e.target.value })} /></td>
                  <td className="right bold" style={{ color }}>{d === null ? '' : `${d > 0 ? '+' : ''}${formatNumber(d)}`}</td>
                  <td className="right" style={{ color }}>{d === null ? '' : formatRupiah(d * Number(r.unit_cost ?? 0))}</td>
                </tr>
              );
            })}
            {!shown.length && <tr><td colSpan={5} className="empty">Tidak ada produk.</td></tr>}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}
