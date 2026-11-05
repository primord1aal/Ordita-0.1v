-- Только новый согласованный тестовый проект. В облаке НЕ применено.
-- Не объединять с SQL старого прототипа. Любой существующий объект — остановка.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Миграцию должен выполнять согласованный владелец PostgreSQL postgres';
  end if;
  if to_regclass('auth.users') is null or to_regprocedure('auth.uid()') is null then
    raise exception 'Не найдены необходимые объекты Supabase Auth';
  end if;
  if exists(select 1 from pg_roles where rolname in ('anon','authenticated')
      and (rolsuper or rolbypassrls or rolcreaterole))
     or exists(select 1 from pg_roles r where (r.rolsuper or r.rolbypassrls)
       and (pg_has_role('authenticated',r.oid,'MEMBER') or pg_has_role('anon',r.oid,'MEMBER')))
     or pg_has_role('authenticated','postgres','MEMBER')
     or pg_has_role('anon','postgres','MEMBER') then
    raise exception 'Клиентские SQL-роли имеют опасные полномочия; миграция остановлена';
  end if;
  if exists (select 1 from pg_namespace where nspname='orbita_mobile_private')
     or to_regclass('public.orbita_profiles') is not null
     or to_regclass('public.orbita_user_roles') is not null
     or to_regclass('public.orbita_account_access') is not null
     or to_regclass('public.orbita_access_audit') is not null
     or to_regprocedure('public.orbita_get_access()') is not null then
    raise exception 'Объекты уже существуют: остановитесь и обследуйте проект, ничего не перезаписывайте';
  end if;
end;
$preflight$;

create schema orbita_mobile_private authorization postgres;
revoke all on schema orbita_mobile_private from public, anon, authenticated;
alter default privileges in schema orbita_mobile_private revoke execute on functions from public;

-- Профиль не содержит ни роли, ни флага блокировки.
create table public.orbita_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name)<=80),
  created_at timestamptz not null default clock_timestamp()
);
create table public.orbita_account_access (
  user_id uuid primary key references public.orbita_profiles(user_id) on delete cascade,
  is_blocked boolean not null default false,
  access_version bigint not null default 1 check (access_version>0)
);
create table public.orbita_user_roles (
  user_id uuid primary key references public.orbita_profiles(user_id) on delete cascade,
  role text not null check (role in ('passenger','driver','admin'))
);
create index orbita_user_roles_admin_idx on public.orbita_user_roles(user_id) where role='admin';
-- Нет FK к Auth: удаление аккаунта сохраняет историю административных изменений.
create table public.orbita_access_audit (
  id bigint generated always as identity primary key,
  target_user_id uuid not null,
  operation text not null,
  old_value jsonb,
  new_value jsonb,
  occurred_at timestamptz not null default clock_timestamp(),
  initiator_user_id uuid,
  initiator_verified boolean not null default false check (not initiator_verified),
  database_actor name not null,
  source text not null check (source in ('sql_editor_operator_declared','direct_database')),
  reason text check (reason is null or char_length(reason) between 5 and 200)
);
create index orbita_access_audit_target_time_idx on public.orbita_access_audit(target_user_id,occurred_at,id);

-- Записываемая строка сериализует изменения, в том числе при REPEATABLE READ:
-- конфликтующая транзакция получит 40001, а не посчитает устаревших администраторов.
create table orbita_mobile_private.access_mutex (
  singleton boolean primary key default true check (singleton),
  revision bigint not null default 0
);
insert into orbita_mobile_private.access_mutex(singleton) values (true);

alter table public.orbita_profiles enable row level security;
alter table public.orbita_account_access enable row level security;
alter table public.orbita_user_roles enable row level security;
alter table public.orbita_access_audit enable row level security;
revoke all on public.orbita_profiles, public.orbita_account_access,
  public.orbita_user_roles, public.orbita_access_audit from public, anon, authenticated;
revoke all on sequence public.orbita_access_audit_id_seq from public, anon, authenticated;
revoke all on orbita_mobile_private.access_mutex from public, anon, authenticated;

create function orbita_mobile_private.lock_access() returns void
language plpgsql volatile security definer set search_path='' as $$
begin
  update orbita_mobile_private.access_mutex set revision=revision+1 where singleton;
  if not found then raise exception 'Отсутствует строка блокировки доступа'; end if;
end;
$$;

create function orbita_mobile_private.active_admins(p_except uuid default null) returns bigint
language sql volatile security definer set search_path='' as $$
  select count(*) from public.orbita_user_roles r
  join public.orbita_profiles p on p.user_id=r.user_id
  join public.orbita_account_access a on a.user_id=r.user_id and not a.is_blocked
  join auth.users u on u.id=r.user_id
  where r.role='admin' and (p_except is null or r.user_id<>p_except);
