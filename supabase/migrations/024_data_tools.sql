-- =====================================================================
-- SANTAP ERP - 024: ALAT DATA (KHUSUS OWNER)
--   * Data contoh transaksi: pembelian, penjualan POS harian, waste, biaya, SO B2B, settlement
--   * Reset data: hapus transaksi saja, atau reset total (master + transaksi)
--   * Backup (export JSON) & restore (import JSON) data perusahaan
--   Perusahaan, outlet, user, role, COA, gudang, metode bayar & pengaturan TIDAK pernah dihapus.
-- =====================================================================

-- ---------------------------------------------------------------------
-- KLASIFIKASI TABEL
-- ---------------------------------------------------------------------
-- tabel inti: tidak pernah dihapus (restore = timpa / upsert)
create or replace function sys_data_core_tables()
returns text[] language sql immutable as $$
  select array['sys_brands', 'sys_outlets', 'sys_roles', 'sys_users', 'sys_user_invitations', 'sys_approval_rules',
               'sys_payment_gateways', 'sys_payment_gateway_secrets', 'fin_accounts', 'mst_payment_methods', 'inv_warehouses',
               'inv_units', 'inv_adjustment_purposes', 'crm_settings', 'crm_membership_tiers']
$$;

-- master data: ikut terhapus hanya pada reset total
create or replace function sys_data_master_tables()
returns text[] language sql immutable as $$
  select array['mst_menu_categories', 'mst_menu_items', 'mst_menu_prices', 'mst_modifier_groups', 'mst_modifiers',
               'mst_menu_item_modifier_groups', 'mst_table_areas', 'mst_tables', 'mst_price_schedules', 'mst_price_schedule_items',
               'inv_item_categories', 'inv_item_sub_categories', 'inv_item_custom_fields', 'inv_items', 'inv_item_units',
               'inv_item_stock_levels', 'inv_recipes', 'inv_recipe_items', 'inv_recipe_costs', 'inv_recipe_access',
               'pur_suppliers', 'pur_pricelists', 'pur_pricelist_items', 'crm_customers', 'crm_promotions',
               'sal_customers', 'sal_pricelists', 'sal_pricelist_items']
$$;

-- semua tabel perusahaan (punya kolom company_id)
create or replace function sys_data_company_tables()
returns text[] language sql stable as $$
  select coalesce(array_agg(c.table_name::text order by c.table_name), '{}')
  from information_schema.columns c
  join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
  where c.table_schema = 'public' and c.column_name = 'company_id'
$$;

-- p_scope: 'transactions' = transaksi saja, 'all' = transaksi + master
create or replace function sys_data_wipe_tables(p_scope text)
returns text[] language sql stable as $$
  select coalesce(array_agg(t), '{}') from unnest(sys_data_company_tables()) t
  where t <> all(sys_data_core_tables())
    and (p_scope = 'all' or t <> all(sys_data_master_tables()))
$$;

-- kolom foreign key antar tabel public
create or replace function sys_data_fk_columns()
returns table (child text, col text, parent text, nullable boolean) language sql stable as $$
  select c.conrelid::regclass::text, a.attname::text, c.confrelid::regclass::text, not a.attnotnull
  from pg_constraint c
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
  where c.contype = 'f' and c.connamespace = 'public'::regnamespace
$$;

-- kolom FK (boleh null) yang membentuk siklus di antara tabel-tabel p_tables
create or replace function sys_data_cycle_columns(p_tables text[])
returns table (child text, col text) language sql stable as $$
  select f.child, f.col from sys_data_fk_columns() f
  where f.child = any(p_tables) and f.parent = any(p_tables) and f.nullable and f.child <> f.parent
    and exists (
      with recursive reach(t) as (
        select f.parent
        union
        select g.parent from sys_data_fk_columns() g join reach on g.child = reach.t
        where g.parent = any(p_tables) and g.child <> g.parent)
      select 1 from reach where reach.t = f.child)
$$;

