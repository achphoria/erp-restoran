-- =====================================================================
-- ERP RESTORAN - UPDATE FASE 4 (Member & Poin, Promo & Voucher, QR Order)
-- Untuk database yang SUDAH menjalankan fase 1-3.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/008_crm_promotions.sql
-- =====================================================================
-- ERP RESTORAN - 008: PELANGGAN (MEMBER & POIN) + PROMO / VOUCHER
--   Permission baru: crm.manage (kelola pelanggan, promo, pengaturan poin)
-- =====================================================================

-- =====================================================================
-- TABEL
-- =====================================================================
create table crm_settings (
  company_id           uuid primary key references sys_companies(id),
  is_points_enabled    boolean not null default true,
  earn_amount          numeric(15,2) not null default 10000,  -- belanja Rp X = 1 poin
  redeem_value         numeric(15,2) not null default 100,    -- 1 poin = Rp Y
  min_redeem_points    int not null default 100,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (earn_amount > 0 and redeem_value >= 0 and min_redeem_points >= 0)
);

create table crm_membership_tiers (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  name               text not null,                 -- Regular, Silver, Gold
  min_total_spent    numeric(15,2) not null default 0,
  point_multiplier   numeric(5,2) not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_id, name)
);

create table crm_customers (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  code            text not null,
  name            text not null,
  phone           text not null check (phone ~ '^[0-9]{8,15}$'),   -- hanya angka, mis. 6281234567890
  email           text,
  birth_date      date,
  note            text,
  tier_id         uuid references crm_membership_tiers(id),
  points_balance  int not null default 0,
  total_spent     numeric(15,2) not null default 0,
  visit_count     int not null default 0,
  last_visit_at   timestamptz,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code),
  unique (company_id, phone)
);

create table crm_point_transactions (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  customer_id       uuid not null references crm_customers(id) on delete cascade,
  order_id          uuid references pos_orders(id),
  transaction_type  text not null,     -- earn / redeem / adjust
  points            int not null,      -- + masuk, - keluar
  balance_after     int not null,
  note              text,
  created_by        uuid references sys_users(id),
  created_at        timestamptz not null default now()
);

create index idx_crm_point_transactions_customer on crm_point_transactions(customer_id, created_at);

create table crm_promotions (
  id                        uuid primary key default gen_random_uuid(),
  company_id                uuid not null references sys_companies(id),
  name                      text not null,
  voucher_code              text,             -- null = promo otomatis
  discount_type             text not null default 'percent',   -- percent / amount
  discount_value            numeric(15,2) not null check (discount_value > 0),
  max_discount              numeric(15,2),    -- batas maksimal potongan (untuk persen)
  min_subtotal              numeric(15,2) not null default 0,
  start_date                date,
  end_date                  date,
  days_of_week              int[],            -- 1=Senin ... 7=Minggu, null = setiap hari
  start_time                time,             -- happy hour, null = sepanjang hari
  end_time                  time,
  outlet_ids                uuid[],           -- null = semua outlet
  sales_channels            text[],           -- null = semua kanal
  menu_item_ids             uuid[],           -- null & category null = semua menu
  menu_category_ids         uuid[],
  requires_member           boolean not null default false,
  usage_limit               int,              -- kuota total, null = tanpa batas
  usage_count               int not null default 0,
  per_customer_limit        int,
  is_active                 boolean not null default true,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  check (discount_type in ('percent', 'amount')),
  check (discount_type <> 'percent' or discount_value <= 100)
);

create unique index uq_crm_promotions_voucher on crm_promotions(company_id, upper(voucher_code)) where voucher_code is not null;

-- Kolom baru di order
alter table pos_orders add column customer_id      uuid references crm_customers(id);
alter table pos_orders add column promotion_id     uuid references crm_promotions(id);
alter table pos_orders add column promotion_amount numeric(15,2) not null default 0;
alter table pos_orders add column points_redeemed  int not null default 0;
alter table pos_orders add column points_amount    numeric(15,2) not null default 0;
alter table pos_orders add column points_earned    int not null default 0;
create index idx_pos_orders_customer on pos_orders(customer_id);

select sys_attach_updated_at_triggers();

select sys_apply_company_policies('crm_settings', 'crm.manage');
select sys_apply_company_policies('crm_membership_tiers', 'crm.manage');
select sys_apply_company_policies('crm_promotions', 'crm.manage');
select sys_apply_company_policies('crm_point_transactions');   -- hanya lewat fungsi
select sys_apply_company_policies('crm_customers', 'crm.manage');

