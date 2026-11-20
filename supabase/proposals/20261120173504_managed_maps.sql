-- New, separately approved migration. No change to Auth, roles or orders.
create table orbita_mobile_private.map_budget (
  bucket text not null,
  period timestamptz not null,
  units integer not null check (units>=0),
  primary key(bucket,period)
);
create index orbita_map_budget_expiry on orbita_mobile_private.map_budget(period);
alter table orbita_mobile_private.map_budget enable row level security;
revoke all on orbita_mobile_private.map_budget from public,anon,authenticated,service_role;
create function public.orbita_map_budget(p_user uuid,p_units integer) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare v_now timestamptz:=clock_timestamp(); v_day timestamptz; v_minute timestamptz;
  v_global integer; v_user integer;
begin
  if p_user is null or p_units is null or p_units not between 1 and 10 then return false; end if;
  if not exists(select 1 from public.orbita_user_roles r join public.orbita_account_access a using(user_id)
      where r.user_id=p_user and r.role in ('passenger','driver') and not a.is_blocked) then return false; end if;
  perform pg_advisory_xact_lock(76421,7);
  v_day:=date_trunc('day',v_now at time zone 'UTC') at time zone 'UTC';
  v_minute:=date_trunc('minute',v_now);
  select units into v_global from orbita_mobile_private.map_budget where bucket='global' and period=v_day;
  select units into v_user from orbita_mobile_private.map_budget where bucket=p_user::text and period=v_minute;
  -- Conservative application quota, below Geoapify Free's 3000 credits/day.
  if coalesce(v_global,0)+p_units>2500 or coalesce(v_user,0)+p_units>120 then return false; end if;
  insert into orbita_mobile_private.map_budget values('global',v_day,p_units),(p_user::text,v_minute,p_units)
    on conflict(bucket,period) do update set units=orbita_mobile_private.map_budget.units+excluded.units;
  delete from orbita_mobile_private.map_budget where period<v_day-interval '1 day';
  return true;
end $$;
revoke all on function public.orbita_map_budget(uuid,integer) from public,anon,authenticated;
grant execute on function public.orbita_map_budget(uuid,integer) to service_role;
