// Uji Edge Function semar-agent dengan Claude palsu & database palsu (tanpa memakai kredit API).
// Jalankan: npm run test:agent
import { handle, LIMITS } from '../../supabase/functions/semar-agent/index.ts';

let passed = 0, failed = 0;
async function check(name, fn) {
  try { await fn(); console.log(`  ✔ ${name}`); passed++; } catch (e) { console.log(`  ✘ ${name}\n      ${e.message}`); failed++; }
}
const assert = (c, m) => { if (!c) throw new Error(m); };
const CONV = '11111111-2222-3333-4444-555555555555';

// ---------------------------------------------------------------- database palsu (meniru supabase-js + RLS sederhana)
function fakeDb({ owner = true, company = 'C1' } = {}) {
  const tables = {
    pur_suppliers: [{ id: 's1', company_id: company, code: 'SUP01', name: 'Toko Lama' }, { id: 's9', company_id: 'C2', code: 'X', name: 'PT Lain' }],
    ai_chat_messages: [],
    pos_orders: [{ id: 'o1', company_id: company, grand_total: 50000 }],
  };
  const info = {
    pur_suppliers: { table: 'pur_suppliers', writable: true, has_company_id: true, columns: [
      { name: 'id', required: false }, { name: 'company_id', required: true }, { name: 'code', required: true }, { name: 'name', required: true }, { name: 'phone', required: false }] },
    pos_orders: { table: 'pos_orders', writable: false, has_company_id: true, columns: [{ name: 'id' }, { name: 'company_id' }, { name: 'grand_total' }] },
  };
  const calls = [];
  // RLS: hanya baris perusahaan sendiri
  const visible = (t) => (tables[t] ?? []).filter((r) => !('company_id' in r) || r.company_id === company);
  function builder(table) {
    const st = { table, op: 'select', filters: [], rows: null, values: null, head: false, limit: null };
    const matches = () => visible(table).filter((r) => st.filters.every(([op, k, v]) => (
      op === 'eq' ? r[k] === v : op === 'ilike' ? String(r[k]).toLowerCase().includes(String(v).replace(/%/g, '').toLowerCase()) : op === 'in' ? v.includes(r[k]) : true)));
    const b = {
      select(_cols, opts = {}) { if (st.op === 'select') st.head = !!opts.head; st.wantRows = true; return b; },
      insert(rows) { st.op = 'insert'; st.rows = rows; return b; },
      update(values) { st.op = 'update'; st.values = values; return b; },
      delete() { st.op = 'delete'; return b; },
      order() { return b; }, limit(n) { st.limit = n; return b; },
      then(resolve) {
        calls.push({ ...st });
        if (st.op === 'insert') {
          for (const r of st.rows) {
            if (table !== 'ai_chat_messages' && r.company_id !== company) return resolve({ data: null, error: { message: 'new row violates row-level security policy' } });
            tables[table] = tables[table] ?? []; tables[table].push({ id: `n${tables[table].length}`, ...r });
          }
          return resolve({ data: st.rows.map((_, i) => ({ id: i })), error: null });
        }
        const rows = matches();
        if (st.op === 'update') { rows.forEach((r) => Object.assign(r, st.values)); return resolve({ data: rows, error: null }); }
        if (st.op === 'delete') { tables[table] = tables[table].filter((r) => !rows.includes(r)); return resolve({ data: rows, error: null }); }
        return resolve({ data: st.head ? null : rows.slice(0, st.limit ?? 1000), count: rows.length, error: null });
      },
    };
    for (const op of ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'ilike', 'in', 'is']) b[op] = (k, v) => { st.filters.push([op, k, v]); return b; };
    return b;
  }
  return {
    tables, calls,
    rpc: async (fn, args) => {
      if (fn === 'sys_get_my_profile') return { data: { user_id: 'U1', company_id: company, company_name: 'Warung Uji', full_name: 'Budi', permissions: owner ? ['*'] : ['pos.order'], outlets: [{ name: 'Pusat' }] }, error: null };
      if (fn === 'ai_recent_usage') return { data: { messages_last_hour: tables.ai_chat_messages.filter((m) => m.role === 'user' && !m.meta).length }, error: null };
      if (fn === 'ai_table_info') {
        const all = Object.values(info);
        return { data: args.p_tables ? all.filter((t) => args.p_tables.includes(t.table)) : all.map(({ columns, ...t }) => t), error: null };
      }
      return { data: null, error: { message: `rpc ${fn}?` } };
    },
    from: builder,
  };
}