create or replace function sys_data_set_triggers(p_tables text[], p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare t text;
begin
  foreach t in array p_tables loop
    execute format('alter table %I %s trigger user', t, case when p_enabled then 'enable' else 'disable' end);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- HAPUS DATA PERUSAHAAN (internal). Urutan hapus dicari otomatis (anak dulu),
-- siklus FK diputus dengan mengosongkan kolom FK yang boleh null.
-- ---------------------------------------------------------------------
create or replace function sys_data_wipe(p_company_id uuid, p_scope text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tables   text[] := sys_data_wipe_tables(p_scope);
  v_left     text[];
  v_counts   jsonb := '{}';
  v_progress boolean;
  v_n        bigint;
  t          text;
  r          record;
begin
  if p_scope not in ('transactions', 'all') then raise exception 'Jenis reset tidak dikenal'; end if;
  perform sys_data_set_triggers(v_tables, false);
  v_left := v_tables;
  for pass in 1..60 loop
    exit when cardinality(v_left) = 0;
    v_progress := false;
    foreach t in array v_left loop
      begin
        execute format('delete from %I where company_id = $1%s', t,
          case when t = 'pur_suppliers' then ' and supplier_type = ''external''' else '' end) using p_company_id;
        get diagnostics v_n = row_count;
        v_counts := v_counts || jsonb_build_object(t, v_n);
        v_left := array_remove(v_left, t);
        v_progress := true;
      exception when foreign_key_violation then null;
      end;
    end loop;
    if not v_progress then
      for r in select * from sys_data_cycle_columns(v_left) loop
        execute format('update %I set %I = null where company_id = $1 and %I is not null', r.child, r.col, r.col) using p_company_id;
      end loop;
    end if;
  end loop;
  if cardinality(v_left) > 0 then raise exception 'Data tidak bisa dihapus (masih dipakai): %', array_to_string(v_left, ', '); end if;
  set constraints all immediate;   -- cek FK tertunda dulu sebelum trigger diaktifkan lagi
  perform sys_data_set_triggers(v_tables, true);

  if p_scope = 'transactions' then
    -- master tetap, angka turunan dari transaksi dikembalikan ke nol
    update crm_customers set points_balance = 0, total_spent = 0, visit_count = 0 where company_id = p_company_id;
    update crm_promotions set usage_count = 0 where company_id = p_company_id;
  end if;
  return v_counts;
end $$;

-- Reset (owner): ketik nama perusahaan sebagai konfirmasi
create or replace function sys_reset_company_data(p_scope text, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_name    text;
  v_counts  jsonb;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa mereset data'; end if;
  select name into v_name from sys_companies where id = v_company;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(trim(v_name)) then raise exception 'Ketik nama perusahaan "%" untuk konfirmasi', v_name; end if;
  v_counts := sys_data_wipe(v_company, p_scope);
  perform sys_log_activity(v_company, 'reset_data', 'sys_companies', v_company,
    case when p_scope = 'all' then 'Reset total (master & transaksi)' else 'Hapus semua transaksi' end, null);
  return jsonb_build_object('scope', p_scope, 'deleted', v_counts);
end $$;

-- ---------------------------------------------------------------------
-- BACKUP (export) - semua data perusahaan sebagai JSON
-- ---------------------------------------------------------------------
create or replace function sys_export_company_data()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_tables  jsonb := '{}';
  v_rows    jsonb;
  t         text;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa membuat backup'; end if;
  foreach t in array sys_data_company_tables() loop
    continue when t = 'sys_payment_gateway_secrets';      -- rahasia tidak ikut di-backup
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from %I x where company_id = $1', t) into v_rows using v_company;
    v_tables := v_tables || jsonb_build_object(t, v_rows);
  end loop;
  v_tables := v_tables || jsonb_build_object('sys_user_outlets',
    (select coalesce(jsonb_agg(to_jsonb(uo)), '[]') from sys_user_outlets uo join sys_users u on u.id = uo.user_id where u.company_id = v_company));

  perform sys_log_activity(v_company, 'export_data', 'sys_companies', v_company, 'Backup data', null);
  return jsonb_build_object('format', 'santap-backup', 'version', 1, 'company_id', v_company,
    'company_name', (select name from sys_companies where id = v_company), 'exported_at', now(),
    'exported_by', (select full_name from sys_users where id = auth.uid()), 'tables', v_tables);
end $$;

-- ---------------------------------------------------------------------
-- RESTORE (import) - kembalikan data perusahaan dari file backup
--   Master & transaksi diganti isi backup; data inti di-upsert; user tidak diubah.
-- ---------------------------------------------------------------------
create or replace function sys_data_insert_sql(p_table text, p_rows jsonb, p_null_cols text[], p_upsert boolean)
returns text language plpgsql stable set search_path = public as $$
declare
  v_keys  text[] := (select coalesce(array_agg(k), '{}') from jsonb_object_keys(coalesce(p_rows->0, '{}')) k);
  v_cols  text;
  v_exprs text;
  v_pk    text;
  v_set   text;
  v_upd   text;
  v_pkarr text[];
begin
  -- kolom yang tidak ada di backup (versi lama) memakai nilai default kolom
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg(case when c.column_name = any(p_null_cols) then 'null'
                         when c.column_name = any(v_keys) then 'r.' || quote_ident(c.column_name)
                         else coalesce(c.column_default, 'null') end, ', ' order by c.ordinal_position),
         null
    into v_cols, v_exprs, v_set
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.is_generated = 'NEVER';

  select string_agg(quote_ident(a.attname), ', '), array_agg(a.attname::text) into v_pk, v_pkarr
  from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
  where i.indrelid = p_table::regclass and i.indisprimary;

  -- upsert: kolom biasa saja (tanpa primary key & identity)
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg('excluded.' || quote_ident(c.column_name), ', ' order by c.ordinal_position)
    into v_upd, v_set
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.is_generated = 'NEVER' and c.is_identity = 'NO'
    and c.column_name <> all(coalesce(v_pkarr, '{}'));

  return format('insert into %I (%s) overriding system value select %s from jsonb_populate_recordset(null::%I, $1) r%s',
    p_table, v_cols, v_exprs, p_table,
    case when not p_upsert or v_pk is null then ''
         when v_upd is null then format(' on conflict (%s) do nothing', v_pk)
         else format(' on conflict (%s) do update set (%s) = row(%s)', v_pk, v_upd, v_set) end);
end $$;

create or replace function sys_import_company_data(p_backup jsonb, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_name     text;
  v_skip     text[] := array['sys_users', 'sys_user_outlets', 'sys_user_invitations', 'sys_payment_gateway_secrets'];
  v_tables   text[];
  v_left     text[];
  v_nulls    jsonb := '{}';      -- tabel -> kolom FK yang diisi belakangan (pemutus siklus)
  v_counts   jsonb := '{}';
  v_progress boolean;
  v_rows     jsonb;
  v_n        bigint;
  v_cols     text[];
  v_pk       text;
  t          text;
  r          record;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa restore data'; end if;
  select name into v_name from sys_companies where id = v_company;
  if p_backup->>'format' <> 'santap-backup' then raise exception 'File bukan backup Santap ERP'; end if;
  if (p_backup->>'company_id')::uuid is distinct from v_company then
    raise exception 'Backup ini milik perusahaan lain (%). Restore hanya untuk perusahaan yang sama.', p_backup->>'company_name';
  end if;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(trim(v_name)) then raise exception 'Ketik nama perusahaan "%" untuk konfirmasi', v_name; end if;

  perform sys_data_wipe(v_company, 'all');

  select coalesce(array_agg(k), '{}') into v_tables
  from jsonb_object_keys(p_backup->'tables') k
  where k = any(sys_data_company_tables()) and k <> all(v_skip);
  perform sys_data_set_triggers(v_tables, false);

  v_left := v_tables;
  for pass in 1..80 loop
    exit when cardinality(v_left) = 0;
    v_progress := false;
    foreach t in array v_left loop
      -- hanya baris milik perusahaan ini
      select coalesce(jsonb_agg(x), '[]') into v_rows from jsonb_array_elements(p_backup->'tables'->t) x
      where x->>'company_id' = v_company::text;
      begin
        if jsonb_array_length(v_rows) > 0 then
          execute sys_data_insert_sql(t, v_rows,
            coalesce((select array_agg(c) from jsonb_array_elements_text(v_nulls->t) c), '{}'), true)
            using v_rows;
        end if;
        v_counts := v_counts || jsonb_build_object(t, jsonb_array_length(v_rows));
        v_left := array_remove(v_left, t);
        v_progress := true;
      exception when foreign_key_violation then null;
      end;
    end loop;
    if not v_progress then
      -- siklus: isi kolom FK yang boleh null belakangan
      v_n := 0;
      for r in select * from sys_data_cycle_columns(v_left) loop
        if not coalesce(v_nulls->r.child, '[]') ? r.col then
          v_nulls := jsonb_set(v_nulls, array[r.child], coalesce(v_nulls->r.child, '[]') || to_jsonb(r.col));
          v_n := v_n + 1;
        end if;
      end loop;
      exit when v_n = 0;
    end if;
  end loop;
  if cardinality(v_left) > 0 then raise exception 'Restore gagal, tabel bermasalah: %', array_to_string(v_left, ', '); end if;

  -- isi kolom yang tadi dikosongkan
  for t in select jsonb_object_keys(v_nulls) loop
    select array_agg(c) into v_cols from jsonb_array_elements_text(v_nulls->t) c;
    select string_agg(format('x.%1$I = r.%1$I', a.attname), ' and ') into v_pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    where i.indrelid = t::regclass and i.indisprimary;
    execute format('update %I x set %s from jsonb_populate_recordset(null::%I, $1) r where %s',
      t, (select string_agg(format('%1$I = r.%1$I', c), ', ') from unnest(v_cols) c), t, v_pk)
      using (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(p_backup->'tables'->t) x where x->>'company_id' = v_company::text);
  end loop;

  -- kolom identity (mis. urutan alokasi batch) dilanjutkan dari nilai terbesar
  for r in select c.table_name, c.column_name from information_schema.columns c
           where c.table_schema = 'public' and c.is_identity = 'YES' and c.table_name = any(v_tables) loop
    execute format('select setval(pg_get_serial_sequence(%L, %L), greatest(coalesce((select max(%I) from %I), 0), 1))',
      r.table_name, r.column_name, r.column_name, r.table_name);
  end loop;

  set constraints all immediate;   -- cek FK tertunda dulu sebelum trigger diaktifkan lagi
  perform sys_data_set_triggers(v_tables, true);
  perform sys_log_activity(v_company, 'import_data', 'sys_companies', v_company,
    'Restore backup ' || coalesce(to_char((p_backup->>'exported_at')::timestamptz, 'DD Mon YYYY HH24:MI'), ''), null);
  return jsonb_build_object('restored', v_counts);
end $$;

-- =====================================================================
-- DATA CONTOH TRANSAKSI (dipanggil per hari dari aplikasi supaya tidak timeout)
-- =====================================================================
create or replace function sys_seed_demo_check(p_outlet_id uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_wh uuid;
begin
  if not sys_has_permission('*') then raise exception 'Hanya owner yang bisa membuat data contoh'; end if;
  select default_warehouse_id into v_wh from sys_outlets where id = p_outlet_id and company_id = sys_current_company_id();
  if v_wh is null then raise exception 'Outlet tidak ditemukan / belum punya gudang POS'; end if;
  return v_wh;
end $$;

-- menu yang bisa dijual tanpa pilihan wajib
create or replace function sys_seed_demo_menus()
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(mi.id), '{}') from mst_menu_items mi
  where mi.company_id = sys_current_company_id() and mi.is_active and mi.base_price > 0
    and not exists (select 1 from mst_menu_item_modifier_groups mg join mst_modifier_groups g on g.id = mg.modifier_group_id
                    where mg.menu_item_id = mi.id and g.min_select > 0)
$$;

create or replace function sys_seed_demo_prepare(p_outlet_id uuid, p_start_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_wh      uuid := sys_seed_demo_check(p_outlet_id);
  v_shift   uuid;
  v_opened  boolean := false;
begin
  if cardinality(sys_seed_demo_menus()) = 0 then raise exception 'Belum ada menu aktif berharga. Isi master menu & resep dulu.'; end if;

  if not exists (select 1 from pur_suppliers where company_id = v_company and supplier_type = 'external' and is_active) then
    insert into pur_suppliers (company_id, code, name, payment_term_days) values (v_company, 'DEMO-SUP', 'CV Demo Pangan Segar', 14);
  end if;
  insert into sal_customers (company_id, code, name, contact_name, phone, address, payment_term_days, credit_limit)
  values (v_company, 'DEMO-B2B', 'PT Demo Katering Sejahtera', 'Ibu Rina', '0812000000', 'Jl. Contoh No. 1', 14, 0)
  on conflict (company_id, code) do nothing;

  -- tanggal contoh di masa lalu ikut di-settle
  update mst_payment_methods set settlement_from = least(settlement_from, p_start_date) where company_id = v_company;

  select id into v_shift from pos_shifts where outlet_id = p_outlet_id and user_id = auth.uid() and status = 'open' limit 1;
  if v_shift is null then
    v_shift := (pos_open_shift(p_outlet_id, 500000)->>'id')::uuid;
    v_opened := true;
  end if;
  return jsonb_build_object('shift_id', v_shift, 'shift_opened', v_opened, 'warehouse_id', v_wh);
end $$;

create or replace function sys_seed_demo_day(p_outlet_id uuid, p_date date, p_orders int default 20, p_purchase boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_wh       uuid := sys_seed_demo_check(p_outlet_id);
  v_menus    uuid[] := sys_seed_demo_menus();
  v_methods  uuid[];
  v_supplier uuid;
  v_po       uuid;
  v_gr       uuid;
  v_order    jsonb;
  v_items    jsonb;
  v_ts       timestamptz;
  v_doc      uuid;
  v_orders   int := 0;
  v_failed   int := 0;
  v_n        int;
  r          record;
begin
  if p_date > current_date then raise exception 'Tanggal tidak boleh di masa depan'; end if;

  -- 1) PEMBELIAN: stok bahan resep untuk ~4 hari
  if p_purchase then
    select id into v_supplier from pur_suppliers where company_id = v_company and supplier_type = 'external' and is_active order by code limit 1;
    insert into pur_purchase_orders (company_id, supplier_id, warehouse_id, po_date, expected_date, note)
    values (v_company, v_supplier, v_wh, p_date, p_date, 'Data contoh') returning id into v_po;
    insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
    select v_company, v_po, x.item_id, it.base_unit_id, 1, x.qty, x.price, round(x.qty * x.price, 2)
    from (
      select ri.item_id,
             ceil(sum(ri.quantity / r2.yield_qty) / cardinality(v_menus) * 2.5 * greatest(p_orders, 1) * 4 * (1.1 + random() * 0.4)::numeric) as qty,
             round(greatest(max(it2.last_purchase_cost), 1) * (0.95 + random() * 0.15)::numeric, 2) as price
      from inv_recipe_items ri
      join inv_recipes r2 on r2.id = ri.recipe_id
      join inv_items it2 on it2.id = ri.item_id
      where r2.menu_item_id = any(v_menus) and it2.is_purchasable and it2.is_active and it2.approval_status = 'approved'
      group by ri.item_id
    ) x join inv_items it on it.id = x.item_id
    where x.qty > 0;
    if exists (select 1 from pur_purchase_order_items where purchase_order_id = v_po) then
      perform pur_approve_purchase_order(v_po);
      v_gr := pur_create_goods_receipt_from_po(v_po);
      update pur_goods_receipt_items gi set expiry_date = p_date + 30, lot_number = 'DEMO-' || to_char(p_date, 'MMDD')
      from inv_items it where gi.goods_receipt_id = v_gr and it.id = gi.item_id and it.track_batch and it.shelf_life_days is null;
      update pur_goods_receipts set receipt_date = p_date, supplier_invoice_number = 'INV-DEMO-' || to_char(p_date, 'YYMMDD') where id = v_gr;
      perform pur_post_goods_receipt(v_gr);
      v_ts := p_date + time '08:00';
      update pur_purchase_orders set approved_at = v_ts, created_at = v_ts where id = v_po;
      update pur_goods_receipts set posted_at = v_ts, created_at = v_ts where id = v_gr;
      update inv_stock_movements set movement_at = v_ts where reference_id = v_gr;
      update inv_stock_batches set received_at = v_ts where reference_id = v_gr;
      update fin_journals set journal_date = p_date where source_id = v_gr;
    else
      delete from pur_purchase_orders where id = v_po;
    end if;
  end if;

  -- 2) PENJUALAN POS
  select array_agg(id order by sort_order) into v_methods from mst_payment_methods
  where company_id = v_company and is_active and code in ('cash', 'qris', 'debit');
  for i in 1..greatest(p_orders, 0) loop
    begin
      select jsonb_agg(jsonb_build_object('menu_item_id', v_menus[1 + floor(random() * cardinality(v_menus))::int],
                                          'quantity', case when random() < 0.25 then 2 else 1 end))
        into v_items from generate_series(1, 1 + floor(random() * 3)::int);
      v_order := pos_save_order(jsonb_build_object('outlet_id', p_outlet_id,
        'sales_channel', (array['dine_in', 'dine_in', 'takeaway', 'gofood'])[1 + floor(random() * 4)::int],
        'guest_count', 1 + floor(random() * 3)::int, 'items', v_items));
      perform pos_pay_order((v_order->>'id')::uuid, jsonb_build_array(jsonb_build_object(
        'payment_method_id', v_methods[1 + floor(random() * cardinality(v_methods))::int],
        'amount', (select grand_total from pos_orders where id = (v_order->>'id')::uuid))));
      v_ts := p_date + time '10:00' + (random() * interval '11 hours');
      update pos_orders set business_date = p_date, created_at = v_ts, paid_at = v_ts + interval '25 minutes' where id = (v_order->>'id')::uuid;
      update pos_payments set created_at = v_ts + interval '25 minutes' where order_id = (v_order->>'id')::uuid;
      update fin_journals set journal_date = p_date where source_id = (v_order->>'id')::uuid;
      update inv_stock_movements set movement_at = v_ts + interval '25 minutes' where reference_id = (v_order->>'id')::uuid;
      v_orders := v_orders + 1;
    exception when others then
      v_failed := v_failed + 1;
    end;
  end loop;

  -- 3) WASTE tiap Senin, PEMAKAIAN tiap Jumat (2 bahan acak, qty kecil)
  if extract(isodow from p_date) in (1, 5) then
    insert into inv_stock_adjustments (company_id, warehouse_id, adjustment_type, adjustment_date, purpose_id, note)
    values (v_company, v_wh, case when extract(isodow from p_date) = 1 then 'waste' else 'usage' end, p_date,
      (select id from inv_adjustment_purposes where company_id = v_company
         and adjustment_type = case when extract(isodow from p_date) = 1 then 'waste' else 'usage' end order by sort_order limit 1),
      'Data contoh') returning id into v_doc;
    insert into inv_stock_adjustment_items (company_id, stock_adjustment_id, item_id, quantity)
    select v_company, v_doc, s.item_id, greatest(round(s.quantity * (0.01 + random() * 0.02)::numeric), 1)
    from inv_stocks s where s.warehouse_id = v_wh and s.quantity > 10 order by random() limit 2;
    if exists (select 1 from inv_stock_adjustment_items where stock_adjustment_id = v_doc) then
      perform inv_post_stock_adjustment(v_doc);
      update inv_stock_movements set movement_at = p_date + time '22:00' where reference_id = v_doc;
      update fin_journals set journal_date = p_date where source_id = v_doc;
    else
      delete from inv_stock_adjustments where id = v_doc;
    end if;
  end if;

  -- 4) BIAYA: listrik tiap Senin, sewa tiap tanggal 1
  if exists (select 1 from fin_accounts where company_id = v_company and code = '6-1300') then
    if extract(isodow from p_date) = 1 then
      perform fin_record_expense(p_date, (select id from fin_accounts where company_id = v_company and code = '6-1300'),
        fin_account_id(v_company, 'bank'), 750000 + round((random() * 250000)::numeric, -3), 'Listrik & air minggu ini (contoh)', p_outlet_id);
    end if;
    if extract(day from p_date) = 1 then
      perform fin_record_expense(p_date, (select id from fin_accounts where company_id = v_company and code = '6-1200'),
        fin_account_id(v_company, 'bank'), 15000000, 'Sewa tempat bulan ini (contoh)', p_outlet_id);
    end if;
  end if;

  return jsonb_build_object('date', p_date, 'orders', v_orders, 'failed', v_failed, 'purchase', v_gr is not null);
end $$;

create or replace function sys_seed_demo_finish(p_outlet_id uuid, p_shift_id uuid default null, p_close_shift boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  v_wh       uuid := sys_seed_demo_check(p_outlet_id);
  v_cust     uuid;
  v_pl       uuid;
  v_so       uuid;
  v_del      uuid;
  v_inv      jsonb;
  v_settled  int := 0;
  r          record;
begin
  -- 1) SALES ORDER B2B: 2 bahan dengan stok, kirim, invoice, bayar sebagian
  select id into v_cust from sal_customers where company_id = v_company and code = 'DEMO-B2B';
  if v_cust is not null and exists (select 1 from inv_stocks where warehouse_id = v_wh and quantity > 100) then
    insert into sal_pricelists (company_id, name, customer_id, valid_from) values (v_company, 'Harga Demo Katering', v_cust, current_date - 30)
    returning id into v_pl;
    insert into sal_pricelist_items (company_id, pricelist_id, item_id, unit_id, price)
    select v_company, v_pl, it.id, it.base_unit_id, round(greatest(it.last_purchase_cost, 1) * 1.4, 2)
    from inv_stocks s join inv_items it on it.id = s.item_id
    where s.warehouse_id = v_wh and s.quantity > 100 order by s.quantity desc limit 2;

    insert into sal_sales_orders (company_id, outlet_id, warehouse_id, customer_type, customer_id, so_date, tax_pct, shipping_address, note)
    values (v_company, p_outlet_id, v_wh, 'external', v_cust, current_date - 3, 11, 'Jl. Contoh No. 1', 'Data contoh') returning id into v_so;
    insert into sal_sales_order_items (company_id, sales_order_id, item_id, unit_id, quantity)
    select v_company, v_so, pi.item_id, pi.unit_id, least(round(s.quantity * 0.05), 5000)
    from sal_pricelist_items pi join inv_stocks s on s.item_id = pi.item_id and s.warehouse_id = v_wh where pi.pricelist_id = v_pl;
    perform sal_confirm_sales_order(v_so);
    v_del := sal_create_delivery(v_so, v_wh);
    perform sal_ship_delivery(v_del);
    v_inv := sal_create_invoice(v_so, current_date - 2, 'Data contoh');
    perform sal_record_payment(jsonb_build_array(jsonb_build_object('invoice_id', v_inv->>'id', 'amount', round((v_inv->>'grand_total')::numeric / 2))),
      fin_account_id(v_company, 'bank'), null, current_date - 1, 'TRF-DEMO');
  end if;

  -- 2) SETTLEMENT: semua metode, tanggal s/d 2 hari lalu (dana non tunai dipotong estimasi MDR)
  for r in
    select payment_method_id, payment_type, array_agg(business_date order by business_date) dates,
           sum(net_amount) net, sum(estimated_fee) fee, max(business_date) last_date
    from rpt_pos_settlement_days
    where outlet_id = p_outlet_id and settlement_id is null and needs_settlement and business_date <= current_date - 2 and net_amount > 0
    group by payment_method_id, payment_type
  loop
    perform pos_create_settlement(p_outlet_id, r.payment_method_id, r.dates,
      r.net - case when r.payment_type = 'cash' then 0 else r.fee end,
      case when r.payment_type = 'cash' then 0 else r.fee end, null, r.last_date + 1, 'DEMO', 'Data contoh');
    v_settled := v_settled + 1;
  end loop;

  if p_close_shift and p_shift_id is not null then
    perform pos_close_shift(p_shift_id, 0);
    update pos_shifts set closing_cash = expected_cash where id = p_shift_id;
  end if;
  return jsonb_build_object('sales_order', v_so is not null, 'settlements', v_settled);
end $$;

-- Satu perintah untuk SQL Editor: select sys_seed_demo_transactions('<outlet_id>', 14, 20);
create or replace function sys_seed_demo_transactions(p_outlet_id uuid, p_days int default 14, p_orders_per_day int default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prep  jsonb;
  v_total int := 0;
  v_day   jsonb;
begin
  if p_days not between 1 and 90 then raise exception 'Jumlah hari 1-90'; end if;
  v_prep := sys_seed_demo_prepare(p_outlet_id, current_date - p_days + 1);
  for d in reverse (p_days - 1)..0 loop
    v_day := sys_seed_demo_day(p_outlet_id, current_date - d, greatest(1, round(p_orders_per_day * (0.7 + random() * 0.6))::int),
                               (p_days - 1 - d) % 4 = 0);
    v_total := v_total + (v_day->>'orders')::int;
  end loop;
  return sys_seed_demo_finish(p_outlet_id, (v_prep->>'shift_id')::uuid, (v_prep->>'shift_opened')::boolean)
    || jsonb_build_object('orders', v_total, 'days', p_days);
end $$;

revoke execute on function sys_data_set_triggers(text[], boolean)          from public, anon, authenticated;
revoke execute on function sys_data_wipe(uuid, text)                       from public, anon, authenticated;
revoke execute on function sys_data_insert_sql(text, jsonb, text[], boolean) from public, anon, authenticated;
revoke execute on function sys_data_fk_columns()                           from public, anon, authenticated;
revoke execute on function sys_data_cycle_columns(text[])                  from public, anon, authenticated;
revoke execute on function sys_data_company_tables()                       from public, anon, authenticated;
revoke execute on function sys_data_wipe_tables(text)                      from public, anon, authenticated;
revoke execute on function sys_seed_demo_check(uuid)                       from public, anon, authenticated;
revoke execute on function sys_seed_demo_menus()                           from public, anon, authenticated;
