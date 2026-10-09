import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { Link } from 'react-router-dom';
import { Check, FileSpreadsheet, ListTodo, Paperclip, Plus, Search, Send, ShoppingCart, Wrench, X } from 'lucide-react';
import type { ChatEvent } from './useOfficeSim';
import { useFeedback } from '../Feedback';
import { useAuth } from '../../context/AuthContext';
import { must, supabase } from '../../lib/supabase';
import { errorMessage, formatDateTime, formatRupiah } from '../../lib/format';
import { MiniMarkdown } from '../../lib/miniMarkdown';
import { invokeSemar, readAttachment, type Attachment } from '../../lib/semar';
import MiniAvatar from './MiniAvatar';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Block = Record<string, any>;
interface Row { id: number; role: 'user' | 'assistant'; content: Block[]; meta: Record<string, any> | null; created_at: string }

const SUGGESTIONS = [
  'Ringkasan usaha hari ini & saran prioritas',
  'Analisa ulasan pelanggan bulan ini',
  'Rekap absensi, telat & cuti tim minggu ini',
  'Buatkan tugas perbaikan dari ulasan yang buruk',
  'Aset mana yang perlu perhatian? Servis atau ganti baru?',
  'Saya owner baru. Apa langkah pertama menyiapkan usaha di SEMAR?',
  'Bantu saya migrasi data supplier dari file Excel',
  'Bahan apa yang perlu dibeli untuk 7 hari ke depan? Buatkan PO-nya',
  'Buatkan SOP buka toko untuk kasir',
];
const TOOL_LABEL: Record<string, string> = {
  daftar_tabel: 'melihat daftar data', struktur_tabel: 'mempelajari struktur', cari_data: 'membaca data',
  analisa_kebutuhan_beli: 'menganalisa kebutuhan beli & harga supplier',
  ringkasan_bisnis: 'membaca ringkasan usaha (penjualan, stok, SDM, tugas, ulasan)',
  analisa_ulasan: 'membaca ulasan pelanggan', rekap_sdm: 'merekap absensi & cuti', daftar_tim: 'melihat daftar tim',
  analisa_aset: 'menganalisa aset, kerusakan & biaya perawatan',
};
const PROPOSAL_TOOLS = ['usulkan_perubahan', 'usulkan_po', 'usulkan_tugas', 'usulkan_perawatan'];
const PRIORITY: Record<string, [string, string]> = {
  low: ['Rendah', ''], normal: ['Normal', 'badge-info'], high: ['Tinggi', 'badge-warning'], urgent: ['Mendesak', 'badge-danger'],
};
const OP_LABEL: Record<string, string> = { tambah: 'Tambah data', ubah: 'Ubah data', hapus: 'Hapus data' };
const newId = () => crypto.randomUUID();

