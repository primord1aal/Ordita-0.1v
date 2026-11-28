-- Standalone proposal after Maps Apply. Holds only the latest active-trip fix.
create schema orbita_trip_location_private;
revoke all on schema orbita_trip_location_private from public, anon, authenticated, service_role;
grant usage on schema orbita_trip_location_private to authenticated;

create table orbita_trip_location_private.latest (
  order_id uuid primary key references public.orbita_orders(id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters double precision not null check (accuracy_meters between 0 and 100),
  captured_at timestamptz not null
);
alter table orbita_trip_location_private.latest enable row level security;
revoke all on orbita_trip_location_private.latest from public, anon, authenticated, service_role;

create function orbita_trip_location_private.exchange(p_order_id uuid, p_fix jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := orbita_mobile_private.order_session_uid();
  v_order public.orbita_orders;
  v_fix orbita_trip_location_private.latest;
  v_now timestamptz := clock_timestamp();
  v_age double precision;
begin
  if p_fix is not null then
    if not orbita_mobile_private.dispatch_allowed(v_user, 'driver') then
      raise exception using errcode='42501', message='ORB_DISPATCH_FORBIDDEN';
    end if;
    -- Shares the order row with other location updates but conflicts with a
    -- terminal transition, whose trigger deletes the location.
    select * into v_order from public.orbita_orders
    where id=p_order_id and driver_id=v_user
      and status in ('accepted','to_pickup','arrived','riding')
    for share;
    if not found or not orbita_mobile_private.dispatch_allowed(v_order.passenger_id, 'passenger') then
      raise exception using errcode='42501', message='ORB_DISPATCH_NOT_FOUND';
    end if;
    if jsonb_typeof(p_fix) <> 'object' or jsonb_typeof(p_fix->'latitude') is distinct from 'number'
        or jsonb_typeof(p_fix->'longitude') is distinct from 'number'
        or jsonb_typeof(p_fix->'accuracy_meters') is distinct from 'number'
        or jsonb_typeof(p_fix->'captured_at') is distinct from 'string' then
      raise exception using errcode='22023', message='ORB_DISPATCH_INVALID';
    end if;
    v_fix := jsonb_populate_record(null::orbita_trip_location_private.latest, p_fix - 'order_id');
    if not (v_fix.captured_at between v_now - interval '30 seconds' and v_now + interval '5 seconds') then
      raise exception using errcode='22023', message='ORB_DISPATCH_INVALID';
    end if;
    insert into orbita_trip_location_private.latest as location
      (order_id,latitude,longitude,accuracy_meters,captured_at)
    values (p_order_id,v_fix.latitude,v_fix.longitude,v_fix.accuracy_meters,v_fix.captured_at)
    on conflict (order_id) do update set latitude=excluded.latitude, longitude=excluded.longitude,
      accuracy_meters=excluded.accuracy_meters,captured_at=excluded.captured_at
    where excluded.captured_at > location.captured_at;
    return jsonb_build_object('order_id',p_order_id,'accepted',true);
  end if;

  if not orbita_mobile_private.dispatch_allowed(v_user, 'passenger') then
    raise exception using errcode='42501', message='ORB_DISPATCH_FORBIDDEN';
  end if;
  select * into v_order from public.orbita_orders
  where id=p_order_id and passenger_id=v_user and driver_id is not null
    and status in ('accepted','to_pickup','arrived','riding');
  if not found or not orbita_mobile_private.dispatch_allowed(v_order.driver_id, 'driver') then
    raise exception using errcode='42501', message='ORB_DISPATCH_NOT_FOUND';
  end if;
  select * into v_fix from orbita_trip_location_private.latest
  where order_id=p_order_id and captured_at >= v_now - interval '2 minutes';
  v_age := greatest(0, extract(epoch from v_now - v_fix.captured_at));
  return jsonb_build_object('order_id',p_order_id,'fix',case when v_fix.order_id is not null then
    jsonb_build_object('latitude',v_fix.latitude,'longitude',v_fix.longitude,
      'age_seconds',ceil(v_age),'captured_at',v_fix.captured_at) else null end);
end;
$$;

create function orbita_trip_location_private.clear_terminal() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from orbita_trip_location_private.latest where order_id=new.id;
  return null;
end;
$$;
create trigger orbita_trip_location_ended after update of status, driver_id on public.orbita_orders
for each row when (new.status in ('completed','cancelled') or old.driver_id is distinct from new.driver_id)
execute function orbita_trip_location_private.clear_terminal();

create function public.orbita_trip_location(p_order_id uuid, p_fix jsonb default null)
returns jsonb language sql security invoker set search_path = '' as $$
  select orbita_trip_location_private.exchange(p_order_id,p_fix);
$$;

revoke all on function orbita_trip_location_private.exchange(uuid,jsonb),
  orbita_trip_location_private.clear_terminal(),
  public.orbita_trip_location(uuid,jsonb) from public, anon, authenticated, service_role;
grant execute on function orbita_trip_location_private.exchange(uuid,jsonb),
  public.orbita_trip_location(uuid,jsonb) to authenticated;
