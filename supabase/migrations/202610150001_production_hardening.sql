begin;

-- Hopa Pizza production hardening migration
-- Compatible with the current Hopa schema/tracking RPCs. Take a database backup first.
-- Existing orders are not assigned new tracking tokens: customers can track orders created
-- after this migration. Complete/cancel legacy pending orders from the admin panel.

create schema if not exists extensions;
-- Keep pgcrypto in its current schema on existing installations. The hash helper below
-- chooses the installed schema explicitly and does not rely on search_path.
create extension if not exists pgcrypto with schema extensions;

alter table public.store_settings add column if not exists minimum_order numeric(10,2) not null default 0;
alter table public.store_settings add column if not exists estimated_delivery_minutes integer not null default 45;
alter table public.store_settings add column if not exists delivery_areas text not null default 'يتم تأكيد نطاق التوصيل مع المطعم';
alter table public.store_settings add column if not exists opening_hours text not null default '';
do $$ begin
  if not exists (select 1 from pg_catalog.pg_constraint where conrelid='public.store_settings'::regclass and conname='store_settings_minimum_order_check') then
    alter table public.store_settings add constraint store_settings_minimum_order_check check (minimum_order >= 0);
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conrelid='public.store_settings'::regclass and conname='store_settings_delivery_minutes_check') then
    alter table public.store_settings add constraint store_settings_delivery_minutes_check check (estimated_delivery_minutes between 5 and 240);
  end if;
end $$;

-- Repair legacy status names and keep one authoritative allowed-status constraint.
alter table public.orders add column if not exists tracking_token_hash text;
alter table public.orders add column if not exists idempotency_key_hash text;
alter table public.orders drop constraint if exists orders_status_check;
update public.orders
set status = case lower(pg_catalog.trim(status))
  when 'جديد' then 'استلمنا طلبك'
  when 'تم الاستلام' then 'استلمنا طلبك'
  when 'new' then 'استلمنا طلبك'
  when 'received' then 'استلمنا طلبك'
  when 'قيد التجهيز' then 'بيتحضر'
  when 'قيد التحضير' then 'بيتحضر'
  when 'preparing' then 'بيتحضر'
  when 'in_preparation' then 'بيتحضر'
  when 'out_for_delivery' then 'خرج للتوصيل'
  when 'out for delivery' then 'خرج للتوصيل'
  when 'مكتمل' then 'تم التوصيل'
  when 'complete' then 'تم التوصيل'
  when 'completed' then 'تم التوصيل'
  when 'delivered' then 'تم التوصيل'
  when 'ملغى' then 'ملغي'
  when 'canceled' then 'ملغي'
  when 'cancelled' then 'ملغي'
  else status
end
where lower(pg_catalog.trim(status)) in (
  'جديد','تم الاستلام','new','received','قيد التجهيز','قيد التحضير','preparing','in_preparation',
  'out_for_delivery','out for delivery','مكتمل','complete','completed','delivered','ملغى','canceled','cancelled'
);
do $$ begin
  if exists (select 1 from public.orders where status not in ('استلمنا طلبك', 'بيتحضر', 'خرج للتوصيل', 'تم التوصيل', 'ملغي')) then
    raise exception 'Migration stopped: orders.status contains an unknown legacy value. Inspect distinct status values and map them before retrying.';
  end if;
end $$;
alter table public.orders alter column status set default 'استلمنا طلبك';
alter table public.orders add constraint orders_status_check
  check (status in ('استلمنا طلبك', 'بيتحضر', 'خرج للتوصيل', 'تم التوصيل', 'ملغي'));

create unique index if not exists orders_tracking_token_hash_uidx
  on public.orders (tracking_token_hash) where tracking_token_hash is not null;
create unique index if not exists orders_idempotency_key_hash_uidx
  on public.orders (idempotency_key_hash) where idempotency_key_hash is not null;
create index if not exists orders_phone_digits_idx
  on public.orders ((regexp_replace(phone, '[^0-9]', '', 'g')));

-- Keep the customer-facing HOPA-NNNN sequence ahead of imported/manual historical rows.
select pg_catalog.setval(
  'public.hopa_order_number_seq',
  greatest(
    1000,
    coalesce((
      select max(substring(order_number from '^HOPA-([0-9]+)$')::bigint)
      from public.orders
      where order_number ~ '^HOPA-[0-9]+$'
    ), 1000)
  ),
  true
);

