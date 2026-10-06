import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { useFeedback, useNotice } from '../components/Feedback';
import { errorMessage, formatDateTime, formatNumber, formatRupiah, SALES_CHANNELS } from '../lib/format';
import Modal from '../components/Modal';
import MoneyInput from '../components/MoneyInput';

type Tab = 'customers' | 'promotions' | 'loyalty';

interface Tier { id: string; name: string; min_total_spent: number; point_multiplier: number }
interface Customer {
  id: string; code: string; name: string; phone: string; email: string | null; birth_date: string | null; note: string | null;
  tier_id: string | null; points_balance: number; total_spent: number; visit_count: number; last_visit_at: string | null; is_active: boolean;
}
interface Promotion {
  id: string; name: string; voucher_code: string | null; discount_type: 'percent' | 'amount'; discount_value: number;
  max_discount: number | null; min_subtotal: number; start_date: string | null; end_date: string | null;
  days_of_week: number[] | null; start_time: string | null; end_time: string | null;
  outlet_ids: string[] | null; sales_channels: string[] | null; menu_item_ids: string[] | null; menu_category_ids: string[] | null;
  requires_member: boolean; usage_limit: number | null; usage_count: number; per_customer_limit: number | null; is_active: boolean;
}

const DAYS = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];

export default function CustomersPage() {
  const [tab, setTab] = useState<Tab>('customers');
  const [tiers, setTiers] = useState<Tier[]>([]);
  const [error, setError] = useState('');
  const setNotice = useNotice();

  const loadTiers = useCallback(async () => {
    setTiers((await must(supabase.from('crm_membership_tiers').select('*').order('min_total_spent'))) as Tier[]);
  }, []);

  useEffect(() => {
    loadTiers().catch((e) => setError(errorMessage(e)));
  }, [loadTiers]);

  const ctx = { tiers, reloadTiers: loadTiers, setError, setNotice };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Pelanggan & Promo</h1>
          <p>Member, poin loyalitas, voucher, dan promo otomatis.</p>
        </div>
      </div>
      <div className="tabs">
        {([['customers', 'Member'], ['promotions', 'Promo & Voucher'], ['loyalty', 'Program Poin & Level']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => { setTab(k); setError(''); setNotice(''); }}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      {tab === 'customers' && <CustomersTab {...ctx} />}
      {tab === 'promotions' && <PromotionsTab {...ctx} />}
      {tab === 'loyalty' && <LoyaltyTab {...ctx} />}
    </>
  );
}

interface Ctx {
  tiers: Tier[];
  reloadTiers: () => Promise<void>;
  setError: (m: string) => void;
  setNotice: (m: string) => void;
}

// ---------------------------------------------------------------- Member
function CustomersTab({ tiers, setError, setNotice }: Ctx) {
  const [rows, setRows] = useState<Customer[]>([]);
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<'total_spent' | 'last_visit_at' | 'created_at'>('total_spent');
  const [adding, setAdding] = useState(false);
  const [detail, setDetail] = useState<Customer | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('crm_customers').select('*').order(sort, { ascending: false, nullsFirst: false }).limit(200);
    const s = search.trim();
    if (s) q = q.or(`name.ilike.%${s.replace(/[,()]/g, '')}%,phone.ilike.%${s.replace(/\D/g, '') || '~'}%,code.ilike.%${s.replace(/[,()]/g, '')}%`);
    setRows((await must(q)) as Customer[]);
  }, [search, sort]);

  useEffect(() => {
    const t = setTimeout(() => load().catch((e) => setError(errorMessage(e))), 250);
    return () => clearTimeout(t);
  }, [load, setError]);

  const tierName = (id: string | null) => tiers.find((t) => t.id === id)?.name ?? '-';

  return (
    <>
      <div className="card">
        <div className="row">
          <input placeholder="🔍 Cari nama / HP / kode" value={search} onChange={(e) => setSearch(e.target.value)} style={{ flex: 1, minWidth: 200 }} />
          <select value={sort} onChange={(e) => setSort(e.target.value as typeof sort)}>
            <option value="total_spent">Belanja terbanyak</option>
            <option value="last_visit_at">Kunjungan terakhir</option>
            <option value="created_at">Terbaru daftar</option>
          </select>
          <button className="btn-primary" onClick={() => setAdding(true)}>+ Member Baru</button>
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Kode</th><th>Nama</th><th>HP</th><th>Level</th><th className="right">Poin</th><th className="right">Total Belanja</th><th className="right">Kunjungan</th><th>Terakhir</th></tr></thead>
          <tbody>
            {rows.map((c) => (
              <tr key={c.id} onClick={() => setDetail(c)} style={{ cursor: 'pointer', opacity: c.is_active ? 1 : 0.5 }}>
                <td>{c.code}</td>
                <td className="bold">{c.name}</td>
                <td>{c.phone}</td>
                <td><span className="badge badge-primary">{tierName(c.tier_id)}</span></td>
                <td className="right">⭐ {formatNumber(c.points_balance)}</td>
                <td className="right">{formatRupiah(c.total_spent)}</td>
                <td className="right">{c.visit_count}×</td>
                <td className="small">{c.last_visit_at ? formatDateTime(c.last_visit_at) : '-'}</td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={8} className="empty">Belum ada member. Daftarkan dari POS atau tombol di atas.</td></tr>}
          </tbody>
        </table>
      </div>

      {adding && <CustomerForm onClose={() => setAdding(false)} onSaved={() => { setAdding(false); setNotice('Member terdaftar.'); load(); }} />}
      {detail && (
        <CustomerDetail customer={detail} tierName={tierName(detail.tier_id)} onClose={() => setDetail(null)}
          onChanged={(msg) => { setNotice(msg); setDetail(null); load(); }} />
      )}
    </>
  );
}

function CustomerForm({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [form, setForm] = useState({ name: '', phone: '', email: '', birth_date: '' });
  const [error, setError] = useState('');
  const save = async () => {
    try {
      await rpc('crm_register_customer', { p_name: form.name, p_phone: form.phone, p_email: form.email || null, p_birth_date: form.birth_date || null });
      onSaved();
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return (
    <Modal title="Member Baru" onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={!form.name || !form.phone} onClick={save}>Daftar</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field"><span>Nama</span><input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></label>
        <label className="field"><span>Nomor HP</span><input value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} placeholder="0812…" /></label>
        <label className="field"><span>Email</span><input type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} /></label>
        <label className="field"><span>Tanggal lahir</span><input type="date" value={form.birth_date} onChange={(e) => setForm({ ...form, birth_date: e.target.value })} /></label>
      </div>
    </Modal>
  );
}

function CustomerDetail({ customer: c, tierName, onClose, onChanged }: {
  customer: Customer; tierName: string; onClose: () => void; onChanged: (msg: string) => void;
}) {
  const [history, setHistory] = useState<{ id: string; transaction_type: string; points: number; balance_after: number; note: string | null; created_at: string }[]>([]);
  const [form, setForm] = useState({ name: c.name, email: c.email ?? '', birth_date: c.birth_date ?? '', note: c.note ?? '', is_active: c.is_active });
  const [adjust, setAdjust] = useState('');
  const [adjustNote, setAdjustNote] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    must(supabase.from('crm_point_transactions').select('*').eq('customer_id', c.id).order('created_at', { ascending: false }).limit(50))
      .then((r) => setHistory(r as typeof history))
      .catch((e) => setError(errorMessage(e)));
  }, [c.id]);

  const run = async (fn: () => Promise<unknown>, msg: string) => {
    try {
      await fn();
      onChanged(msg);
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <Modal title={`${c.name} · ${c.code}`} onClose={onClose} large
      footer={<>
        <button onClick={onClose}>Tutup</button>
        <button className="btn-primary" onClick={() => run(() => must(supabase.from('crm_customers').update({
          name: form.name, email: form.email || null, birth_date: form.birth_date || null, note: form.note || null, is_active: form.is_active,
        }).eq('id', c.id)), 'Data member disimpan.')}>Simpan</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="grid grid-3" style={{ marginBottom: 16 }}>
        <div className="card"><div className="stat-label">Poin</div><div className="stat-value">⭐ {formatNumber(c.points_balance)}</div></div>
        <div className="card"><div className="stat-label">Level</div><div className="stat-value">{tierName}</div></div>
        <div className="card"><div className="stat-label">Total belanja</div><div className="stat-value">{formatRupiah(c.total_spent)}</div></div>
      </div>
      <div className="form-grid">
        <label className="field"><span>Nama</span><input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></label>
        <label className="field"><span>HP</span><input value={c.phone} disabled /></label>
        <label className="field"><span>Email</span><input value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} /></label>
        <label className="field"><span>Tanggal lahir</span><input type="date" value={form.birth_date} onChange={(e) => setForm({ ...form, birth_date: e.target.value })} /></label>
        <label className="field"><span>Catatan</span><input value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} placeholder="alergi, preferensi…" /></label>
        <label className="row"><input type="checkbox" checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} /> Aktif</label>
      </div>

      <h3 style={{ margin: '16px 0 8px' }}>Koreksi / bonus poin</h3>
      <div className="row">
        <input type="number" placeholder="+50 / -20" value={adjust} onChange={(e) => setAdjust(e.target.value)} style={{ width: 110 }} />
        <input placeholder="Alasan (wajib)" value={adjustNote} onChange={(e) => setAdjustNote(e.target.value)} style={{ flex: 1 }} />
        <button disabled={!Number(adjust) || !adjustNote.trim()}
          onClick={() => run(() => rpc('crm_adjust_points', { p_customer_id: c.id, p_points: Number(adjust), p_note: adjustNote }), 'Poin disesuaikan.')}>
          Simpan Poin
        </button>
      </div>

      <h3 style={{ margin: '16px 0 8px' }}>Riwayat poin</h3>
      <table className="table">
        <tbody>
          {history.map((h) => (
            <tr key={h.id}>
              <td className="small">{formatDateTime(h.created_at)}</td>
              <td>{h.note}</td>
              <td className="right bold" style={{ color: h.points < 0 ? 'var(--danger)' : 'var(--success)' }}>{h.points > 0 ? '+' : ''}{h.points}</td>
              <td className="right muted">{h.balance_after}</td>
            </tr>
          ))}
          {!history.length && <tr><td className="empty">Belum ada riwayat poin.</td></tr>}
        </tbody>
      </table>
    </Modal>
  );
}

