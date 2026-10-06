-- =====================================================================
-- ERP RESTORAN - 013: PAYMENT GATEWAY (disiapkan untuk iPay88)
--   Alur:
--   1. Kasir pilih "Bayar Online" -> pos_create_gateway_payment()  (buat RefNo)
--   2. Edge Function ipay88-checkout menandatangani request & mengembalikan
--      form ke halaman pembayaran iPay88
--   3. iPay88 memanggil Edge Function ipay88-callback (BackendURL)
--      -> verifikasi tanda tangan -> pos_complete_gateway_payment()
--      (hanya bisa dipanggil service_role)
--   Merchant key TIDAK pernah bisa dibaca dari aplikasi.
-- =====================================================================

create table sys_payment_gateways (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references sys_companies(id),
  provider          text not null default 'ipay88',
  environment       text not null default 'sandbox',        -- sandbox / production
  merchant_code     text,
  signature_method  text not null default 'hmac_sha512',    -- hmac_sha512 / sha256 (lihat dokumen iPay88 Anda)
  payment_ids       jsonb not null default '[]',            -- metode yang ditampilkan, mis. [{"id":"...","name":"QRIS"}]
  is_active         boolean not null default false,
  has_merchant_key  boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, provider),
  check (environment in ('sandbox', 'production')),
  check (signature_method in ('hmac_sha512', 'sha256'))
);

-- Rahasia: RLS aktif TANPA policy -> hanya service_role (Edge Function) yang bisa membaca
create table sys_payment_gateway_secrets (
  gateway_id    uuid primary key references sys_payment_gateways(id) on delete cascade,
  merchant_key  text not null,
  updated_at    timestamptz not null default now()
);
alter table sys_payment_gateway_secrets enable row level security;

