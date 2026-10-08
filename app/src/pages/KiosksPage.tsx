import { useCallback, useEffect, useMemo, useState } from 'react';
import QRCode from 'qrcode';
import { Copy, ExternalLink, MonitorSmartphone, Plus, RefreshCw, Search, Sparkles } from 'lucide-react';
import Modal from '../components/Modal';
import { useFeedback } from '../components/Feedback';
import { useAuth } from '../context/AuthContext';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';

/* eslint-disable @typescript-eslint/no-explicit-any */
const kioskUrl = (token: string) => `${window.location.origin}${import.meta.env.BASE_URL}kiosk/${token}`;

// Self-order kiosk: perangkat per outlet + menu unggulan yang tampil di layar sambutan & rekomendasi
export default function KiosksPage() {
  const { profile } = useAuth();
  const { toast, confirm } = useFeedback();
  const [tab, setTab] = useTabParam<'devices' | 'menu'>('devices', ['devices', 'menu']);
  const [list, setList] = useState<any[]>([]);
  const [outlets, setOutlets] = useState<{ id: string; name: string }[]>([]);
  const [edit, setEdit] = useState<any | null>(null);
  const [show, setShow] = useState<any | null>(null);

  const load = useCallback(async () => setList(await rpc<any[]>('pos_kiosk_list')), []);
  useEffect(() => {
    load().catch((e) => toast(errorMessage(e), 'error'));
    must(supabase.from('sys_outlets').select('id, name').eq('is_active', true).order('name')).then(setOutlets).catch(() => undefined);
  }, [load, toast]);

  const save = async () => {
    try {
      const v = { name: edit.name?.trim(), outlet_id: edit.outlet_id, is_active: edit.is_active !== false, allow_dine_in: !!edit.allow_dine_in, allow_takeaway: !!edit.allow_takeaway,
        welcome_title: edit.welcome_title, welcome_subtitle: edit.welcome_subtitle, idle_seconds: Number(edit.idle_seconds), print_receipt: !!edit.print_receipt, updated_at: new Date().toISOString() };
      if (!v.name || !v.outlet_id) throw new Error('Nama & outlet wajib diisi');
      if (!v.allow_dine_in && !v.allow_takeaway) throw new Error('Aktifkan minimal satu: makan di sini / bawa pulang');
      if (edit.id) await must(supabase.from('pos_kiosks').update(v).eq('id', edit.id));
      else await must(supabase.from('pos_kiosks').insert({ ...v, company_id: profile!.company_id }));
      setEdit(null);
      load();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const regen = async (k: any) => {
    if (!(await confirm({ title: 'Ganti link kiosk?', message: 'Link lama langsung tidak berlaku. Buka link baru di layar kiosk.', danger: true, confirmLabel: 'Ganti link' }))) return;
    try { await rpc('pos_kiosk_regenerate_token', { p_id: k.id }); toast('Link baru dibuat', 'success'); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };

  return (
    <>
      <div className="page-header">
        <div><h1>Self Kiosk</h1><p>Layar sentuh berdiri untuk pelanggan memesan sendiri, lalu bayar di kasir.</p></div>
        {tab === 'devices' && <button className="btn-primary" onClick={() => setEdit({ name: `Kiosk ${list.length + 1}`, outlet_id: outlets[0]?.id ?? '', allow_dine_in: true, allow_takeaway: true, print_receipt: true,
          idle_seconds: 90, welcome_title: 'Pesan sendiri, lebih cepat', welcome_subtitle: 'Sentuh layar untuk mulai', is_active: true })}><Plus size={16} /> Kiosk baru</button>}
      </div>
      <div className="tabs">
        <button className={tab === 'devices' ? 'active' : ''} onClick={() => setTab('devices')}>Perangkat</button>
        <button className={tab === 'menu' ? 'active' : ''} onClick={() => setTab('menu')}>Menu unggulan</button>
      </div>

      {tab === 'devices' && (
        <>
          <div className="kiosk-cards">
            {list.map((k) => (
              <div key={k.id} className={`card kiosk-card ${k.is_active ? '' : 'off'}`}>
                <div className="kiosk-card-head">
                  <MonitorSmartphone size={22} />
                  <div><b>{k.name}</b><div className="muted small">{k.outlet}</div></div>
                  <span className={`badge ${k.online ? 'badge-success' : ''}`}>{!k.is_active ? 'Nonaktif' : k.online ? 'Online' : 'Offline'}</span>
                </div>
                <div className="small muted">Terakhir aktif: {k.last_seen_at ? formatDateTime(k.last_seen_at) : 'belum pernah'} · {k.orders_today} pesanan hari ini</div>
                <div className="small">{[k.allow_dine_in && 'Makan di sini', k.allow_takeaway && 'Bawa pulang'].filter(Boolean).join(' · ')}{k.print_receipt ? ' · cetak struk' : ''}</div>
                <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
                  <button className="btn-sm btn-primary" onClick={() => setShow(k)}><ExternalLink size={13} /> Pasang di layar</button>
                  <button className="btn-sm" onClick={() => setEdit(k)}>Atur</button>
                  <button className="btn-sm" onClick={() => regen(k)}><RefreshCw size={13} /> Ganti link</button>
                </div>
              </div>
            ))}
            {!list.length && <div className="card empty">Belum ada kiosk. Klik <b>Kiosk baru</b>, lalu buka link-nya di TV / tablet layar sentuh.</div>}
          </div>
          <div className="card small">
            <b>Tips pemasangan</b>
            <ul style={{ margin: '6px 0 0', paddingLeft: 18 }}>
              <li>Pakai layar sentuh <b>portrait</b> (berdiri), mis. 1080×1920. Tampilan menyesuaikan otomatis.</li>
              <li>Jalankan Chrome mode kiosk agar layar penuh & struk langsung tercetak tanpa dialog: <code>chrome --kiosk --kiosk-printing "LINK_KIOSK"</code>, dan jadikan printer thermal 80mm sebagai printer default.</li>
              <li>Pesanan masuk ke <b>Daftar Order</b> dengan label <b>Kiosk + nomor antrean</b>. Dapur baru menerima pesanan setelah dibayar di kasir.</li>
              <li>Atur foto menu yang menarik & menu unggulan di tab <b>Menu unggulan</b>. Menu <b>Terlaris</b> dihitung otomatis dari penjualan 30 hari.</li>
            </ul>
          </div>
        </>
      )}

      {tab === 'menu' && <Highlights />}

      {show && <InstallModal kiosk={show} onClose={() => setShow(null)} />}
      {edit && (
        <Modal title={edit.id ? `Atur ${edit.name}` : 'Kiosk baru'} onClose={() => setEdit(null)}
          footer={<><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field"><span>Nama</span><input value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
            <label className="field"><span>Outlet</span>
              <select value={edit.outlet_id} disabled={!!edit.id} onChange={(e) => setEdit({ ...edit, outlet_id: e.target.value })}>{outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Judul sambutan</span><input value={edit.welcome_title} onChange={(e) => setEdit({ ...edit, welcome_title: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Teks kecil</span><input value={edit.welcome_subtitle} onChange={(e) => setEdit({ ...edit, welcome_subtitle: e.target.value })} /></label>
            <label className="field"><span>Reset bila tidak disentuh (detik)</span><input type="number" min={30} max={600} value={edit.idle_seconds} onChange={(e) => setEdit({ ...edit, idle_seconds: e.target.value })} /></label>
          </div>
          <div className="grid" style={{ marginTop: 10 }}>
            <label className="row"><input type="checkbox" checked={!!edit.allow_dine_in} onChange={(e) => setEdit({ ...edit, allow_dine_in: e.target.checked })} /> Makan di sini</label>
            <label className="row"><input type="checkbox" checked={!!edit.allow_takeaway} onChange={(e) => setEdit({ ...edit, allow_takeaway: e.target.checked })} /> Bawa pulang (harga takeaway dipakai bila ada)</label>
            <label className="row"><input type="checkbox" checked={!!edit.print_receipt} onChange={(e) => setEdit({ ...edit, print_receipt: e.target.checked })} /> Cetak struk nomor antrean</label>
            {edit.id && <label className="row"><input type="checkbox" checked={edit.is_active !== false} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} /> Aktif</label>}
          </div>
        </Modal>
      )}
    </>
  );
}

function InstallModal({ kiosk, onClose }: { kiosk: any; onClose: () => void }) {
  const { toast } = useFeedback();
  const url = kioskUrl(kiosk.token);
  const [qr, setQr] = useState('');
  useEffect(() => { QRCode.toDataURL(url, { width: 360, margin: 1 }).then(setQr); }, [url]);
  return (
    <Modal title={`Pasang ${kiosk.name}`} onClose={onClose} footer={<><button onClick={onClose}>Tutup</button><a className="btn btn-primary" href={url} target="_blank" rel="noreferrer" style={{ textDecoration: 'none' }}><ExternalLink size={14} /> Buka kiosk</a></>}>
      <p style={{ marginTop: 0 }}>Buka link ini di browser layar kiosk (atau pindai QR dari perangkatnya). Simpan sebagai halaman awal.</p>
      <div className="kiosk-link"><code>{url}</code><button className="btn-sm" onClick={() => { navigator.clipboard?.writeText(url); toast('Link disalin', 'info'); }}><Copy size={13} /> Salin</button></div>
      {qr && <img src={qr} alt="QR link kiosk" style={{ display: 'block', margin: '12px auto', width: 220 }} />}
      <p className="muted small">Link ini rahasia: siapa pun yang memegangnya bisa membuat pesanan (tetap harus bayar di kasir). Bila bocor, klik <b>Ganti link</b>.</p>
    </Modal>
  );
}

function Highlights() {
  const { toast } = useFeedback();
  const [items, setItems] = useState<any[]>([]);
  const [q, setQ] = useState('');
  const load = useCallback(async () => setItems(await must(supabase.from('mst_menu_items').select('id, name, image_url, kiosk_featured, kiosk_badge, is_active, mst_menu_categories(name)').eq('is_active', true).order('name'))), []);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);
  const shown = useMemo(() => items.filter((i) => !q || i.name.toLowerCase().includes(q.toLowerCase())), [items, q]);
  const set = async (i: any, featured: boolean, badge: string | null) => {
    setItems((xs) => xs.map((x) => (x.id === i.id ? { ...x, kiosk_featured: featured, kiosk_badge: badge } : x)));
    try { await rpc('pos_kiosk_set_highlight', { p_item_id: i.id, p_featured: featured, p_badge: badge }); } catch (e) { toast(errorMessage(e), 'error'); load(); }
  };
  return (
    <div className="card table-wrap">
      <div className="card-header">
        <h2><Sparkles size={18} style={{ verticalAlign: -3, color: 'var(--sunshine, #F7B733)' }} /> Menu unggulan</h2>
        <label className="task-search"><Search size={14} /><input value={q} placeholder="Cari menu" onChange={(e) => setQ(e.target.value)} /></label>
      </div>
      <p className="muted small" style={{ marginTop: 0 }}>Menu unggulan tampil besar di layar sambutan & baris <b>Rekomendasi</b>. Label (mis. Baru, Promo, Pedas) tampil di kartu menu. Menu tanpa foto kurang menarik di kiosk.</p>
      <table className="table">
        <thead><tr><th>Menu</th><th>Kategori</th><th className="center">Unggulan</th><th>Label</th></tr></thead>
        <tbody>
          {shown.map((i) => (
            <tr key={i.id}>
              <td><div className="row" style={{ flexWrap: 'nowrap' }}>{i.image_url ? <img src={i.image_url} alt="" className="kiosk-thumb" /> : <span className="kiosk-thumb empty">tanpa foto</span>}<b>{i.name}</b></div></td>
              <td className="small">{i.mst_menu_categories?.name ?? '—'}</td>
              <td className="center"><input type="checkbox" checked={!!i.kiosk_featured} onChange={(e) => set(i, e.target.checked, i.kiosk_badge)} aria-label={`Unggulan ${i.name}`} /></td>
              <td><input className="kiosk-badge-input" defaultValue={i.kiosk_badge ?? ''} maxLength={16} placeholder="—" onBlur={(e) => { const v = e.target.value.trim() || null; if (v !== (i.kiosk_badge ?? null)) set(i, !!i.kiosk_featured, v); }} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
