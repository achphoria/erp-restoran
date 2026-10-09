-- =====================================================================
-- SEMAR - 042: TRANSAKSI ANTAR-PT DALAM GRUP (Platform tahap 3)
--   PT pembeli (A)                              PT penjual (B)
--   PO ke supplier "PT B" (otomatis ada) --->   Sales Order baru untuk pelanggan "PT A" (status Baru)
--                                               B konfirmasi / tolak (ditolak -> PO A batal)
--                                               Pengiriman B dikirim
--   Draft Penerimaan Barang otomatis   <---     (qty sesuai kiriman)
--   A terima & posting -> stok + hutang         Invoice B -> piutang & pendapatan
--   A bayar hutang ke supplier "PT B"           B catat penerimaan pembayaran
--   * Supplier & pelanggan antar-PT dibuat otomatis untuk setiap pasangan PT dalam grup.
--   * Barang dicocokkan lewat KODE barang & satuan yang sama di kedua PT.
--   * Semua jurnal dari dokumen antar-PT ditandai counterparty_company_id -> dieliminasi di laporan
--     konsolidasi grup (penjualan, HPP, piutang, hutang antar-PT tidak dihitung dua kali).
-- =====================================================================

-- ---------------------------------------------------------------------
-- MITRA ANTAR-PT
-- ---------------------------------------------------------------------
alter table pur_suppliers add column if not exists linked_company_id uuid references sys_companies(id);
alter table pur_suppliers drop constraint if exists pur_suppliers_type_check;
alter table pur_suppliers add constraint pur_suppliers_type_check check (supplier_type in ('external', 'internal', 'intercompany'));
alter table pur_suppliers drop constraint if exists pur_suppliers_internal_check;
alter table pur_suppliers add constraint pur_suppliers_internal_check check (
  (supplier_type <> 'internal' or linked_outlet_id is not null) and (supplier_type <> 'intercompany' or linked_company_id is not null));
alter table sal_customers add column if not exists linked_company_id uuid references sys_companies(id);
create unique index if not exists uq_pur_suppliers_ic on pur_suppliers (company_id, linked_company_id) where linked_company_id is not null;
create unique index if not exists uq_sal_customers_ic on sal_customers (company_id, linked_company_id) where linked_company_id is not null;

-- tautan lintas PT satu arah & "on delete set null": reset data satu PT tidak terhalang data PT lain
alter table sal_sales_orders add column if not exists ic_purchase_order_id uuid references pur_purchase_orders(id) on delete set null;
create unique index if not exists uq_sal_sales_orders_ic_po on sal_sales_orders (ic_purchase_order_id) where ic_purchase_order_id is not null;
alter table sal_sales_order_items add column if not exists ic_po_item_id uuid references pur_purchase_order_items(id) on delete set null;
alter table pur_goods_receipts add column if not exists ic_delivery_id uuid references sal_deliveries(id) on delete set null;

