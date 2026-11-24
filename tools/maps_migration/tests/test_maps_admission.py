"""Actual disposable PG, synthetic accounts/orders only; no cloud transport."""
from io import StringIO
from pathlib import Path
import hashlib
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from tools.maps_migration.policy import (LOCK, GuardError, sources, history, validate_source,
    validate_request, validate_environment, validate_receipt, no_prior_apply, validate_preview)
from tools.maps_migration.state import capture, state_hash, protected_hash, validate_before, baseline_reference
from tools.maps_migration.atomic import body, postflight_sql
from tools.orders_migration.local import Native
from tools.orders_migration.atomic import body as second_body
from tools.orders_migration.catalog import state_hash as second_hash
from tools.dispatch_migration.atomic import body as third_body
from tools.dispatch_migration.state import state_hash as third_hash
from atomic_apply import migration_body

ROOT=Path(__file__).resolve().parents[3]
PASSENGER='00000000-0000-4000-8000-000000000001'
DRIVER='00000000-0000-4000-8000-000000000002'
ORDER='00000000-0000-4000-8000-000000000003'

class PolicyTests(unittest.TestCase):
    def context(self):
        return dict(event='workflow_dispatch',operation='preview',repository=LOCK['repository'],
          git_ref='refs/heads/'+LOCK['branch'],attempt='1',repo_enabled='true',sha='a'*40,
          approved_sha='a'*40,checkout_sha='a'*40,env_enabled='true',allowed_sha='a'*40,
          allowed_operation='preview',expected_ref=LOCK['project_ref'],requested_ref=LOCK['project_ref'],forbidden_ref=LOCK['forbidden_ref'])
    def test_four_exact_sources_and_protected_admission(self):
        self.assertEqual(len(sources(ROOT)),4)
        self.assertEqual(hashlib.sha256(sources(ROOT)[-1]).hexdigest(),LOCK['sha256'])
        self.assertEqual(len(baseline_reference()['relations']),4)
        validate_request(self.context(),ROOT)
        for key,value in [('attempt','2'),('allowed_sha','b'*40),('operation','apply'),
                          ('requested_ref',LOCK['forbidden_ref']),('git_ref','refs/heads/main')]:
            with self.subTest(key=key),self.assertRaises(GuardError):
                validate_request({**self.context(),key:value},ROOT)
        with self.assertRaises(GuardError):
            validate_source(self.context(),ROOT,{'ORBITA_DISPATCH_ALLOWED_SHA':'a'*40})
    def test_owner_approval_and_exact_branch_cannot_be_bypassed(self):
        env={'name':LOCK['environment'],'id':1,'can_admins_bypass':False,
          'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True},
          'protection_rules':[{'type':'required_reviewers','reviewers':[{'type':'User','reviewer':{'login':'primord1aal'}}]}]}
        reviews=[{'state':'approved','user':{'login':'primord1aal'},'environments':[{'id':1}]}]
        policies={'total_count':2,'branch_policies':[{'type':'branch','name':LOCK['branch']},
            {'type':'branch','name':'codex/orbita-flutter-design-integration'}]}
        validate_environment(env,policies,reviews)
        with self.assertRaises(GuardError):validate_environment({**env,'can_admins_bypass':True},policies,reviews)
        with self.assertRaises(GuardError):validate_environment(env,policies,[])
        with self.assertRaises(GuardError):validate_request({**self.context(),
            'git_ref':'refs/heads/codex/orbita-flutter-design-integration'},ROOT)
    def test_maps_attempts_and_preview_provenance_are_independent(self):
        no_prior_apply([{'id':1,'event':'workflow_dispatch','display_title':'Орбита Dispatch: apply @ a'}],'2')
        with self.assertRaises(GuardError):no_prior_apply([{'id':1,'event':'workflow_dispatch','display_title':'Орбита Maps: apply @ a'}],'2')
        with self.assertRaises(GuardError):validate_receipt({}, {**self.context(),'preview_run_id':'1','backup_sha256':'a'*64})
        with self.assertRaises(GuardError):validate_preview({'display_title':'Орбита Dispatch: preview @'}, {}, {**self.context(),'preview_run_id':'1'})

    def test_preview_reports_only_maps_settings_before_opening_database(self):
        from tools.maps_migration.runner import cli

        output = StringIO()
        context = self.context()
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory) / 'orbita-maps-gate.json'
            gate.write_text(json.dumps({'context': context}))
            env = {
                'GITHUB_WORKSPACE': str(ROOT),
                'RUNNER_TEMP': directory,
                'ORBITA_DATABASE_URL': (
                    f"postgresql://postgres.{LOCK['project_ref']}@aws-0-eu-north-1.pooler.supabase.com:5432/postgres?sslmode=verify-full"
                ),
            }
            with (patch.dict(os.environ, env, clear=True),
                  patch('os.umask'),
                  patch('subprocess.check_output', side_effect=[context['sha'], '']),
                  patch('tools.maps_migration.runner.MapsDatabase') as database,
                  patch('sys.stdout', output)):
                self.assertEqual(cli(), 1)
            database.assert_not_called()
        result = output.getvalue()
        self.assertIn('ORBITA_TEST_DB_PASSWORD', result)
        self.assertIn('ORBITA_TEST_DB_CA_PEM', result)
        self.assertIn('ORBITA_ORDERS_BACKUP_PASSPHRASE', result)
        self.assertNotIn('ORBITA_DISPATCH_', result)

