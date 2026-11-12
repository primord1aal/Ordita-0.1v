-- Только синтетическая одноразовая PostgreSQL, после bootstrap_local.sql.
-- НЕ миграция Auth и НЕ проверка JWT-подписи, Auth HTTP или PostgREST.
create table auth.sessions (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  not_after timestamptz
);
create function auth.jwt() returns jsonb language sql stable set search_path='' as $$
  select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb);
$$;
revoke all on auth.sessions from public,anon,authenticated,service_role;
revoke all on function auth.jwt() from public,anon,authenticated,service_role;
grant execute on function auth.jwt() to anon,authenticated;
