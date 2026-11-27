-- Local candidate for one transaction after Maps and the admin read model.
do $preflight$
begin
  if current_user <> 'postgres'
     or to_regprocedure('orbita_admin_private.snapshot()') is null
     or to_regprocedure('orbita_mobile_private.lock_access()') is null
     or to_regprocedure('public.orbita_map_budget(uuid,integer)') is null then
    raise exception 'ORB_ADMIN_OPERATIONS_PREFLIGHT';
  end if;
end
$preflight$;

create table orbita_admin_private.driver_restrictions (
  driver_id uuid primary key references public.orbita_profiles(user_id) on delete cascade
);

create table orbita_admin_private.operation_audit (
  actor_id uuid not null,
  request_id uuid not null,
  action text not null,
  target_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  details jsonb not null default '{}'::jsonb,
  primary key (actor_id, request_id),
  check (
    (action = 'driver_restriction' and details in ('{"restricted":true}'::jsonb, '{"restricted":false}'::jsonb))
    or (action = 'phone_order' and details = '{}'::jsonb)
  )
);

create index operation_audit_recent
  on orbita_admin_private.operation_audit (created_at desc, actor_id, request_id);

alter table orbita_admin_private.driver_restrictions enable row level security;
alter table orbita_admin_private.operation_audit enable row level security;
revoke all on orbita_admin_private.driver_restrictions, orbita_admin_private.operation_audit
  from public, anon, authenticated, service_role;

-- Dispatch commands already run under the access mutex. Keep the existing
-- contract and return the actual line state when a new shift cannot start.
create function orbita_admin_private.guard_driver_shift() returns trigger
language plpgsql security invoker set search_path = '' as $guard$
begin
  if new.online and not old.online and exists (
    select 1 from orbita_admin_private.driver_restrictions r where r.driver_id = new.driver_id
  ) then
    new.online := false;
    new.queue_position := old.queue_position;
  end if;
  return new;
end
$guard$;

create trigger guard_driver_shift
  before update of online on orbita_mobile_private.dispatch_drivers
  for each row when (new.online and not old.online)
  execute function orbita_admin_private.guard_driver_shift();

-- Close a restricted driver's line in the completion transaction, before
-- dispatch_tick can assign its next offer. The accepted trip progresses normally.
create function orbita_admin_private.close_restricted_driver_shift() returns trigger
language plpgsql security invoker set search_path = '' as $close$
begin
  update orbita_mobile_private.dispatch_drivers d
  set online = false
  where d.driver_id = new.driver_id and d.online and exists (
    select 1 from orbita_admin_private.driver_restrictions r where r.driver_id = d.driver_id
  );
  return new;
end
$close$;

create trigger close_restricted_driver_shift
  after update of status on public.orbita_orders
  for each row when (old.status = 'riding' and new.status = 'completed')
  execute function orbita_admin_private.close_restricted_driver_shift();

create function orbita_admin_private.set_driver_restriction(
  p_request_id uuid, p_driver_id uuid, p_restricted boolean
) returns jsonb language plpgsql volatile security definer set search_path = '' as $restrict$
declare
  v_actor uuid;
  v_receipt orbita_admin_private.operation_audit;
  v_details jsonb;
begin
  perform orbita_mobile_private.lock_access();
  v_actor := orbita_mobile_private.order_session_uid();
  if not orbita_mobile_private.dispatch_allowed(v_actor, 'admin') then
    raise exception using errcode = '42501', message = 'ORB_ADMIN_FORBIDDEN';
  end if;
  if p_request_id is null or p_driver_id is null or p_restricted is null then
    raise exception using errcode = '22023', message = 'ORB_ADMIN_INVALID';
  end if;

  v_details := jsonb_build_object('restricted', p_restricted);
  select * into v_receipt from orbita_admin_private.operation_audit
  where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_receipt.action <> 'driver_restriction'
       or v_receipt.target_id <> p_driver_id or v_receipt.details <> v_details then
      raise exception using errcode = '22023', message = 'ORB_ADMIN_REQUEST_CONFLICT';
    end if;
    return jsonb_build_object('driver_id', p_driver_id, 'restricted', p_restricted);
  end if;

  if not exists (
    select 1 from public.orbita_user_roles r
    where r.user_id = p_driver_id and r.role = 'driver'
  ) then
    raise exception 'ORB_ADMIN_DRIVER_NOT_FOUND';
  end if;

  if p_restricted then
    insert into orbita_admin_private.driver_restrictions (driver_id)
      values (p_driver_id) on conflict do nothing;
    update orbita_mobile_private.dispatch_drivers d set online = false
      where d.driver_id = p_driver_id and d.online and not exists (
        select 1 from public.orbita_orders o where o.driver_id = p_driver_id
          and o.status in ('accepted', 'to_pickup', 'arrived', 'riding')
      );
    -- This is an operator restriction, not a refusal or a missed offer.
    update orbita_mobile_private.dispatch_offers set status = 'cancelled'
      where driver_id = p_driver_id and status = 'pending';
    perform orbita_mobile_private.dispatch_tick();
  else
    delete from orbita_admin_private.driver_restrictions where driver_id = p_driver_id;
  end if;

  insert into orbita_admin_private.operation_audit
    (actor_id, request_id, action, target_id, details)
    values (v_actor, p_request_id, 'driver_restriction', p_driver_id, v_details);
  return jsonb_build_object('driver_id', p_driver_id, 'restricted', p_restricted);
