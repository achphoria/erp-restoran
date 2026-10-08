// Edge Function: semar-agent
// Semar, kepala konsultan AI SEMAR untuk OWNER: tutorial, analisa data, migrasi Excel ke master data.
//
// Keamanan:
//   * Hanya owner (permission '*') yang dilayani; dicek di sini dan di RLS tabel ai_chat_messages.
//   * Semua baca/tulis memakai JWT owner yang memanggil -> RLS membatasi ke company_id owner tersebut.
//   * Perubahan data hanya berupa USULAN; dijalankan setelah owner menekan "Setujui" (action: execute).
//   * Hanya master data (ai_writable_tables) yang boleh diubah; transaksi hanya dibaca.
//
// Secret yang perlu diisi di Supabase (Edge Functions > Secrets):
//   ANTHROPIC_API_KEY  = kunci API Claude Anda (wajib)
//   SEMAR_MODEL        = model Claude (opsional, default claude-sonnet-5-5)
// SUPABASE_URL & SUPABASE_ANON_KEY tersedia otomatis.
//
// Body:
//   { action: 'chat', conversation_id, text, attachments?: [{ name, kind: 'text'|'image'|'pdf', media_type?, data }] }
//   { action: 'execute', conversation_id, action_id }
//   { action: 'reject', conversation_id, action_id }

/* eslint-disable @typescript-eslint/no-explicit-any */
type Json = Record<string, any>;
type Block = Json;
interface Msg { role: 'user' | 'assistant'; content: Block[] }
// subset klien Supabase yang dipakai (supaya bisa diuji dengan klien palsu)
export interface Db { rpc(fn: string, args?: Json): any; from(table: string): any }
export interface Deps { db: Db; apiKey: string | undefined; model: string; fetchFn: typeof fetch; now?: () => Date }

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

export const LIMITS = { messagesPerHour: 40, maxLoops: 8, maxRows: 200, maxWriteRows: 500, toolChars: 40000, attachChars: 60000, history: 40 };
const COL_RE = /^[a-z_][a-z0-9_]*$/;
const OPS = ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'ilike', 'in', 'is'] as const;

// ---------------------------------------------------------------------------- pengetahuan aplikasi
const GUIDE = `PANDUAN APLIKASI SEMAR (Sistem ERP, Manajemen, Akuntansi & Restoran)
Struktur: Platform > Grup usaha > Perusahaan (PT) > Brand > Outlet/branch > Gudang.
Menu sidebar:
- Ringkasan: Dashboard (Pendopo + ringkasan penjualan), Persetujuan (approval yang menunggu).
- Kasir & Outlet: Kasir (POS: dine-in/takeaway, split payment, diskon, struk, QR meja), Daftar Order, Layar Dapur, Shift Kasir (buka/tutup kas), Settlement POS (setoran uang harian per metode bayar), Member & Promo.
- Penjualan: Sales Order (antar cabang & pelanggan B2B), Pengiriman (per koli), Invoice & Piutang, Penerimaan Pembayaran, Pelanggan B2B, Pricelist Jual.
- Pembelian: Purchase Order, Penerimaan Barang (lot & tanggal kedaluwarsa), Tagihan Cabang, Supplier, Pricelist Beli.
- Persediaan: Stok, Dokumen Stok (penyesuaian, waste, opname, transfer), Batch & Kedaluwarsa (FIFO biaya, FEFO keluar), Produksi (simple manufacturing/BOM), Kartu Stok, Gudang & Lokasi.
- Master Data: Master Produk (bahan baku/barang: kategori, satuan & konversi, harga beli, resep/BOM, impor Excel), Menu (kategori menu, harga per outlet, modifier, paket, jadwal harga, impor Excel).
- Keuangan & Laporan: Keuangan (COA, jurnal otomatis, biaya, laba rugi, neraca), Laporan.
- User Management: User (owner membuat akun staf dengan username), Role & Hak Akses, Approval Transaksi (siapa pembuat & penyetuju), Log Aktivitas.
- Pengaturan: Perusahaan & Logo, Brand, Outlet, Pembayaran Online, Data & Backup (data contoh, backup, restore, reset).
Alur umum owner baru: 1) Pengaturan: outlet & brand; 2) Master Produk: satuan, kategori, bahan baku + harga beli; 3) Supplier; 4) Menu + resep (menu terhubung ke bahan lewat resep supaya stok & HPP otomatis); 5) Metode pembayaran & meja; 6) User staf & role; 7) Mulai jualan di Kasir.
Stok berkurang otomatis saat menu terjual (sesuai resep). Jurnal akuntansi terbentuk otomatis dari transaksi.`;

