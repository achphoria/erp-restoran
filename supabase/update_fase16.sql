-- =====================================================================
-- SANTAP ERP - UPDATE FASE 16 (Akses branch per user + role template)
-- Untuk database yang SUDAH menjalankan fase 1-15.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/026_branch_access.sql
-- =====================================================================
-- SANTAP ERP - 026: AKSES BRANCH PER USER + ROLE TEMPLATE
--   * outlet_scope per user: 'all' = semua branch (termasuk branch baru),
--     'selected' = hanya branch yang dicentang (1 branch = terkunci di branch itu)
--   * Data dikunci per branch di database (policy RESTRICTIVE):
--     POS, shift, refund, settlement, stok, batch, kartu stok, dokumen stok, transfer,
--     produksi, PO, penerimaan, sales order, pengiriman, invoice, pembayaran, approval
--   * Owner selalu semua branch. Gudang tanpa outlet (pusat) hanya untuk akses semua branch.
--   * Role template (GM, Finance, Purchasing, ... Supervisor) + cakupan branch default per role
-- =====================================================================

alter table sys_users add column outlet_scope text not null default 'selected';
alter table sys_users add constraint sys_users_outlet_scope_check check (outlet_scope in ('all', 'selected'));
alter table sys_roles add column default_outlet_scope text not null default 'selected';
alter table sys_roles add constraint sys_roles_default_outlet_scope_check check (default_outlet_scope in ('all', 'selected'));

-- ---------------------------------------------------------------------
-- PEMERIKSA AKSES
-- ---------------------------------------------------------------------
create or replace function sys_user_all_outlets()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('*') or coalesce((select outlet_scope = 'all' from sys_users where id = auth.uid() and is_active), false)
$$;

create or replace function sys_can_access_outlet(p_outlet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (sys_user_all_outlets() and exists (
            select 1 from sys_outlets where id = p_outlet_id and company_id = sys_current_company_id()))
      or exists (select 1 from sys_user_outlets where user_id = auth.uid() and outlet_id = p_outlet_id)
$$;

create or replace function sys_can_access_warehouse(p_warehouse_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when w.outlet_id is null then sys_user_all_outlets() else sys_can_access_outlet(w.outlet_id) end
    from inv_warehouses w where w.id = p_warehouse_id and w.company_id = sys_current_company_id()), false)
$$;

-- profil: daftar branch yang boleh diakses + cakupannya
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
    'company_app_name', c.app_name,
    'company_logo_url', c.logo_url,
    'role_code', r.code,
    'role_name', r.name,
    'permissions', r.permissions,
    'outlet_scope', case when r.permissions ? '*' then 'all' else u.outlet_scope end,
    'outlets', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name) order by o.code)
      from sys_outlets o
      where o.company_id = c.id and o.is_active
        and (r.permissions ? '*' or u.outlet_scope = 'all' or exists (
              select 1 from sys_user_outlets uo where uo.user_id = u.id and uo.outlet_id = o.id))
    ), '[]'::jsonb)
  )
  from sys_users u
  join sys_companies c on c.id = u.company_id
  join sys_roles r on r.id = u.role_id
  where u.id = auth.uid() and u.is_active
$$;

create or replace function sys_list_users()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'full_name', u.full_name, 'username', u.username,
           'email', case when u.username is null then au.email end, 'phone', u.phone, 'avatar_url', u.avatar_url,
           'is_active', u.is_active, 'role_id', u.role_id, 'role_name', r.name, 'role_code', r.code,
           'outlet_scope', case when r.permissions ? '*' then 'all' else u.outlet_scope end,
           'outlet_ids', coalesce((select jsonb_agg(uo.outlet_id) from sys_user_outlets uo where uo.user_id = u.id), '[]'::jsonb),
           'last_login_at', (select max(created_at) from sys_activity_logs l where l.user_id = u.id and l.action = 'login'),
           'created_at', u.created_at)
         order by u.created_at), '[]'::jsonb)
  from sys_users u
  join auth.users au on au.id = u.id
  join sys_roles r on r.id = u.role_id
  where u.company_id = sys_current_company_id() and sys_has_permission('user.manage')
$$;

