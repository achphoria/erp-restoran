import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowDownRight, ArrowUpRight, Building2, ChevronDown, ChevronRight, Download, LogIn } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import { rpc } from '../lib/supabase';
import { errorMessage, formatRupiah } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import { downloadXlsx } from '../lib/excel';
import { addDays, localDate } from '../lib/hr';
import IcTab from '../components/group/IcTab';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Tab = 'summary' | 'pl' | 'bs' | 'ic';
const COLORS = ['#1F7F72', '#F7B733', '#FC4A1A', '#6C63FF', '#2E86DE', '#8E44AD', '#27AE60', '#7F8C8D'];
const PRESETS: [string, () => [string, string]][] = [
  ['Hari ini', () => [localDate(), localDate()]],
  ['7 hari', () => [addDays(localDate(), -6), localDate()]],
  ['Bulan ini', () => [`${localDate().slice(0, 7)}-01`, localDate()]],
  ['Bulan lalu', () => { const d = new Date(`${localDate().slice(0, 7)}-01T00:00:00Z`); d.setUTCDate(0); const end = d.toISOString().slice(0, 10); return [`${end.slice(0, 7)}-01`, end]; }],
  ['Tahun ini', () => [`${localDate().slice(0, 4)}-01-01`, localDate()]],
];
const short = (n: number) => {
  const a = Math.abs(n);
  const s = a >= 1e9 ? `${(a / 1e9).toFixed(1)} M` : a >= 1e6 ? `${(a / 1e6).toFixed(1)} jt` : a >= 1e3 ? `${Math.round(a / 1e3)} rb` : String(Math.round(a));
  return (n < 0 ? '-' : '') + s.replace('.', ',');
};
const pct = (cur: number, prev: number) => (prev ? Math.round(((cur - prev) / prev) * 1000) / 10 : null);

