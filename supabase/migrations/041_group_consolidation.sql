-- =====================================================================
-- SEMAR - 041: DASHBOARD GRUP & LAPORAN KONSOLIDASI (Platform tahap 2)
--   * grp_my_groups(): grup usaha yang boleh dilihat (pemilik grup; Platform Admin melihat semua).
--   * grp_dashboard(): ringkasan semua PT dalam grup sekaligus: penjualan bersih (+ pertumbuhan vs
--     periode sebelumnya), tren harian per PT, outlet & menu terlaris, laba rugi singkat, stok menipis,
--     karyawan & kehadiran hari ini, cuti/persetujuan menunggu, rating ulasan.
--   * grp_financials(): laba rugi & neraca per PT + kolom eliminasi + konsolidasi (digabung per kode akun).
--   * fin_journal_lines.counterparty_company_id: lawan transaksi antar-PT. Baris jurnal ke PT lain
--     dalam grup yang sama dieliminasi di konsolidasi (diisi otomatis oleh transaksi antar-PT, tahap 3).
--   Hanya baca. Tidak mengubah data PT mana pun.
-- =====================================================================

alter table fin_journal_lines add column if not exists counterparty_company_id uuid references sys_companies(id);
create index if not exists fin_journal_lines_counterparty on fin_journal_lines (counterparty_company_id) where counterparty_company_id is not null;

-- boleh melihat grup: pemilik grup (user aktif) atau Platform Admin
create or replace function grp_can_view(p_group_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select sys_is_platform_admin() or exists (
    select 1 from sys_group_members m join sys_users u on u.id = m.user_id and u.is_active
    where m.group_id = p_group_id and m.user_id = auth.uid())
$$;

create or replace function grp_my_groups()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'code', g.code, 'name', g.name,
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'logo_url', c.logo_url) order by c.name)
        from sys_companies c where c.group_id = g.id and c.is_active), '[]'::jsonb)) order by g.name), '[]'::jsonb)
  from sys_company_groups g
  where grp_can_view(g.id)
$$;

-- saldo akun satu PT (versi eksplisit dari fin_get_account_balances, tanpa bergantung RLS)
-- p_eliminate_group: baris jurnal dengan lawan transaksi PT lain di grup ini dipisahkan sebagai eliminasi
create or replace function grp_company_balances(p_company_id uuid, p_from date, p_to date, p_group_id uuid)
returns table (code text, name text, account_type text, normal_balance text, is_header boolean,
               period_balance numeric, closing_balance numeric, period_elim numeric, closing_elim numeric)
language sql stable security definer set search_path = public as $$
  with mv as (
    select l.account_id,
      sum(case when j.journal_date <  p_from then l.debit - l.credit else 0 end) as opening_dc,
      sum(case when j.journal_date >= p_from then l.debit - l.credit else 0 end) as period_dc,
      sum(case when j.journal_date >= p_from and ic.id is not null then l.debit - l.credit else 0 end) as period_ic,
      sum(case when ic.id is not null then l.debit - l.credit else 0 end) as closing_ic
    from fin_journal_lines l
    join fin_journals j on j.id = l.journal_id
    left join sys_companies ic on ic.id = l.counterparty_company_id and ic.group_id = p_group_id and ic.id <> p_company_id
    where l.company_id = p_company_id and j.journal_date <= p_to
    group by l.account_id
  )
  select a.code, a.name, a.account_type, a.normal_balance, a.is_header,
    s.sign * coalesce(mv.period_dc, 0),
    s.sign * (coalesce(mv.opening_dc, 0) + coalesce(mv.period_dc, 0)),
    s.sign * coalesce(mv.period_ic, 0),
    s.sign * coalesce(mv.closing_ic, 0)
  from fin_accounts a
  -- tanda mengikuti jenis akun (aset/HPP/beban = debit), jadi akun kontra (diskon, akumulasi penyusutan, prive) bernilai minus
  cross join lateral (select case when a.account_type in ('asset', 'cogs', 'expense') then 1 else -1 end as sign) s
  left join mv on mv.account_id = a.id
  where a.company_id = p_company_id
$$;
revoke execute on function grp_company_balances(uuid, date, date, uuid) from public, anon, authenticated;

-- laba rugi (periode) & neraca (per p_to) per PT + eliminasi + konsolidasi, digabung per kode akun
create or replace function grp_financials(p_group_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not grp_can_view(p_group_id) then raise exception 'Anda bukan pemilik grup ini'; end if;
  if p_to < p_from then raise exception 'Rentang tanggal tidak valid'; end if;
  return (
    with cs as (select id, name from sys_companies where group_id = p_group_id and is_active),
    b as (select c.id as company_id, x.* from cs c cross join lateral grp_company_balances(c.id, p_from, p_to, p_group_id) x),
    acc as (
      select code, (array_agg(name order by name))[1] as name, (array_agg(account_type))[1] as account_type, bool_or(is_header) as is_header,
        jsonb_object_agg(company_id, case when account_type in ('revenue', 'cogs', 'expense') then period_balance else closing_balance end) as by_company,
        sum(case when account_type in ('revenue', 'cogs', 'expense') then period_balance else closing_balance end) as total,
        sum(case when account_type in ('revenue', 'cogs', 'expense') then period_elim else closing_elim end) as elimination
      from b group by code
    ),
    -- laba ditahan: akumulasi laba rugi sampai p_to (belum ada jurnal penutup tahunan)
    re as (
      select company_id, sum(case when account_type = 'revenue' then closing_balance else -closing_balance end) as earnings,
             sum(case when account_type = 'revenue' then closing_elim else -closing_elim end) as earnings_elim
      from b where account_type in ('revenue', 'cogs', 'expense') and not is_header group by company_id
    )
    select jsonb_build_object(
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from cs), '[]'::jsonb),
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'account_type', account_type, 'is_header', is_header,
          'by_company', by_company, 'total', total, 'elimination', elimination, 'consolidated', total - elimination) order by code) from acc), '[]'::jsonb),
      'retained_earnings', coalesce((select jsonb_object_agg(company_id, earnings) from re), '{}'::jsonb),
      'retained_earnings_elim', coalesce((select sum(earnings_elim) from re), 0)));
