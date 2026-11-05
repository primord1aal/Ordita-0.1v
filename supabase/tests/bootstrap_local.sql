-- Только одноразовая PostgreSQL. Не миграция Supabase и не проверка подписи JWT.
create role anon login nosuperuser nobypassrls noinherit;
create role authenticated login nosuperuser nobypassrls noinherit;
create role service_role nologin nosuperuser bypassrls;
revoke create on schema public from public;
grant usage on schema public to anon,authenticated;
create schema auth;
create table auth.users(id uuid primary key, email text unique, raw_user_meta_data jsonb not null default '{}');
create function auth.uid() returns uuid language sql stable set search_path='' as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;
grant usage on schema auth to anon,authenticated;
grant execute on function auth.uid() to anon,authenticated;
revoke all on auth.users from public,anon,authenticated;
-- Стресс-проверка широких исходных default grants, не снимок настроек облака.
alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
alter default privileges grant execute on functions to service_role;
