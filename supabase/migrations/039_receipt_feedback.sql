-- =====================================================================
-- SEMAR - 039: STRUK 80MM + QR ULASAN PELANGGAN
--   * sys_outlets: pengaturan struk (teks atas/bawah, logo, QR ulasan, link Google review).
--   * pos_receipt_data(): semua isi struk dalam satu panggilan (logo brand, kasir, item, pembayaran,
--     member, token ulasan). Token acak dibuat saat struk pertama dicetak.
--   * crm_feedback_settings / crm_feedback_questions / crm_feedback_responses: satu form ulasan + saran
--     yang dibuka dari QR di struk (tanpa login). Pertanyaan bisa diatur; analisa (rating, NPS, aspek,
--     tren, per outlet) & tindak lanjut ulasan buruk.
--   Izin baru: feedback.view (lihat ulasan & analisa), feedback.manage (atur form & tindak lanjut).
-- =====================================================================

alter table sys_outlets add column if not exists receipt_header text;
alter table sys_outlets add column if not exists receipt_footer text not null default 'Terima kasih atas kunjungan Anda';
alter table sys_outlets add column if not exists receipt_show_logo boolean not null default true;
alter table sys_outlets add column if not exists receipt_show_feedback_qr boolean not null default true;
alter table sys_outlets add column if not exists google_review_url text check (google_review_url is null or google_review_url ~ '^https://');
alter table sys_companies add column if not exists tax_number text;

alter table pos_orders add column if not exists feedback_token text unique;

-- ---------------------------------------------------------------------
-- FORM ULASAN
-- ---------------------------------------------------------------------
create table crm_feedback_settings (
  company_id      uuid primary key references sys_companies(id),
  is_enabled      boolean not null default true,
  title           text not null default 'Bagaimana pengalamanmu?',
  intro           text not null default 'Butuh kurang dari 1 menit. Masukanmu langsung dibaca tim kami.',
  thank_you       text not null default 'Terima kasih! Masukanmu sangat berarti untuk kami.',
  incentive_text  text,                          -- mis. "Tunjukkan halaman ini: gratis es teh di kunjungan berikutnya"
  ask_contact     boolean not null default true,
  max_days        int not null default 14 check (max_days between 1 and 90),
  updated_at      timestamptz not null default now()
);
select sys_apply_company_policies('crm_feedback_settings', 'feedback.manage');

create table crm_feedback_questions (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references sys_companies(id),
  kind        text not null check (kind in ('stars', 'aspects', 'nps', 'choice', 'text')),
  label       text not null check (trim(label) <> ''),
  help        text,
  options     text[] not null default '{}',     -- aspek (aspects) / pilihan (choice)
  is_overall  boolean not null default false,   -- rating utama (dipakai untuk rata-rata & sentimen)
  required    boolean not null default false,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (kind not in ('aspects', 'choice') or cardinality(options) > 0)
);
select sys_apply_company_policies('crm_feedback_questions', 'feedback.manage');
create trigger trg_crm_feedback_questions_audit after insert or update or delete on crm_feedback_questions for each row execute function sys_audit_trigger('');

