-- =====================================================================
-- SANTAP ERP - 019: BATCH / LOT, FIFO COST (FEFO), KOLI TRANSFER, BARCODE
--   * Setiap stok masuk = 1 batch (kode label sendiri, lot supplier, kedaluwarsa, harga)
--   * Stok keluar mengambil batch FEFO (kedaluwarsa duluan), lalu FIFO (masuk duluan)
--   * HPP = harga batch yang terpakai (FIFO cost); inv_stocks.average_cost = nilai sisa / qty
--   * Jejak per batch: inv_stock_movement_batches (movement <-> batch)
--   * Transfer bisa dikirim per KOLI (dalam perjalanan) lalu diterima dengan scan label koli
-- =====================================================================

-- ---------------------------------------------------------------------
-- MASTER PRODUK
-- ---------------------------------------------------------------------
alter table inv_items add column track_batch     boolean not null default false;  -- wajib kedaluwarsa saat terima, label batch
alter table inv_items add column shelf_life_days int;                              -- umur simpan: kedaluwarsa otomatis
alter table inv_items add constraint inv_items_shelf_life_check check (shelf_life_days is null or shelf_life_days > 0);

-- ---------------------------------------------------------------------
-- BATCH & ALOKASI
-- ---------------------------------------------------------------------
create table inv_stock_batches (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references sys_companies(id),
  warehouse_id     uuid not null references inv_warehouses(id),
  item_id          uuid not null references inv_items(id),
  batch_code       text not null,                 -- kode label (barcode), ikut pindah gudang
  lot_number       text,                          -- nomor lot dari supplier / pabrik
  expiry_date      date,
  received_at      timestamptz not null default now(),   -- umur batch (urutan FIFO)
  qty_in           numeric(15,4) not null default 0,
  qty_remaining    numeric(15,4) not null default 0 check (qty_remaining >= 0),
  unit_cost        numeric(15,4) not null default 0,
  origin_batch_id  uuid references inv_stock_batches(id),  -- batch asal (hasil transfer)
  reference_type   text,
  reference_id     uuid,
  reference_number text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (warehouse_id, item_id, batch_code)
);
create index idx_inv_stock_batches_fefo on inv_stock_batches(warehouse_id, item_id, expiry_date, received_at) where qty_remaining > 0;
create index idx_inv_stock_batches_code on inv_stock_batches(company_id, batch_code);

-- movement -> batch: + masuk ke batch, - keluar dari batch
create table inv_stock_movement_batches (
  id           uuid primary key default gen_random_uuid(),
  seq          bigint generated always as identity,
  company_id   uuid not null references sys_companies(id),
  movement_id  uuid not null references inv_stock_movements(id) on delete cascade deferrable initially deferred,
  batch_id     uuid not null references inv_stock_batches(id),
  quantity     numeric(15,4) not null,
  unit_cost    numeric(15,4) not null,
  is_backfill  boolean not null default false,   -- menutup stok minus sebelumnya
  created_at   timestamptz not null default now()
);
create index idx_inv_stock_movement_batches_mv    on inv_stock_movement_batches(movement_id);
create index idx_inv_stock_movement_batches_batch on inv_stock_movement_batches(batch_id);

alter table inv_stock_movements add column batch_id           uuid references inv_stock_batches(id);  -- batch dipilih (scan label)
alter table inv_stock_movements add column batch_code         text;     -- kode batch untuk stok masuk (opsional)
alter table inv_stock_movements add column lot_number         text;
alter table inv_stock_movements add column expiry_date        date;
alter table inv_stock_movements add column source_movement_id uuid references inv_stock_movements(id);  -- refund / transfer: ikut batch asal
alter table inv_stock_movements add column unbatched_qty      numeric(15,4);  -- qty keluar saat stok batch kosong (stok minus)

-- Kode label pendek & mudah discan: L + YYMMDD + urut (mis. L2610070001)
create or replace function inv_next_batch_code(p_company_id uuid, p_date date default current_date)
returns text language sql security definer set search_path = public as $$
  select 'L' || to_char(p_date, 'YYMMDD') || lpad(sys_next_sequence(p_company_id, 'LOT/' || to_char(p_date, 'YYYYMMDD'))::text, 4, '0')
$$;

-- Harga cadangan bila tidak ada batch (stok minus / produk baru)
create or replace function inv_fallback_cost(p_warehouse_id uuid, p_item_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(average_cost, 0) from inv_stocks where warehouse_id = p_warehouse_id and item_id = p_item_id),
    (select nullif(unit_cost, 0) from inv_stock_batches where warehouse_id = p_warehouse_id and item_id = p_item_id
      order by received_at desc, created_at desc limit 1),
    (select last_purchase_cost from inv_items where id = p_item_id),
    0)
$$;