// ---------------------------------------------------------------- Promo
function PromotionsTab({ setError, setNotice }: Ctx) {
  const [rows, setRows] = useState<Promotion[]>([]);
  const [editing, setEditing] = useState<Partial<Promotion> | null>(null);

  const load = useCallback(async () => {
    setRows((await must(supabase.from('crm_promotions').select('*').order('is_active', { ascending: false }).order('created_at', { ascending: false }))) as Promotion[]);
  }, []);

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
  }, [load, setError]);

  const describe = (p: Promotion) => {
    const parts: string[] = [];
    if (p.days_of_week?.length) parts.push(p.days_of_week.map((d) => DAYS[d - 1]).join(', '));
    if (p.start_time || p.end_time) parts.push(`${p.start_time?.slice(0, 5) ?? '00:00'}–${p.end_time?.slice(0, 5) ?? '23:59'}`);
    if (p.start_date || p.end_date) parts.push(`${p.start_date ?? '…'} s/d ${p.end_date ?? '…'}`);
    if (Number(p.min_subtotal)) parts.push(`min ${formatRupiah(p.min_subtotal)}`);
    if (p.requires_member) parts.push('khusus member');
    if (p.menu_category_ids?.length || p.menu_item_ids?.length) parts.push('menu tertentu');
    if (p.sales_channels?.length) parts.push(p.sales_channels.map((c) => SALES_CHANNELS[c] ?? c).join('/'));
    return parts.join(' · ') || 'Semua transaksi';
  };

  return (
    <>
      <div className="card">
        <div className="row">
          <div className="muted small" style={{ flex: 1 }}>
            <b>Promo otomatis</b> (tanpa kode) langsung diterapkan di kasir bila syaratnya terpenuhi, dan sistem memilih yang potongannya terbesar.
            <b> Voucher</b> perlu kode yang diinput kasir.
          </div>
          <button className="btn-primary" onClick={() => setEditing({ discount_type: 'percent', discount_value: 10, min_subtotal: 0, is_active: true, requires_member: false })}>
            + Promo Baru
          </button>
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Nama</th><th>Jenis</th><th>Potongan</th><th>Syarat</th><th className="right">Dipakai</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.id} style={{ opacity: p.is_active ? 1 : 0.5 }}>
                <td className="bold">{p.name}</td>
                <td>{p.voucher_code ? <span className="badge badge-info">🎟️ {p.voucher_code}</span> : <span className="badge badge-success">Otomatis</span>}</td>
                <td>{p.discount_type === 'percent' ? `${Number(p.discount_value)}%` : formatRupiah(p.discount_value)}
                  {p.max_discount && <span className="muted small"> (maks {formatRupiah(p.max_discount)})</span>}</td>
                <td className="small">{describe(p)}</td>
                <td className="right">{p.usage_count}{p.usage_limit ? ` / ${p.usage_limit}` : ''}</td>
                <td>{p.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}</td>
                <td className="right"><button className="btn-sm" onClick={() => setEditing(p)}>Edit</button></td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={7} className="empty">Belum ada promo.</td></tr>}
          </tbody>
        </table>
      </div>
      {editing && (
        <PromotionForm promo={editing} onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); setNotice('Promo disimpan.'); load(); }} />
      )}
    </>
  );
}