create table if not exists public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  event_type text not null check (event_type in ('created', 'status_changed', 'customer_edited', 'customer_cancelled', 'admin_note')),
  from_status text,
  to_status text,
  note text not null default '',
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_id_created_at_idx
  on public.order_events (order_id, created_at desc);
alter table public.order_events enable row level security;
revoke all on public.order_events from public, anon, authenticated;
grant select on public.order_events to authenticated;
drop policy if exists "Admins read order events" on public.order_events;
create policy "Admins read order events" on public.order_events
  for select to authenticated using ((select public.is_hopa_admin()));

-- The rate-limit store only accepts calls from the trusted Edge Function via service_role.
create table if not exists public.hopa_api_rate_limits (
  ip_hash text not null,
  action text not null check (action in ('create', 'track', 'update', 'cancel')),
  window_start timestamptz not null,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (ip_hash, action, window_start)
);
alter table public.hopa_api_rate_limits enable row level security;
revoke all on public.hopa_api_rate_limits from public, anon, authenticated;
grant select, insert, update, delete on public.hopa_api_rate_limits to service_role;

-- Strong hashing utility. Tokens and idempotency keys are never stored in plaintext.
create or replace function public.hopa_sha256(p_value text)
returns text
language plpgsql
immutable
strict
security invoker
set search_path = ''
as $$
declare
  v_digest bytea;
  v_input bytea := pg_catalog.convert_to(p_value, 'UTF8');
begin
  if pg_catalog.to_regprocedure('extensions.digest(bytea,text)') is not null then
    execute 'select extensions.digest($1, $2)' into v_digest using v_input, 'sha256';
  elsif pg_catalog.to_regprocedure('public.digest(bytea,text)') is not null then
    execute 'select public.digest($1, $2)' into v_digest using v_input, 'sha256';
  else
    raise exception 'pgcrypto digest(bytea,text) is unavailable; install pgcrypto in extensions or public.';
  end if;
  return pg_catalog.encode(v_digest, 'hex');
end;
$$;
revoke all on function public.hopa_sha256(text) from public, anon, authenticated;
grant execute on function public.hopa_sha256(text) to service_role;