-- Ambil qty dari batch: batch pilihan dulu, lalu FEFO (kedaluwarsa terdekat), lalu FIFO
create or replace function inv_consume_batches(
  p_movement_id uuid, p_warehouse_id uuid, p_item_id uuid, p_qty numeric,
  p_prefer_batch_id uuid default null, p_backfill boolean default false,
  out consumed_value numeric, out unallocated_qty numeric)
language plpgsql security definer set search_path = public as $$
declare
  b      record;
  v_take numeric;
begin
  consumed_value := 0;
  unallocated_qty := p_qty;
  for b in
    select id, company_id, qty_remaining, unit_cost from inv_stock_batches
    where warehouse_id = p_warehouse_id and item_id = p_item_id and qty_remaining > 0
    order by coalesce(id = p_prefer_batch_id, false) desc, expiry_date nulls last, received_at, created_at
    for update
  loop
    exit when unallocated_qty <= 0;
    v_take := least(unallocated_qty, b.qty_remaining);
    update inv_stock_batches set qty_remaining = qty_remaining - v_take where id = b.id;
    insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost, is_backfill)
    values (b.company_id, p_movement_id, b.id, -v_take, b.unit_cost, p_backfill);
    consumed_value := consumed_value + v_take * b.unit_cost;
    unallocated_qty := unallocated_qty - v_take;
  end loop;
end $$;