-- Saldo poin & statistik tidak boleh diubah langsung
revoke update on crm_customers from authenticated, anon;
grant update (name, phone, email, birth_date, note, is_active) on crm_customers to authenticated;

-- =====================================================================
-- HELPER
-- =====================================================================
create or replace function crm_get_settings(p_company_id uuid)
returns crm_settings language plpgsql security definer set search_path = public as $$
declare v crm_settings%rowtype;
begin
  insert into crm_settings (company_id) values (p_company_id) on conflict do nothing;
  select * into v from crm_settings where company_id = p_company_id;
  return v;
end $$;

-- Daftarkan member (boleh dilakukan kasir dari POS)
create or replace function crm_register_customer(p_name text, p_phone text, p_email text default null, p_birth_date date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_phone   text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_cust    crm_customers%rowtype;
begin
  if not (sys_has_permission('pos.order') or sys_has_permission('crm.manage')) then
    raise exception 'Tidak punya izin mendaftarkan pelanggan';
  end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Nama wajib diisi'; end if;
  if v_phone like '0%' then v_phone := '62' || substr(v_phone, 2); end if;
  if v_phone !~ '^[0-9]{8,15}$' then raise exception 'Nomor HP tidak valid'; end if;
  if exists (select 1 from crm_customers where company_id = v_company and phone = v_phone) then
    raise exception 'Nomor HP % sudah terdaftar', v_phone;
  end if;

  insert into crm_customers (company_id, code, name, phone, email, birth_date, tier_id)
  values (v_company, 'MBR-' || lpad(sys_next_sequence(v_company, 'MBR')::text, 6, '0'),
          trim(p_name), v_phone, nullif(trim(p_email), ''), p_birth_date,
          (select id from crm_membership_tiers where company_id = v_company order by min_total_spent limit 1))
  returning * into v_cust;
  return to_jsonb(v_cust);
end $$;

-- Cari member dari POS (kasir tidak perlu crm.manage)
create or replace function crm_search_customers(p_query text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'phone', c.phone,
                              'points_balance', c.points_balance, 'tier_name', t.name) x
    from crm_customers c left join crm_membership_tiers t on t.id = c.tier_id
    where c.company_id = sys_current_company_id() and c.is_active
      and (sys_has_permission('pos.order') or sys_has_permission('crm.manage'))
      and length(trim(coalesce(p_query, ''))) >= 2
      and (c.name ilike '%' || trim(p_query) || '%' or c.phone like '%' || regexp_replace(p_query, '[^0-9]', '', 'g') || '%'
           or c.code ilike '%' || trim(p_query) || '%')
    limit 20
  ) s
$$;

