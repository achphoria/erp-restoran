-- =====================================================================
-- SEMAR - 044: MANAJEMEN ASET TETAP (tahap 1)
--   * Kategori aset (umur & metode default mengikuti kelompok pajak, akun COA per kategori)
--   * Daftar aset: kode otomatis AST-<kategori>-0001, outlet/lokasi, penanggung jawab, foto, garansi, label QR
--   * Perolehan dijurnal otomatis: tunai/bank, hutang pembelian aset (+ pembayaran), aset lama (saldo awal),
--     atau tanpa jurnal (sudah tercatat manual)
--   * Penyusutan bulanan: garis lurus / saldo menurun ganda; jurnal per outlet; bisa dibatalkan (periode terakhir)
--   * Mutasi antar outlet & pelepasan (jual / rusak / hilang / hibah) lewat matriks approval
--     (jenis baru asset_transfer & asset_disposal); laba/rugi pelepasan dijurnal otomatis
--   * Batas kapitalisasi (default Rp 1.000.000): di bawahnya dicatat sebagai biaya, bukan aset
--   Izin baru: asset.view (lihat), asset.manage (kelola), approval.asset_transfer, approval.asset_disposal
-- =====================================================================

-- ---------------------------------------------------------------------
-- IZIN
-- ---------------------------------------------------------------------
create or replace function ast_can_view()
returns boolean language sql stable security definer set search_path = public as $$
  select sys_has_permission('asset.view') or sys_has_permission('asset.manage') or sys_has_permission('finance.view')
      or sys_has_permission('approval.asset_transfer') or sys_has_permission('approval.asset_disposal')
$$;
create or replace function ast_require_manage()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if sys_current_company_id() is null then raise exception 'Belum login'; end if;
  if not sys_has_permission('asset.manage') then raise exception 'Butuh izin kelola aset'; end if;
end $$;

-- ---------------------------------------------------------------------
-- TABEL
-- ---------------------------------------------------------------------
create table ast_settings (
  company_id               uuid primary key references sys_companies(id),
  capitalization_threshold numeric(15,2) not null default 1000000 check (capitalization_threshold >= 0),
  updated_at               timestamptz not null default now()
);

create table ast_categories (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  code                 text not null,
  name                 text not null,
  useful_life_months   int not null check (useful_life_months between 1 and 600),
  method               text not null default 'straight_line' check (method in ('straight_line', 'declining_balance')),
  asset_account_id     uuid not null references fin_accounts(id),
  accum_account_id     uuid not null references fin_accounts(id),
  expense_account_id   uuid not null references fin_accounts(id),
  description          text,
  sort_order           int not null default 0,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, code),
  check (code ~ '^[A-Z0-9]{2,6}$')
);

create table ast_assets (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references sys_companies(id),
  asset_number           text not null,
  name                   text not null,
  category_id            uuid not null references ast_categories(id),
  outlet_id              uuid references sys_outlets(id),
  location               text,                              -- mis. "Dapur panas", "Bar"
  pic_user_id            uuid references sys_users(id),     -- penanggung jawab
  brand_model            text,
  serial_number          text,
  supplier_id            uuid references pur_suppliers(id),
  acquisition_date       date not null,
  acquisition_cost       numeric(15,2) not null check (acquisition_cost > 0),
  residual_value         numeric(15,2) not null default 0 check (residual_value >= 0),
  useful_life_months     int not null check (useful_life_months between 1 and 600),
  method                 text not null check (method in ('straight_line', 'declining_balance')),
  depreciation_start     date not null,                     -- bulan pertama penyusutan di SEMAR (tgl 1)
  funding                text not null check (funding in ('cash', 'payable', 'opening', 'none')),
  paid_from_account_id   uuid references fin_accounts(id),  -- funding = cash
  opening_accumulated    numeric(15,2) not null default 0 check (opening_accumulated >= 0),  -- aset lama: akumulasi sebelum SEMAR
  opening_months         int not null default 0 check (opening_months >= 0),
  -- ringkasan (dihitung ulang dari baris penyusutan, lihat ast_refresh_asset)
  accumulated_depreciation numeric(15,2) not null default 0,
  months_depreciated     int not null default 0,
  last_depreciated_period date,
  acquisition_journal_id uuid references fin_journals(id) on delete set null,
  warranty_until         date,
  photo_path             text,
  notes                  text,
  status                 text not null default 'active' check (status in ('active', 'disposed')),
  created_by             uuid references sys_users(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, asset_number),
  check (residual_value < acquisition_cost),
  check (opening_accumulated <= acquisition_cost - residual_value),
  check (opening_months < useful_life_months),
  check (extract(day from depreciation_start) = 1),
  check (funding <> 'cash' or paid_from_account_id is not null)
);
create index idx_ast_assets_company on ast_assets(company_id, status);
create index idx_ast_assets_outlet on ast_assets(outlet_id);

-- pembayaran hutang pembelian aset (funding = payable)
create table ast_payments (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  asset_id      uuid not null references ast_assets(id) on delete cascade,
  payment_date  date not null,
  account_id    uuid not null references fin_accounts(id),
  amount        numeric(15,2) not null check (amount > 0),
  note          text,
  journal_id    uuid references fin_journals(id) on delete set null,
  created_by    uuid references sys_users(id),
  created_at    timestamptz not null default now()
);

-- satu baris per periode (bulan) per outlet; jurnalnya satu per baris
create table ast_depreciation_runs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references sys_companies(id),
  period        date not null check (extract(day from period) = 1),
  outlet_id     uuid references sys_outlets(id),
  journal_id    uuid references fin_journals(id) on delete set null,
  total_amount  numeric(15,2) not null default 0,
  asset_count   int not null default 0,
  created_by    uuid references sys_users(id),
  created_at    timestamptz not null default now()
);
create unique index uq_ast_depreciation_runs on ast_depreciation_runs(company_id, period, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table ast_depreciation_lines (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  run_id       uuid not null references ast_depreciation_runs(id) on delete cascade,
  asset_id     uuid not null references ast_assets(id) on delete cascade,
  period_from  date not null,
  period_to    date not null,
  months       int not null check (months > 0),        -- > 1 bila mengejar bulan yang tertinggal
  amount       numeric(15,2) not null check (amount >= 0),
  unique (run_id, asset_id)
);
create index idx_ast_depreciation_lines_asset on ast_depreciation_lines(asset_id);

create table ast_transfers (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  transfer_number      text not null,
  asset_id             uuid not null references ast_assets(id) on delete cascade,
  transfer_date        date not null,
  from_outlet_id       uuid references sys_outlets(id),
  to_outlet_id         uuid references sys_outlets(id),
  from_location        text,
  to_location          text,
  from_pic_user_id     uuid references sys_users(id),
  to_pic_user_id       uuid references sys_users(id),
  reason               text,
  status               text not null default 'pending_approval' check (status in ('pending_approval', 'completed', 'rejected', 'cancelled')),
  approval_request_id  uuid references sys_approval_requests(id) on delete set null,
  requested_by         uuid references sys_users(id),
  decided_by           uuid references sys_users(id),
  decided_at           timestamptz,
  decision_note        text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, transfer_number)
);
create unique index uq_ast_transfers_pending on ast_transfers(asset_id) where status = 'pending_approval';

create table ast_disposals (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references sys_companies(id),
  disposal_number      text not null,
  asset_id             uuid not null references ast_assets(id) on delete cascade,
  disposal_date        date not null,
  disposal_type        text not null check (disposal_type in ('sold', 'scrapped', 'lost', 'donated')),
  proceeds             numeric(15,2) not null default 0 check (proceeds >= 0),   -- uang diterima (dijual)
  cash_account_id      uuid references fin_accounts(id),
  reason               text,
  book_value           numeric(15,2),          -- saat diproses
  gain_loss            numeric(15,2),          -- + laba, - rugi
  status               text not null default 'pending_approval' check (status in ('pending_approval', 'completed', 'rejected', 'cancelled')),
  approval_request_id  uuid references sys_approval_requests(id) on delete set null,
  journal_id           uuid references fin_journals(id) on delete set null,
  requested_by         uuid references sys_users(id),
  decided_by           uuid references sys_users(id),
  decided_at           timestamptz,
  decision_note        text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, disposal_number),
  check (proceeds = 0 or cash_account_id is not null)
);
create unique index uq_ast_disposals_pending on ast_disposals(asset_id) where status = 'pending_approval';

-- riwayat aset (dibuat, diubah, mutasi, pelepasan, pembayaran)
create table ast_events (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references sys_companies(id),
  asset_id     uuid not null references ast_assets(id) on delete cascade,
  event_type   text not null,
  description  text not null,
  created_by   uuid references sys_users(id),
  created_at   timestamptz not null default now()
);
create index idx_ast_events_asset on ast_events(asset_id, created_at);

select sys_attach_updated_at_triggers();

-- semua penulisan lewat fungsi; baca: punya izin lihat aset + akses outletnya
do $$
declare t text;
begin
  foreach t in array array['ast_settings', 'ast_categories', 'ast_assets', 'ast_payments', 'ast_depreciation_runs',
                           'ast_depreciation_lines', 'ast_transfers', 'ast_disposals', 'ast_events'] loop
    perform sys_apply_company_policies(t);
    execute format('drop policy %I on %I', t || '_select', t);
    execute format('create policy %I on %I for select to authenticated using (company_id = sys_current_company_id() and ast_can_view())',
      t || '_select', t);
  end loop;