create table pos_payment_requests (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references sys_companies(id),
  outlet_id       uuid not null references sys_outlets(id),
  order_id        uuid not null references pos_orders(id),
  gateway_id      uuid not null references sys_payment_gateways(id),
  ref_no          text not null unique,          -- dikirim ke iPay88 sebagai RefNo
  amount          numeric(15,2) not null,
  currency        text not null default 'IDR',
  payment_id      text,                          -- metode pilihan (kode iPay88)
  status          text not null default 'pending',   -- pending / success / failed / cancelled
  trans_id        text,                          -- TransId dari iPay88
  auth_code       text,
  error_desc      text,
  requested_by    uuid references sys_users(id),
  raw_response    jsonb,
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index idx_pos_payment_requests_order on pos_payment_requests(order_id);

select sys_attach_updated_at_triggers();
select sys_apply_company_policies('sys_payment_gateways', 'settings.manage');
select sys_apply_company_policies('pos_payment_requests');   -- hanya lewat fungsi

-- flag has_merchant_key hanya diubah lewat sys_set_payment_gateway_secret
revoke update on sys_payment_gateways from authenticated, anon;
grant update (environment, merchant_code, signature_method, payment_ids, is_active) on sys_payment_gateways to authenticated;

-- Pembayaran metode gateway hanya boleh dicatat oleh callback (service_role, tanpa user login)
create or replace function pos_check_gateway_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and exists (
      select 1 from mst_payment_methods where id = new.payment_method_id and type = 'gateway') then
    raise exception 'Pembayaran online hanya bisa dicatat otomatis oleh iPay88';
  end if;
  return new;
end $$;

create trigger trg_pos_payments_gateway before insert on pos_payments
  for each row execute function pos_check_gateway_payment();

alter publication supabase_realtime add table pos_payment_requests;

create trigger trg_sys_payment_gateways_audit after insert or update on sys_payment_gateways
  for each row execute function sys_audit_trigger('');

-- Simpan / ganti merchant key (tulis saja, tidak bisa dibaca kembali)
create or replace function sys_set_payment_gateway_secret(p_gateway_id uuid, p_merchant_key text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not sys_has_permission('settings.manage') then raise exception 'Tidak punya izin'; end if;
  if coalesce(trim(p_merchant_key), '') = '' then raise exception 'Merchant key kosong'; end if;
  if not exists (select 1 from sys_payment_gateways where id = p_gateway_id and company_id = sys_current_company_id()) then
    raise exception 'Gateway tidak ditemukan';
  end if;
  insert into sys_payment_gateway_secrets (gateway_id, merchant_key) values (p_gateway_id, trim(p_merchant_key))
  on conflict (gateway_id) do update set merchant_key = excluded.merchant_key, updated_at = now();
  update sys_payment_gateways set has_merchant_key = true where id = p_gateway_id;
  perform sys_log_activity(sys_current_company_id(), 'update_secret', 'sys_payment_gateways', p_gateway_id, 'Merchant key iPay88', null);
end $$;

-- Metode bayar "Online (iPay88)" di POS dibuat otomatis saat gateway aktif
create or replace function sys_on_gateway_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_active then
    insert into mst_payment_methods (company_id, code, name, type, sort_order)
    values (new.company_id, new.provider, 'Online (iPay88)', 'gateway', 90)
    on conflict (company_id, code) do update set is_active = true;
  else
    update mst_payment_methods set is_active = false where company_id = new.company_id and code = new.provider;
  end if;
  return new;
end $$;

create trigger trg_sys_payment_gateways_method after insert or update of is_active on sys_payment_gateways
  for each row execute function sys_on_gateway_change();

-- =====================================================================
-- LANGKAH 1: kasir membuat permintaan pembayaran online
-- =====================================================================
create or replace function pos_create_gateway_payment(p_order_id uuid, p_payment_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o   pos_orders%rowtype;
  g   sys_payment_gateways%rowtype;
  r   pos_payment_requests%rowtype;
  n   int;
begin
  if not sys_has_permission('pos.pay') then raise exception 'Tidak punya izin menerima pembayaran'; end if;
  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found or o.status <> 'open' then raise exception 'Order tidak ditemukan / sudah ditutup'; end if;
  if o.grand_total <= 0 then raise exception 'Total order 0'; end if;
  if exists (select 1 from pos_order_items where order_id = o.id and kitchen_status = 'waiting' and not is_void) then
    raise exception 'Masih ada pesanan QR yang belum dikonfirmasi';
  end if;
  if not exists (select 1 from pos_shifts where outlet_id = o.outlet_id and user_id = auth.uid() and status = 'open') then
    raise exception 'Buka shift kasir terlebih dahulu';
  end if;

  select * into g from sys_payment_gateways
  where company_id = o.company_id and provider = 'ipay88' and is_active and has_merchant_key and merchant_code is not null;
  if not found then raise exception 'Pembayaran online belum diaktifkan. Atur di Pengaturan > Pembayaran Online.'; end if;

  -- request lama yang masih pending untuk order ini dibatalkan (nominal bisa berubah)
  update pos_payment_requests set status = 'cancelled' where order_id = o.id and status = 'pending';

  select count(*) + 1 into n from pos_payment_requests where order_id = o.id;
  insert into pos_payment_requests (company_id, outlet_id, order_id, gateway_id, ref_no, amount, payment_id, requested_by)
  values (o.company_id, o.outlet_id, o.id, g.id,
          replace(o.order_number, '/', '') || '-' || n, o.grand_total, p_payment_id, auth.uid())
  returning * into r;
  return to_jsonb(r);
end $$;

-- =====================================================================
-- LANGKAH 3: dipanggil Edge Function setelah tanda tangan iPay88 valid
-- =====================================================================
create or replace function pos_complete_gateway_payment(
  p_ref_no text, p_success boolean, p_amount numeric, p_trans_id text, p_auth_code text,
  p_error_desc text, p_raw jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r        pos_payment_requests%rowtype;
  o        pos_orders%rowtype;
  v_method uuid;
  v_shift  uuid;
begin
  select * into r from pos_payment_requests where ref_no = p_ref_no for update;
  if not found then raise exception 'RefNo tidak dikenal: %', p_ref_no; end if;
  if r.status = 'success' then return to_jsonb(r); end if;   -- callback dobel: abaikan

  if not p_success then
    update pos_payment_requests set status = 'failed', error_desc = p_error_desc, raw_response = p_raw
    where id = r.id returning * into r;
    return to_jsonb(r);
  end if;

  if p_amount is distinct from r.amount then
    update pos_payment_requests set status = 'failed', error_desc = 'Nominal tidak cocok: ' || p_amount, raw_response = p_raw
    where id = r.id returning * into r;
    return to_jsonb(r);
  end if;

  select * into o from pos_orders where id = r.order_id for update;
  update pos_payment_requests set status = 'success', trans_id = p_trans_id, auth_code = p_auth_code,
         raw_response = p_raw, paid_at = now()
  where id = r.id returning * into r;

  -- uang sudah diterima gateway; tandai lunas meski order sempat berubah (dicatat untuk dicek)
  if o.status = 'open' then
    select id into v_method from mst_payment_methods where company_id = o.company_id and code = 'ipay88';
    select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = r.requested_by and status = 'open' limit 1;

    insert into pos_payments (company_id, order_id, payment_method_id, amount, reference_number)
    values (o.company_id, o.id, v_method, r.amount, coalesce(p_trans_id, r.ref_no));
    update pos_orders set status = 'paid', paid_at = now(), shift_id = coalesce(v_shift, shift_id) where id = o.id;
    if o.table_id is not null then
      update mst_tables set status = 'available'
      where id = o.table_id and not exists (select 1 from pos_orders where table_id = o.table_id and status = 'open');
    end if;
  end if;
  return to_jsonb(r);
end $$;

revoke execute on function pos_complete_gateway_payment(text, boolean, numeric, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function pos_complete_gateway_payment(text, boolean, numeric, text, text, text, jsonb) to service_role;
