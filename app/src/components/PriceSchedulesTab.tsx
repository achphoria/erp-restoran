import { useCallback, useEffect, useState } from 'react';
import { CalendarClock, Plus, Trash2 } from 'lucide-react';
import Modal from './Modal';
import MoneyInput from './MoneyInput';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from './Feedback';
import { must, supabase } from '../lib/supabase';
import { errorMessage, formatRupiah, SALES_CHANNELS } from '../lib/format';

const DAYS = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
interface Schedule {
  id: string; name: string; outlet_ids: string[] | null; sales_channels: string[] | null; days_of_week: number[] | null;
  start_time: string | null; end_time: string | null; start_date: string | null; end_date: string | null; is_active: boolean;
  mst_price_schedule_items: { id: string; menu_item_id: string; price: number }[];
}
interface Menu { id: string; code: string; name: string; base_price: number }

// Harga menu berganti otomatis sesuai hari/jam/tanggal/outlet/kanal (mis. harga sarapan, harga weekend)
export default function PriceSchedulesTab({ companyId }: { companyId: string }) {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const [rows, setRows] = useState<Schedule[]>([]);
  const [menus, setMenus] = useState<Menu[]>([]);
  const [editing, setEditing] = useState<Partial<Schedule> | null>(null);

  const load = useCallback(async () => {
    const [s, m] = await Promise.all([
      must(supabase.from('mst_price_schedules').select('*, mst_price_schedule_items(*)').order('is_active', { ascending: false }).order('updated_at', { ascending: false })),
      must(supabase.from('mst_menu_items').select('id, code, name, base_price').eq('is_active', true).order('name')),
    ]);
    setRows(s); setMenus(m);
  }, []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const describe = (s: Schedule) => [
    s.days_of_week?.length ? s.days_of_week.map((d) => DAYS[d - 1]).join(', ') : 'Setiap hari',
    s.start_time || s.end_time ? `${s.start_time?.slice(0, 5) ?? '00:00'}–${s.end_time?.slice(0, 5) ?? '23:59'}` : 'sepanjang hari',
    s.start_date || s.end_date ? `${s.start_date ?? '…'} s/d ${s.end_date ?? '…'}` : null,
    s.sales_channels?.length ? s.sales_channels.map((c) => SALES_CHANNELS[c] ?? c).join('/') : null,
    s.outlet_ids?.length ? s.outlet_ids.map((id) => profile!.outlets.find((o) => o.id === id)?.name).join(', ') : null,
  ].filter(Boolean).join(' · ');

  return (
    <>
      <div className="card">
        <div className="row">
          <button className="btn-primary" onClick={() => setEditing({ is_active: true, mst_price_schedule_items: [] })}><Plus size={16} /> Jadwal Harga</button>
          <span className="muted small">Saat jadwal aktif, harga menu di kasir & QR otomatis berganti. Bila beberapa jadwal bentrok, yang terakhir diubah yang berlaku.</span>
        </div>
      </div>
      <div className="grid grid-2">
        {rows.map((s) => (
          <div key={s.id} className="card" onClick={() => setEditing(s)} style={{ cursor: 'pointer', opacity: s.is_active ? 1 : 0.6 }}>
            <div className="card-header">
              <h3><CalendarClock size={16} style={{ verticalAlign: -3 }} /> {s.name}</h3>
              {s.is_active ? <span className="badge badge-success">Aktif</span> : <span className="badge">Nonaktif</span>}
            </div>
            <div className="muted small" style={{ marginBottom: 8 }}>{describe(s)}</div>
            {s.mst_price_schedule_items.slice(0, 5).map((i) => {
              const m = menus.find((x) => x.id === i.menu_item_id);
              return <div key={i.id} className="sum-row small"><span>{m?.name}</span><span><s className="muted">{formatRupiah(m?.base_price)}</s> {formatRupiah(i.price)}</span></div>;
            })}
            {s.mst_price_schedule_items.length > 5 && <div className="muted small">+{s.mst_price_schedule_items.length - 5} menu lain</div>}
          </div>
        ))}
        {!rows.length && <div className="card empty">Belum ada jadwal harga.</div>}
      </div>
      {editing && <ScheduleForm companyId={companyId} schedule={editing} menus={menus} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); load(); }} />}
    </>
  );
}

