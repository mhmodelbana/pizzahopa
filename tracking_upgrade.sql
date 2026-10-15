-- WARNING: LEGACY TRACKING FUNCTION UPGRADE
-- Existing installations must apply this only as part of the documented maintenance sequence,
-- then immediately apply supabase/migrations/202610150001_production_hardening.sql and deploy
-- the hopa-public-api Edge Function. This file no longer leaves phone-based RPCs public.

-- Hopa Pizza migration: HOPA-1001-style order ids and rich tracking/editing
-- Existing orders and menu rows are preserved. Run once in Supabase SQL Editor.
create sequence if not exists public.hopa_order_number_seq start with 1001;

create or replace function public.create_hopa_order(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_notes text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_customer_name text := trim(coalesce(p_customer_name, ''));
  v_phone text := trim(coalesce(p_phone, ''));
  v_phone_digits text;
  v_address text := trim(coalesce(p_address, ''));
  v_notes text := trim(coalesce(p_notes, ''));
  v_delivery_fee numeric(10,2) := 15;
  v_is_open boolean := true;
  v_product public.products%rowtype;
  v_addon public.addons%rowtype;
  v_item jsonb;
  v_addon_id text;
  v_product_id text;
  v_size text;
  v_quantity integer;
  v_base_price numeric(12,2);
  v_addon_price numeric(12,2);
  v_unit_price numeric(12,2);
  v_line_total numeric(12,2);
  v_subtotal numeric(12,2) := 0;
  v_addons_json jsonb;
  v_return_items jsonb := '[]'::jsonb;
  v_addon_ids jsonb;
begin
  if length(v_customer_name) < 2 or length(v_customer_name) > 100 then
    raise exception 'من فضلك أدخل اسمًا صحيحًا.' using errcode = '22023';
  end if;
  v_phone_digits := regexp_replace(v_phone, '[^0-9]', '', 'g');
  if length(v_phone_digits) < 10 or length(v_phone_digits) > 15 then
    raise exception 'من فضلك أدخل رقم هاتف صحيحًا.' using errcode = '22023';
  end if;
  if length(v_address) < 5 or length(v_address) > 500 then
    raise exception 'من فضلك أدخل عنوان التوصيل بالتفصيل.' using errcode = '22023';
  end if;
  if length(v_notes) > 500 then
    raise exception 'الملاحظات أطول من المسموح.' using errcode = '22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    raise exception 'السلة غير صحيحة أو تحتوي على عدد أصناف غير مسموح.' using errcode = '22023';
  end if;

  select ss.delivery_fee, ss.is_open
    into v_delivery_fee, v_is_open
    from public.store_settings ss where ss.id = 1;
  v_delivery_fee := coalesce(v_delivery_fee, 15);
  v_is_open := coalesce(v_is_open, true);
  if not v_is_open then
    raise exception 'المطعم مغلق حاليًا ولا يستقبل طلبات جديدة.' using errcode = '22023';
  end if;

  v_order_number := 'HOPA-' || nextval('public.hopa_order_number_seq')::text;
  insert into public.orders (
    order_number, customer_name, phone, address, notes, subtotal, delivery_fee, total, status
  ) values (
    v_order_number, v_customer_name, v_phone, v_address, v_notes, 0, v_delivery_fee, 0, 'استلمنا طلبك'
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) as rows(value)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'يوجد صنف غير صالح في الطلب.' using errcode = '22023';
    end if;

    v_product_id := trim(coalesce(v_item->>'product_id', ''));
    v_size := trim(coalesce(v_item->>'size', ''));
    begin
      v_quantity := (v_item->>'quantity')::integer;
    exception when others then
      raise exception 'كمية أحد الأصناف غير صالحة.' using errcode = '22023';
    end;
    if v_quantity < 1 or v_quantity > 50 then
      raise exception 'الكمية يجب أن تكون بين 1 و50.' using errcode = '22023';
    end if;
    if v_item ? 'addon_ids' and jsonb_typeof(v_item->'addon_ids') <> 'array' then
      raise exception 'إضافات أحد الأصناف غير صالحة.' using errcode = '22023';
    end if;
    v_addon_ids := coalesce(v_item->'addon_ids', '[]'::jsonb);

    select * into v_product
      from public.products p
      where p.id = v_product_id and p.is_active = true;
    if not found then
      raise exception 'أحد المنتجات لم يعد متاحًا.' using errcode = '22023';
    end if;

    select (s.value->>'price')::numeric into v_base_price
      from jsonb_array_elements(v_product.sizes) as s(value)
      where s.value->>'name' = v_size
      limit 1;
    if v_base_price is null or v_base_price < 0 then
      raise exception 'حجم أو سعر أحد المنتجات غير صالح.' using errcode = '22023';
    end if;

    v_unit_price := v_base_price;
    v_addons_json := '[]'::jsonb;

    for v_addon_id in
      select distinct value from jsonb_array_elements_text(v_addon_ids) as ids(value)
    loop
      select * into v_addon
        from public.addons a
        where a.id = v_addon_id
          and a.group_key = v_product.addon_group
          and a.is_active = true;
      if not found then
        raise exception 'إحدى الإضافات غير متاحة لهذا المنتج.' using errcode = '22023';
      end if;

      if v_addon.price_type = 'fixed' then
        v_addon_price := v_addon.fixed_price;
      else
        begin
          v_addon_price := (v_addon.size_prices->>v_size)::numeric;
        exception when others then
          v_addon_price := null;
        end;
      end if;
      if v_addon_price is null or v_addon_price < 0 then
        raise exception 'سعر إحدى الإضافات غير صالح لهذا الحجم.' using errcode = '22023';
      end if;

      v_unit_price := v_unit_price + v_addon_price;
      v_addons_json := v_addons_json || jsonb_build_array(
        jsonb_build_object('id', v_addon.id, 'name', v_addon.name, 'price', v_addon_price)
      );
    end loop;

    v_line_total := v_unit_price * v_quantity;
    v_subtotal := v_subtotal + v_line_total;

    insert into public.order_items (
      order_id, product_id, product_name, size, quantity, unit_price, line_total, addons
    ) values (
      v_order_id, v_product.id, v_product.name, v_size, v_quantity, v_unit_price, v_line_total, v_addons_json
    );

    v_return_items := v_return_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_product.id,
      'product_name', v_product.name,
      'size', v_size,
      'quantity', v_quantity,
      'unit_price', v_unit_price,
      'line_total', v_line_total,
      'addons', v_addons_json
    ));
  end loop;

  update public.orders
    set subtotal = v_subtotal,
        total = v_subtotal + v_delivery_fee,
        updated_at = now()
    where id = v_order_id;

  return jsonb_build_object(
    'id', v_order_id,
    'order_number', v_order_number,
    'customer_name', v_customer_name,
    'phone', v_phone,
    'subtotal', v_subtotal,
    'delivery_fee', v_delivery_fee,
    'total', v_subtotal + v_delivery_fee,
    'status', 'استلمنا طلبك',
    'items', v_return_items
  );
