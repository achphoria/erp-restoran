-- =====================================================================
-- ERP RESTORAN - 004: FUNGSI INVENTORY, PURCHASING & VIEW LAPORAN
-- =====================================================================

-- =====================================================================
-- POTONG STOK OTOMATIS SAAT ORDER DIBAYAR (berdasarkan resep)
-- =====================================================================
create or replace function inv_post_order_consumption(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order        pos_orders%rowtype;
  v_warehouse_id uuid;
begin
  select * into v_order from pos_orders where id = p_order_id;
  select default_warehouse_id into v_warehouse_id from sys_outlets where id = v_order.outlet_id;
  if v_warehouse_id is null then return; end if;

  insert into inv_stock_movements (
    company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by
  )
  select v_order.company_id, v_warehouse_id, ri.item_id, 'sales',
         -sum(oi.quantity * ri.quantity / r.yield_qty),
         'pos_orders', v_order.id, v_order.order_number, auth.uid()
  from pos_order_items oi
  join inv_recipes r       on r.menu_item_id = oi.menu_item_id
  join inv_recipe_items ri on ri.recipe_id = r.id
  where oi.order_id = p_order_id and not oi.is_void
  group by ri.item_id;
end $$;

create or replace function pos_on_order_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform inv_post_order_consumption(new.id);
  return new;
end $$;

create trigger trg_pos_orders_paid
  after update of status on pos_orders
  for each row
  when (new.status = 'paid' and old.status is distinct from 'paid')
  execute function pos_on_order_paid();

-- =====================================================================
-- POSTING DOKUMEN STOK
-- =====================================================================
create or replace function inv_post_stock_adjustment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_doc inv_stock_adjustments%rowtype;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_adjustments
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  v_doc.adjustment_number := coalesce(v_doc.adjustment_number,
    sys_next_document_number(v_doc.company_id, case when v_doc.adjustment_type = 'waste' then 'WST' else 'ADJ' end, v_doc.adjustment_date));

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, note, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, v_doc.adjustment_type,
         case when v_doc.adjustment_type = 'waste' then -abs(i.quantity) else i.quantity end,
         'inv_stock_adjustments', v_doc.id, v_doc.adjustment_number, i.note, auth.uid()
  from inv_stock_adjustment_items i
  where i.stock_adjustment_id = p_id and i.quantity <> 0;

  update inv_stock_adjustments
     set status = 'posted', posted_at = now(), adjustment_number = v_doc.adjustment_number
   where id = p_id;
end $$;

create or replace function inv_post_stock_opname(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_doc inv_stock_opnames%rowtype;
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_opnames
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  v_doc.opname_number := coalesce(v_doc.opname_number,
    sys_next_document_number(v_doc.company_id, 'OPN', v_doc.opname_date));

  update inv_stock_opname_items i set
    system_qty = coalesce((select s.quantity from inv_stocks s
                           where s.warehouse_id = v_doc.warehouse_id and s.item_id = i.item_id), 0)
  where i.stock_opname_id = p_id;

  update inv_stock_opname_items set difference_qty = counted_qty - system_qty
  where stock_opname_id = p_id;

  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity,
    reference_type, reference_id, reference_number, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'opname', i.difference_qty,
         'inv_stock_opnames', v_doc.id, v_doc.opname_number, auth.uid()
  from inv_stock_opname_items i
  where i.stock_opname_id = p_id and i.difference_qty <> 0;

  update inv_stock_opnames
     set status = 'posted', posted_at = now(), opname_number = v_doc.opname_number
   where id = p_id;
end $$;

create or replace function inv_post_stock_transfer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_doc  inv_stock_transfers%rowtype;
  v_line record;
  v_cost numeric(15,4);
begin
  if not sys_has_permission('inventory.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from inv_stock_transfers
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;

  v_doc.transfer_number := coalesce(v_doc.transfer_number,
    sys_next_document_number(v_doc.company_id, 'TRF', v_doc.transfer_date));

  for v_line in select * from inv_stock_transfer_items where stock_transfer_id = p_id loop
    select average_cost into v_cost from inv_stocks
    where warehouse_id = v_doc.from_warehouse_id and item_id = v_line.item_id;

    insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, reference_number, created_by)
    values
      (v_doc.company_id, v_doc.from_warehouse_id, v_line.item_id, 'transfer_out', -v_line.quantity, v_cost,
       'inv_stock_transfers', v_doc.id, v_doc.transfer_number, auth.uid()),
      (v_doc.company_id, v_doc.to_warehouse_id, v_line.item_id, 'transfer_in', v_line.quantity, coalesce(v_cost, 0),
       'inv_stock_transfers', v_doc.id, v_doc.transfer_number, auth.uid());
  end loop;

  update inv_stock_transfers
     set status = 'posted', posted_at = now(), transfer_number = v_doc.transfer_number
   where id = p_id;
end $$;

-- =====================================================================
-- PURCHASING
-- =====================================================================
create or replace function pur_approve_purchase_order(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_doc pur_purchase_orders%rowtype;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_purchase_orders
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'PO tidak ditemukan / bukan draft'; end if;
  if not exists (select 1 from pur_purchase_order_items where purchase_order_id = p_id) then
    raise exception 'PO belum punya item';
  end if;

  update pur_purchase_order_items set line_total = quantity * unit_price where purchase_order_id = p_id;

  update pur_purchase_orders set
    po_number   = coalesce(po_number, sys_next_document_number(company_id, 'PO', po_date)),
    subtotal    = (select coalesce(sum(line_total), 0) from pur_purchase_order_items where purchase_order_id = p_id),
    grand_total = (select coalesce(sum(line_total), 0) from pur_purchase_order_items where purchase_order_id = p_id) + tax_amount,
    status      = 'approved',
    approved_by = auth.uid(),
    approved_at = now()
  where id = p_id
  returning * into v_doc;

  return to_jsonb(v_doc);
end $$;

-- Buat draft penerimaan barang dari sisa PO yang belum diterima
create or replace function pur_create_goods_receipt_from_po(p_po_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_po    pur_purchase_orders%rowtype;
  v_gr_id uuid;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_po from pur_purchase_orders
  where id = p_po_id and company_id = sys_current_company_id();
  if not found or v_po.status not in ('approved', 'partially_received') then
    raise exception 'PO harus berstatus approved';
  end if;

  insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, created_by)
  values (v_po.company_id, v_po.id, v_po.supplier_id, v_po.warehouse_id, auth.uid())
  returning id into v_gr_id;

  insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id,
    item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
  select company_id, v_gr_id, id, item_id, unit_id, conversion_qty,
         quantity - received_qty, unit_price, (quantity - received_qty) * unit_price
  from pur_purchase_order_items
  where purchase_order_id = p_po_id and quantity > received_qty;

  return v_gr_id;
end $$;

create or replace function pur_post_goods_receipt(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_doc pur_goods_receipts%rowtype;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin'; end if;
  select * into v_doc from pur_goods_receipts
  where id = p_id and company_id = sys_current_company_id() for update;
  if not found or v_doc.status <> 'draft' then raise exception 'Dokumen tidak ditemukan / sudah diposting'; end if;
  if not exists (select 1 from pur_goods_receipt_items where goods_receipt_id = p_id) then
    raise exception 'Penerimaan belum punya item';
  end if;

  update pur_goods_receipt_items set line_total = quantity * unit_price where goods_receipt_id = p_id;

  v_doc.receipt_number := coalesce(v_doc.receipt_number,
    sys_next_document_number(v_doc.company_id, 'GR', v_doc.receipt_date));

  -- stok masuk (dikonversi ke base unit)
  insert into inv_stock_movements (company_id, warehouse_id, item_id, movement_type, quantity, unit_cost,
    reference_type, reference_id, reference_number, created_by)
  select v_doc.company_id, v_doc.warehouse_id, i.item_id, 'purchase_receipt',
         i.quantity * i.conversion_qty, i.unit_price / i.conversion_qty,
         'pur_goods_receipts', v_doc.id, v_doc.receipt_number, auth.uid()
  from pur_goods_receipt_items i where i.goods_receipt_id = p_id;

  -- harga beli terakhir per base unit
  update inv_items it set last_purchase_cost = i.unit_price / i.conversion_qty
  from pur_goods_receipt_items i
  where i.goods_receipt_id = p_id and it.id = i.item_id;

  -- update qty diterima di PO
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

-- =====================================================================
-- VIEW LAPORAN (rpt_)  -- security_invoker: tetap tunduk pada RLS
-- =====================================================================
create view rpt_daily_sales with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date,
       count(*)               as order_count,
       sum(o.guest_count)     as guest_count,
       sum(o.subtotal)        as subtotal,
       sum(o.discount_amount) as discount_amount,
       sum(o.service_amount)  as service_amount,
       sum(o.tax_amount)      as tax_amount,
       sum(o.grand_total)     as grand_total
from pos_orders o
where o.status = 'paid'
group by o.company_id, o.outlet_id, o.business_date;

create view rpt_menu_sales with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date,
       oi.menu_item_id, oi.menu_item_name,
       sum(oi.quantity)   as quantity,
       sum(oi.line_total) as revenue
from pos_order_items oi
join pos_orders o on o.id = oi.order_id
where o.status = 'paid' and not oi.is_void
group by o.company_id, o.outlet_id, o.business_date, oi.menu_item_id, oi.menu_item_name;

create view rpt_payment_summary with (security_invoker = true) as
select o.company_id, o.outlet_id, o.business_date,
       m.id as payment_method_id, m.name as payment_method_name,
       count(*) as transaction_count,
       sum(p.amount - p.change_amount) as amount
from pos_payments p
join pos_orders o on o.id = p.order_id
join mst_payment_methods m on m.id = p.payment_method_id
where o.status = 'paid'
group by o.company_id, o.outlet_id, o.business_date, m.id, m.name;

-- HPP standar per menu (pakai harga beli terakhir)
create view rpt_menu_food_costs with (security_invoker = true) as
select mi.company_id, mi.id as menu_item_id, mi.code, mi.name, mi.base_price,
       coalesce(sum(ri.quantity / r.yield_qty * it.last_purchase_cost), 0)::numeric(15,2) as food_cost,
       case when mi.base_price > 0
            then round(coalesce(sum(ri.quantity / r.yield_qty * it.last_purchase_cost), 0) / mi.base_price * 100, 1)
       end as food_cost_pct,
       count(ri.id) > 0 as has_recipe
from mst_menu_items mi
left join inv_recipes r       on r.menu_item_id = mi.id
left join inv_recipe_items ri on ri.recipe_id = r.id
left join inv_items it        on it.id = ri.item_id
where mi.is_active
group by mi.company_id, mi.id, mi.code, mi.name, mi.base_price;

create view rpt_stock_balances with (security_invoker = true) as
select s.company_id, s.warehouse_id, w.name as warehouse_name,
       s.item_id, it.code as item_code, it.name as item_name,
       u.code as unit_code, s.quantity, s.average_cost,
       (s.quantity * s.average_cost)::numeric(15,2) as stock_value,
       it.min_stock, s.quantity <= it.min_stock as is_low_stock
from inv_stocks s
join inv_warehouses w on w.id = s.warehouse_id
join inv_items it     on it.id = s.item_id
join inv_units u      on u.id = it.base_unit_id;

-- =====================================================================
-- KUNCI FUNGSI INTERNAL (tidak boleh dipanggil langsung dari aplikasi)
-- =====================================================================
revoke execute on function sys_next_sequence(uuid, text)                 from public, anon, authenticated;
revoke execute on function sys_next_document_number(uuid, text, date)   from public, anon, authenticated;
revoke execute on function pos_recalculate_order(uuid)                  from public, anon, authenticated;
revoke execute on function inv_post_order_consumption(uuid)             from public, anon, authenticated;
revoke execute on function sys_apply_company_policies(text, text)       from public, anon, authenticated;
revoke execute on function sys_attach_updated_at_triggers()             from public, anon, authenticated;
