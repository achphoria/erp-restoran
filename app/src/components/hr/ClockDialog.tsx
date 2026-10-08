import { useCallback, useEffect, useRef, useState } from 'react';
import { Camera, LocateFixed, MapPin, RefreshCw, TriangleAlert } from 'lucide-react';
import Modal from '../Modal';
import { rpc } from '../../lib/supabase';
import { errorMessage } from '../../lib/format';
import { distanceM, getGps, uploadAttendancePhoto, type GpsFix } from '../../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
interface Props {
  kind: 'in' | 'out';
  companyId: string;
  today: any;                 // hasil hr_attendance_today()
  onClose: () => void;
  onDone: (att: any) => void;
}

// Absen dengan selfie (kamera depan langsung, bukan galeri) + lokasi GPS.
// Jam & jarak resmi dihitung di server; angka di sini hanya perkiraan untuk karyawan.
export default function ClockDialog({ kind, companyId, today, onClose, onDone }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [camError, setCamError] = useState('');
  const [photo, setPhoto] = useState<{ blob: Blob; url: string } | null>(null);
  const [gps, setGps] = useState<GpsFix | null>(null);
  const [gpsError, setGpsError] = useState('');
  const [locating, setLocating] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [now, setNow] = useState(() => new Date());
  const settings = today?.settings ?? {};
  const sched = today?.schedule ?? {};

  const stopCamera = () => { streamRef.current?.getTracks().forEach((t) => t.stop()); streamRef.current = null; };
  const startCamera = useCallback(async () => {
    setCamError('');
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('unsupported');
      const s = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 720 }, height: { ideal: 960 } }, audio: false });
      streamRef.current = s;
      if (videoRef.current) { videoRef.current.srcObject = s; await videoRef.current.play().catch(() => undefined); }
    } catch (e) {
      const name = (e as Error)?.name;
      setCamError(name === 'NotAllowedError' ? 'Izin kamera ditolak. Aktifkan izin kamera untuk situs ini, atau pakai tombol kamera di bawah.'
        : 'Kamera tidak bisa dibuka di browser ini. Pakai tombol kamera di bawah.');
    }
  }, []);
  const locate = useCallback(async () => {
    setLocating(true);
    setGpsError('');
    try { setGps(await getGps()); } catch (e) { setGpsError(errorMessage(e)); } finally { setLocating(false); }
  }, []);

  useEffect(() => {
    startCamera();
    locate();
    const t = window.setInterval(() => setNow(new Date()), 1000);
    return () => { window.clearInterval(t); stopCamera(); };
  }, [startCamera, locate]);
  useEffect(() => () => { if (photo) URL.revokeObjectURL(photo.url); }, [photo]);

  // foto + cap waktu & lokasi sebagai bukti
  const stamp = (canvas: HTMLCanvasElement) => {
    const ctx = canvas.getContext('2d')!;
    const h = Math.round(canvas.height * 0.09);
    ctx.fillStyle = 'rgba(0,0,0,.55)';
    ctx.fillRect(0, canvas.height - h, canvas.width, h);
    ctx.fillStyle = '#fff';
    ctx.font = `600 ${Math.round(h * 0.36)}px system-ui, sans-serif`;
    const when = new Date().toLocaleString('id-ID', { timeZone: 'Asia/Jakarta', dateStyle: 'medium', timeStyle: 'short' });
    ctx.fillText(`${kind === 'in' ? 'MASUK' : 'PULANG'} · ${when}`, h * 0.3, canvas.height - h * 0.55);
    ctx.font = `${Math.round(h * 0.28)}px system-ui, sans-serif`;
    ctx.fillText(gps ? `${gps.lat.toFixed(5)}, ${gps.lng.toFixed(5)} ±${gps.accuracy}m · SEMAR` : 'SEMAR', h * 0.3, canvas.height - h * 0.18);
  };
  const toBlob = (canvas: HTMLCanvasElement) => new Promise<Blob>((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error('Gagal mengambil foto'))), 'image/jpeg', 0.82));
  const capture = async () => {
    const v = videoRef.current;
    if (!v || !v.videoWidth) return;
    const scale = Math.min(1, 720 / v.videoWidth);
    const c = document.createElement('canvas');
    c.width = Math.round(v.videoWidth * scale);
    c.height = Math.round(v.videoHeight * scale);
    const ctx = c.getContext('2d')!;
    ctx.translate(c.width, 0);      // simpan seperti yang terlihat di layar (cermin)
    ctx.scale(-1, 1);
    ctx.drawImage(v, 0, 0, c.width, c.height);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    stamp(c);
    const blob = await toBlob(c);
    setPhoto({ blob, url: URL.createObjectURL(blob) });
  };
  // cadangan untuk browser tanpa getUserMedia: input kamera (capture=user langsung membuka kamera depan di HP)
  const fromInput = async (f: File | undefined) => {
    if (!f) return;
    const img = await createImageBitmap(f);
    const scale = Math.min(1, 720 / img.width);
    const c = document.createElement('canvas');
    c.width = Math.round(img.width * scale);
    c.height = Math.round(img.height * scale);
    c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
    stamp(c);
    const blob = await toBlob(c);
    setPhoto({ blob, url: URL.createObjectURL(blob) });
  };

  const hasGeo = sched.geo_lat != null && sched.geo_lng != null;
  const dist = gps && hasGeo ? distanceM(gps.lat, gps.lng, Number(sched.geo_lat), Number(sched.geo_lng)) : null;
  const outside = dist != null && dist > Number(sched.geo_radius_m ?? 100);
  const needPhoto = settings.require_photo !== false;
  const needGps = settings.require_gps !== false;
  const ready = (!needPhoto || !!photo) && (!needGps || !!gps) && !busy;

  const submit = async () => {
    setBusy(true);
    setError('');
    try {
      const path = photo ? await uploadAttendancePhoto(companyId, today.employee_id, today.work_date, kind, photo.blob) : null;
      const att = await rpc<any>('hr_clock', { p_kind: kind, p_lat: gps?.lat ?? null, p_lng: gps?.lng ?? null, p_accuracy: gps?.accuracy ?? null, p_photo: path });
      stopCamera();
      onDone(att);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal title={kind === 'in' ? 'Absen Masuk' : 'Absen Pulang'} onClose={() => { stopCamera(); onClose(); }}
      footer={<>
        <button onClick={() => { stopCamera(); onClose(); }}>Batal</button>
        <button className="btn-primary" disabled={!ready} onClick={submit}>{busy ? 'Mengirim…' : kind === 'in' ? 'Kirim absen masuk' : 'Kirim absen pulang'}</button>
      </>}>
      <div className="clock-box">
        <div className="clock-now">
          <b>{now.toLocaleTimeString('id-ID', { timeZone: 'Asia/Jakarta', hour: '2-digit', minute: '2-digit', second: '2-digit' })}</b>
          <span className="muted small">{now.toLocaleDateString('id-ID', { timeZone: 'Asia/Jakarta', weekday: 'long', day: 'numeric', month: 'long' })}
            {sched.shift ? ` · Shift ${sched.shift} ${String(sched.start_time).slice(0, 5)}–${String(sched.end_time).slice(0, 5)}` : ''}</span>
        </div>

        <div className="clock-cam">
          {photo && <img src={photo.url} alt="Selfie" />}
          <video ref={videoRef} playsInline muted autoPlay hidden={!!photo || !!camError} />
          {!photo && !camError && <div className="clock-guide" aria-hidden />}
          {camError && !photo && <div className="clock-cam-error"><Camera size={28} /><p>{camError}</p></div>}
        </div>
        <div className="clock-cam-actions">
          {photo
            ? <button onClick={() => setPhoto(null)}><RefreshCw size={15} /> Ulangi foto</button>
            : camError
              ? <>
                  <button className="btn-primary" onClick={() => fileRef.current?.click()}><Camera size={15} /> Buka kamera</button>
                  <input ref={fileRef} type="file" accept="image/*" capture="user" hidden onChange={(e) => fromInput(e.target.files?.[0])} />
                </>
              : <button className="btn-primary clock-shutter" onClick={capture}><Camera size={16} /> Ambil foto</button>}
        </div>

        <div className={`clock-gps ${outside ? 'warn' : gps ? 'ok' : ''}`}>
          <MapPin size={16} />
          <div>
            {locating && <span>Mencari lokasi GPS…</span>}
            {!locating && gpsError && <span className="text-danger">{gpsError}</span>}
            {!locating && gps && (
              <>
                <b>{hasGeo ? (dist! <= Number(sched.geo_radius_m ?? 100) ? `Di area ${sched.outlet}` : `${dist! >= 1000 ? (dist! / 1000).toFixed(1) + ' km' : dist + ' m'} dari ${sched.outlet}`) : 'Lokasi didapat'}</b>
                <small className="muted"> · akurasi ±{gps.accuracy} m{hasGeo ? ` · radius ${sched.geo_radius_m} m` : ''}</small>
                {outside && <div className="small"><TriangleAlert size={13} style={{ verticalAlign: -2 }} /> Di luar radius outlet. Absen tetap tercatat, tapi akan direview atasan / HR.</div>}
                {!hasGeo && <div className="small muted">Titik lokasi outlet belum diatur, jarak tidak bisa dicek.</div>}
              </>
            )}
          </div>
          <button className="btn-sm" onClick={locate} disabled={locating} title="Perbarui lokasi"><LocateFixed size={14} /></button>
        </div>
        {error && <div className="alert alert-error small">{error}</div>}
      </div>
    </Modal>
  );
}
