"""Atomic Apply regressions; synthetic data only, no processes or cloud."""
from pathlib import Path
import copy
import json
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import cloud_run
import dbtools
from policy import LOCK,GuardError

EXECUTOR='postgres_transaction_v1'
URL='postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full'


def preview():
    return {'status':'preview_passed','source_sha':'a'*40,'project_ref':'a'*20,
        'migration_sha256':LOCK['migration_sha256'],'pending':[LOCK['version']],
        'apply_executor':EXECUTOR,'baseline_fingerprint':'stable','backup':{'local_plan':{
            'target':'isolated_restored_snapshot','network':'none','tls':'verify-full',
            'versions':[],'pending':[LOCK['version']],'scoped_state_unchanged':True}}}


class AtomicApplyTests(unittest.TestCase):
    def database(self,read_only=False):
        return dbtools.Database(URL,'a'*20,'artificial-only-db-password','/tmp/artificial-ca',read_only=read_only)

    def method(self,db):
        method=getattr(db,'apply_migration',None)
        self.assertTrue(callable(method),'Missing atomic PostgreSQL executor')
        return method

    def test_read_only_client_cannot_apply(self):
        db=self.database(True)
        with patch.object(db,'tool') as tool,self.assertRaises(GuardError):self.method(db)(ROOT)
        tool.assert_not_called()

    def test_changed_or_extra_source_is_rejected_before_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);migrations=root/'supabase/migrations';migrations.mkdir(parents=True)
            source=migrations/LOCK['migration'];shutil.copyfile(ROOT/'supabase/migrations'/LOCK['migration'],source)
            db=self.database()
            for extra in [False,True]:
                if extra:
                    shutil.copyfile(ROOT/'supabase/migrations'/LOCK['migration'],source)
                    (migrations/'209901010001_extra.sql').write_text('select 1;')
                else:source.write_text(source.read_text()+'\nselect 1;')
                with self.subTest(extra=extra),patch.object(db,'tool') as tool,self.assertRaises(GuardError):
                    self.method(db)(root)
                tool.assert_not_called()

    def test_one_marked_transaction_sets_limits_before_history_and_preserves_source(self):
        db=self.database();token='orbita_mig_'+'a'*32
        original=(ROOT/'supabase/migrations'/LOCK['migration']).read_bytes()
        with patch.object(dbtools,'_new_operation_token',return_value=token),\
             patch.object(db,'_owned_tool',return_value=b'') as process:
            self.method(db)(ROOT)
        process.assert_called_once()
        args,kwargs=process.call_args
        self.assertEqual(args[0],'psql');self.assertIn('ON_ERROR_STOP=1',args[1])
        self.assertEqual(args[2],token);self.assertEqual(kwargs['timeout'],120)
        sql=kwargs['input']
        self.assertTrue(sql.startswith(b'BEGIN TRANSACTION READ WRITE;'))
        self.assertTrue(sql.endswith(b'\nCOMMIT;'))
        first_ddl=sql.index(b'CREATE SCHEMA IF NOT EXISTS supabase_migrations')
        for setting in [b'SET LOCAL statement_timeout=30000;',b'SET LOCAL lock_timeout=5000;',
                        b'SET LOCAL idle_in_transaction_session_timeout=15000;']:
            self.assertLess(sql.index(setting),first_ddl)
        self.assertLess(sql.index(b'pg_settings'),first_ddl)
        self.assertIn(("SET LOCAL application_name='"+token+"';").encode(),sql)
        self.assertIn(original,sql)
        self.assertIn(b'INSERT INTO supabase_migrations.schema_migrations',sql)
        self.assertEqual((ROOT/'supabase/migrations'/LOCK['migration']).read_bytes(),original)

    def test_write_boundary_requires_psql_stop_on_error_and_writable_mode(self):
        for readonly,program,args,flags in [(True,'psql',['ON_ERROR_STOP=1'],{}),
                (False,'pg_dump',[],{}),(False,'psql',[],{}),
                (False,'psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-c','select 1;'],{}),
                (False,'psql',['ON_ERROR_STOP=1'],{'read_only_sql':True})]:
            db=self.database(readonly)
            with self.subTest(readonly=readonly,program=program,flags=flags),\
                 patch.object(db,'_owned_tool') as process,self.assertRaises(GuardError):
                db.tool(program,args,input=b'select 1;',atomic_write=True,**flags)
            process.assert_not_called()

    def execute(self,db,directory,proof,fail_postflight=False):
        initial={'auth_users':0,'app_tables':0,'private_schema':False,'access_rpc':False,'versions':[]}
        with patch.object(cloud_run,'inspect',return_value=initial),\
             patch.object(cloud_run,'baseline_fingerprint',return_value='stable'),\
             patch.object(cloud_run,'postflight',return_value={'verified':True},
                side_effect=GuardError('artificial-private-postflight-error') if fail_postflight else None):
            return cloud_run.execute({'operation':'apply','run_id':'10','sha':'a'*40,'expected_ref':'a'*20},
                db,directory,ROOT,directory,directory/'public',directory/'backup','unused',proof)

    def fake_database(self,fail=False):
        class Database:
            calls=[]
            failure_category='CLIENT_DEADLINE_UNCERTAIN'
            def cli(self,*args):raise AssertionError('Cloud CLI is forbidden, including dry-run')
            def apply_migration(self,root):
                self.calls.append('atomic')
                if fail:raise GuardError('artificial-private-error')
        return Database()

    def test_apply_calls_atomic_executor_once_and_never_remote_cli(self):
        db=self.fake_database()
        with tempfile.TemporaryDirectory() as directory:
            result=self.execute(db,Path(directory),preview())
            self.assertEqual(db.calls,['atomic'])
            self.assertEqual(result['status'],'applied_and_catalog_verified')
            self.assertEqual(result['executor'],EXECUTOR)

    def test_unknown_result_remains_recorded_without_retry_or_private_error(self):
        db=self.fake_database(True)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with self.assertRaises(GuardError):self.execute(db,root,preview())
            receipt=(root/'public/apply.json').read_text()
            self.assertEqual(json.loads(receipt)['status'],'apply_outcome_unknown')
            self.assertEqual(db.calls,['atomic']);self.assertNotIn('artificial-private-error',receipt)

    def test_missing_changed_or_legacy_preview_never_reaches_mutation(self):
        bad=[None]
        for key,value in [('baseline_fingerprint','changed'),('apply_executor','legacy_cli'),('apply_executor',None),
                ('pending',[]),('source_sha','b'*40),('project_ref','b'*20),('migration_sha256','b'*64)]:
            p=copy.deepcopy(preview());p[key]=value;bad.append(p)
        for proof in bad:
            db=self.fake_database()
            with self.subTest(proof=proof),tempfile.TemporaryDirectory() as directory,self.assertRaises(GuardError):
                self.execute(db,Path(directory),proof)
            self.assertEqual(db.calls,[])

    def test_postflight_failure_after_commit_is_unknown_and_never_reapplied(self):
        db=self.fake_database()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with self.assertRaises(GuardError):self.execute(db,root,preview(),fail_postflight=True)
            receipt=(root/'public/apply.json').read_text()
            self.assertEqual(db.calls,['atomic'])
            self.assertEqual(json.loads(receipt)['status'],'apply_outcome_unknown')
            self.assertNotIn('artificial-private-postflight-error',receipt)


if __name__=='__main__':unittest.main(verbosity=2)