create table crm_feedback_responses (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references sys_companies(id),
  outlet_id      uuid references sys_outlets(id) on delete set null,
  order_id       uuid unique references pos_orders(id) on delete set null,
  answers        jsonb not null default '{}',   -- {question_id: nilai}
  overall        int check (overall between 1 and 5),
  nps            int check (nps between 0 and 10),
  comment        text,                          -- gabungan jawaban teks (untuk pencarian & daftar)
  contact_name   text,
  contact_phone  text,
  contact_ok     boolean not null default false,
  status         text not null default 'new' check (status in ('new', 'followed_up', 'resolved')),
  follow_note    text,
  handled_by     uuid references sys_users(id),
  handled_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index crm_feedback_responses_company_date on crm_feedback_responses (company_id, created_at);
alter table crm_feedback_responses enable row level security;
create policy crm_feedback_responses_select on crm_feedback_responses for select to authenticated
  using (company_id = sys_current_company_id() and (sys_has_permission('feedback.view') or sys_has_permission('feedback.manage'))
         and (outlet_id is null or sys_can_access_outlet(outlet_id)));
-- tulis hanya lewat fungsi

-- pertanyaan standar (pendek: 5 layar, < 1 menit)
create or replace function crm_setup_feedback(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into crm_feedback_settings (company_id) values (p_company_id) on conflict do nothing;
  if exists (select 1 from crm_feedback_questions where company_id = p_company_id) then return; end if;
  insert into crm_feedback_questions (company_id, kind, label, help, options, is_overall, required, sort_order) values
    (p_company_id, 'stars', 'Secara keseluruhan, bagaimana kunjunganmu hari ini?', null, '{}', true, true, 10),
    (p_company_id, 'aspects', 'Nilai beberapa hal ini', 'Lewati yang tidak kamu rasakan',
       array['Rasa makanan & minuman', 'Kecepatan penyajian', 'Keramahan staf', 'Kebersihan tempat', 'Harga sesuai kualitas'], false, false, 20),
    (p_company_id, 'nps', 'Seberapa mungkin kamu merekomendasikan kami ke teman?', '0 = tidak mungkin, 10 = sangat mungkin', '{}', false, false, 30),
    (p_company_id, 'choice', 'Apa yang paling kamu suka?', 'Boleh pilih lebih dari satu',
       array['Rasa', 'Porsi', 'Harga', 'Pelayanan', 'Suasana', 'Kecepatan', 'Kebersihan'], false, false, 40),
    (p_company_id, 'text', 'Ada saran atau masukan untuk kami?', 'Menu yang kamu inginkan, hal yang perlu diperbaiki, apa saja', '{}', false, false, 50);
end $$;
do $$
declare c record;
begin
  for c in select id from sys_companies loop perform crm_setup_feedback(c.id); end loop;
end $$;
create or replace function crm_company_feedback_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform crm_setup_feedback(new.id);
  return new;
end $$;
create trigger trg_sys_companies_feedback after insert on sys_companies for each row execute function crm_company_feedback_trigger();

-- ---------------------------------------------------------------------
-- DATA STRUK
-- ---------------------------------------------------------------------
create or replace function pos_receipt_data(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_o pos_orders; v_token text;
begin
  select * into v_o from pos_orders where id = p_order_id and company_id = sys_current_company_id();
  if v_o.id is null or not sys_can_access_outlet(v_o.outlet_id) then raise exception 'Order tidak ditemukan'; end if;
  if not (sys_has_permission('pos.order') or sys_has_permission('pos.pay') or sys_has_permission('report.view')) then raise exception 'Butuh izin kasir'; end if;
  -- token ulasan acak (tidak bisa ditebak) untuk order yang sudah dibayar
  if v_o.status = 'paid' and v_o.feedback_token is null then
    update pos_orders set feedback_token = replace(gen_random_uuid()::text, '-', '') where id = v_o.id returning feedback_token into v_token;
  else
    v_token := v_o.feedback_token;
  end if;
  return pos_receipt_payload(v_o.id) || jsonb_build_object('feedback_token', case when v_o.status = 'paid' then v_token end);
end $$;

-- isi struk (dipakai kasir & nanti kiosk); tanpa cek izin -> jangan dipanggil langsung dari klien
create or replace function pos_receipt_payload(p_order_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'status', o.status, 'sales_channel', o.sales_channel,
      'order_source', o.order_source, 'customer_name', o.customer_name, 'guest_count', o.guest_count, 'note', o.note,
      'created_at', o.created_at, 'paid_at', o.paid_at, 'table', t.code,
      'subtotal', o.subtotal, 'discount_amount', o.discount_amount, 'promotion_amount', o.promotion_amount, 'promotion', pr.name,
      'points_redeemed', o.points_redeemed, 'points_amount', o.points_amount, 'points_earned', o.points_earned,
      'service_amount', o.service_amount, 'tax_amount', o.tax_amount, 'rounding_amount', o.rounding_amount, 'grand_total', o.grand_total,
      'cashier', (select full_name from sys_users where id = o.created_by)),
    'outlet', jsonb_build_object('name', ol.name, 'address', ol.address, 'phone', ol.phone, 'tax_rate', ol.tax_rate,
      'header', ol.receipt_header, 'footer', ol.receipt_footer, 'show_logo', ol.receipt_show_logo,
      'show_feedback_qr', ol.receipt_show_feedback_qr and coalesce(fs.is_enabled, true)),
    'brand', jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url)),
    'company', jsonb_build_object('name', c.name, 'tax_number', c.tax_number),
    'feedback', jsonb_build_object('title', fs.title, 'incentive', fs.incentive_text),
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.menu_item_name, 'qty', i.quantity, 'unit_price', i.unit_price,
        'line_total', i.line_total, 'note', i.note,
        'modifiers', coalesce((select jsonb_agg(m.modifier_name) from pos_order_item_modifiers m where m.order_item_id = i.id), '[]'::jsonb))
        order by i.created_at)
      from pos_order_items i where i.order_id = o.id and not i.is_void), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', pm.name, 'amount', p.amount, 'change', p.change_amount) order by p.created_at)
      from pos_payments p join mst_payment_methods pm on pm.id = p.payment_method_id where p.order_id = o.id), '[]'::jsonb),
    'member', case when cu.id is not null then jsonb_build_object('name', cu.name, 'points_balance', cu.points_balance) end)
  from pos_orders o
  join sys_outlets ol on ol.id = o.outlet_id
  join sys_companies c on c.id = o.company_id
  left join sys_brands b on b.id = ol.brand_id
  left join mst_tables t on t.id = o.table_id
  left join crm_promotions pr on pr.id = o.promotion_id
  left join crm_customers cu on cu.id = o.customer_id
  left join crm_feedback_settings fs on fs.company_id = o.company_id
  where o.id = p_order_id
