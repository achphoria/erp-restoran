import { useEffect, useRef, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';

interface Props {
  title: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  large?: boolean;
}

// Dialog: di layar besar muncul di tengah, di HP menjadi "bottom sheet" dari bawah.
// Tutup dengan Esc, klik latar, atau tombol X.
export default function Modal({ title, onClose, children, footer, large }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      // hanya dialog paling atas yang menutup
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

  return createPortal(
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div ref={ref} className={`modal ${large ? 'modal-lg' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
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
