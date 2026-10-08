-- =====================================================================
-- SANTAP ERP - UPDATE FASE 22 (Semar: forecasting & membuat PO)
-- Untuk database yang SUDAH menjalankan fase 1-21.
-- Jalankan SEKALI di Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- >>>>>>>>>> migrations/032_semar_purchase_order.sql
-- =====================================================================
-- SANTAP ERP - 032: SEMAR BISA MENGANALISA KEBUTUHAN BELI & MEMBUAT PO
--   * ai_purchase_forecast: per bahan -> stok, pemakaian/hari, cukup berapa hari, saran beli
--     (satuan beli), opsi supplier & harga dari pricelist aktif, harga pembelian terakhir.
--   * ai_create_purchase_order: buat PO dari usulan Semar. p_dry_run = true -> hanya pratinjau
--     (harga diisi otomatis dari pricelist / pembelian terakhir), tanpa menyimpan.
--     submit = true -> langsung diajukan lewat pur_approve_purchase_order (ikut matriks approval).
--   Keduanya memakai hak akses user yang memanggil (purchasing.manage, akses gudang/branch).
-- =====================================================================

create or replace function ai_purchase_forecast(
  p_warehouse_id uuid default null, p_days int default 14, p_cover_days int default 7, p_search text default null
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_days int := greatest(coalesce(p_days, 14), 1);
  v_cover int := greatest(coalesce(p_cover_days, 7), 1);
begin
  if not (sys_has_permission('purchasing.manage') or sys_has_permission('inventory.manage')) then raise exception 'Tidak punya izin melihat kebutuhan beli'; end if;
  return jsonb_build_object(
    'periode_data_hari', v_days, 'target_cukup_hari', v_cover,
    'gudang', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'nama', w.name)) from inv_warehouses w
                        where w.company_id = v_company and (p_warehouse_id is null or w.id = p_warehouse_id) and sys_can_access_warehouse(w.id)), '[]'::jsonb),
    'items', coalesce((
      with wh as (
        select id from inv_warehouses where company_id = v_company and (p_warehouse_id is null or id = p_warehouse_id) and sys_can_access_warehouse(id)
      ), stock as (
        select item_id, sum(quantity) qty from inv_stocks where warehouse_id in (select id from wh) group by item_id
      ), usage as (
        select item_id, -sum(quantity) used from inv_stock_movements
        where warehouse_id in (select id from wh) and quantity < 0 and movement_type not in ('transfer_out', 'opname')
          and movement_at >= now() - make_interval(days => v_days)
        group by item_id
      ), lvl as (
        select item_id, sum(min_qty) min_qty from inv_item_stock_levels where warehouse_id in (select id from wh) group by item_id
      ), calc as (
        select i.id, i.code, i.name, b.code base_unit, coalesce(st.qty, 0) stock, coalesce(u.used, 0) / v_days daily,
               coalesce(l.min_qty, i.min_stock, 0) min_qty, coalesce(pu.unit_id, i.base_unit_id) p_unit, coalesce(pu.conversion_qty, 1) p_conv,
               coalesce(pun.code, b.code) p_unit_code, i.last_purchase_cost
        from inv_items i
        join inv_units b on b.id = i.base_unit_id
        left join stock st on st.item_id = i.id
        left join usage u on u.item_id = i.id
        left join lvl l on l.item_id = i.id
        left join inv_item_units pu on pu.item_id = i.id and pu.is_purchase_unit
        left join inv_units pun on pun.id = pu.unit_id
        where i.company_id = v_company and i.is_active and i.is_purchasable
          and (p_search is null or i.name ilike '%' || p_search || '%' or i.code ilike '%' || p_search || '%')
      )
      select jsonb_agg(x order by (x->>'cukup_untuk_hari')::numeric nulls last, x->>'nama')
      from (
        select jsonb_build_object(
          'item_id', c.id, 'kode', c.code, 'nama', c.name,
          'stok', round(c.stock, 2), 'satuan_dasar', c.base_unit,
          'pemakaian_per_hari', round(c.daily, 3),
          'cukup_untuk_hari', case when c.daily > 0 then round(c.stock / c.daily, 1) end,
          'stok_minimum', c.min_qty,
          'saran_beli', ceil(greatest(0, c.daily * v_cover + c.min_qty - c.stock) / c.p_conv),
          'satuan_beli', c.p_unit_code, 'unit_id_beli', c.p_unit, 'isi_per_satuan_beli', c.p_conv,
          'harga_beli_terakhir_per_satuan_beli', round(c.last_purchase_cost * c.p_conv, 2),
          'opsi_supplier', coalesce((
            select jsonb_agg(o order by (o->>'harga')::numeric) from (
              select distinct on (pl.supplier_id) jsonb_build_object(
                'supplier_id', s.id, 'supplier', s.name, 'harga', pi.price, 'satuan', un.code, 'unit_id', pi.unit_id,
                'sumber', 'pricelist ' || coalesce(pl.pricelist_number, '')) o
              from pur_pricelist_items pi join pur_pricelists pl on pl.id = pi.pricelist_id
              join pur_suppliers s on s.id = pl.supplier_id join inv_units un on un.id = pi.unit_id
              where pi.item_id = c.id and pl.company_id = v_company and pl.status = 'approved'
                and pl.effective_date <= current_date and (pl.expiry_date is null or pl.expiry_date >= current_date)
              order by pl.supplier_id, pl.effective_date desc
            ) q), '[]'::jsonb),
          'pembelian_terakhir', (
            select jsonb_build_object('supplier_id', s.id, 'supplier', s.name, 'harga', gi.unit_price, 'satuan', un.code, 'tanggal', g.receipt_date)
            from pur_goods_receipt_items gi join pur_goods_receipts g on g.id = gi.goods_receipt_id
            join pur_suppliers s on s.id = g.supplier_id join inv_units un on un.id = gi.unit_id
            where gi.item_id = c.id and g.company_id = v_company and g.status = 'posted'
            order by g.receipt_date desc limit 1)
        ) x
        from calc c
        where c.daily > 0 or c.stock <= c.min_qty
        limit 80
      ) t
    ), '[]'::jsonb));
