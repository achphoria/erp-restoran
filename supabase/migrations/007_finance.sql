-- =====================================================================
-- ERP RESTORAN - 007: KEUANGAN (AKUNTANSI)
--   * Bagan akun (COA) standar restoran
--   * Jurnal OTOMATIS dari: penjualan (+HPP), penerimaan barang,
--     penyesuaian/waste/opname stok, pembayaran supplier, biaya
--   * Jurnal manual, laporan Laba Rugi / Neraca / Buku Besar
--   Permission baru: finance.manage (input), finance.view (laporan)
-- =====================================================================

-- =====================================================================
-- TABEL
-- =====================================================================
create table fin_accounts (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  parent_id       uuid references fin_accounts(id),
  code            text not null,
  name            text not null,
  account_type    text not null,      -- asset / liability / equity / revenue / cogs / expense
  normal_balance  text not null,      -- debit / credit
  is_header       boolean not null default false,   -- header = pengelompokan, tidak bisa dijurnal
  system_key      text,               -- dipakai jurnal otomatis: cash, bank, inventory, ap, ...
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, code),
  unique (company_id, system_key),
  check (account_type in ('asset', 'liability', 'equity', 'revenue', 'cogs', 'expense')),
  check (normal_balance in ('debit', 'credit'))
);

create table fin_journals (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  outlet_id       uuid references sys_outlets(id),
  journal_number  text not null,
  journal_date    date not null,
  source_type     text not null,
    -- sales / purchase_receipt / stock_adjustment / stock_opname / supplier_payment
    -- expense / manual / opening_stock
  source_id       uuid,
  description     text,
  total_amount    numeric(15,2) not null default 0,
  created_by      uuid references sys_users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, journal_number)
);

create unique index uq_fin_journals_source on fin_journals(source_type, source_id)
  where source_id is not null and source_type not in ('manual', 'expense');
create index idx_fin_journals_date on fin_journals(company_id, journal_date);

create table fin_journal_lines (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  journal_id  uuid not null references fin_journals(id) on delete cascade,
  account_id  uuid not null references fin_accounts(id),
  outlet_id   uuid references sys_outlets(id),
  debit       numeric(15,2) not null default 0 check (debit >= 0),
  credit      numeric(15,2) not null default 0 check (credit >= 0),
  note        text,
  created_at  timestamptz not null default now(),
  check (debit = 0 or credit = 0)
);

create index idx_fin_journal_lines_account on fin_journal_lines(account_id);
create index idx_fin_journal_lines_journal on fin_journal_lines(journal_id);

-- Akun kas/bank tujuan untuk setiap metode bayar
alter table mst_payment_methods add column account_id uuid references fin_accounts(id);

-- Hutang supplier
alter table pur_goods_receipts add column paid_amount numeric(15,2) not null default 0;
alter table pur_goods_receipts add column due_date date;

