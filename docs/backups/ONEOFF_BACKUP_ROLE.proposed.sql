-- PROPOSAL ONLY. Owner selects orbita-mobile-test / fjqghohhohgvwlmefdmo.
-- Separate approval required. No password, LOGIN or user-data changes here.
-- Official Supabase broad-read profile, not the original strict reader.
BEGIN;
SET LOCAL statement_timeout='10s';
SET LOCAL lock_timeout='2s';
SET LOCAL search_path=pg_catalog;
DO $guard$
BEGIN
 IF current_database()<>'postgres' OR current_setting('server_version_num')::int NOT BETWEEN 170000 AND 179999
  OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=current_user AND rolcreaterole AND rolbypassrls) THEN
  RAISE EXCEPTION 'ONEOFF_SETUP_AUTHORITY_REJECTED';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='orbita_oneoff_backup_reader') THEN
  RAISE EXCEPTION 'ONEOFF_READER_EXISTS_STOP';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.roleid
  WHERE r.rolname='pg_read_all_data' AND m.member=(SELECT oid FROM pg_roles WHERE rolname=current_user) AND m.admin_option)
  AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=current_user AND rolsuper) THEN
  RAISE EXCEPTION 'ONEOFF_READ_MEMBERSHIP_AUTHORITY_MISSING';
 END IF;
 IF to_regclass('auth.users') IS NULL OR to_regclass('public.orbita_profiles') IS NULL
  OR to_regclass('supabase_migrations.schema_migrations') IS NULL THEN
  RAISE EXCEPTION 'ONEOFF_TARGET_SCHEMA_REJECTED';
 END IF;
END $guard$;
CREATE ROLE orbita_oneoff_backup_reader NOLOGIN PASSWORD NULL
 NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS
 CONNECTION LIMIT 2 VALID UNTIL '-infinity';
GRANT pg_read_all_data TO orbita_oneoff_backup_reader WITH INHERIT TRUE, SET FALSE;
ALTER ROLE orbita_oneoff_backup_reader SET default_transaction_read_only=on;
ALTER ROLE orbita_oneoff_backup_reader SET statement_timeout='30s';
ALTER ROLE orbita_oneoff_backup_reader SET lock_timeout='5s';
ALTER ROLE orbita_oneoff_backup_reader SET idle_in_transaction_session_timeout='180s';
ALTER ROLE orbita_oneoff_backup_reader SET search_path=pg_catalog;
GRANT CONNECT ON DATABASE postgres TO orbita_oneoff_backup_reader;
COMMIT;
-- Remains NOLOGIN, password NULL and expired. Existing managed roles untouched.
