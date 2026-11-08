from pathlib import Path
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
from policy import (LOCK,REPOSITORY,GuardError,validate_request,validate_connection,
    validate_environment,validate_no_prior_apply,validate_preview,parse_dry_run)
from dbtools import checked,Database,require_initial


def request():
    return {'event':'workflow_dispatch','operation':'preview','repo_enabled':'true','env_enabled':'true','repository':REPOSITORY,
        'git_ref':'refs/heads/'+LOCK['branch'],'attempt':'1','sha':'a'*40,'approved_sha':'a'*40,
        'allowed_sha':'a'*40,'checkout_sha':'a'*40,'expected_ref':'a'*20,'forbidden_ref':'b'*20,
        'requested_ref':'a'*20,'preview_run_id':'10','backup_sha256':'c'*64}


class PolicyTests(unittest.TestCase):
    def test_valid_preview_and_apply_request(self):
        context=request();validate_request(context,ROOT)
        context['operation']='apply';validate_request(context,ROOT)
        context['operation']='inspect';validate_request(context,ROOT)

    def test_push_pull_request_schedule_and_default_event_never_enter_cloud(self):
        for event in ['push','pull_request','pull_request_target','schedule','workflow_run','']:
            with self.subTest(event=event):
                context=request();context['event']=event
                with self.assertRaises(GuardError):validate_request(context,ROOT)

    def test_disabled_missing_unknown_and_wrong_repository_are_rejected(self):
        for key,value in [('repo_enabled',''),('repo_enabled','false'),('env_enabled',''),('env_enabled','false'),
            ('operation','verify'),('operation','repair'),
            ('repository','other/repo'),('git_ref','refs/heads/main'),('git_ref','refs/tags/any'),('attempt','2')]:
            with self.subTest(key=key,value=value):
                context=request();context[key]=value
                with self.assertRaises(GuardError):validate_request(context,ROOT)

    def test_every_commit_boundary_must_match(self):
        for key in ['sha','approved_sha','allowed_sha','checkout_sha']:
            context=request();context[key]='b'*40
            with self.subTest(key=key),self.assertRaises(GuardError):validate_request(context,ROOT)

    def test_exact_allowed_ref_and_forbidden_ref(self):
        for key,value in [('requested_ref','b'*20),('requested_ref','c'*20),('expected_ref','b'*20),('forbidden_ref','')]:
            context=request();context[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(GuardError):validate_request(context,ROOT)

    def test_changed_or_extra_migration_fails_before_connection(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'supabase/migrations';target.mkdir(parents=True)
            source=ROOT/'supabase/migrations'/LOCK['migration'];shutil.copyfile(source,target/source.name)
            validate_request(request(),directory)
            (target/'20261106000000_extra.sql').write_text('select 1;')
            with self.assertRaises(GuardError):validate_request(request(),directory)
            (target/'20261106000000_extra.sql').unlink()
            (target/source.name).write_text(source.read_text()+'\nselect 1;')
            with self.assertRaises(GuardError):validate_request(request(),directory)

    def test_apply_needs_preview_and_backup_confirmation(self):
        for key,value in [('preview_run_id',''),('preview_run_id','../../other'),('backup_sha256','')]:
            context=request();context.update({'operation':'apply',key:value})
            with self.subTest(key=key),self.assertRaises(GuardError):validate_request(context,ROOT)

    def test_only_exact_direct_or_session_pooler_with_full_tls(self):
        ref='a'*20
        for url in [f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full',
                    f'postgresql://postgres.{ref}@aws-0-test.pooler.supabase.com:5432/postgres?sslmode=verify-full']:
            validate_connection(url,ref)
        for url in [f'postgresql://postgres@db.{"b"*20}.supabase.co:5432/postgres?sslmode=verify-full',
            f'postgresql://postgres.{ref}@aws-0-test.pooler.supabase.com:6543/postgres?sslmode=verify-full',
            f'postgresql://postgres:artificial-password@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=require',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=disable',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full&sslmode=',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full&sslmode=verify-full',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full&options=',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full&password=',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres;options=evil?sslmode=verify-full',
            f'postgresql://postgres@db.{ref}.supabase.co:5432/postgres?sslmode=verify-full&options=evil',
            f'postgresql://postgres.{ref}@evil.example.test:5432/postgres?sslmode=verify-full']:
            with self.subTest(url=url),self.assertRaises(GuardError):validate_connection(url,ref)

    def test_preview_is_read_only_and_workflow_ignores_unmasked_url_variable(self):
        from dbtools import _timeout_options
        self.assertIn('default_transaction_read_only=on',_timeout_options(60,read_only=True))
        self.assertNotIn('default_transaction_read_only',_timeout_options(60))
        workflow=(ROOT/'.github/workflows/orbita-stage-3b.yml').read_text()
        self.assertNotIn('vars.ORBITA_TEST_DB_URL',workflow)
        pooler='ORBITA_DATABASE_URL: postgresql://postgres.fjqghohhohgvwlmefdmo@aws-0-eu-north-1.pooler.supabase.com:5432/postgres?sslmode=verify-full'
        direct='ORBITA_DATABASE_URL: postgresql://postgres@db.fjqghohhohgvwlmefdmo.supabase.co:5432/postgres?sslmode=verify-full'
        read_jobs=workflow.split('\n  migration-preview:',1)[1].split('\n  migration-apply:',1)[0]
        apply_job=workflow.split('\n  migration-apply:',1)[1]
        self.assertEqual(read_jobs.count(pooler),3)
        self.assertNotIn(direct,read_jobs)
        self.assertEqual(apply_job.count(pooler),2)
        self.assertNotIn(direct,apply_job)
        self.assertEqual(workflow.count('ORBITA_DATABASE_URL:'),5)
        cloud=(ROOT/'tools/migrations/cloud_run.py').read_text()
        self.assertIn("read_only=context['operation'] in ('preview','inspect')",cloud)

    def test_no_password_in_argv_and_other_secrets_not_forwarded(self):
        with patch.dict(os.environ,{'PGPASSWORD':'old-fake','SUPABASE_ACCESS_TOKEN':'fake-token',
                'ORBITA_BACKUP_PASSPHRASE':'artificial-backup-secret','GH_TOKEN':'artificial-github-token'}):
            db=Database('postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full',
                'a'*20,'artificial-db-secret','/tmp/artificial-ca.pem')
            self.assertNotIn('SUPABASE_ACCESS_TOKEN',db.env);self.assertNotIn('GH_TOKEN',db.env)
            self.assertNotIn('ORBITA_BACKUP_PASSPHRASE',db.env)
            # B1: теперь клиент создаётся, проверяется по CID/метке и удаляется.
            # Проверка отсутствия секрета охватывает каждую из этих команд.
            ownership={}
            def command_result(args,**kwargs):
                if 'create' in args:
                    ownership['token']=kwargs['env']['PGAPPNAME'];output=('c'*64).encode()
                elif 'inspect' in args:
                    output=(json.dumps('c'*64)+'\n'+json.dumps(ownership['token'])+'\n').encode()
                else:output=b'safe'
                return subprocess.CompletedProcess(args,0,stdout=output,stderr=b'')
            with patch('subprocess.run',side_effect=command_result) as run:
                db.tool('psql',['-Atq'])
                self.assertGreaterEqual(run.call_count,5)
                for call in run.call_args_list:
                    self.assertNotIn('artificial-db-secret',' '.join(call.args[0]))
                    self.assertEqual(call.kwargs['env']['PGPASSWORD'],'artificial-db-secret')

    def test_raw_failed_command_output_is_never_in_exception(self):
        result=subprocess.CompletedProcess([],1,stdout=b'artificial-secret',stderr=b'password=artificial-secret')
        with patch('subprocess.run',return_value=result):
            with self.assertRaises(GuardError) as caught:checked(['fake'])
            self.assertNotIn('artificial-secret',str(caught.exception))

    def test_dry_run_is_exactly_one_not_successful_sql_execution(self):
        self.assertEqual(parse_dry_run('Would push these migrations:\n • '+LOCK['migration']),[LOCK['version']])
        for output in ['is up to date.','Would push these migrations:\n'+LOCK['migration']+'\n20261106000000_extra.sql',
            'Would push these migrations:\n'+LOCK['migration']+'\nWould seed these files:',
            'Would push these migrations:\n'+LOCK['migration']+'\n'+LOCK['migration']]:
            with self.subTest(output=output),self.assertRaises(GuardError):parse_dry_run(output)

    def test_prior_apply_blocks_retry_even_failed_cancelled_or_success(self):
        for conclusion in ['failure','cancelled','success',None]:
            run={'id':5,'event':'workflow_dispatch','display_title':'Орбита 3Б: apply @ '+('a'*40),'conclusion':conclusion}
            with self.subTest(conclusion=conclusion),self.assertRaises(GuardError):validate_no_prior_apply([run],10)
        validate_no_prior_apply([{'id':5,'event':'push','display_title':'verify'},{'id':10,'event':'workflow_dispatch','display_title':'Орбита 3Б: apply @'}],10)

    def test_initial_state_rejects_users_objects_or_unexpected_history(self):
        state={'sql_user':'postgres','auth_users':0,'app_tables':0,'private_schema':False,'access_rpc':False,'versions':[]}
        require_initial(state)
        for key,value in [('auth_users',1),('app_tables',1),('private_schema',True),('access_rpc',True),('versions',['other'])]:
            changed=dict(state);changed[key]=value
            with self.subTest(key=key),self.assertRaises(GuardError):require_initial(changed)

    def test_real_environment_rules_branch_and_human_approval_required(self):
        environment={'id':1,'name':LOCK['environment'],'protection_rules':[{'type':'required_reviewers',
            'reviewers':[{'type':'User','reviewer':{'login':'owner'}}]}],
            'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True}}
        branches={'branch_policies':[{'name':LOCK['branch'],'type':'branch'}]}
        reviews=[{'state':'approved','user':{'login':'owner'},'environments':[{'id':1}]}]
        validate_environment(environment,branches,reviews,'owner')
        variants=[(dict(environment,protection_rules=[]),branches,reviews),
            (environment,{'branch_policies':[{'name':'*','type':'branch'}]},reviews),
            (environment,{'branch_policies':[{'name':LOCK['branch'],'type':'tag'}]},reviews),
            (environment,branches,[]),(environment,branches,[{'state':'approved','user':{'login':'other'},'environments':[{'id':1}]}])]
        for values in variants:
            with self.subTest(values=values),self.assertRaises(GuardError):validate_environment(*values,'owner')

    def test_preview_is_bound_to_run_commit_ref_file_and_checked_backup(self):
        context=request();context['operation']='apply'
        run={'id':10,'conclusion':'success','event':'workflow_dispatch','head_sha':'a'*40,
            'head_branch':LOCK['branch'],'run_attempt':1,'display_title':'Орбита 3Б: preview @ '+('a'*40)}
        receipt={'status':'preview_passed','apply_executor':'postgres_transaction_v1',
            'run_id':'10','source_sha':'a'*40,'project_ref':'a'*20,'migration_sha256':LOCK['migration_sha256'],
            'pending':[LOCK['version']],'auth_users':0,'objects_absent':True,'cli_dry_run_target':'isolated_restored_snapshot',
            'backup':{'encrypted_sha256':'c'*64,'decryption_checked':True,'local_restore_checked':True,
                'local_plan':{'target':'isolated_restored_snapshot','network':'none','tls':'verify-full',
                    'versions':[],'pending':[LOCK['version']],'scoped_state_unchanged':True}}}
        validate_preview(run,receipt,context)
        for key,value in [('source_sha','b'*40),('project_ref','b'*20),('pending',[]),('auth_users',1),('objects_absent',False),
                ('apply_executor',None),('apply_executor','legacy_cli'),('status','apply_outcome_unknown')]:
            changed=copy.deepcopy(receipt);changed[key]=value
            with self.subTest(key=key),self.assertRaises(GuardError):validate_preview(run,changed,context)
        changed=copy.deepcopy(receipt);changed['backup']['local_restore_checked']=False
        with self.assertRaises(GuardError):validate_preview(run,changed,context)
        changed=copy.deepcopy(receipt);changed['backup'].pop('local_plan')
        with self.assertRaises(GuardError):validate_preview(run,changed,context)
        changed=copy.deepcopy(receipt);changed['cli_dry_run_target']='cloud'
        with self.assertRaises(GuardError):validate_preview(run,changed,context)

    def test_workflow_cloud_jobs_require_dispatch_and_have_secrets_after_gate(self):
        text=(ROOT/'.github/workflows/orbita-stage-3b.yml').read_text()
        local=text[:text.index('\n  migration-preview:')]
        self.assertNotIn('secrets.ORBITA_TEST_DB_PASSWORD',local)
        self.assertNotIn('secrets.ORBITA_BACKUP_PASSPHRASE',local)
        for name in ['migration-preview','migration-apply']:
            section=text.split('\n  '+name+':',1)[1].split('\n  migration-',1)[0]
            self.assertIn("if: github.event_name == 'workflow_dispatch'",section)
            self.assertIn("vars.ORBITA_REPO_MIGRATIONS_ENABLED == 'true'",section)
            self.assertIn("needs.migration_entry.outputs.repo_enabled == 'true'",section)
            self.assertIn('environment: '+LOCK['environment'],section)
            self.assertLess(section.index('github_gate.py'),section.index('secrets.ORBITA_TEST_DB_PASSWORD'))
            self.assertIn('persist-credentials: false',section)
        self.assertIn('orbita-cloud-migration-single-flight',text)


if __name__=='__main__':unittest.main(verbosity=2)