end;
$$;

revoke all on function public.create_hopa_order(text, text, text, text, jsonb) from public;
grant execute on function public.create_hopa_order(text, text, text, text, jsonb) to anon, authenticated;

create or replace function public.get_hopa_order_status(
  p_order_number text,
  p_phone text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_phone_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if length(trim(coalesce(p_order_number, ''))) < 5
     or length(v_phone_digits) < 10 or length(v_phone_digits) > 15 then
    return null;
  end if;

  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(p_order_number))
    and regexp_replace(o.phone, '[^0-9]', '', 'g') = v_phone_digits
  limit 1;

  if not found then return null; end if;

  return jsonb_build_object(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'customer_name', v_order.customer_name,
    'phone', v_order.phone,
    'address', v_order.address,
    'notes', v_order.notes,
    'subtotal', v_order.subtotal,
    'delivery_fee', v_order.delivery_fee,
    'total', v_order.total,
    'status', v_order.status,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', oi.id,
        'product_id', oi.product_id,
        'product_name', oi.product_name,
        'size', oi.size,
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'line_total', oi.line_total,
        'addons', oi.addons
      ) order by oi.created_at, oi.id)
      from public.order_items oi
      where oi.order_id = v_order.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_hopa_order_status(text, text) from public;
grant execute on function public.get_hopa_order_status(text, text) to anon, authenticated;

