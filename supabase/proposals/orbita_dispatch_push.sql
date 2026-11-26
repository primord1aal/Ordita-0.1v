-- Local rehearsal candidate. Enqueue in the dispatch transaction and deliver
-- outside it. This proposal exposes no API and provisions no worker login.
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
returns table (event_id uuid, recipient_id uuid, lease_id uuid, expires_at timestamptz)
language plpgsql security invoker set search_path = '' as $claim$
declare
  v_now timestamptz := clock_timestamp();
begin
  if p_limit is null or p_limit not between 1 and 20 then
    raise exception 'ORB_PUSH_BATCH_SIZE';
  end if;

  return query
  with picked as (
    select f.id, f.driver_id, f.expires_at
    from orbita_mobile_private.dispatch_offers f
    join orbita_mobile_private.driver_offer_push q on q.event_id = f.id
    join public.orbita_orders o on o.id = f.order_id
    join orbita_mobile_private.dispatch_drivers d on d.driver_id = f.driver_id
    where f.status = 'pending' and f.expires_at > v_now
      and o.status = 'created' and o.expires_at > v_now
      and d.online and d.heartbeat_at > v_now - interval '15 seconds'
      and orbita_mobile_private.dispatch_allowed(f.driver_id, 'driver')
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
  returning q.event_id, picked.driver_id, q.lease_id, picked.expires_at;
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

revoke all on function
  orbita_mobile_private.enqueue_driver_offer_push(),
  orbita_mobile_private.claim_driver_offer_push(integer),
  orbita_mobile_private.finish_driver_offer_push(uuid, uuid, text)
from public, anon, authenticated, service_role;
