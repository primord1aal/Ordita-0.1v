-- Apply once, in a transaction, after the two already applied migrations.
-- No Auth changes, cron, external calls, or writes to existing accounts/roles.
do $$ begin
  if current_user <> 'postgres' or to_regclass('public.orbita_orders') is null
     or to_regclass('orbita_mobile_private.dispatch_drivers') is not null then
    raise exception 'ORB_DISPATCH_PREFLIGHT';
  end if;
  -- Fail closed if any touched v1 RPC/helper has drifted since read-only Preview.
  if (select count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join (values
        ('public','orbita_create_order','0723d81630976e7be2fd9e8605feef51'),
        ('public','orbita_get_current_order','d85bd2a1c06ed3c21081f7d83c54b0c4'),
        ('public','orbita_get_order','aa5269cce37df55689c437be05d382d2'),
        ('public','orbita_cancel_order','424bcafd58f283cc287a66facbc0142d'),
        ('orbita_mobile_private','lock_access','51197e1d155e127cd6e1f986a3843d4f'),
        ('orbita_mobile_private','order_session_uid','78f479da3143e22374f6a0fe3ca2adf5')
      ) as expected(schema_name,function_name,definition_md5)
      on n.nspname=expected.schema_name and p.proname=expected.function_name
      and md5(pg_get_functiondef(p.oid))=expected.definition_md5) <> 6 then
    raise exception 'ORB_DISPATCH_SCHEMA_DRIFT';
  end if;
end $$;

alter table public.orbita_orders
  drop constraint orbita_orders_status_check,
  drop constraint orbita_orders_check2,
  add column driver_id uuid references public.orbita_profiles(user_id),
  add column completed_at timestamptz,
  add constraint orbita_orders_status_check check
    (status in ('created','cancelled','accepted','to_pickup','arrived','riding','completed')),
  add constraint orbita_orders_dispatch_state check (
    (status='created' and driver_id is null and cancellation_reason is null
      and cancelled_at is null and completed_at is null and version=1)
    or (status='cancelled' and driver_id is null and cancellation_reason is not null
      and cancelled_at is not null and completed_at is null and version=2
      and ((cancellation_reason='search_timeout' and cancelled_at=expires_at)
        or (cancellation_reason='passenger' and cancelled_at<expires_at)))
    or (status in ('accepted','to_pickup','arrived','riding','completed')
      and driver_id is not null and cancellation_reason is null and cancelled_at is null
      and version>=2 and ((status='completed')=(completed_at is not null)))
  );
-- Also protects old v1 create callers while a passenger is riding.
create unique index orbita_orders_one_active_passenger on public.orbita_orders(passenger_id)
  where status not in ('cancelled','completed');
create unique index orbita_orders_one_active_driver on public.orbita_orders(driver_id)
  where status in ('accepted','to_pickup','arrived','riding');
create index orbita_orders_dispatch_search on public.orbita_orders(created_at,id) where status='created';

create sequence orbita_mobile_private.dispatch_queue;
create table orbita_mobile_private.dispatch_drivers (
  driver_id uuid primary key references public.orbita_profiles(user_id) on delete cascade,
  online boolean not null default false,
  heartbeat_at timestamptz not null,
  queue_position bigint not null default nextval('orbita_mobile_private.dispatch_queue')
);
create index dispatch_available_queue on orbita_mobile_private.dispatch_drivers(queue_position) where online;
create table orbita_mobile_private.dispatch_offers (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orbita_orders(id) on delete cascade,
  driver_id uuid not null references public.orbita_profiles(user_id) on delete cascade,
  created_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null check(status in ('pending','accepted','declined','expired','cancelled')),
  unique(order_id,driver_id),
  check(expires_at>created_at and expires_at<=created_at+interval '25 seconds')
);
create unique index dispatch_one_offer_per_order on orbita_mobile_private.dispatch_offers(order_id) where status='pending';
create unique index dispatch_one_offer_per_driver on orbita_mobile_private.dispatch_offers(driver_id) where status='pending';
alter table orbita_mobile_private.dispatch_drivers enable row level security;
alter table orbita_mobile_private.dispatch_offers enable row level security;
revoke all on orbita_mobile_private.dispatch_drivers,orbita_mobile_private.dispatch_offers,
  orbita_mobile_private.dispatch_queue from public,anon,authenticated,service_role;

create function orbita_mobile_private.dispatch_allowed(p_uid uuid,p_role text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.orbita_user_roles r
    join public.orbita_account_access a using(user_id)
    join public.orbita_profiles p using(user_id)
    where r.user_id=p_uid and r.role=p_role and not a.is_blocked);
$$;