$$;

create function orbita_mobile_private.guard_access() returns trigger
language plpgsql volatile security definer set search_path='' as $$
declare
  v_target uuid;
  v_loses_access boolean := false;
  v_admin boolean;
begin
  perform orbita_mobile_private.lock_access();
  if tg_op='UPDATE' then
    if new.user_id<>old.user_id then
      raise exception using errcode='22023', message='Идентификатор пользователя неизменяем';
    end if;
  end if;
  if tg_op='INSERT' then return new; end if;
  -- Повторная проверка после ожидания mutex не даёт UPDATE, начавшемуся
  -- до конкурентной блокировки/отзыва, завершиться со старыми правами.
  -- PostgREST использует SET LOCAL ROLE, локальные тесты — прямой LOGIN.
  if tg_table_name='orbita_profiles' and tg_op='UPDATE'
     and (session_user in ('anon','authenticated')
       or current_setting('role',true) in ('anon','authenticated')) then
    if old.user_id is distinct from auth.uid() or not exists(
      select 1 from auth.users u join public.orbita_user_roles r on r.user_id=u.id
      join public.orbita_account_access a on a.user_id=u.id
      where u.id=auth.uid() and not a.is_blocked and r.role in ('passenger','driver','admin')) then
      raise exception using errcode='42501', message='Текущие права на изменение профиля отозваны';
    end if;
  end if;
  if tg_table_schema='auth' then v_target:=old.id;
  else v_target:=old.user_id; end if;
  if tg_table_name='orbita_user_roles' then
    v_loses_access:=old.role='admin';
    if tg_op='UPDATE' then v_loses_access:=v_loses_access and new.role<>'admin'; end if;
    select exists(select 1 from public.orbita_account_access where user_id=v_target and not is_blocked) into v_admin;
    v_loses_access:=v_loses_access and v_admin;
  elsif tg_table_name='orbita_account_access' then
    v_loses_access:=not old.is_blocked;
    if tg_op='UPDATE' then v_loses_access:=v_loses_access and new.is_blocked; end if;
    select exists(select 1 from public.orbita_user_roles where user_id=v_target and role='admin') into v_admin;
    v_loses_access:=v_loses_access and v_admin;
  elsif tg_op='DELETE' then
    select exists(select 1 from public.orbita_user_roles r
      join public.orbita_account_access a using(user_id)
      where r.user_id=v_target and r.role='admin' and not a.is_blocked) into v_loses_access;
  end if;
  if v_loses_access and orbita_mobile_private.active_admins(v_target)=0 then
    raise exception using errcode='23514', message='Последний действующий администратор защищён';
  end if;
  if tg_table_name='orbita_account_access' and tg_op='UPDATE' then
    if new.is_blocked is distinct from old.is_blocked then new.access_version:=old.access_version+1; end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

create function orbita_mobile_private.audit_change() returns trigger
language plpgsql volatile security definer set search_path='' as $$
declare
  v_target uuid;
  v_old jsonb;
  v_new jsonb;
  v_actor text := nullif(current_setting('orbita.audit_actor',true),'');
  v_reason text := nullif(current_setting('orbita.audit_reason',true),'');
begin
  if tg_op='DELETE' then v_target:=old.user_id; else v_target:=new.user_id; end if;
  if tg_table_name='orbita_user_roles' then
    if tg_op<>'INSERT' then v_old:=jsonb_build_object('role',old.role); end if;
    if tg_op<>'DELETE' then v_new:=jsonb_build_object('role',new.role); end if;
    update public.orbita_account_access set access_version=access_version+1 where user_id=v_target;
  elsif tg_table_name='orbita_account_access' then
    if tg_op='UPDATE' and old.is_blocked=new.is_blocked then return null; end if;
    if tg_op<>'INSERT' then v_old:=jsonb_build_object('is_blocked',old.is_blocked); end if;
    if tg_op<>'DELETE' then v_new:=jsonb_build_object('is_blocked',new.is_blocked); end if;
  else
    -- Имя, email и содержимое профиля в аудит не копируются.
    if tg_op='UPDATE' then return null; end if;
    if tg_op='DELETE' then v_old:='{}'; else v_new:='{}'; end if;
  end if;
  insert into public.orbita_access_audit(target_user_id,operation,old_value,new_value,
    initiator_user_id,database_actor,source,reason)
  values(v_target,tg_table_name||':'||lower(tg_op),v_old,v_new,v_actor::uuid,session_user,
    case when v_reason is null then 'direct_database' else 'sql_editor_operator_declared' end,v_reason);
  return null;
