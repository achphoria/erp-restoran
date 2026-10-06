import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { useNotice } from '../components/Feedback';
import { errorMessage, formatDateTime, formatRupiah } from '../lib/format';
import type { Shift } from '../lib/types';
import MoneyInput from '../components/MoneyInput';

export default function ShiftsPage() {
  const { outlet, session } = useAuth();
  const [shifts, setShifts] = useState<Shift[]>([]);
  const [openingCash, setOpeningCash] = useState('');
  const [closingCash, setClosingCash] = useState('');
  const [error, setError] = useState('');
  const setNotice = useNotice();
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!outlet) return;
    try {
      setShifts((await must(
        supabase.from('pos_shifts').select('*').eq('outlet_id', outlet.id).eq('user_id', session!.user.id)
          .order('opened_at', { ascending: false }).limit(20),
      )) as Shift[]);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [outlet, session]);

  useEffect(() => {
    load();
  }, [load]);

  const openShift = shifts.find((s) => s.status === 'open');

  const run = async (fn: () => Promise<string>) => {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      setNotice(await fn());
      await load();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="page-header">
        <div>
          <h1>Shift Kasir</h1>
          <p>Buka shift sebelum menerima pembayaran, tutup shift di akhir untuk setoran kas.</p>
        </div>
      </div>
      {error && <div className="alert alert-error">{error}</div>}

      <div className="card">
        {openShift ? (
          <div className="grid grid-2">
            <div>
              <span className="badge badge-success">Shift terbuka</span>
              <p>Dibuka {formatDateTime(openShift.opened_at)}<br />Modal awal: <b>{formatRupiah(openShift.opening_cash)}</b></p>
            </div>
            <div className="grid">
              <label className="field">
                <span>Uang tunai di laci saat tutup (hitung fisik)</span>
                <MoneyInput value={closingCash} onChange={(v) => setClosingCash(v)} />
              </label>
              <button className="btn-primary" disabled={busy || closingCash === ''}
                onClick={() => run(async () => {
                  const r = await rpc<{ expected_cash: number; difference: number }>('pos_close_shift', {
                    p_shift_id: openShift.id, p_closing_cash: Number(closingCash),
                  });
                  setClosingCash('');
                  const diff = Number(r.difference);
                  return `Shift ditutup. Kas seharusnya ${formatRupiah(r.expected_cash)}, ` +
                    (diff === 0 ? 'kas PAS ✅' : `selisih ${formatRupiah(diff)} ${diff < 0 ? '(kurang)' : '(lebih)'}`);
                })}>
                Tutup Shift
              </button>
            </div>
          </div>
        ) : (
          <div className="row">
            <label className="field" style={{ flex: 1 }}>
              <span>Modal awal kas (Rp)</span>
              <MoneyInput value={openingCash} onChange={(v) => setOpeningCash(v)} placeholder="500000" />
            </label>
            <button className="btn-primary" style={{ alignSelf: 'end' }} disabled={busy}
              onClick={() => run(async () => {
                await rpc('pos_open_shift', { p_outlet_id: outlet!.id, p_opening_cash: Number(openingCash || 0) });
                setOpeningCash('');
                return 'Shift dibuka. Selamat bekerja!';
              })}>
              Buka Shift
            </button>
          </div>
        )}
      </div>

      <div className="card table-wrap">
        <h2 style={{ marginBottom: 12 }}>Riwayat Shift</h2>
        <table className="table">
          <thead>
            <tr><th>Dibuka</th><th>Ditutup</th><th className="right">Modal</th><th className="right">Seharusnya</th><th className="right">Aktual</th><th className="right">Selisih</th></tr>
          </thead>
          <tbody>
            {shifts.map((s) => {
              const diff = s.closing_cash !== null && s.expected_cash !== null ? Number(s.closing_cash) - Number(s.expected_cash) : null;
              return (
                <tr key={s.id}>
                  <td>{formatDateTime(s.opened_at)}</td>
                  <td>{s.closed_at ? formatDateTime(s.closed_at) : <span className="badge badge-success">Terbuka</span>}</td>
                  <td className="right">{formatRupiah(s.opening_cash)}</td>
                  <td className="right">{s.expected_cash !== null ? formatRupiah(s.expected_cash) : '-'}</td>
                  <td className="right">{s.closing_cash !== null ? formatRupiah(s.closing_cash) : '-'}</td>
                  <td className="right" style={{ color: diff ? 'var(--danger)' : undefined }}>{diff !== null ? formatRupiah(diff) : '-'}</td>
                </tr>
              );
            })}
            {!shifts.length && <tr><td colSpan={6} className="empty">Belum ada shift.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