-- All callers hold the SAME access mutex as v1 cancel/create and role changes.
-- The row UPDATE mutex also rejects obsolete repeatable-read snapshots.
create function orbita_mobile_private.dispatch_tick() returns void
language plpgsql volatile security definer set search_path='' as $$
declare v_now timestamptz:=clock_timestamp(); v_offer record; v_order record; v_driver uuid;
begin
  update public.orbita_orders set status='cancelled',cancellation_reason='search_timeout',
    cancelled_at=expires_at,version=2 where status='created' and expires_at<=v_now;
  -- Passenger cancellation/search expiry preserves the offered driver's place.
  update orbita_mobile_private.dispatch_offers f set status='cancelled'
    from public.orbita_orders o where f.order_id=o.id and f.status='pending' and o.status<>'created';
  update orbita_mobile_private.dispatch_drivers d set online=false
    where d.online and (d.heartbeat_at<=v_now-interval '15 seconds'
      or not orbita_mobile_private.dispatch_allowed(d.driver_id,'driver'));
  for v_offer in select f.* from orbita_mobile_private.dispatch_offers f
    join orbita_mobile_private.dispatch_drivers d using(driver_id)
    where f.status='pending' and (f.expires_at<=v_now or not d.online)
    order by f.created_at,f.id
  loop
    update orbita_mobile_private.dispatch_offers set status='expired' where id=v_offer.id;
    update orbita_mobile_private.dispatch_drivers set queue_position=nextval('orbita_mobile_private.dispatch_queue')
      where driver_id=v_offer.driver_id;
  end loop;
  for v_order in select o.* from public.orbita_orders o where o.status='created'
    and not exists(select 1 from orbita_mobile_private.dispatch_offers f where f.order_id=o.id and f.status='pending')
    order by o.created_at,o.id
  loop
    select d.driver_id into v_driver from orbita_mobile_private.dispatch_drivers d
      where d.online and d.heartbeat_at>v_now-interval '15 seconds'
        and orbita_mobile_private.dispatch_allowed(d.driver_id,'driver')
        and not exists(select 1 from public.orbita_orders o where o.driver_id=d.driver_id
          and o.status in ('accepted','to_pickup','arrived','riding'))
        and not exists(select 1 from orbita_mobile_private.dispatch_offers f
          where f.driver_id=d.driver_id and (f.status='pending' or f.order_id=v_order.id))
      order by d.queue_position,d.driver_id limit 1;
    if v_driver is not null then
      insert into orbita_mobile_private.dispatch_offers(order_id,driver_id,created_at,expires_at,status)
        values(v_order.id,v_driver,v_now,least(v_now+interval '25 seconds',v_order.expires_at),'pending');
    end if;
  end loop;
end $$;

create function orbita_mobile_private.dispatch_snapshot(p_uid uuid,p_role text,p_outcome text) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare v_order public.orbita_orders; v_offer orbita_mobile_private.dispatch_offers; v_online boolean:=false;
begin
  if p_role='passenger' then
    select * into v_order from public.orbita_orders where passenger_id=p_uid
      order by (status not in ('cancelled','completed')) desc,created_at desc,id desc limit 1;
  else
    select online into v_online from orbita_mobile_private.dispatch_drivers where driver_id=p_uid;
    select * into v_offer from orbita_mobile_private.dispatch_offers where driver_id=p_uid and status='pending';
    select * into v_order from public.orbita_orders
      where driver_id=p_uid or id=v_offer.order_id
      order by (status not in ('cancelled','completed')) desc,created_at desc,id desc limit 1;
  end if;
  return jsonb_build_object('contract_version',2,'server_time',clock_timestamp(),'user_id',p_uid,
    'role',p_role,'outcome',p_outcome,'online',coalesce(v_online,false),
    'order',case when v_order.id is null then null else to_jsonb(v_order) end,
    'offer',case when v_offer.id is null then null else jsonb_build_object(
      'id',v_offer.id,'order_id',v_offer.order_id,'expires_at',v_offer.expires_at) end);
end $$;