end;
$$;

create function orbita_mobile_private.protect_audit() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  raise exception using errcode='42501', message='Аудит доступен только для добавления доверенными операциями';
end;
$$;

create function orbita_mobile_private.deny_truncate() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  raise exception using errcode='23514', message='Массовая очистка доступа запрещена; используйте проверяемые административные операции';
end;
$$;

create trigger orbita_profiles_guard before insert or update or delete on public.orbita_profiles
  for each row execute function orbita_mobile_private.guard_access();
create trigger orbita_account_access_guard before insert or update or delete on public.orbita_account_access
  for each row execute function orbita_mobile_private.guard_access();
create trigger orbita_user_roles_guard before insert or update or delete on public.orbita_user_roles
  for each row execute function orbita_mobile_private.guard_access();
create trigger orbita_auth_delete_guard before delete on auth.users
  for each row execute function orbita_mobile_private.guard_access();
create trigger orbita_profiles_audit after insert or delete on public.orbita_profiles
  for each row execute function orbita_mobile_private.audit_change();
create trigger orbita_account_access_audit after insert or update or delete on public.orbita_account_access
  for each row execute function orbita_mobile_private.audit_change();
create trigger orbita_user_roles_audit after insert or update or delete on public.orbita_user_roles
  for each row execute function orbita_mobile_private.audit_change();
create trigger orbita_audit_append_only before update or delete or truncate on public.orbita_access_audit
  for each statement execute function orbita_mobile_private.protect_audit();
create trigger orbita_profiles_no_truncate before truncate on public.orbita_profiles
  for each statement execute function orbita_mobile_private.deny_truncate();
create trigger orbita_roles_no_truncate before truncate on public.orbita_user_roles
  for each statement execute function orbita_mobile_private.deny_truncate();
create trigger orbita_access_no_truncate before truncate on public.orbita_account_access
  for each statement execute function orbita_mobile_private.deny_truncate();

-- Единственный клиентский RPC: только собственное актуальное состояние,
-- без параметра user_id и без изменения данных. Не административная операция.
create function public.orbita_get_access() returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'user_id', s.uid,
    'status', case when u.id is null then 'invalid_session'
      when p.user_id is null then 'no_profile'
      when a.user_id is null then 'inconsistent'
      when a.is_blocked then 'blocked'
      when r.role is null then 'no_role'
      when r.role not in ('passenger','driver','admin') then 'unknown_role'
      else 'active' end,
    'role', case when not a.is_blocked then r.role else null end,
    'access_version', a.access_version,
    'display_name', case when not a.is_blocked and r.role is not null then p.display_name else null end
  ) from (select auth.uid() as uid) s
  left join auth.users u on u.id=s.uid
  left join public.orbita_profiles p on p.user_id=u.id
  left join public.orbita_account_access a on a.user_id=p.user_id
  left join public.orbita_user_roles r on r.user_id=p.user_id;
$$;
revoke all on function public.orbita_get_access() from public, anon, authenticated;
grant execute on function public.orbita_get_access() to authenticated;
grant select on public.orbita_profiles to authenticated;
grant update(display_name) on public.orbita_profiles to authenticated;
create policy orbita_profile_own_read on public.orbita_profiles for select to authenticated
  using (user_id=(select auth.uid()) and (select public.orbita_get_access()->>'status')='active');
create policy orbita_profile_own_name on public.orbita_profiles for update to authenticated
  using (user_id=(select auth.uid()) and (select public.orbita_get_access()->>'status')='active')
  with check (user_id=(select auth.uid()) and (select public.orbita_get_access()->>'status')='active');
-- На ролях, блокировках и аудите нет клиентских разрешающих политик.

