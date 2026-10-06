import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah, todayISO } from '../lib/format';
import Modal from '../components/Modal';

type Tab = 'reports' | 'journals' | 'expenses' | 'payables' | 'accounts' | 'ledger';

interface Account {
  id: string; code: string; name: string; account_type: string; normal_balance: string;
  is_header: boolean; system_key: string | null; parent_id: string | null; is_active: boolean;
}
interface Balance {
  account_id: string; code: string; name: string; account_type: string; normal_balance: string; is_header: boolean;
  system_key: string | null; opening_balance: number; period_debit: number; period_credit: number;
  period_balance: number; closing_balance: number;
}
interface JournalLine { id: string; account_id: string; debit: number; credit: number; note: string | null; fin_accounts: { code: string; name: string } }
interface Journal {
  id: string; journal_number: string; journal_date: string; source_type: string; description: string | null;
  total_amount: number; fin_journal_lines: JournalLine[];
}

const TYPE_LABEL: Record<string, string> = {
  asset: 'Aset', liability: 'Kewajiban', equity: 'Ekuitas', revenue: 'Pendapatan', cogs: 'HPP', expense: 'Beban',
};
const SOURCE_LABEL: Record<string, string> = {
  sales: 'Penjualan', purchase_receipt: 'Pembelian', stock_adjustment: 'Penyesuaian Stok', stock_opname: 'Stock Opname',
  supplier_payment: 'Bayar Supplier', expense: 'Biaya', manual: 'Manual', opening_stock: 'Saldo Awal',
};
const NATURAL_BALANCE: Record<string, string> = {
  asset: 'debit', cogs: 'debit', expense: 'debit', liability: 'credit', equity: 'credit', revenue: 'credit',
};
const monthStart = () => todayISO().slice(0, 8) + '01';
const isCashAccount = (a: Account) => a.account_type === 'asset' && !a.is_header && (a.system_key === 'cash' || a.system_key === 'bank' || a.code.startsWith('1-11') || a.code.startsWith('1-12'));