end $$;

-- ringkasan grup
create or replace function grp_dashboard(p_group_id uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_len int := p_to - p_from + 1; v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not grp_can_view(p_group_id) then raise exception 'Anda bukan pemilik grup ini'; end if;
  if p_to < p_from or v_len > 400 then raise exception 'Rentang tanggal tidak valid'; end if;
  return (
    with cs as (select id, name, logo_url from sys_companies where group_id = p_group_id and is_active),
    ord as (
      select o.company_id, o.outlet_id, o.business_date, o.grand_total,
        o.subtotal - o.discount_amount - o.promotion_amount - o.points_amount as net_sales
      from pos_orders o where o.company_id in (select id from cs) and o.status = 'paid' and o.business_date between p_from - v_len and p_to
    ),
    cur as (select * from ord where business_date between p_from and p_to),
    prev as (select * from ord where business_date < p_from),
    pl as (
      select c.id as company_id,
        sum(x.period_balance) filter (where x.account_type = 'revenue' and not x.is_header) as revenue,
        sum(x.period_balance) filter (where x.account_type = 'cogs' and not x.is_header) as cogs,
        sum(x.period_balance) filter (where x.account_type = 'expense' and not x.is_header) as expense
      from cs c cross join lateral grp_company_balances(c.id, p_from, p_to, p_group_id) x group by c.id
    )
    select jsonb_build_object(
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'logo_url', c.logo_url,
          'net_sales', coalesce((select sum(net_sales) from cur where company_id = c.id), 0),
          'gross_sales', coalesce((select sum(grand_total) from cur where company_id = c.id), 0),
          'orders', (select count(*) from cur where company_id = c.id),
          'prev_net_sales', coalesce((select sum(net_sales) from prev where company_id = c.id), 0),
          'outlets', (select count(*) from sys_outlets o where o.company_id = c.id and o.is_active),
          'revenue', coalesce(pl.revenue, 0), 'cogs', coalesce(pl.cogs, 0), 'expense', coalesce(pl.expense, 0),
          'net_profit', coalesce(pl.revenue, 0) - coalesce(pl.cogs, 0) - coalesce(pl.expense, 0),
          'open_orders', (select count(*) from pos_orders o where o.company_id = c.id and o.status = 'open'),
          'low_stock', (select count(*) from rpt_stock_balances s where s.company_id = c.id and s.is_low_stock),
          'employees', (select count(*) from hr_employees e where e.company_id = c.id and e.is_active),
          'present_today', (select count(*) from hr_attendances a where a.company_id = c.id and a.work_date = v_today and a.check_in_at is not null),
          'scheduled_today', (select count(*) from hr_rosters r where r.company_id = c.id and r.work_date = v_today and not r.is_off),
          'pending_leave', (select count(*) from hr_leave_requests l where l.company_id = c.id and l.status = 'pending'),
          'pending_approvals', (select count(*) from sys_approval_requests ar where ar.company_id = c.id and ar.status = 'pending'),
          'rating', (select round(avg(overall), 2) from crm_feedback_responses f where f.company_id = c.id and (f.created_at at time zone 'Asia/Jakarta')::date between p_from and p_to),
          'reviews', (select count(*) from crm_feedback_responses f where f.company_id = c.id and (f.created_at at time zone 'Asia/Jakarta')::date between p_from and p_to))
        order by c.name)
        from cs c left join pl on pl.company_id = c.id), '[]'::jsonb),
      'daily', coalesce((select jsonb_agg(jsonb_build_object('date', d, 'company_id', company_id, 'net_sales', s) order by d)
        from (select business_date as d, company_id, sum(net_sales) as s from cur group by 1, 2) t), '[]'::jsonb),
      'top_outlets', coalesce((select jsonb_agg(jsonb_build_object('outlet', o.name, 'company', c.name, 'net_sales', t.s, 'orders', t.n) order by t.s desc)
        from (select outlet_id, sum(net_sales) as s, count(*) as n from cur group by outlet_id order by 2 desc limit 8) t
        join sys_outlets o on o.id = t.outlet_id join cs c on c.id = o.company_id), '[]'::jsonb),
      'top_menus', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.q, 'revenue', t.r, 'companies', t.cn) order by t.q desc)
        from (select i.menu_item_name as name, sum(i.quantity) as q, sum(i.line_total) as r, count(distinct po.company_id) as cn
              from pos_order_items i join pos_orders po on po.id = i.order_id
              where po.company_id in (select id from cs) and po.status = 'paid' and po.business_date between p_from and p_to and not i.is_void
              group by i.menu_item_name order by 2 desc limit 10) t), '[]'::jsonb)));
end $$;