-- Tambah qty ke batch (buat baru, atau gabung bila kode batch sama di gudang yang sama)
create or replace function inv_add_to_batch(
  p_movement_id uuid, p_company_id uuid, p_warehouse_id uuid, p_item_id uuid, p_qty numeric, p_cost numeric,
  p_batch_code text, p_lot text, p_expiry date, p_received_at timestamptz, p_origin uuid,
  p_ref_type text, p_ref_id uuid, p_ref_number text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into inv_stock_batches as b (company_id, warehouse_id, item_id, batch_code, lot_number, expiry_date, received_at,
    qty_in, qty_remaining, unit_cost, origin_batch_id, reference_type, reference_id, reference_number)
  values (p_company_id, p_warehouse_id, p_item_id, p_batch_code, nullif(trim(p_lot), ''), p_expiry, coalesce(p_received_at, now()),
    p_qty, p_qty, p_cost, p_origin, p_ref_type, p_ref_id, p_ref_number)
  on conflict (warehouse_id, item_id, batch_code) do update set
    unit_cost     = case when b.qty_remaining + excluded.qty_remaining > 0
                         then (b.qty_remaining * b.unit_cost + excluded.qty_remaining * excluded.unit_cost) / (b.qty_remaining + excluded.qty_remaining)
                         else excluded.unit_cost end,
    qty_in        = b.qty_in + excluded.qty_in,
    qty_remaining = b.qty_remaining + excluded.qty_remaining,
    lot_number    = coalesce(b.lot_number, excluded.lot_number),
    expiry_date   = coalesce(b.expiry_date, excluded.expiry_date)
  returning id into v_id;

  insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
  values (p_company_id, p_movement_id, v_id, p_qty, p_cost);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- MESIN STOK: setiap movement -> batch (FIFO cost) + saldo inv_stocks
-- ---------------------------------------------------------------------
create or replace function inv_apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_stock  inv_stocks%rowtype;
  v_item   inv_items%rowtype;
  v_value  numeric := 0;
  v_left   numeric;
  v_cost   numeric;
  v_take   numeric;
  v_rec    record;
  v_src    inv_stock_batches%rowtype;
begin
  insert into inv_stocks (company_id, warehouse_id, item_id)
  values (new.company_id, new.warehouse_id, new.item_id)
  on conflict (warehouse_id, item_id) do nothing;

  select * into v_stock from inv_stocks
  where warehouse_id = new.warehouse_id and item_id = new.item_id
  for update;
  select * into v_item from inv_items where id = new.item_id;

  if new.quantity < 0 then
    -- KELUAR: harga = batch yang terambil
    select c.consumed_value, c.unallocated_qty into v_value, v_left
    from inv_consume_batches(new.id, new.warehouse_id, new.item_id, -new.quantity, new.batch_id) c;
    if v_left > 0 then
      new.unbatched_qty := v_left;
      v_value := v_value + v_left * inv_fallback_cost(new.warehouse_id, new.item_id);
    end if;
    new.unit_cost := round(v_value / -new.quantity, 4);

  elsif new.quantity > 0 then
    v_left := new.quantity;

    -- MASUK dari movement lain (refund / transfer): ikut batch & harga asal
    if new.source_movement_id is not null then
      for v_rec in
        select a.batch_id, -a.quantity as qty, a.unit_cost from inv_stock_movement_batches a
        where a.movement_id = new.source_movement_id and a.quantity < 0 and not a.is_backfill
        order by a.seq
      loop
        exit when v_left <= 0;
        v_take := least(v_left, v_rec.qty);
        select * into v_src from inv_stock_batches where id = v_rec.batch_id;
        if v_src.warehouse_id = new.warehouse_id and v_src.item_id = new.item_id then
          update inv_stock_batches set qty_remaining = qty_remaining + v_take where id = v_src.id;
          insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
          values (new.company_id, new.id, v_src.id, v_take, v_rec.unit_cost);
        else
          perform inv_add_to_batch(new.id, new.company_id, new.warehouse_id, new.item_id, v_take, v_rec.unit_cost,
            v_src.batch_code, v_src.lot_number, v_src.expiry_date, v_src.received_at, coalesce(v_src.origin_batch_id, v_src.id),
            new.reference_type, new.reference_id, new.reference_number);
        end if;
        v_value := v_value + v_take * v_rec.unit_cost;
        v_left := v_left - v_take;
      end loop;
      v_cost := coalesce((select unit_cost from inv_stock_movements where id = new.source_movement_id), new.unit_cost);
    end if;

    -- MASUK biasa (penerimaan, produksi, penyesuaian +): batch baru
    if v_left > 0 then
      v_cost := coalesce(v_cost, new.unit_cost, inv_fallback_cost(new.warehouse_id, new.item_id));
      if new.batch_id is not null and exists (
          select 1 from inv_stock_batches where id = new.batch_id and warehouse_id = new.warehouse_id and item_id = new.item_id) then
        update inv_stock_batches set
          unit_cost     = case when qty_remaining + v_left > 0 then (qty_remaining * unit_cost + v_left * v_cost) / (qty_remaining + v_left) else v_cost end,
          qty_in        = qty_in + v_left,
          qty_remaining = qty_remaining + v_left
        where id = new.batch_id;
        insert into inv_stock_movement_batches (company_id, movement_id, batch_id, quantity, unit_cost)
        values (new.company_id, new.id, new.batch_id, v_left, v_cost);
      else
        perform inv_add_to_batch(new.id, new.company_id, new.warehouse_id, new.item_id, v_left, v_cost,
          coalesce(nullif(trim(new.batch_code), ''), inv_next_batch_code(new.company_id)),
          new.lot_number,
          coalesce(new.expiry_date, new.movement_at::date + v_item.shelf_life_days),
          new.movement_at, null, new.reference_type, new.reference_id, new.reference_number);
      end if;
      v_value := v_value + v_left * v_cost;
    end if;
    new.unit_cost := round(v_value / new.quantity, 4);

    -- stok sebelumnya minus: batch baru langsung menutup kekurangannya
    if v_stock.quantity < 0 then
      perform inv_consume_batches(new.id, new.warehouse_id, new.item_id, least(new.quantity, -v_stock.quantity), null, true);
    end if;
  end if;

  v_stock.quantity := v_stock.quantity + new.quantity;
  new.balance_after := v_stock.quantity;

  update inv_stocks set
    quantity     = v_stock.quantity,
    average_cost = coalesce(
      (select sum(qty_remaining * unit_cost) / nullif(sum(qty_remaining), 0) from inv_stock_batches
        where warehouse_id = new.warehouse_id and item_id = new.item_id and qty_remaining > 0),
      case when new.quantity > 0 then new.unit_cost else v_stock.average_cost end)
  where id = v_stock.id;

  return new;
end $$;

-- Saldo stok yang sudah ada -> batch saldo awal (harga = HPP rata-rata saat ini)
do $$
declare r record;
begin
  for r in select * from inv_stocks where quantity > 0 loop
    insert into inv_stock_batches (company_id, warehouse_id, item_id, batch_code, received_at, qty_in, qty_remaining,
                                   unit_cost, reference_type, reference_number)
    values (r.company_id, r.warehouse_id, r.item_id, inv_next_batch_code(r.company_id), now() - interval '1 second',
            r.quantity, r.quantity, r.average_cost, 'opening', 'Saldo awal');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- PENERIMAAN BARANG: lot & kedaluwarsa per baris
-- ---------------------------------------------------------------------
alter table pur_goods_receipt_items add column lot_number  text;
alter table pur_goods_receipt_items add column expiry_date date;

create or replace function pur_post_goods_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc     pur_goods_receipts%rowtype;
  v_missing text;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_goods_receipts
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id) then
    raise exception 'Penerimaan belum punya item';
  end if;

  select string_agg(it.name, ', ') into v_missing
  from pur_goods_receipt_items i join inv_items it on it.id = i.item_id
  where i.goods_receipt_id = p_id and it.track_batch and i.expiry_date is null and it.shelf_life_days is null;
  if v_missing is not null then
    raise exception 'Isi tanggal kedaluwarsa untuk produk yang dilacak batch: %', v_missing;
  end if;

  update pur_goods_receipt_items set line_total = quantity * unit_price where goods_receipt_id = p_id;

  v_doc.receipt_number := coalesce(v_doc.receipt_number,
    sys_next_document_number(v_doc.company_id, 'GR', v_doc.receipt_date));

  -- stok masuk (dikonversi ke base unit), 1 baris = 1 batch
  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
    reference_type, reference_id, reference_number, created_by, lot_number, expiry_date)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'purchase_receipt',
         i.quantity * i.conversion_qty, i.unit_price / i.conversion_qty,
         'pur_goods_receipts', v_doc.id, v_doc.receipt_number, auth.uid(), i.lot_number, i.expiry_date
  from pur_goods_receipt_items i where i.goods_receipt_id = p_id and i.quantity > 0
  order by i.created_at, i.id;

  -- harga beli terakhir per base unit
  update inv_items it set last_purchase_cost = i.unit_price / i.conversion_qty
  from pur_goods_receipt_items i
  where i.goods_receipt_id = p_id and it.id = i.item_id;

  update pur_purchase_order_items poi
     set received_qty = poi.received_qty + gri.total_qty
  from (select purchase_order_item_id, sum(quantity) total_qty
        from pur_goods_receipt_items
        where goods_receipt_id = p_id and purchase_order_item_id is not null
        group by purchase_order_item_id) gri
  where poi.id = gri.purchase_order_item_id;

  if v_doc.purchase_order_id is not null then
    update pur_purchase_orders po set status =
      case when exists (select 1 from pur_purchase_order_items
                        where purchase_order_id = po.id and received_qty < quantity)
           then 'partially_received' else 'received' end
    where id = v_doc.purchase_order_id;
  end if;

  update pur_goods_receipts set
    status = 'posted', posted_at = now(), receipt_number = v_doc.receipt_number,
    grand_total = (select coalesce(sum(line_total), 0) from pur_goods_receipt_items where goods_receipt_id = p_id)
  where id = p_id
  returning * into v_doc;

  return to_jsonb(v_doc);