end $$;

create or replace function ai_create_purchase_order(p jsonb, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := sys_current_company_id();
  v_sup     pur_suppliers%rowtype;
  v_wh      inv_warehouses%rowtype;
  v_item    inv_items%rowtype;
  v_po      uuid;
  r         jsonb;
  v_lines   jsonb := '[]'::jsonb;
  v_total   numeric := 0;
  v_unit    uuid;
  v_conv    numeric;
  v_qty     numeric;
  v_price   numeric;
  v_src     text;
  v_warn    text[] := '{}';
  v_res     jsonb;
begin
  if not sys_has_permission('purchasing.manage') then raise exception 'Tidak punya izin membuat PO'; end if;
  select * into v_sup from pur_suppliers where id = nullif(p->>'supplier_id', '')::uuid and company_id = v_company;
  if not found then raise exception 'Supplier tidak ditemukan'; end if;
  select * into v_wh from inv_warehouses where id = nullif(p->>'warehouse_id', '')::uuid and company_id = v_company;
  if not found then raise exception 'Gudang tidak ditemukan'; end if;
  if not sys_can_access_warehouse(v_wh.id) then raise exception 'Tidak punya akses ke gudang %', v_wh.name; end if;
  if jsonb_array_length(coalesce(p->'items', '[]'::jsonb)) = 0 then raise exception 'Item PO masih kosong'; end if;

  for r in select * from jsonb_array_elements(p->'items') loop
    select * into v_item from inv_items where id = nullif(r->>'item_id', '')::uuid and company_id = v_company and is_active;
    if not found then raise exception 'Bahan % tidak ditemukan', coalesce(r->>'nama', r->>'item_id'); end if;
    -- satuan: yang diminta, satuan beli, atau satuan dasar
    v_unit := coalesce(nullif(r->>'unit_id', '')::uuid, (select unit_id from inv_item_units where item_id = v_item.id and is_purchase_unit), v_item.base_unit_id);
    v_conv := case when v_unit = v_item.base_unit_id then 1 else (select conversion_qty from inv_item_units where item_id = v_item.id and unit_id = v_unit) end;
    if v_conv is null then raise exception 'Satuan untuk % tidak terdaftar di Master Produk', v_item.name; end if;
    v_qty := nullif(r->>'qty', '')::numeric;
    if coalesce(v_qty, 0) <= 0 then raise exception 'Qty % harus lebih dari 0', v_item.name; end if;
    v_price := nullif(r->>'harga', '')::numeric;
    v_src := 'diisi Semar';
    if v_price is null then
      v_res := pur_get_item_price(v_sup.id, v_item.id, v_unit, v_wh.outlet_id);
      v_price := (v_res->'pricelist'->>'price')::numeric; v_src := 'pricelist';
      if v_price is null then v_price := (v_res->'last'->>'price')::numeric; v_src := 'pembelian terakhir'; end if;
      if v_price is null then v_price := round(v_item.last_purchase_cost * v_conv, 2); v_src := 'harga beli terakhir bahan'; end if;
    end if;
    if coalesce(v_price, 0) = 0 then v_warn := v_warn || format('Harga %s masih 0, isi pricelist atau harga manual', v_item.name); end if;
    v_lines := v_lines || jsonb_build_object(
      'item_id', v_item.id, 'nama', v_item.name, 'unit_id', v_unit, 'satuan', (select code from inv_units where id = v_unit),
      'conversion_qty', v_conv, 'qty', v_qty, 'harga', coalesce(v_price, 0), 'sumber_harga', v_src,
      'subtotal', round(v_qty * coalesce(v_price, 0), 2));
    v_total := v_total + round(v_qty * coalesce(v_price, 0), 2);
  end loop;

  if p_dry_run then
    return jsonb_build_object('supplier', v_sup.name, 'gudang', v_wh.name, 'items', v_lines, 'total', v_total, 'peringatan', to_jsonb(v_warn),
                              'akan_diajukan', coalesce((p->>'submit')::boolean, false));
  end if;

  insert into pur_purchase_orders (company_id, supplier_id, warehouse_id, expected_date, note, created_by)
  values (v_company, v_sup.id, v_wh.id, nullif(p->>'expected_date', '')::date, coalesce(nullif(p->>'note', ''), 'Dibuat oleh Semar (AI)'), auth.uid())
  returning id into v_po;
  insert into pur_purchase_order_items (company_id, purchase_order_id, item_id, unit_id, conversion_qty, quantity, unit_price, line_total)
  select v_company, v_po, (l->>'item_id')::uuid, (l->>'unit_id')::uuid, (l->>'conversion_qty')::numeric,
         (l->>'qty')::numeric, (l->>'harga')::numeric, (l->>'subtotal')::numeric
  from jsonb_array_elements(v_lines) l;

  if coalesce((p->>'submit')::boolean, false) then
    v_res := pur_approve_purchase_order(v_po);
    return jsonb_build_object('id', v_po, 'po_number', v_res->>'po_number', 'total', v_total,
      'status', case when coalesce((v_res->>'pending_approval')::boolean, false) or v_res->>'status' = 'pending_approval'
                     then 'menunggu persetujuan' else 'disetujui' end);
  end if;
  return jsonb_build_object('id', v_po, 'po_number', null, 'status', 'draft', 'total', v_total);
end $$;