$$;
revoke execute on function pos_receipt_payload(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- FORM PUBLIK (tanpa login, dari QR di struk)
-- ---------------------------------------------------------------------
create or replace function public_feedback_form(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_o pos_orders; v_set crm_feedback_settings; v_state text;
begin
  if coalesce(length(p_token), 0) <> 32 then return jsonb_build_object('state', 'invalid'); end if;
  select * into v_o from pos_orders where feedback_token = p_token and status = 'paid';
  if v_o.id is null then return jsonb_build_object('state', 'invalid'); end if;
  select * into v_set from crm_feedback_settings where company_id = v_o.company_id;
  v_state := case
    when not coalesce(v_set.is_enabled, true) then 'disabled'
    when exists (select 1 from crm_feedback_responses where order_id = v_o.id) then 'done'
    when coalesce(v_o.paid_at, v_o.created_at) < now() - make_interval(days => coalesce(v_set.max_days, 14)) then 'expired'
    else 'open' end;
  -- hanya info yang perlu untuk form: nama outlet & brand, tanggal kunjungan (tanpa harga / isi pesanan)
  return jsonb_build_object('state', v_state,
    'outlet', (select name from sys_outlets where id = v_o.outlet_id),
    'brand', (select jsonb_build_object('name', b.name, 'logo_url', coalesce(nullif(b.logo_url, ''), c.logo_url))
              from sys_outlets ol join sys_companies c on c.id = ol.company_id left join sys_brands b on b.id = ol.brand_id where ol.id = v_o.outlet_id),
    'visited_at', coalesce(v_o.paid_at, v_o.created_at),
    'google_review_url', (select google_review_url from sys_outlets where id = v_o.outlet_id),
    'settings', jsonb_build_object('title', coalesce(v_set.title, 'Bagaimana pengalamanmu?'), 'intro', v_set.intro, 'thank_you', v_set.thank_you,
      'incentive', v_set.incentive_text, 'ask_contact', coalesce(v_set.ask_contact, true)),
    'questions', case when v_state = 'open' then coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'label', q.label,
        'help', q.help, 'options', q.options, 'required', q.required, 'is_overall', q.is_overall) order by q.sort_order, q.created_at)
      from crm_feedback_questions q where q.company_id = v_o.company_id and q.is_active), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- kirim ulasan: satu kali per struk, divalidasi terhadap pertanyaan aktif