function systemPrompt(p: Json, today: string) {
  const outlets = (p.outlets ?? []).map((o: Json) => o.name).join(', ') || '-';
  return `Kamu adalah Semar, kepala konsultan di aplikasi SEMAR. Watakmu bijak, sabar, dan ngemong seperti Semar di pewayangan.
Kamu melayani owner bernama ${p.full_name} dari perusahaan "${p.company_name}" (outlet: ${outlets}). Hari ini ${today} (WIB).
Panggil owner "Juragan". Gunakan bahasa Indonesia yang santai, sopan, dan jelas. Jawab ringkas, pakai daftar atau tabel markdown bila membantu.

Tugasmu:
1. Menjelaskan cara memakai aplikasi (tutorial langkah demi langkah, sebutkan menu persisnya).
2. Menganalisa data usaha (penjualan, stok, pembelian, keuangan) dengan membaca database lewat alat yang tersedia.
3. Membantu migrasi data dari file (Excel/CSV/PDF/gambar) ke master data: supplier, produk/bahan baku, kategori, satuan, menu, resep, pelanggan, pricelist.

Aturan penting:
- Kamu HANYA bisa mengakses data perusahaan Juragan ini. Jangan pernah mengaku bisa melihat perusahaan lain.
- Sebelum menyebut angka atau fakta data, cek dulu dengan alat cari_data. Jangan mengarang data.
- Untuk menambah/mengubah/menghapus data, WAJIB pakai alat usulkan_perubahan. Data baru berubah setelah Juragan menekan tombol Setujui. Jangan bilang sudah tersimpan sebelum ada pesan [Sistem] bahwa usulan disetujui.
- Hanya master data yang bisa kamu ubah. Transaksi (penjualan, PO, stok, jurnal) hanya bisa dibaca; arahkan Juragan ke menu aplikasi untuk membuatnya.
- Migrasi file: (a) baca isi lampiran, (b) cek struktur_tabel tujuan (kolom wajib, relasi, aturan), (c) cek data yang sudah ada dengan cari_data supaya tidak dobel, (d) jelaskan pemetaan kolom ke Juragan, (e) usulkan dalam batch (maks ${LIMITS.maxWriteRows} baris). Bila butuh id relasi (kategori, satuan, supplier), cari id-nya dulu; bila belum ada, usulkan pembuatannya lebih dulu, tunggu disetujui, baru lanjut.
- company_id diisi otomatis oleh sistem; jangan mengisinya.
- Pesan yang diawali [Sistem] adalah catatan otomatis dari aplikasi (hasil persetujuan/penolakan usulan).

Pembelian & forecasting:
- Untuk pertanyaan kebutuhan beli, stok cukup berapa hari, atau saran belanja: pakai analisa_kebutuhan_beli. Jelaskan dengan tabel singkat: bahan, stok, pemakaian/hari, cukup berapa hari, saran beli, supplier & harga terbaik. Sebutkan asumsinya (periode data & target hari).
- Pilih supplier dengan harga pricelist termurah yang masih berlaku; bila tidak ada pricelist, pakai supplier pembelian terakhir. Sebutkan alasan pilihanmu.
- Untuk membuat PO pakai usulkan_po: SATU PO = satu supplier + satu gudang (bila beberapa supplier, buat beberapa usulan). Isi supplier_id, gudang_id & item_id dari data (jangan mengarang id), sertakan nama supaya Juragan mudah membaca. Harga boleh dikosongkan, sistem mengisinya dari pricelist/pembelian terakhir.
- Default PO disimpan sebagai draft (ajukan=false). Set ajukan=true hanya bila Juragan meminta langsung diajukan/disetujui; PO tetap mengikuti matriks approval perusahaan.
- Jangan pernah bilang PO sudah dibuat sebelum ada pesan [Sistem] bahwa usulan disetujui.

${GUIDE}`;
}

