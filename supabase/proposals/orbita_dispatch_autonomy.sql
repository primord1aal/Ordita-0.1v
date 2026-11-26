-- Isolated candidate. The scheduler is configured separately after rehearsal.
do $preflight$
begin
  if current_user <> 'postgres'
     or to_regprocedure('orbita_mobile_private.dispatch_tick()') is null
     or to_regprocedure('public.orbita_map_budget(uuid,integer)') is null then
    raise exception 'ORB_AUTONOMY_PREFLIGHT';
  end if;
end
$preflight$;

create function orbita_mobile_private.dispatch_scheduled_tick() returns boolean
language plpgsql volatile security invoker set search_path='' as $tick$
declare
  v_now timestamptz := clock_timestamp();
begin
  -- Readiness check for the fixed Dispatch migration. Actual transitions and
  -- queue ordering remain in dispatch_tick(), under the shared access mutex.
  if not (
    exists (
      select 1 from public.orbita_orders
      where status = 'created' and expires_at <= v_now
    ) or exists (
      select 1 from orbita_mobile_private.dispatch_drivers d
      where d.online and (d.heartbeat_at <= v_now - interval '15 seconds'
        or not orbita_mobile_private.dispatch_allowed(d.driver_id, 'driver'))
    ) or exists (
      select 1 from orbita_mobile_private.dispatch_offers f
      join public.orbita_orders o on o.id = f.order_id
      join orbita_mobile_private.dispatch_drivers d on d.driver_id = f.driver_id
      where f.status = 'pending'
        and (f.expires_at <= v_now or o.status <> 'created' or not d.online)
    ) or exists (
      select 1 from public.orbita_orders o
      where o.status = 'created' and not exists (
        select 1 from orbita_mobile_private.dispatch_offers f
        where f.order_id = o.id and f.status = 'pending'
      ) and exists (
        select 1 from orbita_mobile_private.dispatch_drivers d
        where d.online and d.heartbeat_at > v_now - interval '15 seconds'
          and orbita_mobile_private.dispatch_allowed(d.driver_id, 'driver')
          and not exists (
            select 1 from public.orbita_orders busy
            where busy.driver_id = d.driver_id
              and busy.status in ('accepted', 'to_pickup', 'arrived', 'riding')
          ) and not exists (
            select 1 from orbita_mobile_private.dispatch_offers f
            where f.driver_id = d.driver_id
              and (f.status = 'pending' or f.order_id = o.id)
          )
      )
    )
  ) then
    return false;
  end if;

  begin
    perform 1 from orbita_mobile_private.access_mutex where singleton for update nowait;
    -- Use the same revision update as the client RPC and operator access changes.
    perform orbita_mobile_private.lock_access();
    perform orbita_mobile_private.dispatch_tick();
    return true;
  exception when lock_not_available then
    -- Let the in-flight transaction finish; the next interval will check again.
    return false;
  end;
end
$tick$;

revoke all on function orbita_mobile_private.dispatch_scheduled_tick()
  from public, anon, authenticated, service_role;