end
$restrict$;

create function orbita_admin_private.operations() returns jsonb
language plpgsql volatile security definer set search_path = '' as $operations$
declare
  v_result jsonb;
begin
  -- Check the session and role in the same snapshot as the bounded read.
  select case
    when orbita_mobile_private.dispatch_allowed(orbita_mobile_private.order_session_uid(), 'admin') then (
      with captured as materialized (
        select clock_timestamp() as captured_at
      ), drivers as materialized (
        select p.user_id as driver_id, nullif(btrim(p.display_name), '') as display_name,
          coalesce(d.online and d.heartbeat_at > c.captured_at - interval '15 seconds'
            and not a.is_blocked, false) as online,
          r.driver_id is not null as restricted,
          busy.id as active_order_id
        from public.orbita_user_roles roles
        join public.orbita_profiles p on p.user_id = roles.user_id
        join public.orbita_account_access a on a.user_id = p.user_id
        cross join captured c
        left join orbita_mobile_private.dispatch_drivers d on d.driver_id = p.user_id
        left join orbita_admin_private.driver_restrictions r on r.driver_id = p.user_id
        left join public.orbita_orders busy on busy.driver_id = p.user_id
          and busy.status in ('accepted', 'to_pickup', 'arrived', 'riding')
        where roles.role = 'driver'
        order by online desc, driver_id
        limit 51
      ), audit as materialized (
        select actor_id, request_id, action, target_id, created_at, details
        from orbita_admin_private.operation_audit
        order by created_at desc, actor_id, request_id
        limit 51
      )
      select jsonb_build_object(
        'contract_version', 1,
        'captured_at', c.captured_at,
        'phone_orders_enabled', coalesce(has_function_privilege(
          'authenticated',
          to_regprocedure('orbita_admin_api.create_phone_order(uuid,uuid,jsonb,jsonb)'),
          'EXECUTE'
        ), false),
        'drivers', coalesce((
          select jsonb_agg(to_jsonb(d) order by online desc, driver_id)
          from (select * from drivers order by online desc, driver_id limit 50) d
        ), '[]'::jsonb),
        'audit', coalesce((
          select jsonb_agg(to_jsonb(a) order by created_at desc, actor_id, request_id)
          from (select * from audit order by created_at desc, actor_id, request_id limit 50) a
        ), '[]'::jsonb),
        'truncated', jsonb_build_object(
          'drivers', (select count(*) from drivers) > 50,
          'audit', (select count(*) from audit) > 50
        )
      ) from captured c
    )
  end into v_result;
  if v_result is null then
    raise exception using errcode = '42501', message = 'ORB_ADMIN_FORBIDDEN';
  end if;
  return v_result;
end
$operations$;

create function orbita_admin_api.set_driver_restriction(
  p_request_id uuid, p_driver_id uuid, p_restricted boolean
) returns jsonb language sql volatile security invoker set search_path = '' as $$
  select orbita_admin_private.set_driver_restriction(p_request_id, p_driver_id, p_restricted)
$$;

create function orbita_admin_api.operations() returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select orbita_admin_private.operations()
$$;

revoke all on function
  orbita_admin_private.guard_driver_shift(),
  orbita_admin_private.close_restricted_driver_shift(),
  orbita_admin_private.set_driver_restriction(uuid, uuid, boolean),
  orbita_admin_private.operations(),
  orbita_admin_api.set_driver_restriction(uuid, uuid, boolean),
  orbita_admin_api.operations()
from public, anon, authenticated, service_role;
grant execute on function
  orbita_admin_private.set_driver_restriction(uuid, uuid, boolean),
  orbita_admin_private.operations(),
  orbita_admin_api.set_driver_restriction(uuid, uuid, boolean),
  orbita_admin_api.operations()
to authenticated;