// ---------------------------------------------------------------------------- alat (tools)
const filterSchema = {
  type: 'array',
  description: 'Filter baris. op: eq, neq, gt, gte, lt, lte, ilike (pakai % sebagai wildcard), in (nilai berupa array), is (null/true/false).',
  items: { type: 'object', properties: { kolom: { type: 'string' }, op: { type: 'string', enum: [...OPS] }, nilai: {} }, required: ['kolom', 'op', 'nilai'] },
};
export const TOOLS = [
  {
    name: 'daftar_tabel',
    description: 'Daftar semua tabel & laporan (view rpt_*) yang bisa dibaca, dan mana yang boleh diubah (writable). Prefix: sys_ sistem, mst_ menu/meja/pembayaran, inv_ produk/stok/resep, pur_ pembelian, sal_ penjualan B2B, pos_ kasir, fin_ keuangan, crm_ member/promo, rpt_ laporan siap pakai.',
    input_schema: { type: 'object', properties: {} },
  },
  {
    name: 'struktur_tabel',
    description: 'Kolom (tipe, wajib/tidak, default), relasi (foreign key) dan aturan (check/unique) dari tabel tertentu. Selalu cek ini sebelum mengusulkan perubahan.',
    input_schema: { type: 'object', properties: { tabel: { type: 'array', items: { type: 'string' }, description: 'Nama tabel, maks 6' } }, required: ['tabel'] },
  },
  {
    name: 'cari_data',
    description: `Baca baris dari satu tabel/view milik perusahaan ini (maks ${LIMITS.maxRows} baris). Set hanya_jumlah=true untuk menghitung saja.`,
    input_schema: {
      type: 'object',
      properties: {
        tabel: { type: 'string' },
        kolom: { type: 'array', items: { type: 'string' }, description: 'Kolom yang diambil; kosong = semua' },
        filter: filterSchema,
        urut: { type: 'object', properties: { kolom: { type: 'string' }, naik: { type: 'boolean' } } },
        batas: { type: 'integer', minimum: 1, maximum: LIMITS.maxRows },
        hanya_jumlah: { type: 'boolean' },
      },
      required: ['tabel'],
    },
  },
  {
    name: 'analisa_kebutuhan_beli',
    description: 'Forecast kebutuhan beli per bahan: stok, pemakaian per hari (dari kartu stok), cukup untuk berapa hari, stok minimum, saran beli dalam satuan beli, opsi supplier & harga dari pricelist aktif, dan pembelian terakhir.',
    input_schema: {
      type: 'object',
      properties: {
        gudang_id: { type: 'string', description: 'Kosongkan untuk semua gudang yang bisa diakses' },
        hari_data: { type: 'integer', minimum: 1, maximum: 180, description: 'Periode data pemakaian (default 14 hari)' },
        cukup_hari: { type: 'integer', minimum: 1, maximum: 90, description: 'Target stok cukup untuk berapa hari (default 7)' },
        cari: { type: 'string', description: 'Filter nama/kode bahan' },
      },
    },
  },
  {
    name: 'usulkan_po',
    description: 'Usulkan Purchase Order (pembelian ke supplier). TIDAK langsung dibuat: owner melihat usulan lalu menekan Setujui. Satu PO = satu supplier + satu gudang.',
    input_schema: {
      type: 'object',
      properties: {
        supplier_id: { type: 'string' }, supplier_nama: { type: 'string' },
        gudang_id: { type: 'string' }, gudang_nama: { type: 'string' },
        tanggal_kirim: { type: 'string', description: 'YYYY-MM-DD, opsional' },
        catatan: { type: 'string' },
        ajukan: { type: 'boolean', description: 'true = langsung ajukan/setujui (ikut matriks approval); false = draft' },
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              item_id: { type: 'string' }, nama: { type: 'string' }, unit_id: { type: 'string', description: 'Kosong = satuan beli' },
              satuan: { type: 'string' }, qty: { type: 'number' }, harga: { type: 'number', description: 'Harga per satuan; kosong = otomatis' },
            },
            required: ['item_id', 'qty'],
          },
        },
        ringkasan: { type: 'string', description: 'mis. "PO susu & gula ke CV Susu Segar untuk 7 hari"' },
      },
      required: ['supplier_id', 'gudang_id', 'items', 'ringkasan'],
    },
  },
  {
    name: 'usulkan_perubahan',
    description: 'Usulkan menambah, mengubah, atau menghapus data master. TIDAK langsung dijalankan: owner akan melihat usulan dan menekan Setujui/Tolak. Satu usulan = satu tabel.',
    input_schema: {
      type: 'object',
      properties: {
        operasi: { type: 'string', enum: ['tambah', 'ubah', 'hapus'] },
        tabel: { type: 'string' },
        baris: { type: 'array', items: { type: 'object' }, description: `Untuk tambah: daftar baris (maks ${LIMITS.maxWriteRows})` },
        filter: filterSchema,
        nilai: { type: 'object', description: 'Untuk ubah: kolom yang diubah beserta nilai barunya' },
        ringkasan: { type: 'string', description: 'Ringkasan singkat untuk owner, mis. "Tambah 25 supplier dari file supplier.xlsx"' },
      },
      required: ['operasi', 'tabel', 'ringkasan'],
    },
  },
];