-- One bounded RPC surface; client supplied IDs never establish ownership/role.
create function public.orbita_dispatch(p_action text,p_payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_uid uuid; v_role text; v_now timestamptz; v_order public.orbita_orders;
  v_offer orbita_mobile_private.dispatch_offers; v_online boolean; v_outcome text:='ok'; v_next text; v_ack uuid;
begin
  perform orbita_mobile_private.lock_access();
  v_uid:=orbita_mobile_private.order_session_uid();
  if p_action is null or p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'ORB_DISPATCH_INVALID';
  end if;
  if p_action in ('passenger_poll','create','cancel') then v_role:='passenger';
  elsif p_action in ('driver_poll','online','respond','advance') then v_role:='driver';
  else raise exception 'ORB_DISPATCH_INVALID'; end if;
  if not orbita_mobile_private.dispatch_allowed(v_uid,v_role) then
    raise exception using errcode='42501',message='ORB_DISPATCH_FORBIDDEN';
  end if;
  -- Expire old leases BEFORE heartbeat; reopening cannot silently go online.
  perform orbita_mobile_private.dispatch_tick();
  v_now:=clock_timestamp();
  if v_role='driver' then
    insert into orbita_mobile_private.dispatch_drivers(driver_id,heartbeat_at) values(v_uid,v_now)
      on conflict(driver_id) do update set heartbeat_at=excluded.heartbeat_at;
  end if;
  if p_action='create' then
    -- v1 retains canonical validation and persistent request-ID replay.
    if exists(select 1 from public.orbita_orders where passenger_id=v_uid
      and status not in ('created','cancelled','completed')
      and request_id is distinct from (p_payload->>'request_id')::uuid) then
      raise exception 'ORB_ORDER_ACTIVE_EXISTS';
    end if;
    perform public.orbita_create_order((p_payload->>'request_id')::uuid,p_payload->'pickup',p_payload->'destination');
    v_ack:=(p_payload->>'request_id')::uuid;
  elsif p_action='cancel' then
    perform public.orbita_cancel_order((p_payload->>'order_id')::uuid);
  elsif p_action='online' then
    if jsonb_typeof(p_payload->'online') is distinct from 'boolean' then raise exception 'ORB_DISPATCH_INVALID'; end if;
    v_online:=(p_payload->>'online')::boolean;
    update orbita_mobile_private.dispatch_drivers set online=v_online,
      queue_position=case when v_online and not online then nextval('orbita_mobile_private.dispatch_queue') else queue_position end
      where driver_id=v_uid;
  elsif p_action='respond' then
    if (p_payload->>'response') is null or (p_payload->>'response') not in ('accept','decline') then
      raise exception 'ORB_DISPATCH_INVALID';
    end if;
    select * into v_offer from orbita_mobile_private.dispatch_offers
      where id=(p_payload->>'offer_id')::uuid and driver_id=v_uid;
    if not found then raise exception 'ORB_DISPATCH_NOT_FOUND'; end if;
    if v_offer.status<>'pending' then v_outcome:='already_processed';
    elsif v_offer.expires_at<=clock_timestamp() then v_outcome:='stale_offer';
    else
      select * into v_order from public.orbita_orders where id=v_offer.order_id;
      if v_order.status<>'created' or v_order.expires_at<=clock_timestamp() then v_outcome:='stale_offer';
      else
        update orbita_mobile_private.dispatch_offers set status=case when p_payload->>'response'='accept' then 'accepted' else 'declined' end
          where id=v_offer.id;
        update orbita_mobile_private.dispatch_drivers set queue_position=nextval('orbita_mobile_private.dispatch_queue') where driver_id=v_uid;
        if p_payload->>'response'='accept' then
          update public.orbita_orders set driver_id=v_uid,status='accepted',version=version+1 where id=v_order.id;
        end if;
      end if;
    end if;
  elsif p_action='advance' then
    select * into v_order from public.orbita_orders where id=(p_payload->>'order_id')::uuid and driver_id=v_uid;
    if not found then raise exception 'ORB_DISPATCH_NOT_FOUND'; end if;
    v_next:=p_payload->>'status';
    if v_next is null then raise exception 'ORB_DISPATCH_INVALID'; end if;
    if v_order.status=v_next then v_outcome:='already_processed';
    elsif (v_order.status='accepted' and v_next='to_pickup')
      or (v_order.status='to_pickup' and v_next='arrived')
      or (v_order.status='arrived' and v_next='riding')
      or (v_order.status='riding' and v_next='completed') then
      update public.orbita_orders set status=v_next,version=version+1,
        completed_at=case when v_next='completed' then clock_timestamp() else null end where id=v_order.id;
    else raise exception 'ORB_ORDER_STATE_CHANGED'; end if;
  end if;
  perform orbita_mobile_private.dispatch_tick();
  return orbita_mobile_private.dispatch_snapshot(v_uid,v_role,v_outcome)
    || jsonb_build_object('acknowledged_request_id',v_ack);
end $$;
revoke all on function orbita_mobile_private.dispatch_allowed(uuid,text),
  orbita_mobile_private.dispatch_tick(),orbita_mobile_private.dispatch_snapshot(uuid,text,text),
  public.orbita_dispatch(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.orbita_dispatch(text,jsonb) to authenticated;
