-- =====================================================================
-- SANTAP ERP - 021: SETTLEMENT UANG PENDAPATAN POS
--   Per outlet x metode bayar x tanggal bisnis:
--     seharusnya (penjualan - refund)  vs  dana yang benar-benar masuk
--   Tunai : setoran ke bank (Kas -> Bank), selisih setoran dicatat
--   Non tunai (EDC/QRIS/transfer/ojol): penjualan dicatat ke akun penampung
--     "Piutang Settlement", saat dana cair: Bank + potongan MDR/komisi | penampung
-- =====================================================================

create or replace function fin_ensure_settlement_accounts(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance, system_key)
  select p_company_id, (select id from fin_accounts where company_id = p_company_id and code = x.parent),
         x.code, x.name, x.type, x.normal, x.skey
  from (values
    ('1-0000', '1-1320', 'Piutang Settlement (EDC/QRIS/Ojol)', 'asset',   'debit', 'settlement_clearing'),
    ('6-0000', '6-2100', 'Selisih Kas & Settlement',           'expense', 'debit', 'settlement_difference')
  ) as x(parent, code, name, type, normal, skey)
  where not exists (select 1 from fin_accounts a where a.company_id = p_company_id and (a.system_key = x.skey or a.code = x.code));
end $$;

-- ---------------------------------------------------------------------
-- METODE BAYAR: tujuan pencairan & potongan
-- ---------------------------------------------------------------------
alter table mst_payment_methods add column settlement_account_id uuid references fin_accounts(id);  -- dana cair ke (bank)
alter table mst_payment_methods add column fee_account_id        uuid references fin_accounts(id);  -- beban MDR / komisi
alter table mst_payment_methods add column fee_pct               numeric(6,3) not null default 0 check (fee_pct between 0 and 100);
alter table mst_payment_methods add column settlement_from       date not null default current_date; -- penjualan sebelum ini tidak perlu settlement

