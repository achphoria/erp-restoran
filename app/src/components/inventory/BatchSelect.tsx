import { formatNumber } from '../../lib/format';
import { formatDate, type BatchOption } from './batchUtils';

// Pilih batch untuk satu baris; kosong = otomatis (FEFO lalu FIFO)
export default function BatchSelect({ batches, value, onChange }: { batches: BatchOption[]; value: string; onChange: (id: string) => void }) {
  return (
    <select value={value} style={{ minWidth: 150 }} onChange={(e) => onChange(e.target.value)} title="Batch">
      <option value="">Otomatis (FEFO)</option>
      {batches.map((b) => (
        <option key={b.id} value={b.id}>
          {b.batch_code} · exp {formatDate(b.expiry_date)} · sisa {formatNumber(b.qty_remaining)}
        </option>
      ))}
      {value && !batches.some((b) => b.id === value) && <option value={value}>Batch terpilih (habis)</option>}
    </select>
  );
}
