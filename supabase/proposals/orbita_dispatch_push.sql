-- Local rehearsal candidate. Enqueue in the dispatch transaction and deliver
-- outside it. Apply only after separate admission of Maps and Push.
do $preflight$
begin
  if current_user <> 'postgres'
     or to_regclass('orbita_mobile_private.dispatch_offers') is null
     or to_regprocedure('orbita_mobile_private.dispatch_allowed(uuid,text)') is null
     or to_regprocedure('public.orbita_map_budget(uuid,integer)') is null then
    raise exception 'ORB_PUSH_PREFLIGHT';
  end if;
end
$preflight$;

create schema orbita_push_private authorization postgres;
revoke all on schema orbita_push_private from public, anon, authenticated, service_role;

create table orbita_push_private.devices (
  driver_id uuid primary key references public.orbita_profiles(user_id) on delete cascade,
  session_id uuid not null references auth.sessions(id) on delete cascade,
  token text not null unique,
  valid_until timestamptz not null,
  check (char_length(token) between 16 and 2048 and token collate "C" ~ '^[!-~]+$')
);
alter table orbita_push_private.devices enable row level security;
revoke all on orbita_push_private.devices from public, anon, authenticated, service_role;

-- One active installation per driver. A switched device can replace its
-- binding, but an old session cannot unregister the replacement.
create function orbita_push_private.register_device(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $device$
declare
  v_uid uuid;
  v_session uuid;
begin
  perform orbita_mobile_private.lock_access();
  v_uid := orbita_mobile_private.order_session_uid();
  v_session := (auth.jwt()->>'session_id')::uuid;
  if p_token is null then
    delete from orbita_push_private.devices where driver_id = v_uid and session_id = v_session;
    return true;
  end if;
  if not orbita_mobile_private.dispatch_allowed(v_uid, 'driver') then
    raise exception using errcode = '42501', message = 'ORB_PUSH_DRIVER_REQUIRED';
  end if;
  if char_length(p_token) not between 16 and 2048 or p_token collate "C" !~ '^[!-~]+$' then
    raise exception using errcode = '22023', message = 'ORB_PUSH_TOKEN_INVALID';
  end if;

  delete from orbita_push_private.devices where token = p_token and driver_id <> v_uid;
  insert into orbita_push_private.devices (driver_id, session_id, token, valid_until)
  values (v_uid, v_session, p_token, to_timestamp((auth.jwt()->>'exp')::double precision))
  on conflict (driver_id) do update
    set session_id = excluded.session_id, token = excluded.token, valid_until = excluded.valid_until
  where (devices.session_id, devices.token, devices.valid_until)
    is distinct from (excluded.session_id, excluded.token, excluded.valid_until);
  return true;
end
$device$;

-- Heartbeat can extend an existing live shift. Restarting an expired shift
-- continues to require the ordinary driver action and queue rules.
create function orbita_push_private.driver_heartbeat()
returns boolean language plpgsql security definer set search_path = '' as $heartbeat$
declare
  v_uid uuid;
  v_now timestamptz;
begin
  perform orbita_mobile_private.lock_access();
  v_uid := orbita_mobile_private.order_session_uid();
  if not orbita_mobile_private.dispatch_allowed(v_uid, 'driver') then
    raise exception using errcode = '42501', message = 'ORB_PUSH_DRIVER_REQUIRED';
  end if;
  perform orbita_mobile_private.dispatch_tick();
  v_now := clock_timestamp();
  update orbita_mobile_private.dispatch_drivers set heartbeat_at = v_now
  where driver_id = v_uid and online and heartbeat_at > v_now - interval '15 seconds';
  return found;
end
$heartbeat$;

create function public.orbita_driver_push_device(p_token text)
returns boolean language sql security invoker set search_path = '' as $$
  select orbita_push_private.register_device(p_token)
$$;

create function public.orbita_driver_heartbeat()
returns boolean language sql security invoker set search_path = '' as $$
  select orbita_push_private.driver_heartbeat()
$$;

create table orbita_mobile_private.driver_offer_push (
  event_id uuid primary key
    references orbita_mobile_private.dispatch_offers(id) on delete cascade,
  available_at timestamptz not null,
  attempts smallint not null default 0 check (attempts between 0 and 3),
  lease_id uuid,
  lease_until timestamptz,
  outcome text check (outcome in ('provider_accepted', 'discarded')),
  check ((lease_id is null) = (lease_until is null)),
  check (outcome is null or lease_id is null)
);

alter table orbita_mobile_private.driver_offer_push enable row level security;
revoke all on orbita_mobile_private.driver_offer_push
  from public, anon, authenticated, service_role;

create function orbita_mobile_private.enqueue_driver_offer_push()
returns trigger language plpgsql security invoker set search_path = '' as $enqueue$
begin
  insert into orbita_mobile_private.driver_offer_push (event_id, available_at)
    values (new.id, new.created_at);
  return new;
end
$enqueue$;

create trigger enqueue_driver_offer_push
  after insert on orbita_mobile_private.dispatch_offers
  for each row when (new.status = 'pending')
  execute function orbita_mobile_private.enqueue_driver_offer_push();

-- The event ID is the offer ID. Only kind=driver_offer, offer_id and expires_at
-- (UTC ISO 8601) go to the device. recipient_id is worker-only routing data.
create function orbita_mobile_private.claim_driver_offer_push(p_limit integer)
returns table (event_id uuid, recipient_id uuid, lease_id uuid, expires_at timestamptz, token text)
language plpgsql security invoker set search_path = '' as $claim$
declare
  v_now timestamptz := clock_timestamp();
begin
  if p_limit is null or p_limit not between 1 and 20 then
    raise exception 'ORB_PUSH_BATCH_SIZE';
  end if;

  return query
  with picked as (
    select f.id, f.driver_id, f.expires_at, device.token
    from orbita_mobile_private.dispatch_offers f
    join orbita_mobile_private.driver_offer_push q on q.event_id = f.id
    join public.orbita_orders o on o.id = f.order_id
    join orbita_mobile_private.dispatch_drivers d on d.driver_id = f.driver_id
    join orbita_push_private.devices device on device.driver_id = f.driver_id
    join auth.sessions s on s.id = device.session_id and s.user_id = f.driver_id
    where f.status = 'pending' and f.expires_at > v_now
      and o.status = 'created' and o.expires_at > v_now
      and d.online and d.heartbeat_at > v_now - interval '15 seconds'
      and orbita_mobile_private.dispatch_allowed(f.driver_id, 'driver')
      and device.valid_until > v_now and (s.not_after is null or s.not_after > v_now)
      and q.outcome is null and q.attempts < 3 and q.available_at <= v_now
      and (q.lease_until is null or q.lease_until <= v_now)
    order by q.available_at, q.event_id
    limit p_limit
    for update of q skip locked
  )
  update orbita_mobile_private.driver_offer_push q
  set attempts = q.attempts + 1,
      lease_id = gen_random_uuid(),
      lease_until = least(v_now + interval '5 seconds', picked.expires_at)
  from picked where q.event_id = picked.id
  returning q.event_id, picked.driver_id, q.lease_id, picked.expires_at, picked.token;
end
$claim$;

-- A worker only finishes the lease it owns. A provider response does not
-- prove receipt or acceptance by the driver.
create function orbita_mobile_private.finish_driver_offer_push(
  p_event_id uuid, p_lease_id uuid, p_result text
) returns boolean language plpgsql security invoker set search_path = '' as $finish$
declare
  v_now timestamptz := clock_timestamp();
begin
  if p_result is null or p_result not in ('provider_accepted', 'retry', 'discarded') then
    raise exception 'ORB_PUSH_OUTCOME';
  end if;

  update orbita_mobile_private.driver_offer_push q
  set outcome = case
        when p_result <> 'retry' then p_result
        when q.attempts = 3 then 'discarded'
        else null
      end,
      available_at = case
        when p_result = 'retry' then v_now + interval '2 seconds'
        else q.available_at
      end,
      lease_id = null,
      lease_until = null
  where q.event_id = p_event_id
    and q.lease_id = p_lease_id and q.lease_until > v_now;
  return found;
end
$finish$;

create function orbita_push_private.claim_delivery(p_limit integer)
returns table (event_id uuid, recipient_id uuid, lease_id uuid, expires_at timestamptz, token text)
language sql security definer set search_path = '' as $$
  select * from orbita_mobile_private.claim_driver_offer_push(p_limit)
$$;

create function orbita_push_private.finish_delivery(p_event_id uuid, p_lease_id uuid, p_result text)
returns boolean language sql security definer set search_path = '' as $$
  select orbita_mobile_private.finish_driver_offer_push(p_event_id, p_lease_id, p_result)
$$;

create function public.orbita_driver_push_claim(p_limit integer)
returns table (event_id uuid, recipient_id uuid, lease_id uuid, expires_at timestamptz, token text)
language sql security invoker set search_path = '' as $$
  select * from orbita_push_private.claim_delivery(p_limit)
$$;

create function public.orbita_driver_push_finish(p_event_id uuid, p_lease_id uuid, p_result text)
returns boolean language sql security invoker set search_path = '' as $$
  select orbita_push_private.finish_delivery(p_event_id, p_lease_id, p_result)
$$;

revoke all on function
  orbita_mobile_private.enqueue_driver_offer_push(),
  orbita_mobile_private.claim_driver_offer_push(integer),
  orbita_mobile_private.finish_driver_offer_push(uuid, uuid, text),
  orbita_push_private.register_device(text), orbita_push_private.driver_heartbeat(),
  orbita_push_private.claim_delivery(integer), orbita_push_private.finish_delivery(uuid, uuid, text),
  public.orbita_driver_push_device(text), public.orbita_driver_heartbeat(),
  public.orbita_driver_push_claim(integer), public.orbita_driver_push_finish(uuid, uuid, text)
from public, anon, authenticated, service_role;

grant usage on schema orbita_push_private to authenticated, service_role;
grant execute on function orbita_push_private.register_device(text), orbita_push_private.driver_heartbeat(),
  public.orbita_driver_push_device(text), public.orbita_driver_heartbeat() to authenticated;
grant execute on function orbita_push_private.claim_delivery(integer),
  orbita_push_private.finish_delivery(uuid, uuid, text), public.orbita_driver_push_claim(integer),
  public.orbita_driver_push_finish(uuid, uuid, text) to service_role;
