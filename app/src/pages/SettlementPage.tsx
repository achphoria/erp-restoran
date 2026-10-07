import { useCallback, useEffect, useMemo, useState } from 'react';
import { Banknote } from 'lucide-react';
import Modal from '../components/Modal';
import MoneyInput from '../components/MoneyInput';
import { useFeedback } from '../components/Feedback';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';

type Tab = 'pending' | 'history' | 'methods';
interface Day {
  outlet_id: string; outlet_name: string; payment_method_id: string; payment_method_name: string; payment_type: string; business_date: string;
  order_count: number; sales_amount: number; refund_amount: number; net_amount: number; estimated_fee: number;
  settlement_id: string | null; needs_settlement: boolean;
}
interface Method {
  id: string; code: string; name: string; type: string; is_active: boolean; account_id: string | null; settlement_account_id: string | null;
  fee_account_id: string | null; fee_pct: number; settlement_from: string;
}
interface Account { id: string; code: string; name: string; account_type: string; is_header: boolean }
interface Settlement {
  id: string; settlement_number: string; settlement_date: string; date_from: string; date_to: string; expected_amount: number; received_amount: number;
  fee_amount: number; difference_amount: number; reference_number: string | null; sys_outlets: { name: string }; mst_payment_methods: { name: string };
}

// Settlement uang pendapatan POS: setoran tunai & pencairan EDC/QRIS/transfer/ojol per metode bayar
export default function SettlementPage() {
  const { can } = useAuth();
  const [tab, setTab] = useTabParam<Tab>('pending', ['pending', 'history', 'methods']);
  return (
    <>
      <div className="page-header">
        <div>
          <h1>Settlement POS</h1>
          <p>Cocokkan penjualan POS per metode bayar dengan dana yang benar-benar masuk: setoran tunai ke bank, pencairan EDC/QRIS/ojol beserta potongannya.</p>
        </div>
      </div>
      <div className="tabs">
        {([['pending', 'Belum di-settle'], ['history', 'Riwayat'], ['methods', 'Pengaturan metode']] as [Tab, string][]).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => setTab(k)}>{v}</button>
        ))}
      </div>
      {tab === 'pending' && <PendingTab canManage={can('finance.manage')} />}
      {tab === 'history' && <HistoryTab />}
      {tab === 'methods' && <MethodsTab canEdit={can('master.manage')} />}
    </>
  );
}

