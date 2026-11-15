-- NOT APPROVED FOR EXECUTION. Conditional specification, NOT a hosted-Supabase recipe.
-- Official hosted restrictions currently prevent claiming this profile is available.
-- Do not remove guards, use pg_read_all_data, grant managed memberships or revoke PUBLIC.
-- No password is included. The resulting role is deliberately NOLOGIN.
BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = pg_catalog;
DO $guard$
DECLARE item record;
BEGIN
 IF current_database()<>'postgres' OR current_setting('server_version_num')::int NOT BETWEEN 170000 AND 179999 THEN
  RAISE EXCEPTION 'BACKUP_SETUP_TARGET_NOT_CONFIRMED';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='orbita_backup_reader') THEN
  RAISE EXCEPTION 'BACKUP_READER_ALREADY_EXISTS_STOP';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=current_user AND (rolsuper OR (rolcreaterole AND rolbypassrls))) THEN
  RAISE EXCEPTION 'BACKUP_SETUP_ROLE_AUTHORITY_MISSING';
 END IF;
 IF (SELECT count(*) FROM pg_namespace WHERE nspname IN
  ('auth','public','orbita_mobile_private','supabase_migrations'))<>4 THEN
  RAISE EXCEPTION 'BACKUP_SETUP_SCOPE_MISSING';
 END IF;
 FOR item IN SELECT oid FROM pg_namespace WHERE nspname IN
  ('auth','public','orbita_mobile_private','supabase_migrations') LOOP
  IF NOT has_schema_privilege(current_user,item.oid,'USAGE WITH GRANT OPTION') THEN
   RAISE EXCEPTION 'BACKUP_SETUP_MANAGED_SCHEMA_GRANT_BLOCKED';
  END IF;
 END LOOP;
 IF EXISTS (SELECT 1 FROM pg_database d CROSS JOIN LATERAL
  aclexplode(coalesce(d.datacl,acldefault('d',d.datdba))) a
  WHERE d.datname=current_database() AND a.grantee=0 AND a.privilege_type IN ('CREATE','TEMPORARY')) THEN
  RAISE EXCEPTION 'BACKUP_SETUP_UNSAFE_PUBLIC_DATABASE_PRIVILEGES';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
  WHERE n.nspname='pg_catalog' AND a.grantee=0 AND a.privilege_type='EXECUTE'
  AND p.proname IN ('lo_create','lo_creat','lo_from_bytea','lo_put','lo_unlink','lowrite',
   'lo_import','lo_export','lo_truncate','lo_truncate64')) THEN
  RAISE EXCEPTION 'BACKUP_SETUP_UNSAFE_PUBLIC_LARGE_OBJECT_PRIVILEGES';
 END IF;
 FOR item IN SELECT c.oid,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations')
  AND c.relkind IN ('r','p','m','v','f','S') LOOP
  IF item.relkind='S' THEN
   IF NOT has_sequence_privilege(current_user,item.oid,'SELECT WITH GRANT OPTION') THEN
    RAISE EXCEPTION 'BACKUP_SETUP_SELECT_GRANT_AUTHORITY_MISSING';
   END IF;
  ELSIF NOT has_table_privilege(current_user,item.oid,'SELECT WITH GRANT OPTION') THEN
   RAISE EXCEPTION 'BACKUP_SETUP_SELECT_GRANT_AUTHORITY_MISSING';
  END IF;
 END LOOP;
END
$guard$;
CREATE ROLE orbita_backup_reader NOLOGIN PASSWORD NULL
 NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS CONNECTION LIMIT 2;
ALTER ROLE orbita_backup_reader SET default_transaction_read_only=on;
ALTER ROLE orbita_backup_reader SET statement_timeout='30s';
ALTER ROLE orbita_backup_reader SET lock_timeout='5s';
ALTER ROLE orbita_backup_reader SET idle_in_transaction_session_timeout='180s';
ALTER ROLE orbita_backup_reader SET search_path=pg_catalog;
GRANT CONNECT ON DATABASE postgres TO orbita_backup_reader;
GRANT USAGE ON SCHEMA auth,public,orbita_mobile_private,supabase_migrations TO orbita_backup_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA auth,public,orbita_mobile_private,supabase_migrations TO orbita_backup_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA auth,public,orbita_mobile_private,supabase_migrations TO orbita_backup_reader;
-- Still NOLOGIN and no password: do not activate until full effective-rights review passes.
-- The runtime preflight remains mandatory; these setup guards are not a replacement.
-- No ALTER DEFAULT PRIVILEGES: future Auth/app objects require separately reviewed SELECT grants.
COMMIT;
