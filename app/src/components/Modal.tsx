import { useEffect, useRef, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { ArrowLeft, X } from 'lucide-react';

interface Props {
  title: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  /** form/tabel besar: tampil sebagai HALAMAN LEBAR di area kerja (bukan pop-up) */
  large?: boolean;
  /** pop-up lebar (untuk kasir yang perlu tetap melihat layar di belakangnya) */
  wide?: boolean;
}

// Dialog kecil: di tengah layar, di HP menjadi "bottom sheet".
// large: halaman lebar di sebelah sidebar dengan tombol kembali & bar aksi di bawah;
//        tombol Back browser/HP juga menutupnya.
// Tutup dengan Esc, tombol X / Kembali (dialog kecil juga dengan klik latar).
export default function Modal({ title, onClose, children, footer, large, wide }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const onCloseRef = useRef(onClose);
  useEffect(() => { onCloseRef.current = onClose; });

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      // hanya dialog / halaman paling atas yang menutup
      const all = document.querySelectorAll('.modal');
      if (all[all.length - 1] === ref.current) onCloseRef.current();
    };
    document.addEventListener('keydown', onKey);
    document.body.classList.add('modal-open');
    // fokus otomatis hanya di perangkat bermouse; di HP keyboard tidak langsung muncul menutupi pilihan
    if (window.matchMedia('(pointer: fine)').matches) {
      ref.current?.querySelector<HTMLElement>('input:not([type=hidden]), select, textarea')?.focus({ preventScroll: true });
    }
    return () => {
      document.removeEventListener('keydown', onKey);
      if (document.querySelectorAll('.modal').length <= 1) document.body.classList.remove('modal-open');
    };
  }, []);

  // halaman lebar: tombol Back browser/HP menutup halaman, bukan meninggalkan aplikasi
  useEffect(() => {
    if (!large) return;
    const key = Math.random().toString(36).slice(2);
    let pushed = false;
    let closedByBack = false;
    const timer = window.setTimeout(() => {   // ditunda: aman untuk efek ganda StrictMode
      window.history.pushState({ ...window.history.state, santapSheet: key }, '');
      pushed = true;
    }, 0);
    const onPop = () => {
      if (pushed && window.history.state?.santapSheet !== key) {
        closedByBack = true;
        onCloseRef.current();
      }
    };
    window.addEventListener('popstate', onPop);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener('popstate', onPop);
      if (pushed && !closedByBack && window.history.state?.santapSheet === key) window.history.back();
    };
  }, [large]);

  if (large) {
    return createPortal(
      <div ref={ref} className="modal page-sheet" role="dialog" aria-modal="true" aria-label={title}>
        <div className="page-sheet-header">
          <button className="icon-btn" onClick={onClose} aria-label="Kembali" title="Kembali (Esc)"><ArrowLeft size={20} /></button>
          <h2>{title}</h2>
          <button className="icon-btn page-sheet-close" onClick={onClose} aria-label="Tutup"><X size={18} /></button>
        </div>
        <div className="page-sheet-body"><div className="page-sheet-content">{children}</div></div>
        {footer && <div className="page-sheet-footer"><div className="page-sheet-content">{footer}</div></div>}
      </div>,
      document.body,
    );
  }

  return createPortal(
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div ref={ref} className={`modal ${wide ? 'modal-lg' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-grabber" aria-hidden />
        <div className="modal-header">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Tutup"><X size={18} /></button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}