function ScheduleForm({ companyId, schedule, menus, onClose, onSaved }: {
  companyId: string; schedule: Partial<Schedule>; menus: Menu[]; onClose: () => void; onSaved: () => void;
}) {
  const { profile } = useAuth();
  const { toast, confirm } = useFeedback();
  const [s, setS] = useState<Partial<Schedule>>(schedule);
  const [prices, setPrices] = useState<Record<string, string>>(() =>
    Object.fromEntries((schedule.mst_price_schedule_items ?? []).map((i) => [i.menu_item_id, String(Number(i.price))])));
  const [search, setSearch] = useState('');
  const toggle = <T,>(key: 'days_of_week' | 'sales_channels' | 'outlet_ids', v: T) => {
    const cur = ((s[key] as T[] | null | undefined) ?? []);
    const next = cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v];
    setS({ ...s, [key]: next.length ? next : null });
  };
  const has = (key: 'days_of_week' | 'sales_channels' | 'outlet_ids', v: unknown) => ((s[key] as unknown[] | null | undefined) ?? []).includes(v);
  const chosen = Object.entries(prices).filter(([, v]) => v !== '');

  const save = async () => {
    try {
      const row = {
        company_id: companyId, name: s.name?.trim(), outlet_ids: s.outlet_ids ?? null, sales_channels: s.sales_channels ?? null,
        days_of_week: s.days_of_week ?? null, start_time: s.start_time || null, end_time: s.end_time || null,
        start_date: s.start_date || null, end_date: s.end_date || null, is_active: !!s.is_active,
      };
      const saved = (await must(s.id ? supabase.from('mst_price_schedules').update(row).eq('id', s.id).select('id').single()
        : supabase.from('mst_price_schedules').insert(row).select('id').single())) as { id: string };
      await must(supabase.from('mst_price_schedule_items').delete().eq('schedule_id', saved.id));
      if (chosen.length) await must(supabase.from('mst_price_schedule_items').insert(chosen.map(([menu_item_id, price]) => ({
        company_id: companyId, schedule_id: saved.id, menu_item_id, price: Number(price) }))));
      toast('Jadwal harga disimpan');
      onSaved();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  const remove = async () => {
    if (!(await confirm({ title: `Hapus jadwal ${s.name}?`, danger: true, confirmLabel: 'Hapus' }))) return;
    await must(supabase.from('mst_price_schedules').delete().eq('id', s.id!)).catch((e) => toast(errorMessage(e), 'error'));
    onSaved();
  };

  const q = search.trim().toLowerCase();
  return (
    <Modal title={s.id ? `Edit ${s.name}` : 'Jadwal Harga Baru'} onClose={onClose} large
      footer={<>
        {s.id && <button className="btn-danger" style={{ marginRight: 'auto' }} onClick={remove}><Trash2 size={16} /> Hapus</button>}
        <button onClick={onClose}>Batal</button>
        <button className="btn-primary" disabled={!s.name?.trim() || !chosen.length} onClick={save}>Simpan</button>
      </>}>
      <div className="form-grid">
        <label className="field" style={{ gridColumn: 'span 2' }}><span>Nama jadwal</span><input value={s.name ?? ''} placeholder="Harga Weekend" onChange={(e) => setS({ ...s, name: e.target.value })} /></label>
        <label className="field"><span>Jam mulai</span><input type="time" value={s.start_time?.slice(0, 5) ?? ''} onChange={(e) => setS({ ...s, start_time: e.target.value || null })} /></label>
        <label className="field"><span>Jam selesai</span><input type="time" value={s.end_time?.slice(0, 5) ?? ''} onChange={(e) => setS({ ...s, end_time: e.target.value || null })} /></label>
        <label className="field"><span>Dari tanggal</span><input type="date" value={s.start_date ?? ''} onChange={(e) => setS({ ...s, start_date: e.target.value || null })} /></label>
        <label className="field"><span>Sampai tanggal</span><input type="date" value={s.end_date ?? ''} onChange={(e) => setS({ ...s, end_date: e.target.value || null })} /></label>
      </div>
      <div className="grid" style={{ marginTop: 12 }}>
        <div><div className="muted small" style={{ marginBottom: 6 }}>Hari (kosong = setiap hari)</div>
          <div className="choice-list">{DAYS.map((d, i) => <button key={d} className={has('days_of_week', i + 1) ? 'active' : ''} onClick={() => toggle('days_of_week', i + 1)}>{d}</button>)}</div></div>
        <div><div className="muted small" style={{ marginBottom: 6 }}>Kanal (kosong = semua)</div>
          <div className="choice-list">{Object.entries(SALES_CHANNELS).map(([k, v]) => <button key={k} className={has('sales_channels', k) ? 'active' : ''} onClick={() => toggle('sales_channels', k)}>{v}</button>)}</div></div>
        {profile!.outlets.length > 1 && (
          <div><div className="muted small" style={{ marginBottom: 6 }}>Outlet (kosong = semua)</div>
            <div className="choice-list">{profile!.outlets.map((o) => <button key={o.id} className={has('outlet_ids', o.id) ? 'active' : ''} onClick={() => toggle('outlet_ids', o.id)}>{o.name}</button>)}</div></div>
        )}
        <label className="switch"><input type="checkbox" checked={!!s.is_active} onChange={(e) => setS({ ...s, is_active: e.target.checked })} /><span>Aktif</span></label>
      </div>
      <div className="section-title">Harga menu ({chosen.length} dipilih)</div>
      <input type="search" placeholder="Cari menu…" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: '100%', marginBottom: 8 }} />
      <div className="table-wrap" style={{ maxHeight: 320, overflowY: 'auto' }}>
        <table className="table">
          <thead><tr><th>Menu</th><th className="right">Harga normal</th><th>Harga di jadwal (kosong = tidak berubah)</th></tr></thead>
          <tbody>
            {menus.filter((m) => !q || m.name.toLowerCase().includes(q) || m.code.toLowerCase().includes(q)).map((m) => (
              <tr key={m.id}>
                <td>{m.name}</td>
                <td className="right muted">{formatRupiah(m.base_price)}</td>
                <td><MoneyInput value={prices[m.id] ?? ''} onChange={(v) => setPrices({ ...prices, [m.id]: v })} style={{ width: 140 }} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}