// Panel obrolan dengan Semar di sebelah kanan Pendopo (khusus owner).
// onEvent memberi tahu kantor supaya karakter Semar ikut bereaksi (berpikir, menjawab, ada usulan, disetujui).
export default function SemarChat({ onClose, onEvent }: { onClose: () => void; onEvent?: (e: ChatEvent) => void }) {
  const { profile } = useAuth();
  const { toast } = useFeedback();
  const isOwner = !!profile?.permissions.includes('*');
  const [conv, setConv] = useState<string | null>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [text, setText] = useState('');
  const [files, setFiles] = useState<Attachment[]>([]);
  const [busy, setBusy] = useState(false);
  const [acting, setActing] = useState<string | null>(null);
  const [draft, setDraft] = useState<string | null>(null);     // pesan yang sedang dikirim (tampil langsung)
  const listRef = useRef<HTMLDivElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const eventRef = useRef(onEvent);
  useEffect(() => { eventRef.current = onEvent; });

  const load = useCallback(async (id: string) => {
    setRows(await must(supabase.from('ai_chat_messages').select('id, role, content, meta, created_at').eq('conversation_id', id).order('id').limit(400)));
  }, []);

  // buka obrolan terakhir (atau mulai baru); Semar menyambut
  useEffect(() => {
    eventRef.current?.('open');
    if (isOwner) {
      supabase.from('ai_chat_messages').select('conversation_id').order('id', { ascending: false }).limit(1)
        .then(({ data }) => {
          const id = data?.[0]?.conversation_id ?? newId();
          setConv(id);
          if (data?.length) load(id).catch((e) => toast(errorMessage(e), 'error'));
        });
    }
    return () => eventRef.current?.('close');
  }, [isOwner, load, toast]);

  // tutup dengan Esc
  useEffect(() => {
    const onKeyDown = (e: globalThis.KeyboardEvent) => { if (e.key === 'Escape' && !document.querySelector('.modal')) onClose(); };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [onClose]);

  useEffect(() => { listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: 'smooth' }); }, [rows, draft, busy]);

  const send = async (msg = text) => {
    if (!conv || busy || (!msg.trim() && !files.length)) return;
    setBusy(true);
    setDraft(msg.trim() || `(${files.length} lampiran)`);
    setText('');
    const atts = files;
    setFiles([]);
    eventRef.current?.('thinking');
    try {
      const r = await invokeSemar<{ pending: unknown[] }>({ action: 'chat', conversation_id: conv, text: msg.trim(), attachments: atts.map(({ info: _i, ...a }) => a) });
      await load(conv);
      eventRef.current?.(r.pending?.length ? 'pending' : 'answered');
    } catch (e) {
      toast(errorMessage(e), 'error');
      setText(msg);
      setFiles(atts);
      eventRef.current?.('answered');
    } finally {
      setBusy(false);
      setDraft(null);
    }
  };

  const decide = async (actionId: string, action: 'execute' | 'reject') => {
    if (!conv) return;
    setActing(actionId);
    try {
      const r = await invokeSemar<{ status: string; result: { message: string } }>({ action, conversation_id: conv, action_id: actionId });
      toast(r.status === 'executed' ? `Berhasil: ${r.result.message}` : r.status === 'rejected' ? 'Usulan ditolak' : `Gagal: ${r.result.message}`, r.status === 'failed' ? 'error' : 'success');
      eventRef.current?.(r.status === 'executed' ? 'executed' : 'rejected');
      await load(conv);
    } catch (e) {
      toast(errorMessage(e), 'error');
    } finally {
      setActing(null);
    }
  };

  const attach = async (list: FileList | null) => {
    if (!list) return;
    for (const f of Array.from(list).slice(0, 5 - files.length)) {
      try { const a = await readAttachment(f); setFiles((x) => [...x, a]); } catch (e) { toast(errorMessage(e), 'error'); }
    }
    if (fileRef.current) fileRef.current.value = '';
  };

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
  };

  // status usulan dari catatan [Sistem]
  const decisions = new Map<string, Record<string, any>>();
  rows.forEach((r) => { if (r.meta?.action_id) decisions.set(r.meta.action_id, r.meta); });
  const previews = new Map<string, Record<string, any>>();
  rows.forEach((r) => r.content.forEach((b) => {
    if (b.type !== 'tool_result' || typeof b.content !== 'string') return;
    const i = b.content.indexOf('PRATINJAU: ');
    if (i >= 0) { try { previews.set(b.tool_use_id, JSON.parse(b.content.slice(i + 11))); } catch { /* abaikan */ } }
  }));

  return (
    <aside className="semar-panel" aria-label="Obrolan dengan Semar">
      <div className="semar-panel-in">
        <div className="semar-top">
          <MiniAvatar id="semar" size={42} />
          <div>
            <b>Semar <span className="semar-online">● online</span></b>
            <div className="muted small">Kepala konsultan · data {profile?.company_name}</div>
          </div>
          {isOwner && <button type="button" className="icon-btn" title="Obrolan baru" onClick={() => { setConv(newId()); setRows([]); }} disabled={busy}><Plus size={18} /></button>}
          <button type="button" className="icon-btn" title="Tutup (Esc)" onClick={onClose}><X size={18} /></button>
        </div>

        {!isOwner ? (
          <div className="semar-locked">
            <MiniAvatar id="semar" size={72} />
            <p><b>Semar hanya melayani owner.</b> Akun Anda bukan owner perusahaan ini, jadi belum bisa mengobrol dengan Semar.</p>
          </div>
        ) : (
          <>
            <div ref={listRef} className="semar-list">
              {!rows.length && !draft && (
                <div className="semar-empty">
                  <p>Sugeng rawuh, Juragan {profile?.full_name}. Saya Semar. Mau dibantu apa hari ini?</p>
                  <div className="semar-suggest">{SUGGESTIONS.map((s) => <button key={s} type="button" onClick={() => send(s)}>{s}</button>)}</div>
                </div>
              )}
              {rows.map((r) => <Message key={r.id} row={r} decisions={decisions} previews={previews} acting={acting} onDecide={decide} />)}
              {draft && <div className="semar-msg me"><div className="semar-bubble">{draft}</div></div>}
              {busy && <div className="semar-msg ai"><div className="semar-bubble thinking"><span /><span /><span /> Semar sedang menimbang…</div></div>}
            </div>

            <div className="semar-composer">
              {files.length > 0 && (
                <div className="semar-files">
                  {files.map((f, i) => (
                    <span key={i} className="semar-file"><FileSpreadsheet size={14} /> {f.name} <small>{f.info}</small>
                      <button type="button" aria-label="Hapus lampiran" onClick={() => setFiles((x) => x.filter((_, j) => j !== i))}><X size={12} /></button></span>
                  ))}
                </div>
              )}
              <div className="semar-input">
                <button type="button" className="icon-btn" title="Lampirkan file (Excel, CSV, PDF, gambar)" onClick={() => fileRef.current?.click()} disabled={busy}><Paperclip size={18} /></button>
                <input ref={fileRef} type="file" hidden multiple accept=".xlsx,.xls,.xlsm,.ods,.csv,.tsv,.txt,.json,.pdf,image/png,image/jpeg,image/webp,image/gif" onChange={(e) => attach(e.target.files)} />
                <textarea rows={1} value={text} placeholder="Tanya Semar…" onChange={(e) => setText(e.target.value)} onKeyDown={onKey} disabled={busy} />
                <button type="button" className="btn-primary" onClick={() => send()} disabled={busy || (!text.trim() && !files.length)} aria-label="Kirim"><Send size={16} /></button>
              </div>
              <div className="semar-hint">Enter kirim · Shift+Enter baris baru · perubahan data selalu minta persetujuan</div>
            </div>
          </>
        )}
      </div>
    </aside>
  );
}