create or replace function public_submit_feedback(p_token text, p_answers jsonb, p_contact jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_o pos_orders; v_form jsonb; q record; v jsonb; v_clean jsonb := '{}'; v_overall int; v_nps int; v_texts text[] := '{}';
  v_phone text := nullif(regexp_replace(coalesce(p_contact->>'phone', ''), '[^0-9+]', '', 'g'), '');
begin
  v_form := public_feedback_form(p_token);
  if v_form->>'state' <> 'open' then raise exception '%', case v_form->>'state'
    when 'done' then 'Ulasan untuk struk ini sudah dikirim. Terima kasih!' when 'expired' then 'Batas waktu ulasan untuk struk ini sudah lewat'
    when 'disabled' then 'Form ulasan sedang tidak aktif' else 'Link ulasan tidak valid' end; end if;
  select * into v_o from pos_orders where feedback_token = p_token;
  if jsonb_typeof(coalesce(p_answers, '{}'::jsonb)) <> 'object' then raise exception 'Jawaban tidak valid'; end if;
  for q in select * from crm_feedback_questions where company_id = v_o.company_id and is_active loop
    v := p_answers->(q.id::text);
    if v is null or v = 'null'::jsonb or v = '""'::jsonb or v = '[]'::jsonb or v = '{}'::jsonb then
      if q.required then raise exception 'Pertanyaan "%" wajib dijawab', q.label; end if;
      continue;
    end if;
    if q.kind = 'stars' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric not in (1, 2, 3, 4, 5) then raise exception 'Nilai bintang tidak valid'; end if;
      if q.is_overall and v_overall is null then v_overall := (v #>> '{}')::int; end if;
    elsif q.kind = 'nps' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric not between 0 and 10 or (v #>> '{}')::numeric <> floor((v #>> '{}')::numeric) then raise exception 'Nilai rekomendasi tidak valid'; end if;
      v_nps := coalesce(v_nps, (v #>> '{}')::int);
    elsif q.kind = 'aspects' then
      if jsonb_typeof(v) <> 'object' or exists (select 1 from jsonb_each(v) e
          where not (e.key = any(q.options)) or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}')::numeric not in (1, 2, 3, 4, 5)) then
        raise exception 'Nilai aspek tidak valid';
      end if;
    elsif q.kind = 'choice' then
      if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements_text(v) x where not (x = any(q.options))) then raise exception 'Pilihan tidak valid'; end if;
    else
      if jsonb_typeof(v) <> 'string' then raise exception 'Jawaban teks tidak valid'; end if;
      v := to_jsonb(left(trim(v #>> '{}'), 1000));
      v_texts := v_texts || (v #>> '{}');
    end if;
    v_clean := v_clean || jsonb_build_object(q.id::text, v);
  end loop;
  insert into crm_feedback_responses (company_id, outlet_id, order_id, answers, overall, nps, comment, contact_name, contact_phone, contact_ok)
  values (v_o.company_id, v_o.outlet_id, v_o.id, v_clean, v_overall, v_nps, nullif(array_to_string(v_texts, E'\n'), ''),
    left(nullif(trim(coalesce(p_contact->>'name', '')), ''), 80), left(v_phone, 20),
    coalesce((p_contact->>'ok')::boolean, false) and v_phone is not null);
  return jsonb_build_object('ok', true, 'thank_you', v_form->'settings'->>'thank_you', 'incentive', v_form->'settings'->>'incentive',
    'google_review_url', case when v_overall >= 4 then v_form->>'google_review_url' end);
end $$;
grant execute on function public_feedback_form(text) to anon, authenticated;
grant execute on function public_submit_feedback(text, jsonb, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- ANALISA & TINDAK LANJUT
-- ---------------------------------------------------------------------
create or replace function crm_feedback_summary(p_from date, p_to date, p_outlet_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_company uuid := sys_current_company_id();
begin
  if not (sys_has_permission('feedback.view') or sys_has_permission('feedback.manage')) then raise exception 'Butuh izin lihat ulasan'; end if;
  return (
    with r as (
      select * from crm_feedback_responses
      where company_id = v_company and (created_at at time zone 'Asia/Jakarta')::date between p_from and p_to
        and (p_outlet_id is null or outlet_id = p_outlet_id) and (outlet_id is null or sys_can_access_outlet(outlet_id))
    ), paid as (
      select count(*) as n from pos_orders where company_id = v_company and status = 'paid' and business_date between p_from and p_to
        and (p_outlet_id is null or outlet_id = p_outlet_id) and sys_can_access_outlet(outlet_id)
    )
    select jsonb_build_object(
      'responses', (select count(*) from r),
      'paid_orders', (select n from paid),
      'avg_overall', (select round(avg(overall), 2) from r),
      'overall_dist', (select jsonb_object_agg(s, (select count(*) from r where overall = s)) from generate_series(1, 5) s),
      'nps', (select case when count(nps) > 0 then round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(nps)) end from r),
      'nps_count', (select count(nps) from r),
      'negative_open', (select count(*) from r where overall <= 2 and status = 'new'),
      'questions', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'label', q.label,
          'stats', case q.kind
            when 'stars' then jsonb_build_object('avg', (select round(avg((answers->>q.id::text)::numeric), 2) from r where answers ? q.id::text),
                                                 'count', (select count(*) from r where answers ? q.id::text))
            when 'aspects' then (select jsonb_object_agg(a, (select jsonb_build_object('avg', round(avg((answers->q.id::text->>a)::numeric), 2),
                                    'count', count(answers->q.id::text->>a)) from r where answers->q.id::text ? a)) from unnest(q.options) a)
            when 'choice' then (select jsonb_object_agg(a, (select count(*) from r where answers->q.id::text ? a)) from unnest(q.options) a)
            else jsonb_build_object('count', (select count(*) from r where answers ? q.id::text)) end) order by q.sort_order)
        from crm_feedback_questions q where q.company_id = v_company and q.kind <> 'nps'), '[]'::jsonb),
      'trend', coalesce((select jsonb_agg(jsonb_build_object('week', w, 'count', n, 'avg', a) order by w)
        from (select date_trunc('week', created_at at time zone 'Asia/Jakarta')::date as w, count(*) as n, round(avg(overall), 2) as a from r group by 1) t), '[]'::jsonb),
      'outlets', coalesce((select jsonb_agg(jsonb_build_object('outlet', o.name, 'count', x.n, 'avg', x.a, 'nps', x.nps) order by x.a desc nulls last)
        from (select outlet_id, count(*) as n, round(avg(overall), 2) as a,
                case when count(nps) > 0 then round(100.0 * (count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6)) / count(nps)) end as nps
              from r group by outlet_id) x left join sys_outlets o on o.id = x.outlet_id), '[]'::jsonb)));
end $$;

create or replace function crm_feedback_list(p_from date, p_to date, p_outlet_id uuid default null, p_filter text default 'all')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (sys_has_permission('feedback.view') or sys_has_permission('feedback.manage')) then raise exception 'Butuh izin lihat ulasan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('outlet', o.name, 'order_number', po.order_number, 'grand_total', po.grand_total,
      'handler', (select full_name from sys_users where id = r.handled_by)) order by r.created_at desc)
    from crm_feedback_responses r left join sys_outlets o on o.id = r.outlet_id left join pos_orders po on po.id = r.order_id
    where r.company_id = sys_current_company_id() and (r.created_at at time zone 'Asia/Jakarta')::date between p_from and p_to
      and (p_outlet_id is null or r.outlet_id = p_outlet_id) and (r.outlet_id is null or sys_can_access_outlet(r.outlet_id))
      and case p_filter when 'negative' then r.overall <= 2 when 'positive' then r.overall >= 4 when 'comment' then r.comment is not null
                        when 'open' then r.status = 'new' and r.overall <= 3 else true end), '[]'::jsonb);
