-- Локальное предложение после диспетчеризации. Выполнять только одной транзакцией.
-- Допуск к схеме Data API управляется отдельно. В public ничего не добавляется.
do $preflight$
begin
  if current_user <> 'postgres'
     or to_regclass('public.orbita_orders') is null
     or to_regclass('orbita_mobile_private.dispatch_drivers') is null
     or to_regclass('orbita_mobile_private.dispatch_offers') is null
     or to_regprocedure('orbita_mobile_private.order_session_uid()') is null
     or to_regprocedure('orbita_mobile_private.dispatch_allowed(uuid,text)') is null then
    raise exception 'ORB_ADMIN_PREFLIGHT';
  end if;
end
$preflight$;

create schema orbita_admin_private authorization postgres;
create schema orbita_admin_api authorization postgres;
revoke all on schema orbita_admin_private, orbita_admin_api from public, anon, authenticated, service_role;

create index orbita_orders_admin_recent_history
  on public.orbita_orders ((coalesce(completed_at, cancelled_at)) desc, id desc)
  where status in ('completed', 'cancelled');

create function orbita_admin_private.snapshot() returns jsonb
language plpgsql volatile security definer set search_path='' as $snapshot$
declare
  payload jsonb;
begin
  -- Один снимок для проверки роли и чтения. Проверка сессии является
  -- серверной, а роли из JWT и параметры от клиента не используются.
  select case
    when orbita_mobile_private.dispatch_allowed(orbita_mobile_private.order_session_uid(), 'admin') then (
      with captured as materialized (
        select pg_catalog.clock_timestamp() as captured_at
      ), active as materialized (
        select o.id, o.status, o.created_at, o.expires_at, o.driver_id,
          pg_catalog.left(o.pickup->>'address', 120) as pickup_address,
          pg_catalog.left(o.destination->>'address', 120) as destination_address
        from public.orbita_orders o
        where o.status not in ('completed', 'cancelled')
        order by o.created_at, o.id
        limit 51
      ), history as materialized (
        select o.id, o.status, coalesce(o.completed_at, o.cancelled_at) as finished_at,
          o.cancellation_reason
        from public.orbita_orders o
        where o.status in ('completed', 'cancelled')
        order by finished_at desc, o.id desc
        limit 51
      ), queue as materialized (
        select d.driver_id, nullif(pg_catalog.btrim(p.display_name), '') as display_name,
          d.queue_position, coalesce(busy.id, offer.order_id) as order_id,
          case when busy.id is not null then 'busy'
               when offer.expires_at>c.captured_at then 'offered'
               when offer.id is not null then 'updating'
               else 'waiting' end as state,
          case when busy.id is null and offer.id is null then
            count(*) filter (where busy.id is null and offer.id is null)
              over (order by d.queue_position, d.driver_id rows unbounded preceding)
          end as queue_rank
        from orbita_mobile_private.dispatch_drivers d
        cross join captured c
        join public.orbita_profiles p on p.user_id=d.driver_id
        left join public.orbita_orders busy on busy.driver_id=d.driver_id
          and busy.status in ('accepted', 'to_pickup', 'arrived', 'riding')
        left join orbita_mobile_private.dispatch_offers offer on offer.driver_id=d.driver_id
          and offer.status='pending'
        where d.online and d.heartbeat_at>c.captured_at-interval '15 seconds'
          and orbita_mobile_private.dispatch_allowed(d.driver_id, 'driver')
        order by d.queue_position, d.driver_id
        limit 51
      )
      select pg_catalog.jsonb_build_object(
        'contract_version', 1,
        'captured_at', c.captured_at,
        'active_orders', coalesce((
          select pg_catalog.jsonb_agg(
            pg_catalog.to_jsonb(a) order by a.created_at, a.id)
          from (select * from active order by created_at, id limit 50) a
        ), '[]'::jsonb),
        'history', coalesce((
          select pg_catalog.jsonb_agg(
            pg_catalog.to_jsonb(h) order by h.finished_at desc, h.id desc)
          from (select * from history order by finished_at desc, id desc limit 50) h
        ), '[]'::jsonb),
        'queue', coalesce((
          select pg_catalog.jsonb_agg(
            pg_catalog.to_jsonb(q)-'queue_position' order by q.queue_position, q.driver_id)
          from (select * from queue order by queue_position, driver_id limit 50) q
        ), '[]'::jsonb),
        'truncated', pg_catalog.jsonb_build_object(
          'active_orders', (select count(*) from active)>50,
          'history', (select count(*) from history)>50,
          'queue', (select count(*) from queue)>50
        )
      ) from captured c
    )
  end into payload;

  if payload is null then
    raise exception using errcode='42501', message='ORB_ADMIN_FORBIDDEN';
  end if;
  return payload;
end
$snapshot$;

-- Не публиковать orbita_admin_private. Здесь нет SECURITY DEFINER.
create function orbita_admin_api.snapshot() returns jsonb
language sql volatile security invoker set search_path='' as $$
  select orbita_admin_private.snapshot()
$$;

revoke all on function orbita_admin_private.snapshot(), orbita_admin_api.snapshot()
  from public, anon, authenticated, service_role;
grant usage on schema orbita_admin_private, orbita_admin_api to authenticated;
grant execute on function orbita_admin_private.snapshot(), orbita_admin_api.snapshot() to authenticated;