end $$;

-- ---------------------------------------------------------------------
-- DOKUMEN PENYESUAIAN: baris boleh menunjuk batch (hasil scan label)
-- ---------------------------------------------------------------------
alter table inv_stock_adjustment_items add column batch_id uuid references inv_stock_batches(id);

create or replace function inv_post_stock_adjustment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc   inv_stock_adjustments%rowtype;
  v_value numeric(15,2);
  v_label text;
begin
  if not (sys_has_permission('inventory.manage') or sys_has_permission('approval.stock_adjustment')) then
    raise exception 'Tidak punya izin';
  end if;
  select * into v_doc from inv_stock_adjustments
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status not in ('draft', 'pending_approval') then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from inv_stock_adjustment_items where stock_adjustment_id = p_id and quantity <> 0) then
    raise exception 'Dokumen belum punya item';
  end if;
  if v_doc.adjustment_type <> 'adjustment' and exists (
      select 1 from inv_stock_adjustment_items where stock_adjustment_id = p_id and coalesce(purpose_id, v_doc.purpose_id) is null) then
    raise exception 'Pilih purpose / alasan untuk dokumen ini';
  end if;

  select coalesce(sum(abs(i.quantity) * coalesce(b.unit_cost, nullif(s.average_cost, 0), it.last_purchase_cost)), 0) into v_value
  from inv_stock_adjustment_items i
  join inv_items it on it.id = i.item_id
  left join inv_stocks s on s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id
  left join inv_stock_batches b on b.id = i.batch_id
  where i.stock_adjustment_id = p_id;

  v_label := case v_doc.adjustment_type when 'waste' then 'Waste' when 'usage' then 'Pemakaian'
                                        when 'shrinkage' then 'Penyusutan' else 'Penyesuaian stok' end;

  if sys_approval_required('stock_adjustment', v_value) then
    if v_doc.status = 'pending_approval' then raise exception 'Dokumen ini masih menunggu persetujuan'; end if;
    update inv_stock_adjustments set status = 'pending_approval' where id = p_id;
    perform sys_request_approval('stock_adjustment', p_id,
      (select outlet_id from inv_warehouses where id = v_doc.warehouse_id), v_value,
      v_label || ' ' || (select name from inv_warehouses where id = v_doc.warehouse_id), '{}');
    return;
  end if;

  v_doc.adjustment_number := coalesce(v_doc.adjustment_number, sys_next_document_number(v_doc.company_id,
    case v_doc.adjustment_type when 'waste' then 'WST' when 'usage' then 'USG' when 'shrinkage' then 'SHR' else 'ADJ' end,
    v_doc.adjustment_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, note, created_by, counter_account_id, batch_id)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, v_doc.adjustment_type,
         case when v_doc.adjustment_type = 'adjustment' then i.quantity else -abs(i.quantity) end,
         'inv_stock_adjustments', v_doc.id, v_doc.adjustment_number,
         coalesce(i.note, p.name), auth.uid(),
         coalesce(p.account_id,
           case v_doc.adjustment_type
             when 'waste'     then fin_account_id_or_null(v_doc.company_id, 'waste_expense')
             when 'usage'     then fin_account_id_or_null(v_doc.company_id, 'usage_expense')
             when 'shrinkage' then fin_account_id_or_null(v_doc.company_id, 'shrinkage_expense')
           end),
         i.batch_id
  from inv_stock_adjustment_items i
  left join inv_adjustment_purposes p on p.id = coalesce(i.purpose_id, v_doc.purpose_id)
  where i.stock_adjustment_id = p_id and i.quantity <> 0
  order by i.created_at, i.id;

  update inv_stock_adjustments
     set status = 'posted', posted_at = now(), adjustment_number = v_doc.adjustment_number
   where id = p_id;
  perform sys_close_approval('stock_adjustment', p_id);
end $$;

-- ---------------------------------------------------------------------
-- REFUND: stok kembali ke batch asalnya
-- ---------------------------------------------------------------------
create or replace function pos_refund_order_execute(p_order_id uuid, p_reason text, p_return_stock boolean, p_cashier_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o         pos_orders%rowtype;
  r         pos_refunds%rowtype;
  v_shift   uuid;
  v_date    date;
  v_cust    crm_customers%rowtype;
  v_deduct  int;
  v_balance int;
  v_journal uuid;
  v_lines   jsonb;
begin
  select * into o from pos_orders where id = p_order_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if o.status <> 'paid' then raise exception 'Hanya order lunas yang bisa direfund'; end if;

  select id into v_shift from pos_shifts where outlet_id = o.outlet_id and user_id = p_cashier_id and status = 'open' limit 1;
  if v_shift is null and exists (
      select 1 from pos_payments p join mst_payment_methods m on m.id = p.payment_method_id
      where p.order_id = o.id and m.type = 'cash') then
    raise exception 'Kasir harus membuka shift dulu (uang tunai dikembalikan dari laci)';
  end if;
  v_date := sys_outlet_business_date(o.outlet_id);

  insert into pos_refunds (company_id, outlet_id, order_id, shift_id, refund_number, business_date, amount,
                           reason, is_stock_returned, refunded_by)
  values (o.company_id, o.outlet_id, o.id, v_shift, sys_next_document_number(o.company_id, 'RFD', v_date), v_date,
          o.grand_total, trim(p_reason), coalesce(p_return_stock, false), p_cashier_id)
  returning * into r;

  insert into pos_refund_payments (company_id, refund_id, payment_method_id, amount)
  select o.company_id, r.id, payment_method_id, amount - change_amount
  from pos_payments where order_id = o.id;

  update pos_orders set status = 'refunded', refunded_at = now() where id = o.id;

  if p_return_stock then
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, note, created_by, source_movement_id)
    select company_id, warehouse_id, item_id, 'sales_return', -quantity, unit_cost,
           'pos_refunds', r.id, r.refund_number, 'Refund ' || o.order_number, auth.uid(), id
    from inv_stock_movements where reference_type = 'pos_orders' and reference_id = o.id;
  end if;

  if o.customer_id is not null then
    select * into v_cust from crm_customers where id = o.customer_id for update;
    v_deduct := least(o.points_earned, v_cust.points_balance + o.points_redeemed);
    v_balance := v_cust.points_balance + o.points_redeemed - v_deduct;
    if o.points_redeemed - v_deduct <> 0 then
      insert into crm_point_transactions (company_id, customer_id, order_id, transaction_type, points, balance_after, note, created_by)
      values (o.company_id, o.customer_id, o.id, 'refund', o.points_redeemed - v_deduct, v_balance,
              'Refund ' || o.order_number, auth.uid());
    end if;
    update crm_customers set
      points_balance = v_balance,
      total_spent    = greatest(total_spent - o.grand_total, 0),
      visit_count    = greatest(visit_count - 1, 0)
    where id = o.customer_id;
  end if;

  if o.promotion_id is not null then
    update crm_promotions set usage_count = greatest(usage_count - 1, 0) where id = o.promotion_id;
  end if;

  select id into v_journal from fin_journals where source_type = 'sales' and source_id = o.id;
  if v_journal is not null then
    select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'debit', l.credit, 'credit', l.debit, 'note', l.note))
      into v_lines
    from fin_journal_lines l join fin_accounts a on a.id = l.account_id
    where l.journal_id = v_journal
      and (p_return_stock or coalesce(a.system_key, '') not in ('cogs', 'inventory'));
    perform fin_create_journal(o.company_id, o.outlet_id, v_date, 'sales_refund', o.id,
                               'Refund ' || o.order_number || ' - ' || trim(p_reason), v_lines);
  end if;

  return to_jsonb(r);
