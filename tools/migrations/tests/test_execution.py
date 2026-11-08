from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import cloud_run
from policy import LOCK,GuardError


class FakeDatabase:
    def __init__(self,fail_apply=False):self.calls=[];self.fail_apply=fail_apply
    def cli(self,work,dry_run):
        self.calls.append(dry_run)
        if dry_run:return 'Would push these migrations:\n'+LOCK['migration']
        if self.fail_apply:raise GuardError('Artificial uncertain result')
        return 'applied'


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory();self.root=Path(self.directory.name)
        self.context={'operation':'preview','run_id':'10','sha':'a'*40,'expected_ref':'a'*20}
        self.initial={'auth_users':0,'app_tables':0,'private_schema':False,'access_rpc':False,'versions':[]}
    def tearDown(self):self.directory.cleanup()

    def execute(self,db,preview=None):
        with patch.object(cloud_run,'inspect',return_value=self.initial),\
             patch.object(cloud_run,'baseline_fingerprint',return_value='stable'),\
             patch.object(cloud_run,'postflight',return_value={'verified':True}),\
             patch.object(cloud_run,'create_backup',return_value={'verified':True,'local_plan':{
                 'target':'isolated_restored_snapshot','network':'none','tls':'verify-full',
                 'versions':[],'pending':[LOCK['version']],'scoped_state_unchanged':True}}):
            return cloud_run.execute(self.context,db,self.root,ROOT,self.root,self.root/'public',self.root/'backup',
                'artificial-passphrase-only',preview,cli_binary='/artificial/supabase')

    def test_preview_never_calls_mutating_cli(self):
        db=FakeDatabase();receipt=self.execute(db)
        self.assertEqual(db.calls,[]);self.assertEqual(receipt['status'],'preview_passed')
        self.assertEqual(receipt['cli_dry_run_target'],'isolated_restored_snapshot')

    def test_apply_has_one_preliminary_and_exactly_one_mutation(self):
        db=FakeDatabase();self.context['operation']='apply'
        receipt=self.execute(db,{'baseline_fingerprint':'stable'})
        self.assertEqual(db.calls,[True,False]);self.assertEqual(receipt['status'],'applied_and_catalog_verified')

    def test_unknown_result_is_recorded_and_never_retried(self):
        db=FakeDatabase(True);self.context['operation']='apply'
        with self.assertRaises(GuardError):self.execute(db,{'baseline_fingerprint':'stable'})
        self.assertEqual(db.calls,[True,False])
        receipt=json.loads((self.root/'public/apply.json').read_text())
        self.assertEqual(receipt['status'],'apply_outcome_unknown')

    def test_changed_baseline_or_missing_preview_never_apply(self):
        for preview in [None,{'baseline_fingerprint':'changed'}]:
            db=FakeDatabase();self.context['operation']='apply'
            with self.subTest(preview=preview),self.assertRaises(GuardError):self.execute(db,preview)
            self.assertEqual(db.calls,[True])

    def test_inspection_after_unknown_result_never_retries_or_runs_cli(self):
        self.context['operation']='inspect';self.initial.update({'app_tables':4,'versions':[LOCK['version']]})
        db=FakeDatabase();receipt=self.execute(db)
        self.assertEqual(db.calls,[]);self.assertEqual(receipt['status'],'read_only_inspection')
        self.assertEqual(receipt['observed']['app_tables'],4)


if __name__=='__main__':unittest.main(verbosity=2)
