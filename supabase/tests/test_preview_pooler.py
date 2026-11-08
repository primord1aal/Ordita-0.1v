"""Compatibility regressions against actual pinned Supavisor, never cloud."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch

from pooler_fixture import PoolerFixture,POOLER_URL,FAKE_REF,dbtools,ROOT,docker
import cloud_run
from policy import GuardError,LOCK


class PreviewPoolerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture=PoolerFixture()
        try:cls.fixture.start()
        except BaseException:
            # Keep diagnostics of fake-only startup failure before fixture cleanup.
            log=cls.fixture.path/'startup.log'
            if log.exists():print(log.read_text()[-5000:])
            cls.fixture.close();raise
        cls.records=[]

    @classmethod
    def tearDownClass(cls):
        try:
            out=ROOT/'build/preview-pooler-results.json';out.parent.mkdir(exist_ok=True)
            out.write_text(json.dumps({'pooler_image':dbtools.LOCK['test_pooler_image'],
                'network':'none + shared local namespace; no published ports',
                'client_tls':'verify-full; disposable local CA','records':cls.records},indent=2)+'\n')
        finally:cls.fixture.close()

    def test_startup_read_only_filter_reproduces_cloud_failure(self):
        result=self.fixture.pooler_query('show default_transaction_read_only;',
            options='-c default_transaction_read_only=on',target_attrs='read-only',check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('session is not read-only',result.stderr)
        self.records.append({'test':self.id(),'original_session_filter_rejected':True})

    def test_sql_read_only_is_confirmed_inside_transaction(self):
        result=self.fixture.pooler_query('begin transaction read only; show transaction_read_only; rollback;')
        self.assertEqual(result.stdout.strip(),'on')
        self.records.append({'test':self.id(),'transaction_read_only':'on'})

    def test_server_limits_are_set_inside_pooler_transaction(self):
        db=dbtools.Database(POOLER_URL,FAKE_REF,self.fixture.password,self.fixture.path/'ca.pem',
                            read_only=True,check_read_only_session=False)
        with patch.object(dbtools,'DOCKER',self.fixture.shim('pooler-limits-'+self.fixture.token)):
            result=json.loads(db.query("select json_build_object('read_only',current_setting('transaction_read_only'),"
                "'statement',current_setting('statement_timeout'),'lock',current_setting('lock_timeout'),"
                "'idle',current_setting('idle_in_transaction_session_timeout'));"))
        self.assertEqual(result,{'read_only':'on','statement':'30s','lock':'5s','idle':'15s'})
        self.records.append({'test':self.id(),'server_settings':result})

    def database(self):
        return dbtools.Database(POOLER_URL,FAKE_REF,self.fixture.password,self.fixture.path/'ca.pem',
                                read_only=True,check_read_only_session=False)

    def test_server_statement_timeout_really_cancels_query_through_pooler(self):
        db=self.database();token=uuid.uuid4().hex
        with patch.object(dbtools,'DOCKER',self.fixture.shim(token)),self.assertRaises(GuardError):
            db.tool('psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-Atq','--dbname',db.url],
                input=b'select pg_sleep(8);',timeout=4,read_only_sql=True)
        self.assertEqual(db.failure_category,'SERVER_STATEMENT_TIMEOUT')
        self.records.append({'test':self.id(),'server_timeout_ms':2000,'client_timeout_seconds':4,
                             'server_error_category':db.failure_category})

    def test_read_only_transaction_blocks_ddl_through_pooler(self):
        db=self.database();name='denied_'+uuid.uuid4().hex[:12]
        with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),self.assertRaises(GuardError):
            db.query('create table public.'+name+'(id integer);')
        self.assertEqual(self.fixture.query("select to_regclass('public."+name+"') is null;"),'t')
        self.records.append({'test':self.id(),'ddl_rejected_by_server':True})

    def test_pg_dump_uses_its_own_server_read_only_transaction(self):
        db=self.database();before=docker('logs',self.fixture.cid,check=False)
        with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)):
            data=db.dump(['public'])
        self.assertTrue(data.startswith(b'PGDMP'))
        after=docker('logs',self.fixture.cid,check=False)
        extra=(after.stdout+after.stderr)[len(before.stdout+before.stderr):]
        self.assertRegex(extra,r'SET TRANSACTION ISOLATION LEVEL [^\n]*READ ONLY')
        self.records.append({'test':self.id(),'native_pg_dump_read_only_confirmed':True,'format':'custom'})

    def test_complete_preview_encrypts_restores_and_plans_only_offline(self):
        binary=Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        db=self.database();name='empty_'+uuid.uuid4().hex[:12]
        self.fixture.query('create table public.'+name+'(id integer primary key);')
        try:
            with tempfile.TemporaryDirectory(prefix='orbita-preview-live-') as directory:
                root=Path(directory);backup=root/'encrypted';public=root/'public'
                with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),\
                     patch.object(db,'cli',side_effect=AssertionError('Cloud CLI forbidden')):
                    receipt=cloud_run.execute({'operation':'preview','run_id':'local','sha':'a'*40,'expected_ref':FAKE_REF},
                        db,root,ROOT,root,public,backup,'artificial-local-passphrase-'+uuid.uuid4().hex,cli_binary=binary)
                self.assertEqual(receipt['pending'],[LOCK['version']])
                self.assertEqual(receipt['cli_dry_run_target'],'isolated_restored_snapshot')
                self.assertTrue(receipt['backup']['decryption_checked'])
                self.assertTrue(receipt['backup']['local_restore_checked'])
                self.assertTrue(receipt['backup']['local_plan']['scoped_state_unchanged'])
                self.assertEqual([p.name for p in backup.iterdir()],['snapshot.tar.gpg'])
                self.assertEqual([p.name for p in public.iterdir()],['preview.json'])
                self.assertEqual(self.fixture.query("select to_regclass('supabase_migrations.schema_migrations') is null;"),'t')
                self.records.append({'test':self.id(),'encrypted_archive_checked':True,'decryption_checked':True,
                    'restore_checked':True,'offline_cli_only':True,'pending':[LOCK['version']],
                    'cloud_source_history_unchanged':True})
        finally:self.fixture.query('drop table public.'+name+';')

    def test_local_cli_timeout_stops_its_owned_clone(self):
        binary=Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        original=docker('ps','-aq','--no-trunc').stdout.split();real_run=subprocess.run;timed_out=[]
        def timeout(args,**kwargs):
            if '/tmp/orbita-supabase' in args and 'push' in args:
                timed_out.append(True)
                raise subprocess.TimeoutExpired(args,120,output=b'artificial-private-output')
            return real_run(args,**kwargs)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);db=self.database()
            with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),\
                 patch('subprocess.run',side_effect=timeout),self.assertRaises(GuardError):
                cloud_run.execute({'operation':'preview'},db,root,ROOT,root,root/'public',root/'encrypted',
                    'artificial-local-passphrase-'+uuid.uuid4().hex,cli_binary=binary)
            self.assertFalse((root/'public/preview.json').exists())
        self.assertEqual(set(docker('ps','-aq','--no-trunc').stdout.split()),set(original))
        self.assertEqual(timed_out,[True])
        self.records.append({'test':self.id(),'local_cli_timeout':'no_retry','owned_clone_removed':True})


if __name__=='__main__':unittest.main(verbosity=2)