end $$;

-- ---------------------------------------------------------------------
-- TRANSFER PER KOLI: draft -> dikirim (dalam perjalanan) -> diterima per koli
-- ---------------------------------------------------------------------
alter table inv_stock_transfers add column shipped_at  timestamptz;
alter table inv_stock_transfers add column shipped_by  uuid references sys_users(id);
alter table inv_stock_transfers add column received_at timestamptz;

create table inv_transfer_packages (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references sys_companies(id),
  stock_transfer_id  uuid not null references inv_stock_transfers(id) on delete cascade,
  package_no         int not null check (package_no > 0),
  package_code       text,                 -- label koli (barcode), dibuat saat dikirim
  status             text not null default 'open' check (status in ('open', 'shipped', 'received')),
  note               text,
  received_at        timestamptz,
  received_by        uuid references sys_users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (stock_transfer_id, package_no)
);
create unique index uq_inv_transfer_packages_code on inv_transfer_packages(company_id, package_code) where package_code is not null;

alter table inv_stock_transfer_items add column package_id          uuid references inv_transfer_packages(id) on delete set null;
alter table inv_stock_transfer_items add column batch_id            uuid references inv_stock_batches(id);
alter table inv_stock_transfer_items add column shipped_movement_id uuid references inv_stock_movements(id);
alter table inv_stock_transfer_items add column received_qty        numeric(15,4);

