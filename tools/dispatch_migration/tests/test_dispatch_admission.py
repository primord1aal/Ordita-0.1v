"""Synthetic native PG tests for the guarded wrapper; no cloud credentials."""
from pathlib import Path
import hashlib
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from tools.dispatch_migration.policy import (LOCK, GuardError, sources, history, validate_source,
    validate_request, validate_environment, validate_receipt, no_prior_apply)
from tools.dispatch_migration.state import capture, state_hash, protected_hash, validate_before
from tools.dispatch_migration.atomic import body, postflight_sql
from tools.orders_migration.local import Native
from tools.orders_migration.atomic import body as second_body
from tools.orders_migration.catalog import state_hash as second_hash
from atomic_apply import migration_body

ROOT=Path(__file__).resolve().parents[3]

class PolicyTests(unittest.TestCase):
    def context(self):
        return dict(event='workflow_dispatch',operation='preview',repository=LOCK['repository'],
          git_ref='refs/heads/'+LOCK['branch'],attempt='1',repo_enabled='true',sha='a'*40,
          approved_sha='a'*40,checkout_sha='a'*40,env_enabled='true',allowed_sha='a'*40,
          allowed_operation='preview',expected_ref=LOCK['project_ref'],requested_ref=LOCK['project_ref'],forbidden_ref=LOCK['forbidden_ref'])
    def test_exact_sources_and_separate_admission(self):
        self.assertEqual(hashlib.sha256(sources(ROOT)[-1]).hexdigest(),LOCK['sha256'])
        validate_request(self.context(),ROOT)
        for key,value in [('attempt','2'),('allowed_sha','b'*40),('operation','apply'),
                          ('requested_ref',LOCK['forbidden_ref']),('git_ref','refs/heads/main'),
                          ('git_ref','refs/heads/codex/orbita-flutter-design-integration')]:
            with self.subTest(key=key), self.assertRaises(GuardError):
                validate_request({**self.context(),key:value},ROOT)
        with self.assertRaises(GuardError):
            validate_source(self.context(),ROOT,{'ORBITA_DISPATCH_ALLOWED_SHA':'a'*40})
    def test_two_exact_rules_do_not_relax_source_or_owner_review(self):
        env={'name':LOCK['environment'],'id':1,'can_admins_bypass':False,
          'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True},
          'protection_rules':[{'type':'required_reviewers','reviewers':[{'type':'User','reviewer':{'login':'primord1aal'}}]}]}
        reviews=[{'state':'approved','user':{'login':'primord1aal'},'environments':[{'id':1}]}]
        active={'type':'branch','name':LOCK['branch']}
        legacy={'type':'branch','name':'codex/orbita-flutter-design-integration'}
        approved={'total_count':2,'branch_policies':[legacy,active]}
        validate_environment(env,approved,reviews)
        for policies in ([legacy], [active,active], [active,{**legacy,'type':'tag'}],
                         [active,{**legacy,'name':'codex/*'}], [active,legacy,{'type':'branch','name':'main'}]):
            with self.subTest(policies=policies), self.assertRaises(GuardError):
                validate_environment(env,{'total_count':len(policies),'branch_policies':policies},reviews)
        with self.assertRaises(GuardError): validate_environment(env,{**approved,'total_count':3},reviews)
        with self.assertRaises(GuardError): validate_environment({**env,'can_admins_bypass':True},approved,reviews)
        with self.assertRaises(GuardError): validate_environment(env,approved,[])
        with self.assertRaises(GuardError): validate_environment(env,approved,[{**reviews[0],'user':{'login':'other'}}])
    def test_no_prior_apply_and_no_unproven_backup(self):
        with self.assertRaises(GuardError): no_prior_apply([{'id':1,'event':'workflow_dispatch','display_title':'Орбита Dispatch: apply @ a'}],'2')
        with self.assertRaises(GuardError): validate_receipt({}, {**self.context(),'preview_run_id':'1','backup_sha256':'a'*64})

class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.db=Native(os.environ.get('TMPDIR'))
        self.addCleanup(self.db.close)
        for name in ['bootstrap_local.sql','bootstrap_orders_local.sql']:
            self.db.psql((ROOT/'supabase/tests'/name).read_text())
        self.db.execute(migration_body(ROOT))
        self.db.psql((ROOT/'supabase/tests/fixtures/host_rls_auto_enable.sql').read_text())
        self.db.execute(second_body(ROOT,second_hash(self.db)))
        self.before=capture(self.db)
        validate_before(self.before)
        self.sha=state_hash(self.db)
        self.protected=protected_hash(self.db)
    def test_atomic_third_history_and_unchanged_auth(self):
        self.db.execute(body(ROOT,self.sha))
        self.assertEqual(capture(self.db)['history'],history(True))
        self.assertEqual(protected_hash(self.db),self.protected)
        self.assertEqual(self.db.query(postflight_sql()),'t')
        with self.assertRaises(GuardError): self.db.execute(body(ROOT,self.sha))
        self.assertEqual(capture(self.db)['history'],history(True))
    def test_drift_rejected_before_ddl(self):
        self.db.psql("revoke execute on function public.orbita_create_order(uuid,jsonb,jsonb) from authenticated;")
        with self.assertRaises(GuardError): self.db.execute(body(ROOT,self.sha))
        self.assertEqual(self.db.query("select to_regprocedure('public.orbita_dispatch(text,jsonb)') is null;"),'t')
        self.assertEqual(capture(self.db)['history'],history())
    def test_postflight_error_rolls_back_all_ddl_and_history(self):
        script=body(ROOT,self.sha)+b"\nDO $$ BEGIN RAISE EXCEPTION 'synthetic failure'; END $$;"
        with self.assertRaises(GuardError): self.db.execute(script)
        self.assertEqual(capture(self.db),self.before)
    def test_dump_restore_and_encrypted_backup_roundtrip(self):
        from tools.dispatch_migration.backup import create
        with tempfile.TemporaryDirectory() as directory:
            result=create(self.db,ROOT,Path(directory)/'work',Path(directory)/'encrypted',
              'synthetic-dispatch-backup-passphrase-not-real',factory=Native)
            self.assertTrue(result['decryption_checked'] and result['restore_checked'] and result['rehearsal_checked'])
            self.assertEqual(result['network'],'native_test_unix_only')
            self.assertEqual(capture(self.db),self.before)
            self.assertTrue((Path(directory)/'encrypted/snapshot.tar.gpg').is_file())