// Dashboard grup usaha: semua PT sekaligus + laba rugi & neraca konsolidasi (dengan eliminasi antar-PT)
export default function GroupPage() {
  const { switchCompany } = useAuth();
  const { toast } = useFeedback();
  const [tab, setTab] = useTabParam<Tab>('summary', ['summary', 'pl', 'bs', 'ic']);
  const [groups, setGroups] = useState<any[] | null>(null);
  const [groupId, setGroupId] = useState('');
  const [[from, to], setRange] = useState<[string, string]>(PRESETS[2][1]);
  const [dash, setDash] = useState<any | null>(null);
  const [fin, setFin] = useState<any | null>(null);

  useEffect(() => {
    rpc<any[]>('grp_my_groups').then((g) => { setGroups(g); setGroupId((cur) => cur || g[0]?.id || ''); }).catch((e) => toast(errorMessage(e), 'error'));
  }, [toast]);
  const load = useCallback(async () => {
    if (!groupId) return;
    const [d, f] = await Promise.all([rpc<any>('grp_dashboard', { p_group_id: groupId, p_from: from, p_to: to }),
      rpc<any>('grp_financials', { p_group_id: groupId, p_from: from, p_to: to })]);
    setDash(d);
    setFin(f);
  }, [groupId, from, to]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const companies: any[] = dash?.companies ?? [];
  const color = (id: string) => COLORS[Math.max(0, companies.findIndex((c) => c.id === id)) % COLORS.length];
  const tot = (k: string) => companies.reduce((s, c) => s + Number(c[k] ?? 0), 0);
  const group = groups?.find((g) => g.id === groupId);

  const enter = async (id: string) => {
    try { await switchCompany(id); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  if (groups && !groups.length) {
    return (
      <>
        <div className="page-header"><div><h1>Dashboard Grup</h1></div></div>
        <div className="card empty">Anda belum menjadi pemilik grup usaha. Grup (beberapa PT) diatur oleh Platform Admin di menu <b>Platform → Grup</b>.</div>
      </>
    );
  }

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Dashboard Grup</h1>
          <p>{group ? `${group.name} · ${group.companies.length} PT` : 'Memuat…'} · semua angka digabung, transaksi antar-PT dieliminasi di laporan konsolidasi.</p>
        </div>
        {groups && groups.length > 1 && (
          <select value={groupId} onChange={(e) => setGroupId(e.target.value)}>{groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}</select>
        )}
      </div>
      <div className="task-toolbar">
        <div className="seg">{PRESETS.map(([l, f]) => { const [a, b] = f(); return <button key={l} className={a === from && b === to ? 'active' : ''} onClick={() => setRange([a, b])}>{l}</button>; })}</div>
        <div className="row" style={{ gap: 6 }}>
          <input type="date" value={from} max={to} onChange={(e) => setRange([e.target.value, to])} /><span className="muted">s/d</span>
          <input type="date" value={to} min={from} onChange={(e) => setRange([from, e.target.value])} />
        </div>
      </div>
      <div className="tabs">
        <button className={tab === 'summary' ? 'active' : ''} onClick={() => setTab('summary')}>Ringkasan</button>
        <button className={tab === 'pl' ? 'active' : ''} onClick={() => setTab('pl')}>Laba Rugi Konsolidasi</button>
        <button className={tab === 'bs' ? 'active' : ''} onClick={() => setTab('bs')}>Neraca Konsolidasi</button>
        <button className={tab === 'ic' ? 'active' : ''} onClick={() => setTab('ic')}>Antar-PT</button>
      </div>

      {tab === 'summary' && dash && (
        <>
          <div className="grp-kpis">
            <Kpi label="Penjualan bersih" value={formatRupiah(tot('net_sales'))} growth={pct(tot('net_sales'), tot('prev_net_sales'))} sub={`${tot('orders').toLocaleString('id-ID')} transaksi`} />
            <Kpi label="Rata-rata per transaksi" value={formatRupiah(tot('orders') ? tot('net_sales') / tot('orders') : 0)} sub={`${tot('outlets')} outlet aktif`} />
            <Kpi label="Laba bersih (jurnal)" value={formatRupiah(tot('net_profit'))} tone={tot('net_profit') < 0 ? 'neg' : 'pos'}
              sub={tot('revenue') ? `margin ${Math.round((tot('net_profit') / tot('revenue')) * 100)}%` : 'belum ada jurnal'} />
            <Kpi label="Karyawan hadir hari ini" value={`${tot('present_today')} / ${tot('scheduled_today') || tot('employees')}`} sub={`${tot('employees')} karyawan aktif`} />
          </div>

          <div className="card">
            <div className="card-header"><h2>Penjualan harian per PT</h2>
              <div className="grp-legend">{companies.map((c) => <span key={c.id}><i style={{ background: color(c.id) }} />{c.name}</span>)}</div></div>
            <DailyChart daily={dash.daily} from={from} to={to} color={color} />
          </div>

          <div className="card table-wrap">
            <div className="card-header"><h2>Perbandingan PT</h2></div>
            <table className="table">
              <thead><tr><th>PT</th><th className="right">Penjualan bersih</th><th className="right">vs periode lalu</th><th className="right">Transaksi</th>
                <th className="right">Laba bersih</th><th className="right">Stok menipis</th><th className="right">Hadir</th><th className="right">Rating</th><th className="right">Menunggu</th><th></th></tr></thead>
              <tbody>
                {companies.map((c) => {
                  const g = pct(Number(c.net_sales), Number(c.prev_net_sales));
                  const share = tot('net_sales') ? (Number(c.net_sales) / tot('net_sales')) * 100 : 0;
                  return (
                    <tr key={c.id}>
                      <td><div className="row" style={{ flexWrap: 'nowrap' }}><i className="grp-dot" style={{ background: color(c.id) }} /><b>{c.name}</b></div>
                        <div className="grp-share"><span style={{ width: `${share}%`, background: color(c.id) }} /></div></td>
                      <td className="right bold">{formatRupiah(c.net_sales)}</td>
                      <td className="right">{g == null ? '—' : <span className={g >= 0 ? 'text-success' : 'text-danger'}>{g >= 0 ? '+' : ''}{g}%</span>}</td>
                      <td className="right">{Number(c.orders).toLocaleString('id-ID')}</td>
                      <td className={`right ${Number(c.net_profit) < 0 ? 'text-danger' : ''}`}>{formatRupiah(c.net_profit)}</td>
                      <td className="right">{c.low_stock > 0 ? <span className="badge badge-warning">{c.low_stock}</span> : '—'}</td>
                      <td className="right">{c.present_today}/{c.scheduled_today || c.employees}</td>
                      <td className="right">{c.rating ? `${c.rating}★` : '—'}<div className="muted small">{c.reviews ? `${c.reviews} ulasan` : ''}</div></td>
                      <td className="right small">{Number(c.pending_approvals) + Number(c.pending_leave) > 0 ? `${c.pending_approvals} approval · ${c.pending_leave} cuti` : '—'}</td>
                      <td className="right"><button className="btn-sm" onClick={() => enter(c.id)} title="Masuk ke PT ini"><LogIn size={13} /> Masuk</button></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <div className="grid grid-2" style={{ alignItems: 'start' }}>
            <div className="card table-wrap">
              <h3 style={{ marginTop: 0 }}>Outlet terlaris</h3>
              <table className="table"><tbody>
                {dash.top_outlets.map((o: any, i: number) => <tr key={i}><td><b>{o.outlet}</b><div className="muted small">{o.company}</div></td><td className="right">{formatRupiah(o.net_sales)}<div className="muted small">{o.orders} trx</div></td></tr>)}
                {!dash.top_outlets.length && <tr><td className="empty">Belum ada penjualan.</td></tr>}
              </tbody></table>
            </div>
            <div className="card table-wrap">
              <h3 style={{ marginTop: 0 }}>Menu terlaris se-grup</h3>
              <table className="table"><tbody>
                {dash.top_menus.map((m: any, i: number) => <tr key={i}><td><b>{i + 1}. {m.name}</b>{m.companies > 1 && <div className="muted small">dijual di {m.companies} PT</div>}</td><td className="right">{Number(m.qty).toLocaleString('id-ID')} porsi<div className="muted small">{short(Number(m.revenue))}</div></td></tr>)}
                {!dash.top_menus.length && <tr><td className="empty">Belum ada penjualan.</td></tr>}
              </tbody></table>
            </div>
          </div>
        </>
      )}

      {tab === 'ic' && groupId && <IcTab groupId={groupId} />}
      {(tab === 'pl' || tab === 'bs') && fin && <Statement kind={tab} fin={fin} from={from} to={to} groupName={group?.name ?? 'grup'} />}
    </>
  );
}

function Kpi({ label, value, sub, growth, tone }: { label: string; value: string; sub?: string; growth?: number | null; tone?: 'pos' | 'neg' }) {
  return (
    <div className={`card grp-kpi ${tone ?? ''}`}>
      <small className="muted">{label}</small>
      <b>{value}</b>
      <span className="small muted">
        {growth != null && <span className={growth >= 0 ? 'text-success' : 'text-danger'}>{growth >= 0 ? <ArrowUpRight size={13} /> : <ArrowDownRight size={13} />}{growth >= 0 ? '+' : ''}{growth}% </span>}
        {sub}
      </span>
    </div>
  );
}

// grafik batang bertumpuk per hari (SVG sederhana, tanpa library)
function DailyChart({ daily, from, to, color }: { daily: any[]; from: string; to: string; color: (id: string) => string }) {
  const days = useMemo(() => {
    const out: string[] = [];
    for (let d = from; d <= to && out.length < 400; d = addDays(d, 1)) out.push(d);
    return out;
  }, [from, to]);
  const byDay = useMemo(() => {
    const m: Record<string, { id: string; v: number }[]> = {};
    for (const r of daily) (m[r.date] ??= []).push({ id: r.company_id, v: Number(r.net_sales) });
    return m;
  }, [daily]);
  const max = Math.max(1, ...days.map((d) => (byDay[d] ?? []).reduce((s, x) => s + x.v, 0)));
  if (!daily.length) return <p className="muted">Belum ada penjualan di rentang ini.</p>;
  const W = 760, H = 220, pad = 34, bw = Math.max(2, (W - pad) / days.length - 2);
  const step = Math.ceil(days.length / 10);
  return (
    <svg viewBox={`0 0 ${W} ${H + 24}`} className="grp-chart" role="img" aria-label="Penjualan harian per PT">
      {[0, 0.5, 1].map((t) => <g key={t}><line x1={pad} x2={W} y1={H - t * (H - 10)} y2={H - t * (H - 10)} className="grp-grid" /><text x={0} y={H - t * (H - 10) + 4} className="grp-axis">{short(max * t)}</text></g>)}
      {days.map((d, i) => {
        let y = H;
        const x = pad + i * ((W - pad) / days.length) + 1;
        return (
          <g key={d}>
            {(byDay[d] ?? []).map((s) => { const h = (s.v / max) * (H - 10); y -= h; return <rect key={s.id} x={x} y={y} width={bw} height={h} fill={color(s.id)} rx={1.5}><title>{`${d}: ${formatRupiah(s.v)}`}</title></rect>; })}
            {i % step === 0 && <text x={x + bw / 2} y={H + 16} textAnchor="middle" className="grp-axis">{new Date(`${d}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', timeZone: 'UTC' })}</text>}
          </g>
        );
      })}
    </svg>
  );
}

// laporan laba rugi / neraca: kolom per PT + eliminasi + konsolidasi, kelompok bisa dilipat
function Statement({ kind, fin, from, to, groupName }: { kind: 'pl' | 'bs'; fin: any; from: string; to: string; groupName: string }) {
  const [closed, setClosed] = useState<Record<string, boolean>>({});
  const cs: any[] = fin.companies;
  const types = kind === 'pl' ? [['revenue', 'Pendapatan'], ['cogs', 'Harga Pokok Penjualan'], ['expense', 'Beban Operasional']] : [['asset', 'Aset'], ['liability', 'Kewajiban'], ['equity', 'Ekuitas']];
  const rows = (t: string) => fin.accounts.filter((a: any) => a.account_type === t && !a.is_header && (Number(a.total) !== 0 || Number(a.consolidated) !== 0));
  const sumBy = (t: string, key: string) => rows(t).reduce((s: number, a: any) => s + Number(key === 'total' || key === 'elimination' || key === 'consolidated' ? a[key] : a.by_company[key] ?? 0), 0);
  const cols = [...cs.map((c) => c.id), 'elimination', 'consolidated'];
  const re = (k: string) => (k === 'elimination' ? Number(fin.retained_earnings_elim ?? 0) : k === 'consolidated'
    ? cs.reduce((s, c) => s + Number(fin.retained_earnings[c.id] ?? 0), 0) - Number(fin.retained_earnings_elim ?? 0) : Number(fin.retained_earnings[k] ?? 0));
  const val = (a: any, k: string) => Number(k === 'elimination' ? a.elimination : k === 'consolidated' ? a.consolidated : a.by_company[k] ?? 0);
  const profit = (k: string) => sumBy('revenue', k) - sumBy('cogs', k) - sumBy('expense', k);
  const money = (n: number) => (n ? formatRupiah(n) : '—');
  const head = cols.map((k) => (k === 'elimination' ? 'Eliminasi' : k === 'consolidated' ? 'Konsolidasi' : cs.find((c) => c.id === k)?.name));

  const exportXlsx = () => {
    const out: Record<string, string | number>[] = [];
    for (const [t, l] of types) {
      out.push({ Akun: l.toUpperCase() });
      for (const a of rows(t)) out.push({ Kode: a.code, Akun: a.name, ...Object.fromEntries(cols.map((k, i) => [head[i], (k === 'elimination' ? -1 : 1) * val(a, k)])) });
      out.push({ Akun: `Total ${l}`, ...Object.fromEntries(cols.map((k, i) => [head[i], (k === 'elimination' ? -1 : 1) * sumBy(t, k)])) });
    }
    if (kind === 'pl') out.push({ Akun: 'LABA BERSIH', ...Object.fromEntries(cols.map((k, i) => [head[i], k === 'elimination' ? -profit(k) : profit(k)])) });
    else out.push({ Akun: 'Laba ditahan (akumulasi)', ...Object.fromEntries(cols.map((k, i) => [head[i], (k === 'elimination' ? -1 : 1) * re(k)])) });
    downloadXlsx(`${kind === 'pl' ? 'laba-rugi' : 'neraca'}-konsolidasi-${groupName}-${to}`, [{ name: kind === 'pl' ? 'Laba Rugi' : 'Neraca', rows: out, widths: [10, 34, ...cols.map(() => 18)] }]);
  };

  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2>{kind === 'pl' ? `Laba rugi konsolidasi · ${from} s/d ${to}` : `Neraca konsolidasi · per ${to}`}</h2>
        <button className="btn-sm" onClick={exportXlsx}><Download size={14} /> Excel</button>
      </div>
      <table className="table grp-fin">
        <thead><tr><th>Akun</th>{head.map((h, i) => <th key={i} className={`right ${cols[i] === 'consolidated' ? 'grp-cons' : ''}`}>{cols[i] !== 'elimination' && cols[i] !== 'consolidated' && <Building2 size={12} />} {h}</th>)}</tr></thead>
        <tbody>
          {types.map(([t, l]) => (
            <SectionRows key={t} label={l} open={!closed[t]} onToggle={() => setClosed((x) => ({ ...x, [t]: !x[t] }))} rows={rows(t)} cols={cols} val={val} money={money}
              total={(k) => sumBy(t, k)} />
          ))}
          {kind === 'pl' ? (
            <tr className="grp-fin-grand"><td>LABA BERSIH</td>{cols.map((k) => <td key={k} className={`right ${k === 'consolidated' ? 'grp-cons' : ''} ${profit(k) < 0 ? 'text-danger' : ''}`}>{money(k === 'elimination' ? -profit(k) : profit(k))}</td>)}</tr>
          ) : (
            <>
              <tr><td className="small">Laba ditahan (akumulasi laba rugi)</td>{cols.map((k) => <td key={k} className={`right small ${k === 'consolidated' ? 'grp-cons' : ''}`}>{money(k === 'elimination' ? -re(k) : re(k))}</td>)}</tr>
              <tr className="grp-fin-grand"><td>Kewajiban + Ekuitas + Laba ditahan</td>{cols.map((k) => {
                const v = k === 'elimination' ? -(sumBy('liability', k) + sumBy('equity', k) + re(k)) : sumBy('liability', k) + sumBy('equity', k) + re(k);
                return <td key={k} className={`right ${k === 'consolidated' ? 'grp-cons' : ''}`}>{money(v)}</td>;
              })}</tr>
            </>
          )}
        </tbody>
      </table>
      <p className="muted small" style={{ margin: '8px 0 0' }}>
        Digabung per kode akun. Kolom <b>Eliminasi</b> berisi transaksi antar-PT dalam grup (mis. penjualan PT A ke PT B), sehingga konsolidasi hanya menghitung transaksi dengan pihak luar.
        {kind === 'bs' && ' Belum ada jurnal penutup tahunan, jadi laba ditahan = akumulasi laba rugi sejak awal.'}
      </p>
    </div>
  );
}

function SectionRows({ label, open, onToggle, rows, cols, val, money, total }: {
  label: string; open: boolean; onToggle: () => void; rows: any[]; cols: string[]; val: (a: any, k: string) => number; money: (n: number) => string; total: (k: string) => number;
}) {
  return (
    <>
      <tr className="grp-fin-head" onClick={onToggle}><td>{open ? <ChevronDown size={14} /> : <ChevronRight size={14} />} {label}</td>
        {cols.map((k) => <td key={k} className={`right ${k === 'consolidated' ? 'grp-cons' : ''}`}>{money(k === 'elimination' ? -total(k) : total(k))}</td>)}</tr>
      {open && rows.map((a) => (
        <tr key={a.code}><td className="grp-fin-acc"><span className="muted small">{a.code}</span> {a.name}</td>
          {cols.map((k) => <td key={k} className={`right ${k === 'consolidated' ? 'grp-cons' : ''} ${k === 'elimination' && val(a, k) ? 'text-danger' : ''}`}>{money(k === 'elimination' ? -val(a, k) : val(a, k))}</td>)}</tr>
      ))}
    </>
  );
}
