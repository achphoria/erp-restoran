import { useNavigate } from 'react-router-dom';
import { Wrench } from 'lucide-react';
import ScanInput from '../ScanInput';
import { parseAssetCode } from '../../lib/assets';

// Kartu di Beranda Saya: scan label QR aset (kamera HP / scanner) lalu lapor kerusakan
export default function ReportAssetCard() {
  const navigate = useNavigate();
  return (
    <div className="card">
      <div className="me-card-title"><Wrench size={16} /> Lapor kerusakan aset</div>
      <p className="small muted" style={{ margin: '0 0 8px' }}>Kompor, AC, kulkas, mesin kasir rusak? Scan label QR yang tertempel di aset, atau ketik kodenya.</p>
      <ScanInput onScan={(c) => navigate(`/aset/${encodeURIComponent(parseAssetCode(c))}`)} placeholder="Scan QR / kode aset (AST-…)" />
    </div>
  );
}