function PendingTab({ canManage }: { canManage: boolean }) {
  const { toast } = useFeedback();
  const { profile } = useAuth();
  const [outlet, setOutlet] = useState('');
  const [days, setDays] = useState<Day[]>([]);
  const [picked, setPicked] = useState<Record<string, string[]>>({});   // group key -> tanggal
  const [settling, setSettling] = useState<Day[] | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('rpt_pos_settlement_days').select('*').is('settlement_id', null).eq('needs_settlement', true).order('business_date');
    if (outlet) q = q.eq('outlet_id', outlet);
    setDays(await must(q));
    setPicked({});
  }, [outlet]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const groups = useMemo(() => {
    const map = new Map<string, Day[]>();
    for (const d of days) {
      const k = `${d.outlet_id}|${d.payment_method_id}`;
      map.set(k, [...(map.get(k) ?? []), d]);
    }
    return [...map.entries()];
  }, [days]);

  return (
    <>
      <div className="card">
        <div className="filter-bar" style={{ marginBottom: 0 }}>
          <select value={outlet} onChange={(e) => setOutlet(e.target.value)}>
            <option value="">Semua outlet</option>
            {profile?.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
          <span className="muted small">Total belum di-settle: <b>{formatRupiah(days.reduce((s, d) => s + Number(d.net_amount), 0))}</b></span>
        </div>
      </div>
      <div className="grid grid-2">
        {groups.map(([k, ds]) => {
          const sel = picked[k] ?? [];
          const chosen = ds.filter((d) => sel.includes(d.business_date));
          return (
            <div key={k} className="card">
              <div className="card-header">
                <h3>{ds[0].payment_method_name} <span className="muted small">· {ds[0].outlet_name}</span></h3>
                <b>{formatRupiah(ds.reduce((s, d) => s + Number(d.net_amount), 0))}</b>
              </div>
              <table className="table">
                <thead><tr><th style={{ width: 28 }}><input type="checkbox" aria-label="Pilih semua" checked={sel.length === ds.length}
                  onChange={(e) => setPicked({ ...picked, [k]: e.target.checked ? ds.map((d) => d.business_date) : [] })} /></th>
                  <th>Tanggal</th><th className="right">Order</th><th className="right">Bersih</th></tr></thead>
                <tbody>
                  {ds.map((d) => (
                    <tr key={d.business_date}>
                      <td><input type="checkbox" checked={sel.includes(d.business_date)}
                        onChange={(e) => setPicked({ ...picked, [k]: e.target.checked ? [...sel, d.business_date] : sel.filter((x) => x !== d.business_date) })} /></td>
                      <td>{d.business_date}</td>
                      <td className="right">{d.order_count}</td>
                      <td className="right">{formatRupiah(d.net_amount)}{Number(d.refund_amount) > 0 && <div className="muted small">refund −{formatRupiah(d.refund_amount)}</div>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="row" style={{ justifyContent: 'flex-end', marginTop: 8 }}>
                <button className="btn-primary" disabled={!chosen.length || !canManage} title={canManage ? '' : 'Butuh akses finance.manage'} onClick={() => setSettling(chosen)}>
                  <Banknote size={16} /> {ds[0].payment_type === 'cash' ? 'Catat setoran' : 'Catat pencairan'} ({chosen.length})</button>
              </div>
            </div>
          );
        })}
      </div>
      {!groups.length && <div className="card empty">Semua penjualan POS sudah di-settle 🎉</div>}
      {settling && <SettleModal days={settling} onClose={() => setSettling(null)} onDone={() => { setSettling(null); load(); }} />}
    </>
  );
}

function SettleModal({ days, onClose, onDone }: { days: Day[]; onClose: () => void; onDone: () => void }) {
  const { toast } = useFeedback();
  const cash = days[0].payment_type === 'cash';
  const expected = days.reduce((s, d) => s + Number(d.net_amount), 0);
  const est = cash ? 0 : days.reduce((s, d) => s + Number(d.estimated_fee), 0);
  const [received, setReceived] = useState(String(expected - est));
  const [fee, setFee] = useState(String(est));
  const [date, setDate] = useState(todayISO());
  const [ref, setRef] = useState('');
  const [note, setNote] = useState('');
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [to, setTo] = useState('');
  const [busy, setBusy] = useState(false);
  const diff = expected - Number(received || 0) - Number(fee || 0);

  useEffect(() => {
    Promise.all([
      must(supabase.from('fin_accounts').select('id, code, name, account_type, is_header').eq('account_type', 'asset').eq('is_header', false).or('code.like.1-11%,code.like.1-12%').order('code')),
      must(supabase.from('mst_payment_methods').select('settlement_account_id').eq('id', days[0].payment_method_id).single()),
    ]).then(([a, m]) => { setAccounts(a); setTo(m.settlement_account_id ?? a.find((x: Account) => x.code === '1-1200')?.id ?? ''); })
      .catch((e) => toast(errorMessage(e), 'error'));
  }, [days, toast]);

  const save = async () => {
    setBusy(true);
    try {
      const r = await rpc<{ settlement_number: string }>('pos_create_settlement', {
        p_outlet_id: days[0].outlet_id, p_payment_method_id: days[0].payment_method_id, p_dates: days.map((d) => d.business_date),
        p_received_amount: Number(received || 0), p_fee_amount: Number(fee || 0), p_to_account_id: to || null, p_settlement_date: date,
        p_reference: ref || null, p_note: note || null,
      });
      toast(`Settlement ${r.settlement_number} tercatat`);
      onDone();
    } catch (e) { toast(errorMessage(e), 'error'); setBusy(false); }
  };

  return (
    <Modal title={`${cash ? 'Setoran tunai' : 'Pencairan'} ${days[0].payment_method_name}`} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !to || Number(received) < 0} onClick={save}>Simpan settlement</button></>}>
      <p className="muted small" style={{ marginTop: 0 }}>{days[0].outlet_name} · {days.length} hari ({days[0].business_date}{days.length > 1 ? ` s/d ${days[days.length - 1].business_date}` : ''})</p>
      <div className="grid grid-3" style={{ marginBottom: 12 }}>
        <div><div className="stat-label">Seharusnya</div><b>{formatRupiah(expected)}</b></div>
        <div><div className="stat-label">{cash ? 'Disetor' : 'Masuk bank'}</div><b>{formatRupiah(Number(received || 0))}</b></div>
        <div><div className="stat-label">Selisih</div><b style={{ color: Math.abs(diff) > 0.5 ? 'var(--danger)' : 'var(--success)' }}>{formatRupiah(diff)}</b></div>
      </div>
      <div className="form-grid">
        <label className="field"><span>{cash ? 'Jumlah disetor' : 'Dana masuk ke bank'}</span><MoneyInput value={received} onChange={setReceived} /></label>
        {!cash && <label className="field"><span>Potongan MDR / komisi</span><MoneyInput value={fee} onChange={setFee} /></label>}
        <label className="field"><span>Masuk ke akun</span>
          <select value={to} onChange={(e) => setTo(e.target.value)}>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label>
        <label className="field"><span>Tanggal {cash ? 'setor' : 'dana masuk'}</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>No. referensi / slip</span><input value={ref} onChange={(e) => setRef(e.target.value)} /></label>
        <label className="field"><span>Catatan</span><input value={note} onChange={(e) => setNote(e.target.value)} /></label>
      </div>
      <p className="muted small">Jurnal: {cash ? 'Bank | Kas' : 'Bank + beban potongan | Piutang Settlement'}. Selisih (kurang/lebih) masuk akun <b>Selisih Kas & Settlement</b>.</p>
    </Modal>
  );
}

function HistoryTab() {
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Settlement[]>([]);
  useEffect(() => {
    must(supabase.from('pos_settlements').select('*, sys_outlets(name), mst_payment_methods(name)').order('created_at', { ascending: false }).limit(200))
      .then(setRows).catch((e) => toast(errorMessage(e), 'error'));
  }, [toast]);
  return (
    <div className="card table-wrap">
      <table className="table">
        <thead><tr><th>No.</th><th>Outlet</th><th>Metode</th><th>Periode penjualan</th><th className="right">Seharusnya</th><th className="right">Diterima</th><th className="right">Potongan</th><th className="right">Selisih</th></tr></thead>
        <tbody>
          {rows.map((s) => (
            <tr key={s.id}>
              <td className="bold">{s.settlement_number}<div className="muted small">{s.settlement_date}{s.reference_number ? ` · ${s.reference_number}` : ''}</div></td>
              <td>{s.sys_outlets.name}</td>
              <td>{s.mst_payment_methods.name}</td>
              <td className="small">{s.date_from}{s.date_to !== s.date_from ? ` – ${s.date_to}` : ''}</td>
              <td className="right">{formatRupiah(s.expected_amount)}</td>
              <td className="right">{formatRupiah(s.received_amount)}</td>
              <td className="right">{formatRupiah(s.fee_amount)}</td>
              <td className="right" style={{ color: Math.abs(Number(s.difference_amount)) > 0.5 ? 'var(--danger)' : undefined }}>{formatRupiah(s.difference_amount)}</td>
            </tr>
          ))}
          {!rows.length && <tr><td colSpan={8} className="empty">Belum ada settlement.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}

const TYPE_LABEL: Record<string, string> = { cash: 'Tunai', card: 'Kartu (EDC)', ewallet: 'E-wallet / QRIS', online: 'Ojol / online', other: 'Lainnya' };

function MethodsTab({ canEdit }: { canEdit: boolean }) {
  const { toast } = useFeedback();
  const [methods, setMethods] = useState<Method[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [dirty, setDirty] = useState<Record<string, Partial<Method>>>({});

  const load = useCallback(async () => {
    const [m, a] = await Promise.all([
      must(supabase.from('mst_payment_methods').select('*').order('sort_order')),
      must(supabase.from('fin_accounts').select('id, code, name, account_type, is_header').eq('is_header', false).eq('is_active', true).order('code')).catch(() => []),
    ]);
    setMethods(m); setAccounts(a); setDirty({});
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const val = <K extends keyof Method>(m: Method, k: K): Method[K] => (dirty[m.id]?.[k] ?? m[k]) as Method[K];
  const set = (id: string, patch: Partial<Method>) => setDirty({ ...dirty, [id]: { ...dirty[id], ...patch } });
  const assets = accounts.filter((a) => a.account_type === 'asset');
  const expenses = accounts.filter((a) => ['expense', 'cogs'].includes(a.account_type));

  const save = async () => {
    try {
      for (const [id, patch] of Object.entries(dirty)) await must(supabase.from('mst_payment_methods').update(patch).eq('id', id));
      toast('Pengaturan metode bayar disimpan');
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <div className="card table-wrap">
      <div className="filter-bar">
        <span className="muted small">Akun penjualan = tempat uang POS dicatat saat transaksi (non tunai sebaiknya ke <b>Piutang Settlement</b>). Saat settle, dana dipindah ke akun cair dan potongan ke akun beban.</span>
        {canEdit && <button className="btn-primary" style={{ marginLeft: 'auto' }} disabled={!Object.keys(dirty).length} onClick={save}>Simpan ({Object.keys(dirty).length})</button>}
      </div>
      {!accounts.length && <div className="alert alert-info small">Akun tidak tampil karena Anda tidak punya akses Keuangan.</div>}
      <table className="table">
        <thead><tr><th>Metode</th><th>Akun penjualan</th><th>Cair ke</th><th>Potongan %</th><th>Akun potongan</th><th>Settlement mulai</th></tr></thead>
        <tbody>
          {methods.map((m) => (
            <tr key={m.id} style={{ opacity: m.is_active ? 1 : 0.5 }}>
              <td><b>{m.name}</b><div className="muted small">{TYPE_LABEL[m.type] ?? m.type}</div></td>
              <td><select disabled={!canEdit} value={val(m, 'account_id') ?? ''} onChange={(e) => set(m.id, { account_id: e.target.value || null })}>
                {assets.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></td>
              <td><select disabled={!canEdit} value={val(m, 'settlement_account_id') ?? ''} onChange={(e) => set(m.id, { settlement_account_id: e.target.value || null })}>
                <option value="">—</option>{assets.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></td>
              <td><input type="number" step="0.01" min={0} max={100} style={{ width: 80 }} disabled={!canEdit || m.type === 'cash'} value={val(m, 'fee_pct')}
                onChange={(e) => set(m.id, { fee_pct: Number(e.target.value) })} /></td>
              <td><select disabled={!canEdit || m.type === 'cash'} value={val(m, 'fee_account_id') ?? ''} onChange={(e) => set(m.id, { fee_account_id: e.target.value || null })}>
                <option value="">—</option>{expenses.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></td>
              <td><input type="date" disabled={!canEdit} value={val(m, 'settlement_from')} onChange={(e) => set(m.id, { settlement_from: e.target.value })} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
