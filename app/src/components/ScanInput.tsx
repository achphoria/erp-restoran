import { useEffect, useRef, useState } from 'react';
import { Camera, ScanLine } from 'lucide-react';
import Modal from './Modal';

// Input scan: scanner USB/Bluetooth (mengetik + Enter) atau kamera HP
export default function ScanInput({ onScan, placeholder = 'Scan / ketik barcode lalu Enter', autoFocus, style }: {
  onScan: (code: string) => void; placeholder?: string; autoFocus?: boolean; style?: React.CSSProperties;
}) {
  const [value, setValue] = useState('');
  const [camera, setCamera] = useState(false);

  const submit = (code: string) => {
    const c = code.trim();
    if (c) onScan(c);
    setValue('');
  };

  return (
    <div className="scan-input" style={style}>
      <ScanLine size={16} className="scan-input-icon" />
      <input value={value} placeholder={placeholder} autoFocus={autoFocus} autoComplete="off" enterKeyHint="search"
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); submit(value); } }} />
      <button type="button" className="btn-sm" title="Scan pakai kamera" onClick={() => setCamera(true)}><Camera size={16} /></button>
      {camera && <CameraScanner onClose={() => setCamera(false)} onDetected={(c) => { setCamera(false); submit(c); }} />}
    </div>
  );
}

interface Detector { detect: (source: HTMLVideoElement) => Promise<{ rawValue: string }[]> }

const FORMATS = ['code_128', 'ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_39', 'qr_code', 'data_matrix', 'itf'];

async function createDetector(): Promise<Detector> {
  const Native = (window as unknown as { BarcodeDetector?: new (o: { formats: string[] }) => Detector }).BarcodeDetector;
  if (Native) return new Native({ formats: FORMATS });
  const { BarcodeDetector } = await import('barcode-detector/ponyfill');
  return new BarcodeDetector({ formats: FORMATS as never }) as unknown as Detector;
}

function CameraScanner({ onClose, onDetected }: { onClose: () => void; onDetected: (code: string) => void }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState('');
  const detected = useRef(onDetected);
  useEffect(() => { detected.current = onDetected; });

  useEffect(() => {
    let stream: MediaStream | null = null;
    let timer = 0;
    let stopped = false;
    (async () => {
      try {
        if (!navigator.mediaDevices?.getUserMedia) throw new Error('Browser ini tidak mendukung kamera. Pakai scanner atau ketik kodenya.');
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
        if (stopped) return;
        const video = videoRef.current!;
        video.srcObject = stream;
        await video.play();
        const detector = await createDetector();
        const tick = async () => {
          if (stopped) return;
          try {
            if (video.readyState >= 2) {
              const found = await detector.detect(video);
              if (found[0]?.rawValue) {
                navigator.vibrate?.(80);
                detected.current(found[0].rawValue);
                return;
              }
            }
          } catch { /* frame berikutnya */ }
          timer = window.setTimeout(tick, 200);
        };
        tick();
      } catch (e) {
        setError(e instanceof Error && e.name === 'NotAllowedError'
          ? 'Izin kamera ditolak. Izinkan kamera di pengaturan browser.'
          : e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  return (
    <Modal title="Scan Barcode" onClose={onClose} footer={<button onClick={onClose}>Tutup</button>}>
      {error ? <div className="alert alert-error">{error}</div> : (
        <div className="camera-box">
          <video ref={videoRef} playsInline muted />
          <div className="camera-aim" />
        </div>
      )}
      <p className="muted small" style={{ textAlign: 'center' }}>Arahkan kamera ke barcode / label batch / label koli.</p>
    </Modal>
  );
}
