-- =====================================================================
-- ERP RESTORAN - 011: LOGO PERUSAHAAN, PROFIL USER, LOG AKTIVITAS
--   Permission baru: audit.view (melihat log aktivitas)
-- =====================================================================

-- =====================================================================
-- LOGO & DATA PERUSAHAAN
-- =====================================================================
alter table sys_companies add column logo_url text;
alter table sys_companies add column phone    text;
alter table sys_companies add column email    text;
alter table sys_companies add column address  text;

-- =====================================================================
-- PROFIL USER: foto & nomor HP
-- =====================================================================
alter table sys_users add column phone      text;
alter table sys_users add column avatar_url text;

-- Bucket aset perusahaan:
--   <company_id>/logo/...            -> butuh settings.manage
--   <company_id>/avatars/<user_id>-* -> user sendiri, atau user.manage
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('company-assets', 'company-assets', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function sys_can_write_company_asset(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (
       ((storage.foldername(p_name))[2] = 'logo' and sys_has_permission('settings.manage'))
       or ((storage.foldername(p_name))[2] = 'avatars'
           and (left(storage.filename(p_name), 36) = auth.uid()::text or sys_has_permission('user.manage')))
     )
$$;

create policy company_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'company-assets' and sys_can_write_company_asset(name));
create policy company_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'company-assets' and sys_can_write_company_asset(name));
create policy company_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'company-assets' and sys_can_write_company_asset(name));

-- Ubah profil sendiri
create or replace function sys_update_my_profile(p_full_name text, p_phone text, p_avatar_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Anda belum login'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  update sys_users set
    full_name  = trim(p_full_name),
    phone      = nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), ''),
    avatar_url = nullif(trim(p_avatar_url), '')
  where id = auth.uid();
end $$;

-- Owner / admin mengubah profil user lain
create or replace function sys_update_user_profile(p_user_id uuid, p_full_name text, p_phone text, p_avatar_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  update sys_users set
    full_name  = trim(p_full_name),
    phone      = nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), ''),
    avatar_url = nullif(trim(p_avatar_url), '')
  where id = p_user_id and company_id = sys_current_company_id();
  if not found then raise exception 'User tidak ditemukan'; end if;
end $$;

-- Profil login (versi baru: + foto, HP, logo perusahaan)
create or replace function sys_get_my_profile()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', u.id,
    'full_name', u.full_name,
    'phone', u.phone,
    'avatar_url', u.avatar_url,
    'email', (select email from auth.users where id = u.id),
    'company_id', c.id,
    'company_name', c.name,
    'company_logo_url', c.logo_url,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

-- =====================================================================
-- LOG AKTIVITAS
-- =====================================================================
create table sys_activity_logs (
  id            bigint generated always as identity primary key,
  company_id    uuid not null references sys_companies(id),
  user_id       uuid references sys_users(id) on delete set null,
  user_name     text,          -- snapshot nama saat kejadian
  action        text not null, -- login / create / update / delete / paid / void / refunded / approve / ...
  entity_type   text not null, -- nama tabel, mis. mst_menu_items
  entity_id     uuid,
  entity_label  text,          -- mis. "Nasi Goreng Spesial", "INV/OUT01/..."
  changes       jsonb,         -- { kolom: [lama, baru] }
  created_at    timestamptz not null default now()
);

create index idx_sys_activity_logs_company on sys_activity_logs(company_id, created_at desc);
create index idx_sys_activity_logs_entity  on sys_activity_logs(entity_type, entity_id);
create index idx_sys_activity_logs_user    on sys_activity_logs(user_id, created_at desc);

alter table sys_activity_logs enable row level security;
create policy sys_activity_logs_select on sys_activity_logs for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('audit.view') or sys_has_permission('user.manage')));

create or replace function sys_log_activity(
  p_company_id uuid, p_action text, p_entity_type text, p_entity_id uuid, p_label text, p_changes jsonb default null
)
returns void language sql security definer set search_path = public as $$
  insert into sys_activity_logs (company_id, user_id, user_name, action, entity_type, entity_id, entity_label, changes)
  values (p_company_id, auth.uid(), (select full_name from sys_users where id = auth.uid()),
          p_action, p_entity_type, p_entity_id, left(p_label, 200), p_changes)