function Message({ row, decisions, previews, acting, onDecide }: {
  row: Row; decisions: Map<string, Record<string, any>>; previews: Map<string, Record<string, any>>; acting: string | null;
  onDecide: (id: string, a: 'execute' | 'reject') => void;
}) {
  if (row.role === 'user') {
    if (row.meta) {
      const st = row.meta.status;
      return <div className={`semar-note ${st}`}>{st === 'executed' ? '✅' : st === 'rejected' ? '✋' : '⚠️'} {row.content[0]?.text?.replace(/^\[Sistem\]\s*/, '')}</div>;
    }
    const texts = row.content.filter((b) => b.type === 'text').map((b) => b.text as string);
    if (!texts.length) return null;   // hasil alat, tidak ditampilkan
    const atts = texts.filter((t) => t.startsWith('[Lampiran')).map((t) => t.split('\n')[0].replace(/^\[|\]$/g, ''));
    const body = texts.filter((t) => !t.startsWith('[Lampiran')).join('\n');
    return (
      <div className="semar-msg me">
        <div className="semar-bubble">
          {atts.map((a) => <div key={a} className="semar-att"><Paperclip size={12} /> {a.replace(/^Lampiran( gambar| PDF)?:\s*/, '')}</div>)}
          {body}
        </div>
      </div>
    );
  }
  return (
    <>
      {row.content.map((b, i) => {
        if (b.type === 'text' && b.text?.trim()) {
          return <div key={i} className="semar-msg ai"><MiniAvatar id="semar" size={30} /><div className="semar-bubble"><MiniMarkdown text={b.text} /></div></div>;
        }
        if (b.type === 'tool_use' && !PROPOSAL_TOOLS.includes(b.name)) {
          const t = b.input?.tabel ?? (b.input?.dari ? `${b.input.dari} s/d ${b.input.sampai}` : undefined);
          return <div key={i} className="semar-tool"><Search size={12} /> {TOOL_LABEL[b.name] ?? b.name}{t ? `: ${Array.isArray(t) ? t.join(', ') : t}` : ''}</div>;
        }
        if (b.type === 'tool_use' && b.name === 'usulkan_perawatan') {
          return <MaintenanceProposal key={i} id={b.id} input={b.input} decision={decisions.get(b.id)} acting={acting === b.id} onDecide={onDecide} />;
        }
        if (b.type === 'tool_use' && b.name === 'usulkan_tugas') {
          return <TaskProposal key={i} id={b.id} input={b.input} decision={decisions.get(b.id)} acting={acting === b.id} onDecide={onDecide} />;
        }
        if (b.type === 'tool_use' && b.name === 'usulkan_po') {
          return <PoProposal key={i} id={b.id} input={b.input} preview={previews.get(b.id)} decision={decisions.get(b.id)} acting={acting === b.id} onDecide={onDecide} />;
        }
        if (b.type === 'tool_use') return <Proposal key={i} id={b.id} input={b.input} decision={decisions.get(b.id)} acting={acting === b.id} onDecide={onDecide} />;
        return null;
      })}
      <div className="semar-time">{formatDateTime(row.created_at)}</div>
    </>
  );
}