create or replace function inv_ship_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc  inv_stock_transfers%rowtype;
  v_pkg  record;
  v_line record;
  v_mid  uuid;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_transfers
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Transfer tidak ditemukan / sudah dikirim'; end if;
  if not exists (select 1 from inv_stock_transfer_items where stock_transfer_id = p_id) then
    raise exception 'Transfer belum punya item';
  end if;

  -- tanpa koli: semua barang = koli 1
  if not exists (select 1 from inv_transfer_packages where stock_transfer_id = p_id) then
    insert into inv_transfer_packages (company_id, stock_transfer_id, package_no) values (v_doc.company_id, p_id, 1);
    update inv_stock_transfer_items set package_id = (select id from inv_transfer_packages where stock_transfer_id = p_id)
    where stock_transfer_id = p_id;
  end if;
  if exists (select 1 from inv_stock_transfer_items where stock_transfer_id = p_id and package_id is null) then
    raise exception 'Masih ada barang yang belum dimasukkan ke koli';
  end if;
  delete from inv_transfer_packages p where p.stock_transfer_id = p_id
    and not exists (select 1 from inv_stock_transfer_items i where i.package_id = p.id);

  v_doc.transfer_number := coalesce(v_doc.transfer_number,
    sys_next_document_number(v_doc.company_id, 'TRF', v_doc.transfer_date));

  for v_pkg in select id from inv_transfer_packages where stock_transfer_id = p_id order by package_no loop
    update inv_transfer_packages set status = 'shipped',
      package_code = coalesce(package_code, 'K' || to_char(v_doc.transfer_date, 'YYMMDD')
        || lpad(sys_next_sequence(v_doc.company_id, 'KOLI/' || to_char(v_doc.transfer_date, 'YYYYMMDD'))::text, 4, '0'))
    where id = v_pkg.id;
  end loop;

  for v_line in
    select i.*, p.package_code from inv_stock_transfer_items i join inv_transfer_packages p on p.id = i.package_id
    where i.stock_transfer_id = p_id order by p.package_no, i.created_at, i.id
  loop
    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, batch_id,
      reference_type, reference_id, reference_number, note, created_by)
    values (v_doc.company_id, v_doc.from_warehouse_id, v_line.item_id, 'transfer_out', -v_line.quantity, v_line.batch_id,
      'inv_stock_transfers', v_doc.id, v_doc.transfer_number, 'Koli ' || v_line.package_code, auth.uid())
    returning id into v_mid;
    update inv_stock_transfer_items set shipped_movement_id = v_mid where id = v_line.id;
  end loop;

  update inv_stock_transfers set status = 'in_transit', transfer_number = v_doc.transfer_number,
    shipped_at = now(), shipped_by = auth.uid()
  where id = p_id;
end $$;