end $$;
select sys_apply_outlet_lock('ast_assets', 'outlet_id is null or sys_can_access_outlet(outlet_id)');
select sys_apply_outlet_lock('ast_transfers', 'exists (select 1 from ast_assets a where a.id = asset_id)
  or (from_outlet_id is not null and sys_can_access_outlet(from_outlet_id)) or (to_outlet_id is not null and sys_can_access_outlet(to_outlet_id))');
select sys_apply_outlet_lock('ast_disposals', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_events', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_payments', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_depreciation_lines', 'exists (select 1 from ast_assets a where a.id = asset_id)');
select sys_apply_outlet_lock('ast_depreciation_runs', 'outlet_id is null or sys_can_access_outlet(outlet_id)');

-- kategori & pengaturan tetap ikut saat reset transaksi (seperti COA)
create or replace function sys_data_core_tables()
returns text[] language sql immutable as $$
  select array['sys_brands', 'sys_outlets', 'sys_roles', 'sys_users', 'sys_user_invitations', 'sys_approval_rules',
               'sys_payment_gateways', 'sys_payment_gateway_secrets', 'fin_accounts', 'mst_payment_methods', 'inv_warehouses',
               'inv_units', 'inv_adjustment_purposes', 'crm_settings', 'crm_membership_tiers', 'ast_settings', 'ast_categories']
$$;

-- ---------------------------------------------------------------------
-- AKUN COA & KATEGORI DEFAULT
-- ---------------------------------------------------------------------
create or replace function ast_ensure_setup(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare acc record; v_code text; v_n int;
begin
  if not exists (select 1 from fin_accounts where company_id = p_company_id) then return; end if;
  -- akun bawaan COA standar diberi kunci sistem (bila belum dipakai)
  update fin_accounts a set system_key = y.skey
  from (values ('1-2100', 'fa_equipment'), ('1-2200', 'fa_accum_depreciation'), ('6-2000', 'depreciation_expense'),
               ('6-1900', 'maintenance_expense')) as y(code, skey)
  where a.company_id = p_company_id and a.code = y.code and a.system_key is null and not a.is_header
    and not exists (select 1 from fin_accounts b where b.company_id = p_company_id and b.system_key = y.skey);
  -- akun baru; bila kodenya sudah dipakai akun lain, ambil nomor kosong berikutnya (6-2200 -> 6-2201 ...)
  for acc in select * from (values
    ('1-0000', '1-2100', 'Peralatan Dapur & Restoran',      'asset',     'debit',  'fa_equipment'),
    ('1-0000', '1-2110', 'Mesin & Peralatan Besar',         'asset',     'debit',  'fa_machinery'),
    ('1-0000', '1-2120', 'Elektronik & Komputer',           'asset',     'debit',  'fa_electronics'),
    ('1-0000', '1-2130', 'Furnitur & Interior',             'asset',     'debit',  'fa_furniture'),
    ('1-0000', '1-2140', 'Kendaraan',                       'asset',     'debit',  'fa_vehicle'),
    ('1-0000', '1-2150', 'Bangunan & Renovasi',             'asset',     'debit',  'fa_building'),
    ('1-0000', '1-2200', 'Akumulasi Penyusutan',            'asset',     'credit', 'fa_accum_depreciation'),
    ('2-0000', '2-1400', 'Hutang Pembelian Aset',           'liability', 'credit', 'asset_payable'),
    ('4-0000', '4-1800', 'Laba Pelepasan Aset',             'revenue',   'credit', 'asset_disposal_gain'),
    ('6-0000', '6-1900', 'Beban Perbaikan & Perawatan',     'expense',   'debit',  'maintenance_expense'),
    ('6-0000', '6-2000', 'Beban Penyusutan',                'expense',   'debit',  'depreciation_expense'),
    ('6-0000', '6-2200', 'Rugi Pelepasan Aset',             'expense',   'debit',  'asset_disposal_loss')
  ) as t(parent, code, name, type, normal, skey) loop
    continue when exists (select 1 from fin_accounts a where a.company_id = p_company_id and a.system_key = acc.skey);
    v_code := acc.code; v_n := 0;
    while exists (select 1 from fin_accounts a where a.company_id = p_company_id and a.code = v_code) and v_n < 99 loop
      v_n := v_n + 1;
      v_code := left(acc.code, 4) || lpad((right(acc.code, 2)::int + v_n)::text, 2, '0');
    end loop;
    insert into fin_accounts (company_id, parent_id, code, name, account_type, normal_balance, system_key)
    values (p_company_id, (select id from fin_accounts where company_id = p_company_id and code = acc.parent),
            v_code, acc.name, acc.type, acc.normal, acc.skey);
  end loop;

  insert into ast_settings (company_id) values (p_company_id) on conflict do nothing;

  if not exists (select 1 from ast_categories where company_id = p_company_id) then
    insert into ast_categories (company_id, code, name, useful_life_months, asset_account_id, accum_account_id, expense_account_id, description, sort_order)
    select p_company_id, x.code, x.name, x.months, fin_account_id(p_company_id, x.skey),
           fin_account_id(p_company_id, 'fa_accum_depreciation'), fin_account_id(p_company_id, 'depreciation_expense'), x.descr, x.ord
    from (values
      ('DPR', 'Peralatan Dapur',            48, 'fa_equipment',   'Kompor, fryer, griller, blender, chiller kecil (kelompok 1 pajak, 4 tahun)', 1),
      ('ELK', 'Elektronik & Komputer',      48, 'fa_electronics', 'Mesin kasir, printer, laptop, CCTV, TV (kelompok 1, 4 tahun)', 2),
      ('MSN', 'Mesin & Peralatan Besar',    96, 'fa_machinery',   'Oven deck, chiller / freezer besar, genset, AC sentral (kelompok 2, 8 tahun)', 3),
      ('FRN', 'Furnitur & Interior',        96, 'fa_furniture',   'Meja, kursi, rak, booth, signage (kelompok 2, 8 tahun)', 4),
      ('KND', 'Kendaraan',                  96, 'fa_vehicle',     'Mobil boks, motor delivery (8 tahun)', 5),
      ('BGN', 'Bangunan & Renovasi',       240, 'fa_building',    'Bangunan permanen 20 tahun; renovasi tempat sewa sesuaikan dengan masa sewa', 6)
    ) as x(code, name, months, skey, descr, ord);
  end if;
end $$;

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform ast_ensure_setup(r.id); end loop;
end $$;

-- dipanggil halaman Aset saat dibuka (perusahaan baru / setelah COA dibuat)
create or replace function ast_setup()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id();
begin
  if v_c is null or not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  perform ast_ensure_setup(v_c);
  return (select to_jsonb(s) from ast_settings s where company_id = v_c);
end $$;

create or replace function ast_save_settings(p_threshold numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id();
begin
  perform ast_require_manage();
  if p_threshold is null or p_threshold < 0 then raise exception 'Batas nilai aset tidak valid'; end if;
  perform ast_ensure_setup(v_c);
  update ast_settings set capitalization_threshold = p_threshold where company_id = v_c;
  return (select to_jsonb(s) from ast_settings s where company_id = v_c);
end $$;

-- akun milik perusahaan ini, bukan header, jenis sesuai
create or replace function ast_check_account(p_id uuid, p_types text[], p_label text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if p_id is null or not exists (select 1 from fin_accounts where id = p_id and company_id = sys_current_company_id()
                                 and not is_header and is_active and account_type = any(p_types)) then
    raise exception '% tidak valid', p_label;
  end if;
end $$;

create or replace function ast_save_category(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id();
  v ast_categories;
  v_code text := upper(trim(coalesce(p->>'code', '')));
begin
  perform ast_require_manage();
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Nama kategori wajib diisi'; end if;
  if v_code !~ '^[A-Z0-9]{2,6}$' then raise exception 'Kode kategori 2-6 huruf/angka, mis. DPR'; end if;
  if coalesce((p->>'useful_life_months')::int, 0) not between 1 and 600 then raise exception 'Umur manfaat 1-600 bulan'; end if;
  perform ast_check_account((p->>'asset_account_id')::uuid, array['asset'], 'Akun aset');
  perform ast_check_account((p->>'accum_account_id')::uuid, array['asset'], 'Akun akumulasi penyusutan');
  perform ast_check_account((p->>'expense_account_id')::uuid, array['expense', 'cogs'], 'Akun beban penyusutan');
  if nullif(p->>'id', '') is null then
    insert into ast_categories (company_id, code, name, useful_life_months, method, asset_account_id, accum_account_id, expense_account_id, description, sort_order)
    values (v_c, v_code, trim(p->>'name'), (p->>'useful_life_months')::int, coalesce(nullif(p->>'method', ''), 'straight_line'),
      (p->>'asset_account_id')::uuid, (p->>'accum_account_id')::uuid, (p->>'expense_account_id')::uuid, nullif(trim(coalesce(p->>'description', '')), ''),
      coalesce((p->>'sort_order')::int, 0))
    returning * into v;
  else
    select * into v from ast_categories where id = (p->>'id')::uuid and company_id = v_c for update;
    if v.id is null then raise exception 'Kategori tidak ditemukan'; end if;
    -- akun tidak boleh diganti bila sudah ada aset (jurnal lama memakai akun lama)
    if (v.asset_account_id, v.accum_account_id, v.expense_account_id) is distinct from
       ((p->>'asset_account_id')::uuid, (p->>'accum_account_id')::uuid, (p->>'expense_account_id')::uuid)
       and exists (select 1 from ast_assets where category_id = v.id) then
      raise exception 'Akun kategori tidak bisa diganti karena sudah dipakai aset. Buat kategori baru.';
    end if;
    update ast_categories set code = v_code, name = trim(p->>'name'), useful_life_months = (p->>'useful_life_months')::int,
      method = coalesce(nullif(p->>'method', ''), 'straight_line'), asset_account_id = (p->>'asset_account_id')::uuid,
      accum_account_id = (p->>'accum_account_id')::uuid, expense_account_id = (p->>'expense_account_id')::uuid,
      description = nullif(trim(coalesce(p->>'description', '')), ''), sort_order = coalesce((p->>'sort_order')::int, sort_order),
      is_active = coalesce((p->>'is_active')::boolean, is_active)
    where id = v.id returning * into v;
  end if;
  return to_jsonb(v);
end $$;

-- ---------------------------------------------------------------------
-- HITUNG PENYUSUTAN
-- garis lurus : (harga - residu) / umur per bulan; bulan terakhir mengambil sisa
-- saldo menurun ganda: nilai buku x (2 / umur tahun) / 12 per bulan; bulan terakhir mengambil sisa
-- ---------------------------------------------------------------------
create or replace function ast_month_amount(a ast_assets, p_months_used int, p_accumulated numeric)
returns numeric language plpgsql immutable as $$
declare
  v_depreciable numeric := a.acquisition_cost - a.residual_value;
  v_remaining   numeric := a.acquisition_cost - a.residual_value - p_accumulated;
  v_amt         numeric;
begin
  if v_remaining <= 0 or p_months_used >= a.useful_life_months then return 0; end if;
  if p_months_used + 1 >= a.useful_life_months then return round(v_remaining, 2); end if;
  if a.method = 'declining_balance' then
    v_amt := round((a.acquisition_cost - p_accumulated) * (2.0 / (a.useful_life_months / 12.0)) / 12, 2);
  else
    v_amt := round(v_depreciable / a.useful_life_months, 2);
  end if;
  return least(v_amt, round(v_remaining, 2));
end $$;

-- penyusutan yang belum dijurnal untuk satu aset sampai bulan p_period (termasuk bulan yang tertinggal)
create or replace function ast_pending_depreciation(a ast_assets, p_period date,
  out period_from date, out period_to date, out months int, out amount numeric)
language plpgsql stable as $$
declare
  v_month date := greatest(a.depreciation_start, coalesce((a.last_depreciated_period + interval '1 month')::date, a.depreciation_start));
  v_used int := a.months_depreciated;
  v_acc numeric := a.accumulated_depreciation;
  v_amt numeric;
begin
  months := 0; amount := 0;
  if a.status <> 'active' then return; end if;
  while v_month <= p_period loop
    v_amt := ast_month_amount(a, v_used, v_acc);
    exit when v_amt <= 0;
    if period_from is null then period_from := v_month; end if;
    period_to := v_month;
    months := months + 1; amount := amount + v_amt;
    v_used := v_used + 1; v_acc := v_acc + v_amt;
    v_month := (v_month + interval '1 month')::date;
  end loop;
end $$;

-- ringkasan aset dihitung ulang dari baris penyusutan
create or replace function ast_refresh_asset(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update ast_assets a set
    accumulated_depreciation = a.opening_accumulated + coalesce((select sum(amount) from ast_depreciation_lines where asset_id = a.id), 0),
    months_depreciated = a.opening_months + coalesce((select sum(months) from ast_depreciation_lines where asset_id = a.id), 0),
    last_depreciated_period = (select max(period_to) from ast_depreciation_lines where asset_id = a.id)
  where a.id = p_id
$$;

create or replace function ast_log(p_asset_id uuid, p_type text, p_desc text)
returns void language sql security definer set search_path = public as $$
  insert into ast_events (company_id, asset_id, event_type, description, created_by)
  select company_id, id, p_type, p_desc, auth.uid() from ast_assets where id = p_asset_id
$$;

-- ---------------------------------------------------------------------
-- JURNAL PEROLEHAN
-- cash    : Dr Aset / Cr Kas-Bank
-- payable : Dr Aset / Cr Hutang Pembelian Aset
-- opening : Dr Aset / Cr Akumulasi (akumulasi lama) / Cr Ekuitas Saldo Awal (nilai buku)
-- none    : tanpa jurnal (sudah dicatat manual)
-- ---------------------------------------------------------------------
create or replace function ast_post_acquisition(p_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  a ast_assets; k ast_categories; v_lines jsonb; v_date date; v_j uuid;
begin
  select * into a from ast_assets where id = p_id;
  select * into k from ast_categories where id = a.category_id;
  if a.acquisition_journal_id is not null then
    delete from fin_journals where id = a.acquisition_journal_id;
  end if;
  if a.funding = 'none' then
    update ast_assets set acquisition_journal_id = null where id = a.id;
    return null;
  end if;
  v_date := case when a.funding = 'opening' then (a.depreciation_start - 1) else a.acquisition_date end;
  v_lines := jsonb_build_array(jsonb_build_object('account_id', k.asset_account_id, 'debit', a.acquisition_cost, 'note', a.asset_number));
  if a.funding = 'cash' then
    v_lines := v_lines || jsonb_build_object('account_id', a.paid_from_account_id, 'credit', a.acquisition_cost);
  elsif a.funding = 'payable' then
    v_lines := v_lines || jsonb_build_object('account_id', fin_account_id(a.company_id, 'asset_payable'), 'credit', a.acquisition_cost);
  else
    v_lines := v_lines || jsonb_build_object('account_id', k.accum_account_id, 'credit', a.opening_accumulated, 'note', 'Akumulasi penyusutan sebelum SEMAR')
                       || jsonb_build_object('account_id', fin_account_id(a.company_id, 'opening_equity'), 'credit', a.acquisition_cost - a.opening_accumulated);
  end if;
  v_j := fin_create_journal(a.company_id, a.outlet_id, v_date, 'asset_acquisition', a.id,
    'Perolehan aset ' || a.asset_number || ' ' || a.name, v_lines);
  update ast_assets set acquisition_journal_id = v_j where id = a.id;
  return v_j;
end $$;

-- ---------------------------------------------------------------------
-- SIMPAN ASET
-- ---------------------------------------------------------------------
create or replace function ast_save_asset(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c       uuid := sys_current_company_id();
  a         ast_assets;
  k         ast_categories;
  v_new     boolean := nullif(p->>'id', '') is null;
  v_cost    numeric := round(coalesce((p->>'acquisition_cost')::numeric, 0), 2);
  v_res     numeric := round(coalesce((p->>'residual_value')::numeric, 0), 2);
  v_acq     date := nullif(p->>'acquisition_date', '')::date;
  v_fund    text := coalesce(nullif(p->>'funding', ''), 'cash');
  v_outlet  uuid := nullif(p->>'outlet_id', '')::uuid;
  v_pic     uuid := nullif(p->>'pic_user_id', '')::uuid;
  v_sup     uuid := nullif(p->>'supplier_id', '')::uuid;
  v_paid    uuid := nullif(p->>'paid_from_account_id', '')::uuid;
  v_life    int;
  v_method  text;
  v_start   date;
  v_open_m  int := 0;
  v_open_a  numeric := 0;
  v_fin_locked boolean := false;
  v_threshold numeric;
begin
  perform ast_require_manage();
  perform ast_ensure_setup(v_c);
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Nama aset wajib diisi'; end if;
  if not v_new then
    select * into a from ast_assets where id = (p->>'id')::uuid and company_id = v_c for update;
    if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
    if a.status <> 'active' then raise exception 'Aset sudah dilepas, tidak bisa diubah'; end if;
    -- data keuangan terkunci setelah ada penyusutan / pembayaran
    v_fin_locked := exists (select 1 from ast_depreciation_lines where asset_id = a.id) or exists (select 1 from ast_payments where asset_id = a.id);
  end if;
  if v_pic is not null and not exists (select 1 from sys_users where id = v_pic and company_id = v_c and is_active) then raise exception 'Penanggung jawab tidak ditemukan'; end if;
  if v_sup is not null and not exists (select 1 from pur_suppliers where id = v_sup and company_id = v_c) then raise exception 'Supplier tidak ditemukan'; end if;

  if v_new or not v_fin_locked then
    select * into k from ast_categories where id = nullif(p->>'category_id', '')::uuid and company_id = v_c and is_active;
    if k.id is null then raise exception 'Kategori aset wajib dipilih'; end if;
    if v_new then
      if v_outlet is not null and not exists (select 1 from sys_outlets where id = v_outlet and company_id = v_c) then raise exception 'Outlet tidak ditemukan'; end if;
      if v_outlet is not null and not sys_can_access_outlet(v_outlet) then raise exception 'Tidak punya akses ke outlet ini'; end if;
      if v_outlet is null and not sys_user_all_outlets() then
        raise exception 'Pilih outlet aset';
      end if;
    end if;
    if v_acq is null then raise exception 'Tanggal perolehan wajib diisi'; end if;
    if v_acq > (now() at time zone 'Asia/Jakarta')::date then raise exception 'Tanggal perolehan tidak boleh di masa depan'; end if;
    if v_cost <= 0 then raise exception 'Harga perolehan wajib diisi'; end if;
    select capitalization_threshold into v_threshold from ast_settings where company_id = v_c;
    if v_cost < coalesce(v_threshold, 0) then
      raise exception 'Harga di bawah batas aset (Rp %). Catat sebagai biaya / perlengkapan, bukan aset.', to_char(v_threshold, 'FM999G999G999G999');
    end if;
    if v_res < 0 or v_res >= v_cost then raise exception 'Nilai sisa harus lebih kecil dari harga perolehan'; end if;
    v_life := coalesce(nullif(p->>'useful_life_months', '')::int, k.useful_life_months);
    if v_life not between 1 and 600 then raise exception 'Umur manfaat 1-600 bulan'; end if;
    v_method := coalesce(nullif(p->>'method', ''), k.method);
    if v_method not in ('straight_line', 'declining_balance') then raise exception 'Metode penyusutan tidak dikenal'; end if;
    if v_fund not in ('cash', 'payable', 'opening', 'none') then raise exception 'Sumber perolehan tidak dikenal'; end if;
    if v_fund = 'cash' then perform ast_check_account(v_paid, array['asset'], 'Akun kas / bank pembayar'); else v_paid := null; end if;

    if v_fund = 'opening' then
      -- aset lama: penyusutan di SEMAR mulai bulan ini (atau bulan yang diisi); bulan sebelumnya = akumulasi lama
      v_start := date_trunc('month', coalesce(nullif(p->>'depreciation_start', '')::date, (now() at time zone 'Asia/Jakarta')::date))::date;
      if v_start <= date_trunc('month', v_acq)::date then raise exception 'Untuk aset lama, bulan mulai penyusutan di SEMAR harus setelah bulan perolehan'; end if;
      v_open_m := coalesce(nullif(p->>'opening_months', '')::int,
        ((extract(year from v_start) - extract(year from v_acq)) * 12 + extract(month from v_start) - extract(month from v_acq))::int);
      if v_open_m < 0 or v_open_m >= v_life then raise exception 'Umur aset lama sudah habis (% dari % bulan). Aset yang sudah habis disusutkan tidak perlu dicatat ulang.', v_open_m, v_life; end if;
      v_open_a := round(coalesce(nullif(p->>'opening_accumulated', '')::numeric,
        least(v_cost - v_res, round((v_cost - v_res) / v_life, 2) * v_open_m)), 2);
      if v_open_a < 0 or v_open_a > v_cost - v_res then raise exception 'Akumulasi penyusutan lama tidak valid'; end if;
    else
      v_start := date_trunc('month', coalesce(nullif(p->>'depreciation_start', '')::date, v_acq))::date;
      if v_start < date_trunc('month', v_acq)::date then raise exception 'Penyusutan tidak bisa mulai sebelum bulan perolehan'; end if;
    end if;
  end if;

  if v_new then
    insert into ast_assets (company_id, asset_number, name, category_id, outlet_id, location, pic_user_id, brand_model, serial_number,
      supplier_id, acquisition_date, acquisition_cost, residual_value, useful_life_months, method, depreciation_start, funding,
      paid_from_account_id, opening_accumulated, opening_months, accumulated_depreciation, months_depreciated, warranty_until, photo_path, notes, created_by)
    values (v_c, 'AST-' || k.code || '-' || lpad(sys_next_sequence(v_c, 'AST-' || k.code)::text, 4, '0'), trim(p->>'name'), k.id, v_outlet,
      nullif(trim(coalesce(p->>'location', '')), ''), v_pic, nullif(trim(coalesce(p->>'brand_model', '')), ''), nullif(trim(coalesce(p->>'serial_number', '')), ''),
      v_sup, v_acq, v_cost, v_res, v_life, v_method, v_start, v_fund, v_paid, v_open_a, v_open_m, v_open_a, v_open_m,
      nullif(p->>'warranty_until', '')::date, nullif(p->>'photo_path', ''), nullif(trim(coalesce(p->>'notes', '')), ''), auth.uid())
    returning * into a;
    perform ast_post_acquisition(a.id);
    perform ast_log(a.id, 'created', 'Aset dicatat · harga Rp ' || to_char(v_cost, 'FM999G999G999G999') || case v_fund
      when 'cash' then ' dibayar tunai/bank' when 'payable' then ' (hutang)' when 'opening' then ' (aset lama, akumulasi Rp ' || to_char(v_open_a, 'FM999G999G999G999') || ')'
      else ' (tanpa jurnal)' end);
    perform sys_log_activity(v_c, 'create', 'ast_assets', a.id, a.asset_number || ' ' || a.name, null);
  else
    update ast_assets set name = trim(p->>'name'), location = nullif(trim(coalesce(p->>'location', '')), ''), pic_user_id = v_pic,
      brand_model = nullif(trim(coalesce(p->>'brand_model', '')), ''), serial_number = nullif(trim(coalesce(p->>'serial_number', '')), ''),
      supplier_id = v_sup, warranty_until = nullif(p->>'warranty_until', '')::date, photo_path = nullif(p->>'photo_path', ''),
      notes = nullif(trim(coalesce(p->>'notes', '')), '')
    where id = a.id;
    if not v_fin_locked and (a.category_id, a.acquisition_date, a.acquisition_cost, a.residual_value, a.useful_life_months, a.method,
        a.depreciation_start, a.funding, a.paid_from_account_id, a.opening_accumulated, a.opening_months) is distinct from
        (k.id, v_acq, v_cost, v_res, v_life, v_method, v_start, v_fund, v_paid, v_open_a, v_open_m) then
      update ast_assets set category_id = k.id, acquisition_date = v_acq, acquisition_cost = v_cost, residual_value = v_res,
        useful_life_months = v_life, method = v_method, depreciation_start = v_start, funding = v_fund, paid_from_account_id = v_paid,
        opening_accumulated = v_open_a, opening_months = v_open_m
      where id = a.id;
      perform ast_refresh_asset(a.id);
      perform ast_post_acquisition(a.id);
      perform ast_log(a.id, 'updated', 'Data perolehan / penyusutan diubah');
    elsif v_fin_locked and nullif(p->>'acquisition_cost', '') is not null and v_cost <> a.acquisition_cost then
      raise exception 'Harga & data penyusutan tidak bisa diubah karena sudah ada penyusutan / pembayaran';
    else
      perform ast_log(a.id, 'updated', 'Data aset diubah');
    end if;
    select * into a from ast_assets where id = a.id;
  end if;
  return to_jsonb(a);
end $$;

-- hapus aset yang salah input (belum ada penyusutan, pembayaran, mutasi / pelepasan)
create or replace function ast_delete_asset(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a ast_assets;
begin
  perform ast_require_manage();
  select * into a from ast_assets where id = p_id and company_id = sys_current_company_id() for update;
  if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
  if exists (select 1 from ast_depreciation_lines where asset_id = p_id) or exists (select 1 from ast_payments where asset_id = p_id)
     or exists (select 1 from ast_transfers where asset_id = p_id and status = 'completed') or exists (select 1 from ast_disposals where asset_id = p_id) then
    raise exception 'Aset sudah punya penyusutan / pembayaran / mutasi / pelepasan, tidak bisa dihapus. Gunakan Lepas aset.';
  end if;
  update sys_approval_requests set status = 'cancelled', decided_at = now(), decision_note = 'Aset dihapus'
  where document_type = 'asset_transfer' and status = 'pending' and document_id in (select id from ast_transfers where asset_id = p_id);
  if a.acquisition_journal_id is not null then delete from fin_journals where id = a.acquisition_journal_id; end if;
  delete from ast_assets where id = p_id;
  perform sys_log_activity(a.company_id, 'delete', 'ast_assets', a.id, a.asset_number || ' ' || a.name, null);
end $$;

-- pembayaran hutang pembelian aset: Dr Hutang Pembelian Aset / Cr Kas-Bank
create or replace function ast_record_payment(p_asset_id uuid, p_account_id uuid, p_amount numeric, p_date date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a ast_assets; v_paid numeric; v_pay ast_payments;
begin
  perform ast_require_manage();
  select * into a from ast_assets where id = p_asset_id and company_id = sys_current_company_id() for update;
  if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
  if a.funding <> 'payable' then raise exception 'Aset ini tidak dibeli dengan hutang'; end if;
  perform ast_check_account(p_account_id, array['asset'], 'Akun kas / bank');
  v_paid := coalesce((select sum(amount) from ast_payments where asset_id = a.id), 0);
  if coalesce(p_amount, 0) <= 0 then raise exception 'Nominal pembayaran wajib diisi'; end if;
  if round(p_amount, 2) > a.acquisition_cost - v_paid then
    raise exception 'Melebihi sisa hutang (Rp %)', to_char(a.acquisition_cost - v_paid, 'FM999G999G999G999');
  end if;
  if p_date is null or p_date < a.acquisition_date then raise exception 'Tanggal bayar tidak valid'; end if;
  insert into ast_payments (company_id, asset_id, payment_date, account_id, amount, note, created_by)
  values (a.company_id, a.id, p_date, p_account_id, round(p_amount, 2), nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning * into v_pay;
  update ast_payments set journal_id = fin_create_journal(a.company_id, a.outlet_id, p_date, 'asset_payment', v_pay.id,
    'Bayar hutang aset ' || a.asset_number || ' ' || a.name,
    jsonb_build_array(jsonb_build_object('account_id', fin_account_id(a.company_id, 'asset_payable'), 'debit', v_pay.amount),
                      jsonb_build_object('account_id', p_account_id, 'credit', v_pay.amount)))
  where id = v_pay.id returning * into v_pay;
  perform ast_log(a.id, 'payment', 'Bayar hutang Rp ' || to_char(v_pay.amount, 'FM999G999G999G999'));
  return to_jsonb(v_pay);
end $$;

-- ---------------------------------------------------------------------
-- PENYUSUTAN BULANAN
-- ---------------------------------------------------------------------
create or replace function ast_last_period(p_company uuid)
returns date language sql stable security definer set search_path = public as $$
  select max(period) from ast_depreciation_runs where company_id = p_company
$$;

-- pratinjau: aset yang akan disusutkan sampai bulan p_period
create or replace function ast_depreciation_preview(p_period date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_p date := date_trunc('month', p_period)::date;
begin
  if v_c is null or not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return jsonb_build_object(
    'period', v_p, 'last_period', ast_last_period(v_c),
    'items', coalesce((select jsonb_agg(jsonb_build_object('asset_id', a.id, 'asset_number', a.asset_number, 'name', a.name,
        'category', k.name, 'outlet', o.name, 'months', d.months, 'period_from', d.period_from, 'amount', d.amount,
        'book_value_after', a.acquisition_cost - a.accumulated_depreciation - d.amount) order by o.name nulls first, a.asset_number)
      from ast_assets a join ast_categories k on k.id = a.category_id left join sys_outlets o on o.id = a.outlet_id
      cross join lateral ast_pending_depreciation(a, v_p) d
      where a.company_id = v_c and a.status = 'active' and d.months > 0
        and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id))), '[]'::jsonb));
end $$;

create or replace function ast_run_depreciation(p_period date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c     uuid := sys_current_company_id();
  v_p     date := date_trunc('month', p_period)::date;
  v_last  date;
  r       record;
  v_run   ast_depreciation_runs;
  v_lines jsonb;
  v_total numeric := 0;
  v_count int := 0;
begin
  if not (sys_has_permission('asset.manage') or sys_has_permission('finance.manage')) then raise exception 'Butuh izin kelola aset / keuangan'; end if;
  if p_period is null then raise exception 'Pilih bulan'; end if;
  if v_p > date_trunc('month', (now() at time zone 'Asia/Jakarta')::date)::date then raise exception 'Bulan yang belum berjalan tidak bisa disusutkan'; end if;
  -- satu perusahaan sekaligus (supaya tidak terlewat aset outlet lain)
  if not sys_user_all_outlets() then
    raise exception 'Penyusutan dijalankan oleh user dengan akses semua outlet';
  end if;
  perform pg_advisory_xact_lock(hashtext('ast_depr_' || v_c::text));
  v_last := ast_last_period(v_c);
  if v_last is not null and v_p <= v_last then
    raise exception 'Penyusutan sampai % sudah dijalankan. Pilih bulan sesudahnya (atau batalkan periode terakhir).', to_char(v_last, 'MM/YYYY');
  end if;

  for r in
    select coalesce(a.outlet_id, '00000000-0000-0000-0000-000000000000'::uuid) as grp, a.outlet_id
    from ast_assets a
    where a.company_id = v_c and a.status = 'active' and (ast_pending_depreciation(a, v_p)).months > 0
    group by 1, 2
  loop
    insert into ast_depreciation_runs (company_id, period, outlet_id, created_by)
    values (v_c, v_p, r.outlet_id, auth.uid()) returning * into v_run;
    insert into ast_depreciation_lines (company_id, run_id, asset_id, period_from, period_to, months, amount)
    select v_c, v_run.id, a.id, d.period_from, d.period_to, d.months, d.amount
    from ast_assets a cross join lateral ast_pending_depreciation(a, v_p) d
    where a.company_id = v_c and a.status = 'active' and a.outlet_id is not distinct from r.outlet_id and d.months > 0;

    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_lines from (
      select jsonb_build_object('account_id', k.expense_account_id, 'debit', sum(l.amount), 'note', 'Penyusutan ' || k.name) as x
      from ast_depreciation_lines l join ast_assets a on a.id = l.asset_id join ast_categories k on k.id = a.category_id
      where l.run_id = v_run.id group by k.expense_account_id, k.name
      union all
      select jsonb_build_object('account_id', k.accum_account_id, 'credit', sum(l.amount), 'note', 'Akumulasi ' || k.name)
      from ast_depreciation_lines l join ast_assets a on a.id = l.asset_id join ast_categories k on k.id = a.category_id
      where l.run_id = v_run.id group by k.accum_account_id, k.name) t;
    update ast_depreciation_runs set
      total_amount = (select coalesce(sum(amount), 0) from ast_depreciation_lines where run_id = v_run.id),
      asset_count = (select count(*) from ast_depreciation_lines where run_id = v_run.id),
      journal_id = fin_create_journal(v_c, r.outlet_id, (v_p + interval '1 month' - interval '1 day')::date, 'asset_depreciation', v_run.id,
        'Penyusutan aset ' || to_char(v_p, 'MM/YYYY'), v_lines)
    where id = v_run.id returning * into v_run;
    v_total := v_total + v_run.total_amount; v_count := v_count + v_run.asset_count;
  end loop;

  for r in select l.asset_id from ast_depreciation_lines l join ast_depreciation_runs d on d.id = l.run_id
           where d.company_id = v_c and d.period = v_p loop
    perform ast_refresh_asset(r.asset_id);
  end loop;
  if v_count = 0 then raise exception 'Tidak ada aset yang perlu disusutkan sampai %', to_char(v_p, 'MM/YYYY'); end if;
  perform sys_log_activity(v_c, 'post', 'ast_depreciation_runs', null, 'Penyusutan aset ' || to_char(v_p, 'MM/YYYY'),
    jsonb_build_object('total', v_total, 'assets', v_count));
  return jsonb_build_object('period', v_p, 'total', v_total, 'assets', v_count);
end $$;

-- batalkan periode terakhir (jurnal ikut dihapus)
create or replace function ast_void_depreciation(p_period date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_p date := date_trunc('month', p_period)::date; v_ids uuid[]; v_j uuid[];
begin
  if not (sys_has_permission('asset.manage') or sys_has_permission('finance.manage')) then raise exception 'Butuh izin kelola aset / keuangan'; end if;
  if not sys_user_all_outlets() then
    raise exception 'Pembatalan penyusutan oleh user dengan akses semua outlet';
  end if;
  if v_p is distinct from ast_last_period(v_c) then raise exception 'Hanya periode penyusutan terakhir yang bisa dibatalkan'; end if;
  if exists (select 1 from ast_disposals x join ast_depreciation_lines l on l.asset_id = x.asset_id join ast_depreciation_runs d on d.id = l.run_id
             where d.company_id = v_c and d.period = v_p and x.status = 'completed') then
    raise exception 'Ada aset yang sudah dilepas setelah penyusutan ini, tidak bisa dibatalkan';
  end if;
  select array_agg(distinct l.asset_id), array_agg(distinct d.journal_id) into v_ids, v_j
  from ast_depreciation_runs d left join ast_depreciation_lines l on l.run_id = d.id where d.company_id = v_c and d.period = v_p;
  delete from ast_depreciation_runs where company_id = v_c and period = v_p;
  delete from fin_journals where id = any(v_j);
  perform ast_refresh_asset(x) from unnest(v_ids) x where x is not null;
  perform sys_log_activity(v_c, 'void', 'ast_depreciation_runs', null, 'Batal penyusutan aset ' || to_char(v_p, 'MM/YYYY'), null);
  return jsonb_build_object('period', v_p, 'assets', coalesce(array_length(v_ids, 1), 0));
end $$;

-- ---------------------------------------------------------------------
-- MUTASI ANTAR OUTLET
-- ---------------------------------------------------------------------
create or replace function ast_complete_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t ast_transfers; a ast_assets;
begin
  select * into t from ast_transfers where id = p_id for update;
  select * into a from ast_assets where id = t.asset_id for update;
  if a.status <> 'active' then raise exception 'Aset sudah dilepas'; end if;
  update ast_assets set outlet_id = t.to_outlet_id, location = t.to_location, pic_user_id = t.to_pic_user_id where id = a.id;
  update ast_transfers set status = 'completed', decided_at = coalesce(decided_at, now()) where id = t.id;
  perform ast_log(a.id, 'transferred', 'Mutasi ' || t.transfer_number || ': ' || coalesce((select name from sys_outlets where id = t.from_outlet_id), 'Kantor pusat')
    || coalesce(' / ' || t.from_location, '') || ' → ' || coalesce((select name from sys_outlets where id = t.to_outlet_id), 'Kantor pusat')
    || coalesce(' / ' || t.to_location, ''));
end $$;

create or replace function ast_request_transfer(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); a ast_assets; t ast_transfers; v_appr jsonb;
  v_to uuid := nullif(p->>'to_outlet_id', '')::uuid; v_pic uuid := nullif(p->>'to_pic_user_id', '')::uuid;
  v_date date := coalesce(nullif(p->>'transfer_date', '')::date, (now() at time zone 'Asia/Jakarta')::date);
begin
  perform ast_require_manage();
  select * into a from ast_assets where id = (p->>'asset_id')::uuid and company_id = v_c for update;
  if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
  if a.status <> 'active' then raise exception 'Aset sudah dilepas'; end if;
  if v_to is not null and not exists (select 1 from sys_outlets where id = v_to and company_id = v_c and is_active) then raise exception 'Outlet tujuan tidak ditemukan'; end if;
  if v_pic is not null and not exists (select 1 from sys_users where id = v_pic and company_id = v_c and is_active) then raise exception 'Penanggung jawab tidak ditemukan'; end if;
  if v_to is not distinct from a.outlet_id and coalesce(trim(p->>'to_location'), '') = coalesce(a.location, '') and v_pic is not distinct from a.pic_user_id then
    raise exception 'Tujuan mutasi sama dengan posisi sekarang';
  end if;
  if exists (select 1 from ast_transfers where asset_id = a.id and status = 'pending_approval') then raise exception 'Aset ini masih punya mutasi yang menunggu persetujuan'; end if;
  if exists (select 1 from ast_disposals where asset_id = a.id and status = 'pending_approval') then raise exception 'Aset ini sedang diajukan untuk dilepas'; end if;
  insert into ast_transfers (company_id, transfer_number, asset_id, transfer_date, from_outlet_id, to_outlet_id, from_location, to_location,
    from_pic_user_id, to_pic_user_id, reason, requested_by)
  values (v_c, sys_next_document_number(v_c, 'MTA', v_date), a.id, v_date, a.outlet_id, v_to, a.location, nullif(trim(coalesce(p->>'to_location', '')), ''),
    a.pic_user_id, v_pic, nullif(trim(coalesce(p->>'reason', '')), ''), auth.uid())
  returning * into t;
  if sys_approval_required('asset_transfer', a.acquisition_cost - a.accumulated_depreciation) then
    v_appr := sys_request_approval('asset_transfer', t.id, coalesce(v_to, a.outlet_id), a.acquisition_cost - a.accumulated_depreciation,
      'Mutasi aset ' || a.asset_number || ' ' || a.name || ' → ' || coalesce((select name from sys_outlets where id = v_to), 'Kantor pusat'),
      jsonb_build_object('asset_number', a.asset_number, 'asset', a.name, 'from', (select name from sys_outlets where id = a.outlet_id),
        'to', (select name from sys_outlets where id = v_to), 'to_location', t.to_location, 'reason', t.reason));
    update ast_transfers set approval_request_id = (v_appr->>'approval_request_id')::uuid where id = t.id returning * into t;
    perform ast_log(a.id, 'transfer_requested', 'Mutasi ' || t.transfer_number || ' diajukan, menunggu persetujuan');
  else
    perform ast_complete_transfer(t.id);
    update ast_transfers set decided_by = auth.uid() where id = t.id;
    select * into t from ast_transfers where id = t.id;
  end if;
  return to_jsonb(t);
end $$;

-- ---------------------------------------------------------------------
-- PELEPASAN (jual / rusak / hilang / hibah)
-- Dr Akumulasi | Dr Kas (hasil jual) | Dr Rugi / Cr Laba | Cr Aset
-- ---------------------------------------------------------------------
create or replace function ast_complete_disposal(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare x ast_disposals; a ast_assets; k ast_categories; v_book numeric; v_gl numeric; v_lines jsonb;
begin
  select * into x from ast_disposals where id = p_id for update;
  select * into a from ast_assets where id = x.asset_id for update;
  if a.status <> 'active' then raise exception 'Aset sudah dilepas'; end if;
  select * into k from ast_categories where id = a.category_id;
  v_book := a.acquisition_cost - a.accumulated_depreciation;
  v_gl := x.proceeds - v_book;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', k.accum_account_id, 'debit', a.accumulated_depreciation),
    jsonb_build_object('account_id', x.cash_account_id, 'debit', x.proceeds),
    jsonb_build_object('account_id', k.asset_account_id, 'credit', a.acquisition_cost, 'note', a.asset_number));
  if v_gl > 0 then v_lines := v_lines || jsonb_build_object('account_id', fin_account_id(a.company_id, 'asset_disposal_gain'), 'credit', v_gl);
  elsif v_gl < 0 then v_lines := v_lines || jsonb_build_object('account_id', fin_account_id(a.company_id, 'asset_disposal_loss'), 'debit', -v_gl);
  end if;
  -- baris kas tanpa akun (hasil 0) dibuang
  select jsonb_agg(l) into v_lines from jsonb_array_elements(v_lines) l where l->>'account_id' is not null;
  update ast_disposals set status = 'completed', book_value = v_book, gain_loss = v_gl, decided_at = coalesce(decided_at, now()),
    journal_id = fin_create_journal(a.company_id, a.outlet_id, x.disposal_date, 'asset_disposal', x.id,
      'Pelepasan aset ' || a.asset_number || ' ' || a.name, v_lines)
  where id = x.id;
  update ast_assets set status = 'disposed' where id = a.id;
  perform ast_log(a.id, 'disposed', initcap(case x.disposal_type when 'sold' then 'dijual' when 'scrapped' then 'rusak / dibuang'
    when 'lost' then 'hilang' else 'dihibahkan' end) || ' (' || x.disposal_number || ') · nilai buku Rp ' || to_char(v_book, 'FM999G999G999G990')
    || case when v_gl > 0 then ' · laba Rp ' || to_char(v_gl, 'FM999G999G999G990') when v_gl < 0 then ' · rugi Rp ' || to_char(-v_gl, 'FM999G999G999G990') else '' end);
  perform sys_log_activity(a.company_id, 'dispose', 'ast_assets', a.id, a.asset_number || ' ' || a.name, jsonb_build_object('book_value', v_book, 'gain_loss', v_gl));
end $$;

create or replace function ast_request_disposal(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c uuid := sys_current_company_id(); a ast_assets; x ast_disposals; v_appr jsonb;
  v_type text := coalesce(nullif(p->>'disposal_type', ''), 'scrapped');
  v_date date := coalesce(nullif(p->>'disposal_date', '')::date, (now() at time zone 'Asia/Jakarta')::date);
  v_proc numeric := round(coalesce(nullif(p->>'proceeds', '')::numeric, 0), 2);
  v_acc uuid := nullif(p->>'cash_account_id', '')::uuid;
begin
  perform ast_require_manage();
  select * into a from ast_assets where id = (p->>'asset_id')::uuid and company_id = v_c for update;
  if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
  if a.status <> 'active' then raise exception 'Aset sudah dilepas'; end if;
  if v_type not in ('sold', 'scrapped', 'lost', 'donated') then raise exception 'Jenis pelepasan tidak dikenal'; end if;
  if v_type <> 'sold' then v_proc := 0; v_acc := null; end if;
  if v_proc < 0 then raise exception 'Hasil penjualan tidak valid'; end if;
  if v_proc > 0 then perform ast_check_account(v_acc, array['asset'], 'Akun kas / bank penerima'); else v_acc := null; end if;
  if v_date < a.acquisition_date then raise exception 'Tanggal pelepasan sebelum tanggal perolehan'; end if;
  if v_date > (now() at time zone 'Asia/Jakarta')::date then raise exception 'Tanggal pelepasan tidak boleh di masa depan'; end if;
  if a.last_depreciated_period is not null and v_date < a.last_depreciated_period then
    raise exception 'Penyusutan sudah dijurnal sampai %. Tanggal pelepasan harus sesudahnya.', to_char(a.last_depreciated_period, 'MM/YYYY');
  end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Alasan pelepasan wajib diisi'; end if;
  if exists (select 1 from ast_disposals where asset_id = a.id and status = 'pending_approval') then raise exception 'Aset ini sudah diajukan untuk dilepas'; end if;
  if exists (select 1 from ast_transfers where asset_id = a.id and status = 'pending_approval') then raise exception 'Aset ini masih punya mutasi yang menunggu persetujuan'; end if;
  insert into ast_disposals (company_id, disposal_number, asset_id, disposal_date, disposal_type, proceeds, cash_account_id, reason, book_value, requested_by)
  values (v_c, sys_next_document_number(v_c, 'PLA', v_date), a.id, v_date, v_type, v_proc, v_acc, trim(p->>'reason'),
    a.acquisition_cost - a.accumulated_depreciation, auth.uid())
  returning * into x;
  if sys_approval_required('asset_disposal', a.acquisition_cost - a.accumulated_depreciation) then
    v_appr := sys_request_approval('asset_disposal', x.id, a.outlet_id, a.acquisition_cost - a.accumulated_depreciation,
      'Lepas aset ' || a.asset_number || ' ' || a.name || ' (' || case v_type when 'sold' then 'dijual' when 'scrapped' then 'rusak'
        when 'lost' then 'hilang' else 'hibah' end || ')',
      jsonb_build_object('asset_number', a.asset_number, 'asset', a.name, 'type', v_type, 'book_value', a.acquisition_cost - a.accumulated_depreciation,
        'proceeds', v_proc, 'reason', x.reason, 'date', v_date));
    update ast_disposals set approval_request_id = (v_appr->>'approval_request_id')::uuid where id = x.id returning * into x;
    perform ast_log(a.id, 'disposal_requested', 'Pelepasan ' || x.disposal_number || ' diajukan, menunggu persetujuan');
  else
    perform ast_complete_disposal(x.id);
    update ast_disposals set decided_by = auth.uid() where id = x.id;
    select * into x from ast_disposals where id = x.id;
  end if;
  return to_jsonb(x);
end $$;

-- batalkan pengajuan sendiri yang masih menunggu
create or replace function ast_cancel_request(p_kind text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_req uuid; v_by uuid;
begin
  perform ast_require_manage();
  if p_kind = 'transfer' then
    select approval_request_id, requested_by into v_req, v_by from ast_transfers where id = p_id and company_id = sys_current_company_id() and status = 'pending_approval';
  elsif p_kind = 'disposal' then
    select approval_request_id, requested_by into v_req, v_by from ast_disposals where id = p_id and company_id = sys_current_company_id() and status = 'pending_approval';
  else raise exception 'Jenis tidak dikenal'; end if;
  if v_by is null then raise exception 'Pengajuan tidak ditemukan / sudah diputuskan'; end if;
  if v_by <> auth.uid() and not sys_has_permission('*') then raise exception 'Hanya pengaju yang bisa membatalkan'; end if;
  if v_req is not null then
    update sys_approval_requests set status = 'cancelled', decided_at = now(), decision_note = 'Dibatalkan pengaju' where id = v_req and status = 'pending';
  end if;
  -- tanpa approval request (atau sudah tertutup) -> tutup langsung
  if p_kind = 'transfer' then update ast_transfers set status = 'cancelled', updated_at = now() where id = p_id and status = 'pending_approval';
  else update ast_disposals set status = 'cancelled', updated_at = now() where id = p_id and status = 'pending_approval'; end if;
end $$;

-- keputusan dari menu Persetujuan diteruskan ke mutasi / pelepasan
create or replace function ast_sync_approval()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.document_type = 'asset_transfer' then
    if new.status = 'approved' then
      update ast_transfers set decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()), decision_note = new.decision_note
      where id = new.document_id and status = 'pending_approval';
      if found then perform ast_complete_transfer(new.document_id); end if;
    else
      update ast_transfers set status = new.status, decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()), decision_note = new.decision_note
      where id = new.document_id and status = 'pending_approval';
    end if;
  else
    if new.status = 'approved' then
      update ast_disposals set decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()), decision_note = new.decision_note
      where id = new.document_id and status = 'pending_approval';
      if found then perform ast_complete_disposal(new.document_id); end if;
    else
      update ast_disposals set status = new.status, decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()), decision_note = new.decision_note
      where id = new.document_id and status = 'pending_approval';
    end if;
  end if;
  return new;
end $$;
create trigger trg_sys_approval_requests_assets after update of status on sys_approval_requests
  for each row when (new.document_type in ('asset_transfer', 'asset_disposal') and old.status = 'pending' and new.status in ('approved', 'rejected', 'cancelled'))
  execute function ast_sync_approval();

-- matriks approval: jenis baru (default aktif untuk semua nilai; owner & penyetuju tidak perlu approval)
alter table sys_approval_rules drop constraint sys_approval_rules_document_type_check;
alter table sys_approval_rules add constraint sys_approval_rules_document_type_check
  check (document_type in ('purchase_order', 'expense', 'stock_adjustment', 'stock_opname', 'refund', 'product', 'pricelist',
                           'sales_order', 'credit_note', 'sales_payment', 'supplier_payment', 'pos_settlement',
                           'manual_journal', 'stock_transfer', 'production', 'asset_transfer', 'asset_disposal'));

create or replace function sys_setup_approval_rules(p_company_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into sys_approval_rules (company_id, document_type, min_amount, is_enabled) values
    (p_company_id, 'purchase_order',   5000000, false),
    (p_company_id, 'expense',          1000000, false),
    (p_company_id, 'stock_adjustment',  500000, false),
    (p_company_id, 'stock_opname',     1000000, false),
    (p_company_id, 'refund',                 0, false),
    (p_company_id, 'product',                0, false),
    (p_company_id, 'pricelist',              0, false),
    (p_company_id, 'sales_order',     10000000, false),
    (p_company_id, 'credit_note',            0, false),
    (p_company_id, 'sales_payment',   10000000, false),
    (p_company_id, 'supplier_payment', 5000000, false),
    (p_company_id, 'pos_settlement',     50000, false),
    (p_company_id, 'manual_journal',         0, false),
    (p_company_id, 'stock_transfer',   5000000, false),
    (p_company_id, 'production',             0, false),
    (p_company_id, 'asset_transfer',         0, true),
    (p_company_id, 'asset_disposal',         0, true)
  on conflict do nothing
$$;

do $$
declare c record;
begin
  for c in select id from sys_companies loop perform sys_setup_approval_rules(c.id); end loop;
end $$;

-- owner / manager otomatis bisa menyetujui; staf yang bisa kelola keuangan melihat aset
update sys_roles set permissions = permissions || '["asset.manage", "approval.asset_transfer", "approval.asset_disposal"]'::jsonb
where code in ('manager') and not permissions ? '*' and not permissions ? 'asset.manage';
update sys_roles set permissions = permissions || '["asset.view"]'::jsonb
where (permissions ? 'finance.manage') and not permissions ? '*' and not permissions ? 'asset.view' and not permissions ? 'asset.manage';

-- ---------------------------------------------------------------------
-- BACA: ringkasan, detail, cari kode (scan QR)
-- ---------------------------------------------------------------------
create or replace function ast_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id(); v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if v_c is null or not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return (with a as (
      select * from ast_assets where company_id = v_c and (outlet_id is null or sys_can_access_outlet(outlet_id)))
    select jsonb_build_object(
      'aktif', (select count(*) from a where status = 'active'),
      'dilepas', (select count(*) from a where status = 'disposed'),
      'harga_perolehan', (select coalesce(sum(acquisition_cost), 0) from a where status = 'active'),
      'akumulasi', (select coalesce(sum(accumulated_depreciation), 0) from a where status = 'active'),
      'nilai_buku', (select coalesce(sum(acquisition_cost - accumulated_depreciation), 0) from a where status = 'active'),
      'per_kategori', coalesce((select jsonb_agg(jsonb_build_object('kategori', k.name, 'jumlah', x.n, 'harga', x.c, 'nilai_buku', x.b) order by k.sort_order)
        from (select category_id, count(*) n, sum(acquisition_cost) c, sum(acquisition_cost - accumulated_depreciation) b from a where status = 'active' group by 1) x
        join ast_categories k on k.id = x.category_id), '[]'::jsonb),
      'per_outlet', coalesce((select jsonb_agg(jsonb_build_object('outlet', coalesce(o.name, 'Kantor pusat'), 'jumlah', x.n, 'nilai_buku', x.b) order by o.name nulls first)
        from (select outlet_id, count(*) n, sum(acquisition_cost - accumulated_depreciation) b from a where status = 'active' group by 1) x
        left join sys_outlets o on o.id = x.outlet_id), '[]'::jsonb),
      'garansi_habis_30_hari', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kode', asset_number, 'nama', name, 'garansi', warranty_until) order by warranty_until)
        from a where status = 'active' and warranty_until between v_today and v_today + 30), '[]'::jsonb),
      'periode_terakhir', ast_last_period(v_c),
      'perlu_disusutkan', (select count(*) from a cross join lateral ast_pending_depreciation(a, (date_trunc('month', v_today) - interval '1 month')::date) d
        where a.status = 'active' and d.months > 0),
      'hutang_aset', (select coalesce(sum(a.acquisition_cost - coalesce((select sum(amount) from ast_payments p where p.asset_id = a.id), 0)), 0)
        from a where a.funding = 'payable'),
      'pengajuan_menunggu', (select count(*) from ast_transfers t where t.company_id = v_c and t.status = 'pending_approval' and t.asset_id in (select id from a))
        + (select count(*) from ast_disposals x where x.company_id = v_c and x.status = 'pending_approval' and x.asset_id in (select id from a))));
end $$;

-- jadwal penyusutan ke depan (proyeksi) untuk satu aset
create or replace function ast_schedule(a ast_assets)
returns jsonb language plpgsql stable as $$
declare
  v_month date := greatest(a.depreciation_start, coalesce((a.last_depreciated_period + interval '1 month')::date, a.depreciation_start));
  v_used int := a.months_depreciated; v_acc numeric := a.accumulated_depreciation; v_amt numeric; v_out jsonb := '[]'; v_year int; v_sum numeric := 0;
begin
  if a.status <> 'active' then return v_out; end if;
  -- diringkas per tahun supaya tidak terlalu panjang
  loop
    v_amt := ast_month_amount(a, v_used, v_acc);
    exit when v_amt <= 0 or v_used > 700;
    if v_year is not null and extract(year from v_month)::int <> v_year then
      v_out := v_out || jsonb_build_object('tahun', v_year, 'penyusutan', v_sum, 'nilai_buku_akhir', a.acquisition_cost - v_acc);
      v_sum := 0;
    end if;
    v_year := extract(year from v_month)::int;
    v_sum := v_sum + v_amt; v_acc := v_acc + v_amt; v_used := v_used + 1;
    v_month := (v_month + interval '1 month')::date;
  end loop;
  if v_year is not null then v_out := v_out || jsonb_build_object('tahun', v_year, 'penyusutan', v_sum, 'nilai_buku_akhir', a.acquisition_cost - v_acc); end if;
  return v_out;
end $$;

create or replace function ast_asset_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a ast_assets;
begin
  if not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  select * into a from ast_assets where id = p_id and company_id = sys_current_company_id();
  if a.id is null or not (a.outlet_id is null or sys_can_access_outlet(a.outlet_id)) then raise exception 'Aset tidak ditemukan'; end if;
  return to_jsonb(a) || jsonb_build_object(
    'category', (select jsonb_build_object('code', code, 'name', name) from ast_categories where id = a.category_id),
    'outlet_name', (select name from sys_outlets where id = a.outlet_id),
    'pic_name', (select full_name from sys_users where id = a.pic_user_id),
    'supplier_name', (select name from pur_suppliers where id = a.supplier_id),
    'paid_from_account', (select code || ' ' || name from fin_accounts where id = a.paid_from_account_id),
    'book_value', a.acquisition_cost - a.accumulated_depreciation,
    'monthly_depreciation', ast_month_amount(a, a.months_depreciated, a.accumulated_depreciation),
    'remaining_months', greatest(a.useful_life_months - a.months_depreciated, 0),
    'paid_amount', (select coalesce(sum(amount), 0) from ast_payments where asset_id = a.id),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('date', p.payment_date, 'amount', p.amount, 'account', f.code || ' ' || f.name, 'note', p.note) order by p.payment_date)
      from ast_payments p join fin_accounts f on f.id = p.account_id where p.asset_id = a.id), '[]'::jsonb),
    'depreciation', coalesce((select jsonb_agg(jsonb_build_object('period_from', l.period_from, 'period_to', l.period_to, 'months', l.months, 'amount', l.amount,
        'journal_number', j.journal_number) order by l.period_to desc)
      from ast_depreciation_lines l join ast_depreciation_runs d on d.id = l.run_id left join fin_journals j on j.id = d.journal_id where l.asset_id = a.id), '[]'::jsonb),
    'schedule', ast_schedule(a),
    'transfers', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'number', t.transfer_number, 'date', t.transfer_date, 'status', t.status,
        'from', coalesce(fo.name, 'Kantor pusat'), 'to', coalesce(tt.name, 'Kantor pusat'), 'to_location', t.to_location, 'reason', t.reason,
        'requested_by', ru.full_name, 'decision_note', t.decision_note, 'mine', t.requested_by = auth.uid()) order by t.created_at desc)
      from ast_transfers t left join sys_outlets fo on fo.id = t.from_outlet_id left join sys_outlets tt on tt.id = t.to_outlet_id
      left join sys_users ru on ru.id = t.requested_by where t.asset_id = a.id), '[]'::jsonb),
    'disposals', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'number', x.disposal_number, 'date', x.disposal_date, 'type', x.disposal_type,
        'status', x.status, 'proceeds', x.proceeds, 'book_value', x.book_value, 'gain_loss', x.gain_loss, 'reason', x.reason,
        'requested_by', ru.full_name, 'decision_note', x.decision_note, 'mine', x.requested_by = auth.uid()) order by x.created_at desc)
      from ast_disposals x left join sys_users ru on ru.id = x.requested_by where x.asset_id = a.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('type', e.event_type, 'description', e.description, 'by', u.full_name, 'at', e.created_at) order by e.created_at desc)
      from ast_events e left join sys_users u on u.id = e.created_by where e.asset_id = a.id), '[]'::jsonb));