const clip = (v: unknown) => {
  const s = JSON.stringify(v);
  return s.length > LIMITS.toolChars ? s.slice(0, LIMITS.toolChars) + `… (dipotong, total ${s.length} karakter; persempit filter/kolom)` : s;
};

async function tableInfo(db: Db, tables?: string[]) {
  const { data, error } = await db.rpc('ai_table_info', { p_tables: tables ?? null });
  if (error) throw new Error(error.message);
  return (data ?? []) as Json[];
}

function applyFilters(q: any, filters: Json[] | undefined) {
  for (const f of filters ?? []) {
    if (!COL_RE.test(String(f.kolom))) throw new Error(`Nama kolom tidak valid: ${f.kolom}`);
    if (!OPS.includes(f.op)) throw new Error(`Operator tidak dikenal: ${f.op}`);
    if (f.op === 'in') q = q.in(f.kolom, Array.isArray(f.nilai) ? f.nilai : [f.nilai]);
    else q = q[f.op](f.kolom, f.nilai);
  }
  return q;
}

export async function runReadTool(db: Db, name: string, input: Json): Promise<string> {
  if (name === 'daftar_tabel') {
    const info = await tableInfo(db);
    return clip(info.map((t) => ({ tabel: t.table, jenis: t.kind, boleh_diubah: t.writable })));
  }
  if (name === 'struktur_tabel') {
    const names = (input.tabel ?? []).slice(0, 6).map(String);
    const info = await tableInfo(db, names);
    if (!info.length) return `Tabel tidak ditemukan: ${names.join(', ')}`;
    return clip(info);
  }
  if (name === 'cari_data') {
    const table = String(input.tabel ?? '');
    const known = await tableInfo(db, [table]);
    if (!known.length) return `Tabel/laporan "${table}" tidak ada atau tidak boleh dibaca. Pakai daftar_tabel.`;
    const cols = (input.kolom ?? []).map(String);
    if (cols.some((c: string) => !COL_RE.test(c))) return 'Nama kolom tidak valid';
    const limit = Math.min(Number(input.batas) || 50, LIMITS.maxRows);
    let q = db.from(table).select(cols.length ? cols.join(',') : '*', input.hanya_jumlah ? { count: 'exact', head: true } : { count: 'exact' });
    q = applyFilters(q, input.filter);
    if (input.urut?.kolom && COL_RE.test(input.urut.kolom)) q = q.order(input.urut.kolom, { ascending: input.urut.naik !== false });
    if (!input.hanya_jumlah) q = q.limit(limit);
    const { data, error, count } = await q;
    if (error) return `Gagal membaca: ${error.message}`;
    return input.hanya_jumlah ? JSON.stringify({ jumlah: count }) : clip({ jumlah_total: count, ditampilkan: data?.length ?? 0, baris: data });
  }
  if (name === 'analisa_kebutuhan_beli') {
    const { data, error } = await db.rpc('ai_purchase_forecast', {
      p_warehouse_id: input.gudang_id || null, p_days: input.hari_data ?? 14, p_cover_days: input.cukup_hari ?? 7, p_search: input.cari || null,
    });
    if (error) return `Gagal menganalisa: ${error.message}`;
    return clip(data);
  }
  return `Alat tidak dikenal: ${name}`;
}

// usulan PO -> payload fungsi database
export const poPayload = (input: Json) => ({
  supplier_id: input.supplier_id, warehouse_id: input.gudang_id, expected_date: input.tanggal_kirim || null,
  note: input.catatan || null, submit: !!input.ajukan,
  items: (input.items ?? []).map((i: Json) => ({ item_id: i.item_id, unit_id: i.unit_id || null, qty: i.qty, harga: i.harga ?? null, nama: i.nama })),
});