create table fin_supplier_payments (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  supplier_id     uuid not null references pur_suppliers(id),
  account_id      uuid not null references fin_accounts(id),   -- dibayar dari kas/bank
  payment_number  text not null,
  payment_date    date not null default current_date,
  amount          numeric(15,2) not null check (amount > 0),
  reference_number text,
  note            text,
  created_by      uuid references sys_users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table fin_supplier_payment_items (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  supplier_payment_id  uuid not null references fin_supplier_payments(id) on delete cascade,
  goods_receipt_id     uuid not null references pur_goods_receipts(id),
  amount               numeric(15,2) not null check (amount > 0),
  created_at           timestamptz not null default now()
);

select sys_attach_updated_at_triggers();

select sys_apply_company_policies('fin_accounts', 'finance.manage');
select sys_apply_company_policies('fin_journals');              -- hanya lewat fungsi
select sys_apply_company_policies('fin_journal_lines');
select sys_apply_company_policies('fin_supplier_payments');
select sys_apply_company_policies('fin_supplier_payment_items');

-- Data keuangan hanya bisa dibaca role yang punya finance.view / finance.manage
do $$
declare t text;
begin
  foreach t in array array['fin_accounts', 'fin_journals', 'fin_journal_lines',
                           'fin_supplier_payments', 'fin_supplier_payment_items'] loop
    execute format('drop policy %I on %I', t || '_select', t);
    execute format(
      'create policy %I on %I for select to authenticated
       using (company_id = sys_current_company_id()
              and (sys_has_permission(''finance.view'') or sys_has_permission(''finance.manage'')))',
      t || '_select', t);
  end loop;
end $$;

-- =====================================================================
-- COA STANDAR RESTORAN
-- =====================================================================
create or replace function fin_setup_default_accounts(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;

  insert into fin_accounts (company_id, code, name, account_type, normal_balance, is_header, system_key)
  select p_company_id, a.code, a.name, a.type,
         coalesce(a.normal, case when a.type in ('asset', 'cogs', 'expense') then 'debit' else 'credit' end),
         a.header, a.skey
  from (values
    ('1-0000', 'ASET',                              'asset',     null::text, true,  null::text),
    ('1-1100', 'Kas',                               'asset',     null, false, 'cash'),
    ('1-1200', 'Bank',                              'asset',     null, false, 'bank'),
    ('1-1300', 'Piutang Usaha',                     'asset',     null, false, 'ar'),
    ('1-1400', 'Persediaan Bahan Baku',             'asset',     null, false, 'inventory'),
    ('1-1500', 'Biaya Dibayar di Muka',             'asset',     null, false, null),
    ('1-2100', 'Peralatan Dapur & Restoran',        'asset',     null, false, null),
    ('1-2200', 'Akumulasi Penyusutan',              'asset',     'credit', false, null),
    ('2-0000', 'KEWAJIBAN',                         'liability', null, true,  null),
    ('2-1100', 'Hutang Usaha',                      'liability', null, false, 'ap'),
    ('2-1200', 'Hutang Pajak Restoran (PB1)',       'liability', null, false, 'tax_payable'),
    ('2-1300', 'Hutang Gaji',                       'liability', null, false, null),
    ('3-0000', 'EKUITAS',                           'equity',    null, true,  null),
    ('3-1100', 'Modal Pemilik',                     'equity',    null, false, 'owner_equity'),
    ('3-1200', 'Ekuitas Saldo Awal',                'equity',    null, false, 'opening_equity'),
    ('3-1300', 'Prive / Penarikan Pemilik',         'equity',    'debit', false, null),
    ('4-0000', 'PENDAPATAN',                        'revenue',   null, true,  null),
    ('4-1100', 'Penjualan Makanan & Minuman',       'revenue',   null, false, 'sales_revenue'),
    ('4-1200', 'Pendapatan Service Charge',         'revenue',   null, false, 'service_revenue'),
    ('4-1300', 'Diskon Penjualan',                  'revenue',   'debit', false, 'sales_discount'),
    ('4-1400', 'Selisih Pembulatan',                'revenue',   null, false, 'rounding'),
    ('4-1500', 'Pendapatan Lain-lain',              'revenue',   null, false, null),
    ('5-0000', 'HARGA POKOK PENJUALAN',             'cogs',      null, true,  null),
    ('5-1100', 'HPP Bahan Baku',                    'cogs',      null, false, 'cogs'),
    ('5-1200', 'Bahan Terbuang (Waste)',            'cogs',      null, false, 'waste_expense'),
    ('5-1300', 'Selisih Stok',                      'cogs',      null, false, 'inventory_adjustment'),
    ('6-0000', 'BEBAN OPERASIONAL',                 'expense',   null, true,  null),
    ('6-1100', 'Beban Gaji & Upah',                 'expense',   null, false, null),
    ('6-1200', 'Beban Sewa Tempat',                 'expense',   null, false, null),
    ('6-1300', 'Beban Listrik, Air & Gas',          'expense',   null, false, null),
    ('6-1400', 'Beban Internet & Telepon',          'expense',   null, false, null),
    ('6-1500', 'Beban Pemasaran & Promosi',         'expense',   null, false, null),
    ('6-1600', 'Beban Perlengkapan & Kemasan',      'expense',   null, false, null),
    ('6-1700', 'Beban Komisi Ojek Online',          'expense',   null, false, null),
    ('6-1800', 'Beban Admin Bank & MDR',            'expense',   null, false, null),
    ('6-1900', 'Beban Perbaikan & Perawatan',       'expense',   null, false, null),
    ('6-2000', 'Beban Penyusutan',                  'expense',   null, false, null),
    ('6-9900', 'Beban Lain-lain',                   'expense',   null, false, null)
  ) as a(code, name, type, normal, header, skey);

  -- induk = header dengan digit pertama yang sama
  update fin_accounts a set parent_id = h.id
  from fin_accounts h
  where a.company_id = p_company_id and h.company_id = p_company_id
    and h.is_header and not a.is_header and left(a.code, 1) = left(h.code, 1);

  -- metode bayar: tunai -> Kas, lainnya -> Bank
  update mst_payment_methods m set account_id = (
    select id from fin_accounts
    where company_id = p_company_id and system_key = case when m.type = 'cash' then 'cash' else 'bank' end)
  where m.company_id = p_company_id and m.account_id is null;
end $$;

create or replace function fin_account_id(p_company_id uuid, p_key text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from fin_accounts where company_id = p_company_id and system_key = p_key;
  if v_id is null then raise exception 'Akun sistem "%" belum ada. Jalankan setup akun.', p_key; end if;
  return v_id;
end $$;

-- =====================================================================
-- MESIN JURNAL
-- p_lines: [{ "account_id": uuid, "debit": 0, "credit": 0, "note": "" }]
-- Baris bernilai 0 dilewati. Debit harus = kredit.
-- =====================================================================
create or replace function fin_create_journal(
  p_company_id uuid, p_outlet_id uuid, p_date date, p_source_type text, p_source_id uuid,
  p_description text, p_lines jsonb
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_debit  numeric(15,2);
  v_credit numeric(15,2);
begin
  select coalesce(sum(round(coalesce((l->>'debit')::numeric, 0), 2)), 0),
         coalesce(sum(round(coalesce((l->>'credit')::numeric, 0), 2)), 0)
    into v_debit, v_credit
  from jsonb_array_elements(p_lines) l;

  if v_debit <> v_credit then
    raise exception 'Jurnal tidak seimbang: debit % <> kredit %', v_debit, v_credit;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(p_lines) l
    where round(coalesce((l->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((l->>'credit')::numeric, 0), 2) <> 0) then
    return null;
  end if;

  insert into fin_journals (company_id, outlet_id, journal_number, journal_date, source_type, source_id,
                            description, created_by)
  values (p_company_id, p_outlet_id, sys_next_document_number(p_company_id, 'JRN', p_date), p_date,
          p_source_type, p_source_id, p_description, auth.uid())
  returning id into v_id;

  insert into fin_journal_lines (company_id, journal_id, account_id, outlet_id, debit, credit, note)
  select p_company_id, v_id, (l->>'account_id')::uuid, p_outlet_id,
         -- angka negatif dipindah ke sisi seberangnya
         greatest(round(coalesce((l->>'debit')::numeric, 0), 2), 0) + greatest(-round(coalesce((l->>'credit')::numeric, 0), 2), 0),
         greatest(round(coalesce((l->>'credit')::numeric, 0), 2), 0) + greatest(-round(coalesce((l->>'debit')::numeric, 0), 2), 0),
         nullif(l->>'note', '')
  from jsonb_array_elements(p_lines) l
  where round(coalesce((l->>'debit')::numeric, 0), 2) <> 0 or round(coalesce((l->>'credit')::numeric, 0), 2) <> 0;

  update fin_journals set total_amount = (select sum(debit) from fin_journal_lines where journal_id = v_id)
  where id = v_id;

  return v_id;
end $$;

-- Nilai persediaan dari kartu stok sebuah dokumen (negatif = keluar)
create or replace function fin_stock_value(p_reference_type text, p_reference_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(round(sum(quantity * coalesce(unit_cost, 0)), 2), 0)
  from inv_stock_movements where reference_type = p_reference_type and reference_id = p_reference_id
$$;

-- =====================================================================
-- JURNAL OTOMATIS
-- =====================================================================

-- Penjualan:  Dr Kas/Bank, Dr Diskon | Cr Penjualan, Cr Service, Cr PB1, +/- Pembulatan
-- HPP:        Dr HPP | Cr Persediaan
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
    jsonb_build_object('account_id', fin_account_id(c, 'sales_discount'),  'debit',  o.discount_amount),
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

-- Penerimaan barang: Dr Persediaan | Cr Hutang Usaha
create or replace function fin_post_goods_receipt_journal(p_receipt_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g pur_goods_receipts%rowtype;
  v_supplier text;
begin
  select * into g from pur_goods_receipts where id = p_receipt_id and status = 'posted';
  if not found or not exists (select 1 from fin_accounts where company_id = g.company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = 'purchase_receipt' and source_id = g.id) then return; end if;
  select name into v_supplier from pur_suppliers where id = g.supplier_id;

  perform fin_create_journal(g.company_id, null, g.receipt_date, 'purchase_receipt', g.id,
    'Pembelian ' || g.receipt_number || ' - ' || v_supplier,
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(g.company_id, 'inventory'), 'debit', g.grand_total),
      jsonb_build_object('account_id', fin_account_id(g.company_id, 'ap'), 'credit', g.grand_total)));
end $$;

-- Penyesuaian / waste / opname:  selisih nilai stok vs akun Selisih Stok / Waste
create or replace function fin_post_stock_document_journal(
  p_company_id uuid, p_reference_type text, p_reference_id uuid, p_date date,
  p_number text, p_counter_key text, p_source_type text
)
returns void language plpgsql security definer set search_path = public as $$
declare v_value numeric;
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  if exists (select 1 from fin_journals where source_type = p_source_type and source_id = p_reference_id) then return; end if;
  v_value := fin_stock_value(p_reference_type, p_reference_id);

  perform fin_create_journal(p_company_id, null, p_date, p_source_type, p_reference_id,
    'Stok ' || p_number,
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(p_company_id, 'inventory'),  'debit',  v_value),
      jsonb_build_object('account_id', fin_account_id(p_company_id, p_counter_key), 'credit', v_value)));
end $$;

-- Trigger: dipanggil setelah dokumen berstatus posted
create or replace function fin_on_document_posted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'pur_goods_receipts' then
    perform fin_post_goods_receipt_journal(new.id);
  elsif tg_table_name = 'inv_stock_adjustments' then
    perform fin_post_stock_document_journal(new.company_id, 'inv_stock_adjustments', new.id, new.adjustment_date,
      new.adjustment_number,
      case when new.adjustment_type = 'waste' then 'waste_expense' else 'inventory_adjustment' end,
      'stock_adjustment');
  elsif tg_table_name = 'inv_stock_opnames' then
    perform fin_post_stock_document_journal(new.company_id, 'inv_stock_opnames', new.id, new.opname_date,
      new.opname_number, 'inventory_adjustment', 'stock_opname');
  end if;
  return new;
end $$;

create trigger trg_pur_goods_receipts_journal after update of status on pur_goods_receipts
  for each row when (new.status = 'posted' and old.status is distinct from 'posted')
  execute function fin_on_document_posted();
create trigger trg_inv_stock_adjustments_journal after update of status on inv_stock_adjustments
  for each row when (new.status = 'posted' and old.status is distinct from 'posted')
  execute function fin_on_document_posted();
create trigger trg_inv_stock_opnames_journal after update of status on inv_stock_opnames
  for each row when (new.status = 'posted' and old.status is distinct from 'posted')
  execute function fin_on_document_posted();

-- Order lunas: potong stok DULU, baru jurnal (supaya HPP terhitung)
create or replace function pos_on_order_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform inv_post_order_consumption(new.id);
  perform fin_post_sales_journal(new.id);
  return new;
end $$;

-- Jatuh tempo hutang = tanggal terima + termin supplier
create or replace function pur_set_receipt_due_date()
returns trigger language plpgsql as $$
begin
  if new.status = 'posted' and new.due_date is null then
    new.due_date := new.receipt_date + coalesce(
      (select payment_term_days from pur_suppliers where id = new.supplier_id), 0);
  end if;
  return new;
end $$;

create trigger trg_pur_goods_receipts_due_date before update of status on pur_goods_receipts
  for each row execute function pur_set_receipt_due_date();

-- Stok awal (movement tanpa dokumen): Dr Persediaan | Cr Ekuitas Saldo Awal
create or replace function fin_post_opening_stock_journal(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_value numeric;
begin
  if exists (select 1 from fin_journals where company_id = p_company_id and source_type = 'opening_stock') then return; end if;
  select coalesce(round(sum(quantity * coalesce(unit_cost, 0)), 2), 0) into v_value
  from inv_stock_movements where company_id = p_company_id and reference_id is null;

  perform fin_create_journal(p_company_id, null, current_date, 'opening_stock', p_company_id,
    'Saldo awal persediaan',
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(p_company_id, 'inventory'), 'debit', v_value),
      jsonb_build_object('account_id', fin_account_id(p_company_id, 'opening_equity'), 'credit', v_value)));
end $$;

-- =====================================================================
-- FUNGSI UNTUK APLIKASI
-- =====================================================================

-- Catat biaya operasional: Dr Beban | Cr Kas/Bank
create or replace function fin_record_expense(
  p_date date, p_expense_account_id uuid, p_paid_from_account_id uuid,
  p_amount numeric, p_description text, p_outlet_id uuid default null
)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Nominal harus lebih dari 0'; end if;
  if not exists (select 1 from fin_accounts where id = p_expense_account_id and company_id = v_company and not is_header)
     or not exists (select 1 from fin_accounts where id = p_paid_from_account_id and company_id = v_company and not is_header) then
    raise exception 'Akun tidak valid';
  end if;

  return fin_create_journal(v_company, p_outlet_id, coalesce(p_date, current_date), 'expense', null,
    coalesce(nullif(trim(p_description), ''), 'Biaya operasional'),
    jsonb_build_array(
      jsonb_build_object('account_id', p_expense_account_id, 'debit', p_amount),
      jsonb_build_object('account_id', p_paid_from_account_id, 'credit', p_amount)));
end $$;

-- Jurnal manual (bebas, harus seimbang)
create or replace function fin_post_manual_journal(p_date date, p_description text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    where not exists (select 1 from fin_accounts a
                      where a.id = (l->>'account_id')::uuid and a.company_id = v_company and not a.is_header)) then
    raise exception 'Ada akun yang tidak valid / akun header';
  end if;
  return fin_create_journal(v_company, null, coalesce(p_date, current_date), 'manual', null, p_description, p_lines);
end $$;

-- Bayar hutang supplier
-- p_allocations: [{ "goods_receipt_id": uuid, "amount": 100000 }]
create or replace function fin_pay_supplier(
  p_supplier_id uuid, p_account_id uuid, p_payment_date date, p_allocations jsonb, p_reference_number text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_total   numeric(15,2);
  v_pay     fin_supplier_payments%rowtype;
  v_alloc   jsonb;
  v_gr      pur_goods_receipts%rowtype;
begin
  if not sys_has_permission('finance.manage') then raise exception 'Tidak punya izin'; end if;
  if not exists (select 1 from fin_accounts
                 where id = p_account_id and company_id = v_company and account_type = 'asset' and not is_header) then
    raise exception 'Akun pembayaran tidak valid';
  end if;

  select coalesce(sum((a->>'amount')::numeric), 0) into v_total from jsonb_array_elements(p_allocations) a;
  if v_total <= 0 then raise exception 'Nominal pembayaran harus lebih dari 0'; end if;

  insert into fin_supplier_payments (company_id, supplier_id, account_id, payment_number, payment_date,
                                     amount, reference_number, created_by)
  values (v_company, p_supplier_id, p_account_id,
          sys_next_document_number(v_company, 'PAY', coalesce(p_payment_date, current_date)),
          coalesce(p_payment_date, current_date), v_total, p_reference_number, auth.uid())
  returning * into v_pay;

  for v_alloc in select * from jsonb_array_elements(p_allocations) loop
    if (v_alloc->>'amount')::numeric <= 0 then continue; end if;
    select * into v_gr from pur_goods_receipts
    where id = (v_alloc->>'goods_receipt_id')::uuid and company_id = v_company
      and supplier_id = p_supplier_id and status = 'posted'
    for update;
    if not found then raise exception 'Penerimaan barang tidak valid untuk supplier ini'; end if;
    if v_gr.paid_amount + (v_alloc->>'amount')::numeric > v_gr.grand_total then
      raise exception 'Pembayaran % melebihi sisa hutang', v_gr.receipt_number;
    end if;

    insert into fin_supplier_payment_items (company_id, supplier_payment_id, goods_receipt_id, amount)
    values (v_company, v_pay.id, v_gr.id, (v_alloc->>'amount')::numeric);
    update pur_goods_receipts set paid_amount = paid_amount + (v_alloc->>'amount')::numeric where id = v_gr.id;
  end loop;

  perform fin_create_journal(v_company, null, v_pay.payment_date, 'supplier_payment', v_pay.id,
    'Pembayaran supplier ' || v_pay.payment_number,
    jsonb_build_array(
      jsonb_build_object('account_id', fin_account_id(v_company, 'ap'), 'debit', v_total),
      jsonb_build_object('account_id', p_account_id, 'credit', v_total)));

  return to_jsonb(v_pay);
end $$;

-- Saldo akun untuk Neraca Saldo / Laba Rugi / Neraca
--   opening = saldo sebelum p_from, period = mutasi p_from..p_to, closing = opening + period
--   Saldo bertanda sesuai normal balance (positif = saldo normal)
create or replace function fin_get_account_balances(p_from date, p_to date, p_outlet_id uuid default null)
returns table (
  account_id uuid, code text, name text, account_type text, normal_balance text, is_header boolean,
  system_key text, opening_balance numeric, period_debit numeric, period_credit numeric,
  period_balance numeric, closing_balance numeric
)
language sql stable security invoker set search_path = public as $$
  with mv as (
    select l.account_id,
           sum(case when j.journal_date <  p_from then l.debit - l.credit else 0 end) as opening_dc,
           sum(case when j.journal_date >= p_from then l.debit  else 0 end)          as period_debit,
           sum(case when j.journal_date >= p_from then l.credit else 0 end)          as period_credit
    from fin_journal_lines l
    join fin_journals j on j.id = l.journal_id
    where j.journal_date <= p_to and (p_outlet_id is null or l.outlet_id = p_outlet_id)
    group by l.account_id
  )
  select a.id, a.code, a.name, a.account_type, a.normal_balance, a.is_header, a.system_key,
         s.sign * coalesce(mv.opening_dc, 0),
         coalesce(mv.period_debit, 0), coalesce(mv.period_credit, 0),
         s.sign * (coalesce(mv.period_debit, 0) - coalesce(mv.period_credit, 0)),
         s.sign * (coalesce(mv.opening_dc, 0) + coalesce(mv.period_debit, 0) - coalesce(mv.period_credit, 0))
  from fin_accounts a
  cross join lateral (select case when a.normal_balance = 'debit' then 1 else -1 end as sign) s
  left join mv on mv.account_id = a.id
  order by a.code
$$;

-- Daftar hutang per penerimaan barang
create view rpt_payables with (security_invoker = true) as
select g.company_id, g.id as goods_receipt_id, g.receipt_number, g.receipt_date, g.due_date,
       g.supplier_id, s.name as supplier_name, g.supplier_invoice_number,
       g.grand_total, g.paid_amount, g.grand_total - g.paid_amount as outstanding_amount,
       coalesce(g.due_date < current_date, false) and g.grand_total > g.paid_amount as is_overdue
from pur_goods_receipts g
join pur_suppliers s on s.id = g.supplier_id
where g.status = 'posted';

-- =====================================================================
-- ONBOARDING: tambah COA + jurnal stok awal untuk perusahaan baru
-- =====================================================================
-- Metode bayar baru otomatis diarahkan ke akun Kas / Bank
create or replace function mst_on_payment_method_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.account_id is null and exists (select 1 from fin_accounts where company_id = new.company_id) then
    new.account_id := fin_account_id(new.company_id, case when new.type = 'cash' then 'cash' else 'bank' end);
  end if;
  return new;
end $$;

create trigger trg_mst_payment_methods_account before insert on mst_payment_methods
  for each row execute function mst_on_payment_method_created();

-- Bungkus fungsi onboarding lama: setelah selesai, siapkan keuangan
alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_base;
revoke execute on function sys_onboard_company_base(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_base(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform fin_setup_default_accounts((v_result->>'company_id')::uuid);
  perform fin_post_opening_stock_journal((v_result->>'company_id')::uuid);
  return v_result;
end $$;

-- =====================================================================
-- PERMISSION & DATA LAMA
-- =====================================================================
-- Manager boleh melihat laporan keuangan
update sys_roles set permissions = permissions || '["finance.view"]'::jsonb
where code = 'manager' and not permissions ? 'finance.view';

-- Siapkan COA & jurnal untuk perusahaan yang sudah ada (idempotent)
do $$
declare r record;
begin
  for r in select id from sys_companies loop
    perform fin_setup_default_accounts(r.id);
    perform fin_post_opening_stock_journal(r.id);
  end loop;
  for r in select id from pur_goods_receipts where status = 'posted' order by posted_at loop
    perform fin_post_goods_receipt_journal(r.id);
  end loop;
  for r in select id, company_id, adjustment_date, adjustment_number, adjustment_type
           from inv_stock_adjustments where status = 'posted' loop
    perform fin_post_stock_document_journal(r.company_id, 'inv_stock_adjustments', r.id, r.adjustment_date,
      r.adjustment_number, case when r.adjustment_type = 'waste' then 'waste_expense' else 'inventory_adjustment' end,
      'stock_adjustment');
  end loop;
  for r in select id, company_id, opname_date, opname_number from inv_stock_opnames where status = 'posted' loop
    perform fin_post_stock_document_journal(r.company_id, 'inv_stock_opnames', r.id, r.opname_date,
      r.opname_number, 'inventory_adjustment', 'stock_opname');
  end loop;
  for r in select id from pos_orders where status = 'paid' order by paid_at loop
    perform fin_post_sales_journal(r.id);
  end loop;
  update pur_goods_receipts g set due_date = g.receipt_date + s.payment_term_days
  from pur_suppliers s where s.id = g.supplier_id and g.status = 'posted' and g.due_date is null;
end $$;

-- =====================================================================
-- KUNCI FUNGSI INTERNAL
-- =====================================================================
revoke execute on function fin_setup_default_accounts(uuid)                                         from public, anon, authenticated;
revoke execute on function fin_account_id(uuid, text)                                               from public, anon, authenticated;
revoke execute on function fin_create_journal(uuid, uuid, date, text, uuid, text, jsonb)            from public, anon, authenticated;
revoke execute on function fin_stock_value(text, uuid)                                              from public, anon, authenticated;
revoke execute on function fin_post_sales_journal(uuid)                                             from public, anon, authenticated;
revoke execute on function fin_post_goods_receipt_journal(uuid)                                     from public, anon, authenticated;
revoke execute on function fin_post_stock_document_journal(uuid, text, uuid, date, text, text, text) from public, anon, authenticated;
revoke execute on function fin_post_opening_stock_journal(uuid)                                     from public, anon, authenticated;
