"""Synthetic data only; a private Unix socket, never the hosted Supabase endpoint."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import unittest

from tools.current_backup import backup as b
from tools.orders_migration.local import Native  # TEST ONLY; not imported by backup runtime.


@unittest.skipUnless(os.environ.get('ORBITA_ORDERS_PG_BIN'), 'Local PostgreSQL 17 binaries required')
class CurrentBackupIntegration(unittest.TestCase):
    def test_synthetic_auth_export_encryption_restore_and_unsafe_acl_rejection(self):
        local = Native()
        try:
            self._fixture(local)
            env = dict(local.env, PGHOST=str(local.socket), PGPORT='55432', PGUSER=b.READER,
                       PGDATABASE='postgres', PGOPTIONS='-c default_transaction_read_only=on')
            with tempfile.TemporaryDirectory(dir=local.path) as directory:
                work = Path(directory); dump = work/'database.dump'
                with b.ReadSession(env,local.bin) as session:
                    facts = json.loads(session.select(b.PREFLIGHT_SQL))
                    b.validate_facts(facts,require_tls=False)  # Only this test's Unix socket.
                    with self.assertRaisesRegex(b.BackupError,'TLS_REQUIRED'):
                        b.validate_facts(facts)
                    manifest = b.export(session,local.bin,dump,require_tls=False)
                self.assertEqual(manifest['tables']['auth.users']['rows'],2)
                self.assertEqual(manifest['tables']['auth.refresh_tokens']['rows'],1)
                self.assertEqual(manifest['catalog']['history'],['20260401000000'])
                self.assertEqual(manifest['sequences']['public.fixture_sequence']['last_value'],7)
                phrase = 'synthetic-current-backup-phrase-not-for-production'
                output = work/'artifact'
                b.package(dump,manifest,phrase,work,output,'a'*40,'123')
                b.crypt(output/'snapshot.tar.gpg',work/'owner.tar',phrase,work/'owner-gpg',decrypt=True)
                with tarfile.open(work/'owner.tar') as archive:
                    restored_dump = work/'restored.dump'
                    restored_dump.write_bytes(archive.extractfile('database.dump').read())
                    archived_manifest = json.load(archive.extractfile('manifest.json'))
                self.assertEqual(hashlib.sha256(restored_dump.read_bytes()).hexdigest(),
                                 archived_manifest['dump_sha256'])
                # A second disposable DB in the same socket-only cluster. No cloud credentials.
                local.psql('CREATE DATABASE backup_restore;')
                self._command(local,'psql','-d','backup_restore','-c','DROP SCHEMA public;')
                self._command(local,'pg_restore','--exit-on-error','-d','backup_restore',str(restored_dump))
                with b.ReadSession({**env,'PGDATABASE':'backup_restore'},local.bin) as restored:
                    for name,expected in manifest['tables'].items():
                        schema,table = name.split('.')
                        self.assertEqual(b.table_fingerprint(restored,schema,table),expected,name)
                    self.assertEqual(restored.select('SELECT last_value FROM public.fixture_sequence'),'7')
                    self.assertEqual(restored.select('SELECT count(*) FROM pg_catalog.pg_policy'),'1')
                self.assertEqual(local.query('SELECT count(*) FROM auth.users;'),'2')
                self.assertEqual(local.query('SELECT count(*) FROM supabase_migrations.schema_migrations;'),'1')
                self.assertEqual(local.query("SELECT to_regclass('public.orbita_orders') IS NULL;"),'t')
                # ACL must also deny writes if the caller requests a READ WRITE transaction.
                for sql in ("INSERT INTO auth.users VALUES (3,'forbidden')",
                            "UPDATE auth.users SET encrypted_password='forbidden'",
                            'DELETE FROM auth.users', 'TRUNCATE auth.users',
                            'CREATE TABLE public.forbidden (id int)',
                            'CREATE TEMP TABLE forbidden (id int)',
                            "SELECT nextval('public.fixture_sequence')"):
                    result = subprocess.run([str(local.bin/'psql'),'-X','-Atq','--set=ON_ERROR_STOP=1'],
                        input='BEGIN READ WRITE;'+sql+';ROLLBACK;', env=env,
                        capture_output=True,text=True,timeout=15)
                    self.assertNotEqual(result.returncode,0,sql)
                # PUBLIC and column-only grants must be checked effectively, before pg_dump.
                unsafe_grants = [
                    ('GRANT TEMP ON DATABASE postgres TO PUBLIC;',
                     'REVOKE TEMP ON DATABASE postgres FROM PUBLIC;'),
                    ('GRANT UPDATE(encrypted_password) ON auth.users TO orbita_backup_reader;',
                     'REVOKE UPDATE(encrypted_password) ON auth.users FROM orbita_backup_reader;'),
                    ('GRANT EXECUTE ON FUNCTION pg_catalog.lo_create(oid) TO PUBLIC;',
                     'REVOKE EXECUTE ON FUNCTION pg_catalog.lo_create(oid) FROM PUBLIC;'),
                    ("CREATE FUNCTION public.unsafe_function() RETURNS void LANGUAGE sql AS 'SELECT NULL';",
                     'DROP FUNCTION public.unsafe_function();'),
                    ("CREATE FUNCTION public.unsafe_definer() RETURNS int LANGUAGE sql STABLE SECURITY DEFINER AS 'SELECT 1';",
                     'DROP FUNCTION public.unsafe_definer();')]
                for grant,undo in unsafe_grants:
                    with self.subTest(grant=grant):
                        local.psql(grant)
                        try:
                            with b.ReadSession(env,local.bin) as session:
                                with self.assertRaisesRegex(b.BackupError,'UNSAFE_READER_PRIVILEGES'):
                                    b.export(session,local.bin,work/'must-not-exist.dump',require_tls=False)
                            self.assertFalse((work/'must-not-exist.dump').exists())
                        finally:
                            local.psql(undo)
                self.assertEqual(local.query('SELECT count(*) FROM auth.users;'),'2')
        finally:
            local.close()

    @staticmethod
    def _command(local,program,*args):
        result = subprocess.run([str(local.bin/program),'-h',str(local.socket),'-p','55432',
                                 '-U','postgres',*args],env=local.env,capture_output=True,timeout=60)
        if result.returncode:
            raise AssertionError('Synthetic local restore command failed; no raw output.')

    @staticmethod
    def _fixture(local):
        local.psql('''
CREATE SCHEMA auth;
CREATE SCHEMA orbita_mobile_private;
CREATE SCHEMA supabase_migrations;
CREATE TABLE auth.users (id int PRIMARY KEY, encrypted_password text);
INSERT INTO auth.users VALUES (1,'SYNTHETIC_HASH_ONE'),(2,'SYNTHETIC_HASH_TWO');
ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.users FORCE ROW LEVEL SECURITY;
CREATE POLICY own_row ON auth.users USING (false);
CREATE TABLE auth.refresh_tokens (token text);
INSERT INTO auth.refresh_tokens VALUES ('SYNTHETIC_REFRESH_TOKEN');
CREATE TABLE public.fixture (id int PRIMARY KEY, label text);
INSERT INTO public.fixture VALUES (1,'synthetic fixture');
CREATE SEQUENCE public.fixture_sequence START WITH 7;
CREATE TABLE orbita_mobile_private.roles (id int, role text);
INSERT INTO orbita_mobile_private.roles VALUES (1,'passenger'),(2,'driver');
CREATE TABLE supabase_migrations.schema_migrations (version text PRIMARY KEY, statements text[]);
INSERT INTO supabase_migrations.schema_migrations VALUES ('20260401000000',ARRAY['synthetic history']);
CREATE ROLE orbita_backup_reader LOGIN BYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
ALTER ROLE orbita_backup_reader SET default_transaction_read_only=on;
REVOKE TEMP ON DATABASE postgres FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA auth,public,orbita_mobile_private,supabase_migrations TO orbita_backup_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA auth,public,orbita_mobile_private,supabase_migrations TO orbita_backup_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO orbita_backup_reader;
''')
        # Changes only this throwaway cluster; never proposed for the hosted project.
        for row in json.loads(local.query("SELECT json_agg(p.oid::regprocedure::text) FROM pg_proc p "
                "JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='pg_catalog' "
                "AND p.proname IN ("+','.join("'"+name+"'" for name in b.WRITE_LO)+");")):
            local.psql('REVOKE EXECUTE ON FUNCTION '+row+' FROM PUBLIC;')


if __name__ == '__main__':
    unittest.main()