-- Hitung potongan sebuah promo untuk sebuah order. null = tidak memenuhi syarat.
create or replace function crm_calculate_promotion(p_order_id uuid, p_promotion_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare
  p          crm_promotions%rowtype;
  o          pos_orders%rowtype;
  v_local    timestamp;
  v_eligible numeric(15,2);
  v_disc     numeric(15,2);
begin
  select * into p from crm_promotions where id = p_promotion_id and is_active;
  if not found then return null; end if;
  select * into o from pos_orders where id = p_order_id and company_id = p.company_id;
  if not found then return null; end if;

  select now() at time zone timezone into v_local from sys_outlets where id = o.outlet_id;

  if p.start_date is not null and v_local::date < p.start_date then return null; end if;
  if p.end_date   is not null and v_local::date > p.end_date   then return null; end if;
  if p.days_of_week is not null and not (extract(isodow from v_local)::int = any(p.days_of_week)) then return null; end if;
  if p.start_time is not null and v_local::time < p.start_time then return null; end if;
  if p.end_time   is not null and v_local::time > p.end_time   then return null; end if;
  if p.outlet_ids is not null and not (o.outlet_id = any(p.outlet_ids)) then return null; end if;
  if p.sales_channels is not null and not (o.sales_channel = any(p.sales_channels)) then return null; end if;
  if p.usage_limit is not null and p.usage_count >= p.usage_limit then return null; end if;
  if p.requires_member and o.customer_id is null then return null; end if;
  if p.per_customer_limit is not null and o.customer_id is not null and (
       select count(*) from pos_orders
       where customer_id = o.customer_id and promotion_id = p.id and status = 'paid') >= p.per_customer_limit then
    return null;
  end if;

  select coalesce(sum(oi.line_total), 0) into v_eligible
  from pos_order_items oi join mst_menu_items mi on mi.id = oi.menu_item_id
  where oi.order_id = o.id and not oi.is_void
    and ((p.menu_item_ids is null and p.menu_category_ids is null)
         or mi.id = any(coalesce(p.menu_item_ids, '{}'))
         or mi.menu_category_id = any(coalesce(p.menu_category_ids, '{}')));

  if v_eligible <= 0 or v_eligible < p.min_subtotal then return null; end if;

  v_disc := case when p.discount_type = 'percent' then round(v_eligible * p.discount_value / 100)
                 else least(p.discount_value, v_eligible) end;
  if p.max_discount is not null then v_disc := least(v_disc, p.max_discount); end if;
  return v_disc;
end $$;

-- =====================================================================
-- HITUNG ULANG ORDER (versi baru: + promo + tukar poin)
--   subtotal - diskon manual - promo - poin -> + service -> + pajak -> pembulatan
--   Tanpa voucher, promo otomatis terbaik dipilih sendiri (mis. happy hour).
-- =====================================================================
create or replace function pos_recalculate_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order    pos_orders%rowtype;
  v_outlet   sys_outlets%rowtype;
  v_settings crm_settings%rowtype;
  v_sub      numeric(15,2);
  v_promo_id uuid;
  v_promo    numeric(15,2) := 0;
  v_points   numeric(15,2) := 0;
  v_base     numeric(15,2);
  v_service  numeric(15,2);
  v_tax      numeric(15,2);
  v_raw      numeric(15,2);
  v_total    numeric(15,2);
begin
  select * into v_order from pos_orders where id = p_order_id;
  select * into v_outlet from sys_outlets where id = v_order.outlet_id;
  v_settings := crm_get_settings(v_order.company_id);

  select coalesce(sum(line_total), 0) into v_sub
  from pos_order_items where order_id = p_order_id and not is_void;

  -- voucher yang dipilih kasir
  v_promo_id := v_order.promotion_id;
  if v_promo_id is not null and exists (select 1 from crm_promotions where id = v_promo_id and voucher_code is not null) then
    v_promo := crm_calculate_promotion(p_order_id, v_promo_id);
    if v_promo is null then v_promo_id := null; v_promo := 0; end if;   -- tidak lagi memenuhi syarat
  else
    v_promo_id := null;
  end if;

  -- promo otomatis terbaik
  if v_promo_id is null then
    select id, d into v_promo_id, v_promo from (
      select p.id, crm_calculate_promotion(p_order_id, p.id) d
      from crm_promotions p
      where p.company_id = v_order.company_id and p.is_active and p.voucher_code is null
    ) x where d is not null order by d desc limit 1;
    v_promo := coalesce(v_promo, 0);
  end if;

  v_promo := least(v_promo, greatest(v_sub - v_order.discount_amount, 0));

  if v_order.points_redeemed > 0 then
    v_points := least(v_order.points_redeemed * v_settings.redeem_value,
                      greatest(v_sub - v_order.discount_amount - v_promo, 0));
  end if;

  v_base    := greatest(v_sub - v_order.discount_amount - v_promo - v_points, 0);
  v_service := round(v_base * v_outlet.service_charge_rate / 100);
  v_tax     := round((v_base + v_service) * v_outlet.tax_rate / 100);
  v_raw     := v_base + v_service + v_tax;
  v_total   := case when v_outlet.rounding_unit > 1
                    then round(v_raw / v_outlet.rounding_unit) * v_outlet.rounding_unit
                    else v_raw end;

  update pos_orders set
    subtotal         = v_sub,
    promotion_id     = v_promo_id,
    promotion_amount = v_promo,
    points_amount    = v_points,
    service_amount   = v_service,
    tax_amount       = v_tax,
    rounding_amount  = v_total - v_raw,
    grand_total      = v_total
  where id = p_order_id;
end $$;

-- =====================================================================
-- FUNGSI POS UNTUK MEMBER / VOUCHER / POIN
-- =====================================================================
create or replace function pos_lock_open_order(p_order_id uuid)
returns pos_orders language plpgsql security definer set search_path = public as $$
declare v pos_orders%rowtype;
begin
  select * into v from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if v.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  return v;
end $$;

create or replace function pos_set_order_customer(p_order_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v pos_orders%rowtype;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);
  if p_customer_id is not null and not exists (
      select 1 from crm_customers where id = p_customer_id and company_id = v.company_id and is_active) then
    raise exception 'Pelanggan tidak ditemukan';
  end if;
  update pos_orders set customer_id = p_customer_id,
    points_redeemed = case when p_customer_id is distinct from v.customer_id then 0 else points_redeemed end,
    customer_name = coalesce((select name from crm_customers where id = p_customer_id), customer_name)
  where id = p_order_id;
  perform pos_recalculate_order(p_order_id);
  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

-- p_code null = hapus voucher
create or replace function pos_apply_voucher(p_order_id uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  v_promo crm_promotions%rowtype;
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);

  if coalesce(trim(p_code), '') = '' then
    update pos_orders set promotion_id = null where id = p_order_id;
  else
    select * into v_promo from crm_promotions
    where company_id = v.company_id and upper(voucher_code) = upper(trim(p_code));
    if not found then raise exception 'Kode voucher tidak ditemukan'; end if;
    if crm_calculate_promotion(p_order_id, v_promo.id) is null then
      raise exception 'Voucher % tidak memenuhi syarat (cek periode, minimal belanja, member, atau kuota)', v_promo.voucher_code;
    end if;
    update pos_orders set promotion_id = v_promo.id where id = p_order_id;
  end if;

  perform pos_recalculate_order(p_order_id);
  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

create or replace function pos_redeem_points(p_order_id uuid, p_points int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       pos_orders%rowtype;
  v_cust  crm_customers%rowtype;
  v_set   crm_settings%rowtype;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin'; end if;
  v := pos_lock_open_order(p_order_id);
  v_set := crm_get_settings(v.company_id);
  p_points := coalesce(p_points, 0);

  if p_points > 0 then
    if not v_set.is_points_enabled then raise exception 'Program poin tidak aktif'; end if;
    if v.customer_id is null then raise exception 'Pilih member terlebih dahulu'; end if;
    select * into v_cust from crm_customers where id = v.customer_id;
    if p_points > v_cust.points_balance then raise exception 'Poin tidak cukup (saldo %)', v_cust.points_balance; end if;
    if p_points < v_set.min_redeem_points then raise exception 'Minimal tukar % poin', v_set.min_redeem_points; end if;
  end if;

  update pos_orders set points_redeemed = greatest(p_points, 0) where id = p_order_id;
  perform pos_recalculate_order(p_order_id);
  select * into v from pos_orders where id = p_order_id;
  return to_jsonb(v);
end $$;

-- Koreksi / bonus poin manual
create or replace function crm_adjust_points(p_customer_id uuid, p_points int, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_cust crm_customers%rowtype;
begin
  if not sys_has_permission('crm.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(p_points, 0) = 0 then raise exception 'Jumlah poin tidak boleh 0'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Alasan wajib diisi'; end if;
  select * into v_cust from crm_customers
  where id = p_customer_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Pelanggan tidak ditemukan'; end if;
  if v_cust.points_balance + p_points < 0 then raise exception 'Saldo poin tidak boleh minus'; end if;

  update crm_customers set points_balance = points_balance + p_points where id = p_customer_id;
  insert into crm_point_transactions (company_id, customer_id, transaction_type, points, balance_after, note, created_by)
  values (v_cust.company_id, p_customer_id, 'adjust', p_points, v_cust.points_balance + p_points, trim(p_note), auth.uid());
  return v_cust.points_balance + p_points;
end $$;

-- =====================================================================
-- SAAT ORDER LUNAS: poin, statistik member, kuota promo
-- =====================================================================
create or replace function crm_post_order_paid(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o        pos_orders%rowtype;
  v_cust   crm_customers%rowtype;
  v_set    crm_settings%rowtype;
  v_mult   numeric;
  v_earned int := 0;
  v_balance int;
begin
  select * into o from pos_orders where id = p_order_id;

  if o.promotion_id is not null then
    update crm_promotions set usage_count = usage_count + 1 where id = o.promotion_id;
  end if;

  if o.customer_id is null then return; end if;
  select * into v_cust from crm_customers where id = o.customer_id for update;
  v_set := crm_get_settings(o.company_id);
  v_balance := v_cust.points_balance;

  if o.points_redeemed > 0 then
    if o.points_redeemed > v_balance then
      raise exception 'Poin member tidak cukup (saldo %, ditukar %)', v_balance, o.points_redeemed;
    end if;
    v_balance := v_balance - o.points_redeemed;
    insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
    values (o.company_id, o.customer_id, o.id, 'redeem', -o.points_redeemed, v_balance, 'Tukar poin ' || o.order_number, auth.uid());
  end if;

  if v_set.is_points_enabled then
    select coalesce(point_multiplier, 1) into v_mult from crm_membership_tiers where id = v_cust.tier_id;
    v_earned := floor((o.subtotal - o.discount_amount - o.promotion_amount - o.points_amount)
                      / v_set.earn_amount * coalesce(v_mult, 1));
    if v_earned > 0 then
      v_balance := v_balance + v_earned;
      insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
      values (o.company_id, o.customer_id, o.id, 'earn', v_earned, v_balance, 'Belanja ' || o.order_number, auth.uid());
    end if;
  end if;

  update pos_orders set points_earned = v_earned where id = o.id;

  update crm_customers c set
    points_balance = v_balance,
    total_spent    = c.total_spent + o.grand_total,
    visit_count    = c.visit_count + 1,
    last_visit_at  = now(),
    tier_id        = coalesce((select t.id from crm_membership_tiers t
                               where t.company_id = c.company_id and t.min_total_spent <= c.total_spent + o.grand_total
                               order by t.min_total_spent desc limit 1), c.tier_id)
  where c.id = o.customer_id;
end $$;

-- Jurnal penjualan: semua potongan (manual + promo + poin) masuk akun Diskon Penjualan
create or replace function fin_post_sales_journal(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  o       pos_orders%rowtype;
  c       uuid;
  v_lines jsonb;
  v_cogs  numeric;
begin
  select * into o from pos_orders where id = p_order_id and status = 'paid';
  if not found then return; end if;
  if exists (select 1 from fin_journals where source_type = 'sales' and source_id = o.id) then return; end if;
  c := o.company_id;
  if not exists (select 1 from fin_accounts where company_id = c) then return; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'account_id', coalesce(m.account_id, fin_account_id(c, 'cash')),
           'debit', p.amount - p.change_amount, 'note', m.name)), '[]'::jsonb)
    into v_lines
  from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
  where p.order_id = o.id;

  v_cogs := -fin_stock_value('pos_orders', o.id);

  v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id', fin_account_id(c, 'sales_discount'),  'debit',  o.discount_amount + o.promotion_amount + o.points_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'sales_revenue'),   'credit', o.subtotal),
    jsonb_build_object('account_id', fin_account_id(c, 'service_revenue'), 'credit', o.service_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'tax_payable'),     'credit', o.tax_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'rounding'),        'credit', o.rounding_amount),
    jsonb_build_object('account_id', fin_account_id(c, 'cogs'),            'debit',  v_cogs),
    jsonb_build_object('account_id', fin_account_id(c, 'inventory'),       'credit', v_cogs)
  );

  perform fin_create_journal(c, o.outlet_id, o.business_date, 'sales', o.id,
                             'Penjualan ' || o.order_number, v_lines);