function Proposal({ id, input, decision, acting, onDecide }: {
  id: string; input: Record<string, any>; decision?: Record<string, any>; acting: boolean; onDecide: (id: string, a: 'execute' | 'reject') => void;
}) {
  const rows: Record<string, any>[] = Array.isArray(input.baris) ? input.baris : [];
  const cols = [...new Set(rows.slice(0, 20).flatMap((r) => Object.keys(r)))].slice(0, 6);
  const st = decision?.status;
  return (
    <div className={`semar-prop ${input.operasi} ${st ?? 'pending'}`}>
      <div className="semar-prop-head">
        <span className="badge">{OP_LABEL[input.operasi] ?? input.operasi}</span>
        <code>{input.tabel}</code>
        {st === 'executed' && <span className="badge badge-success">Sudah dijalankan</span>}
        {st === 'rejected' && <span className="badge">Ditolak</span>}
        {st === 'failed' && <span className="badge badge-danger">Gagal</span>}
      </div>
      <b>{input.ringkasan}</b>
      {rows.length > 0 && (
        <div className="md-table">
          <table className="table">
            <thead><tr>{cols.map((c) => <th key={c}>{c}</th>)}</tr></thead>
            <tbody>{rows.slice(0, 5).map((r, i) => <tr key={i}>{cols.map((c) => <td key={c}>{String(r[c] ?? '')}</td>)}</tr>)}</tbody>
          </table>
          {rows.length > 5 && <div className="muted small">… dan {rows.length - 5} baris lainnya ({rows.length} total)</div>}
        </div>
      )}
      {input.filter && <div className="small">Untuk data: {input.filter.map((f: any) => `${f.kolom} ${f.op} ${JSON.stringify(f.nilai)}`).join(' dan ')}</div>}
      {input.nilai && <div className="small">Diubah menjadi: {Object.entries(input.nilai).map(([k, v]) => `${k} = ${JSON.stringify(v)}`).join(', ')}</div>}
      {st === 'failed' && <div className="small" style={{ color: 'var(--danger)' }}>{decision?.result?.message}</div>}
      {!st && (
        <div className="semar-prop-actions">
          <button type="button" className="btn-primary btn-sm" disabled={acting} onClick={() => onDecide(id, 'execute')}><Check size={14} /> {acting ? 'Menjalankan…' : 'Setujui & jalankan'}</button>
          <button type="button" className="btn-sm" disabled={acting} onClick={() => onDecide(id, 'reject')}><X size={14} /> Tolak</button>
        </div>
      )}
    </div>
  );
}