-- Terima satu koli. p_lines = [{id: <transfer item id>, received_qty}] (kosong = diterima lengkap).
-- Kekurangan kiriman dijurnal ke purpose "Hilang / Rusak di Perjalanan".
create or replace function inv_receive_transfer_package(p_package_id uuid, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pkg   inv_transfer_packages%rowtype;
  v_doc   inv_stock_transfers%rowtype;
  v_line  record;
  v_rq    numeric;
  v_in    numeric;
  v_loss  numeric;
  v_total numeric := 0;
  v_acc   uuid;
  v_lines jsonb := '[]';
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_pkg from inv_transfer_packages
  where id = p_package_id and company_id = sys_current_company_id() for update;
  if not found then raise exception 'Koli tidak ditemukan'; end if;
  if v_pkg.status <> 'shipped' then
    raise exception 'Koli % %', coalesce(v_pkg.package_code, ''), case v_pkg.status when 'received' then 'sudah diterima' else 'belum dikirim' end;
  end if;
  select * into v_doc from inv_stock_transfers where id = v_pkg.stock_transfer_id for update;

  select coalesce(p.account_id, fin_account_id_or_null(v_doc.company_id, 'waste_expense')) into v_acc
  from (select 1) x left join inv_adjustment_purposes p
    on p.company_id = v_doc.company_id and p.adjustment_type = 'waste' and p.name = 'Hilang / Rusak di Perjalanan';

  for v_line in
    select i.*, m.unit_cost as out_cost from inv_stock_transfer_items i
    join inv_stock_movements m on m.id = i.shipped_movement_id
    where i.package_id = p_package_id order by i.created_at, i.id
  loop
    v_rq := coalesce((select (x->>'received_qty')::numeric from jsonb_array_elements(coalesce(p_lines, '[]')) x
                      where x->>'id' = v_line.id::text), v_line.quantity);
    if v_rq < 0 or v_rq > v_line.quantity then
      raise exception 'Qty diterima tidak valid (maksimal %)', v_line.quantity;
    end if;

    v_in := 0;
    if v_rq > 0 then
      insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, source_movement_id,
        reference_type, reference_id, reference_number, note, created_by)
      values (v_doc.company_id, v_doc.to_warehouse_id, v_line.item_id, 'transfer_in', v_rq, v_line.shipped_movement_id,
        'inv_stock_transfers', v_doc.id, v_doc.transfer_number, 'Koli ' || v_pkg.package_code, auth.uid())
      returning round(quantity * unit_cost, 2) into v_in;
    end if;
    update inv_stock_transfer_items set received_qty = v_rq where id = v_line.id;

    v_loss := round(v_line.quantity * v_line.out_cost, 2) - v_in;
    if v_rq < v_line.quantity and v_loss <> 0 then
      v_total := v_total + v_loss;
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('account_id', fin_item_account(v_line.item_id, 'inventory'), 'credit', v_loss),
        jsonb_build_object('account_id', v_acc, 'debit', v_loss,
          'note', 'Kurang ' || (v_line.quantity - v_rq)::text || ' ' || (select name from inv_items where id = v_line.item_id)));
    end if;
  end loop;

  if v_total <> 0 and v_acc is not null and exists (select 1 from fin_accounts where company_id = v_doc.company_id) then
    perform fin_create_journal(v_doc.company_id, (select outlet_id from inv_warehouses where id = v_doc.to_warehouse_id),
      current_date, 'transfer_loss', v_pkg.id, 'Selisih kiriman ' || v_doc.transfer_number || ' koli ' || v_pkg.package_code, v_lines);
  end if;

  update inv_transfer_packages set status = 'received', received_at = now(), received_by = auth.uid() where id = p_package_id;

  if not exists (select 1 from inv_transfer_packages where stock_transfer_id = v_doc.id and status <> 'received') then
    update inv_stock_transfers set status = 'posted', posted_at = now(), received_at = now() where id = v_doc.id;
  end if;

  return jsonb_build_object('package_code', v_pkg.package_code, 'loss_value', v_total,
    'transfer_status', (select status from inv_stock_transfers where id = v_doc.id));
end $$;

-- Transfer langsung (tanpa perjalanan): kirim lalu terima semua koli
create or replace function inv_post_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_pkg uuid;
begin
  perform inv_ship_stock_transfer(p_id);
  for v_pkg in select id from inv_transfer_packages where stock_transfer_id = p_id order by package_no loop
    perform inv_receive_transfer_package(v_pkg, null);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- BARCODE: kode koli / label batch / barcode produk / kode produk
-- ---------------------------------------------------------------------
create or replace function inv_resolve_barcode(p_code text, p_warehouse_id uuid default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v      jsonb;
begin
  if v_code = '' then return null; end if;

  select jsonb_build_object('kind', 'package', 'package_id', p.id, 'package_code', p.package_code, 'package_no', p.package_no,
           'status', p.status, 'stock_transfer_id', p.stock_transfer_id, 'transfer_number', t.transfer_number,
           'to_warehouse_id', t.to_warehouse_id)
    into v
  from inv_transfer_packages p join inv_stock_transfers t on t.id = p.stock_transfer_id
  where upper(p.package_code) = v_code;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'batch', 'batch_id', b.id, 'batch_code', b.batch_code, 'item_id', b.item_id,
           'item_code', it.code, 'item_name', it.name, 'unit_code', u.code, 'qty', 1,
           'warehouse_id', b.warehouse_id, 'qty_remaining', b.qty_remaining, 'expiry_date', b.expiry_date, 'lot_number', b.lot_number)
    into v
  from inv_stock_batches b join inv_items it on it.id = b.item_id join inv_units u on u.id = it.base_unit_id
  where upper(b.batch_code) = v_code
  order by (b.warehouse_id = p_warehouse_id) desc nulls last, b.qty_remaining desc
  limit 1;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'item', 'item_id', it.id, 'item_code', it.code, 'item_name', it.name,
           'unit_code', bu.code, 'qty', iu.conversion_qty, 'scanned_unit', su.code)
    into v
  from inv_item_units iu join inv_items it on it.id = iu.item_id
  join inv_units bu on bu.id = it.base_unit_id join inv_units su on su.id = iu.unit_id
  where upper(iu.barcode) = v_code limit 1;
  if v is not null then return v; end if;

  select jsonb_build_object('kind', 'item', 'item_id', it.id, 'item_code', it.code, 'item_name', it.name,
           'unit_code', u.code, 'qty', 1, 'scanned_unit', u.code)
    into v
  from inv_items it join inv_units u on u.id = it.base_unit_id
  where upper(it.code) = v_code limit 1;
  return v;
