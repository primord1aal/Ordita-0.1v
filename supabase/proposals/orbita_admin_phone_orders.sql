-- Local proposal after Maps, the admin read model, and admin operations.
-- Apply as a single transaction in the separately authorized environment.
do $preflight$
begin
  if current_user <> 'postgres'
     or to_regclass('orbita_admin_private.operation_audit') is null
     or to_regprocedure('public.orbita_map_budget(uuid,integer)') is null
     or to_regprocedure('orbita_mobile_private.dispatch_tick()') is null
     or md5(pg_get_functiondef(to_regprocedure('public.orbita_create_order(uuid,jsonb,jsonb)')))
        is distinct from '0723d81630976e7be2fd9e8605feef51' then
    raise exception 'ORB_PHONE_ORDER_PREFLIGHT';
  end if;
end
$preflight$;

-- Shared order creation retains the original v1 validation and replay rules.
-- Both entry points must authenticate the actor and hold the access mutex.
create function orbita_mobile_private.order_create_for_passenger(
  p_passenger_id uuid, p_request_id uuid, p_pickup jsonb, p_destination jsonb
) returns jsonb
language plpgsql volatile security invoker set search_path='' as $create$
declare
  v_pickup jsonb;
  v_destination jsonb;
  v_order public.orbita_orders;
  v_now timestamptz;
begin
  if p_request_id is null then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  v_pickup := orbita_mobile_private.order_point(p_pickup);
  v_destination := orbita_mobile_private.order_point(p_destination);
  if v_pickup->'latitude' = v_destination->'latitude'
     and v_pickup->'longitude' = v_destination->'longitude' then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  select * into v_order from public.orbita_orders
    where passenger_id = p_passenger_id and request_id = p_request_id;
  if found then
    if v_order.pickup <> v_pickup or v_order.destination <> v_destination then
      raise exception using errcode='P0001', message='ORB_ORDER_IDEMPOTENCY_CONFLICT';
    end if;
    return orbita_mobile_private.order_envelope(v_order, pg_catalog.clock_timestamp());
  end if;
  if not orbita_mobile_private.dispatch_allowed(p_passenger_id, 'passenger') then
    raise exception using errcode='42501', message='ORB_ORDER_CREATE_FORBIDDEN';
  end if;
  v_now := pg_catalog.clock_timestamp();
  update public.orbita_orders set status='cancelled', cancellation_reason='search_timeout',
    cancelled_at=expires_at, version=2
    where passenger_id=p_passenger_id and status='created' and expires_at<=v_now;
  if exists (select 1 from public.orbita_orders where passenger_id=p_passenger_id and status='created') then
    raise exception using errcode='P0001', message='ORB_ORDER_ACTIVE_EXISTS';
  end if;
  v_now := pg_catalog.clock_timestamp();
  insert into public.orbita_orders(passenger_id, request_id, pickup, destination, created_at, expires_at)
    values (p_passenger_id, p_request_id, v_pickup, v_destination, v_now, v_now + interval '5 minutes')
    returning * into v_order;
  return orbita_mobile_private.order_envelope(v_order, v_now);
end
$create$;

revoke all on function orbita_mobile_private.order_create_for_passenger(uuid, uuid, jsonb, jsonb)
  from public, anon, authenticated, service_role;

create or replace function public.orbita_create_order(
  p_request_id uuid, p_pickup jsonb, p_destination jsonb
) returns jsonb
language plpgsql volatile security definer set search_path='' as $mobile$
declare
  v_passenger_id uuid;
begin
  perform orbita_mobile_private.lock_access();
  v_passenger_id := orbita_mobile_private.order_session_uid();
  return orbita_mobile_private.order_create_for_passenger(
    v_passenger_id, p_request_id, p_pickup, p_destination
  );
end
$mobile$;

create function orbita_admin_private.create_phone_order(
  p_passenger_id uuid, p_request_id uuid, p_pickup jsonb, p_destination jsonb
) returns jsonb
language plpgsql volatile security definer set search_path='' as $phone$
declare
  v_actor uuid;
  v_audit orbita_admin_private.operation_audit;
  v_existing public.orbita_orders;
  v_order jsonb;
begin
  perform orbita_mobile_private.lock_access();
  v_actor := orbita_mobile_private.order_session_uid();
  if not orbita_mobile_private.dispatch_allowed(v_actor, 'admin') then
    raise exception using errcode='42501', message='ORB_ADMIN_FORBIDDEN';
  end if;
  if p_passenger_id is null or p_request_id is null then
    raise exception 'ORB_ORDER_INVALID_REQUEST';
  end if;
  if not orbita_mobile_private.dispatch_allowed(p_passenger_id, 'passenger') then
    raise exception using errcode='22023', message='ORB_ORDER_CREATE_FORBIDDEN';
  end if;

  select * into v_audit from orbita_admin_private.operation_audit
    where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_audit.action <> 'phone_order' then
      raise exception using errcode='23505', message='ORB_ORDER_IDEMPOTENCY_CONFLICT';
    end if;
    select * into v_existing from public.orbita_orders where id = v_audit.target_id;
    if not found or v_existing.passenger_id <> p_passenger_id
       or v_existing.pickup <> orbita_mobile_private.order_point(p_pickup)
       or v_existing.destination <> orbita_mobile_private.order_point(p_destination) then
      raise exception using errcode='23505', message='ORB_ORDER_IDEMPOTENCY_CONFLICT';
    end if;
    v_order := orbita_mobile_private.order_envelope(v_existing, pg_catalog.clock_timestamp())->'order';
  else
    perform orbita_mobile_private.dispatch_tick();
    if exists (
      select 1 from public.orbita_orders
      where passenger_id = p_passenger_id and status not in ('completed', 'cancelled')
    ) then
      raise exception using errcode='23505', message='ORB_ORDER_ACTIVE_EXISTS';
    end if;

    -- The journal and the passenger's own request space use separate keys.
    v_order := orbita_mobile_private.order_create_for_passenger(
      p_passenger_id, pg_catalog.gen_random_uuid(), p_pickup, p_destination
    )->'order';
    perform orbita_mobile_private.dispatch_tick();
    insert into orbita_admin_private.operation_audit(actor_id, request_id, action, target_id)
      values (v_actor, p_request_id, 'phone_order', (v_order->>'id')::uuid);
  end if;
  return pg_catalog.jsonb_build_object(
    'order_id', v_order->>'id', 'status', v_order->>'status', 'expires_at', v_order->>'expires_at'
  );
end
$phone$;

create function orbita_admin_api.create_phone_order(
  p_passenger_id uuid, p_request_id uuid, p_pickup jsonb, p_destination jsonb
) returns jsonb
language sql volatile security invoker set search_path='' as $api$
  select orbita_admin_private.create_phone_order(p_passenger_id, p_request_id, p_pickup, p_destination)
$api$;

revoke all on function
  orbita_admin_private.create_phone_order(uuid, uuid, jsonb, jsonb),
  orbita_admin_api.create_phone_order(uuid, uuid, jsonb, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function
  orbita_admin_private.create_phone_order(uuid, uuid, jsonb, jsonb),
  orbita_admin_api.create_phone_order(uuid, uuid, jsonb, jsonb)
  to authenticated;