create function orbita_mobile_private.admin_access(
  p_target uuid,
  p_action text,
  p_role text default null,
  p_operator uuid default null,
  p_reason text default null,
  p_confirm_loss boolean default false,
  p_display_name text default ''
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_old_role text;
  v_old_blocked boolean;
  v_changed boolean := true;
begin
  perform orbita_mobile_private.lock_access();
  if p_target is null or not exists(select 1 from auth.users where id=p_target) then
    raise exception using errcode='22023', message='Нужен точный существующий UUID пользователя Auth';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 5 and 200
     or p_reason ~* '(sb_secret_|access_token|refresh_token|-----BEGIN)' then
    raise exception using errcode='22023', message='Укажите причину длиной 5–200 символов без секретов';
  end if;
  if p_operator is not null and not exists(select 1 from auth.users where id=p_operator) then
    raise exception using errcode='22023', message='Не найден указанный оператор; это ручное, не удостоверенное указание';
  end if;
  perform set_config('orbita.audit_actor',coalesce(p_operator::text,''),true);
  perform set_config('orbita.audit_reason',btrim(p_reason),true);
  if p_action='provision' then
    if p_role is not null then raise exception using errcode='22023', message='Создание профиля не назначает роль'; end if;
    insert into public.orbita_profiles(user_id,display_name) values(p_target,p_display_name);
    insert into public.orbita_account_access(user_id) values(p_target);
  else
    select r.role,a.is_blocked into v_old_role,v_old_blocked
      from public.orbita_profiles p join public.orbita_account_access a using(user_id)
      left join public.orbita_user_roles r using(user_id) where p.user_id=p_target;
    if not found then raise exception using errcode='22023', message='Сначала доверенно создайте профиль и состояние доступа'; end if;
    if p_action in ('assign','bootstrap') then
      if p_role is null or p_role not in ('passenger','driver','admin') then
        raise exception using errcode='22023', message='Неизвестная роль';
      end if;
    elsif p_action not in ('revoke','block','unblock') or p_role is not null then
      raise exception using errcode='22023', message='Неизвестная операция или лишний параметр роли';
    end if;
    if p_action='bootstrap' then
      if p_role<>'admin' or not p_confirm_loss or v_old_blocked
        or orbita_mobile_private.active_admins()<>0 then
        raise exception using errcode='23514', message='Первый администратор требует отдельного подтверждения и отсутствия действующих администраторов';
      end if;
    elsif orbita_mobile_private.active_admins()=0 then
      raise exception using errcode='23514', message='Сначала выполните доверенное первоначальное назначение администратора';
    end if;
    if ((v_old_role='admin' and (p_action in ('revoke','block') or p_action='assign' and p_role<>'admin'))
      or (p_operator=p_target and (p_action in ('revoke','block') or p_action='assign' and p_role is distinct from v_old_role)))
      and not p_confirm_loss then
      raise exception using errcode='22023', message='Требуется явное подтверждение потери полномочий';
    end if;
    if p_action in ('assign','bootstrap') then
      v_changed:=v_old_role is distinct from p_role;
      insert into public.orbita_user_roles(user_id,role) values(p_target,p_role)
        on conflict(user_id) do update set role=excluded.role where orbita_user_roles.role is distinct from excluded.role;
    elsif p_action='revoke' then
      v_changed:=v_old_role is not null;
      delete from public.orbita_user_roles where user_id=p_target;
    else
      v_changed:=v_old_blocked is distinct from (p_action='block');
      update public.orbita_account_access set is_blocked=(p_action='block'),access_version=access_version+1
        where user_id=p_target and is_blocked is distinct from (p_action='block');
    end if;
    if not v_changed then
      insert into public.orbita_access_audit(target_user_id,operation,old_value,new_value,
        initiator_user_id,database_actor,source,reason)
      values(p_target,'no_change:'||p_action,jsonb_build_object('role',v_old_role,'is_blocked',v_old_blocked),
        jsonb_build_object('role',v_old_role,'is_blocked',v_old_blocked),p_operator,session_user,
        'sql_editor_operator_declared',btrim(p_reason));
    end if;
  end if;
  return (select jsonb_build_object('target_user_id',p_target,'action',p_action,'changed',v_changed,
      'role',r.role,'is_blocked',a.is_blocked,'access_version',a.access_version)
    from public.orbita_profiles p join public.orbita_account_access a using(user_id)
    left join public.orbita_user_roles r using(user_id) where p.user_id=p_target);
end;
$$;

-- В том числе триггерные и вспомогательные функции закрыты от прямого вызова.
revoke all on all functions in schema orbita_mobile_private from public, anon, authenticated;
revoke all on all tables in schema orbita_mobile_private from public, anon, authenticated;
-- Supabase может выдавать глобальные default grants роли service_role.
-- Эти новые административные объекты не предназначены и для такого HTTP API.
do $service_acl$
begin
  if exists(select 1 from pg_roles where rolname='service_role') then
    revoke all on schema orbita_mobile_private from service_role;
    revoke all on all functions in schema orbita_mobile_private from service_role;
    revoke all on all tables in schema orbita_mobile_private from service_role;
    revoke all on function public.orbita_get_access() from service_role;
    revoke all on public.orbita_profiles, public.orbita_user_roles,
      public.orbita_account_access, public.orbita_access_audit from service_role;
    revoke all on sequence public.orbita_access_audit_id_seq from service_role;
  end if;
end;
$service_acl$;
comment on function public.orbita_get_access() is 'Только собственный текущий доступ; не даёт прав из JWT metadata и не изменяет роли';
commit;