-- Atomic fixed-window rate limiter. IP values are already salted+hashed by the Edge Function.
create or replace function public.consume_hopa_rate_limit(
  p_ip_hash text,
  p_action text,
  p_window_seconds integer,
  p_max_requests integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_count integer;
begin
  if p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$'
     or p_action not in ('create', 'track', 'update', 'cancel')
     or p_window_seconds < 1 or p_window_seconds > 86400
     or p_max_requests < 1 or p_max_requests > 500 then
    raise exception 'Invalid rate-limit request.' using errcode = '22023';
  end if;
  v_start := pg_catalog.to_timestamp(
    pg_catalog.floor(pg_catalog.extract(epoch from pg_catalog.now()) / p_window_seconds) * p_window_seconds
  );
  -- Spread cleanup over requests rather than scanning this table for every API call.
  if pg_catalog.random() < 0.02 then
    delete from public.hopa_api_rate_limits
      where window_start < pg_catalog.now() - interval '48 hours';
  end if;
  insert into public.hopa_api_rate_limits(ip_hash, action, window_start, request_count)
  values (p_ip_hash, p_action, v_start, 1)
  on conflict (ip_hash, action, window_start)
  do update set request_count = public.hopa_api_rate_limits.request_count + 1
  returning request_count into v_count;
  return v_count <= p_max_requests;
end;
$$;
revoke all on function public.consume_hopa_rate_limit(text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.consume_hopa_rate_limit(text, text, integer, integer) to service_role;

-- Fix SECURITY DEFINER search paths: all application objects are explicitly schema-qualified.
create or replace function public.is_hopa_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admin_users au where au.user_id = (select auth.uid())
  );
$$;
revoke all on function public.is_hopa_admin() from public;
grant execute on function public.is_hopa_admin() to anon, authenticated;

-- Trusted create wrapper. The old pricing function still does the full transactional catalog
-- validation; this wrapper adds high-entropy access tokens and request idempotency atomically.
create or replace function public.create_hopa_order_secure(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_notes text,
  p_items jsonb,
  p_tracking_token text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token_hash text;
  v_idempotency_hash text;
  v_existing public.orders%rowtype;
  v_result jsonb;
  v_minimum_order numeric(10,2) := 0;
begin
  if p_tracking_token is null or p_tracking_token !~ '^[0-9a-fA-F]{64}$'
     or p_idempotency_key is null or p_idempotency_key !~ '^[0-9a-fA-F]{64}$' then
    raise exception 'تعذر تأمين الطلب. حدّث الصفحة وحاول مرة أخرى.' using errcode = '22023';
  end if;
  v_token_hash := public.hopa_sha256(pg_catalog.lower(p_tracking_token));
  v_idempotency_hash := public.hopa_sha256(pg_catalog.lower(p_idempotency_key));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_idempotency_hash, 0));

  select * into v_existing from public.orders o
   where o.idempotency_key_hash = v_idempotency_hash
   limit 1 for update;
  if found then
    if v_existing.tracking_token_hash is distinct from v_token_hash then
      raise exception 'مفتاح إعادة المحاولة مرتبط بمحاولة أخرى.' using errcode = '22023';
    end if;
    return public.get_hopa_order_by_token(v_existing.order_number, p_tracking_token) || pg_catalog.jsonb_build_object('_idempotent_replay', true);
  end if;

  v_result := public.create_hopa_order(
    p_customer_name, p_phone, p_address, p_notes, p_items
  );
  select ss.minimum_order into v_minimum_order from public.store_settings ss where ss.id = 1;
  v_minimum_order := coalesce(v_minimum_order, 0);
  if coalesce((v_result ->> 'subtotal')::numeric, 0) < v_minimum_order then
    raise exception 'الحد الأدنى للطلب هو % جنيه قبل رسوم التوصيل.', v_minimum_order using errcode = '22023';
  end if;
  update public.orders
    set tracking_token_hash = v_token_hash,
        idempotency_key_hash = v_idempotency_hash
    where id = (v_result ->> 'id')::uuid
    returning * into v_existing;

  insert into public.order_events(order_id, event_type, from_status, to_status, note)
  values (v_existing.id, 'created', null, v_existing.status, 'تم إنشاء الطلب من واجهة العميل');
  return public.get_hopa_order_by_token(v_existing.order_number, p_tracking_token) || pg_catalog.jsonb_build_object('_idempotent_replay', false);
end;
$$;

