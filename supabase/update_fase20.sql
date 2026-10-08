-- =====================================================================
-- SANTAP ERP - UPDATE FASE 20 (Agent AI Semar)
-- Untuk database yang SUDAH menjalankan fase 1-19.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/030_semar_agent.sql
-- =====================================================================
-- SANTAP ERP - 030: AGENT AI "SEMAR" (KEPALA KONSULTAN)
--   * Hanya OWNER (permission '*') yang bisa mengobrol dengan Semar.
--   * Semar membaca & mengubah data lewat JWT owner sendiri -> RLS menjamin hanya data
--     perusahaan owner tersebut (company_id) yang tersentuh.
--   * Perubahan data selalu berupa USULAN yang harus disetujui owner di jendela obrolan.
--   * Semar hanya boleh MENGUBAH master data (ai_writable_tables); transaksi hanya dibaca.
--   * Kunci API Claude disimpan sebagai secret Edge Function (ANTHROPIC_API_KEY), tidak di database.
-- =====================================================================

create table ai_chat_messages (
  id               bigint generated always as identity primary key,
  company_id       uuid not null references sys_companies(id) on delete cascade,
  user_id          uuid not null references sys_users(id) on delete cascade,
  conversation_id  uuid not null,
  role             text not null check (role in ('user', 'assistant')),
  content          jsonb not null,           -- blok pesan format Claude (text, tool_use, tool_result)
  meta             jsonb,                    -- mis. { action_id, status: 'executed'|'rejected', result }
  input_tokens     int not null default 0,
  output_tokens    int not null default 0,
  created_at       timestamptz not null default now()
);
create index ai_chat_messages_conv_idx on ai_chat_messages (user_id, conversation_id, id);
alter table ai_chat_messages enable row level security;
-- obrolan pribadi: hanya pemiliknya sendiri, di perusahaan aktif, dan harus owner
create policy ai_chat_messages_select on ai_chat_messages for select to authenticated
  using (user_id = auth.uid() and company_id = sys_current_company_id() and sys_has_permission('*'));
create policy ai_chat_messages_insert on ai_chat_messages for insert to authenticated
  with check (user_id = auth.uid() and company_id = sys_current_company_id() and sys_has_permission('*'));
create policy ai_chat_messages_delete on ai_chat_messages for delete to authenticated
  using (user_id = auth.uid() and company_id = sys_current_company_id());

-- tabel yang tidak boleh dilihat agent sama sekali
create or replace function ai_hidden_tables()
returns text[] language sql immutable as $$
  select array['sys_platform_admins', 'sys_user_context', 'sys_payment_gateway_secrets', 'sys_company_groups',
               'sys_group_members', 'ai_chat_messages', 'sys_document_sequences']
$$;

-- master data yang boleh ditambah/diubah/dihapus agent (transaksi & stok hanya dibaca)
create or replace function ai_writable_tables()
returns text[] language sql immutable as $$
  select array[
    'mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
    'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_payment_methods',
    'inv_units', 'inv_item_categories', 'inv_item_sub_categories', 'inv_items', 'inv_item_units', 'inv_item_stock_levels',
    'inv_recipes', 'inv_recipe_items',
    'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items',
    'sal_customers', 'sal_pricelists', 'sal_pricelist_items',
    'crm_customers', 'crm_promotions', 'crm_membership_tiers']
$$;

-- Struktur tabel untuk agent: kolom, tipe, wajib/tidak, relasi, aturan (check). Khusus owner.
create or replace function ai_table_info(p_tables text[] default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sys_has_permission('*') then raise exception 'Khusus owner'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'table', t.table_name,
      'kind', case when t.table_type = 'VIEW' then 'laporan (view, hanya baca)' else 'tabel' end,
      'writable', t.table_name = any(ai_writable_tables()),
      'has_company_id', exists (select 1 from information_schema.columns c where c.table_schema = 'public' and c.table_name = t.table_name and c.column_name = 'company_id'),
      'columns', case when p_tables is null then null else (
        select jsonb_agg(jsonb_build_object(
          'name', c.column_name, 'type', c.data_type, 'required', c.is_nullable = 'NO' and c.column_default is null and c.is_identity = 'NO',
          'default', c.column_default) order by c.ordinal_position)
        from information_schema.columns c where c.table_schema = 'public' and c.table_name = t.table_name) end,
      'references', case when p_tables is null then null else (
        select jsonb_agg(jsonb_build_object('column', a.attname, 'table', pl.relname))
        from pg_constraint k join pg_class cl on cl.oid = k.conrelid join pg_class pl on pl.oid = k.confrelid
        join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
        where k.contype = 'f' and cl.relname = t.table_name and cl.relnamespace = 'public'::regnamespace) end,
      'rules', case when p_tables is null then null else (
        select jsonb_agg(pg_get_constraintdef(k.oid))
        from pg_constraint k join pg_class cl on cl.oid = k.conrelid
        where k.contype in ('c', 'u') and cl.relname = t.table_name and cl.relnamespace = 'public'::regnamespace) end
    ) order by t.table_name)
    from information_schema.tables t
    where t.table_schema = 'public' and t.table_name <> all(ai_hidden_tables())
      and (t.table_type = 'BASE TABLE' or t.table_name like 'rpt\_%')
      and (p_tables is null or t.table_name = any(p_tables))
  ), '[]'::jsonb);
end $$;

-- penggunaan agent: jumlah pesan owner dalam 1 jam terakhir (batas pemakaian kunci API)
create or replace function ai_recent_usage()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'messages_last_hour', (select count(*) from ai_chat_messages where user_id = auth.uid() and role = 'user'
                             and created_at > now() - interval '1 hour' and meta is null),
    'tokens_today', (select coalesce(sum(input_tokens + output_tokens), 0) from ai_chat_messages
                       where company_id = sys_current_company_id() and created_at > now() - interval '1 day'))
$$;
