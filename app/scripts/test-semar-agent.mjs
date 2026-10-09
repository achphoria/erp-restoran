// Uji Edge Function semar-agent dengan Claude palsu & database palsu (tanpa memakai kredit API).
// Jalankan: npm run test:agent
import { handle, LIMITS, modulesNote } from '../../supabase/functions/semar-agent/index.ts';

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
      if (fn === 'ai_purchase_forecast') {
        calls.push({ rpc: fn, args });
        return { data: { periode_data_hari: args.p_days, items: [{ nama: 'Susu UHT', stok: 2, pemakaian_per_hari: 1.5, cukup_untuk_hari: 1.3, saran_beli: 9 }] }, error: null };
      }
      if (fn === 'ai_create_purchase_order') {
        calls.push({ rpc: fn, args });
        if (!args.p.items?.length) return { data: null, error: { message: 'Item PO masih kosong' } };
        if (args.p_dry_run) return { data: { supplier: 'CV Susu', gudang: 'Gudang Pusat', items: [{ nama: 'Susu UHT', qty: 10, harga: 18000, subtotal: 180000 }], total: 180000 }, error: null };
        tables.pur_purchase_orders = [...(tables.pur_purchase_orders ?? []), { id: 'po1', company_id: company }];
        return { data: { id: 'po1', po_number: args.p.submit ? 'PO/OUT01/0001' : null, status: args.p.submit ? 'disetujui' : 'draft', total: 180000 }, error: null };
      }
      if (fn === 'ai_business_brief' || fn === 'ai_feedback_insights' || fn === 'ai_hr_recap') {
        calls.push({ rpc: fn, args });
        return { data: fn === 'ai_business_brief' ? { penjualan: { hari_ini: { omzet: 1200000 } }, sdm: { belum_absen: [{ nama: 'Andi' }] } } : [{ nama: 'Andi', telat: 2 }], error: null };
      }
      if (fn === 'hr_task_people') return { data: { users: [{ id: 'u-andi', full_name: 'Andi', role: 'Kasir' }], roles: [{ id: 'r-kasir', name: 'Kasir' }] }, error: null };
      if (fn === 'ai_asset_insights') {
        calls.push({ rpc: fn, args });
        return { data: { ringkasan: { aktif: 2 }, aset: [{ id: 'a-ac', kode: 'AST-MSN-0001', nama: 'AC split', biaya_perawatan_12_bulan: 850000 }] }, error: null };
      }
      if (fn === 'ast_list') return { data: [{ id: 'a-ac', asset_number: 'AST-MSN-0001', name: 'AC split' }], error: null };
      if (fn === 'ast_save_plan') {
        calls.push({ rpc: fn, args });
        tables.ast_maintenance_plans = [...(tables.ast_maintenance_plans ?? []), { company_id: company, ...args.p }];
        return { data: { id: 'pl1' }, error: null };
      }
      if (fn === 'hr_task_save') {
        calls.push({ rpc: fn, args });
        tables.hr_tasks = [...(tables.hr_tasks ?? []), { id: `t${(tables.hr_tasks ?? []).length}`, company_id: company, ...args.p }];
        return { data: { task_number: `TSK-000${tables.hr_tasks.length}` }, error: null };
      }
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

