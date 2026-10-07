import { useMemo, useState } from 'react';
import { Printer } from 'lucide-react';
import Modal from '../Modal';
import { useFeedback } from '../Feedback';
import { barcodeSvg, getLabelSizeKey, LABEL_SIZES, printLabels, setLabelSizeKey, type LabelData } from '../../lib/barcode';
import { errorMessage } from '../../lib/format';

// Pilih ukuran stiker & jumlah salinan, lalu cetak ke printer label thermal
export default function LabelPrintModal({ labels, kind = 'batch', title = 'Cetak Label', defaultCopies = 1, defaultSize, onClose }: {
  labels: LabelData[]; kind?: 'batch' | 'koli'; title?: string; defaultCopies?: number; defaultSize?: string; onClose: () => void;
}) {
  const { toast } = useFeedback();
  const [sizeKey, setSizeKey] = useState(getLabelSizeKey(kind, defaultSize));
  const [copies, setCopies] = useState(defaultCopies);
  const size = (LABEL_SIZES.find((s) => s.key === sizeKey) ?? LABEL_SIZES[0]).size;
  const first = labels[0];
  const preview = useMemo(() => (first ? barcodeSvg(first.code) : ''), [first]);

  const print = () => {
    try {
      setLabelSizeKey(kind, sizeKey);
      printLabels(labels.flatMap((l) => Array.from({ length: Math.max(1, copies) }, () => l)), size);
      onClose();
    } catch (e) {
      toast(errorMessage(e), 'error');
    }
  };

  return (
    <Modal title={title} onClose={onClose}
      footer={<><button onClick={onClose}>Batal</button><button className="btn-primary" disabled={!labels.length} onClick={print}><Printer size={16} /> Cetak {labels.length * Math.max(1, copies)} label</button></>}>
      <div className="form-grid">
        <label className="field"><span>Ukuran stiker</span>
          <select value={sizeKey} onChange={(e) => setSizeKey(e.target.value)}>
            {LABEL_SIZES.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select></label>
        <label className="field"><span>Salinan per label</span>
          <input type="number" min={1} max={100} value={copies} onChange={(e) => setCopies(Number(e.target.value) || 1)} /></label>
      </div>
      {first && (
        <div className="label-preview" style={{ aspectRatio: `${size.w} / ${size.h}` }}>
          <b>{first.title}</b>
          <div className="label-preview-bc" dangerouslySetInnerHTML={{ __html: preview }} />
          <code>{first.code}</code>
          {first.lines.filter(Boolean).map((l, i) => <small key={i}>{l}</small>)}
        </div>
      )}
      <p className="muted small">Pilih printer label pada dialog cetak, set ukuran kertas sama dengan stiker dan margin "None".
        {labels.length > 1 && ` Total ${labels.length} label berbeda.`}</p>
    </Modal>
  );
}