end $$;

-- daftar aset untuk tabel (dengan nama-nama relasi & nilai buku)
create or replace function ast_list(p_status text default 'active')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'asset_number', a.asset_number, 'name', a.name, 'category_id', a.category_id,
      'category', k.name, 'outlet_id', a.outlet_id, 'outlet', o.name, 'location', a.location, 'pic', u.full_name, 'brand_model', a.brand_model,
      'serial_number', a.serial_number, 'acquisition_date', a.acquisition_date, 'acquisition_cost', a.acquisition_cost,
      'accumulated_depreciation', a.accumulated_depreciation, 'book_value', a.acquisition_cost - a.accumulated_depreciation,
      'useful_life_months', a.useful_life_months, 'months_depreciated', a.months_depreciated, 'warranty_until', a.warranty_until,
      'status', a.status, 'photo_path', a.photo_path,
      'pending', exists (select 1 from ast_transfers t where t.asset_id = a.id and t.status = 'pending_approval')
              or exists (select 1 from ast_disposals x where x.asset_id = a.id and x.status = 'pending_approval')) order by a.asset_number)
    from ast_assets a join ast_categories k on k.id = a.category_id left join sys_outlets o on o.id = a.outlet_id left join sys_users u on u.id = a.pic_user_id
    where a.company_id = sys_current_company_id() and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id))
      and (p_status = 'all' or a.status = p_status)), '[]'::jsonb);