// pratinjau PO (dry run): harga terisi otomatis, error ketahuan sebelum owner menyetujui
export async function previewPo(db: Db, input: Json) {
  const { data, error } = await db.rpc('ai_create_purchase_order', { p: poPayload(input), p_dry_run: true });
  if (error) return { error: error.message as string };
  return { preview: data as Json };
}

// validasi usulan; kembalikan pesan error (string) atau null bila valid
export async function validateProposal(db: Db, input: Json): Promise<string | null> {
  const table = String(input.tabel ?? '');
  const [info] = await tableInfo(db, [table]);
  if (!info) return `Tabel "${table}" tidak ada.`;
  if (!info.writable) return `Tabel "${table}" tidak boleh diubah agent (hanya master data). Arahkan owner ke menu aplikasi.`;
  const cols = new Set((info.columns ?? []).map((c: Json) => c.name));
  const badKeys = (obj: Json) => Object.keys(obj).filter((k) => !cols.has(k));
  if (input.operasi === 'tambah') {
    const rows = input.baris;
    if (!Array.isArray(rows) || !rows.length) return 'Operasi tambah butuh "baris" (minimal 1).';
    if (rows.length > LIMITS.maxWriteRows) return `Maksimal ${LIMITS.maxWriteRows} baris per usulan; bagi menjadi beberapa usulan.`;
    const bad = [...new Set(rows.flatMap(badKeys))];
    if (bad.length) return `Kolom tidak dikenal di ${table}: ${bad.join(', ')}`;
    const required = (info.columns ?? []).filter((c: Json) => c.required && c.name !== 'company_id').map((c: Json) => c.name);
    const missing = required.filter((c: string) => rows.some((r: Json) => r[c] === undefined || r[c] === null || r[c] === ''));
    if (missing.length) return `Kolom wajib belum diisi: ${missing.join(', ')}`;
  } else if (input.operasi === 'ubah' || input.operasi === 'hapus') {
    if (!Array.isArray(input.filter) || !input.filter.length) return `Operasi ${input.operasi} wajib memakai filter (tidak boleh semua baris).`;
    if (input.operasi === 'ubah') {
      if (!input.nilai || !Object.keys(input.nilai).length) return 'Operasi ubah butuh "nilai".';
      const bad = badKeys(input.nilai);
      if (bad.length) return `Kolom tidak dikenal di ${table}: ${bad.join(', ')}`;
    }
  } else return 'operasi harus tambah, ubah, atau hapus';
  return null;
}

const PROTECTED = ['id', 'company_id', 'created_at', 'updated_at', 'created_by'];
const clean = (o: Json) => Object.fromEntries(Object.entries(o).filter(([k]) => !PROTECTED.includes(k)));

export async function executeProposal(db: Db, input: Json, companyId: string) {
  const err = await validateProposal(db, input);
  if (err) return { ok: false, message: err };
  const table = String(input.tabel);
  const [info] = await tableInfo(db, [table]);
  if (input.operasi === 'tambah') {
    const rows = input.baris.map((r: Json) => ({ ...clean(r), ...(info.has_company_id ? { company_id: companyId } : {}) }));
    let total = 0;
    for (let i = 0; i < rows.length; i += 200) {
      const { data, error } = await db.from(table).insert(rows.slice(i, i + 200)).select('id');
      if (error) return { ok: false, message: `Gagal di baris ${i + 1}-${i + Math.min(200, rows.length - i)}: ${error.message}${total ? ` (${total} baris sebelumnya sudah tersimpan)` : ''}`, count: total };
      total += data?.length ?? 0;
    }
    return { ok: true, message: `${total} baris ditambahkan ke ${table}`, count: total };
  }
  // ubah / hapus: cek jumlah baris yang kena dulu
  const { count, error: cErr } = await applyFilters(db.from(table).select('id', { count: 'exact', head: true }), input.filter);
  if (cErr) return { ok: false, message: cErr.message };
  if ((count ?? 0) > LIMITS.maxWriteRows) return { ok: false, message: `Filter mengenai ${count} baris (maks ${LIMITS.maxWriteRows}). Persempit filter.` };
  const base = input.operasi === 'ubah' ? db.from(table).update(clean(input.nilai)) : db.from(table).delete();
  const { data, error } = await applyFilters(base, input.filter).select('id');
  if (error) return { ok: false, message: error.message };
  const n = data?.length ?? 0;
  return { ok: true, message: `${n} baris ${input.operasi === 'ubah' ? 'diubah' : 'dihapus'} di ${table}`, count: n };
}

