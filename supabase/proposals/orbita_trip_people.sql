-- Standalone proposal. Vehicle records are maintained by authenticated admins.
create schema orbita_trip_people_private;
revoke all on schema orbita_trip_people_private from public, anon, authenticated, service_role;
grant usage on schema orbita_trip_people_private to authenticated;

create table orbita_trip_people_private.vehicles (
  driver_id uuid primary key references public.orbita_profiles(user_id) on delete cascade,
  make text not null check (char_length(make) between 1 and 48),
  model text not null check (char_length(model) between 1 and 48),
  color text not null check (char_length(color) between 1 and 32),
  plate text not null check (plate ~ '^[A-ZА-Я0-9 -]{4,16}$'),
  confirmed_at timestamptz not null default clock_timestamp()
);
alter table orbita_trip_people_private.vehicles enable row level security;
revoke all on orbita_trip_people_private.vehicles from public, anon, authenticated, service_role;

create function orbita_trip_people_private.vehicle(p_driver uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('make',v.make,'model',v.model,'color',v.color,'plate',v.plate)
  from orbita_trip_people_private.vehicles v where v.driver_id=p_driver;
$$;

create function orbita_trip_people_private.details(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid := orbita_mobile_private.order_session_uid();
  v_peer uuid;
  v_peer_name text;
  v_is_passenger boolean;
begin
  select case when o.passenger_id=v_actor then o.driver_id else o.passenger_id end,
         o.passenger_id=v_actor
  into v_peer,v_is_passenger
  from public.orbita_orders o
  where o.id=p_order and o.driver_id is not null
    and o.status in ('accepted','to_pickup','arrived','riding')
    and (o.passenger_id=v_actor or o.driver_id=v_actor);
  if not found
    or not orbita_mobile_private.dispatch_allowed(v_actor, case when v_is_passenger then 'passenger' else 'driver' end)
    or not orbita_mobile_private.dispatch_allowed(v_peer, case when v_is_passenger then 'driver' else 'passenger' end) then
    raise exception using errcode='42501',message='ORB_DISPATCH_NOT_FOUND';
  end if;
  select nullif(btrim(p.display_name),'') into v_peer_name
  from public.orbita_profiles p where p.user_id=v_peer;
  return jsonb_build_object('order_id',p_order,'display_name',v_peer_name,
    'vehicle',case when v_is_passenger then orbita_trip_people_private.vehicle(v_peer) else null end);
end;
$$;

create function orbita_trip_people_private.own_vehicle()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid := orbita_mobile_private.order_session_uid();
begin
  if not orbita_mobile_private.dispatch_allowed(v_actor,'driver') then
    raise exception using errcode='42501', message='ORB_DISPATCH_FORBIDDEN';
  end if;
  return jsonb_build_object('user_id',v_actor,'vehicle',orbita_trip_people_private.vehicle(v_actor));
end;
$$;

create function orbita_trip_people_private.edit_vehicle(p_driver uuid,p_vehicle jsonb)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_make text;
  v_model text;
  v_color text;
  v_plate text;
begin
  perform orbita_mobile_private.lock_access();
  v_actor := orbita_mobile_private.order_session_uid();
  if not orbita_mobile_private.dispatch_allowed(v_actor,'admin') then
    raise exception using errcode='42501', message='ORB_DISPATCH_FORBIDDEN';
  end if;
  if not orbita_mobile_private.dispatch_allowed(p_driver,'driver') then
    raise exception using errcode='42501', message='ORB_DISPATCH_NOT_FOUND';
  end if;
  if p_vehicle is null then
    delete from orbita_trip_people_private.vehicles where driver_id=p_driver;
    return true;
  end if;
  if jsonb_typeof(p_vehicle) <> 'object'
    or jsonb_typeof(p_vehicle->'make') is distinct from 'string'
    or jsonb_typeof(p_vehicle->'model') is distinct from 'string'
    or jsonb_typeof(p_vehicle->'color') is distinct from 'string'
    or jsonb_typeof(p_vehicle->'plate') is distinct from 'string' then
    raise exception using errcode='22023', message='ORB_DISPATCH_INVALID';
  end if;
  v_make := btrim(p_vehicle->>'make');
  v_model := btrim(p_vehicle->>'model');
  v_color := btrim(p_vehicle->>'color');
  v_plate := upper(btrim(p_vehicle->>'plate'));
  insert into orbita_trip_people_private.vehicles as target (driver_id,make,model,color,plate)
  values (p_driver,v_make,v_model,v_color,v_plate)
  on conflict (driver_id) do update set make=excluded.make, model=excluded.model,
    color=excluded.color, plate=excluded.plate, confirmed_at=clock_timestamp();
  return true;
end;
$$;

create function public.orbita_trip_peer(p_order uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select orbita_trip_people_private.details(p_order);
$$;
create function public.orbita_my_vehicle()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select orbita_trip_people_private.own_vehicle();
$$;
create function public.orbita_admin_set_vehicle(p_driver uuid,p_vehicle jsonb)
returns boolean language sql security invoker set search_path = '' as $$
  select orbita_trip_people_private.edit_vehicle(p_driver,p_vehicle);
$$;

revoke all on function orbita_trip_people_private.vehicle(uuid),
  orbita_trip_people_private.details(uuid), orbita_trip_people_private.own_vehicle(),
  orbita_trip_people_private.edit_vehicle(uuid,jsonb), public.orbita_trip_peer(uuid),
  public.orbita_my_vehicle(), public.orbita_admin_set_vehicle(uuid,jsonb)
from public, anon, authenticated, service_role;
grant execute on function orbita_trip_people_private.details(uuid),
  orbita_trip_people_private.own_vehicle(), orbita_trip_people_private.edit_vehicle(uuid,jsonb),
  public.orbita_trip_peer(uuid), public.orbita_my_vehicle(),
  public.orbita_admin_set_vehicle(uuid,jsonb) to authenticated;