end $$;

-- Koreksi lot / kedaluwarsa batch (berlaku untuk kode batch yang sama di semua gudang)
create or replace function inv_update_batch(p_batch_id uuid, p_lot_number text, p_expiry_date date)
returns void language plpgsql security definer set search_path = public as $$
declare b inv_stock_batches%rowtype;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into b from inv_stock_batches where id = p_batch_id and company_id = sys_current_company_id();
  if not found then raise exception 'Batch tidak ditemukan'; end if;
  update inv_stock_batches set lot_number = nullif(trim(p_lot_number), ''), expiry_date = p_expiry_date
  where company_id = b.company_id and item_id = b.item_id and batch_code = b.batch_code;
end $$;

-- ---------------------------------------------------------------------
-- VIEW
-- ---------------------------------------------------------------------
create view rpt_stock_batches with (security_invoker = true) as
select b.id, b.company_id, b.warehouse_id, w.name as warehouse_name, b.item_id, it.code as item_code, it.name as item_name,
       u.code as unit_code, it.track_batch, b.batch_code, b.lot_number, b.expiry_date, b.received_at,
       b.qty_in, b.qty_remaining, b.unit_cost, (b.qty_remaining * b.unit_cost)::numeric(15,2) as stock_value,
       (b.expiry_date - current_date) as days_to_expiry, b.reference_type, b.reference_number
from inv_stock_batches b
join inv_warehouses w on w.id = b.warehouse_id
join inv_items it     on it.id = b.item_id
join inv_units u      on u.id = it.base_unit_id;

create view rpt_batch_movements with (security_invoker = true) as
select a.id, a.company_id, a.seq, b.batch_code, b.id as batch_id, b.item_id, m.warehouse_id, w.name as warehouse_name,
       m.movement_type, m.movement_at, m.reference_number, m.note, a.quantity, a.unit_cost, a.is_backfill
from inv_stock_movement_batches a
join inv_stock_batches b    on b.id = a.batch_id
join inv_stock_movements m  on m.id = a.movement_id
join inv_warehouses w       on w.id = m.warehouse_id;

-- ---------------------------------------------------------------------
-- PURPOSE kehilangan di perjalanan
-- ---------------------------------------------------------------------
create or replace function inv_setup_transfer_purposes(p_company_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into inv_adjustment_purposes (company_id, adjustment_type, name, account_id, sort_order)
  select p_company_id, 'waste', 'Hilang / Rusak di Perjalanan', fin_account_id_or_null(p_company_id, 'waste_expense'), 5
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------
-- TRIGGER, RLS, DATA AWAL
-- ---------------------------------------------------------------------
select sys_attach_updated_at_triggers();
select sys_apply_company_policies('inv_stock_batches');                    -- baca saja; diubah lewat kartu stok
select sys_apply_company_policies('inv_stock_movement_batches');
select sys_apply_company_policies('inv_transfer_packages', 'inventory.manage');

do $$
declare r record;
begin
  for r in select id from sys_companies loop perform inv_setup_transfer_purposes(r.id); end loop;
end $$;

alter function sys_onboard_company(text, text, text, boolean) rename to sys_onboard_company_v4;
revoke execute on function sys_onboard_company_v4(text, text, text, boolean) from public, anon, authenticated;

create or replace function sys_onboard_company(
  p_company_name text, p_outlet_name text, p_full_name text, p_with_demo_data boolean default true
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  v_result := sys_onboard_company_v4(p_company_name, p_outlet_name, p_full_name, p_with_demo_data);
  perform inv_setup_transfer_purposes((v_result->>'company_id')::uuid);
  return v_result;
end $$;

revoke execute on function inv_next_batch_code(uuid, date)                                      from public, anon, authenticated;
revoke execute on function inv_fallback_cost(uuid, uuid)                                        from public, anon, authenticated;
revoke execute on function inv_consume_batches(uuid, uuid, uuid, numeric, uuid, boolean)        from public, anon, authenticated;
revoke execute on function inv_add_to_batch(uuid, uuid, uuid, uuid, numeric, numeric, text, text, date, timestamptz, uuid, text, uuid, text)
                                                                                                from public, anon, authenticated;
revoke execute on function inv_setup_transfer_purposes(uuid)                                    from public, anon, authenticated;
