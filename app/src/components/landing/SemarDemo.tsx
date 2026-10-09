import { useEffect, useRef, useState } from 'react';
import { Check, FileSpreadsheet, ListTodo, Search, ShoppingCart, Wrench } from 'lucide-react';
import MiniAvatar from '../pendopo/MiniAvatar';

// Simulasi obrolan dengan Semar di landing page (bukan data asli).
// Skenario berganti otomatis; tombol Setujui pada kartu usulan bisa diklik.
interface Scenario {
  key: string; label: string; ask: string; file?: string; tool: string; reply: string[];
  card: { icon: typeof Check; title: string; lines: string[]; action: string };
}
const SCENARIOS: Scenario[] = [
  {
    key: 'briefing', label: 'Briefing pagi', ask: 'Sugeng enjang, Semar. Gimana usaha hari ini?',
    tool: 'membaca ringkasan usaha (penjualan, stok, tim, aset)',
    reply: [
      'Sugeng enjang, Juragan 🙏 Kemarin omzet **Rp 12,4 jt**, naik 18%. Jam ramai 12.00–13.00.',
      'Perlu perhatian: **Susu UHT** cukup 1 hari lagi · **Andi** belum absen shift pagi · **Chiller Cabang Kemang** dilaporkan mati total.',
      'Saran: panggil teknisi chiller pagi ini, lalu pesan susu hari ini juga.',
    ],
    card: { icon: ListTodo, title: 'Usulan tugas', lines: ['Panggil teknisi chiller · Tim Dapur · hari ini', 'Pindahkan stok susu ke kulkas cadangan'], action: 'Setujui & buat tugas' },
  },
  {
    key: 'po', label: 'Belanja & PO', ask: 'Bahan apa yang perlu dibeli untuk 7 hari ke depan?',
    tool: 'menganalisa kebutuhan beli & harga supplier',
    reply: [
      'Dari pemakaian 14 hari terakhir, yang perlu dibeli:',
      '• Susu UHT **24 L**: CV Susu Segar, Rp 18.000/L (pricelist termurah)\n• Gula pasir **10 kg**: Toko Makmur, Rp 16.500/kg',
      'PO-nya sudah saya siapkan sebagai draft, Juragan tinggal cek.',
    ],
    card: { icon: ShoppingCart, title: 'Usulan PO · CV Susu Segar', lines: ['Susu UHT 24 L × Rp 18.000', 'Total Rp 432.000 → Gudang Pusat'], action: 'Setujui & buat PO' },
  },
  {
    key: 'excel', label: 'Pindah data Excel', ask: 'Tolong masukkan daftar supplier dari file ini.', file: 'supplier-lama.xlsx',
    tool: 'membaca lampiran & struktur tabel supplier',
    reply: [
      'File berisi **25 supplier**. 2 sudah ada di SEMAR, jadi saya lewati.',
      'Pemetaan kolom: Nama → nama, Telp → telepon, Alamat → alamat, Jatuh tempo → termin hari.',
    ],
    card: { icon: FileSpreadsheet, title: 'Usulan tambah data · Supplier', lines: ['23 baris baru', 'CV Susu Segar, Toko Makmur, UD Sayur Segar, …'], action: 'Setujui & simpan' },
  },
  {
    key: 'aset', label: 'Aset & servis', ask: 'Aset mana yang perlu perhatian? Servis atau ganti baru?',
    tool: 'menganalisa aset, kerusakan & biaya perawatan',
    reply: [
      '**Kompor 4 tungku**: servis 4× setahun, Rp 1,35 jt = 75% nilai bukunya. Lebih hemat ganti baru.',
      '**AC** & **chiller** belum punya jadwal servis rutin. Saya usulkan jadwalnya, tugasnya nanti muncul sendiri di menu Tugas.',
    ],
    card: { icon: Wrench, title: 'Usulan jadwal perawatan', lines: ['Service AC · tiap 3 bulan', 'Bersihkan kondensor chiller · tiap 3 bulan'], action: 'Setujui & buat jadwal' },
  },
];