-- metode non tunai lama: penjualan berikutnya ke akun penampung, cair ke bank
create or replace function fin_setup_payment_settlement(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  perform fin_ensure_settlement_accounts(p_company_id);
  update mst_payment_methods m set
    settlement_account_id = coalesce(m.settlement_account_id,
      case when m.type = 'cash' then fin_account_id(p_company_id, 'bank')
           else coalesce(nullif(m.account_id, fin_account_id(p_company_id, 'cash')), fin_account_id(p_company_id, 'bank')) end),
    account_id = case when m.type <> 'cash' and m.account_id = fin_account_id(p_company_id, 'bank')
                      then fin_account_id(p_company_id, 'settlement_clearing') else m.account_id end,
    fee_account_id = coalesce(m.fee_account_id,
      (select id from fin_accounts where company_id = p_company_id and code = case when m.type = 'online' then '6-1700' else '6-1800' end))
  where m.company_id = p_company_id;
end $$;

-- metode bayar baru: non tunai -> akun penampung
create or replace function mst_on_payment_method_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from fin_accounts where company_id = new.company_id) then
    if new.account_id is null then
      new.account_id := case when new.type = 'cash' then fin_account_id(new.company_id, 'cash')
                             else coalesce(fin_account_id_or_null(new.company_id, 'settlement_clearing'), fin_account_id(new.company_id, 'bank')) end;
    end if;
    new.settlement_account_id := coalesce(new.settlement_account_id, fin_account_id_or_null(new.company_id, 'bank'));
    new.fee_account_id := coalesce(new.fee_account_id,
      (select id from fin_accounts where company_id = new.company_id and code = case when new.type = 'online' then '6-1700' else '6-1800' end));
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- SETTLEMENT
-- ---------------------------------------------------------------------
create table pos_settlements (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  outlet_id          uuid not null references sys_outlets(id),
  payment_method_id  uuid not null references mst_payment_methods(id),
  settlement_number  text not null,
  settlement_date    date not null default current_date,   -- tanggal dana masuk / setor
  date_from          date not null,
  date_to            date not null,
  expected_amount    numeric(15,2) not null,                -- penjualan - refund
  received_amount    numeric(15,2) not null check (received_amount >= 0),
  fee_amount         numeric(15,2) not null default 0 check (fee_amount >= 0),
  difference_amount  numeric(15,2) not null default 0,      -- + = kurang terima
  to_account_id      uuid not null references fin_accounts(id),
  reference_number   text,
  note               text,
  created_by         uuid references sys_users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table pos_settlement_items (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  settlement_id      uuid not null references pos_settlements(id) on delete cascade,
  outlet_id          uuid not null references sys_outlets(id),
  payment_method_id  uuid not null references mst_payment_methods(id),
  business_date      date not null,
  sales_amount       numeric(15,2) not null,
  refund_amount      numeric(15,2) not null default 0,
  created_at         timestamptz not null default now(),
  unique (outlet_id, payment_method_id, business_date)
);

-- pendapatan POS per outlet x metode x tanggal + status settlement
create view rpt_pos_settlement_days with (security_invoker = true) as
with sales as (
  select o.company_id, o.outlet_id, p.payment_method_id, o.business_date, sum(p.amount - p.change_amount) amount, count(distinct o.id) orders
  from pos_payments p join pos_orders o on o.id = p.order_id
  where o.status in ('paid', 'refunded')
  group by o.company_id, o.outlet_id, p.payment_method_id, o.business_date
), refunds as (
  select r.company_id, r.outlet_id, rp.payment_method_id, r.business_date, sum(rp.amount) amount
  from pos_refund_payments rp join pos_refunds r on r.id = rp.refund_id
  group by r.company_id, r.outlet_id, rp.payment_method_id, r.business_date
), days as (
  select company_id, outlet_id, payment_method_id, business_date from sales
  union
  select company_id, outlet_id, payment_method_id, business_date from refunds
)
select d.company_id, d.outlet_id, o.name as outlet_name, d.payment_method_id, m.name as payment_method_name, m.type as payment_type,
       d.business_date, coalesce(s.orders, 0) as order_count,
       coalesce(s.amount, 0) as sales_amount, coalesce(r.amount, 0) as refund_amount,
       coalesce(s.amount, 0) - coalesce(r.amount, 0) as net_amount,
       round((coalesce(s.amount, 0) - coalesce(r.amount, 0)) * m.fee_pct / 100, 2) as estimated_fee,
       si.settlement_id, st.settlement_number,
       d.business_date >= m.settlement_from as needs_settlement
from days d
join sys_outlets o on o.id = d.outlet_id
join mst_payment_methods m on m.id = d.payment_method_id
left join sales s on s.outlet_id = d.outlet_id and s.payment_method_id = d.payment_method_id and s.business_date = d.business_date
left join refunds r on r.outlet_id = d.outlet_id and r.payment_method_id = d.payment_method_id and r.business_date = d.business_date
left join pos_settlement_items si on si.outlet_id = d.outlet_id and si.payment_method_id = d.payment_method_id and si.business_date = d.business_date
left join pos_settlements st on st.id = si.settlement_id;

-- Buat settlement: tanggal-tanggal yang belum di-settle untuk 1 outlet & 1 metode
create or replace function pos_create_settlement(
  p_outlet_id uuid, p_payment_method_id uuid, p_dates date[], p_received_amount numeric,
  p_fee_amount numeric default 0, p_to_account_id uuid default null, p_settlement_date date default current_date,
  p_reference text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := sys_current_company_id();
  m          mst_payment_methods%rowtype;
  s          pos_settlements%rowtype;
  v_expected numeric(15,2);
  v_diff     numeric(15,2);
  v_to       uuid;
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  select * into m from mst_payment_methods where id = p_payment_method_id and company_id = v_company;
  if not found then raise exception 'Metode bayar tidak ditemukan'; end if;
  if not exists (select 1 from sys_outlets where id = p_outlet_id and company_id = v_company) then raise exception 'Outlet tidak ditemukan'; end if;
  if coalesce(array_length(p_dates, 1), 0) = 0 then raise exception 'Pilih tanggal yang di-settle'; end if;
  if coalesce(p_received_amount, -1) < 0 or coalesce(p_fee_amount, 0) < 0 then raise exception 'Nominal tidak valid'; end if;

  if exists (select 1 from pos_settlement_items where outlet_id = p_outlet_id and payment_method_id = m.id and business_date = any(p_dates)) then
    raise exception 'Sebagian tanggal sudah pernah di-settle';
  end if;
  select coalesce(sum(net_amount), 0) into v_expected
  from rpt_pos_settlement_days where outlet_id = p_outlet_id and payment_method_id = m.id and business_date = any(p_dates);
  v_diff := v_expected - round(p_received_amount, 2) - round(coalesce(p_fee_amount, 0), 2);
  v_to := coalesce(p_to_account_id, m.settlement_account_id);
  if not exists (select 1 from fin_accounts where id = v_to and company_id = v_company and account_type = 'asset' and not is_header) then
    raise exception 'Pilih akun bank tujuan';
  end if;

  insert into pos_settlements (company_id, outlet_id, payment_method_id, settlement_number, settlement_date, date_from, date_to,
    expected_amount, received_amount, fee_amount, difference_amount, to_account_id, reference_number, note, created_by)
  values (v_company, p_outlet_id, m.id, sys_next_document_number(v_company, 'STL', coalesce(p_settlement_date, current_date)),
    coalesce(p_settlement_date, current_date), (select min(x) from unnest(p_dates) x), (select max(x) from unnest(p_dates) x),
    v_expected, round(p_received_amount, 2), round(coalesce(p_fee_amount, 0), 2), v_diff, v_to,
    nullif(trim(p_reference), ''), nullif(trim(p_note), ''), auth.uid())
  returning * into s;

  insert into pos_settlement_items (company_id, settlement_id, outlet_id, payment_method_id, business_date, sales_amount, refund_amount)
  select v_company, s.id, p_outlet_id, m.id, d.business_date, d.sales_amount, d.refund_amount
  from rpt_pos_settlement_days d
  where d.outlet_id = p_outlet_id and d.payment_method_id = m.id and d.business_date = any(p_dates);
  if not found then raise exception 'Tidak ada penjualan pada tanggal tersebut'; end if;

  -- Bank (diterima) + beban potongan + selisih | akun metode bayar (kas / penampung)
  if exists (select 1 from fin_accounts where company_id = v_company) then
    perform fin_create_journal(v_company, p_outlet_id, s.settlement_date, 'pos_settlement', s.id,
      'Settlement ' || m.name || ' ' || to_char(s.date_from, 'DD/MM') ||
        case when s.date_to <> s.date_from then ' - ' || to_char(s.date_to, 'DD/MM') else '' end,
      jsonb_build_array(
        jsonb_build_object('account_id', v_to, 'debit', s.received_amount, 'note', coalesce(s.reference_number, 'Dana masuk')),
        jsonb_build_object('account_id', coalesce(m.fee_account_id, fin_account_id(v_company, 'settlement_difference')),
                           'debit', s.fee_amount, 'note', 'Potongan MDR / komisi'),
        jsonb_build_object('account_id', fin_account_id(v_company, 'settlement_difference'), 'debit', s.difference_amount, 'note', 'Selisih'),
        jsonb_build_object('account_id', coalesce(m.account_id, fin_account_id(v_company, 'cash')), 'credit', s.expected_amount)));
  end if;
  return to_jsonb(s);
end $$;

-- ---------------------------------------------------------------------
-- RLS & DATA AWAL
-- ---------------------------------------------------------------------
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('pos_settlements');
select sys_apply_company_policies('pos_settlement_items');

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform fin_setup_payment_settlement(r.id); end loop;
end $$;

alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v6;
revoke execute on function sys_onboard_company_v6(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v6(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform fin_setup_payment_settlement((v_result->>'company_id')::uuid);
  return v_result;
end $$;

revoke execute on function fin_ensure_settlement_accounts(uuid)  from public, anon, authenticated;
revoke execute on function fin_setup_payment_settlement(uuid)    from public, anon, authenticated;