// ---------------------------------------------------------------------------- riwayat obrolan
const ALLOWED: Record<string, string[]> = {
  text: ['type', 'text'], tool_use: ['type', 'id', 'name', 'input'], tool_result: ['type', 'tool_use_id', 'content', 'is_error'],
};
function sanitize(rows: Json[]): Msg[] {
  const out: Msg[] = [];
  for (const r of rows) {
    const content = (r.content as Block[]).filter((b) => ALLOWED[b.type])
      .map((b) => Object.fromEntries(Object.entries(b).filter(([k]) => ALLOWED[b.type].includes(k))));
    if (!content.length) continue;
    const last = out[out.length - 1];
    if (last && last.role === r.role) last.content.push(...content);   // gabungkan giliran yang berurutan
    else out.push({ role: r.role, content });
  }
  // potong riwayat lama; harus dimulai pesan user yang bukan tool_result
  let msgs = out.slice(-LIMITS.history);
  while (msgs.length && (msgs[0].role !== 'user' || msgs[0].content.some((b) => b.type === 'tool_result'))) msgs = msgs.slice(1);
  return msgs;
}

async function loadHistory(db: Db, conversationId: string) {
  const { data, error } = await db.from('ai_chat_messages').select('role, content, meta').eq('conversation_id', conversationId).order('id', { ascending: true }).limit(400);
  if (error) throw new Error(error.message);
  return (data ?? []) as Json[];
}

async function saveMessages(db: Db, profile: Json, conversationId: string, msgs: (Msg & { meta?: Json; input_tokens?: number; output_tokens?: number })[]) {
  if (!msgs.length) return;
  const { error } = await db.from('ai_chat_messages').insert(msgs.map((m) => ({
    company_id: profile.company_id, user_id: profile.user_id, conversation_id: conversationId, role: m.role, content: m.content,
    meta: m.meta ?? null, input_tokens: m.input_tokens ?? 0, output_tokens: m.output_tokens ?? 0,
  })));
  if (error) throw new Error(`Gagal menyimpan obrolan: ${error.message}`);
}

const PROPOSAL_TOOLS = ['usulkan_perubahan', 'usulkan_po'];
function findProposal(history: Json[], actionId: string) {
  for (const m of history) for (const b of m.content as Block[]) {
    if (b.type === 'tool_use' && b.id === actionId && PROPOSAL_TOOLS.includes(b.name)) return { name: b.name as string, input: b.input as Json };
  }
  return null;
}

export async function executePo(db: Db, input: Json) {
  const { data, error } = await db.rpc('ai_create_purchase_order', { p: poPayload(input), p_dry_run: false });
  if (error) return { ok: false, message: error.message as string };
  const total = new Intl.NumberFormat('id-ID').format(Number(data?.total ?? 0));
  return { ok: true, message: `PO ${data?.po_number ?? '(draft)'} ${data?.status} · total Rp ${total}`, po: data };
}

// ---------------------------------------------------------------------------- Claude
async function callClaude(deps: Deps, body: Json) {
  const res = await deps.fetchFn('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': deps.apiKey!, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data?.error?.message ?? `HTTP ${res.status}`;
    if (res.status === 401) throw new Error('Kunci API Claude tidak valid. Periksa secret ANTHROPIC_API_KEY.');
    if (/credit balance/i.test(msg)) throw new Error('Saldo kredit API Claude habis. Tambah kredit di console.anthropic.com.');
    if (res.status === 429 || res.status === 529) throw new Error('Server Claude sedang sibuk. Coba lagi sebentar.');
    throw new Error(`Claude: ${msg}`);
  }
  return data as Json;
}

