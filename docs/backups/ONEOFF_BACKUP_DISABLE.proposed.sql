-- PROPOSAL ONLY; separate cleanup approval after encrypted backup acceptance.
-- Does not delete backup data, old phrases, roles, Secrets or running sessions.
ALTER ROLE orbita_oneoff_backup_reader NOLOGIN PASSWORD NULL VALID UNTIL '-infinity';
