from pathlib import Path
import copy
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml
from tools.current_backup import backup as b

ROOT = Path(__file__).resolve().parents[3]


def valid_facts():
    result = dict(current_user=b.READER, session_user=b.READER, read_only='on',
                  default_read_only='on', version=170011, tls=True, scoped_schemas=4,
                  missing_reads=0)
    result['role'] = dict(super=False, createdb=False, createrole=False, replication=False,
                          inherit=False, bypassrls=True, login=True, default_ro=True)
    for name in ('memberships','database_write','ownership','schema_create','table_writes',
                 'sequence_writes','outside_reads','definers','large_object_writes',
                 'extension_side_effects','grant_options'):
        result[name] = 0
    return result


class BackupTests(unittest.TestCase):
    def test_source_requires_owner_exact_commit_project_and_first_manual_attempt(self):
        sha = 'a' * 40
        env = dict(GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REPOSITORY=b.REPOSITORY,
                   GITHUB_REF=b.BRANCH, GITHUB_ACTOR='primord1aal',
                   GITHUB_TRIGGERING_ACTOR='primord1aal', GITHUB_RUN_ATTEMPT='1',
                   GITHUB_SHA=sha, GITHUB_RUN_ID='123', ORBITA_BACKUP_APPROVED_SHA=sha,
                   ORBITA_BACKUP_PROJECT_REF=b.PROJECT, ORBITA_BACKUP_CONFIRMATION='BACKUP_ONLY')
        with patch.object(b, 'run', side_effect=[sha.encode(), b'']):
            b.validate_source(env, ROOT)
        for key, value in (('GITHUB_EVENT_NAME','push'), ('GITHUB_REPOSITORY','other/repo'),
                           ('GITHUB_REF','refs/heads/main'), ('GITHUB_ACTOR','someone'),
                           ('GITHUB_TRIGGERING_ACTOR','someone'), ('GITHUB_RUN_ATTEMPT','2'),
                           ('ORBITA_BACKUP_APPROVED_SHA','b'*40),
                           ('ORBITA_BACKUP_PROJECT_REF',b.FORBIDDEN),
                           ('ORBITA_BACKUP_CONFIRMATION','APPLY'), ('GITHUB_RUN_ID','x')):
            with self.subTest(key=key), patch.object(b, 'run') as run:
                with self.assertRaises(b.BackupError):
                    b.validate_source({**env,key:value}, ROOT)
                run.assert_not_called()
        for results in ([b'b'*40,b''], [sha.encode(),b' M tracked']):
            with patch.object(b, 'run', side_effect=results), self.assertRaises(b.BackupError):
                b.validate_source(env,ROOT)

    def test_connection_pins_target_tls_and_drops_inherited_credentials(self):
        with patch.dict(os.environ, {'GH_TOKEN':'do-not-inherit','PGSERVICE':'unsafe'}):
            env = b.connection_env('synthetic-reader-password', '/private/ca.pem')
        self.assertEqual(env['PGSSLMODE'], 'verify-full')
        self.assertEqual(env['PGUSER'], b.READER+'.'+b.PROJECT)
        self.assertEqual(env['PGHOST'], 'aws-0-eu-north-1.pooler.supabase.com')
        self.assertNotIn('GH_TOKEN',env)
        self.assertNotIn('PGSERVICE',env)
        self.assertNotIn('PGTARGETSESSIONATTRS',env)
        self.assertIn('default_transaction_read_only=on',env['PGOPTIONS'])

    def test_preflight_fails_closed_for_effective_writes_and_incomplete_reader(self):
        facts = valid_facts(); b.validate_facts(facts)
        for key in ('memberships','database_write','ownership','schema_create','table_writes',
                    'sequence_writes','outside_reads','definers','large_object_writes',
                    'extension_side_effects','grant_options','missing_reads'):
            with self.subTest(key=key), self.assertRaises(b.BackupError):
                b.validate_facts({**facts,key:1})
        for key, value in (('current_user','postgres'), ('session_user','postgres'),
                           ('read_only','off'), ('default_read_only','off'),
                           ('version',160000), ('tls',False), ('scoped_schemas',3)):
            with self.subTest(key=key), self.assertRaises(b.BackupError):
                b.validate_facts({**facts,key:value})
        for name in facts['role']:
            broken = copy.deepcopy(facts); broken['role'][name] = not broken['role'][name]
            with self.subTest(role=name), self.assertRaises(b.BackupError):
                b.validate_facts(broken)

    def test_select_rejects_arbitrary_commands_before_transport(self):
        session = b.ReadSession({})
        with patch.object(session,'_exchange') as query:
            for sql in ('DELETE FROM public.x', 'SELECT 1; DELETE FROM public.x',
                        'SELECT 1 -- unsafe', 'SELECT 1 /* unsafe */', 'SELECT 1\\gexec'):
                with self.assertRaises(b.BackupError):
                    session.select(sql)
            query.assert_not_called()

    def test_client_failures_do_not_expose_stderr_stdout_or_password(self):
        raw = b'private connection password and row content'
        with patch.object(b.subprocess,'run',return_value=subprocess.CompletedProcess([],1,raw,raw)):
            with self.assertRaisesRegex(b.BackupError, '^CLIENT_FAILED$'):
                b.run(['pg_dump'])
        with self.assertRaisesRegex(b.BackupError,'^PROGRAM_REJECTED$'):
            b.run(['psql'])

    def test_encrypt_roundtrip_and_only_three_safe_artifacts(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder); dump = directory/'database.dump'
            secret_fixture = b'SYNTHETIC_AUTH_REFRESH_TOKEN_NOT_A_REAL_SECRET'
            dump.write_bytes(secret_fixture)
            manifest = {'dump_sha256':hashlib.sha256(secret_fixture).hexdigest()}
            output = directory/'output'
            result = b.package(dump,manifest,'synthetic-backup-phrase-long-enough',directory,
                               output,'a'*40,'123')
            self.assertEqual({p.name for p in output.iterdir()},
                             {'snapshot.tar.gpg','SHA256SUMS','receipt.json'})
            for path in output.iterdir():
                self.assertNotIn(secret_fixture,path.read_bytes())
            digest = hashlib.sha256((output/'snapshot.tar.gpg').read_bytes()).hexdigest()
            self.assertTrue((output/'SHA256SUMS').read_text().startswith(digest+'  '))
            self.assertFalse(result['isolated_restore_checked'])
            self.assertFalse(result['full_project_restore_proven'])
            with self.assertRaises(b.BackupError):
                b.crypt(output/'snapshot.tar.gpg',directory/'wrong.tar',
                        'incorrect-backup-phrase-long-enough',directory/'wrong-gpg',decrypt=True)
            receipt = json.loads((output/'receipt.json').read_text())
            self.assertEqual(receipt['encrypted_sha256'],digest)

    def test_failed_encryption_produces_no_upload_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder); dump = directory/'database.dump'; dump.write_bytes(b'fixture')
            with patch.object(b,'crypt',side_effect=b.BackupError('CLIENT_FAILED')):
                with self.assertRaises(b.BackupError):
                    b.package(dump,{},'synthetic-backup-phrase-long-enough',directory,
                              directory/'output','a'*40,'123')
            self.assertFalse((directory/'output').exists())

    def test_workflow_is_manual_backup_only_and_uploads_no_plaintext(self):
        raw = (ROOT/'.github/workflows/orbita-current-backup.yml').read_text()
        workflow = yaml.load(raw,Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow['on']),{'workflow_dispatch'})
        self.assertEqual(set(workflow['on']['workflow_dispatch']['inputs']),
                         {'approved_sha','project_ref','confirmation'})
        self.assertEqual(workflow['permissions'],{'contents':'read'})
        self.assertEqual(set(workflow['jobs']),{'verify','backup'})
        self.assertNotIn('secrets.',json.dumps(workflow['jobs']['verify']))
        backup = workflow['jobs']['backup']
        self.assertEqual(backup['environment'],'orbita-mobile-test-backups')
        uploads = [s for s in backup['steps'] if s.get('uses','').startswith('actions/upload-artifact@')]
        self.assertEqual(len(uploads),1)
        upload = uploads[0]; self.assertEqual(upload['if'],'success()')
        self.assertEqual(upload['with']['retention-days'],'3')
        paths = upload['with']['path'].splitlines()
        self.assertEqual([Path(p).name for p in paths],['snapshot.tar.gpg','SHA256SUMS','receipt.json'])
        self.assertNotIn('*',upload['with']['path'])
        self.assertEqual(raw.count('secrets.'),2)
        for job in workflow['jobs'].values():
            self.assertIn('github.run_attempt == 1',job['if'])
            self.assertIn("github.triggering_actor == 'primord1aal'",job['if'])
        runtime = '\n'.join(p.read_text() for p in (ROOT/'tools/current_backup').glob('*.py'))
        for forbidden in ('tools.migrations','orders_migration','pg_cancel_backend','pg_terminate_backend',
                          'pg_restore --dbname','--clean','--create','execute_sql'):
            self.assertNotIn(forbidden,runtime)
        # Existing cloud migration stops must remain independent of this workflow.
        for file,jobs in (('orbita-stage-3b.yml',('migration_entry','migration-preview','migration-apply')),
                          ('orbita-orders-migration.yml',('entry','guarded'))):
            old = yaml.load((ROOT/'.github/workflows'/file).read_text(),Loader=yaml.BaseLoader)
            for name in jobs:
                self.assertTrue(old['jobs'][name]['if'].rstrip().endswith('&& false'))


if __name__ == '__main__':
    unittest.main()
