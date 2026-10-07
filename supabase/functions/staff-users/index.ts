// Edge Function: staff-users
// Owner/admin membuat user staf (username + password) & reset password staf, tanpa staf mendaftar sendiri.
// Dipanggil aplikasi dengan JWT user yang login; izin dicek di database (sys_prepare_staff_user / sys_check_staff_reset).
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY tersedia otomatis di Edge Function.
//
// Body:
//   { action: 'create', username, password, full_name, role_id, outlet_ids: [] }
//   { action: 'reset_password', user_id, password }
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const MIN_PASSWORD = 8;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const body = await req.json();
    const url = Deno.env.get('SUPABASE_URL')!;
    // klien sebagai user yang memanggil -> izin & perusahaan dicek oleh database
    const asCaller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
      auth: { persistSession: false },
    });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

    if (body.action === 'create') {
      const { username, password, full_name, role_id, outlet_ids } = body;
      if (typeof password !== 'string' || password.length < MIN_PASSWORD) return json({ error: `Password minimal ${MIN_PASSWORD} karakter` }, 400);

      const { data: prep, error: prepErr } = await asCaller.rpc('sys_prepare_staff_user', {
        p_username: username, p_full_name: full_name, p_role_id: role_id, p_outlet_ids: outlet_ids ?? [],
      });
      if (prepErr) return json({ error: prepErr.message }, 400);

      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email: prep.email, password, email_confirm: true,
        user_metadata: { username: prep.username, full_name, staff: true },
      });
      if (createErr || !created.user) {
        return json({ error: /already|registered|exists/i.test(createErr?.message ?? '') ? `Username "${prep.username}" sudah dipakai` : createErr?.message }, 400);
      }

      const { error: regErr } = await admin.rpc('sys_register_staff_user', {
        p_user_id: created.user.id, p_company_id: prep.company_id, p_username: prep.username, p_full_name: full_name,
        p_role_id: role_id, p_outlet_ids: outlet_ids ?? [], p_created_by: prep.caller_id,
      });
      if (regErr) {
        await admin.auth.admin.deleteUser(created.user.id);   // batalkan akun login bila gagal disimpan
        return json({ error: regErr.message }, 400);
      }
      return json({ user_id: created.user.id, username: prep.username });
    }

    if (body.action === 'reset_password') {
      const { user_id, password } = body;
      if (typeof password !== 'string' || password.length < MIN_PASSWORD) return json({ error: `Password minimal ${MIN_PASSWORD} karakter` }, 400);
      const { error: checkErr } = await asCaller.rpc('sys_check_staff_reset', { p_user_id: user_id });
      if (checkErr) return json({ error: checkErr.message }, 400);
      const { error } = await admin.auth.admin.updateUserById(user_id, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: 'Aksi tidak dikenal' }, 400);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
