import { CheckCircle2 } from 'lucide-react';
import Logo from '../components/Logo';

// Halaman tujuan setelah pelanggan selesai di halaman iPay88 (ResponseURL).
// Status lunas ditentukan oleh callback server, bukan oleh halaman ini.
export default function PaymentReturnPage() {
  return (
    <div className="auth-page">
      <div className="auth-card" style={{ textAlign: 'center' }}>
        <Logo size={48} />
        <CheckCircle2 size={56} style={{ color: 'var(--fresh)', margin: '20px auto 8px', display: 'block' }} />
        <h1>Pembayaran diproses</h1>
        <p className="muted">Terima kasih! Status pembayaran akan otomatis muncul di layar kasir. Jendela ini boleh ditutup.</p>
        <button className="btn-primary btn-block" onClick={() => window.close()}>Tutup</button>
      </div>
    </div>
  );
}