$$;

-- Dipanggil aplikasi sekali setiap login
create or replace function sys_log_login()
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if v_company is null then return; end if;
  -- tidak dobel bila halaman dimuat ulang dalam 30 menit
  if exists (select 1 from sys_activity_logs where user_id = auth.uid() and action = 'login'
             and created_at > now() - interval '30 minutes') then return; end if;
  perform sys_log_activity(v_company, 'login', 'sys_users', auth.uid(), (select full_name from sys_users where id = auth.uid()));
end $$;

create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'email', au.email, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

-- Trigger audit umum. TG_ARGV[0] = kolom yang diabaikan (dipisah koma)
create or replace function sys_audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_ignore  text[] := array['updated_at', 'created_at'] || string_to_array(coalesce(tg_argv[0], ''), ',');
  v_changes jsonb;
  v_action  text := lower(tg_op);
  v_company uuid;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(k, jsonb_build_array(v_old->k, v_new->k)) into v_changes
    from jsonb_object_keys(v_new) k
    where not (k = any(v_ignore)) and (v_old->k) is distinct from (v_new->k);
    if v_changes is null then return null; end if;
    -- perubahan status dicatat sebagai aksinya (paid, void, posted, approved, ...)
    if v_changes ? 'status' then v_action := v_new->>'status'; end if;
  elsif tg_op = 'INSERT' then
    v_changes := null;
  end if;

  v_company := coalesce((v_row->>'company_id')::uuid,
                        case when tg_table_name = 'sys_companies' then (v_row->>'id')::uuid end);
  if v_company is null then return null; end if;

  perform sys_log_activity(
    v_company, v_action, tg_table_name, (v_row->>'id')::uuid,
    coalesce(v_row->>'order_number', v_row->>'po_number', v_row->>'receipt_number', v_row->>'adjustment_number',
             v_row->>'opname_number', v_row->>'transfer_number', v_row->>'full_name', v_row->>'name',
             v_row->>'code', v_row->>'menu_item_name', v_row->>'email'),
    v_changes);
  return null;
end $$;

-- Pasang audit ke tabel-tabel penting
do $$
declare r record;
begin
  for r in select * from (values
    ('sys_companies', ''), ('sys_outlets', ''), ('sys_users', ''), ('sys_roles', ''), ('sys_user_invitations', ''),
    ('mst_menu_categories', ''), ('mst_menu_items', ''), ('mst_menu_prices', ''), ('mst_modifiers', ''),
    ('mst_payment_methods', ''), ('mst_tables', 'status'),
    ('inv_items', 'last_purchase_cost'), ('inv_recipe_items', ''), ('inv_warehouses', ''),
    ('inv_stock_adjustments', ''), ('inv_stock_opnames', ''), ('inv_stock_transfers', ''),
    ('pur_suppliers', ''), ('pur_purchase_orders', 'subtotal,grand_total'), ('pur_goods_receipts', 'grand_total,paid_amount'),
    ('crm_promotions', 'usage_count'), ('crm_settings', ''), ('crm_membership_tiers', ''),
    ('fin_accounts', ''), ('pos_shifts', '')
  ) as t(tbl, ignored) loop
    execute format(
      'create trigger %I after insert or update or delete on %I
       for each row execute function sys_audit_trigger(%L)',
      'trg_' || r.tbl || '_audit', r.tbl, r.ignored);
  end loop;
end $$;

-- Order: hanya perubahan status (lunas, void, refund, digabung)
create trigger trg_pos_orders_audit after update of status on pos_orders
  for each row when (old.status is distinct from new.status)
  execute function sys_audit_trigger('subtotal,discount_amount,service_amount,tax_amount,rounding_amount,grand_total,promotion_id,promotion_amount,points_amount,points_earned,paid_at,voided_at,refunded_at,shift_id');

-- Item void
create trigger trg_pos_order_items_audit after update of is_void on pos_order_items
  for each row when (new.is_void and not old.is_void)
  execute function sys_audit_trigger('note,updated_at');

update sys_roles set permissions = permissions || '["audit.view"]'::jsonb
where code = 'manager' and not permissions ? 'audit.view';

revoke execute on function sys_log_activity(uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function sys_can_write_company_asset(text) from public, anon;