class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.db=Native(os.environ.get('TMPDIR'));self.addCleanup(self.db.close)
        for name in ['bootstrap_local.sql','bootstrap_orders_local.sql']:
            self.db.psql((ROOT/'supabase/tests'/name).read_text())
        self.db.execute(migration_body(ROOT))
        self.db.psql((ROOT/'supabase/tests/fixtures/host_rls_auto_enable.sql').read_text())
        self.db.execute(second_body(ROOT,second_hash(self.db)))
        self.db.execute(third_body(ROOT,third_hash(self.db)))
        for i,uid in enumerate((PASSENGER,DRIVER)):
            self.db.psql(f"insert into auth.users(id,email) values('{uid}','maps{i}@example.test');")
            self.db.psql(f"select orbita_mobile_private.admin_access('{uid}','provision',null,null,'Synthetic maps fixture',false);")
        self.db.psql(f"""with moment as (select clock_timestamp() as now)
          insert into public.orbita_orders(id,passenger_id,request_id,pickup,destination,created_at,expires_at)
          select '{ORDER}','{PASSENGER}','00000000-0000-4000-8000-000000000004',
          '{{"address":"Synthetic pickup","latitude":55,"longitude":82.43}}',
          '{{"address":"Synthetic destination","latitude":55.01,"longitude":82.44}}',now,now+interval '5 minutes' from moment;
          insert into orbita_mobile_private.dispatch_drivers(driver_id,online,heartbeat_at)
            values('{DRIVER}',false,clock_timestamp());
          insert into orbita_mobile_private.dispatch_offers(order_id,driver_id,created_at,expires_at,status)
            values('{ORDER}','{DRIVER}',clock_timestamp(),clock_timestamp()+interval '24 seconds','declined');
          select nextval('orbita_mobile_private.dispatch_queue');""")
        self.before=capture(self.db);validate_before(self.before)
        self.sha=state_hash(self.db);self.protected=protected_hash(self.db)
    def test_fourth_history_only_and_existing_dispatcher_state_preserved(self):
        self.db.execute(body(ROOT,self.sha))
        self.assertEqual(capture(self.db)['history'],history(True))
        self.assertEqual(protected_hash(self.db),self.protected)
        self.assertEqual(self.db.query(postflight_sql()),'t')
        self.assertEqual(self.db.query('select count(*) from public.orbita_orders;'),'1')
        self.assertEqual(self.db.query('select count(*) from orbita_mobile_private.dispatch_offers;'),'1')
        with self.assertRaises(GuardError):self.db.execute(body(ROOT,self.sha))
        self.assertEqual(capture(self.db)['history'],history(True))
    def test_schema_drift_and_sequence_drift_rejected_before_ddl(self):
        self.db.psql("select nextval('orbita_mobile_private.dispatch_queue');")
        with self.assertRaises(GuardError):self.db.execute(body(ROOT,self.sha))
        self.assertEqual(self.db.query("select to_regprocedure('public.orbita_map_budget(uuid,integer)') is null;"),'t')
        self.assertEqual(capture(self.db)['history'],history())
        self.db.psql("revoke execute on function public.orbita_dispatch(text,jsonb) from authenticated;")
        with self.assertRaises(GuardError):validate_before(capture(self.db))
    def test_postflight_error_rolls_back_all_new_ddl_and_history(self):
        with self.assertRaises(GuardError):self.db.execute(body(ROOT,self.sha)+b"\nDO $$ BEGIN RAISE EXCEPTION 'synthetic failure'; END $$;")
        self.assertEqual(capture(self.db),self.before)
    def test_encrypted_backup_restores_rows_sequences_and_rehearses_fourth(self):
        from tools.maps_migration.backup import create
        with tempfile.TemporaryDirectory() as directory:
            result=create(self.db,ROOT,Path(directory)/'work',Path(directory)/'encrypted',
              'synthetic-maps-backup-passphrase-not-real',factory=Native)
            self.assertTrue(result['decryption_checked'] and result['restore_checked'] and result['rehearsal_checked'])
            self.assertEqual(result['network'],'native_test_unix_only')
            self.assertEqual(result['before_versions'],[r['version'] for r in history()])
            self.assertEqual(result['after_versions'],[r['version'] for r in history(True)])
            self.assertEqual(capture(self.db),self.before)
            self.assertTrue((Path(directory)/'encrypted/snapshot.tar.gpg').is_file())
    def test_missing_dispatcher_history_is_not_repaired(self):
        self.db.psql("delete from supabase_migrations.schema_migrations where version='20261120160748';")
        with self.assertRaises(GuardError):validate_before(capture(self.db))
