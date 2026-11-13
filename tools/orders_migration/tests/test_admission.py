"""Offline gates and workflow tests. No GitHub/Supabase/DB calls."""
from pathlib import Path
from unittest.mock import patch
import copy
import hashlib
import json
import shutil
import tempfile
import unittest
import yaml
from tools.orders_migration.admission import (LOCK, ENV_ONLY, GuardError, validate_source, validate_request,
    validate_environment, validate_preview, no_prior_apply, validate_connection, sources)
from tools.orders_migration.atomic import body

ROOT=Path(__file__).resolve().parents[3]

def context():
    return dict(event='workflow_dispatch',operation='apply',repository=LOCK['repository'],
        git_ref='refs/heads/'+LOCK['branch'],attempt='1',sha='a'*40,approved_sha='a'*40,checkout_sha='a'*40,
        repo_enabled='true',env_enabled='true',allowed_sha='a'*40,allowed_operation='apply',
        expected_ref=LOCK['project_ref'],requested_ref=LOCK['project_ref'],forbidden_ref=LOCK['forbidden_ref'],
        preview_run_id='12',run_id='13',backup_sha256='b'*64)

def proof():
    return dict(status='preview_passed',source_sha='a'*40,run_id='12',project_ref=LOCK['project_ref'],
        sql_sha256=LOCK['sha256'],executor=LOCK['executor'],before_versions=[LOCK['first_version']],
        pending=[LOCK['version']],state_sha256='c'*64,backup=dict(encrypted_sha256='b'*64,
        decryption_checked=True,restore_checked=True,rehearsal_checked=True,network='none'))