end $$;

create or replace function pos_on_order_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform inv_post_order_consumption(new.id);
  perform crm_post_order_paid(new.id);
  perform fin_post_sales_journal(new.id);
  return new;
end $$;

-- =====================================================================
-- DATA AWAL & PERMISSION
-- =====================================================================
create or replace function crm_setup_defaults(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform crm_get_settings(p_company_id);
  insert into crm_membership_tiers (company_id, name, min_total_spent, point_multiplier) values
    (p_company_id, 'Regular', 0, 1),
    (p_company_id, 'Silver',  1000000, 1.25),
    (p_company_id, 'Gold',    5000000, 1.5)
  on conflict do nothing;
end $$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop
    perform crm_setup_defaults(r.id);
  end loop;
end $$;

-- Perusahaan baru: bungkus lagi fungsi onboarding
alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v2;
revoke execute on function sys_onboard_company_v2(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v2(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform crm_setup_defaults((v_result->>'company_id')::uuid);
  if p_with_demo_data then
    insert into crm_promotions (company_id, name, discount_type, discount_value, days_of_week, start_time, end_time, sales_channels)
    values ((v_result->>'company_id')::uuid, 'Happy Hour 14:00-17:00', 'percent', 15, '{1,2,3,4,5}', '14:00', '17:00', '{dine_in,takeaway}');
    insert into crm_promotions (company_id, name, voucher_code, discount_type, discount_value, min_subtotal, requires_member, per_customer_limit)
    values ((v_result->>'company_id')::uuid, 'Member Baru Rp 20.000', 'WELCOME20', 'amount', 20000, 75000, true, 1);
  end if;
  return v_result;
end $$;

update sys_roles set permissions = permissions || '["crm.manage"]'::jsonb
where code = 'manager' and not permissions ? 'crm.manage';

revoke execute on function crm_get_settings(uuid)                    from public, anon, authenticated;
revoke execute on function crm_calculate_promotion(uuid, uuid)       from public, anon, authenticated;
revoke execute on function crm_post_order_paid(uuid)                 from public, anon, authenticated;
revoke execute on function crm_setup_defaults(uuid)                  from public, anon, authenticated;
revoke execute on function pos_lock_open_order(uuid)                 from public, anon, authenticated;
revoke execute on function fin_post_sales_journal(uuid)              from public, anon, authenticated;

-- >>>>>>>>>> migrations/009_qr_order.sql
-- =====================================================================
-- ERP RESTORAN - 009: QR SELF-ORDER
--   Tamu scan QR meja -> lihat menu -> pesan. Tanpa login.
--   Item dari QR berstatus 'waiting' sampai kasir konfirmasi
--   (bisa dimatikan per outlet: qr_requires_confirmation = false).
-- =====================================================================

alter table mst_tables add column qr_token text not null default replace(gen_random_uuid()::text, '-', '');
create unique index uq_mst_tables_qr_token on mst_tables(qr_token);

alter table sys_outlets add column is_qr_order_enabled      boolean not null default true;
alter table sys_outlets add column qr_requires_confirmation boolean not null default true;

alter table pos_orders add column order_source text not null default 'pos';   -- pos / qr

-- =====================================================================
-- INTERNAL: buat header order & tambah item (dipakai POS dan QR)
-- =====================================================================
create or replace function pos_create_order_header(
  p_outlet_id uuid, p_table_id uuid, p_sales_channel text, p_customer_name text, p_guest_count int,
  p_note text, p_customer_id uuid, p_order_source text, p_created_by uuid
)
returns pos_orders language plpgsql security definer set search_path = public as $$
declare
  v_outlet sys_outlets%rowtype;
  v_date   date;
  v_key    text;
  v_order  pos_orders%rowtype;
begin
  select * into v_outlet from sys_outlets where id = p_outlet_id;
  v_date := sys_outlet_business_date(p_outlet_id);
  v_key := 'INV/' || v_outlet.code || '/' || to_char(v_date, 'YYYYMMDD');

  insert into pos_orders (
    company_id, outlet_id, table_id, order_number, business_date, sales_channel,
    customer_name, guest_count, note, created_by, customer_id, order_source, shift_id
  ) values (
    v_outlet.company_id, p_outlet_id, p_table_id,
    v_key || '/' || lpad(sys_next_sequence(v_outlet.company_id, v_key)::text, 4, '0'),
    v_date, coalesce(nullif(p_sales_channel, ''), 'dine_in'),
    nullif(trim(p_customer_name), ''), coalesce(p_guest_count, 1), nullif(p_note, ''), p_created_by,
    p_customer_id, p_order_source,
    (select id from pos_shifts where outlet_id = p_outlet_id and user_id = p_created_by and status = 'open' limit 1)
  ) returning * into v_order;

  if p_table_id is not null then
    update mst_tables set status = 'occupied' where id = p_table_id and outlet_id = p_outlet_id;
  end if;
  return v_order;
end $$;

-- items: [{ "menu_item_id", "quantity", "note", "modifier_ids": [] }]
create or replace function pos_add_order_items(p_order_id uuid, p_items jsonb, p_kitchen_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order     pos_orders%rowtype;
  v_item      jsonb;
  v_menu      mst_menu_items%rowtype;
  v_price     numeric(15,2);
  v_mod_total numeric(15,2);
  v_qty       numeric(10,2);
  v_line_id   uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  if jsonb_array_length(coalesce(p_items, '[]')) = 0 then raise exception 'Order tidak punya item'; end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Terlalu banyak item dalam satu pesanan'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_menu from mst_menu_items
    where id = (v_item->>'menu_item_id')::uuid and company_id = v_order.company_id and is_active;
    if not found then raise exception 'Menu tidak ditemukan / tidak aktif'; end if;

    v_qty := coalesce((v_item->>'quantity')::numeric, 1);
    if v_qty <= 0 or v_qty > 99 then raise exception 'Jumlah tidak valid'; end if;

    v_price := coalesce(
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id = v_order.outlet_id and sales_channel = v_order.sales_channel),
      (select price from mst_menu_prices
        where menu_item_id = v_menu.id and outlet_id is null and sales_channel = v_order.sales_channel),
      v_menu.base_price);

    -- hanya modifier yang memang terhubung ke menu ini
    select coalesce(sum(m.extra_price), 0) into v_mod_total
    from mst_modifiers m
    join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id and l.menu_item_id = v_menu.id
    where m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);

    insert into pos_order_items (
      company_id, order_id, menu_item_id, menu_item_name, station,
      quantity, unit_price, modifier_amount, line_total, note, kitchen_status
    ) values (
      v_order.company_id, v_order.id, v_menu.id, v_menu.name, v_menu.station,
      v_qty, v_price, v_mod_total, v_qty * (v_price + v_mod_total),
      left(nullif(trim(v_item->>'note'), ''), 200), p_kitchen_status
    ) returning id into v_line_id;

    insert into pos_order_item_modifiers (company_id, order_item_id, modifier_id, modifier_name, extra_price)
    select v_order.company_id, v_line_id, m.id, m.name, m.extra_price
    from mst_modifiers m
    join mst_menu_item_modifier_groups l on l.modifier_group_id = m.modifier_group_id and l.menu_item_id = v_menu.id
    where m.id in (select jsonb_array_elements_text(coalesce(v_item->'modifier_ids', '[]'))::uuid);
  end loop;

  perform pos_recalculate_order(v_order.id);
end $$;

-- =====================================================================
-- POS: simpan order (versi baru, mendukung customer_id)
-- =====================================================================
create or replace function pos_save_order(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company     uuid := sys_current_company_id();
  v_order_id    uuid := nullif(p_payload->>'order_id', '')::uuid;
  v_outlet_id   uuid;
  v_customer_id uuid := nullif(p_payload->>'customer_id', '')::uuid;
  v_order       pos_orders%rowtype;
begin
  if v_company is null then raise exception 'Anda belum login'; end if;
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin membuat order'; end if;

  if v_customer_id is not null and not exists (
      select 1 from crm_customers where id = v_customer_id and company_id = v_company and is_active) then
    raise exception 'Pelanggan tidak ditemukan';
  end if;

  if v_order_id is null then
    v_outlet_id := (p_payload->>'outlet_id')::uuid;
    if not sys_can_access_outlet(v_outlet_id) then raise exception 'Tidak punya akses ke outlet ini'; end if;
    v_order := pos_create_order_header(
      v_outlet_id, nullif(p_payload->>'table_id', '')::uuid, p_payload->>'sales_channel',
      coalesce(nullif(p_payload->>'customer_name', ''), (select name from crm_customers where id = v_customer_id)),
      (p_payload->>'guest_count')::int, p_payload->>'note', v_customer_id, 'pos', auth.uid());
  else
    select * into v_order from pos_orders where id = v_order_id and company_id = v_company for update;
    if not found then raise exception 'Order tidak ditemukan'; end if;
    if v_order.status <> 'open' then raise exception 'Order sudah ditutup'; end if;
  end if;

  perform pos_add_order_items(v_order.id, p_payload->'items', 'pending');

  select * into v_order from pos_orders where id = v_order.id;
  return to_jsonb(v_order);
end $$;

-- Kasir mengonfirmasi item dari QR -> diteruskan ke dapur
create or replace function pos_confirm_qr_items(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('pos.order') then raise exception 'Tidak punya izin'; end if;
  update pos_order_items set kitchen_status = 'pending'
  where order_id = p_order_id and kitchen_status = 'waiting' and company_id = sys_current_company_id();
end $$;

create or replace function pos_regenerate_table_qr(p_table_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text := replace(gen_random_uuid()::text, '-', '');
begin
  if not sys_has_permission('master.manage') then raise exception 'Tidak punya izin'; end if;
  update mst_tables set qr_token = v_token where id = p_table_id and company_id = sys_current_company_id();
  if not found then raise exception 'Meja tidak ditemukan'; end if;
  return v_token;
end $$;

-- =====================================================================
-- PUBLIK (tanpa login) - diakses dengan token QR meja
-- =====================================================================
create or replace function public_get_table_menu(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_table  mst_tables%rowtype;
  v_outlet sys_outlets%rowtype;
begin
  select * into v_table from mst_tables where qr_token = p_token;
  if not found then raise exception 'QR tidak valid. Silakan minta bantuan pelayan.'; end if;
  select * into v_outlet from sys_outlets where id = v_table.outlet_id;
  if not v_outlet.is_active or not v_outlet.is_qr_order_enabled then
    raise exception 'Pemesanan lewat QR sedang tidak tersedia.';
  end if;

  return jsonb_build_object(
    'outlet', jsonb_build_object('name', v_outlet.name, 'tax_rate', v_outlet.tax_rate,
                                 'service_charge_rate', v_outlet.service_charge_rate,
                                 'requires_confirmation', v_outlet.qr_requires_confirmation),
    'company_name', (select name from sys_companies where id = v_outlet.company_id),
    'table', jsonb_build_object('code', v_table.code),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name)
      from mst_menu_categories c
      where c.company_id = v_outlet.company_id and c.brand_id = v_outlet.brand_id and c.is_active
        and exists (select 1 from mst_menu_items i where i.menu_category_id = c.id and i.is_active)), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'description', i.description, 'image_url', i.image_url,
        'menu_category_id', i.menu_category_id,
        'price', coalesce(
          (select price from mst_menu_prices where menu_item_id = i.id and outlet_id = v_outlet.id and sales_channel = 'dine_in'),
          (select price from mst_menu_prices where menu_item_id = i.id and outlet_id is null and sales_channel = 'dine_in'),
          i.base_price),
        'modifier_groups', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select,
            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'extra_price', m.extra_price)
                                                    order by m.sort_order) from mst_modifiers m where m.modifier_group_id = g.id), '[]'::jsonb)))
          from mst_menu_item_modifier_groups l join mst_modifier_groups g on g.id = l.modifier_group_id
          where l.menu_item_id = i.id), '[]'::jsonb)
      ) order by i.name)
      from mst_menu_items i
      where i.company_id = v_outlet.company_id and i.brand_id = v_outlet.brand_id and i.is_active), '[]'::jsonb)
  );
