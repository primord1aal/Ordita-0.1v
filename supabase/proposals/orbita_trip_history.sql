-- Standalone proposal. Apply only after a protected review against the four
-- previously applied migrations. This read surface does not run dispatch_tick.
create schema orbita_trip_history_private;
revoke all on schema orbita_trip_history_private from public, anon, authenticated, service_role;
grant usage on schema orbita_trip_history_private to authenticated;

create index orbita_orders_passenger_history
  on public.orbita_orders(passenger_id, created_at desc, id desc)
  where status in ('completed', 'cancelled');
create index orbita_orders_driver_history
  on public.orbita_orders(driver_id, created_at desc, id desc)
  where status in ('completed', 'cancelled') and driver_id is not null;

create function orbita_trip_history_private.read_page(
  p_role text,
  p_before_at timestamptz,
  p_before_id uuid,
  p_status text
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid;
  v_history jsonb;
  v_has_more boolean;
begin
  v_user := orbita_mobile_private.order_session_uid();
  if p_role is null or p_role not in ('passenger', 'driver')
     or not orbita_mobile_private.dispatch_allowed(v_user, p_role) then
    raise exception using errcode = '42501', message = 'ORB_DISPATCH_FORBIDDEN';
  end if;

  if (p_status is not null and p_status not in ('completed', 'cancelled'))
     or (p_before_at is null) <> (p_before_id is null)
     or (p_before_at is not null and not pg_catalog.isfinite(p_before_at)) then
    raise exception using errcode = '22023', message = 'ORB_DISPATCH_INVALID';
  end if;

  with matching as (
    select o.id, o.status, o.created_at, o.completed_at, o.cancelled_at,
           o.pickup->>'address' as pickup_address, o.destination->>'address' as destination_address
    from public.orbita_orders o
    where p_role = 'passenger' and o.passenger_id = v_user
      and o.status in ('completed', 'cancelled')
      and (p_status is null or o.status = p_status)
      and (p_before_at is null or (o.created_at, o.id) < (p_before_at, p_before_id))
    union all
    select o.id, o.status, o.created_at, o.completed_at, o.cancelled_at,
           o.pickup->>'address' as pickup_address, o.destination->>'address' as destination_address
    from public.orbita_orders o
    where p_role = 'driver' and o.driver_id = v_user and o.driver_id is not null
      and o.status in ('completed', 'cancelled')
      and (p_status is null or o.status = p_status)
      and (p_before_at is null or (o.created_at, o.id) < (p_before_at, p_before_id))
  ),
  page as (
    select * from matching order by created_at desc, id desc limit 31
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', item.id,
      'status', item.status,
      'created_at', item.created_at,
      'finished_at', coalesce(item.completed_at, item.cancelled_at),
      'pickup_address', item.pickup_address,
      'destination_address', item.destination_address
    ) order by item.created_at desc, item.id desc), '[]'::jsonb),
    (select count(*) > 30 from page)
  into v_history, v_has_more
  from (select * from page order by created_at desc, id desc limit 30) item;

  return jsonb_build_object('contract_version', 1, 'user_id', v_user,
    'role', p_role, 'items', v_history, 'has_more', v_has_more);
end;
$$;

create function public.orbita_order_history(
  p_role text,
  p_before_at timestamptz default null,
  p_before_id uuid default null,
  p_status text default null
) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select orbita_trip_history_private.read_page(p_role, p_before_at, p_before_id, p_status);
$$;

revoke all on function orbita_trip_history_private.read_page(text, timestamptz, uuid, text),
  public.orbita_order_history(text, timestamptz, uuid, text) from public, anon, authenticated, service_role;
grant execute on function orbita_trip_history_private.read_page(text, timestamptz, uuid, text),
  public.orbita_order_history(text, timestamptz, uuid, text) to authenticated;