end $$;

create or replace function crm_feedback_update(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_r crm_feedback_responses;
begin
  if not sys_has_permission('feedback.manage') then raise exception 'Butuh izin kelola ulasan'; end if;
  select * into v_r from crm_feedback_responses where id = p_id and company_id = sys_current_company_id();
  if v_r.id is null or (v_r.outlet_id is not null and not sys_can_access_outlet(v_r.outlet_id)) then raise exception 'Ulasan tidak ditemukan'; end if;
  if p_status not in ('new', 'followed_up', 'resolved') then raise exception 'Status tidak dikenal'; end if;
  update crm_feedback_responses set status = p_status, follow_note = coalesce(nullif(trim(coalesce(p_note, '')), ''), follow_note),
    handled_by = auth.uid(), handled_at = now() where id = p_id;
end $$;

-- badge: ulasan buruk (<= 2 bintang) yang belum ditindaklanjuti
create or replace function crm_feedback_open_count()
returns int language sql stable security definer set search_path = public as $$
  select case when sys_has_permission('feedback.manage') or sys_has_permission('feedback.view') then
    (select count(*)::int from crm_feedback_responses where company_id = sys_current_company_id() and status = 'new' and overall <= 2
       and (outlet_id is null or sys_can_access_outlet(outlet_id))) else 0 end
$$;