function PromotionForm({ promo, onClose, onSaved }: { promo: Partial<Promotion>; onClose: () => void; onSaved: () => void }) {
  const { profile } = useAuth();
  const [p, setP] = useState<Partial<Promotion>>(promo);
  const [categories, setCategories] = useState<{ id: string; name: string }[]>([]);
  const [items, setItems] = useState<{ id: string; name: string }[]>([]);
  const [error, setError] = useState('');
  const set = (patch: Partial<Promotion>) => setP((x) => ({ ...x, ...patch }));

  useEffect(() => {
    Promise.all([
      must(supabase.from('mst_menu_categories').select('id, name').order('sort_order')),
      must(supabase.from('mst_menu_items').select('id, name').eq('is_active', true).order('name')),
    ]).then(([c, i]) => { setCategories(c); setItems(i); }).catch((e) => setError(errorMessage(e)));
  }, []);

  // toggle nilai di array; array kosong disimpan sebagai null (= berlaku untuk semua)
  const toggle = <T,>(key: keyof Promotion, value: T) => {
    const cur = ((p[key] as T[] | null | undefined) ?? []);
    const next = cur.includes(value) ? cur.filter((v) => v !== value) : [...cur, value];
    set({ [key]: next.length ? next : null } as Partial<Promotion>);
  };
  const has = (key: keyof Promotion, value: unknown) => ((p[key] as unknown[] | null | undefined) ?? []).includes(value);

  const save = async () => {
    setError('');
    try {
      const row = {
        company_id: profile!.company_id,
        name: p.name, voucher_code: p.voucher_code?.trim().toUpperCase() || null,
        discount_type: p.discount_type, discount_value: Number(p.discount_value),
        max_discount: p.max_discount ? Number(p.max_discount) : null, min_subtotal: Number(p.min_subtotal || 0),
        start_date: p.start_date || null, end_date: p.end_date || null, days_of_week: p.days_of_week ?? null,
        start_time: p.start_time || null, end_time: p.end_time || null,
        outlet_ids: p.outlet_ids ?? null, sales_channels: p.sales_channels ?? null,
        menu_item_ids: p.menu_item_ids ?? null, menu_category_ids: p.menu_category_ids ?? null,
        requires_member: !!p.requires_member, usage_limit: p.usage_limit ? Number(p.usage_limit) : null,
        per_customer_limit: p.per_customer_limit ? Number(p.per_customer_limit) : null, is_active: !!p.is_active,
      };
      await must(p.id ? supabase.from('crm_promotions').update(row).eq('id', p.id) : supabase.from('crm_promotions').insert(row));
      onSaved();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const chips = <T extends string | number>(key: keyof Promotion, options: [T, string][]) => (
    <div className="choice-list">
      {options.map(([v, label]) => (
        <button key={String(v)} type="button" className={has(key, v) ? 'active' : ''} onClick={() => toggle(key, v)}>{label}</button>
      ))}
    </div>
  );

  return (
    <Modal title={p.id ? `Edit ${p.name}` : 'Promo Baru'} onClose={onClose} large
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={!p.name || !(Number(p.discount_value) > 0)} onClick={save}>Simpan</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Nama promo</span><input value={p.name ?? ''} onChange={(e) => set({ name: e.target.value })} placeholder="Happy Hour Sore" /></label>
        <label className="field"><span>Kode voucher (kosong = otomatis)</span><input value={p.voucher_code ?? ''} onChange={(e) => set({ voucher_code: e.target.value.toUpperCase() })} placeholder="HEMAT20" /></label>
        <label className="field"><span>Jenis potongan</span>
          <select value={p.discount_type} onChange={(e) => set({ discount_type: e.target.value as 'percent' | 'amount' })}>
            <option value="percent">Persen (%)</option><option value="amount">Nominal (Rp)</option>
          </select>
        </label>
        <label className="field"><span>Besar potongan</span><input type="number" value={p.discount_value ?? ''} onChange={(e) => set({ discount_value: Number(e.target.value) })} /></label>
        {p.discount_type === 'percent' && (
          <label className="field"><span>Maks potongan (Rp)</span><MoneyInput value={p.max_discount ?? ''} onChange={(v) => set({ max_discount: v ? Number(v) : null })} /></label>
        )}
        <label className="field"><span>Minimal belanja (Rp)</span><MoneyInput value={p.min_subtotal ?? 0} onChange={(v) => set({ min_subtotal: Number(v) })} /></label>
        <label className="field"><span>Mulai tanggal</span><input type="date" value={p.start_date ?? ''} onChange={(e) => set({ start_date: e.target.value || null })} /></label>
        <label className="field"><span>Sampai tanggal</span><input type="date" value={p.end_date ?? ''} onChange={(e) => set({ end_date: e.target.value || null })} /></label>
        <label className="field"><span>Jam mulai</span><input type="time" value={p.start_time?.slice(0, 5) ?? ''} onChange={(e) => set({ start_time: e.target.value || null })} /></label>
        <label className="field"><span>Jam selesai</span><input type="time" value={p.end_time?.slice(0, 5) ?? ''} onChange={(e) => set({ end_time: e.target.value || null })} /></label>
        <label className="field"><span>Kuota total</span><input type="number" value={p.usage_limit ?? ''} onChange={(e) => set({ usage_limit: e.target.value ? Number(e.target.value) : null })} placeholder="tanpa batas" /></label>
        <label className="field"><span>Maks per member</span><input type="number" value={p.per_customer_limit ?? ''} onChange={(e) => set({ per_customer_limit: e.target.value ? Number(e.target.value) : null })} placeholder="tanpa batas" /></label>
      </div>

      <div className="grid" style={{ marginTop: 16 }}>
        <div><div className="muted small" style={{ marginBottom: 6 }}>Hari berlaku (kosong = setiap hari)</div>
          {chips('days_of_week', DAYS.map((d, i) => [i + 1, d] as [number, string]))}</div>
        <div><div className="muted small" style={{ marginBottom: 6 }}>Kanal (kosong = semua)</div>
          {chips('sales_channels', Object.entries(SALES_CHANNELS) as [string, string][])}</div>
        {profile!.outlets.length > 1 && (
          <div><div className="muted small" style={{ marginBottom: 6 }}>Outlet (kosong = semua)</div>
            {chips('outlet_ids', profile!.outlets.map((o) => [o.id, o.name] as [string, string]))}</div>
        )}
        <div><div className="muted small" style={{ marginBottom: 6 }}>Hanya untuk kategori (kosong = semua menu)</div>
          {chips('menu_category_ids', categories.map((c) => [c.id, c.name] as [string, string]))}</div>
        <div><div className="muted small" style={{ marginBottom: 6 }}>…atau menu tertentu</div>
          {chips('menu_item_ids', items.map((c) => [c.id, c.name] as [string, string]))}</div>
        <label className="row"><input type="checkbox" checked={!!p.requires_member} onChange={(e) => set({ requires_member: e.target.checked })} /> Khusus member</label>
        <label className="row"><input type="checkbox" checked={!!p.is_active} onChange={(e) => set({ is_active: e.target.checked })} /> Aktif</label>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- Program poin
function LoyaltyTab({ tiers, reloadTiers, setError, setNotice }: Ctx) {
  const { prompt } = useFeedback();
  const { profile } = useAuth();
  const [s, setS] = useState<{ is_points_enabled: boolean; earn_amount: number; redeem_value: number; min_redeem_points: number } | null>(null);
  const [tierRows, setTierRows] = useState<Tier[]>(tiers);

  useEffect(() => setTierRows(tiers), [tiers]);
  useEffect(() => {
    must(supabase.from('crm_settings').select('*').maybeSingle())
      .then((r) => setS(r ?? { is_points_enabled: true, earn_amount: 10000, redeem_value: 100, min_redeem_points: 100 }))
      .catch((e) => setError(errorMessage(e)));
  }, [setError]);

  const run = async (fn: () => Promise<unknown>, msg: string) => {
    try {
      await fn();
      setNotice(msg);
      await reloadTiers();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  if (!s) return null;
  const example = 100000;

  return (
    <div className="grid grid-2">
      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Aturan Poin</h2>
        <div className="grid">
          <label className="row"><input type="checkbox" checked={s.is_points_enabled} onChange={(e) => setS({ ...s, is_points_enabled: e.target.checked })} /> Program poin aktif</label>
          <label className="field"><span>Setiap belanja (Rp) dapat 1 poin</span><MoneyInput value={s.earn_amount} onChange={(v) => setS({ ...s, earn_amount: Number(v) })} /></label>
          <label className="field"><span>Nilai 1 poin saat ditukar (Rp)</span><MoneyInput value={s.redeem_value} onChange={(v) => setS({ ...s, redeem_value: Number(v) })} /></label>
          <label className="field"><span>Minimal tukar (poin)</span><input type="number" value={s.min_redeem_points} onChange={(e) => setS({ ...s, min_redeem_points: Number(e.target.value) })} /></label>
          <div className="alert alert-info small" style={{ margin: 0 }}>
            Contoh: belanja {formatRupiah(example)} → {Math.floor(example / (s.earn_amount || 1))} poin
            (senilai {formatRupiah(Math.floor(example / (s.earn_amount || 1)) * s.redeem_value)},
            ≈ {((s.redeem_value / (s.earn_amount || 1)) * 100).toFixed(1)}% cashback).
          </div>
          <button className="btn-primary" onClick={() => run(() => must(supabase.from('crm_settings').upsert({ company_id: profile!.company_id, ...s })), 'Aturan poin disimpan.')}>
            Simpan
          </button>
        </div>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Level Member</h2>
        <table className="table">
          <thead><tr><th>Level</th><th>Min. total belanja</th><th>Pengali poin</th><th></th></tr></thead>
          <tbody>
            {tierRows.map((t, idx) => (
              <tr key={t.id}>
                <td><input value={t.name} onChange={(e) => setTierRows(tierRows.map((x, i) => i === idx ? { ...x, name: e.target.value } : x))} style={{ width: 100 }} /></td>
                <td><MoneyInput value={t.min_total_spent} onChange={(v) => setTierRows(tierRows.map((x, i) => i === idx ? { ...x, min_total_spent: Number(v) } : x))} style={{ width: 130 }} /></td>
                <td><input type="number" step="0.05" value={t.point_multiplier} onChange={(e) => setTierRows(tierRows.map((x, i) => i === idx ? { ...x, point_multiplier: Number(e.target.value) } : x))} style={{ width: 80 }} />×</td>
                <td><button className="btn-sm" onClick={() => run(() => must(supabase.from('crm_membership_tiers')
                  .update({ name: t.name, min_total_spent: t.min_total_spent, point_multiplier: t.point_multiplier }).eq('id', t.id)), `Level ${t.name} disimpan.`)}>Simpan</button></td>
              </tr>
            ))}
          </tbody>
        </table>
        <button className="btn-sm" style={{ marginTop: 8 }} onClick={async () => {
          const name = await prompt({ title: 'Level member baru', label: 'Nama level', placeholder: 'contoh: Platinum' });
          if (name?.trim()) run(() => must(supabase.from('crm_membership_tiers').insert({ company_id: profile!.company_id, name: name.trim(), min_total_spent: 10000000, point_multiplier: 2 })), `Level ${name} dibuat.`);
        }}>+ Level</button>
        <p className="muted small">Level naik otomatis saat total belanja member mencapai batas. Member Gold dengan pengali 1.5× mendapat poin 50% lebih banyak.</p>
      </div>
    </div>
  );
}
