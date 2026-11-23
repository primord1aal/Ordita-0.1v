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
begin
  -- An idle project should not rewrite the access mutex on every timer interval.
  if not exists (select 1 from public.orbita_orders where status='created')
     and not exists (select 1 from orbita_mobile_private.dispatch_offers where status='pending')
     and not exists (select 1 from orbita_mobile_private.dispatch_drivers where online) then
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
