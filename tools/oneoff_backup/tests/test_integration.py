"""Synthetic PostgreSQL17 export/encryption/restore; no hosted connections."""
from pathlib import Path
import hashlib
import json
import os
import tempfile
import unittest

from tools.oneoff_backup import core as b
from tools.orders_migration.local import Native

ROOT=Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.environ.get('ORBITA_ORDERS_PG_BIN'),'Separately verified PostgreSQL17 required')
class OneoffIntegration(unittest.TestCase):
    def test_supported_role_full_snapshot_crypto_restore_and_rejection(self):
        local=Native()
        try:
            local.psql('''CREATE SCHEMA auth; CREATE SCHEMA orbita_mobile_private; CREATE SCHEMA supabase_migrations;
CREATE TABLE auth.users(id int PRIMARY KEY,encrypted_password text);
INSERT INTO auth.users VALUES(1,'SYNTHETIC_HASH_ONE'),(2,'SYNTHETIC_HASH_TWO');
ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY; ALTER TABLE auth.users FORCE ROW LEVEL SECURITY;
CREATE POLICY no_rows ON auth.users USING(false);
CREATE TABLE auth.refresh_tokens(user_id int REFERENCES auth.users(id),token text);
INSERT INTO auth.refresh_tokens VALUES(1,'SYNTHETIC_REFRESH_TOKEN');
CREATE TABLE public.orbita_profiles(user_id int PRIMARY KEY,name text);
INSERT INTO public.orbita_profiles VALUES(1,'Synthetic one'),(2,'Synthetic two');
CREATE TABLE public.orbita_user_roles(user_id int,role text);
INSERT INTO public.orbita_user_roles VALUES(1,'passenger'),(2,'driver');
CREATE SEQUENCE public.fixture_sequence START WITH 7;
CREATE TABLE orbita_mobile_private.fixture(id int,label text); INSERT INTO orbita_mobile_private.fixture VALUES(1,'synthetic');
CREATE TABLE supabase_migrations.schema_migrations(version text PRIMARY KEY,statements text[]);
INSERT INTO supabase_migrations.schema_migrations VALUES('202611050001',ARRAY['synthetic history']);
CREATE SCHEMA outside_scope; CREATE TABLE outside_scope.not_exported(secret text);
INSERT INTO outside_scope.not_exported VALUES('SYNTHETIC_OUTSIDE_NOT_IN_DUMP');
CREATE FUNCTION public.synthetic_volatile() RETURNS void LANGUAGE sql VOLATILE AS 'SELECT NULL';
''')
            local.psql((ROOT/'docs/backups/ONEOFF_BACKUP_ROLE.proposed.sql').read_text())
            self.assertEqual(local.query("SELECT rolcanlogin FROM pg_roles WHERE rolname='"+b.READER+"';"),'f')
            local.psql((ROOT/'docs/backups/ONEOFF_BACKUP_ACTIVATE.proposed.sql').read_text())
            env=dict(local.env,PGHOST=str(local.socket),PGPORT='55432',PGDATABASE='postgres',PGUSER=b.READER,
                PGOPTIONS='-c default_transaction_read_only=on')
            with tempfile.TemporaryDirectory(dir=local.path) as directory:
                root=Path(directory); dump=root/'database.dump'
                with b.base.ReadSession(env,local.bin) as session:
                    facts=json.loads(session.select(b.base.PREFLIGHT_SQL)); profile=json.loads(session.select(b.PROFILE_SQL))
                    b.validate(facts,profile,require_tls=False)
                    self.assertGreater(facts['outside_reads'],0)
                    self.assertTrue(facts['database_write'])  # PUBLIC TEMP intentionally remains.
                    self.assertGreater(facts['large_object_writes'],0)
                    self.assertGreater(facts['extension_side_effects'],0)
                    with self.assertRaises(b.base.BackupError):b.base.validate_facts(facts,require_tls=False)
                    original=session.select
                    def concurrent(sql):
                        value=original(sql)
                        if sql=='SELECT pg_export_snapshot()':
                            local.psql("INSERT INTO auth.users VALUES(3,'SYNTHETIC_LATER_HASH'); SELECT nextval('public.fixture_sequence');")
                        return value
                    session.select=concurrent
                    manifest=b.export(session,local.bin,dump,root,require_tls=False)
                self.assertEqual(manifest['tables']['auth.users']['rows'],2)
                self.assertEqual(manifest['tables']['auth.refresh_tokens']['rows'],1)
                self.assertNotIn('outside_scope.not_exported',manifest['tables'])
                self.assertTrue(manifest['sequences']['public.fixture_sequence']['is_called'])
                phrase='synthetic-oneoff-passphrase-not-for-production'
                manifest.update(source_sha='a'*40,run_id='123')
                staging=root/'staging'
                b.base.package(dump,manifest,phrase,root,staging,'a'*40,'123')
                accepted=root/'accepted'; restore_work=root/'restore';restore_work.mkdir()
                receipt=b.accept(staging,accepted,phrase,restore_work,local.bin,isolation='test_only_private_unix_socket')
                self.assertTrue(receipt['isolated_restore_checked'])
                self.assertEqual(receipt['project_ref'],b.base.PROJECT)
                self.assertFalse(receipt['full_project_restore_proven'])
                self.assertEqual({p.name for p in accepted.iterdir()},{'snapshot.tar.gpg','SHA256SUMS','receipt.json'})
                self.assertEqual(local.query('SELECT count(*) FROM auth.users;'),'3')
                self.assertEqual(local.query("SELECT count(*) FROM public.orbita_user_roles;"),'2')
                self.assertNotIn(b'SYNTHETIC_HASH_ONE',(accepted/'snapshot.tar.gpg').read_bytes())
                bad=root/'tampered';bad.mkdir()
                for file in staging.iterdir():(bad/file.name).write_bytes(file.read_bytes())
                (bad/'snapshot.tar.gpg').write_bytes(b'tampered')
                with self.assertRaisesRegex(b.base.BackupError,'CIPHER_CHECKSUM_MISMATCH'):
                    b.decrypt(bad,phrase,root/'unused')
            local.psql((ROOT/'docs/backups/ONEOFF_BACKUP_DISABLE.proposed.sql').read_text())
            self.assertEqual(local.query("SELECT rolcanlogin FROM pg_roles WHERE rolname='"+b.READER+"';"),'f')
        finally:local.close()


if __name__=='__main__':unittest.main()