end $$;

-- Status pesanan yang sedang berjalan di meja ini
create or replace function public_get_table_order(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order_number', o.order_number, 'grand_total', o.grand_total, 'subtotal', o.subtotal,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.menu_item_name, 'quantity', i.quantity, 'line_total', i.line_total, 'note', i.note,
        'kitchen_status', i.kitchen_status,
        'modifiers', (select coalesce(jsonb_agg(m.modifier_name), '[]'::jsonb) from pos_order_item_modifiers m where m.order_item_id = i.id))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb))
  from mst_tables t
  join pos_orders o on o.table_id = t.id and o.status = 'open'
  where t.qr_token = p_token
  order by o.created_at desc
  limit 1
$$;

-- p_items: [{ "menu_item_id", "quantity", "note", "modifier_ids": [] }]
create or replace function public_submit_table_order(p_token text, p_customer_name text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_table  mst_tables%rowtype;
  v_outlet sys_outlets%rowtype;
  v_order  pos_orders%rowtype;
  v_recent int;
begin
  select * into v_table from mst_tables where qr_token = p_token for update;
  if not found then raise exception 'QR tidak valid. Silakan minta bantuan pelayan.'; end if;
  select * into v_outlet from sys_outlets where id = v_table.outlet_id;
  if not v_outlet.is_active or not v_outlet.is_qr_order_enabled then
    raise exception 'Pemesanan lewat QR sedang tidak tersedia.';
  end if;

  -- batas anti-spam: maks 40 item dari QR per meja dalam 10 menit
  select count(*) into v_recent
  from pos_order_items i join pos_orders o on o.id = i.order_id
  where o.table_id = v_table.id and o.order_source = 'qr' and i.created_at > now() - interval '10 minutes';
  if v_recent + jsonb_array_length(coalesce(p_items, '[]')) > 40 then
    raise exception 'Terlalu banyak pesanan dalam waktu singkat. Silakan panggil pelayan.';
  end if;

  -- gabung ke order yang masih terbuka di meja ini, atau buat baru
  select * into v_order from pos_orders
  where table_id = v_table.id and status = 'open'
  order by created_at desc limit 1 for update;

  if not found then
    v_order := pos_create_order_header(v_outlet.id, v_table.id, 'dine_in', left(p_customer_name, 60), 1,
                                       null, null, 'qr', null);
  end if;

  perform pos_add_order_items(v_order.id, p_items,
    case when v_outlet.qr_requires_confirmation then 'waiting' else 'pending' end);

  return public_get_table_order(p_token);
end $$;

-- Order dengan item QR yang belum dikonfirmasi tidak boleh dibayar
create or replace function pos_check_unconfirmed_items()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from pos_order_items where order_id = new.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi. Konfirmasi atau void dulu sebelum bayar.';
  end if;
  return new;
end $$;

create trigger trg_pos_orders_check_unconfirmed
  before update of status on pos_orders
  for each row when (new.status = 'paid' and old.status is distinct from 'paid')
  execute function pos_check_unconfirmed_items();

-- =====================================================================
-- HAK EKSEKUSI
-- =====================================================================
revoke execute on function pos_create_order_header(uuid, uuid, text, text, int, text, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function pos_add_order_items(uuid, jsonb, text) from public, anon, authenticated;

grant execute on function public_get_table_menu(text)                  to anon, authenticated;
grant execute on function public_get_table_order(text)                 to anon, authenticated;
grant execute on function public_submit_table_order(text, text, jsonb) to anon, authenticated;

-- realtime untuk notifikasi pesanan QR (pos_order_items sudah terdaftar)