function attachmentBlocks(atts: Json[] | undefined): { send: Block[]; keep: Block[] } {
  const send: Block[] = [], keep: Block[] = [];
  for (const a of (atts ?? []).slice(0, 5)) {
    const name = String(a.name ?? 'lampiran');
    if (a.kind === 'text') {
      const text = String(a.data ?? '').slice(0, LIMITS.attachChars);
      const b = { type: 'text', text: `[Lampiran: ${name}]\n${text}${String(a.data ?? '').length > LIMITS.attachChars ? '\n… (dipotong)' : ''}` };
      send.push(b); keep.push(b);
    } else if (a.kind === 'image') {
      send.push({ type: 'image', source: { type: 'base64', media_type: a.media_type, data: a.data } });
      keep.push({ type: 'text', text: `[Lampiran gambar: ${name} (sudah dibaca, tidak disimpan)]` });
    } else if (a.kind === 'pdf') {
      send.push({ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: a.data } });
      keep.push({ type: 'text', text: `[Lampiran PDF: ${name} (sudah dibaca, tidak disimpan)]` });
    }
  }
  return { send, keep };
}

// ---------------------------------------------------------------------------- handler
export async function handle(body: Json, deps: Deps): Promise<{ status: number; body: Json }> {
  const { db } = deps;
  const { data: profile, error: pErr } = await db.rpc('sys_get_my_profile');
  if (pErr || !profile) return { status: 401, body: { error: 'Silakan login dulu.' } };
  if (!(profile.permissions ?? []).includes('*')) return { status: 403, body: { error: 'Semar hanya melayani owner perusahaan.' } };
  const conversationId = String(body.conversation_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(conversationId)) return { status: 400, body: { error: 'conversation_id tidak valid' } };

  if (body.action === 'execute' || body.action === 'reject') {
    const history = await loadHistory(db, conversationId);
    const found = findProposal(history, String(body.action_id));
    if (!found) return { status: 404, body: { error: 'Usulan tidak ditemukan.' } };
    if (history.some((m) => m.meta?.action_id === body.action_id)) return { status: 409, body: { error: 'Usulan ini sudah diproses.' } };
    const proposal = found.input;
    const result: Json = body.action !== 'execute' ? { ok: true, message: 'ditolak owner', count: 0 }
      : found.name === 'usulkan_po' ? await executePo(db, proposal) : await executeProposal(db, proposal, profile.company_id);
    const status = body.action === 'reject' ? 'rejected' : result.ok ? 'executed' : 'failed';
    const note = body.action === 'reject'
      ? `[Sistem] Juragan MENOLAK usulan "${proposal.ringkasan}". Tidak ada data yang berubah.`
      : result.ok ? `[Sistem] Juragan MENYETUJUI usulan "${proposal.ringkasan}". Hasil: ${result.message}.`
        : `[Sistem] Usulan "${proposal.ringkasan}" disetujui tetapi GAGAL dijalankan: ${result.message}`;
    await saveMessages(db, profile, conversationId, [{ role: 'user', content: [{ type: 'text', text: note }], meta: { action_id: body.action_id, status, result } }]);
    return { status: 200, body: { status, result } };
  }

  if (body.action !== 'chat') return { status: 400, body: { error: 'Aksi tidak dikenal' } };
  if (!deps.apiKey) return { status: 500, body: { error: 'Secret ANTHROPIC_API_KEY belum diisi di Supabase (Edge Functions > Secrets).' } };
  const text = String(body.text ?? '').trim();
  if (!text && !(body.attachments ?? []).length) return { status: 400, body: { error: 'Pesan kosong' } };

  const { data: usage } = await db.rpc('ai_recent_usage');
  if ((usage?.messages_last_hour ?? 0) >= LIMITS.messagesPerHour) {
    return { status: 429, body: { error: `Batas ${LIMITS.messagesPerHour} pesan per jam tercapai. Semar istirahat sebentar ya, Juragan.` } };
  }

  const history = sanitize(await loadHistory(db, conversationId));
  const att = attachmentBlocks(body.attachments);
  const userMsg: Msg = { role: 'user', content: [...att.send, ...(text ? [{ type: 'text', text }] : [])] };
  const userKeep: Msg = { role: 'user', content: [...att.keep, ...(text ? [{ type: 'text', text }] : [])] };
  const today = new Intl.DateTimeFormat('id-ID', { timeZone: 'Asia/Jakarta', dateStyle: 'full', timeStyle: 'short' }).format(deps.now?.() ?? new Date());
  const system = [{ type: 'text', text: systemPrompt(profile, today), cache_control: { type: 'ephemeral' } }];

  // giliran user berurutan (mis. catatan [Sistem] lalu pesan baru) digabung jadi satu
  const lastHist = history[history.length - 1];
  const convo: Msg[] = lastHist?.role === 'user'
    ? [...history.slice(0, -1), { role: 'user', content: [...lastHist.content, ...userMsg.content] }]
    : [...history, userMsg];
  const produced: (Msg & { input_tokens?: number; output_tokens?: number })[] = [];
  const pending: Json[] = [];
  let inTok = 0, outTok = 0;

  for (let loop = 0; loop < LIMITS.maxLoops; loop++) {
    const res = await callClaude(deps, { model: deps.model, max_tokens: 4096, system, tools: TOOLS, messages: convo });
    inTok += (res.usage?.input_tokens ?? 0) + (res.usage?.cache_read_input_tokens ?? 0) + (res.usage?.cache_creation_input_tokens ?? 0);
    outTok += res.usage?.output_tokens ?? 0;
    const assistant: Msg = { role: 'assistant', content: res.content ?? [] };
    convo.push(assistant);
    produced.push(assistant);
    if (res.stop_reason !== 'tool_use') break;

    const results: Block[] = [];
    for (const b of assistant.content.filter((x) => x.type === 'tool_use')) {
      try {
        if (b.name === 'usulkan_po') {
          const r = await previewPo(db, b.input ?? {});
          if (r.error) results.push({ type: 'tool_result', tool_use_id: b.id, content: `Usulan PO ditolak sistem: ${r.error}`, is_error: true });
          else {
            pending.push({ id: b.id, kind: 'po', ...b.input, preview: r.preview });
            results.push({ type: 'tool_result', tool_use_id: b.id, content: `Usulan PO #${b.id.slice(-6)} sudah ditampilkan ke Juragan dan MENUNGGU persetujuan. Belum ada PO yang dibuat. PRATINJAU: ${JSON.stringify(r.preview)}` });
          }
        } else if (b.name === 'usulkan_perubahan') {
          const err = await validateProposal(db, b.input);
          if (err) results.push({ type: 'tool_result', tool_use_id: b.id, content: `Usulan ditolak sistem: ${err}`, is_error: true });
          else {
            pending.push({ id: b.id, ...b.input });
            results.push({ type: 'tool_result', tool_use_id: b.id, content: `Usulan #${b.id.slice(-6)} sudah ditampilkan ke Juragan dan MENUNGGU persetujuan. Belum ada data yang berubah. Jangan mengulang usulan yang sama.` });
          }
        } else {
          results.push({ type: 'tool_result', tool_use_id: b.id, content: await runReadTool(db, b.name, b.input ?? {}) });
        }
      } catch (e) {
        results.push({ type: 'tool_result', tool_use_id: b.id, content: `Error: ${e instanceof Error ? e.message : String(e)}`, is_error: true });
      }
    }
    const toolMsg: Msg = { role: 'user', content: results };
    convo.push(toolMsg);
    produced.push(toolMsg);
  }
  // pesan terakhir harus dari assistant (bila batas loop tercapai saat masih memakai alat, tutup dengan catatan)
  if (produced[produced.length - 1]?.role === 'user') {
    produced.push({ role: 'assistant', content: [{ type: 'text', text: 'Maaf Juragan, pekerjaan ini cukup panjang. Ketik "lanjut" supaya saya teruskan.' }] });
  }
  const lastAssistant = [...produced].reverse().find((m) => m.role === 'assistant')!;
  lastAssistant.input_tokens = inTok;
  lastAssistant.output_tokens = outTok;
  await saveMessages(db, profile, conversationId, [userKeep, ...produced]);
  return { status: 200, body: { pending, usage: { input_tokens: inTok, output_tokens: outTok } } };
}

// ---------------------------------------------------------------------------- server (Deno / Supabase)
declare const Deno: any;
if (typeof Deno !== 'undefined') {
  const { createClient } = await import('npm:@supabase/supabase-js@2');
  Deno.serve(async (req: Request) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
    try {
      const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
        global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
        auth: { persistSession: false },
      });
      const r = await handle(await req.json(), {
        db, apiKey: Deno.env.get('ANTHROPIC_API_KEY'), model: Deno.env.get('SEMAR_MODEL') || 'claude-sonnet-5-5', fetchFn: fetch,
      });
      return json(r.body, r.status);
    } catch (e) {
      return json({ error: e instanceof Error ? e.message : String(e) }, 500);
    }
  });
}