await check('forecast kebutuhan beli memanggil fungsi database dengan parameter', async () => {
  const db = fakeDb();
  const claude = fakeClaude([tool('f1', 'analisa_kebutuhan_beli', { hari_data: 30, cukup_hari: 10 }), say('Susu UHT hanya cukup 1 hari')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'bahan apa yang perlu dibeli?' }, deps(db, claude));
  const call = db.calls.find((c) => c.rpc === 'ai_purchase_forecast');
  assert(call && call.args.p_days === 30 && call.args.p_cover_days === 10, JSON.stringify(call));
  assert(/Susu UHT/.test(claude.requests[1].messages.at(-1).content[0].content), 'hasil tidak dikirim ke Claude');
});
await check('usulan PO: diuji coba (dry run) dulu, belum dibuat sampai disetujui, lalu dibuat & diajukan', async () => {
  const db = fakeDb();
  const input = { supplier_id: 'sup1', supplier_nama: 'CV Susu', gudang_id: 'wh1', gudang_nama: 'Gudang Pusat', ajukan: true,
    items: [{ item_id: 'it1', nama: 'Susu UHT', qty: 10 }], ringkasan: 'PO susu ke CV Susu' };
  const claude = fakeClaude([tool('po_1', 'usulkan_po', input), say('Silakan cek usulan PO, Juragan')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'buatkan PO susu' }, deps(db, claude));
  assert(r.body.pending.length === 1 && r.body.pending[0].kind === 'po' && r.body.pending[0].preview.total === 180000, JSON.stringify(r.body.pending));
  const dry = db.calls.find((c) => c.rpc === 'ai_create_purchase_order');
  assert(dry.args.p_dry_run === true && dry.args.p.warehouse_id === 'wh1' && dry.args.p.submit === true, JSON.stringify(dry.args));
  assert(!(db.tables.pur_purchase_orders ?? []).length, 'PO dibuat sebelum disetujui!');
  assert(/PRATINJAU/.test(claude.requests[1].messages.at(-1).content[0].content), 'pratinjau tidak dikirim ke Claude');
  const ex = await handle({ action: 'execute', conversation_id: CONV, action_id: 'po_1' }, deps(db, claude));
  assert(ex.body.status === 'executed' && /PO\/OUT01\/0001/.test(ex.body.result.message), JSON.stringify(ex.body));
  assert((db.tables.pur_purchase_orders ?? []).length === 1, 'PO tidak dibuat');
  assert(db.calls.filter((c) => c.rpc === 'ai_create_purchase_order').at(-1).args.p_dry_run === false, 'eksekusi masih dry run');
});
await check('usulan PO yang tidak valid ditolak sistem sebelum sampai ke owner', async () => {
  const db = fakeDb();
  const claude = fakeClaude([tool('po_x', 'usulkan_po', { supplier_id: 's', gudang_id: 'w', items: [], ringkasan: 'kosong' }), say('maaf')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'po' }, deps(db, claude));
  assert(r.body.pending.length === 0, 'usulan kosong lolos');
  assert(/Item PO masih kosong/.test(claude.requests[1].messages.at(-1).content[0].content), 'error tidak diteruskan ke Claude');
});

await check('briefing harian: ringkasan_bisnis memanggil ai_business_brief dengan periode', async () => {
  const db = fakeDb(), claude = fakeClaude([tool('b1', 'ringkasan_bisnis', { hari: 14 }), say('Omzet hari ini Rp1,2 jt. Saran: ...')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'ringkasan hari ini' }, deps(db, claude));
  assert(r.status === 200, JSON.stringify(r.body));
  assert(db.calls.find((c) => c.rpc === 'ai_business_brief')?.args.p_days === 14, 'periode tidak diteruskan');
  assert(/1200000/.test(claude.requests[1].messages.at(-1).content[0].content), 'hasil briefing tidak dikirim ke Claude');
  assert(/ringkasan_bisnis/.test(claude.requests[0].system) || claude.requests[0].tools.some((t) => t.name === 'ringkasan_bisnis'), 'alat tidak tersedia');
});
await check('analisa_ulasan & rekap_sdm meneruskan rentang tanggal', async () => {
  const db = fakeDb(), claude = fakeClaude([tool('a1', 'analisa_ulasan', { dari: '2026-10-01', sampai: '2026-10-09' }), tool('a2', 'rekap_sdm', { dari: '2026-10-01', sampai: '2026-10-07' }), say('ok')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'ulasan & absensi' }, deps(db, claude));
  const f = db.calls.find((c) => c.rpc === 'ai_feedback_insights'), h = db.calls.find((c) => c.rpc === 'ai_hr_recap');
  assert(f?.args.p_from === '2026-10-01' && f.args.p_to === '2026-10-09', JSON.stringify(f));
  assert(h?.args.p_to === '2026-10-07', JSON.stringify(h));
});
await check('usulan tugas: menunggu persetujuan, lalu dibuat lewat hr_task_save', async () => {
  const db = fakeDb();
  const input = { ringkasan: '2 tugas dari ulasan', tugas: [
    { judul: 'Bersihkan meja lebih sering', untuk_role_id: 'r-kasir', untuk_nama: 'Tim Kasir', prioritas: 'high', tenggat: '2026-10-12', checklist: ['Lap meja tiap 30 menit'], wajib_foto: true },
    { judul: 'Cek waktu saji', untuk_user_id: 'u-andi', untuk_role_id: 'r-kasir' }] };
  const claude = fakeClaude([tool('tk_1', 'usulkan_tugas', input), say('Silakan cek usulan tugas')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'buatkan tugas' }, deps(db, claude));
  assert(r.body.pending.length === 1 && r.body.pending[0].kind === 'task', JSON.stringify(r.body.pending));
  assert(!(db.tables.hr_tasks ?? []).length, 'tugas dibuat sebelum disetujui!');
  const ex = await handle({ action: 'execute', conversation_id: CONV, action_id: 'tk_1' }, deps(db, claude));
  assert(ex.body.status === 'executed' && /2 tugas dibuat: TSK-0001, TSK-0002/.test(ex.body.result.message), JSON.stringify(ex.body));
  const [a, b] = db.tables.hr_tasks;
  assert(a.assignee_role_id === 'r-kasir' && a.assignee_id === null && a.priority === 'high' && a.due_date === '2026-10-12' && a.requires_photo === true, JSON.stringify(a));
  assert(a.checklist[0].text === 'Lap meja tiap 30 menit' && a.checklist[0].done === false, 'checklist salah');
  assert(b.assignee_id === 'u-andi' && b.assignee_role_id === null && b.priority === 'normal', JSON.stringify(b));
});
await check('usulan tugas dengan penerima karangan ditolak sistem', async () => {
  const db = fakeDb();
  const claude = fakeClaude([tool('tk_x', 'usulkan_tugas', { ringkasan: 'x', tugas: [{ judul: 'Tes', untuk_user_id: 'u-palsu' }] }), say('maaf')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'tugas' }, deps(db, claude));
  assert(r.body.pending.length === 0, 'penerima palsu lolos');
  assert(/penerima tidak ditemukan/.test(claude.requests[1].messages.at(-1).content[0].content), 'error tidak diteruskan');
});

