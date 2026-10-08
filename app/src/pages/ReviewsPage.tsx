import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, Download, MessageSquareText, Phone, Plus, Star, Trash2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useFeedback } from '../components/Feedback';
import Modal from '../components/Modal';
import { must, rpc, supabase } from '../lib/supabase';
import { errorMessage, formatDateTime } from '../lib/format';
import { useTabParam } from '../lib/useTabParam';
import { downloadXlsx } from '../lib/excel';
import { addDays, localDate } from '../lib/hr';

/* eslint-disable @typescript-eslint/no-explicit-any */
type Tab = 'summary' | 'list' | 'form';
const KINDS: Record<string, string> = { stars: 'Bintang 1–5', aspects: 'Nilai beberapa aspek', nps: 'Rekomendasi 0–10 (NPS)', choice: 'Pilihan (boleh banyak)', text: 'Isian teks' };
const STATUS: Record<string, [string, string]> = { new: ['Baru', 'badge-warning'], followed_up: ['Ditindaklanjuti', 'badge-info'], resolved: ['Selesai', 'badge-success'] };
const stars = (n: number | null) => (n ? '★'.repeat(n) + '☆'.repeat(5 - n) : '—');

// Ulasan pelanggan dari QR struk: analisa, daftar & tindak lanjut, atur pertanyaan form
export default function ReviewsPage() {
  const { can } = useAuth();
  const { toast } = useFeedback();
  const canManage = can('feedback.manage');
  const [tab, setTab] = useTabParam<Tab>('summary', canManage ? ['summary', 'list', 'form'] : ['summary', 'list']);
  const [from, setFrom] = useState(() => addDays(localDate(), -29));
  const [to, setTo] = useState(localDate());
  const [outletId, setOutletId] = useState('');
  const [outlets, setOutlets] = useState<{ id: string; name: string }[]>([]);
  const [sum, setSum] = useState<any | null>(null);
  const [list, setList] = useState<any[]>([]);
  const [filter, setFilter] = useState('all');
  const [questions, setQuestions] = useState<any[]>([]);
  const [follow, setFollow] = useState<any | null>(null);

  useEffect(() => { must(supabase.from('sys_outlets').select('id, name').eq('is_active', true).order('name')).then(setOutlets).catch(() => undefined); }, []);
  const load = useCallback(async () => {
    const args = { p_from: from, p_to: to, p_outlet_id: outletId || null };
    const [s, l, q] = await Promise.all([rpc<any>('crm_feedback_summary', args), rpc<any[]>('crm_feedback_list', { ...args, p_filter: filter }),
      must(supabase.from('crm_feedback_questions').select('*').order('sort_order'))]);
    setSum(s);
    setList(l);
    setQuestions(q);
    window.dispatchEvent(new Event('feedback-changed'));
  }, [from, to, outletId, filter]);
  useEffect(() => { load().catch((e) => toast(errorMessage(e), 'error')); }, [load, toast]);

  const qLabel = (id: string) => questions.find((q) => q.id === id);
  const rate = sum?.paid_orders ? Math.round((sum.responses / sum.paid_orders) * 1000) / 10 : null;
  const saveFollow = async () => {
    try { await rpc('crm_feedback_update', { p_id: follow.id, p_status: follow.status, p_note: follow.note }); setFollow(null); load(); } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const exportXlsx = () => downloadXlsx(`ulasan-${from}-sd-${to}`, [{ name: 'Ulasan', widths: [18, 18, 8, 6, 40, 16, 16, 14],
    rows: list.map((r) => ({ Tanggal: formatDateTime(r.created_at), Outlet: r.outlet ?? '', Bintang: r.overall ?? '', NPS: r.nps ?? '', Komentar: r.comment ?? '',
      Nama: r.contact_name ?? '', WhatsApp: r.contact_ok ? r.contact_phone ?? '' : '', Status: STATUS[r.status][0] })) }]);

  return (
    <>
      <div className="page-header">
        <div><h1>Ulasan Pelanggan</h1><p>Dari QR di struk: rating, rekomendasi (NPS), saran & tindak lanjut.</p></div>
      </div>
      <div className="tabs">
        <button className={tab === 'summary' ? 'active' : ''} onClick={() => setTab('summary')}>Ringkasan</button>
        <button className={tab === 'list' ? 'active' : ''} onClick={() => setTab('list')}>Ulasan {sum?.negative_open > 0 && <span className="badge badge-danger">{sum.negative_open}</span>}</button>
        {canManage && <button className={tab === 'form' ? 'active' : ''} onClick={() => setTab('form')}>Form & pertanyaan</button>}
      </div>

      {tab !== 'form' && (
        <div className="task-toolbar">
          <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
            <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /><span className="muted">s/d</span>
            <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} />
            {outlets.length > 1 && <select value={outletId} onChange={(e) => setOutletId(e.target.value)}><option value="">Semua outlet</option>{outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select>}
          </div>
        </div>
      )}

      {tab === 'summary' && sum && (
        <>
          <div className="rv-kpis">
            <div className="card rv-kpi"><small className="muted">Rata-rata bintang</small><b>{sum.avg_overall ?? '—'}<Star size={18} fill="#F7B733" color="#F7B733" /></b><span className="muted small">{sum.responses} ulasan</span></div>
            <div className="card rv-kpi"><small className="muted">NPS</small><b className={Number(sum.nps) >= 30 ? 'text-success' : Number(sum.nps) < 0 ? 'text-danger' : ''}>{sum.nps ?? '—'}</b><span className="muted small">{sum.nps_count} jawaban · -100 s/d 100</span></div>
            <div className="card rv-kpi"><small className="muted">Tingkat respons</small><b>{rate != null ? `${rate}%` : '—'}</b><span className="muted small">dari {sum.paid_orders} struk</span></div>
            <div className="card rv-kpi"><small className="muted">Ulasan buruk belum ditangani</small><b className={sum.negative_open ? 'text-danger' : ''}>{sum.negative_open}</b>
              <button className="btn-sm" onClick={() => { setFilter('open'); setTab('list'); }}>Lihat</button></div>
          </div>
          <div className="grid grid-2">
            <div className="card">
              <h3 style={{ marginTop: 0 }}>Sebaran bintang</h3>
              {[5, 4, 3, 2, 1].map((s) => {
                const n = Number(sum.overall_dist?.[s] ?? 0);
                return <div key={s} className="rv-bar"><span>{s}★</span><div><i style={{ width: `${sum.responses ? (n / sum.responses) * 100 : 0}%`, background: s >= 4 ? '#1f9d6b' : s === 3 ? '#F7B733' : '#FC4A1A' }} /></div><b>{n}</b></div>;
              })}
            </div>
            <div className="card">
              <h3 style={{ marginTop: 0 }}>Tren mingguan</h3>
              {!sum.trend.length && <p className="muted">Belum ada data.</p>}
              <div className="rv-trend">
                {sum.trend.map((t: any) => (
                  <div key={t.week} title={`${t.count} ulasan`}>
                    <i style={{ height: `${(Number(t.avg ?? 0) / 5) * 100}%` }} />
                    <b>{t.avg ?? '—'}</b>
                    <small>{new Date(`${t.week}T00:00:00Z`).toLocaleDateString('id-ID', { day: 'numeric', month: 'short', timeZone: 'UTC' })}</small>
                  </div>
                ))}
              </div>
            </div>
            {sum.questions.filter((q: any) => q.kind === 'aspects' || q.kind === 'choice').map((q: any) => {
              const entries = Object.entries(q.stats ?? {}) as [string, any][];
              const max = Math.max(1, ...entries.map(([, v]) => (q.kind === 'choice' ? Number(v) : Number(v?.avg ?? 0))));
              return (
                <div key={q.id} className="card">
                  <h3 style={{ marginTop: 0 }}>{q.label}</h3>
                  {entries.sort((a, b) => (q.kind === 'choice' ? Number(b[1]) - Number(a[1]) : Number(b[1]?.avg ?? 0) - Number(a[1]?.avg ?? 0))).map(([k, v]) => {
                    const val = q.kind === 'choice' ? Number(v) : Number(v?.avg ?? 0);
                    return <div key={k} className="rv-bar wide"><span>{k}</span><div><i style={{ width: `${(val / (q.kind === 'choice' ? max : 5)) * 100}%`, background: q.kind === 'choice' ? '#4ABDAC' : val >= 4 ? '#1f9d6b' : val >= 3 ? '#F7B733' : '#FC4A1A' }} /></div>
                      <b>{q.kind === 'choice' ? val : val ? val.toFixed(1) : '—'}</b></div>;
                  })}
                </div>
              );
            })}
            {sum.outlets.length > 1 && (
              <div className="card table-wrap">
                <h3 style={{ marginTop: 0 }}>Per outlet</h3>
                <table className="table"><thead><tr><th>Outlet</th><th className="right">Ulasan</th><th className="right">Bintang</th><th className="right">NPS</th></tr></thead>
                  <tbody>{sum.outlets.map((o: any, i: number) => <tr key={i}><td>{o.outlet ?? '—'}</td><td className="right">{o.count}</td><td className="right">{o.avg ?? '—'}</td><td className="right">{o.nps ?? '—'}</td></tr>)}</tbody></table>
              </div>
            )}
          </div>
          <p className="muted small">NPS = % pemberi nilai 9–10 dikurangi % pemberi nilai 0–6. Di atas 30 = baik, di atas 50 = sangat baik.</p>
        </>
      )}

      {tab === 'list' && (
        <div className="card">
          <div className="card-header roster-head">
            <div className="seg">
              {([['all', 'Semua'], ['open', 'Perlu tindak lanjut'], ['negative', '≤ 2★'], ['positive', '≥ 4★'], ['comment', 'Ada saran']] as [string, string][]).map(([k, l]) => (
                <button key={k} className={filter === k ? 'active' : ''} onClick={() => setFilter(k)}>{l}</button>
              ))}
            </div>
            <button className="btn-sm" disabled={!list.length} onClick={exportXlsx}><Download size={14} /> Excel</button>
          </div>
          <div className="rv-list">
            {list.map((r) => (
              <article key={r.id} className={`rv-item ${r.overall != null && r.overall <= 2 ? 'neg' : r.overall >= 4 ? 'pos' : ''}`}>
                <header>
                  <span className="rv-stars">{stars(r.overall)}</span>
                  {r.nps != null && <span className="badge">NPS {r.nps}</span>}
                  <span className={`badge ${STATUS[r.status][1]}`}>{STATUS[r.status][0]}</span>
                  <span className="muted small" style={{ marginLeft: 'auto' }}>{formatDateTime(r.created_at)} · {r.outlet ?? '—'} · {r.order_number}</span>
                </header>
                {r.comment && <p className="rv-comment"><MessageSquareText size={14} /> {r.comment}</p>}
                <div className="rv-answers">
                  {Object.entries(r.answers ?? {}).map(([qid, v]: [string, any]) => {
                    const q = qLabel(qid);
                    if (!q || q.kind === 'text' || q.is_overall || q.kind === 'nps') return null;
                    return <span key={qid}>{q.kind === 'aspects' ? Object.entries(v).map(([a, s]) => `${a} ${s}★`).join(' · ') : q.kind === 'choice' ? `Suka: ${(v as string[]).join(', ')}` : `${q.label}: ${v}★`}</span>;
                  })}
                </div>
                <footer>
                  {r.contact_name || r.contact_phone ? <span className="small">{r.contact_name ?? 'Tanpa nama'}{r.contact_ok && r.contact_phone ? <> · <a href={`https://wa.me/${r.contact_phone.replace(/^0/, '62').replace(/^\+/, '')}`} target="_blank" rel="noreferrer"><Phone size={12} /> {r.contact_phone}</a></> : ' · tidak bersedia dihubungi'}</span> : <span className="muted small">Anonim</span>}
                  {r.follow_note && <span className="muted small">Catatan: {r.follow_note}{r.handler ? ` (${r.handler})` : ''}</span>}
                  {canManage && <button className="btn-sm" onClick={() => setFollow({ id: r.id, status: r.status === 'new' ? 'followed_up' : r.status, note: '' })}>Tindak lanjut</button>}
                </footer>
              </article>
            ))}
            {!list.length && <div className="empty">Belum ada ulasan di rentang ini.</div>}
          </div>
        </div>
      )}

      {tab === 'form' && canManage && <FormSettings questions={questions} onChanged={load} />}

      {follow && (
        <Modal title="Tindak lanjut ulasan" onClose={() => setFollow(null)}
          footer={<><button onClick={() => setFollow(null)}>Batal</button><button className="btn-primary" onClick={saveFollow}>Simpan</button></>}>
          <label className="field"><span>Status</span>
            <select value={follow.status} onChange={(e) => setFollow({ ...follow, status: e.target.value })}>{Object.entries(STATUS).map(([k, v]) => <option key={k} value={k}>{v[0]}</option>)}</select></label>
          <label className="field" style={{ marginTop: 10 }}><span>Catatan</span><textarea rows={3} value={follow.note} placeholder="mis. Sudah ditelepon, diberi voucher minuman" onChange={(e) => setFollow({ ...follow, note: e.target.value })} /></label>
        </Modal>
      )}
    </>
  );
}

function FormSettings({ questions, onChanged }: { questions: any[]; onChanged: () => void }) {
  const { profile } = useAuth();
  const { toast, confirm } = useFeedback();
  const [set, setSet] = useState<any | null>(null);
  const [edit, setEdit] = useState<any | null>(null);
  useEffect(() => { must(supabase.from('crm_feedback_settings').select('*').maybeSingle()).then((s) => setSet(s ?? { is_enabled: true, ask_contact: true, max_days: 14, title: '', intro: '', thank_you: '' })).catch(() => undefined); }, []);
  const sorted = useMemo(() => [...questions].sort((a, b) => a.sort_order - b.sort_order), [questions]);

  const saveSettings = async () => {
    try {
      await must(supabase.from('crm_feedback_settings').upsert({ company_id: profile!.company_id, is_enabled: set.is_enabled, title: set.title, intro: set.intro, thank_you: set.thank_you,
        incentive_text: set.incentive_text || null, ask_contact: set.ask_contact, max_days: Number(set.max_days), updated_at: new Date().toISOString() }));
      toast('Pengaturan form disimpan', 'success');
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const save = async () => {
    try {
      const options = String(edit.optionsText ?? '').split('\n').map((s: string) => s.trim()).filter(Boolean);
      const v = { kind: edit.kind, label: edit.label?.trim(), help: edit.help || null, options: ['aspects', 'choice'].includes(edit.kind) ? options : [],
        required: !!edit.required, is_overall: edit.kind === 'stars' && !!edit.is_overall, is_active: edit.is_active !== false, updated_at: new Date().toISOString() };
      if (!v.label) throw new Error('Pertanyaan wajib diisi');
      if (['aspects', 'choice'].includes(v.kind) && !v.options.length) throw new Error('Isi minimal satu pilihan / aspek');
      if (edit.id) await must(supabase.from('crm_feedback_questions').update(v).eq('id', edit.id));
      else await must(supabase.from('crm_feedback_questions').insert({ ...v, company_id: profile!.company_id, sort_order: (sorted.at(-1)?.sort_order ?? 0) + 10 }));
      setEdit(null);
      onChanged();
    } catch (e) { toast(errorMessage(e), 'error'); }
  };
  const move = async (i: number, d: -1 | 1) => {
    const a = sorted[i], b = sorted[i + d];
    if (!b) return;
    await must(supabase.from('crm_feedback_questions').update({ sort_order: b.sort_order }).eq('id', a.id));
    await must(supabase.from('crm_feedback_questions').update({ sort_order: a.sort_order }).eq('id', b.id));
    onChanged();
  };
  const remove = async (q: any) => {
    if (!(await confirm({ title: 'Nonaktifkan pertanyaan?', message: 'Jawaban lama tetap tersimpan. Pertanyaan tidak tampil lagi di form.', danger: true }))) return;
    await must(supabase.from('crm_feedback_questions').update({ is_active: false }).eq('id', q.id));
    onChanged();
  };

  return (
    <div className="grid grid-2" style={{ alignItems: 'start' }}>
      <div className="card">
        <div className="card-header"><h2>Pertanyaan</h2><button className="btn-sm btn-primary" onClick={() => setEdit({ kind: 'stars', label: '', optionsText: '', required: false, is_active: true })}><Plus size={14} /> Pertanyaan</button></div>
        <p className="muted small" style={{ marginTop: 0 }}>Tips riset: maksimal ±5 layar (&lt; 1 menit), satu pertanyaan per layar, hanya rating utama yang wajib.</p>
        {sorted.map((q, i) => (
          <div key={q.id} className={`rv-qrow ${q.is_active ? '' : 'off'}`}>
            <div className="rv-qmove"><button className="btn-sm" disabled={i === 0} onClick={() => move(i, -1)} aria-label="Naik"><ArrowUp size={12} /></button><button className="btn-sm" disabled={i === sorted.length - 1} onClick={() => move(i, 1)} aria-label="Turun"><ArrowDown size={12} /></button></div>
            <div style={{ flex: 1 }}>
              <b>{q.label}</b>{q.required && <span className="text-danger"> *</span>}
              <div className="muted small">{KINDS[q.kind]}{q.is_overall ? ' · rating utama' : ''}{q.options?.length ? ` · ${q.options.join(', ')}` : ''}{!q.is_active ? ' · nonaktif' : ''}</div>
            </div>
            <button className="btn-sm" onClick={() => setEdit({ ...q, optionsText: (q.options ?? []).join('\n') })}>Edit</button>
            {q.is_active && <button className="btn-sm" onClick={() => remove(q)} aria-label="Nonaktifkan"><Trash2 size={13} /></button>}
          </div>
        ))}
      </div>
      {set && (
        <div className="card">
          <h2 style={{ marginTop: 0 }}>Pengaturan form</h2>
          <label className="row"><input type="checkbox" checked={set.is_enabled} onChange={(e) => setSet({ ...set, is_enabled: e.target.checked })} /> Form aktif & QR tampil di struk</label>
          <div className="form-grid" style={{ marginTop: 10 }}>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Judul</span><input value={set.title} onChange={(e) => setSet({ ...set, title: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Pembuka</span><input value={set.intro} onChange={(e) => setSet({ ...set, intro: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Ucapan terima kasih</span><input value={set.thank_you} onChange={(e) => setSet({ ...set, thank_you: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Hadiah / insentif (opsional)</span><input value={set.incentive_text ?? ''} placeholder="mis. Tunjukkan layar ini: gratis es teh di kunjungan berikutnya" onChange={(e) => setSet({ ...set, incentive_text: e.target.value })} />
              <small className="muted">Beri hadiah untuk <b>semua</b> yang mengisi (bukan hanya ulasan bagus) supaya ulasan tetap jujur.</small></label>
            <label className="field"><span>Berlaku (hari setelah transaksi)</span><input type="number" min={1} max={90} value={set.max_days} onChange={(e) => setSet({ ...set, max_days: e.target.value })} /></label>
            <label className="row" style={{ alignSelf: 'end' }}><input type="checkbox" checked={set.ask_contact} onChange={(e) => setSet({ ...set, ask_contact: e.target.checked })} /> Tanya kontak (opsional)</label>
          </div>
          <div className="row" style={{ justifyContent: 'flex-end', marginTop: 10 }}><button className="btn-primary" onClick={saveSettings}>Simpan</button></div>
          <p className="muted small">Link Google Maps (muncul untuk pemberi 4–5 bintang) & teks struk diatur per outlet di <b>Pengaturan → Outlet</b>.</p>
        </div>
      )}

      {edit && (
        <Modal title={edit.id ? 'Edit pertanyaan' : 'Pertanyaan baru'} onClose={() => setEdit(null)}
          footer={<><button onClick={() => setEdit(null)}>Batal</button><button className="btn-primary" onClick={save}>Simpan</button></>}>
          <div className="form-grid">
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Jenis</span>
              <select value={edit.kind} disabled={!!edit.id} onChange={(e) => setEdit({ ...edit, kind: e.target.value })}>{Object.entries(KINDS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
              {edit.id && <small className="muted">Jenis tidak bisa diubah supaya analisa jawaban lama tetap benar.</small>}</label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Pertanyaan</span><input value={edit.label} onChange={(e) => setEdit({ ...edit, label: e.target.value })} /></label>
            <label className="field" style={{ gridColumn: '1 / -1' }}><span>Keterangan kecil (opsional)</span><input value={edit.help ?? ''} onChange={(e) => setEdit({ ...edit, help: e.target.value })} /></label>
            {['aspects', 'choice'].includes(edit.kind) && (
              <label className="field" style={{ gridColumn: '1 / -1' }}><span>{edit.kind === 'aspects' ? 'Aspek yang dinilai' : 'Pilihan'} (satu per baris)</span>
                <textarea rows={5} value={edit.optionsText} onChange={(e) => setEdit({ ...edit, optionsText: e.target.value })} /></label>
            )}
          </div>
          <div className="grid" style={{ marginTop: 8 }}>
            <label className="row"><input type="checkbox" checked={!!edit.required} onChange={(e) => setEdit({ ...edit, required: e.target.checked })} /> Wajib dijawab</label>
            {edit.kind === 'stars' && <label className="row"><input type="checkbox" checked={!!edit.is_overall} onChange={(e) => setEdit({ ...edit, is_overall: e.target.checked })} /> Rating utama (dipakai di ringkasan & otomatis lanjut)</label>}
            {edit.id && <label className="row"><input type="checkbox" checked={edit.is_active !== false} onChange={(e) => setEdit({ ...edit, is_active: e.target.checked })} /> Aktif</label>}
          </div>
        </Modal>
      )}
    </div>
  );
}
