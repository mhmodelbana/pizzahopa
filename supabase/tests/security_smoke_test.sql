-- Run only AFTER 202610150001_production_hardening.sql has completed.
-- This is a read-only invariant check: any failed condition raises an exception.
do $$
begin
  if pg_catalog.has_function_privilege('anon', 'public.create_hopa_order(text,text,text,text,jsonb)', 'EXECUTE') then
    raise exception 'Security failure: anon can execute the legacy create RPC';
  end if;
  if pg_catalog.has_function_privilege('anon', 'public.get_hopa_order_status(text,text)', 'EXECUTE') then
    raise exception 'Security failure: anon can execute the legacy order lookup RPC';
  end if;
  if pg_catalog.has_function_privilege('anon', 'public.update_hopa_order(text,text,text,text,text,text,jsonb)', 'EXECUTE') then
    raise exception 'Security failure: anon can execute the legacy order update RPC';
  end if;
  if pg_catalog.has_function_privilege('anon', 'public.cancel_hopa_order(text,text)', 'EXECUTE') then
    raise exception 'Security failure: anon can execute the legacy order cancellation RPC';
  end if;
  if pg_catalog.has_table_privilege('anon', 'public.orders', 'SELECT') then
    raise exception 'Security failure: anon can select orders directly';
  end if;
  if pg_catalog.has_table_privilege('anon', 'public.order_items', 'SELECT') then
    raise exception 'Security failure: anon can select order_items directly';
  end if;
  if pg_catalog.has_table_privilege('authenticated', 'public.orders', 'UPDATE') then
    raise exception 'Security failure: authenticated users can update orders directly';
  end if;
  if not pg_catalog.has_function_privilege('service_role', 'public.create_hopa_order_secure(text,text,text,text,jsonb,text,text)', 'EXECUTE') then
    raise exception 'Configuration failure: service_role cannot execute secure order creation';
  end if;
  if pg_catalog.to_regclass('public.order_events') is null then
    raise exception 'Configuration failure: public.order_events is missing';
  end if;
  if pg_catalog.to_regclass('public.hopa_api_rate_limits') is null then
    raise exception 'Configuration failure: public.hopa_api_rate_limits is missing';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid='public.orders'::regclass and conname='orders_status_check'
  ) then
    raise exception 'Configuration failure: orders_status_check is missing';
  end if;
end;
$$;
