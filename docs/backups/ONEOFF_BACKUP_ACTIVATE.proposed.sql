-- PROPOSAL ONLY; after separate owner approval and interactive \password.
-- Run only in the already trusted cloud psql session for the approved project.
-- Does not contain or set the password. VALID UNTIL does not terminate sessions.
BEGIN;
SET LOCAL statement_timeout='10s';
SET LOCAL lock_timeout='2s';
DO $activation$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='orbita_oneoff_backup_reader' AND NOT rolsuper
  AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND rolbypassrls AND rolinherit) THEN
  RAISE EXCEPTION 'ONEOFF_READER_PROFILE_REJECTED';
 END IF;
 EXECUTE format('ALTER ROLE orbita_oneoff_backup_reader LOGIN VALID UNTIL %L',
                (clock_timestamp()+interval '1 hour')::text);
END $activation$;
COMMIT;
