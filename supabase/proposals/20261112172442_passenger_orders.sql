-- ЛОКАЛЬНЫЙ КАНДИДАТ. Не находится в runnable migrations и не применялся в облаке.
-- Первый сохранённый тестовый заказ без цены, диспетчеризации и уведомлений.
-- Вызывающий исполнитель должен обернуть весь файл в одну транзакцию.

do $preflight$
begin
  if current_user <> 'postgres'
     or to_regclass('public.orbita_orders') is not null
     or to_regprocedure('orbita_mobile_private.lock_access()') is null
     or to_regclass('public.orbita_user_roles') is null
     or to_regclass('public.orbita_account_access') is null
     or to_regclass('auth.sessions') is null
     or to_regprocedure('auth.uid()') is null
     or to_regprocedure('auth.jwt()') is null then
    raise exception 'ORB_ORDER_STATE_CHANGED';
  end if;
  if exists (
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='public' and p.proname in (
      'orbita_create_order','orbita_get_current_order','orbita_get_order','orbita_cancel_order'))
      or (n.nspname='orbita_mobile_private' and p.proname in (
        'order_point','order_session_uid','order_envelope'))
  ) then
    raise exception 'ORB_ORDER_STATE_CHANGED';
  end if;
end;
$preflight$;

-- Числа остаются числами; порядок ключей/масштаб numeric не меняют intent.
create function orbita_mobile_private.order_point(p_point jsonb) returns jsonb
language plpgsql immutable security definer set search_path='' as $$
declare
  v_address text;
  v_latitude numeric;
  v_longitude numeric;
begin
  if p_point is null or pg_catalog.jsonb_typeof(p_point)<>'object' then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  if (select count(*) from pg_catalog.jsonb_object_keys(p_point))<>3
     or not (p_point ?& array['address','latitude','longitude'])
     or pg_catalog.jsonb_typeof(p_point->'address')<>'string'
     or pg_catalog.jsonb_typeof(p_point->'latitude')<>'number'
     or pg_catalog.jsonb_typeof(p_point->'longitude')<>'number' then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  v_address:=pg_catalog.btrim(pg_catalog.regexp_replace((p_point->>'address') collate "C",
    E'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+',
    ' ','g'),' ');
  v_latitude:=(p_point->>'latitude')::numeric;
  v_longitude:=(p_point->>'longitude')::numeric;
  if pg_catalog.char_length(v_address) not between 1 and 500
     or v_latitude not between -90 and 90
     or v_longitude not between -180 and 180 then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  return pg_catalog.jsonb_build_object(
    'address',v_address,'latitude',v_latitude,'longitude',v_longitude);
end;
$$;

create table public.orbita_orders (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  passenger_id uuid not null references public.orbita_profiles(user_id) on delete cascade,
  request_id uuid not null,
  pickup jsonb not null,
  destination jsonb not null,
  status text not null default 'created' check (status in ('created','cancelled')),
  cancellation_reason text check (cancellation_reason in ('passenger','search_timeout')),
  created_at timestamptz not null,
  expires_at timestamptz not null,
  cancelled_at timestamptz,
  version integer not null default 1,
  unique (passenger_id,request_id),
  check (pickup=orbita_mobile_private.order_point(pickup)),
  check (destination=orbita_mobile_private.order_point(destination)),
  check (pickup->'latitude'<>destination->'latitude' or pickup->'longitude'<>destination->'longitude'),
  check (expires_at=created_at+interval '5 minutes'),
  check (
    (status='created' and cancellation_reason is null and cancelled_at is null and version=1)
    or (status='cancelled' and cancellation_reason is not null and cancelled_at is not null and version=2
      and ((cancellation_reason='search_timeout' and cancelled_at=expires_at)
        or (cancellation_reason='passenger' and cancelled_at<expires_at)))
  )
);
create unique index orbita_orders_one_created_per_passenger
  on public.orbita_orders(passenger_id) where status='created';
alter table public.orbita_orders enable row level security;
revoke all on public.orbita_orders from public, anon, authenticated;
-- Ни одной разрешающей клиентской политики. Доступ только через четыре RPC.

-- Отдельная проверка orders: не изменяет старый orbita_get_access/Auth.
-- Проверка подписи JWT остаётся обязанностью доверенного Auth/PostgREST слоя.
create function orbita_mobile_private.order_session_uid() returns uuid
language plpgsql volatile security definer set search_path='' as $$
declare
  v_uid uuid;
  v_claim_uid uuid;
  v_session uuid;
  v_claims jsonb;
  v_exp numeric;
  v_now timestamptz:=pg_catalog.clock_timestamp();