end $$;

create or replace function ast_find_by_code(p_code text)
returns uuid language sql stable security definer set search_path = public as $$
  select id from ast_assets
  where company_id = sys_current_company_id() and ast_can_view() and (outlet_id is null or sys_can_access_outlet(outlet_id))
    and (upper(asset_number) = upper(trim(p_code)) or upper(serial_number) = upper(trim(p_code)))
  order by upper(asset_number) = upper(trim(p_code)) desc limit 1
$$;

-- daftar pengajuan mutasi & pelepasan
create or replace function ast_requests(p_status text default 'pending_approval')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return coalesce((select jsonb_agg(r order by r->>'created_at' desc) from (
    select jsonb_build_object('kind', 'transfer', 'id', t.id, 'number', t.transfer_number, 'date', t.transfer_date, 'status', t.status,
      'asset_id', a.id, 'asset_number', a.asset_number, 'asset', a.name,
      'detail', coalesce(fo.name, 'Kantor pusat') || ' → ' || coalesce(tt.name, 'Kantor pusat') || coalesce(' / ' || t.to_location, ''),
      'reason', t.reason, 'requested_by', ru.full_name, 'decision_note', t.decision_note, 'mine', t.requested_by = auth.uid(), 'created_at', t.created_at) r
    from ast_transfers t join ast_assets a on a.id = t.asset_id left join sys_outlets fo on fo.id = t.from_outlet_id
    left join sys_outlets tt on tt.id = t.to_outlet_id left join sys_users ru on ru.id = t.requested_by
    where t.company_id = sys_current_company_id() and (p_status = 'all' or t.status = p_status)
      and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id) or (t.to_outlet_id is not null and sys_can_access_outlet(t.to_outlet_id)))
    union all
    select jsonb_build_object('kind', 'disposal', 'id', x.id, 'number', x.disposal_number, 'date', x.disposal_date, 'status', x.status,
      'asset_id', a.id, 'asset_number', a.asset_number, 'asset', a.name,
      'detail', case x.disposal_type when 'sold' then 'Dijual Rp ' || to_char(x.proceeds, 'FM999G999G999G990') when 'scrapped' then 'Rusak / dibuang'
        when 'lost' then 'Hilang' else 'Dihibahkan' end || ' · nilai buku Rp ' || to_char(coalesce(x.book_value, 0), 'FM999G999G999G990'),
      'reason', x.reason, 'requested_by', ru.full_name, 'decision_note', x.decision_note, 'mine', x.requested_by = auth.uid(), 'created_at', x.created_at)
    from ast_disposals x join ast_assets a on a.id = x.asset_id left join sys_users ru on ru.id = x.requested_by
    where x.company_id = sys_current_company_id() and (p_status = 'all' or x.status = p_status)
      and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id))) s), '[]'::jsonb);