// **tebal** dalam teks
function Rich({ text }: { text: string }) {
  return <>{text.split(/(\*\*[^*]+\*\*)/).map((p, i) => (p.startsWith('**') ? <b key={i}>{p.slice(2, -2)}</b> : <span key={i}>{p}</span>))}</>;
}

export default function SemarDemo() {
  const reduced = typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  const [idx, setIdx] = useState(0);
  const [step, setStep] = useState(reduced ? 99 : 0);   // 0 tanya, 1 alat, 2.. balasan, terakhir kartu
  const [approved, setApproved] = useState(false);
  const [auto, setAuto] = useState(true);
  const box = useRef<HTMLDivElement>(null);
  const s = SCENARIOS[idx];
  const last = 2 + s.reply.length;   // langkah kartu usulan

  // langkah demi langkah; setelah selesai pindah ke skenario berikutnya (bila tidak sedang dipilih manual)
  useEffect(() => {
    if (reduced) return;
    if (step <= last) {
      const t = setTimeout(() => setStep((x) => x + 1), step === 0 ? 700 : step === 1 ? 1100 : 1300);
      return () => clearTimeout(t);
    }
    if (!auto) return;
    const t = setTimeout(() => { setIdx((i) => (i + 1) % SCENARIOS.length); setStep(0); setApproved(false); }, 6500);
    return () => clearTimeout(t);
  }, [step, last, auto, reduced]);
  useEffect(() => { box.current?.scrollTo({ top: box.current.scrollHeight, behavior: reduced ? 'auto' : 'smooth' }); }, [step, approved, reduced]);

  const pick = (i: number) => { setIdx(i); setStep(reduced ? 99 : 0); setApproved(false); setAuto(false); };
  const Icon = s.card.icon;

  return (
    <div className="lp-demo">
      <div className="lp-demo-tabs" role="tablist" aria-label="Contoh percakapan">
        {SCENARIOS.map((x, i) => (
          <button key={x.key} type="button" role="tab" aria-selected={i === idx} className={i === idx ? 'active' : ''} onClick={() => pick(i)}>{x.label}</button>
        ))}
      </div>
      <div className="lp-demo-head">
        <MiniAvatar id="semar" size={32} />
        <div><b>Semar</b><small>Kepala konsultan · contoh percakapan</small></div>
      </div>
      <div className="lp-demo-body" ref={box}>
        <div className="lp-msg me">
          {s.file && <span className="lp-msg-file"><FileSpreadsheet size={14} /> {s.file}</span>}
          {s.ask}
        </div>
        {step >= 1 && <div className="lp-msg-tool"><Search size={12} /> {s.tool}</div>}
        {step === 1 && <div className="lp-typing" aria-label="Semar mengetik"><i /><i /><i /></div>}
        {s.reply.map((r, i) => step >= 2 + i && (
          <div key={i} className="lp-msg ai">{r.split('\n').map((line, j) => <div key={j}><Rich text={line} /></div>)}</div>
        ))}
        {step >= last && (
          <div className={`lp-msg-card ${approved ? 'done' : ''}`}>
            <div className="lp-msg-card-head"><Icon size={14} /> {s.card.title}</div>
            {s.card.lines.map((l) => <div key={l} className="small">{l}</div>)}
            {approved
              ? <div className="lp-msg-card-ok"><Check size={14} /> Disetujui · sudah dijalankan</div>
              : <button type="button" className="btn btn-primary btn-sm" onClick={() => { setApproved(true); setAuto(false); }}><Check size={14} /> {s.card.action}</button>}
          </div>
        )}
      </div>
      <div className="lp-demo-foot">Semua usulan Semar baru dijalankan setelah Juragan menekan Setujui.</div>
    </div>
  );
}
