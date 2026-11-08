"""First migration body; run only inside Database's guarded write transaction."""
from pathlib import Path
import hashlib
import re

from policy import LOCK,require


def migration_body(root):
    directory=Path(root)/'supabase/migrations'
    require(sorted(p.name for p in directory.glob('*.sql'))==[LOCK['migration']],
            'Нужен ровно один согласованный файл миграции.')
    source=(directory/LOCK['migration']).read_bytes()
    require(hashlib.sha256(source).hexdigest()==LOCK['migration_sha256'],
            'SQL-файл изменился перед применением.')
    match=re.fullmatch(r'([0-9]{1,20})_([A-Za-z0-9_]+)\.sql',LOCK['migration'])
    require(match is not None and match[1]==LOCK['version'],'Версия и имя миграции не совпали.')
    delimiter=b'$orbita_migration_source$'
    require(delimiter not in source,'Не удалось безопасно подготовить запись истории.')
    # History is initialized under the same limits/transaction as application DDL.
    # The transaction lock plus a live guard also reject a concurrent/repeated Apply.
    before=b"""SELECT pg_catalog.pg_advisory_xact_lock(76421,3);
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations(
  version text PRIMARY KEY, statements text[], name text);
DO $orbita_initial$
BEGIN
  IF EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations)
    OR EXISTS(SELECT 1 FROM auth.users)
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname IN
        ('orbita_profiles','orbita_user_roles','orbita_account_access','orbita_access_audit'))
    OR EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='orbita_mobile_private')
    OR pg_catalog.to_regprocedure('public.orbita_get_access()') IS NOT NULL
  THEN RAISE EXCEPTION 'Initial migration conditions changed; no automatic retry';
  END IF;
END;
$orbita_initial$;
"""
    # CLI 3.0.0 history format: exact source text is one text[] entry, without
    # the executor's transaction/limit/history commands. No repair or reset.
    history=(b"\nINSERT INTO supabase_migrations.schema_migrations(version,statements,name) VALUES ('"+
        LOCK['version'].encode('ascii')+b"',ARRAY["+delimiter+source+delimiter+b"],'"+
        match[2].encode('ascii')+b"');\n")
    return before+source+history