// Kartu usulan jadwal perawatan aset dari Semar
function MaintenanceProposal({ id, input, decision, acting, onDecide }: {
  id: string; input: Record<string, any>; decision?: Record<string, any>; acting: boolean; onDecide: (id: string, a: 'execute' | 'reject') => void;
}) {
  const st = decision?.status;
  const plans: Record<string, any>[] = Array.isArray(input.jadwal) ? input.jadwal : [];
  return (
    <div className={`semar-prop task ${st ?? 'pending'}`}>
      <div className="semar-prop-head">
        <span className="badge badge-primary"><Wrench size={12} /> {plans.length} jadwal perawatan</span>
        {st === 'executed' && <span className="badge badge-success">Sudah dibuat</span>}
        {st === 'rejected' && <span className="badge">Ditolak</span>}
        {st === 'failed' && <span className="badge badge-danger">Gagal</span>}
      </div>
      <b>{input.ringkasan}</b>
      <div className="semar-tasks">
        {plans.map((j, i) => (
          <div key={i} className="semar-task">
            <div><b>{j.judul}</b> · {j.aset_nama ?? 'aset'}</div>
            <div className="small">Tiap {j.setiap} {j.satuan} · mulai {j.mulai}{j.untuk_nama && <> · {j.untuk_nama}</>}
              {j.perkiraan_biaya ? <> · ± {formatRupiah(Number(j.perkiraan_biaya))}</> : null}</div>
            {Array.isArray(j.checklist) && j.checklist.length > 0 && <ul className="small">{j.checklist.slice(0, 5).map((c: string, k: number) => <li key={k}>{c}</li>)}</ul>}
          </div>
        ))}
      </div>
      {st === 'executed' && <div className="small">✅ {decision?.result?.message} · <Link to="/assets?tab=maintenance">Buka Perawatan Aset →</Link></div>}
      {st === 'failed' && <div className="small" style={{ color: 'var(--danger)' }}>{decision?.result?.message}</div>}
      {!st && (
        <div className="semar-prop-actions">
          <button type="button" className="btn-primary btn-sm" disabled={acting} onClick={() => onDecide(id, 'execute')}><Check size={14} /> {acting ? 'Menyimpan…' : 'Setujui & buat jadwal'}</button>
          <button type="button" className="btn-sm" disabled={acting} onClick={() => onDecide(id, 'reject')}><X size={14} /> Tolak</button>
        </div>
      )}
    </div>
  );
}

// Kartu usulan tugas untuk tim dari Semar
function TaskProposal({ id, input, decision, acting, onDecide }: {
  id: string; input: Record<string, any>; decision?: Record<string, any>; acting: boolean; onDecide: (id: string, a: 'execute' | 'reject') => void;
}) {
  const st = decision?.status;
  const tasks: Record<string, any>[] = Array.isArray(input.tugas) ? input.tugas : [];
  return (
    <div className={`semar-prop task ${st ?? 'pending'}`}>
      <div className="semar-prop-head">
        <span className="badge badge-primary"><ListTodo size={12} /> {tasks.length} tugas</span>
        {st === 'executed' && <span className="badge badge-success">Sudah dibuat</span>}
        {st === 'rejected' && <span className="badge">Ditolak</span>}
        {st === 'failed' && <span className="badge badge-danger">Gagal</span>}
      </div>
      <b>{input.ringkasan}</b>
      <div className="semar-tasks">
        {tasks.map((t, i) => (
          <div key={i} className="semar-task">
            <div><b>{t.judul}</b> <span className={`badge ${PRIORITY[t.prioritas ?? 'normal']?.[1] ?? ''}`}>{PRIORITY[t.prioritas ?? 'normal']?.[0] ?? t.prioritas}</span></div>
            {t.deskripsi && <div className="small muted">{t.deskripsi}</div>}
            <div className="small">
              Untuk: <b>{t.untuk_nama ?? (t.untuk_user_id || t.untuk_role_id ? 'penerima terpilih' : 'belum ditentukan')}</b>
              {t.tenggat && <> · tenggat {t.tenggat}</>}
              {t.wajib_foto && <> · wajib foto bukti</>}
            </div>
            {Array.isArray(t.checklist) && t.checklist.length > 0 && (
              <ul className="small">{t.checklist.slice(0, 6).map((c: string, j: number) => <li key={j}>{c}</li>)}{t.checklist.length > 6 && <li className="muted">… {t.checklist.length - 6} langkah lagi</li>}</ul>
            )}
          </div>
        ))}
      </div>
      {st === 'executed' && <div className="small">✅ {decision?.result?.message} · <Link to="/tugas">Buka papan Tugas →</Link></div>}
      {st === 'failed' && <div className="small" style={{ color: 'var(--danger)' }}>{decision?.result?.message}</div>}
      {!st && (
        <div className="semar-prop-actions">
          <button type="button" className="btn-primary btn-sm" disabled={acting} onClick={() => onDecide(id, 'execute')}><Check size={14} /> {acting ? 'Membuat tugas…' : 'Setujui & buat tugas'}</button>
          <button type="button" className="btn-sm" disabled={acting} onClick={() => onDecide(id, 'reject')}><X size={14} /> Tolak</button>
        </div>
      )}
    </div>
  );
}