export default function FinancePage() {
  const { can } = useAuth();
  const [tab, setTab] = useState<Tab>('reports');
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const loadAccounts = useCallback(async () => {
    try {
      setAccounts((await must(supabase.from('fin_accounts').select('*').order('code'))) as Account[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);

  useEffect(() => {
    loadAccounts();
  }, [loadAccounts]);

  const manage = can('finance.manage');
  const tabs: [Tab, string, boolean][] = [
    ['reports', 'Laporan Keuangan', true],
    ['journals', 'Jurnal', true],
    ['expenses', 'Catat Biaya', manage],
    ['payables', 'Hutang Supplier', true],
    ['ledger', 'Buku Besar', true],
    ['accounts', 'Daftar Akun', true],
  ];
  const ctx = { accounts, reloadAccounts: loadAccounts, setError, setNotice, manage };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Keuangan</h1>
          <p>Jurnal otomatis dari penjualan, pembelian, dan stok.</p>
        </div>
      </div>
      <div className="tabs">
        {tabs.filter(([, , ok]) => ok).map(([k, v]) => (
          <button key={k} className={tab === k ? 'active' : ''} onClick={() => { setTab(k); setNotice(''); setError(''); }}>{v}</button>
        ))}
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      {notice && <div className="alert alert-success">{notice}</div>}
      {tab === 'reports' && <ReportsTab {...ctx} />}
      {tab === 'journals' && <JournalsTab {...ctx} />}
      {tab === 'expenses' && <ExpensesTab {...ctx} />}
      {tab === 'payables' && <PayablesTab {...ctx} />}
      {tab === 'ledger' && <LedgerTab {...ctx} />}
      {tab === 'accounts' && <AccountsTab {...ctx} />}
    </>
  );
}

interface Ctx {
  accounts: Account[];
  reloadAccounts: () => Promise<void>;
  setError: (m: string) => void;
  setNotice: (m: string) => void;
  manage: boolean;
}

function PeriodPicker({ from, to, setFrom, setTo, single }: {
  from?: string; to: string; setFrom?: (v: string) => void; setTo: (v: string) => void; single?: boolean;
}) {
  return (
    <div className="row">
      {!single && <><input type="date" value={from} onChange={(e) => setFrom!(e.target.value)} /><span>s/d</span></>}
      {single && <span className="muted">Per tanggal</span>}
      <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
    </div>
  );
}

// ---------------------------------------------------------------- Laporan keuangan
function ReportsTab({ setError }: Ctx) {
  const { profile } = useAuth();
  const [report, setReport] = useState<'pl' | 'bs' | 'tb'>('pl');
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(todayISO());
  const [outletId, setOutletId] = useState('');
  const [rows, setRows] = useState<Balance[]>([]);

  useEffect(() => {
    rpc<Balance[]>('fin_get_account_balances', {
      p_from: report === 'bs' ? '1900-01-01' : from, p_to: to, p_outlet_id: report === 'pl' && outletId ? outletId : null,
    })
      .then(setRows)
      .catch((e) => setError(errorMessage(e)));
  }, [report, from, to, outletId, setError]);

  // Saldo dari server bertanda menurut saldo normal akun. Akun kontra (Diskon Penjualan,
  // Akumulasi Penyusutan, Prive) dibalik tandanya agar mengurangi kelompoknya di laporan.
  const leaf = rows.filter((r) => !r.is_header).map((r) =>
    r.normal_balance === NATURAL_BALANCE[r.account_type]
      ? r
      : { ...r, period_balance: -Number(r.period_balance), closing_balance: -Number(r.closing_balance) });
  const sumType = (type: string, key: 'period_balance' | 'closing_balance') =>
    leaf.filter((r) => r.account_type === type).reduce((s, r) => s + Number(r[key]), 0);

  return (
    <>
      <div className="card">
        <div className="row">
          <div className="choice-list">
            {([['pl', 'Laba Rugi'], ['bs', 'Neraca'], ['tb', 'Neraca Saldo']] as const).map(([k, v]) => (
              <button key={k} className={report === k ? 'active' : ''} onClick={() => setReport(k)}>{v}</button>
            ))}
          </div>
          <span className="spacer" />
          {report === 'pl' && profile!.outlets.length > 1 && (
            <select value={outletId} onChange={(e) => setOutletId(e.target.value)}>
              <option value="">Semua outlet</option>
              {profile!.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select>
          )}
          <PeriodPicker from={from} to={to} setFrom={setFrom} setTo={setTo} single={report === 'bs'} />
          <button className="btn-sm" onClick={() => window.print()}>🖨️ Cetak</button>
        </div>
      </div>

      {report === 'pl' && <ProfitLoss rows={leaf} sumType={(t) => sumType(t, 'period_balance')} />}
      {report === 'bs' && <BalanceSheet rows={leaf} sumType={(t) => sumType(t, 'closing_balance')} asOf={to} />}
      {report === 'tb' && <TrialBalance rows={leaf} />}
    </>
  );
}

function StatementSection({ title, rows, valueKey, total, negate }: {
  title: string; rows: Balance[]; valueKey: 'period_balance' | 'closing_balance'; total: number; negate?: boolean;
}) {
  const shown = rows.filter((r) => Number(r[valueKey]) !== 0);
  return (
    <>
      <tr><td colSpan={2} className="bold" style={{ background: 'var(--surface-2)' }}>{title}</td></tr>
      {shown.map((r) => (
        <tr key={r.account_id}>
          <td style={{ paddingLeft: 24 }}><span className="muted small">{r.code}</span> {r.name}</td>
          <td className="right">{formatRupiah((negate ? -1 : 1) * Number(r[valueKey]))}</td>
        </tr>
      ))}
      {!shown.length && <tr><td style={{ paddingLeft: 24 }} className="muted" colSpan={2}>—</td></tr>}
      <tr><td className="bold">Total {title}</td><td className="right bold">{formatRupiah(total)}</td></tr>
    </>
  );
}

function ProfitLoss({ rows, sumType }: { rows: Balance[]; sumType: (t: string) => number }) {
  const revenueRows = rows.filter((r) => r.account_type === 'revenue');
  const revenue = sumType('revenue');
  const cogs = sumType('cogs');
  const expense = sumType('expense');
  const gross = revenue - cogs;
  const net = gross - expense;

  return (
    <div className="grid" style={{ gridTemplateColumns: 'minmax(0, 2fr) minmax(0, 1fr)', marginTop: 16 }}>
      <div className="card table-wrap">
        <table className="table">
          <tbody>
            <StatementSection title="Pendapatan" rows={revenueRows} valueKey="period_balance" total={revenue} />
            <StatementSection title="Harga Pokok Penjualan" rows={rows.filter((r) => r.account_type === 'cogs')} valueKey="period_balance" total={cogs} />
            <tr><td className="bold" style={{ fontSize: 16 }}>Laba Kotor</td><td className="right bold" style={{ fontSize: 16 }}>{formatRupiah(gross)}</td></tr>
            <StatementSection title="Beban Operasional" rows={rows.filter((r) => r.account_type === 'expense')} valueKey="period_balance" total={expense} />
            <tr>
              <td className="bold" style={{ fontSize: 18 }}>{net >= 0 ? 'Laba Bersih' : 'Rugi Bersih'}</td>
              <td className="right bold" style={{ fontSize: 18, color: net >= 0 ? 'var(--success)' : 'var(--danger)' }}>{formatRupiah(net)}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div className="grid" style={{ alignContent: 'start' }}>
        <div className="card"><div className="stat-label">Pendapatan bersih</div><div className="stat-value">{formatRupiah(revenue)}</div></div>
        <div className="card"><div className="stat-label">Food cost (HPP ÷ pendapatan)</div><div className="stat-value">{revenue ? ((cogs / revenue) * 100).toFixed(1) : 0}%</div></div>
        <div className="card"><div className="stat-label">Margin laba bersih</div><div className="stat-value">{revenue ? ((net / revenue) * 100).toFixed(1) : 0}%</div></div>
      </div>
    </div>
  );
}

function BalanceSheet({ rows, sumType, asOf }: { rows: Balance[]; sumType: (t: string) => number; asOf: string }) {
  const assets = sumType('asset');
  const liabilities = sumType('liability');
  const equity = sumType('equity');
  // laba berjalan = semua pendapatan - HPP - beban (belum ditutup ke laba ditahan)
  const earnings = sumType('revenue') - sumType('cogs') - sumType('expense');
  const right = liabilities + equity + earnings;
  const balanced = Math.abs(assets - right) < 1;

  return (
    <div className="grid grid-2" style={{ marginTop: 16 }}>
      <div className="card table-wrap">
        <table className="table">
          <tbody>
            <StatementSection title="Aset" rows={rows.filter((r) => r.account_type === 'asset')} valueKey="closing_balance" total={assets} />
          </tbody>
        </table>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <tbody>
            <StatementSection title="Kewajiban" rows={rows.filter((r) => r.account_type === 'liability')} valueKey="closing_balance" total={liabilities} />
            <StatementSection title="Ekuitas" rows={rows.filter((r) => r.account_type === 'equity')} valueKey="closing_balance" total={equity} />
            <tr><td style={{ paddingLeft: 24 }}>Laba (rugi) berjalan</td><td className="right">{formatRupiah(earnings)}</td></tr>
            <tr><td className="bold">Total Kewajiban + Ekuitas</td><td className="right bold">{formatRupiah(right)}</td></tr>
          </tbody>
        </table>
        <div className={`alert ${balanced ? 'alert-success' : 'alert-error'}`} style={{ marginTop: 12, marginBottom: 0 }}>
          {balanced ? `✅ Neraca seimbang per ${asOf}` : `⚠️ Selisih ${formatRupiah(assets - right)}`}
        </div>
      </div>
    </div>
  );
}

function TrialBalance({ rows }: { rows: Balance[] }) {
  const shown = rows.filter((r) => Number(r.opening_balance) || Number(r.period_debit) || Number(r.period_credit));
  const totalDebit = shown.reduce((s, r) => s + Number(r.period_debit), 0);
  const totalCredit = shown.reduce((s, r) => s + Number(r.period_credit), 0);
  return (
    <div className="card table-wrap" style={{ marginTop: 16 }}>
      <table className="table">
        <thead><tr><th>Kode</th><th>Akun</th><th className="right">Saldo Awal</th><th className="right">Debit</th><th className="right">Kredit</th><th className="right">Saldo Akhir</th></tr></thead>
        <tbody>
          {shown.map((r) => (
            <tr key={r.account_id}>
              <td>{r.code}</td><td>{r.name}</td>
              <td className="right">{formatRupiah(r.opening_balance)}</td>
              <td className="right">{formatRupiah(r.period_debit)}</td>
              <td className="right">{formatRupiah(r.period_credit)}</td>
              <td className="right bold">{formatRupiah(r.closing_balance)}</td>
            </tr>
          ))}
          <tr>
            <td colSpan={3} className="bold">Total mutasi</td>
            <td className="right bold">{formatRupiah(totalDebit)}</td>
            <td className="right bold">{formatRupiah(totalCredit)}</td>
            <td>{Math.abs(totalDebit - totalCredit) < 0.01 ? <span className="badge badge-success">Seimbang</span> : <span className="badge badge-danger">Tidak seimbang</span>}</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------- Jurnal
function JournalsTab({ accounts, manage, setError, setNotice }: Ctx) {
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(todayISO());
  const [source, setSource] = useState('');
  const [journals, setJournals] = useState<Journal[]>([]);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    let q = supabase.from('fin_journals')
      .select('*, fin_journal_lines(id, account_id, debit, credit, note, fin_accounts(code, name))')
      .gte('journal_date', from).lte('journal_date', to)
      .order('journal_date', { ascending: false }).order('created_at', { ascending: false }).limit(300);
    if (source) q = q.eq('source_type', source);
    setJournals((await must(q)) as Journal[]);
  }, [from, to, source]);

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
  }, [load, setError]);

  return (
    <>
      <div className="card">
        <div className="row">
          <PeriodPicker from={from} to={to} setFrom={setFrom} setTo={setTo} />
          <select value={source} onChange={(e) => setSource(e.target.value)}>
            <option value="">Semua jenis</option>
            {Object.entries(SOURCE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
          <span className="spacer" />
          {manage && <button className="btn-primary" onClick={() => setCreating(true)}>+ Jurnal Manual</button>}
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Tanggal</th><th>No. Jurnal</th><th>Jenis</th><th>Keterangan</th><th className="right">Nilai</th></tr></thead>
          <tbody>
            {journals.map((j) => (
              <Fragment key={j.id}>
                <tr onClick={() => setExpanded(expanded === j.id ? null : j.id)} style={{ cursor: 'pointer' }}>
                  <td>{j.journal_date}</td>
                  <td className="bold">{expanded === j.id ? '▾' : '▸'} {j.journal_number}</td>
                  <td><span className="badge">{SOURCE_LABEL[j.source_type] ?? j.source_type}</span></td>
                  <td>{j.description}</td>
                  <td className="right">{formatRupiah(j.total_amount)}</td>
                </tr>
                {expanded === j.id && (
                  <tr>
                    <td colSpan={5} style={{ background: 'var(--surface-2)' }}>
                      <table className="table">
                        <thead><tr><th>Akun</th><th className="right">Debit</th><th className="right">Kredit</th></tr></thead>
                        <tbody>
                          {[...j.fin_journal_lines].sort((a, b) => Number(b.debit) - Number(a.debit)).map((l) => (
                            <tr key={l.id}>
                              <td style={{ paddingLeft: Number(l.credit) ? 32 : 8 }}>{l.fin_accounts.code} · {l.fin_accounts.name} {l.note && <span className="muted small">({l.note})</span>}</td>
                              <td className="right">{Number(l.debit) ? formatRupiah(l.debit) : ''}</td>
                              <td className="right">{Number(l.credit) ? formatRupiah(l.credit) : ''}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {!journals.length && <tr><td colSpan={5} className="empty">Belum ada jurnal pada periode ini.</td></tr>}
          </tbody>
        </table>
      </div>
      {creating && (
        <ManualJournalModal accounts={accounts} onClose={() => setCreating(false)}
          onSaved={() => {
            setCreating(false);
            setNotice('Jurnal manual tersimpan.');
            load().catch((e) => setError(errorMessage(e)));
          }} />
      )}
    </>
  );
}

function AccountSelect({ accounts, value, onChange, filter, placeholder = '— pilih akun —' }: {
  accounts: Account[]; value: string; onChange: (v: string) => void; filter?: (a: Account) => boolean; placeholder?: string;
}) {
  const groups = Object.keys(TYPE_LABEL);
  return (
    <select value={value} onChange={(e) => onChange(e.target.value)} style={{ width: '100%' }}>
      <option value="">{placeholder}</option>
      {groups.map((g) => (
        <optgroup key={g} label={TYPE_LABEL[g]}>
          {accounts.filter((a) => a.account_type === g && !a.is_header && a.is_active && (!filter || filter(a))).map((a) => (
            <option key={a.id} value={a.id}>{a.code} · {a.name}</option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}

function ManualJournalModal({ accounts, onClose, onSaved }: { accounts: Account[]; onClose: () => void; onSaved: () => void }) {
  const [date, setDate] = useState(todayISO());
  const [description, setDescription] = useState('');
  const [lines, setLines] = useState([{ account_id: '', debit: '', credit: '' }, { account_id: '', debit: '', credit: '' }]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const debit = lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const credit = lines.reduce((s, l) => s + Number(l.credit || 0), 0);
  const balanced = debit > 0 && Math.abs(debit - credit) < 0.01;
  const update = (idx: number, patch: Partial<(typeof lines)[number]>) => setLines(lines.map((l, i) => (i === idx ? { ...l, ...patch } : l)));

  const save = async () => {
    setBusy(true);
    setError('');
    try {
      await rpc('fin_post_manual_journal', {
        p_date: date, p_description: description,
        p_lines: lines.filter((l) => l.account_id).map((l) => ({ account_id: l.account_id, debit: Number(l.debit || 0), credit: Number(l.credit || 0) })),
      });
      onSaved();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title="Jurnal Manual" onClose={onClose} large
      footer={<>
        <span className={balanced ? 'badge badge-success' : 'badge badge-warning'} style={{ marginRight: 'auto' }}>
          Debit {formatRupiah(debit)} · Kredit {formatRupiah(credit)}
        </span>
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={busy || !balanced || !description.trim()} onClick={save}>Simpan</button>
      </>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field"><span>Tanggal</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Keterangan</span>
          <input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="contoh: Setoran modal awal" /></label>
      </div>
      <table className="table" style={{ marginTop: 16 }}>
        <thead><tr><th>Akun</th><th>Debit</th><th>Kredit</th><th></th></tr></thead>
        <tbody>
          {lines.map((l, idx) => (
            <tr key={idx}>
              <td><AccountSelect accounts={accounts} value={l.account_id} onChange={(v) => update(idx, { account_id: v })} /></td>
              <td><input type="number" value={l.debit} onChange={(e) => update(idx, { debit: e.target.value, credit: '' })} style={{ width: 130 }} /></td>
              <td><input type="number" value={l.credit} onChange={(e) => update(idx, { credit: e.target.value, debit: '' })} style={{ width: 130 }} /></td>
              <td>{lines.length > 2 && <button className="btn-sm btn-danger" onClick={() => setLines(lines.filter((_, i) => i !== idx))}>✕</button>}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <button className="btn-sm" onClick={() => setLines([...lines, { account_id: '', debit: '', credit: '' }])}>+ Baris</button>
    </Modal>
  );
}

// ---------------------------------------------------------------- Biaya
function ExpensesTab({ accounts, setError, setNotice }: Ctx) {
  const { outlet } = useAuth();
  const [date, setDate] = useState(todayISO());
  const [expenseId, setExpenseId] = useState('');
  const [paidFromId, setPaidFromId] = useState('');
  const [amount, setAmount] = useState('');
  const [description, setDescription] = useState('');
  const [busy, setBusy] = useState(false);
  const [recent, setRecent] = useState<Journal[]>([]);

  useEffect(() => {
    if (!paidFromId) {
      const cash = accounts.find((a) => a.system_key === 'cash');
      if (cash) setPaidFromId(cash.id);
    }
  }, [accounts, paidFromId]);

  const load = useCallback(async () => {
    setRecent((await must(supabase.from('fin_journals')
      .select('*, fin_journal_lines(id, account_id, debit, credit, note, fin_accounts(code, name))')
      .eq('source_type', 'expense').order('created_at', { ascending: false }).limit(20))) as Journal[]);
  }, []);

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
  }, [load, setError]);

  const save = async () => {
    setBusy(true);
    setError('');
    try {
      await rpc('fin_record_expense', {
        p_date: date, p_expense_account_id: expenseId, p_paid_from_account_id: paidFromId,
        p_amount: Number(amount), p_description: description, p_outlet_id: outlet?.id ?? null,
      });
      setNotice(`Biaya ${formatRupiah(amount)} tercatat.`);
      setAmount('');
      setDescription('');
      await load();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid grid-2">
      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Catat Biaya Operasional</h2>
        <div className="grid">
          <label className="field"><span>Tanggal</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label className="field"><span>Jenis biaya</span>
            <AccountSelect accounts={accounts} value={expenseId} onChange={setExpenseId}
              filter={(a) => a.account_type === 'expense' || a.account_type === 'cogs'} />
          </label>
          <label className="field"><span>Dibayar dari</span>
            <AccountSelect accounts={accounts} value={paidFromId} onChange={setPaidFromId} filter={isCashAccount} />
          </label>
          <label className="field"><span>Nominal (Rp)</span><input type="number" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
          <label className="field"><span>Keterangan</span><input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="contoh: Bayar listrik Oktober" /></label>
          <button className="btn-primary" disabled={busy || !expenseId || !paidFromId || !(Number(amount) > 0)} onClick={save}>Simpan Biaya</button>
        </div>
      </div>
      <div className="card table-wrap">
        <h2 style={{ marginBottom: 12 }}>Biaya Terakhir</h2>
        <table className="table">
          <tbody>
            {recent.map((j) => {
              const exp = j.fin_journal_lines.find((l) => Number(l.debit) > 0);
              return (
                <tr key={j.id}>
                  <td>{j.journal_date}</td>
                  <td><div className="bold">{j.description}</div><div className="muted small">{exp?.fin_accounts.name}</div></td>
                  <td className="right">{formatRupiah(j.total_amount)}</td>
                </tr>
              );
            })}
            {!recent.length && <tr><td className="empty">Belum ada biaya tercatat.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Hutang supplier
interface Payable {
  goods_receipt_id: string; receipt_number: string; receipt_date: string; due_date: string | null;
  supplier_id: string; supplier_name: string; supplier_invoice_number: string | null;
  grand_total: number; paid_amount: number; outstanding_amount: number; is_overdue: boolean;
}

function PayablesTab({ accounts, manage, setError, setNotice }: Ctx) {
  const [rows, setRows] = useState<Payable[]>([]);
  const [showPaid, setShowPaid] = useState(false);
  const [paying, setPaying] = useState<{ supplierId: string; supplierName: string } | null>(null);

  const load = useCallback(async () => {
    let q = supabase.from('rpt_payables').select('*').order('due_date');
    if (!showPaid) q = q.gt('outstanding_amount', 0);
    setRows((await must(q)) as Payable[]);
  }, [showPaid]);

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
  }, [load, setError]);

  const bySupplier = useMemo(() => {
    const map = new Map<string, { name: string; total: number; overdue: number }>();
    for (const r of rows) {
      const cur = map.get(r.supplier_id) ?? { name: r.supplier_name, total: 0, overdue: 0 };
      cur.total += Number(r.outstanding_amount);
      if (r.is_overdue) cur.overdue += Number(r.outstanding_amount);
      map.set(r.supplier_id, cur);
    }
    return [...map.entries()].filter(([, v]) => v.total > 0);
  }, [rows]);

  return (
    <>
      <div className="grid grid-3">
        {bySupplier.map(([id, s]) => (
          <div key={id} className="card">
            <div className="stat-label">{s.name}</div>
            <div className="stat-value">{formatRupiah(s.total)}</div>
            {s.overdue > 0 && <div className="small" style={{ color: 'var(--danger)' }}>Jatuh tempo: {formatRupiah(s.overdue)}</div>}
            {manage && <button className="btn-sm btn-primary" style={{ marginTop: 8 }} onClick={() => setPaying({ supplierId: id, supplierName: s.name })}>Bayar</button>}
          </div>
        ))}
        {!bySupplier.length && <div className="card empty">🎉 Tidak ada hutang supplier.</div>}
      </div>
      <div className="card table-wrap" style={{ marginTop: 16 }}>
        <div className="card-header">
          <h2>Rincian per Penerimaan Barang</h2>
          <label className="row"><input type="checkbox" checked={showPaid} onChange={(e) => setShowPaid(e.target.checked)} /> Tampilkan yang sudah lunas</label>
        </div>
        <table className="table">
          <thead><tr><th>No. Penerimaan</th><th>Supplier</th><th>No. Faktur</th><th>Tanggal</th><th>Jatuh Tempo</th><th className="right">Total</th><th className="right">Dibayar</th><th className="right">Sisa</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.goods_receipt_id}>
                <td className="bold">{r.receipt_number}</td>
                <td>{r.supplier_name}</td>
                <td>{r.supplier_invoice_number ?? '-'}</td>
                <td>{r.receipt_date}</td>
                <td>{r.due_date} {r.is_overdue && <span className="badge badge-danger">Lewat</span>}</td>
                <td className="right">{formatRupiah(r.grand_total)}</td>
                <td className="right">{formatRupiah(r.paid_amount)}</td>
                <td className="right bold">{formatRupiah(r.outstanding_amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {paying && (
        <PaySupplierModal supplierName={paying.supplierName} accounts={accounts}
          payables={rows.filter((r) => r.supplier_id === paying.supplierId && Number(r.outstanding_amount) > 0)}
          supplierId={paying.supplierId}
          onClose={() => setPaying(null)}
          onPaid={(msg) => {
            setPaying(null);
            setNotice(msg);
            load().catch((e) => setError(errorMessage(e)));
          }} />
      )}
    </>
  );
}

function PaySupplierModal({ supplierId, supplierName, payables, accounts, onClose, onPaid }: {
  supplierId: string; supplierName: string; payables: Payable[]; accounts: Account[];
  onClose: () => void; onPaid: (msg: string) => void;
}) {
  const [accountId, setAccountId] = useState(accounts.find((a) => a.system_key === 'bank')?.id ?? '');
  const [date, setDate] = useState(todayISO());
  const [reference, setReference] = useState('');
  const [amounts, setAmounts] = useState<Record<string, string>>(
    Object.fromEntries(payables.map((p) => [p.goods_receipt_id, String(Number(p.outstanding_amount))])));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const total = Object.values(amounts).reduce((s, v) => s + Number(v || 0), 0);

  const pay = async () => {
    setBusy(true);
    setError('');
    try {
      const r = await rpc<{ payment_number: string }>('fin_pay_supplier', {
        p_supplier_id: supplierId, p_account_id: accountId, p_payment_date: date, p_reference_number: reference || null,
        p_allocations: Object.entries(amounts).filter(([, v]) => Number(v) > 0).map(([id, v]) => ({ goods_receipt_id: id, amount: Number(v) })),
      });
      onPaid(`Pembayaran ${r.payment_number} ke ${supplierName} sebesar ${formatRupiah(total)} tercatat.`);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title={`Bayar ${supplierName}`} onClose={onClose} large
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={busy || !accountId || total <= 0} onClick={pay}>Bayar {formatRupiah(total)}</button></>}>
      {error && <div className="alert alert-error">{error}</div>}
      <div className="form-grid">
        <label className="field"><span>Tanggal bayar</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>Dibayar dari</span><AccountSelect accounts={accounts} value={accountId} onChange={setAccountId} filter={isCashAccount} /></label>
        <label className="field"><span>No. referensi / transfer</span><input value={reference} onChange={(e) => setReference(e.target.value)} /></label>
      </div>
      <table className="table" style={{ marginTop: 16 }}>
        <thead><tr><th>Penerimaan</th><th>Jatuh tempo</th><th className="right">Sisa hutang</th><th>Dibayar sekarang</th></tr></thead>
        <tbody>
          {payables.map((p) => (
            <tr key={p.goods_receipt_id}>
              <td className="bold">{p.receipt_number}</td>
              <td>{p.due_date}</td>
              <td className="right">{formatRupiah(p.outstanding_amount)}</td>
              <td><input type="number" value={amounts[p.goods_receipt_id]} max={Number(p.outstanding_amount)}
                onChange={(e) => setAmounts({ ...amounts, [p.goods_receipt_id]: e.target.value })} style={{ width: 140 }} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </Modal>
  );
}

// ---------------------------------------------------------------- Buku besar
function LedgerTab({ accounts, setError }: Ctx) {
  const [accountId, setAccountId] = useState('');
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(todayISO());
  const [opening, setOpening] = useState(0);
  const [lines, setLines] = useState<{ id: string; debit: number; credit: number; note: string | null; fin_journals: { journal_number: string; journal_date: string; description: string | null } }[]>([]);

  const account = accounts.find((a) => a.id === accountId);

  useEffect(() => {
    if (!accountId && accounts.length) setAccountId(accounts.find((a) => a.system_key === 'cash')?.id ?? '');
  }, [accounts, accountId]);

  useEffect(() => {
    if (!accountId) return;
    Promise.all([
      rpc<Balance[]>('fin_get_account_balances', { p_from: from, p_to: to }),
      must(supabase.from('fin_journal_lines')
        .select('id, debit, credit, note, fin_journals!inner(journal_number, journal_date, description)')
        .eq('account_id', accountId)
        .gte('fin_journals.journal_date', from).lte('fin_journals.journal_date', to)
        .limit(1000)),
    ])
      .then(([balances, rows]) => {
        setOpening(Number(balances.find((b) => b.account_id === accountId)?.opening_balance ?? 0));
        setLines((rows as typeof lines).sort((a, b) => a.fin_journals.journal_date.localeCompare(b.fin_journals.journal_date)));
      })
      .catch((e) => setError(errorMessage(e)));
  }, [accountId, from, to, setError]);

  const sign = account?.normal_balance === 'credit' ? -1 : 1;
  let running = opening;

  return (
    <>
      <div className="card">
        <div className="row">
          <div style={{ minWidth: 280 }}><AccountSelect accounts={accounts} value={accountId} onChange={setAccountId} /></div>
          <PeriodPicker from={from} to={to} setFrom={setFrom} setTo={setTo} />
        </div>
      </div>
      <div className="card table-wrap">
        <table className="table">
          <thead><tr><th>Tanggal</th><th>No. Jurnal</th><th>Keterangan</th><th className="right">Debit</th><th className="right">Kredit</th><th className="right">Saldo</th></tr></thead>
          <tbody>
            <tr><td colSpan={5} className="bold">Saldo awal</td><td className="right bold">{formatRupiah(opening)}</td></tr>
            {lines.map((l) => {
              running += sign * (Number(l.debit) - Number(l.credit));
              return (
                <tr key={l.id}>
                  <td>{l.fin_journals.journal_date}</td>
                  <td>{l.fin_journals.journal_number}</td>
                  <td>{l.fin_journals.description} {l.note && <span className="muted small">({l.note})</span>}</td>
                  <td className="right">{Number(l.debit) ? formatRupiah(l.debit) : ''}</td>
                  <td className="right">{Number(l.credit) ? formatRupiah(l.credit) : ''}</td>
                  <td className="right">{formatRupiah(running)}</td>
                </tr>
              );
            })}
            <tr><td colSpan={5} className="bold">Saldo akhir</td><td className="right bold">{formatRupiah(running)}</td></tr>
          </tbody>
        </table>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- Daftar akun
function AccountsTab({ accounts, reloadAccounts, manage, setError, setNotice }: Ctx) {
  const { profile } = useAuth();
  const [balances, setBalances] = useState<Balance[]>([]);
  const [methods, setMethods] = useState<{ id: string; name: string; account_id: string | null }[]>([]);
  const [adding, setAdding] = useState<{ code: string; name: string; parent_id: string } | null>(null);

  const load = useCallback(async () => {
    const [b, m] = await Promise.all([
      rpc<Balance[]>('fin_get_account_balances', { p_from: '1900-01-01', p_to: todayISO() }),
      must(supabase.from('mst_payment_methods').select('id, name, account_id').order('sort_order')),
    ]);
    setBalances(b);
    setMethods(m as typeof methods);
  }, []);

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
  }, [load, setError]);

  const run = async (fn: () => Promise<unknown>, msg: string) => {
    try {
      await fn();
      setNotice(msg);
      await reloadAccounts();
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const balanceOf = (id: string) => Number(balances.find((b) => b.account_id === id)?.closing_balance ?? 0);
  const parent = accounts.find((a) => a.id === adding?.parent_id);

  return (
    <div className="grid" style={{ gridTemplateColumns: 'minmax(0, 2fr) minmax(0, 1fr)' }}>
      <div className="card table-wrap">
        <div className="card-header">
          <h2>Bagan Akun (COA)</h2>
          {manage && <button className="btn-primary" onClick={() => setAdding({ code: '', name: '', parent_id: accounts.find((a) => a.code === '6-0000')?.id ?? '' })}>+ Akun Baru</button>}
        </div>
        <table className="table">
          <thead><tr><th>Kode</th><th>Nama</th><th>Tipe</th><th className="right">Saldo</th></tr></thead>
          <tbody>
            {accounts.map((a) => (
              <tr key={a.id} style={a.is_header ? { background: 'var(--surface-2)' } : undefined}>
                <td className={a.is_header ? 'bold' : ''}>{a.code}</td>
                <td className={a.is_header ? 'bold' : ''} style={{ paddingLeft: a.is_header ? 8 : 24 }}>
                  {a.name} {a.system_key && <span className="badge" title="Dipakai jurnal otomatis">otomatis</span>}
                </td>
                <td className="muted small">{TYPE_LABEL[a.account_type]}</td>
                <td className="right">{a.is_header ? '' : formatRupiah(balanceOf(a.id))}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ alignSelf: 'start' }}>
        <h2 style={{ marginBottom: 4 }}>Metode Bayar → Akun</h2>
        <p className="muted small">Uang dari tiap metode pembayaran POS masuk ke akun ini.</p>
        <div className="grid">
          {methods.map((m) => (
            <label key={m.id} className="field"><span>{m.name}</span>
              <AccountSelect accounts={accounts} value={m.account_id ?? ''} filter={isCashAccount}
                onChange={(v) => manage && run(() => must(supabase.from('mst_payment_methods').update({ account_id: v || null }).eq('id', m.id)), `${m.name} diarahkan ke akun baru.`)} />
            </label>
          ))}
        </div>
        {!manage && <p className="muted small">Butuh hak akses finance.manage untuk mengubah.</p>}
      </div>

      {adding && (
        <Modal title="Akun Baru" onClose={() => setAdding(null)}
          footer={<>
            <button onClick={() => setAdding(null)}>Batal</button>
            <button className="btn-primary" disabled={!adding.code || !adding.name || !parent} onClick={() => run(async () => {
              await must(supabase.from('fin_accounts').insert({
                company_id: profile!.company_id, parent_id: parent!.id, code: adding.code.trim(), name: adding.name.trim(),
                account_type: parent!.account_type, normal_balance: parent!.normal_balance,
              }));
              setAdding(null);
            }, `Akun ${adding.name} dibuat.`)}>Simpan</button>
          </>}>
          <div className="grid">
            <label className="field"><span>Kelompok</span>
              <select value={adding.parent_id} onChange={(e) => setAdding({ ...adding, parent_id: e.target.value })}>
                {accounts.filter((a) => a.is_header).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
              </select>
            </label>
            <label className="field"><span>Kode</span><input value={adding.code} onChange={(e) => setAdding({ ...adding, code: e.target.value })} placeholder="contoh: 6-1950" /></label>
            <label className="field"><span>Nama akun</span><input value={adding.name} onChange={(e) => setAdding({ ...adding, name: e.target.value })} placeholder="contoh: Beban Laundry" /></label>
          </div>
        </Modal>
      )}
    </div>
  );
}
