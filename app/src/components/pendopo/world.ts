// Peta Pendopo (kantor virtual SEMAR). Koordinat = satuan dunia pada kanvas 1280×720.
// Belum terhubung ke AI: semua perilaku hanya simulasi visual di browser.

export const W = 1280;
export const H = 720;
export const CORRIDOR_Y = 596;          // jalur jalan di depan meja-meja

export type Pose = 'stand' | 'sit' | 'desk' | 'lie';
export interface Spot { id: string; x: number; y: number; pose: Pose; face: 1 | -1; work?: boolean }

const sp = (id: string, x: number, y: number, pose: Pose = 'stand', face: 1 | -1 = 1, work = false): Spot => ({ id, x, y, pose, face, work });

export const SPOTS = {
  home: {
    semar: sp('home-semar', 690, 652, 'sit', 1, true),
    gareng: sp('home-gareng', 182, 508, 'desk', 1, true),
    bagong: sp('home-bagong', 448, 508, 'desk', -1, true),
    bima: sp('home-bima', 852, 508, 'desk', 1, true),
    petruk: sp('home-petruk', 1000, 566, 'stand', 1, true),
  } as Record<string, Spot>,
  lincak: [sp('lincak-1', 582, 652, 'sit', 1), sp('lincak-2', 798, 652, 'sit', -1), sp('lincak-3', 492, 664, 'stand', 1)],
  dapur: [sp('dapur-1', 1150, 580, 'stand', 1), sp('dapur-2', 1214, 606, 'stand', -1)],
  papan: [sp('papan-1', 318, 566, 'stand', -1)],
  tikar: [sp('tikar-1', 62, 676, 'lie', -1), sp('tikar-2', 182, 692, 'lie', -1)],
  jendela: [sp('jendela-1', 138, 566, 'stand', -1)],
  radio: [sp('radio-1', 930, 668, 'stand', -1)],
  pintu: [sp('pintu-1', 700, 418, 'stand', 1)],
};

// tempat berkunjung saat ngobrol dengan rekan (kunci = id meja rekan)
export const VISIT: Record<string, Spot> = {
  'home-gareng': sp('visit-gareng', 262, 566, 'stand', -1),
  'home-bagong': sp('visit-bagong', 528, 566, 'stand', -1),
  'home-bima': sp('visit-bima', 770, 566, 'stand', 1),
  'home-petruk': sp('visit-petruk', 1072, 584, 'stand', -1),
  'home-semar': sp('visit-semar', 890, 664, 'stand', -1),
};

export type AgentId = 'semar' | 'gareng' | 'petruk' | 'bagong' | 'bima';

export interface AgentDef {
  id: AgentId; name: string; role: string; watak: string; tone: string;
  tasks: string[];               // aktivitas saat di meja sendiri
}

export const AGENTS: AgentDef[] = [
  { id: 'semar', name: 'Semar', role: 'Kepala konsultan', watak: 'Pamong yang bijak', tone: '#1F7F72',
    tasks: ['menyusun ringkasan usaha', 'memantau semua outlet', 'membagi tugas tim', 'menimbang saran juragan'] },
  { id: 'gareng', name: 'Gareng', role: 'Penjualan', watak: 'Teliti & jujur', tone: '#d38a00',
    tasks: ['rekap penjualan hari ini', 'cari menu terlaris', 'cek jam ramai kasir', 'merancang paket promo'] },
  { id: 'petruk', name: 'Petruk', role: 'Stok & pembelian', watak: 'Jangkauannya panjang', tone: '#E2410F',
    tasks: ['hitung stok gudang', 'cek batch hampir kedaluwarsa', 'siapkan draft PO', 'bandingkan harga supplier'] },
  { id: 'bagong', name: 'Bagong', role: 'Keuangan', watak: 'Lugas, apa adanya', tone: '#5b4636',
    tasks: ['hitung laba rugi', 'cek HPP menu', 'main sempoa', 'catat di buku besar'] },
  { id: 'bima', name: 'Bima', role: 'Auditor', watak: 'Tegas, tidak bisa disuap', tone: '#2f6fb0',
    tasks: ['pantau CCTV outlet', 'audit void & refund', 'cek selisih opname', 'periksa transaksi di luar jam'] },
];

// tooltip saat kursor di atas bagian kantor
export const AREAS = [
  { label: 'Jendela krepyak', desc: 'Langit di luar ikut jam WIB', x0: 40, y0: 70, x1: 232, y1: 262 },
  { label: 'Papan kapur', desc: 'Corat-coret rencana & target', x0: 262, y0: 96, x1: 422, y1: 222 },
  { label: 'Wayang gunungan', desc: 'Hiasan dinding, lambang SEMAR', x0: 446, y0: 70, x1: 524, y1: 214 },
  { label: 'Jam bandul', desc: 'Jam dinding jadul, jarumnya asli', x0: 540, y0: 50, x1: 612, y1: 262 },
  { label: 'Lawang gebyok', desc: 'Pintu kayu jati, keluar-masuk kantor', x0: 640, y0: 140, x1: 762, y1: 380 },
  { label: 'Lemari server', desc: 'Server di dalam lemari jati, lampunya kedip-kedip', x0: 798, y0: 132, x1: 906, y1: 380 },
  { label: 'Rak gudang', desc: 'Karung beras, kardus & toples bahan', x0: 930, y0: 150, x1: 1066, y1: 380 },
  { label: 'Pawon', desc: 'Dapur: tungku, kuali, cerek & kopi tubruk', x0: 1080, y0: 150, x1: 1272, y1: 470 },
  { label: 'Lincak bambu', desc: 'Bangku bambu untuk rapat & ngopi', x0: 520, y0: 600, x1: 860, y1: 700 },
  { label: 'Tikar pandan', desc: 'Buat tidur siang sebentar', x0: 40, y0: 640, x1: 300, y1: 712 },
  { label: 'Radio transistor', desc: 'Siaran RRI & campursari', x0: 880, y0: 610, x1: 980, y1: 700 },
];