class AdmissionTests(unittest.TestCase):
    def test_fixed_sources_and_builder_preserve_first_bytes(self):
        first,second=sources(ROOT)
        self.assertEqual(hashlib.sha256(first).hexdigest(),LOCK['first_sha256'])
        sql=body(ROOT,'c'*64)
        self.assertEqual(sql.count(second),2) # body + exact history payload
        self.assertNotIn(b'CREATE TABLE IF NOT EXISTS supabase_migrations',sql)
        self.assertIn(b'pg_advisory_xact_lock',sql)
        self.assertIn(b'SHARE ROW EXCLUSIVE MODE',sql)
        self.assertIn(b'ORDERS_BASELINE_CHANGED',sql)
        self.assertIn(b'ORDERS_POSTFLIGHT_FAILED',sql)
        for invalid in ['',"x'; DROP TABLE auth.users;--",'c'*63]:
            with self.assertRaises(GuardError):body(ROOT,invalid)
    def test_modified_missing_linked_or_extra_sql_refused(self):
        for mutation in ['first','second','extra','link']:
            with self.subTest(mutation=mutation),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                for key in ['first_path','path']:
                    target=root/LOCK[key];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/LOCK[key],target)
                if mutation=='extra':(root/'supabase/migrations/999999999999_extra.sql').write_text('select 1;')
                else:
                    p=root/LOCK['first_path' if mutation=='first' else 'path']
                    if mutation=='link':p.unlink();p.symlink_to(ROOT/LOCK['path'])
                    else:p.write_bytes(p.read_bytes()+b'\n--changed')
                with self.assertRaises(GuardError):sources(root)
    def test_manual_source_and_independent_stage_admission(self):
        validate_request(context(),ROOT)
        for key,value in [('event','push'),('attempt','2'),('repository','someone/else'),('git_ref','refs/heads/main'),
            ('approved_sha','d'*40),('checkout_sha','d'*40),('repo_enabled','false'),('env_enabled','false'),
            ('allowed_sha','d'*40),('allowed_operation','preview'),('requested_ref',LOCK['forbidden_ref']),
            ('expected_ref','a'*20),('forbidden_ref','b'*20),('preview_run_id',''),('backup_sha256','')]:
            c=context();c[key]=value
            with self.subTest(key=key),self.assertRaises(GuardError):validate_request(c,ROOT)
    def test_environment_settings_may_not_be_defined_at_repository_scope(self):
        for name in ENV_ONLY:
            with self.subTest(name=name),self.assertRaises(GuardError):
                validate_source(context(),ROOT,{name:'true'})
        validate_source(context(),ROOT,{})
    def test_exact_tls_and_project_no_password_url(self):
        good=f"postgresql://postgres@db.{LOCK['project_ref']}.supabase.co:5432/postgres?sslmode=verify-full"
        validate_connection(good,LOCK['project_ref'])
        for bad in [good.replace('verify-full','require'),good+'&sslmode=disable',good.replace(':5432',':6543'),
                    good.replace(LOCK['project_ref'],LOCK['forbidden_ref']),good.replace('postgres@','postgres:secret@'),
                    good.replace('/postgres?','/other?')]:
            with self.subTest(bad=bad),self.assertRaises(GuardError):validate_connection(bad,LOCK['project_ref'])
    def test_real_owner_approval_and_non_bypassable_environment(self):
        env=dict(name=LOCK['environment'],id=7,can_admins_bypass=False,
            deployment_branch_policy=dict(protected_branches=False,custom_branch_policies=True),
            protection_rules=[dict(type='required_reviewers',reviewers=[dict(type='User',reviewer=dict(login='primord1aal'))])])
        branches={'branch_policies':[dict(name=LOCK['branch'],type='branch')]}
        reviews=[dict(state='approved',user=dict(login='primord1aal'),environments=[dict(id=7)])]
        validate_environment(env,branches,reviews)
        for modified in [dict(env,can_admins_bypass=True),dict(env,name='old-environment'),dict(env,protection_rules=[])]:
            with self.assertRaises(GuardError):validate_environment(modified,branches,reviews)
        for wrong in [[],[dict(state='approved',user=dict(login='other'),environments=[dict(id=7)])],
                      [dict(state='approved',user=dict(login='primord1aal'),environments=[dict(id=8)])]]:
            with self.assertRaises(GuardError):validate_environment(env,branches,wrong)
        with self.assertRaises(GuardError):validate_environment(env,{'branch_policies':[dict(name='*',type='branch')]},reviews)
    def test_preview_provenance_backup_and_native_proof_cannot_promote(self):
        run=dict(id=12,conclusion='success',event='workflow_dispatch',run_attempt=1,head_sha='a'*40,
                 head_branch=LOCK['branch'],path='.github/workflows/'+LOCK['workflow'],display_title='Орбита Orders: preview @ a')
        validate_preview(run,proof(),context())
        for key,value in [('head_sha','d'*40),('path','.github/workflows/old.yml'),('run_attempt',2),('conclusion','failure')]:
            r=copy.deepcopy(run);r[key]=value
            with self.assertRaises(GuardError):validate_preview(r,proof(),context())
        for key,value in [('source_sha','d'*40),('sql_sha256','d'*64),('before_versions',[]),('pending',[]),('executor','old')]:
            p=proof();p[key]=value
            with self.assertRaises(GuardError):validate_preview(run,p,context())
        for key,value in [('restore_checked',False),('decryption_checked',False),('rehearsal_checked',False),
                          ('encrypted_sha256','d'*64),('network','native_test_unix_only')]:
            p=proof();p['backup'][key]=value
            with self.assertRaises(GuardError):validate_preview(run,p,context())
    def test_prior_unknown_failed_or_cancelled_apply_stops_retry(self):
        for conclusion in ['failure','cancelled',None,'success']:
            with self.subTest(conclusion=conclusion),self.assertRaises(GuardError):
                no_prior_apply([dict(id=10,event='workflow_dispatch',display_title='Орбита Orders: apply @ x',conclusion=conclusion)],13)
        no_prior_apply([dict(id=10,event='workflow_dispatch',display_title='Орбита Orders: preview @ x')],13)
    def test_read_only_transport_refuses_apply_before_starting_a_process(self):
        from tools.orders_migration.runner import OrdersDatabase
        url=f"postgresql://postgres@db.{LOCK['project_ref']}.supabase.co:5432/postgres?sslmode=verify-full"
        db=OrdersDatabase(url,LOCK['project_ref'],'synthetic-db-password','/tmp/artificial-ca',read_only=True)
        with patch.object(db,'tool') as process,self.assertRaises(GuardError):
            db.apply_orders(ROOT,'c'*64)
        process.assert_not_called()

    def test_future_workflow_is_manual_separate_gated_no_existing_config_change(self):
        text=(ROOT/'.github/workflows'/LOCK['workflow']).read_text()
        data=yaml.load(text,Loader=yaml.BaseLoader)
        self.assertEqual(set(data['on']),{'workflow_dispatch'})
        self.assertEqual(data['jobs']['guarded']['environment'],LOCK['environment'])
        self.assertNotIn('CLOUD_ENABLED',data['jobs']['guarded']['if'])
        self.assertIn('needs.entry.outputs.admitted',data['jobs']['guarded']['if'])
        entry=data['jobs']['entry'];self.assertNotIn('environment',entry)
        self.assertNotIn('secrets.',json.dumps(entry))
        for flag in ENV_ONLY:self.assertIn('OUTSIDE_'+flag,json.dumps(entry))
        steps=data['jobs']['guarded']['steps'];gate=next(i for i,s in enumerate(steps) if s.get('run')=='python3 -m tools.orders_migration.github_gate gate')
        for i,step in enumerate(steps):
            if 'secrets.' in json.dumps(step):self.assertGreater(i,gate)
        self.assertIn('vars.ORBITA_ORDERS_ALLOWED_OPERATION',text)
        self.assertNotIn('workflow_dispatch --',text)
        self.assertFalse(data['concurrency']['cancel-in-progress']=='true')