// Kartu usulan Purchase Order dari Semar
function PoProposal({ id, input, preview, decision, acting, onDecide }: {
  id: string; input: Record<string, any>; preview?: Record<string, any>; decision?: Record<string, any>; acting: boolean;
  onDecide: (id: string, a: 'execute' | 'reject') => void;
}) {
  const st = decision?.status;
  const items: Record<string, any>[] = preview?.items ?? (input.items ?? []);
  const total = preview?.total ?? items.reduce((s2, it) => s2 + Number(it.qty ?? 0) * Number(it.harga ?? 0), 0);
  const warn: string[] = preview?.peringatan ?? [];
  return (
    <div className={`semar-prop po ${st ?? 'pending'}`}>
      <div className="semar-prop-head">
        <span className="badge badge-primary"><ShoppingCart size={12} /> Purchase Order</span>
        <span className="badge">{input.ajukan ? 'Langsung diajukan' : 'Draft'}</span>
        {st === 'executed' && <span className="badge badge-success">Sudah dibuat</span>}
        {st === 'rejected' && <span className="badge">Ditolak</span>}
        {st === 'failed' && <span className="badge badge-danger">Gagal</span>}
      </div>
      <b>{input.ringkasan}</b>
      <div className="small">
        <b>{preview?.supplier ?? input.supplier_nama ?? 'Supplier'}</b> → {preview?.gudang ?? input.gudang_nama ?? 'Gudang'}
        {input.tanggal_kirim && <> · kirim {input.tanggal_kirim}</>}
      </div>
      <div className="md-table">
        <table className="table">
          <thead><tr><th>Bahan</th><th className="right">Qty</th><th>Satuan</th><th className="right">Harga</th><th className="right">Subtotal</th></tr></thead>
          <tbody>
            {items.map((it, i) => (
              <tr key={i}>
                <td>{it.nama ?? it.item_id}{it.sumber_harga && <div className="muted" style={{ fontSize: 10.5 }}>{it.sumber_harga}</div>}</td>
                <td className="right">{Number(it.qty).toLocaleString('id-ID')}</td>
                <td>{it.satuan ?? '-'}</td>
                <td className="right">{it.harga != null ? formatRupiah(Number(it.harga)) : 'otomatis'}</td>
                <td className="right">{it.subtotal != null ? formatRupiah(Number(it.subtotal)) : it.harga != null ? formatRupiah(Number(it.qty) * Number(it.harga)) : '-'}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr><td colSpan={4} className="right bold">Total</td><td className="right bold">{formatRupiah(Number(total))}</td></tr></tfoot>
        </table>
      </div>
      {warn.map((w) => <div key={w} className="small" style={{ color: 'var(--warning)' }}>⚠️ {w}</div>)}
      {input.catatan && <div className="small muted">Catatan: {input.catatan}</div>}
      {st === 'executed' && (
        <div className="small">✅ {decision?.result?.message} · <Link to="/purchasing?tab=po">Buka di Pembelian →</Link></div>
      )}
      {st === 'failed' && <div className="small" style={{ color: 'var(--danger)' }}>{decision?.result?.message}</div>}
      {!st && (
        <div className="semar-prop-actions">
          <button type="button" className="btn-primary btn-sm" disabled={acting} onClick={() => onDecide(id, 'execute')}>
            <Check size={14} /> {acting ? 'Membuat PO…' : input.ajukan ? 'Setujui & buat PO' : 'Setujui & simpan draft'}</button>
          <button type="button" className="btn-sm" disabled={acting} onClick={() => onDecide(id, 'reject')}><X size={14} /> Tolak</button>
        </div>
      )}
    </div>
  );
}