-- buat / aktifkan supplier & pelanggan antar-PT untuk semua pasangan PT dalam grup;
-- mitra ke PT yang sudah keluar dari grup dinonaktifkan
create or replace function grp_sync_partners(p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s record; b record;
begin
  if p_group_id is not null then
    for s in select * from sys_companies where group_id = p_group_id and is_active loop
      for b in select * from sys_companies where group_id = p_group_id and is_active and id <> s.id loop
        -- di penjual (s): pelanggan = PT b
        insert into sal_customers (company_id, code, name, address, tax_number, payment_term_days, notes, linked_company_id)
        values (s.id, left('IC-' || b.code, 30), b.name, b.address, b.tax_number, 30, 'Pelanggan antar-PT (otomatis)', b.id)
        on conflict (company_id, linked_company_id) where linked_company_id is not null do update set is_active = true, name = excluded.name;
        -- di pembeli (b): supplier = PT s
        insert into pur_suppliers (company_id, code, name, address, payment_term_days, supplier_type, linked_company_id)
        values (b.id, left('IC-' || s.code, 30), s.name, s.address, 30, 'intercompany', s.id)
        on conflict (company_id, linked_company_id) where linked_company_id is not null do update set is_active = true, name = excluded.name;
      end loop;
    end loop;
  end if;
  update sal_customers c set is_active = false
  where c.linked_company_id is not null and c.is_active and not exists (
    select 1 from sys_companies me join sys_companies other on other.id = c.linked_company_id
    where me.id = c.company_id and me.group_id is not null and me.group_id = other.group_id and other.is_active);
  update pur_suppliers p set is_active = false
  where p.linked_company_id is not null and p.is_active and not exists (
    select 1 from sys_companies me join sys_companies other on other.id = p.linked_company_id
    where me.id = p.company_id and me.group_id is not null and me.group_id = other.group_id and other.is_active);
end $$;
revoke execute on function grp_sync_partners(uuid) from public, anon, authenticated;

create or replace function grp_on_company_group_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform grp_sync_partners(new.group_id);
  if old.group_id is distinct from new.group_id then perform grp_sync_partners(old.group_id); end if;
  return new;
end $$;
create trigger trg_sys_companies_ic_partners after update of group_id, is_active on sys_companies
  for each row execute function grp_on_company_group_change();

do $$
declare g record;
begin
  for g in select distinct group_id from sys_companies where group_id is not null loop perform grp_sync_partners(g.group_id); end loop;
end $$;

-- ---------------------------------------------------------------------
-- PENCOCOKAN BARANG ANTAR-PT (kode barang & kode satuan sama)
-- ---------------------------------------------------------------------
create or replace function grp_map_item(p_item_id uuid, p_target_company uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select t.id from inv_items s join inv_items t on t.company_id = p_target_company and lower(t.code) = lower(s.code) and t.is_active
  where s.id = p_item_id limit 1
$$;
create or replace function grp_map_unit(p_unit_id uuid, p_target_company uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select t.id from inv_units s join inv_units t on t.company_id = p_target_company and lower(t.code) = lower(s.code)
  where s.id = p_unit_id limit 1
$$;
-- outlet penjual untuk SO antar-PT: outlet aktif pertama yang punya gudang
create or replace function grp_seller_outlet(p_company_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from sys_outlets where company_id = p_company_id and is_active and default_warehouse_id is not null order by code limit 1
$$;

-- harga PO ke PT lain: dari Pricelist Jual PT penjual (bila ada), barang & satuan harus ada di PT penjual
create or replace function pur_set_ic_po_price()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_po pur_purchase_orders; v_sup pur_suppliers; v_item uuid; v_unit uuid; v_price numeric; v_cust uuid;
begin
  select * into v_po from pur_purchase_orders where id = new.purchase_order_id;
  if v_po.status not in ('draft', 'pending_approval') then return new; end if;
  select * into v_sup from pur_suppliers where id = v_po.supplier_id;
  if v_sup.supplier_type <> 'intercompany' then return new; end if;
  v_item := grp_map_item(new.item_id, v_sup.linked_company_id);
  if v_item is null then
    raise exception 'Barang "%" (kode %) belum ada di %. Samakan kode barang di kedua PT.',
      (select name from inv_items where id = new.item_id), (select code from inv_items where id = new.item_id), v_sup.name;
  end if;
  v_unit := grp_map_unit(new.unit_id, v_sup.linked_company_id);
  if v_unit is null then raise exception 'Satuan "%" belum ada di %', (select code from inv_units where id = new.unit_id), v_sup.name; end if;
  select id into v_cust from sal_customers where company_id = v_sup.linked_company_id and linked_company_id = v_po.company_id;
  v_price := sal_get_price(v_sup.linked_company_id, grp_seller_outlet(v_sup.linked_company_id), null, v_cust, v_item, v_unit, v_po.po_date);
  if v_price is not null then new.unit_price := v_price; end if;
  if coalesce(new.unit_price, 0) <= 0 then
    raise exception 'Harga "%" belum ada di Pricelist Jual %. Isi harga di PO atau buat pricelist di PT penjual.', (select name from inv_items where id = new.item_id), v_sup.name;
  end if;
  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end $$;
create trigger trg_pur_po_items_ic_price before insert or update of item_id, unit_id, unit_price, quantity
  on pur_purchase_order_items for each row execute function pur_set_ic_po_price();

-- ---------------------------------------------------------------------
-- PO DISETUJUI -> SALES ORDER DI PT PENJUAL
-- ---------------------------------------------------------------------
create or replace function grp_on_ic_po_approved()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sup pur_suppliers; v_cust uuid; v_outlet uuid; v_so uuid; v_buyer text;
begin
  select * into v_sup from pur_suppliers where id = new.supplier_id;
  if v_sup.supplier_type <> 'intercompany' or exists (select 1 from sal_sales_orders where ic_purchase_order_id = new.id) then return new; end if;
  -- grup harus masih sama
  if not exists (select 1 from sys_companies a join sys_companies b on b.group_id = a.group_id
                 where a.id = new.company_id and b.id = v_sup.linked_company_id and a.group_id is not null and b.is_active) then
    raise exception '% tidak lagi satu grup dengan PT ini', v_sup.name;
  end if;
  v_outlet := grp_seller_outlet(v_sup.linked_company_id);
  if v_outlet is null then raise exception '% belum punya outlet dengan gudang', v_sup.name; end if;
  select id into v_cust from sal_customers where company_id = v_sup.linked_company_id and linked_company_id = new.company_id;
  if v_cust is null then perform grp_sync_partners((select group_id from sys_companies where id = new.company_id));
    select id into v_cust from sal_customers where company_id = v_sup.linked_company_id and linked_company_id = new.company_id; end if;
  v_buyer := (select name from sys_companies where id = new.company_id);

  insert into sal_sales_orders (company_id, outlet_id, warehouse_id, customer_type, customer_id, ic_purchase_order_id,
    so_number, so_date, expected_date, status, shipping_address, note)
  values (v_sup.linked_company_id, v_outlet, (select default_warehouse_id from sys_outlets where id = v_outlet), 'external', v_cust, new.id,
    sys_next_document_number(v_sup.linked_company_id, 'SO', current_date), current_date, new.expected_date, 'new',
    (select o.address from inv_warehouses w join sys_outlets o on o.id = w.outlet_id where w.id = new.warehouse_id),
    'PO antar-PT ' || new.po_number || ' dari ' || v_buyer || coalesce(' - ' || new.note, ''))
  returning id into v_so;

  insert into sal_sales_order_items (company_id, sales_order_id, ic_po_item_id, item_id, unit_id, quantity, unit_price)
  select v_sup.linked_company_id, v_so, i.id, grp_map_item(i.item_id, v_sup.linked_company_id), grp_map_unit(i.unit_id, v_sup.linked_company_id),
         i.quantity, i.unit_price
  from pur_purchase_order_items i where i.purchase_order_id = new.id order by i.created_at, i.id;
  perform sal_recalculate_order(v_so);
  update pur_purchase_orders set sales_note = 'Menunggu konfirmasi ' || v_sup.name where id = new.id;
  return new;
end $$;
create trigger trg_pur_po_ic_approved after update of status on pur_purchase_orders
  for each row when (new.status = 'approved' and old.status is distinct from 'approved')
  execute function grp_on_ic_po_approved();

-- SO antar-PT dikonfirmasi / ditolak -> kabar ke PO pembeli; ditolak = PO batal (bila belum ada penerimaan)
create or replace function grp_on_ic_so_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.ic_purchase_order_id is null or new.status = old.status then return new; end if;
  if new.status in ('rejected', 'cancelled') then
    update pur_purchase_orders set status = 'cancelled', sales_note = 'Ditolak penjual' || coalesce(': ' || new.reject_reason, '')
    where id = new.ic_purchase_order_id and status = 'approved';
  else
    update pur_purchase_orders set sales_note = case new.status
      when 'confirmed' then 'Dikonfirmasi penjual (' || new.so_number || ')'
      when 'partially_delivered' then 'Sebagian dikirim penjual'
      when 'delivered' then 'Semua sudah dikirim penjual'
      when 'closed' then 'SO penjual ditutup' else sales_note end
    where id = new.ic_purchase_order_id;
  end if;
  return new;
end $$;
create trigger trg_sal_so_ic_status after update of status on sal_sales_orders
  for each row execute function grp_on_ic_so_status();

-- pengiriman PT penjual dikirim -> draft penerimaan barang di PT pembeli (sebagai penerimaan biasa: stok + hutang)
create or replace function grp_on_ic_delivery_shipped()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_so sal_sales_orders; v_po pur_purchase_orders; v_gr uuid;
begin
  select * into v_so from sal_sales_orders where id = new.sales_order_id;
  if v_so.ic_purchase_order_id is null then return new; end if;
  select * into v_po from pur_purchase_orders where id = v_so.ic_purchase_order_id;
  insert into pur_goods_receipts (company_id, purchase_order_id, supplier_id, warehouse_id, ic_delivery_id, note)
  values (v_po.company_id, v_po.id, v_po.supplier_id, v_po.warehouse_id, new.id,
          'Kiriman ' || coalesce(new.delivery_number, '') || ' dari ' || (select name from sys_companies where id = new.company_id))
  returning id into v_gr;
  insert into pur_goods_receipt_items (company_id, goods_receipt_id, purchase_order_item_id, item_id, unit_id,
    conversion_qty, quantity, shipped_qty, unit_price, line_total)
  select v_po.company_id, v_gr, poi.id, poi.item_id, poi.unit_id, poi.conversion_qty, di.quantity, di.quantity, poi.unit_price,
         round(di.quantity * poi.unit_price, 2)
  from sal_delivery_items di
  join sal_sales_order_items soi on soi.id = di.sales_order_item_id
  join pur_purchase_order_items poi on poi.id = soi.ic_po_item_id
  where di.delivery_id = new.id and di.quantity > 0 order by di.package_no, di.created_at, di.id;
  update pur_purchase_orders set sales_note = 'Barang dikirim, menunggu diterima (' || coalesce(new.delivery_number, '') || ')' where id = v_po.id;
  return new;
end $$;
create trigger trg_sal_delivery_ic_shipped after update of status on sal_deliveries
  for each row when (new.status = 'shipped' and old.status is distinct from 'shipped')
  execute function grp_on_ic_delivery_shipped();

-- PO ke PT lain / cabang internal tidak boleh dibuat penerimaan manual (datang dari pengiriman penjual)
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
  if (select supplier_type from pur_suppliers where id = v_po.supplier_id) = 'internal' then
    raise exception 'PO ke cabang internal diterima dari dokumen Pengiriman penjual (lihat Penerimaan Barang)';
  end if;
  if (select supplier_type from pur_suppliers where id = v_po.supplier_id) = 'intercompany' then
    raise exception 'PO ke PT dalam grup diterima otomatis dari pengiriman PT penjual (lihat Penerimaan Barang)';
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

-- ---------------------------------------------------------------------
-- JURNAL: tandai lawan transaksi antar-PT (untuk eliminasi konsolidasi)
-- ---------------------------------------------------------------------
create or replace function fin_ic_counterparty(p_source_type text, p_source_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select case p_source_type
    when 'sales_delivery' then (select c.linked_company_id from sal_deliveries d join sal_sales_orders so on so.id = d.sales_order_id
                                join sal_customers c on c.id = so.customer_id where d.id = p_source_id)
    when 'sales_invoice' then (select c.linked_company_id from sal_invoices i join sal_customers c on c.id = i.customer_id where i.id = p_source_id)
    when 'sales_credit_note' then (select c.linked_company_id from sal_credit_notes n join sal_invoices i on i.id = n.invoice_id
                                   join sal_customers c on c.id = i.customer_id where n.id = p_source_id)
    when 'sales_payment' then (select c.linked_company_id from sal_payments p join sal_customers c on c.id = p.customer_id where p.id = p_source_id)
    when 'purchase_receipt' then (select s.linked_company_id from pur_goods_receipts g join pur_suppliers s on s.id = g.supplier_id where g.id = p_source_id)
    when 'supplier_payment' then (select s.linked_company_id from fin_supplier_payments p join pur_suppliers s on s.id = p.supplier_id where p.id = p_source_id)
  end
$$;

create or replace function fin_tag_ic_line()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_j fin_journals;
begin
  if new.counterparty_company_id is null then
    select * into v_j from fin_journals where id = new.journal_id;
    if v_j.source_type in ('sales_delivery', 'sales_invoice', 'sales_credit_note', 'sales_payment', 'purchase_receipt', 'supplier_payment') then
      new.counterparty_company_id := fin_ic_counterparty(v_j.source_type, v_j.source_id);
    end if;
  end if;
  return new;
end $$;
create trigger trg_fin_journal_lines_ic before insert on fin_journal_lines
  for each row execute function fin_tag_ic_line();

-- ---------------------------------------------------------------------
-- PANTAU ANTAR-PT (pemilik grup): dokumen & saldo piutang/hutang antar-PT
-- ---------------------------------------------------------------------
create or replace function grp_ic_overview(p_group_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not grp_can_view(p_group_id) then raise exception 'Anda bukan pemilik grup ini'; end if;
  return (
    with cs as (select id, name from sys_companies where group_id = p_group_id),
    docs as (
      select po.id, po.po_number, po.po_date, po.status as po_status, po.subtotal, po.sales_note,
        po.company_id as buyer_id, s.linked_company_id as seller_id, so.so_number, so.status as so_status, so.grand_total as so_total,
        (select coalesce(sum(i.quantity), 0) from pur_purchase_order_items i where i.purchase_order_id = po.id) as qty_ordered,
        (select coalesce(sum(i.received_qty), 0) from pur_purchase_order_items i where i.purchase_order_id = po.id) as qty_received,
        (select coalesce(sum(i.delivered_qty), 0) from sal_sales_order_items i where i.sales_order_id = so.id) as qty_delivered,
        (select count(*) from pur_goods_receipts g where g.purchase_order_id = po.id and g.status = 'draft') as receipts_waiting,
        (select coalesce(sum(inv.grand_total), 0) from sal_invoices inv where inv.sales_order_id = so.id) as invoiced,
        (select coalesce(sum(inv.paid_amount), 0) from sal_invoices inv where inv.sales_order_id = so.id) as paid
      from pur_purchase_orders po
      join pur_suppliers s on s.id = po.supplier_id and s.supplier_type = 'intercompany'
      left join sal_sales_orders so on so.ic_purchase_order_id = po.id
      where po.company_id in (select id from cs)
    ),
    bal as (
      select l.company_id, l.counterparty_company_id as other_id, a.system_key, sum(l.debit - l.credit) as dc
      from fin_journal_lines l join fin_accounts a on a.id = l.account_id
      where l.company_id in (select id from cs) and l.counterparty_company_id in (select id from cs) and a.system_key in ('ar', 'ap')
      group by 1, 2, 3
    )
    select jsonb_build_object(
      'companies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from cs), '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('buyer', (select name from cs where id = d.buyer_id),
          'seller', (select name from cs where id = d.seller_id)) order by d.po_date desc, d.po_number desc) from docs d), '[]'::jsonb),
      -- piutang penjual atas pembeli vs hutang pembeli ke penjual (harus sama bila semua sudah diterima & ditagih)
      'balances', coalesce((select jsonb_agg(jsonb_build_object('seller_id', x.seller_id, 'buyer_id', x.buyer_id,
          'seller', (select name from cs where id = x.seller_id), 'buyer', (select name from cs where id = x.buyer_id),
          'receivable', x.ar, 'payable', x.ap, 'difference', x.ar - x.ap))
        from (select coalesce(r.company_id, p.other_id) as seller_id, coalesce(r.other_id, p.company_id) as buyer_id,
                     coalesce(r.dc, 0) as ar, coalesce(-p.dc, 0) as ap
              from (select * from bal where system_key = 'ar') r
              full join (select * from bal where system_key = 'ap') p on p.company_id = r.other_id and p.other_id = r.company_id) x
        where x.ar <> 0 or x.ap <> 0), '[]'::jsonb)));
end $$;