end $$;

-- pilihan untuk form aset (staf aset tanpa izin keuangan tetap bisa memilih akun kas/bank)
create or replace function ast_options()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c uuid := sys_current_company_id();
begin
  if v_c is null or not ast_can_view() then raise exception 'Butuh izin lihat aset'; end if;
  return jsonb_build_object(
    'categories', coalesce((select jsonb_agg(to_jsonb(k) order by k.sort_order, k.name) from ast_categories k where k.company_id = v_c), '[]'::jsonb),
    'outlets', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from sys_outlets
      where company_id = v_c and is_active and sys_can_access_outlet(id)), '[]'::jsonb),
    'all_outlets', sys_user_all_outlets(),
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', full_name) order by full_name) from sys_users
      where company_id = v_c and is_active), '[]'::jsonb),
    'suppliers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from pur_suppliers
      where company_id = v_c and is_active and supplier_type = 'external'), '[]'::jsonb),
    -- kas & bank (aset lancar selain piutang / persediaan)
    'cash_accounts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', code || ' ' || name, 'key', system_key) order by code) from fin_accounts
      where company_id = v_c and account_type = 'asset' and not is_header and is_active and code < '1-2'
        and coalesce(system_key, '') not in ('ar', 'inventory', 'ic_receivable')), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', code || ' ' || name, 'type', account_type, 'key', system_key) order by code)
      from fin_accounts where company_id = v_c and not is_header and is_active and account_type in ('asset', 'expense', 'cogs')), '[]'::jsonb),
    'settings', (select to_jsonb(s) from ast_settings s where s.company_id = v_c),
    'can_manage', sys_has_permission('asset.manage'),
    'can_depreciate', (sys_has_permission('asset.manage') or sys_has_permission('finance.manage')) and sys_user_all_outlets());