-- Atur role, cakupan branch, branch & status user
create or replace function sys_set_user_access(p_user_id uuid, p_role_id uuid, p_outlet_scope text, p_outlet_ids uuid[], p_is_active boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola user'; end if;
  if p_user_id = auth.uid() then raise exception 'Tidak bisa mengubah akun sendiri'; end if;
  if not exists (select 1 from sys_users where id = p_user_id and company_id = v_company) then raise exception 'User tidak ditemukan'; end if;
  if not exists (select 1 from sys_roles where id = p_role_id and company_id = v_company) then raise exception 'Role tidak valid'; end if;
  if p_outlet_scope not in ('all', 'selected') then raise exception 'Cakupan branch tidak valid'; end if;
  if p_outlet_scope = 'selected' and coalesce(array_length(p_outlet_ids, 1), 0) = 0 then raise exception 'Pilih minimal 1 branch'; end if;

  update sys_users set role_id = p_role_id, is_active = coalesce(p_is_active, true), outlet_scope = p_outlet_scope where id = p_user_id;
  delete from sys_user_outlets where user_id = p_user_id;
  insert into sys_user_outlets (user_id, outlet_id)
  select p_user_id, o.id from sys_outlets o
  where o.company_id = v_company and (p_outlet_scope = 'all' or o.id = any(p_outlet_ids));
  perform sys_log_activity(v_company, 'update_user_access', 'sys_users', p_user_id,
    (select full_name from sys_users where id = p_user_id) || case when p_outlet_scope = 'all' then ' (semua branch)'
      else ' (' || coalesce(array_length(p_outlet_ids, 1), 0) || ' branch)' end, null);
end $$;

-- ---------------------------------------------------------------------
-- KUNCI DATA PER BRANCH (policy restrictive = DIGABUNG "AND" dengan policy yang sudah ada)
-- ---------------------------------------------------------------------
create or replace function sys_apply_outlet_lock(p_table text, p_predicate text)
returns void language plpgsql as $$
begin
  execute format('drop policy if exists %I on %I', p_table || '_branch', p_table);
  execute format('create policy %I on %I as restrictive for all to authenticated using (%s) with check (%s)',
    p_table || '_branch', p_table, p_predicate, p_predicate);
end $$;

select sys_apply_outlet_lock('pos_orders',            'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_shifts',            'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_refunds',           'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_settlements',       'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('pos_settlement_items',  'sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('inv_stocks',            'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_movements',   'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_batches',     'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_adjustments', 'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_stock_opnames',     'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('inv_productions',       'sys_can_access_warehouse(warehouse_id) or (dest_warehouse_id is not null and sys_can_access_warehouse(dest_warehouse_id))');
select sys_apply_outlet_lock('inv_stock_transfers',   'sys_can_access_warehouse(from_warehouse_id) or sys_can_access_warehouse(to_warehouse_id)');
select sys_apply_outlet_lock('pur_purchase_orders',   'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('pur_goods_receipts',    'sys_can_access_warehouse(warehouse_id)');
select sys_apply_outlet_lock('sal_sales_orders',      'sys_can_access_outlet(outlet_id) or (buyer_outlet_id is not null and sys_can_access_outlet(buyer_outlet_id))');
select sys_apply_outlet_lock('sal_deliveries',        'exists (select 1 from sal_sales_orders s where s.id = sales_order_id)');
select sys_apply_outlet_lock('sal_invoices',          'sys_can_access_outlet(outlet_id) or (buyer_outlet_id is not null and sys_can_access_outlet(buyer_outlet_id))');
select sys_apply_outlet_lock('sal_payments',          'sys_can_access_outlet(outlet_id) or (buyer_outlet_id is not null and sys_can_access_outlet(buyer_outlet_id))');
select sys_apply_outlet_lock('sys_approval_requests', 'outlet_id is null or sys_can_access_outlet(outlet_id)');

-- ---------------------------------------------------------------------
-- ROLE TEMPLATE
-- ---------------------------------------------------------------------
create or replace function sys_create_role_templates()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_n       int;
begin
  if not sys_has_permission('user.manage') then raise exception 'Tidak punya izin mengelola role'; end if;
  insert into sys_roles (company_id, code, name, permissions, default_outlet_scope)
  select v_company, x.code, x.name, x.perms::jsonb, x.scope
  from (values
    -- HEAD OFFICE (semua branch)
    ('gm', 'General Manager', '["report.view","master.manage","inventory.manage","purchasing.manage","sales.manage","crm.manage","finance.view","pos.order","pos.pay","pos.discount","pos.void","pos.refund","kds.update","approval.purchase_order","approval.sales_order","approval.stock_transfer","approval.production","approval.stock_adjustment","approval.stock_opname","approval.refund"]', 'all'),
    ('finance', 'Finance & Accounting', '["finance.view","finance.manage","report.view","approval.expense","approval.supplier_payment","approval.sales_payment","approval.credit_note","approval.pos_settlement","approval.manual_journal"]', 'all'),
    ('purchasing', 'Purchasing', '["purchasing.manage","report.view"]', 'all'),
    ('cost_control', 'Cost Control / Inventory Controller', '["inventory.manage","report.view","approval.stock_adjustment","approval.stock_opname","approval.product","approval.pricelist"]', 'all'),
    ('sales_admin', 'Sales B2B / Admin Sales', '["sales.manage","report.view"]', 'all'),
    ('marketing', 'Marketing / CRM', '["crm.manage","master.manage","report.view"]', 'all'),
    ('admin_it', 'Admin / HR-IT', '["user.manage","audit.view"]', 'all'),
    -- SUPPLY CHAIN / CENTRAL KITCHEN
    ('head_chef', 'Head Chef / Supervisor CK', '["inventory.manage","sales.manage","kds.update","report.view"]', 'selected'),
    ('warehouse', 'Staf Gudang', '["inventory.manage","purchasing.manage"]', 'selected'),
    -- OUTLET
    ('store_manager', 'Store Manager', '["pos.order","pos.pay","pos.discount","pos.void","pos.refund","kds.update","inventory.manage","purchasing.manage","report.view","approval.refund","approval.stock_adjustment"]', 'selected'),
    ('supervisor', 'Supervisor / Kapten', '["pos.order","pos.pay","pos.discount","pos.void","kds.update","approval.refund"]', 'selected')
  ) as x(code, name, perms, scope)
  where not exists (select 1 from sys_roles r where r.company_id = v_company and r.code = x.code);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function sys_apply_outlet_lock(text, text) from public, anon, authenticated;