await check('analisa_aset memanggil ai_asset_insights dan hasilnya sampai ke Claude', async () => {
  const db = fakeDb(), claude = fakeClaude([tool('as1', 'analisa_aset', {}), say('AC split biaya servis tinggi')]);
  await handle({ action: 'chat', conversation_id: CONV, text: 'aset mana yang bermasalah?' }, deps(db, claude));
  assert(db.calls.some((c) => c.rpc === 'ai_asset_insights'), 'rpc tidak dipanggil');
  assert(/850000/.test(claude.requests[1].messages.at(-1).content[0].content), 'hasil tidak diteruskan');
  assert(/Aset & perawatan/.test(claude.requests[0].system[0].text), 'panduan aset tidak ada di prompt');
});
await check('usulan jadwal perawatan: menunggu persetujuan, lalu dibuat lewat ast_save_plan; aset karangan ditolak', async () => {
  const db = fakeDb();
  const input = { ringkasan: 'Servis rutin AC', jadwal: [{ asset_id: 'a-ac', aset_nama: 'AC split', judul: 'Service AC', setiap: 3, satuan: 'bulan',
    mulai: '2026-11-01', untuk_role_id: 'r-kasir', checklist: ['Cuci filter'], perkiraan_biaya: 150000 }] };
  const claude = fakeClaude([tool('mp_1', 'usulkan_perawatan', input), say('Silakan cek jadwal')]);
  const r = await handle({ action: 'chat', conversation_id: CONV, text: 'buatkan jadwal servis AC' }, deps(db, claude));
  assert(r.body.pending.length === 1 && r.body.pending[0].kind === 'maintenance', JSON.stringify(r.body.pending));
  assert(!(db.tables.ast_maintenance_plans ?? []).length, 'jadwal dibuat sebelum disetujui!');
  const ex = await handle({ action: 'execute', conversation_id: CONV, action_id: 'mp_1' }, deps(db, claude));
  assert(ex.body.status === 'executed' && /1 jadwal perawatan dibuat/.test(ex.body.result.message), JSON.stringify(ex.body));
  const pl = db.tables.ast_maintenance_plans[0];
  assert(pl.interval_unit === 'month' && pl.interval_value === 3 && pl.assignee_role_id === 'r-kasir' && pl.next_due_date === '2026-11-01' && pl.estimated_cost === 150000, JSON.stringify(pl));
  const db2 = fakeDb(), claude2 = fakeClaude([tool('mp_x', 'usulkan_perawatan', { ringkasan: 'x', jadwal: [{ ...input.jadwal[0], asset_id: 'a-palsu' }] }), say('maaf')]);
  const r2 = await handle({ action: 'chat', conversation_id: CONV, text: 'jadwal' }, deps(db2, claude2));
  assert(r2.body.pending.length === 0 && /aset tidak ditemukan/.test(claude2.requests[1].messages.at(-1).content[0].content), 'aset palsu lolos');
});

await check('prompt Semar menyebut modul aktif & tidak aktif (Pengaturan → Modul)', async () => {
  assert(modulesNote({}) === 'Semua modul aplikasi aktif.', 'tanpa info modul = semua aktif');
  const n = modulesNote({ modules: { enabled: ['pos', 'inventory'] } });
  assert(/Modul aktif: Kasir \(POS\), Stok & gudang/.test(n) && /TIDAK aktif.*SDM & absensi/.test(n) && /Pengaturan → Modul/.test(n), n);
});

console.log(`\n${passed} lulus, ${failed} gagal\n`);
process.exit(failed ? 1 : 0);