create or replace function public.update_hopa_order(
  p_order_number text,
  p_phone text,
  p_customer_name text,
  p_new_phone text,
  p_address text,
  p_notes text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_customer_name text := trim(coalesce(p_customer_name, ''));
  v_phone text := trim(coalesce(p_new_phone, ''));
  v_phone_digits text := regexp_replace(coalesce(p_new_phone, ''), '[^0-9]', '', 'g');
  v_old_phone_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_address text := trim(coalesce(p_address, ''));
  v_notes text := trim(coalesce(p_notes, ''));
  v_product public.products%rowtype;
  v_addon public.addons%rowtype;
  v_item jsonb;
  v_addon_id text;
  v_product_id text;
  v_size text;
  v_quantity integer;
  v_base_price numeric(12,2);
  v_addon_price numeric(12,2);
  v_unit_price numeric(12,2);
  v_line_total numeric(12,2);
  v_subtotal numeric(12,2) := 0;
  v_addons_json jsonb;
  v_addon_ids jsonb;
begin
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and regexp_replace(o.phone, '[^0-9]', '', 'g') = v_old_phone_digits
  for update;

  if not found then return null; end if;
  if v_order.status <> 'استلمنا طلبك' then
    raise exception 'يمكن تعديل الطلب قبل بدء التجهيز فقط.' using errcode = '22023';
  end if;
  if length(v_customer_name) < 2 or length(v_customer_name) > 100 then
    raise exception 'من فضلك أدخل اسمًا صحيحًا.' using errcode = '22023';
  end if;
  if length(v_phone_digits) < 10 or length(v_phone_digits) > 15 then
    raise exception 'من فضلك أدخل رقم هاتف صحيحًا.' using errcode = '22023';
  end if;
  if length(v_address) < 5 or length(v_address) > 500 then
    raise exception 'من فضلك أدخل عنوان التوصيل بالتفصيل.' using errcode = '22023';
  end if;
  if length(v_notes) > 500 then
    raise exception 'الملاحظات أطول من المسموح.' using errcode = '22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    raise exception 'يجب أن يحتوي الطلب على صنف واحد على الأقل وبحد أقصى 30 صنفًا.' using errcode = '22023';
  end if;

  -- The statement is transactional: any bad product/add-on restores the original order items.
  delete from public.order_items where order_id = v_order.id;

  for v_item in select value from jsonb_array_elements(p_items) as rows(value)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'يوجد صنف غير صالح في الطلب.' using errcode = '22023';
    end if;
    v_product_id := trim(coalesce(v_item->>'product_id', ''));
    v_size := trim(coalesce(v_item->>'size', ''));
    begin
      v_quantity := (v_item->>'quantity')::integer;
    exception when others then
      raise exception 'كمية أحد الأصناف غير صالحة.' using errcode = '22023';
    end;
    if v_quantity < 1 or v_quantity > 50 then
      raise exception 'الكمية يجب أن تكون بين 1 و50.' using errcode = '22023';
    end if;
    if v_item ? 'addon_ids' and jsonb_typeof(v_item->'addon_ids') <> 'array' then
      raise exception 'إضافات أحد الأصناف غير صالحة.' using errcode = '22023';
    end if;
    v_addon_ids := coalesce(v_item->'addon_ids', '[]'::jsonb);

    select * into v_product
    from public.products p
    where p.id = v_product_id and p.is_active = true;
    if not found then
      raise exception 'أحد المنتجات لم يعد متاحًا.' using errcode = '22023';
    end if;

    select (s.value->>'price')::numeric into v_base_price
    from jsonb_array_elements(v_product.sizes) as s(value)
    where s.value->>'name' = v_size
    limit 1;
    if v_base_price is null or v_base_price < 0 then
      raise exception 'حجم أو سعر أحد المنتجات غير صالح.' using errcode = '22023';
    end if;

    v_unit_price := v_base_price;
    v_addons_json := '[]'::jsonb;
    for v_addon_id in
      select distinct value from jsonb_array_elements_text(v_addon_ids) as ids(value)
    loop
      select * into v_addon
      from public.addons a
      where a.id = v_addon_id
        and a.group_key = v_product.addon_group
        and a.is_active = true;
      if not found then
        raise exception 'إحدى الإضافات غير متاحة لهذا المنتج.' using errcode = '22023';
      end if;
      if v_addon.price_type = 'fixed' then
        v_addon_price := v_addon.fixed_price;
      else
        begin
          v_addon_price := (v_addon.size_prices->>v_size)::numeric;
        exception when others then
          v_addon_price := null;
        end;
      end if;
      if v_addon_price is null or v_addon_price < 0 then
        raise exception 'سعر إحدى الإضافات غير صالح لهذا الحجم.' using errcode = '22023';
      end if;
      v_unit_price := v_unit_price + v_addon_price;
      v_addons_json := v_addons_json || jsonb_build_array(
        jsonb_build_object('id', v_addon.id, 'name', v_addon.name, 'price', v_addon_price)
      );
    end loop;

    v_line_total := v_unit_price * v_quantity;
    v_subtotal := v_subtotal + v_line_total;
    insert into public.order_items (
      order_id, product_id, product_name, size, quantity, unit_price, line_total, addons
    ) values (
      v_order.id, v_product.id, v_product.name, v_size, v_quantity, v_unit_price, v_line_total, v_addons_json
    );
  end loop;

  update public.orders
  set customer_name = v_customer_name,
      phone = v_phone,
      address = v_address,
      notes = v_notes,
      subtotal = v_subtotal,
      total = v_subtotal + v_order.delivery_fee,
      updated_at = now()
  where id = v_order.id;

  return public.get_hopa_order_status(p_order_number, v_phone);
end;
$$;

revoke all on function public.update_hopa_order(text, text, text, text, text, text, jsonb) from public;
grant execute on function public.update_hopa_order(text, text, text, text, text, text, jsonb) to anon, authenticated;

create or replace function public.update_hopa_order_details(
  p_order_number text,
  p_phone text,
  p_customer_name text,
  p_new_phone text,
  p_address text,
  p_notes text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_status text;
  v_old_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_new_digits text := regexp_replace(coalesce(p_new_phone, ''), '[^0-9]', '', 'g');
  v_customer_name text := trim(coalesce(p_customer_name, ''));
  v_new_phone_clean text := trim(coalesce(p_new_phone, ''));
  v_address text := trim(coalesce(p_address, ''));
  v_notes text := trim(coalesce(p_notes, ''));
begin
  if length(v_customer_name) < 2 or length(v_customer_name) > 100 then
    raise exception 'من فضلك أدخل اسمًا صحيحًا.' using errcode = '22023';
  end if;
  if length(v_new_digits) < 10 or length(v_new_digits) > 15 then
    raise exception 'من فضلك أدخل رقم هاتف صحيحًا.' using errcode = '22023';
  end if;
  if length(v_address) < 5 or length(v_address) > 500 then
    raise exception 'من فضلك أدخل عنوان التوصيل بالتفصيل.' using errcode = '22023';
  end if;
  if length(v_notes) > 500 then
    raise exception 'الملاحظات أطول من المسموح.' using errcode = '22023';
  end if;

  select o.id, o.status into v_order_id, v_status
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and regexp_replace(o.phone, '[^0-9]', '', 'g') = v_old_digits
  for update;

  if not found then return null; end if;
  if v_status <> 'استلمنا طلبك' then
    raise exception 'يمكن تعديل بيانات الطلب قبل بدء التجهيز فقط.' using errcode = '22023';
  end if;

  update public.orders
  set customer_name = v_customer_name,
      phone = v_new_phone_clean,
      address = v_address,
      notes = v_notes,
      updated_at = now()
  where id = v_order_id;

  return public.get_hopa_order_status(p_order_number, v_new_phone_clean);
end;
$$;

revoke all on function public.update_hopa_order_details(text, text, text, text, text, text) from public;
grant execute on function public.update_hopa_order_details(text, text, text, text, text, text) to anon, authenticated;

create or replace function public.cancel_hopa_order(
  p_order_number text,
  p_phone text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_phone_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  select * into v_order
  from public.orders o
  where upper(o.order_number) = upper(trim(coalesce(p_order_number, '')))
    and regexp_replace(o.phone, '[^0-9]', '', 'g') = v_phone_digits
  for update;

  if not found then return null; end if;
  if v_order.status <> 'استلمنا طلبك' then
    raise exception 'يمكن إلغاء الطلب قبل بدء التجهيز فقط.' using errcode = '22023';
  end if;

  update public.orders
  set status = 'ملغي', updated_at = now()
  where id = v_order.id
  returning * into v_order;

  return jsonb_build_object(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'customer_name', v_order.customer_name,
    'phone', v_order.phone,
    'address', v_order.address,
    'notes', v_order.notes,
    'subtotal', v_order.subtotal,
    'delivery_fee', v_order.delivery_fee,
    'total', v_order.total,
    'status', v_order.status,
    'created_at', v_order.created_at,
    'updated_at', v_order.updated_at
  );
end;
$$;

revoke all on function public.cancel_hopa_order(text, text) from public;
grant execute on function public.cancel_hopa_order(text, text) to anon, authenticated;


-- Final privilege state: browser clients must use the token-based Edge API, never these phone RPCs.
revoke all on function public.create_hopa_order(text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.get_hopa_order_status(text, text) from public, anon, authenticated;
revoke all on function public.update_hopa_order(text, text, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.update_hopa_order_details(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.cancel_hopa_order(text, text) from public, anon, authenticated;
grant execute on function public.create_hopa_order(text, text, text, text, jsonb) to service_role;
grant execute on function public.get_hopa_order_status(text, text) to service_role;
grant execute on function public.update_hopa_order(text, text, text, text, text, text, jsonb) to service_role;
grant execute on function public.update_hopa_order_details(text, text, text, text, text, text) to service_role;
grant execute on function public.cancel_hopa_order(text, text) to service_role;