end $$;

-- ---------------------------------------------------------------------
-- FOTO ASET (storage privat): asset-files/<company>/<asset_id>/...
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('asset-files', 'asset-files', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function ast_file_ok(p_name text, p_write boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = sys_current_company_id()::text
     and (case when p_write then sys_has_permission('asset.manage') else ast_can_view() end)
     and ((storage.foldername(p_name))[2] = 'new' or exists (
       select 1 from ast_assets a where a.id::text = (storage.foldername(p_name))[2] and a.company_id = sys_current_company_id()
         and (a.outlet_id is null or sys_can_access_outlet(a.outlet_id))))
$$;
create policy asset_files_select on storage.objects for select to authenticated using (bucket_id = 'asset-files' and ast_file_ok(name, false));
create policy asset_files_insert on storage.objects for insert to authenticated with check (bucket_id = 'asset-files' and ast_file_ok(name, true));
create policy asset_files_delete on storage.objects for delete to authenticated using (bucket_id = 'asset-files' and ast_file_ok(name, true));

-- ---------------------------------------------------------------------
-- HAK EKSEKUSI
-- ---------------------------------------------------------------------
revoke execute on function ast_ensure_setup(uuid)                 from public, anon, authenticated;
revoke execute on function ast_post_acquisition(uuid)             from public, anon, authenticated;
revoke execute on function ast_refresh_asset(uuid)                from public, anon, authenticated;
revoke execute on function ast_log(uuid, text, text)              from public, anon, authenticated;
revoke execute on function ast_complete_transfer(uuid)            from public, anon, authenticated;
revoke execute on function ast_complete_disposal(uuid)            from public, anon, authenticated;
revoke execute on function ast_sync_approval()                    from public, anon, authenticated;
revoke execute on function ast_last_period(uuid)                  from public, anon, authenticated;
revoke execute on function ast_check_account(uuid, text[], text)  from public, anon, authenticated;
do $$
declare f text;
begin
  -- fungsi untuk aplikasi: hanya user login (bukan anon)
  foreach f in array array['ast_can_view()', 'ast_require_manage()', 'ast_setup()', 'ast_save_settings(numeric)', 'ast_save_category(jsonb)',
    'ast_save_asset(jsonb)', 'ast_delete_asset(uuid)', 'ast_record_payment(uuid, uuid, numeric, date, text)', 'ast_depreciation_preview(date)',
    'ast_run_depreciation(date)', 'ast_void_depreciation(date)', 'ast_request_transfer(jsonb)', 'ast_request_disposal(jsonb)',
    'ast_cancel_request(text, uuid)', 'ast_summary()', 'ast_asset_detail(uuid)', 'ast_list(text)', 'ast_find_by_code(text)',
    'ast_requests(text)', 'ast_file_ok(text, boolean)', 'ast_options()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
