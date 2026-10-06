import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/format';

interface TableRow { id: string; code: string; capacity: number; status: string; qr_token: string }

// Daftar meja + kartu QR untuk dicetak dan ditempel di meja
export default function TableQrList({ companyId, outletId, outletName }: { companyId: string; outletId: string; outletName: string }) {
  const [tables, setTables] = useState<TableRow[]>([]);
  const [images, setImages] = useState<Record<string, string>>({});
  const [code, setCode] = useState('');
  const [capacity, setCapacity] = useState('4');
  const [error, setError] = useState('');

  const urlFor = (token: string) => `${window.location.origin}${import.meta.env.BASE_URL}order/${token}`;

  const load = async () => {
    const rows = (await must(supabase.from('mst_tables').select('id, code, capacity, status, qr_token').eq('outlet_id', outletId).order('code'))) as TableRow[];
    setTables(rows);
    const entries = await Promise.all(rows.map(async (t) => [t.id, await QRCode.toDataURL(urlFor(t.qr_token), { width: 320, margin: 1 })] as const));
    setImages(Object.fromEntries(entries));
  };

  useEffect(() => {
    load().catch((e) => setError(errorMessage(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [outletId]);

  const run = async (fn: () => Promise<unknown>) => {
    setError('');
    try {
      await fn();
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const isLocal = ['localhost', '127.0.0.1'].includes(window.location.hostname);

  return (
    <div className="card">
      <div className="card-header no-print">
        <h2>Meja & QR Order · {outletName}</h2>
        <button className="btn-primary" onClick={() => window.print()} disabled={!tables.length}>🖨️ Cetak Semua QR</button>
      </div>
      {error && <div className="alert alert-error">{error}</div>}
      {isLocal && (
        <div className="alert alert-info small no-print">
          QR ini masih mengarah ke <b>{window.location.origin}</b>, yang hanya bisa dibuka dari komputer ini.
          Supaya bisa di-scan dari HP tamu, aplikasi perlu di-deploy ke internet (mis. Vercel / Netlify), lalu cetak ulang QR dari alamat tersebut.
        </div>
      )}

      <form className="row no-print" style={{ marginBottom: 16 }} onSubmit={(e) => {
        e.preventDefault();
        if (!code.trim()) return;
        run(() => must(supabase.from('mst_tables').insert({ company_id: companyId, outlet_id: outletId, code: code.trim().toUpperCase(), capacity: Number(capacity) || 1 })));
        setCode('');
      }}>
        <input placeholder="Kode meja baru, mis. C1" value={code} onChange={(e) => setCode(e.target.value)} />
        <input type="number" min={1} value={capacity} onChange={(e) => setCapacity(e.target.value)} style={{ width: 80 }} title="Kapasitas" />
        <button>+ Tambah Meja</button>
      </form>

      <div className="qr-cards">
        {tables.map((t) => (
          <div key={t.id} className="qr-card">
            <div className="bold" style={{ fontSize: 20 }}>Meja {t.code}</div>
            <div className="small muted">{outletName}</div>
            {images[t.id] && <img src={images[t.id]} alt={`QR meja ${t.code}`} />}
            <div className="small">Scan untuk lihat menu & pesan</div>
            <div className="row no-print" style={{ justifyContent: 'center', marginTop: 8 }}>
              <a className="btn btn-sm" href={urlFor(t.qr_token)} target="_blank" rel="noreferrer" style={{ textDecoration: 'none' }}>Buka</a>
              <button className="btn-sm" title="Buat QR baru, QR lama tidak berlaku"
                onClick={() => confirm(`Ganti QR meja ${t.code}? QR lama yang sudah tercetak tidak akan berlaku lagi.`) &&
                  run(() => rpc('pos_regenerate_table_qr', { p_table_id: t.id }))}>↻ QR</button>
              <button className="btn-sm" onClick={() => {
                const v = prompt('Kode meja', t.code);
                if (v?.trim()) run(() => must(supabase.from('mst_tables').update({ code: v.trim().toUpperCase() }).eq('id', t.id)));
              }}>Ubah</button>
              <button className="btn-sm btn-danger" onClick={() => confirm(`Hapus meja ${t.code}?`) &&
                run(() => must(supabase.from('mst_tables').delete().eq('id', t.id)))}>Hapus</button>
            </div>
          </div>
        ))}
      </div>
      {!tables.length && <div className="empty">Belum ada meja.</div>}
    </div>
  );
}