begin
  begin
    v_uid:=auth.uid();
    v_claims:=auth.jwt();
    if v_uid is null or pg_catalog.jsonb_typeof(v_claims->'exp') is distinct from 'number'
       or pg_catalog.jsonb_typeof(v_claims->'sub') is distinct from 'string'
       or pg_catalog.jsonb_typeof(v_claims->'session_id') is distinct from 'string' then
      raise exception using errcode='28000', message='ORB_ORDER_SESSION_REQUIRED';
    end if;
    v_session:=(v_claims->>'session_id')::uuid;
    v_claim_uid:=(v_claims->>'sub')::uuid;
    v_exp:=(v_claims->>'exp')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode='28000', message='ORB_ORDER_SESSION_REQUIRED';
  end;
  if v_claim_uid is distinct from v_uid or v_exp<=extract(epoch from v_now) or not exists (
    select 1 from auth.sessions s join auth.users u on u.id=s.user_id
    where s.id=v_session and s.user_id=v_uid and (s.not_after is null or s.not_after>v_now)
  ) then
    raise exception using errcode='28000', message='ORB_ORDER_SESSION_REQUIRED';
  end if;
  return v_uid;
end;
$$;

-- Только сериализация уже найденной собственной строки. Время передаёт сервер.
-- Терминальный timeout имеет одинаковые поля до и после физического UPDATE.
create function orbita_mobile_private.order_envelope(
  p_order public.orbita_orders, p_server_time timestamptz
) returns jsonb
language sql immutable security definer set search_path='' as $$
  with effective as (
    select p_order.status='created' and p_order.expires_at<=p_server_time as timed_out
  )
  select pg_catalog.jsonb_build_object(
    'contract_version',1,
    'server_time',pg_catalog.to_char(p_server_time at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'order',case when p_order.id is null then null else pg_catalog.jsonb_build_object(
      'id',p_order.id,'passenger_id',p_order.passenger_id,'request_id',p_order.request_id,
      'pickup',p_order.pickup,'destination',p_order.destination,
      'status',case when timed_out then 'cancelled' else p_order.status end,
      'cancellation_reason',case when timed_out then 'search_timeout' else p_order.cancellation_reason end,
      'created_at',pg_catalog.to_char(p_order.created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'expires_at',pg_catalog.to_char(p_order.expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'cancelled_at',pg_catalog.to_char(
        (case when timed_out then p_order.expires_at else p_order.cancelled_at end) at time zone 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'version',case when timed_out then 2 else p_order.version end
    ) end
  ) from effective;
$$;

create function public.orbita_create_order(
  p_request_id uuid,p_pickup jsonb,p_destination jsonb
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_uid uuid;
  v_pickup jsonb;
  v_destination jsonb;
  v_order public.orbita_orders;
  v_now timestamptz;
begin
  -- Тот же mutex, что у блокировки/смены роли. Проверки идут ПОСЛЕ ожидания.
  perform orbita_mobile_private.lock_access();
  v_uid:=orbita_mobile_private.order_session_uid();
  if p_request_id is null then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  v_pickup:=orbita_mobile_private.order_point(p_pickup);
  v_destination:=orbita_mobile_private.order_point(p_destination);
  if v_pickup->'latitude'=v_destination->'latitude'
     and v_pickup->'longitude'=v_destination->'longitude' then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  select * into v_order from public.orbita_orders
    where passenger_id=v_uid and request_id=p_request_id;
  if found then
    if v_order.pickup<>v_pickup or v_order.destination<>v_destination then
      raise exception using errcode='P0001', message='ORB_ORDER_IDEMPOTENCY_CONFLICT';
    end if;
    return orbita_mobile_private.order_envelope(v_order,pg_catalog.clock_timestamp());
  end if;
  -- Чтение/replay/отмена своих доступны после отзыва роли; НОВОЕ создание нет.
  if not exists (
    select 1 from public.orbita_profiles p
    join public.orbita_account_access a using(user_id)
    join public.orbita_user_roles r using(user_id)
    where p.user_id=v_uid and not a.is_blocked and r.role='passenger'
  ) then
    raise exception using errcode='42501', message='ORB_ORDER_CREATE_FORBIDDEN';
  end if;
  v_now:=pg_catalog.clock_timestamp();
  update public.orbita_orders set status='cancelled',cancellation_reason='search_timeout',
    cancelled_at=expires_at,version=2
    where passenger_id=v_uid and status='created' and expires_at<=v_now;
  if exists (select 1 from public.orbita_orders where passenger_id=v_uid and status='created') then
    raise exception using errcode='P0001', message='ORB_ORDER_ACTIVE_EXISTS';
  end if;
  v_now:=pg_catalog.clock_timestamp();
  insert into public.orbita_orders(passenger_id,request_id,pickup,destination,created_at,expires_at)
    values(v_uid,p_request_id,v_pickup,v_destination,v_now,v_now+interval '5 minutes')
    returning * into v_order;
  return orbita_mobile_private.order_envelope(v_order,v_now);
end;
$$;

create function public.orbita_get_current_order() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_uid uuid:=orbita_mobile_private.order_session_uid();
  v_order public.orbita_orders;
  v_now timestamptz:=pg_catalog.clock_timestamp();
begin
  -- Активный предпочитается даже при равных временах; затем последний receipt.
  select * into v_order from public.orbita_orders
    where passenger_id=v_uid and status='created' and expires_at>v_now;
  if not found then
    select * into v_order from public.orbita_orders where passenger_id=v_uid
      order by created_at desc,id desc limit 1;
  end if;
  return orbita_mobile_private.order_envelope(v_order,pg_catalog.clock_timestamp());
end;
$$;

create function public.orbita_get_order(p_order_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_uid uuid:=orbita_mobile_private.order_session_uid();
  v_order public.orbita_orders;
begin
  if p_order_id is null then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  select * into v_order from public.orbita_orders where id=p_order_id and passenger_id=v_uid;
  if not found then
    raise exception using errcode='P0001', message='ORB_ORDER_NOT_FOUND';
  end if;
  return orbita_mobile_private.order_envelope(v_order,pg_catalog.clock_timestamp());
end;
$$;

create function public.orbita_cancel_order(p_order_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_uid uuid;
  v_order public.orbita_orders;
  v_now timestamptz;
begin
  perform orbita_mobile_private.lock_access();
  v_uid:=orbita_mobile_private.order_session_uid();
  if p_order_id is null then
    raise exception using errcode='P0001', message='ORB_ORDER_INVALID_REQUEST';
  end if;
  select * into v_order from public.orbita_orders where id=p_order_id and passenger_id=v_uid;
  if not found then
    raise exception using errcode='P0001', message='ORB_ORDER_NOT_FOUND';
  end if;
  v_now:=pg_catalog.clock_timestamp();
  if v_order.status='cancelled' then
    return orbita_mobile_private.order_envelope(v_order,v_now);
  elsif v_order.status<>'created' then
    raise exception using errcode='P0001', message='ORB_ORDER_STATE_CHANGED';
  end if;
  update public.orbita_orders set status='cancelled',version=2,
    cancellation_reason=case when expires_at<=v_now then 'search_timeout' else 'passenger' end,
    cancelled_at=case when expires_at<=v_now then expires_at else v_now end
    where id=v_order.id and passenger_id=v_uid and status='created'
    returning * into v_order;
  if not found then
    raise exception using errcode='P0001', message='ORB_ORDER_STATE_CHANGED';
  end if;
  return orbita_mobile_private.order_envelope(v_order,v_now);
end;
$$;

revoke all on function orbita_mobile_private.order_point(jsonb),
  orbita_mobile_private.order_session_uid(),
  orbita_mobile_private.order_envelope(public.orbita_orders,timestamptz)
  from public,anon,authenticated;
revoke all on function public.orbita_create_order(uuid,jsonb,jsonb),
  public.orbita_get_current_order(),public.orbita_get_order(uuid),public.orbita_cancel_order(uuid)
  from public,anon,authenticated;
grant execute on function public.orbita_create_order(uuid,jsonb,jsonb),
  public.orbita_get_current_order(),public.orbita_get_order(uuid),public.orbita_cancel_order(uuid)
  to authenticated;
do $service_acl$
begin
  if exists(select 1 from pg_catalog.pg_roles where rolname='service_role') then
    revoke all on public.orbita_orders from service_role;
    revoke all on function orbita_mobile_private.order_point(jsonb),
      orbita_mobile_private.order_session_uid(),
      orbita_mobile_private.order_envelope(public.orbita_orders,timestamptz),
      public.orbita_create_order(uuid,jsonb,jsonb),public.orbita_get_current_order(),
      public.orbita_get_order(uuid),public.orbita_cancel_order(uuid) from service_role;
  end if;
end;
$service_acl$;