// Claude palsu: mengembalikan respons berurutan & merekam permintaan
function fakeClaude(responses) {
  const requests = [];
  const fetchFn = async (_url, init) => {
    requests.push(JSON.parse(init.body));
    const r = responses.shift();
    if (r?.httpError) return { ok: false, status: r.httpError, json: async () => ({ error: { message: r.message ?? 'err' } }) };
    return { ok: true, status: 200, json: async () => ({ usage: { input_tokens: 100, output_tokens: 20 }, ...r }) };
  };
  return { fetchFn, requests };
}
const deps = (db, claude, extra = {}) => ({ db, apiKey: 'sk-test', model: 'claude-sonnet-5-5', fetchFn: claude.fetchFn, ...extra });
const say = (text) => ({ stop_reason: 'end_turn', content: [{ type: 'text', text }] });
const tool = (id, name, input) => ({ stop_reason: 'tool_use', content: [{ type: 'tool_use', id, name, input }] });

console.log('\nAgent Semar (Edge Function):');
await check('bukan owner ditolak, Claude tidak dipanggil', async () => {
  const claude = fakeClaude([say('halo')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'halo' }, deps(fakeDb({ owner: false }), claude));
  assert(r.status === 403 && /owner/.test(r.body.error), JSON.stringify(r));
  assert(claude.requests.length === 0, 'Claude tetap dipanggil');
});
await check('tanpa ANTHROPIC_API_KEY memberi pesan jelas', async () => {
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'halo' }, deps(fakeDb(), fakeClaude([]), { apiKey: undefined }));
  assert(r.status === 500 && /ANTHROPIC_API_KEY/.test(r.body.error), JSON.stringify(r));
});
await check('obrolan biasa tersimpan; system prompt berisi perusahaan & di-cache', async () => {
  const db = fakeDb(), claude = fakeClaude([say('Sugeng rawuh, Juragan Budi')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'cara buat menu?' }, deps(db, claude));
  assert(r.status === 200, JSON.stringify(r));
  const req = claude.requests[0];
  assert(req.model === 'claude-sonnet-5-5' && req.system[0].cache_control && /Warung Uji/.test(req.system[0].text), 'system prompt');
  assert(db.tables.ai_chat_messages.length === 2 && db.tables.ai_chat_messages[1].output_tokens === 20, 'tidak tersimpan');
});
await check('alat baca hanya melihat data perusahaan sendiri', async () => {
  const db = fakeDb(), claude = fakeClaude([tool('t1', 'cari_data', { tabel: 'pur_suppliers' }), say('Ada 1 supplier')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'supplier saya?' }, deps(db, claude));
  const result = claude.requests[1].messages.at(-1).content[0].content;
  assert(/Toko Lama/.test(result) && !/PT Lain/.test(result), result);
});
await check('usulan perubahan TIDAK langsung dijalankan, dikembalikan sebagai pending', async () => {
  const db = fakeDb();
  const claude = fakeClaude([tool('tu_add', 'usulkan_perubahan', { operasi: 'tambah', tabel: 'pur_suppliers', ringkasan: 'Tambah 2 supplier',
    baris: [{ code: 'SUP02', name: 'Pasar Induk' }, { code: 'SUP03', name: 'Toko Sayur', company_id: 'C2' }] }), say('Silakan setujui, Juragan')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'impor supplier' }, deps(db, claude));
  assert(r.body.pending.length === 1 && r.body.pending[0].id === 'tu_add', JSON.stringify(r.body));
  assert(db.tables.pur_suppliers.length === 2, 'data sudah berubah sebelum disetujui!');
});
await check('setujui usulan: company_id dipaksa milik owner & tercatat; tidak bisa dijalankan dua kali', async () => {
  const db = fakeDb();
  const claude = fakeClaude([tool('tu_add', 'usulkan_perubahan', { operasi: 'tambah', tabel: 'pur_suppliers', ringkasan: 'Tambah 2 supplier',
    baris: [{ code: 'SUP02', name: 'Pasar Induk' }, { code: 'SUP03', name: 'Toko Sayur', company_id: 'C2', id: 'paksa' }] }), say('ok')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'impor' }, deps(db, claude));
  const r = await handle({ action: 'execute', conversation_id: CONV, action_id: 'tu_add' }, deps(db, claude));
  assert(r.body.status === 'executed' && r.body.result.count === 2, JSON.stringify(r.body));
  const added = db.tables.pur_suppliers.filter((s) => s.code === 'SUP02' || s.code === 'SUP03');
  assert(added.length === 2 && added.every((s) => s.company_id === 'C1' && s.id !== 'paksa'), JSON.stringify(added));
  assert(db.tables.ai_chat_messages.some((m) => m.meta?.status === 'executed'), 'catatan sistem tidak ada');
  const again = await handle({ action: 'execute', conversation_id: CONV, action_id: 'tu_add' }, deps(db, claude));
  assert(again.status === 409, 'bisa dijalankan dua kali');
});
await check('tabel transaksi tidak boleh diubah; ubah/hapus tanpa filter ditolak', async () => {
  const db = fakeDb();
  const claude = fakeClaude([
    { stop_reason: 'tool_use', content: [
      { type: 'tool_use', id: 'a', name: 'usulkan_perubahan', input: { operasi: 'hapus', tabel: 'pos_orders', filter: [{ kolom: 'id', op: 'eq', nilai: 'o1' }], ringkasan: 'hapus order' } },
      { type: 'tool_use', id: 'b', name: 'usulkan_perubahan', input: { operasi: 'hapus', tabel: 'pur_suppliers', ringkasan: 'hapus semua' } },
      { type: 'tool_use', id: 'c', name: 'usulkan_perubahan', input: { operasi: 'tambah', tabel: 'pur_suppliers', baris: [{ name: 'Tanpa kode' }], ringkasan: 'x' } },
    ] }, say('maaf')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'hapus' }, deps(db, claude));
  assert(r.body.pending.length === 0, 'usulan tidak valid lolos');
  const res = claude.requests[1].messages.at(-1).content.map((b) => b.content).join(' | ');
  assert(/tidak boleh diubah/.test(res) && /wajib memakai filter/.test(res) && /wajib belum diisi: code/.test(res), res);
});
await check('tolak usulan tercatat tanpa mengubah data', async () => {
  const db = fakeDb();
  const claude = fakeClaude([tool('tu_del', 'usulkan_perubahan', { operasi: 'hapus', tabel: 'pur_suppliers', filter: [{ kolom: 'code', op: 'eq', nilai: 'SUP01' }], ringkasan: 'Hapus SUP01' }), say('ok')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'hapus SUP01' }, deps(db, claude));
  const r = await handle({ action: 'reject', conversation_id: CONV, action_id: 'tu_del' }, deps(db, claude));
  assert(r.body.status === 'rejected' && db.tables.pur_suppliers.some((s) => s.code === 'SUP01'), JSON.stringify(r.body));
});
await check(`batas ${LIMITS.messagesPerHour} pesan per jam`, async () => {
  const db = fakeDb();
  for (let i = 0; i < LIMITS.messagesPerHour; i++) db.tables.ai_chat_messages.push({ role: 'user', meta: null });
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'lagi' }, deps(db, fakeClaude([say('x')])));
  assert(r.status === 429, JSON.stringify(r));
});
await check('lampiran gambar dikirim ke Claude tapi tidak disimpan; error kredit habis diterjemahkan', async () => {
  const db = fakeDb(), claude = fakeClaude([say('Ini nota belanja')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'baca nota', attachments: [{ name: 'nota.jpg', kind: 'image', media_type: 'image/jpeg', data: 'QUJD' }] }, deps(db, claude));
  assert(claude.requests[0].messages[0].content[0].type === 'image', 'gambar tidak terkirim');
  assert(!JSON.stringify(db.tables.ai_chat_messages).includes('QUJD'), 'gambar tersimpan di database');
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'x' }, deps(db, fakeClaude([{ httpError: 400, message: 'Your credit balance is too low' }])))
    .catch((e) => ({ error: e.message }));
  assert(/Saldo kredit/.test(r.error), JSON.stringify(r));
});

console.log(`\n${passed} lulus, ${failed} gagal\n`);
process.exit(failed ? 1 : 0);