create or replace function public.get_hopa_order_by_token(
  p_order_number text,
  p_tracking_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_token_hash text;
begin
  if pg_catalog.length(pg_catalog.trim(coalesce(p_order_number, ''))) < 5
     or p_tracking_token is null or p_tracking_token !~ '^[0-9a-fA-F]{64}$' then
    return null;
  end if;
  v_token_hash := public.hopa_sha256(pg_catalog.lower(p_tracking_token));
  select * into v_order from public.orders o
   where pg_catalog.upper(o.order_number) = pg_catalog.upper(pg_catalog.trim(p_order_number))
     and o.tracking_token_hash = v_token_hash
   limit 1;
  if not found then return null; end if;
  return pg_catalog.jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number,
    'customer_name', v_order.customer_name, 'phone', v_order.phone,
    'address', v_order.address, 'notes', v_order.notes,
    'subtotal', v_order.subtotal, 'delivery_fee', v_order.delivery_fee,
    'total', v_order.total, 'status', v_order.status,
    'created_at', v_order.created_at, 'updated_at', v_order.updated_at,
    'items', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', oi.id, 'product_id', oi.product_id, 'product_name', oi.product_name,
        'size', oi.size, 'quantity', oi.quantity, 'unit_price', oi.unit_price,
        'line_total', oi.line_total, 'addons', oi.addons
      ) order by oi.created_at, oi.id)
      from public.order_items oi where oi.order_id = v_order.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.update_hopa_order_by_token(
  p_order_number text,
  p_tracking_token text,
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
  v_result jsonb;
begin
  if p_tracking_token is null or p_tracking_token !~ '^[0-9a-fA-F]{64}$' then return null; end if;
  select * into v_order from public.orders o
   where pg_catalog.upper(o.order_number) = pg_catalog.upper(pg_catalog.trim(coalesce(p_order_number, '')))
     and o.tracking_token_hash = public.hopa_sha256(pg_catalog.lower(p_tracking_token))
   limit 1 for update;
  if not found then return null; end if;
  if v_order.status <> 'استلمنا طلبك' then
    raise exception 'يمكن تعديل الطلب قبل بدء التجهيز فقط.' using errcode = '22023';
  end if;
  v_result := public.update_hopa_order(
    p_order_number, v_order.phone, p_customer_name, p_new_phone,
    p_address, p_notes, p_items
  );
  if v_result is null then return null; end if;
  insert into public.order_events(order_id, event_type, note)
  values (v_order.id, 'customer_edited', 'عدّل العميل بيانات الطلب أو الكميات قبل التجهيز');
  return public.get_hopa_order_by_token(p_order_number, p_tracking_token);
end;
$$;

create or replace function public.cancel_hopa_order_by_token(
  p_order_number text,
  p_tracking_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_result jsonb;
begin
  if p_tracking_token is null or p_tracking_token !~ '^[0-9a-fA-F]{64}$' then return null; end if;
  select * into v_order from public.orders o
   where pg_catalog.upper(o.order_number) = pg_catalog.upper(pg_catalog.trim(coalesce(p_order_number, '')))
     and o.tracking_token_hash = public.hopa_sha256(pg_catalog.lower(p_tracking_token))
   limit 1 for update;
  if not found then return null; end if;
  if v_order.status <> 'استلمنا طلبك' then
    raise exception 'يمكن إلغاء الطلب قبل بدء التجهيز فقط.' using errcode = '22023';
  end if;
  v_result := public.cancel_hopa_order(p_order_number, v_order.phone);
  if v_result is null then return null; end if;
  insert into public.order_events(order_id, event_type, from_status, to_status, note)
  values (v_order.id, 'customer_cancelled', v_order.status, 'ملغي', 'ألغى العميل الطلب قبل بدء التجهيز');
  return public.get_hopa_order_by_token(p_order_number, p_tracking_token);
end;
$$;

-- Only the trusted Edge Function may invoke legacy phone-based public RPCs.
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

revoke all on function public.create_hopa_order_secure(text, text, text, text, jsonb, text, text) from public, anon, authenticated;
revoke all on function public.get_hopa_order_by_token(text, text) from public, anon, authenticated;
revoke all on function public.update_hopa_order_by_token(text, text, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.cancel_hopa_order_by_token(text, text) from public, anon, authenticated;
grant execute on function public.create_hopa_order_secure(text, text, text, text, jsonb, text, text) to service_role;
grant execute on function public.get_hopa_order_by_token(text, text) to service_role;
grant execute on function public.update_hopa_order_by_token(text, text, text, text, text, text, jsonb) to service_role;
grant execute on function public.cancel_hopa_order_by_token(text, text) to service_role;

-- Centralized state machine: no direct order-status UPDATE grant remains for browser sessions.
create or replace function public.admin_set_hopa_order_status(
  p_order_id uuid,
  p_new_status text,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_user_id uuid := auth.uid();
  v_allowed boolean := false;
  v_previous_status text;
begin
  if not public.is_hopa_admin() then
    raise exception 'غير مصرح بتغيير حالة الطلب.' using errcode = '42501';
  end if;
  if p_new_status not in ('استلمنا طلبك', 'بيتحضر', 'خرج للتوصيل', 'تم التوصيل', 'ملغي') then
    raise exception 'حالة الطلب غير صالحة.' using errcode = '22023';
  end if;
  select * into v_order from public.orders o where o.id = p_order_id for update;
  if not found then raise exception 'الطلب غير موجود.' using errcode = 'P0002'; end if;
  if p_new_status = v_order.status then
    return pg_catalog.jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'status',v_order.status,'updated_at',v_order.updated_at);
  end if;
  v_previous_status := v_order.status;
  v_allowed := case v_order.status
    when 'استلمنا طلبك' then p_new_status in ('بيتحضر','ملغي')
    when 'بيتحضر' then p_new_status = 'خرج للتوصيل'
    when 'خرج للتوصيل' then p_new_status = 'تم التوصيل'
    else false
  end;
  if not v_allowed then
    raise exception 'انتقال الحالة من "%" إلى "%" غير مسموح.', v_order.status, p_new_status using errcode = '22023';
  end if;
  update public.orders set status = p_new_status, updated_at = pg_catalog.now()
   where id = v_order.id returning * into v_order;
  insert into public.order_events(order_id,event_type,from_status,to_status,note,changed_by)
  values (v_order.id,'status_changed',v_previous_status,p_new_status,pg_catalog.left(coalesce(p_note,''),500),v_user_id);
  return pg_catalog.jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'status',v_order.status,'updated_at',v_order.updated_at);
end;
$$;
revoke all on function public.admin_set_hopa_order_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_hopa_order_status(uuid, text, text) to authenticated;
revoke update on public.orders from authenticated;

create or replace function public.get_hopa_admin_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today timestamptz := pg_catalog.date_trunc('day', pg_catalog.now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
  v_result jsonb;
begin
  if not public.is_hopa_admin() then raise exception 'غير مصرح بعرض ملخص الإدارة.' using errcode = '42501'; end if;
  select pg_catalog.jsonb_build_object(
    'total_orders', count(*),
    'today_orders', count(*) filter (where created_at >= v_today),
    'new_orders', count(*) filter (where status = 'استلمنا طلبك'),
    'active_orders', count(*) filter (where status in ('استلمنا طلبك','بيتحضر','خرج للتوصيل')),
    'preparation_orders', count(*) filter (where status = 'بيتحضر'),
    'out_for_delivery_orders', count(*) filter (where status = 'خرج للتوصيل'),
    'cancelled_orders', count(*) filter (where status = 'ملغي'),
    'delivered_sales', coalesce(sum(total) filter (where status = 'تم التوصيل'), 0),
    'active_order_value', coalesce(sum(total) filter (where status in ('استلمنا طلبك','بيتحضر','خرج للتوصيل')), 0),
    'cancelled_value', coalesce(sum(total) filter (where status = 'ملغي'), 0)
  ) into v_result from public.orders;
  return v_result;
end;
$$;
revoke all on function public.get_hopa_admin_summary() from public, anon;
grant execute on function public.get_hopa_admin_summary() to authenticated;

create or replace function public.get_hopa_order_events_admin(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_hopa_admin() then raise exception 'غير مصرح بعرض سجل الطلب.' using errcode = '42501'; end if;
  if not exists (select 1 from public.orders o where o.id = p_order_id) then return '[]'::jsonb; end if;
  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'event_type',e.event_type,'from_status',e.from_status,'to_status',e.to_status,
      'note',e.note,'changed_by',e.changed_by,
      'changed_by_label',(select u.email from auth.users u where u.id=e.changed_by),
      'created_at',e.created_at
    ) order by e.created_at desc)
    from public.order_events e where e.order_id = p_order_id
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.get_hopa_order_events_admin(uuid) from public, anon;
grant execute on function public.get_hopa_order_events_admin(uuid) to authenticated;

-- Prevent direct anonymous access to orders/items and direct status edits. RLS policies remain in force.
revoke all on public.orders, public.order_items from public, anon;
revoke insert, update, delete on public.orders, public.order_items from public, authenticated;
grant select on public.orders, public.order_items to authenticated;

-- Reduce the attack surface of all old/new definer RPCs in the base schema.
alter function public.create_hopa_order(text, text, text, text, jsonb) set search_path = '';
alter function public.get_hopa_order_status(text, text) set search_path = '';
alter function public.update_hopa_order(text, text, text, text, text, text, jsonb) set search_path = '';
alter function public.update_hopa_order_details(text, text, text, text, text, text) set search_path = '';
alter function public.cancel_hopa_order(text, text) set search_path = '';
alter function public.is_hopa_admin() set search_path = '';

-- Ensure idempotency/tracking hashes are not exposed through broadly granted table APIs.
comment on column public.orders.tracking_token_hash is 'SHA-256 digest of the customer tracking secret; never return to the browser.';
comment on column public.orders.idempotency_key_hash is 'SHA-256 digest used for deduplicating order creation attempts.';

commit;
