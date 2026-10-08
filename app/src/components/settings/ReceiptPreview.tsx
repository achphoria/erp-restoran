import { useEffect, useState } from 'react';
import { Printer } from 'lucide-react';
import Modal from '../Modal';
import { useAuth } from '../../context/AuthContext';
import { buildReceiptHtml, printHtml, sampleReceipt } from '../../lib/receipt';

/* eslint-disable @typescript-eslint/no-explicit-any */
// Pratinjau struk 80mm dengan pengaturan outlet yang sedang diedit (contoh pesanan)
export default function ReceiptPreview({ outlet, brand, onClose }: { outlet: any; brand: { name?: string; logo_url?: string | null } | null; onClose: () => void }) {
  const { profile } = useAuth();
  const [html, setHtml] = useState('');
  useEffect(() => {
    const b = { name: brand?.name, logo_url: brand?.logo_url || profile?.company_logo_url || null };
    buildReceiptHtml(sampleReceipt(outlet, b, { name: profile?.company_name })).then(setHtml);
  }, [outlet, brand, profile]);
  return (
    <Modal title="Pratinjau struk 80mm" onClose={onClose}
      footer={<><button onClick={onClose}>Tutup</button><button className="btn-primary" disabled={!html} onClick={() => printHtml(html)}><Printer size={15} /> Uji cetak</button></>}>
      <div className="receipt-preview">{html && <iframe title="Pratinjau struk" srcDoc={html} />}</div>
      <p className="muted small">Contoh pesanan. Di printer thermal, logo dicetak hitam-putih; pakai logo dengan latar putih/transparan supaya tajam.</p>
    </Modal>
  );
}
