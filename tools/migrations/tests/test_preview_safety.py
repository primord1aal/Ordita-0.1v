"""Preview never gives the cloud connection to CLI; models use fake data only."""
from pathlib import Path
import copy
import json
import subprocess
import sys
import tempfile
import unittest
import os
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import cloud_run
import dbtools
import policy
import local_plan


def plan():
    return {'target':'isolated_restored_snapshot','versions':[],
            'pending':[policy.LOCK['version']],'scoped_state_unchanged':True,
            'network':'none','tls':'verify-full'}


class PreviewSafetyTests(unittest.TestCase):
    def test_read_only_database_never_starts_remote_cli_even_for_dry_run(self):
        db=dbtools.Database('postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full',
            'a'*20,'artificial-password','/tmp/artificial-ca',read_only=True,check_read_only_session=False)
        with patch('subprocess.run',return_value=subprocess.CompletedProcess([],0,stdout=b'',stderr=b'')) as run:
            for dry_run in [True,False]:
                with self.subTest(dry_run=dry_run),self.assertRaises(policy.GuardError):db.cli('/tmp',dry_run)
        run.assert_not_called()

    def test_local_plan_proof_rejects_wrong_history_or_missing_safety(self):
        validate=getattr(policy,'validate_local_plan',None)
        self.assertTrue(callable(validate),'Missing validation of restored-snapshot plan')
        validate(plan(),[])
        for key,value in [('target','cloud'),('versions',['202001010001']),('pending',[]),
                ('pending',[policy.LOCK['version'],'202001010001']),('scoped_state_unchanged',False),
                ('network','bridge'),('tls','require')]:
            invalid=plan();invalid[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(policy.GuardError):validate(invalid,[])

    def execute(self,root,backup):
        state={'auth_users':0,'app_tables':0,'private_schema':False,'access_rpc':False,'versions':[]}
        class Database:
            def cli(self,*args):raise AssertionError('Cloud CLI must never be called by Preview')
        with patch.object(cloud_run,'inspect',return_value=state),\
             patch.object(cloud_run,'baseline_fingerprint',return_value='unchanged'),\
             patch.object(cloud_run,'create_backup',return_value=copy.deepcopy(backup)):
            return cloud_run.execute({'operation':'preview','sha':'a'*40,'run_id':'10','expected_ref':'a'*20},
                Database(),root,root,root,root/'public',root/'encrypted','artificial-passphrase-only',
                cli_binary='/artificial/verified-supabase')

    def test_preview_uses_restored_snapshot_and_marks_cli_scope_honestly(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            receipt=self.execute(root,{'encrypted_sha256':'c'*64,'decryption_checked':True,
                'local_restore_checked':True,'local_plan':plan()})
            self.assertEqual(receipt['pending'],[policy.LOCK['version']])
            self.assertEqual(receipt['cli_dry_run_target'],'isolated_restored_snapshot')
            self.assertEqual(receipt['backup']['local_plan'],plan())
            self.assertTrue((root/'public/preview.json').is_file())

    def test_missing_or_failed_local_plan_never_produces_success_receipt(self):
        for local_plan in [None,dict(plan(),pending=[]),dict(plan(),scoped_state_unchanged=False)]:
            with self.subTest(plan=local_plan),tempfile.TemporaryDirectory() as directory:
                root=Path(directory)
                with self.assertRaises(policy.GuardError):
                    self.execute(root,{'encrypted_sha256':'c'*64,'decryption_checked':True,
                        'local_restore_checked':True,'local_plan':local_plan})
                self.assertFalse((root/'public/preview.json').exists())

    def test_changed_cloud_state_after_export_never_produces_success_receipt(self):
        before={'auth_users':0,'app_tables':0,'private_schema':False,'access_rpc':False,'versions':[]}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            backup={'encrypted_sha256':'c'*64,'decryption_checked':True,'local_restore_checked':True,'local_plan':plan()}
            with patch.object(cloud_run,'inspect',side_effect=[before,dict(before,auth_users=1)]),\
                 patch.object(cloud_run,'baseline_fingerprint',return_value='stable'),\
                 patch.object(cloud_run,'create_backup',return_value=backup),self.assertRaises(policy.GuardError):
                cloud_run.execute({'operation':'preview'},object(),root,root,root,root/'public',root/'encrypted',
                    'fake-passphrase',cli_binary='/artificial/supabase')
            self.assertFalse((root/'public/preview.json').exists())

    def test_external_network_or_foreign_clone_is_rejected_before_cli_copy(self):
        cid='c'*64;token='a'*32
        for network,owner in [('bridge',token),('none','foreign')]:
            with self.subTest(network=network,owner=owner),\
                 patch.dict(os.environ,{'PGPASSWORD':'artificial-db-secret','GH_TOKEN':'artificial-gh-secret',
                    'ORBITA_BACKUP_PASSPHRASE':'artificial-backup-secret'}),\
                 patch.object(local_plan,'checked',return_value=json.dumps([cid,network,owner]).encode()) as command,\
                 self.assertRaises(policy.GuardError):
                local_plan.run_local_plan(cid,token,'/missing/cli',ROOT,[],'/tmp')
            self.assertEqual(command.call_count,1)
            self.assertIn('inspect',command.call_args.args[0])
            for key in ['PGPASSWORD','GH_TOKEN','ORBITA_BACKUP_PASSPHRASE']:
                self.assertNotIn(key,command.call_args.kwargs['env'])

    def test_foreign_clone_is_never_removed_and_cleanup_failure_cannot_pass(self):
        cid='c'*64;token='a'*32
        with patch.object(local_plan,'checked',return_value=json.dumps([cid,'none','foreign']).encode()) as command,\
             self.assertRaises(policy.GuardError):local_plan.cleanup_restore('local-copy',token,cid)
        self.assertEqual(command.call_count,1)
        with patch.object(local_plan,'checked',side_effect=[json.dumps([cid,'none',token]).encode(),
                policy.GuardError('artificial cleanup failure')]),self.assertRaises(policy.GuardError):
            local_plan.cleanup_restore('local-copy',token,cid)


if __name__=='__main__':unittest.main(verbosity=2)
