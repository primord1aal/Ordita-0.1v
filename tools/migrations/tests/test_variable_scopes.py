"""Локальные модели этапов GitHub. API/runner GitHub здесь не запускаются."""
from pathlib import Path
from contextlib import redirect_stdout
import ast
import copy
import io
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import github_gate
import repository_gate
from policy import LOCK,REPOSITORY,GuardError,validate_request,validate_repository_admission


def context():
    return {'event':'workflow_dispatch','operation':'preview','repo_enabled':'true','env_enabled':'true',
        'repository':REPOSITORY,'git_ref':'refs/heads/'+LOCK['branch'],'attempt':'1',
        'sha':'a'*40,'approved_sha':'a'*40,'allowed_sha':'a'*40,'checkout_sha':'a'*40,
        'expected_ref':'a'*20,'forbidden_ref':'b'*20,'requested_ref':'a'*20}


def job_section(name):
    text=(ROOT/'.github/workflows/orbita-stage-3b.yml').read_text()
    return text.split('\n  '+name+':',1)[1].split('\n  migration',1)[0]


def condition_value(expression,values):
    """Только используемые ==/&&/|| и обращения к контексту; не эмулятор Actions."""
    def visit(node):
        if isinstance(node,ast.Expression):return visit(node.body)
        if isinstance(node,ast.Constant):return node.value
        if isinstance(node,ast.Name):return values.get(node.id,{})
        if isinstance(node,ast.Attribute):
            value=visit(node.value)
            return value.get(node.attr,'') if isinstance(value,dict) else ''
        if isinstance(node,ast.BoolOp):
            return all(visit(n) for n in node.values) if isinstance(node.op,ast.And) else any(visit(n) for n in node.values)
        if isinstance(node,ast.Compare) and len(node.ops)==1 and isinstance(node.ops[0],ast.Eq):
            left,right=visit(node.left),visit(node.comparators[0])
            # GitHub сравнивает строки без учёта регистра. Сам Python gate строже.
            return left.lower()==right.lower() if isinstance(left,str) and isinstance(right,str) else left==right
        raise AssertionError('Неожиданный оператор в тестируемом условии workflow')
    return bool(visit(ast.parse(expression.replace('&&',' and ').replace('||',' or '),mode='eval')))


class VariableScopeTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory();self.temporary=Path(self.directory.name)
        self.env={'GITHUB_WORKSPACE':str(ROOT),'GITHUB_EVENT_NAME':'workflow_dispatch',
            'GITHUB_REPOSITORY':REPOSITORY,'GITHUB_REF':'refs/heads/'+LOCK['branch'],
            'GITHUB_RUN_ATTEMPT':'1','GITHUB_SHA':'a'*40,'GITHUB_RUN_ID':'10',
            'RUNNER_TEMP':str(self.temporary),'GITHUB_OUTPUT':str(self.temporary/'output'),
            'ORBITA_OPERATION':'preview','ORBITA_REPO_ENABLED':'true','ORBITA_ENV_ENABLED':'true',
            'ORBITA_REQUEST_SHA':'a'*40,'ORBITA_ALLOWED_SHA':'a'*40,
            'ORBITA_EXPECTED_REF':'a'*20,'ORBITA_FORBIDDEN_REF':'b'*20,'ORBITA_REQUEST_REF':'a'*20,
            'ORBITA_DATABASE_URL':'postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full'}
    def tearDown(self):self.directory.cleanup()

    def run_environment_gate(self,env,reviews=None):
        environment={'id':1,'name':LOCK['environment'],'protection_rules':[{'type':'required_reviewers',
            'reviewers':[{'type':'User','reviewer':{'login':'primord1aal'}}]}],
            'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True}}
        branches={'branch_policies':[{'name':LOCK['branch'],'type':'branch'}]}
        if reviews is None:reviews=[{'state':'approved','user':{'login':'primord1aal'},'environments':[{'id':1}]}]
        with patch.dict(os.environ,env,clear=True),\
             patch('subprocess.check_output',side_effect=['a'*40,'']),\
             patch.object(github_gate,'github',side_effect=[environment,branches,reviews]) as api,\
             redirect_stdout(io.StringIO()):
            try:github_gate.gate()
            finally:self.api_calls=api.call_count

    def test_actual_job_conditions_require_repository_switch_and_never_environment_values(self):
        expressions={name:job_section(name).split('\n    if: ',1)[1].splitlines()[0]
            for name in ['migration_entry','migration-preview','migration-apply']}
        for expression in expressions.values():
            self.assertNotIn('vars.ORBITA_CLOUD_MIGRATIONS_ENABLED',expression)
            self.assertNotIn('vars.ORBITA_ALLOWED_MIGRATION_SHA',expression)
        for event in ['push','workflow_dispatch','pull_request','schedule']:
            for mode in ['verify','preview','apply','inspect']:
                for enabled in ['','false','true','True']:
                    for entry in ['','false','true']:
                        values={'github':{'event_name':event,'ref':'refs/heads/'+LOCK['branch']},
                            'inputs':{'migration_operation':mode},'vars':{'ORBITA_REPO_MIGRATIONS_ENABLED':enabled},
                            'needs':{'migration_entry':{'outputs':{'repo_enabled':entry}}}}
                        eligible=event=='workflow_dispatch' and mode!='verify' and enabled.lower()=='true'
                        with self.subTest(event=event,mode=mode,enabled=enabled,entry=entry):
                            self.assertEqual(condition_value(expressions['migration_entry'],values),eligible)
                            self.assertEqual(condition_value(expressions['migration-preview'],values),
                                eligible and mode in ('preview','inspect') and entry=='true')
                            self.assertEqual(condition_value(expressions['migration-apply'],values),
                                eligible and mode=='apply' and entry=='true')
        values['github']={'event_name':'workflow_dispatch','ref':'refs/heads/main'}
        values['vars']['ORBITA_REPO_MIGRATIONS_ENABLED']='true'
        for expression in expressions.values():self.assertFalse(condition_value(expression,values))

    def test_environment_names_outside_environment_are_rejected_even_when_false(self):
        validate_repository_admission(context(),{})
        for name in ['ORBITA_CLOUD_MIGRATIONS_ENABLED','ORBITA_ALLOWED_MIGRATION_SHA']:
            for value in ['false','true','a'*40,' ']:
                with self.subTest(name=name,value=value),self.assertRaises(GuardError):
                    validate_repository_admission(context(),{name:value})

    def test_repository_script_emits_only_boolean_after_validation(self):
        with patch.dict(os.environ,self.env,clear=True),\
             patch('subprocess.check_output',side_effect=['a'*40,'']) as git,redirect_stdout(io.StringIO()):
            repository_gate.main()
        self.assertEqual((self.temporary/'output').read_text(),'repo_enabled=true\n')
        self.assertEqual([call.args[0][:2] for call in git.call_args_list],[['git','rev-parse'],['git','status']])

    def test_repository_script_failure_produces_no_admission_output(self):
        for key,value in [('ORBITA_REPO_ENABLED','false'),('ORBITA_REPO_ENABLED','True'),('ORBITA_OUTSIDE_ENV_ENABLED','true'),
                ('ORBITA_OUTSIDE_ENV_ENABLED','false'),('ORBITA_OUTSIDE_ENV_ALLOWED_SHA','a'*40),
                ('ORBITA_REQUEST_SHA','b'*40)]:
            env=dict(self.env);env[key]=value
            with self.subTest(key=key,value=value),patch.dict(os.environ,env,clear=True),\
                 patch('subprocess.check_output',side_effect=['a'*40,'']),self.assertRaises(GuardError):
                repository_gate.main()
            self.assertFalse((self.temporary/'output').exists())

    def test_disabled_missing_or_nonliteral_environment_flag_blocks_before_api(self):
        for value in ['','false','False','True','1',' true ']:
            env=dict(self.env);env['ORBITA_ENV_ENABLED']=value
            with self.subTest(value=value),self.assertRaises(GuardError):self.run_environment_gate(env)
            self.assertEqual(self.api_calls,0)
            self.assertFalse((self.temporary/'orbita-migration-gate.json').exists())

    def test_environment_sha_missing_or_wrong_blocks_before_api(self):
        for value in ['','b'*40]:
            env=dict(self.env);env['ORBITA_ALLOWED_SHA']=value
            with self.subTest(value=value),self.assertRaises(GuardError):self.run_environment_gate(env)
            self.assertEqual(self.api_calls,0)
            self.assertFalse((self.temporary/'orbita-migration-gate.json').exists())

    def test_valid_environment_gate_preserves_two_independent_admissions(self):
        self.run_environment_gate(self.env)
        receipt=json.loads((self.temporary/'orbita-migration-gate.json').read_text())
        self.assertEqual(self.api_calls,3)
        self.assertEqual(receipt['context']['repo_enabled'],'true')
        self.assertEqual(receipt['context']['env_enabled'],'true')
        self.assertNotIn('PGPASSWORD',json.dumps(receipt))

    def test_environment_values_do_not_replace_required_human_approval(self):
        with self.assertRaises(GuardError):self.run_environment_gate(self.env,reviews=[])
        self.assertEqual(self.api_calls,3)
        self.assertFalse((self.temporary/'orbita-migration-gate.json').exists())

    def test_workflow_scope_wiring_and_secret_order(self):
        entry=job_section('migration_entry')
        self.assertNotIn('\n    environment:',entry);self.assertNotIn('secrets.',entry)
        self.assertNotIn('cloud_run.py',entry);self.assertNotIn('GH_TOKEN',entry)
        self.assertIn('ORBITA_OUTSIDE_ENV_ENABLED: ${{ vars.ORBITA_CLOUD_MIGRATIONS_ENABLED }}',entry)
        self.assertIn('ORBITA_OUTSIDE_ENV_ALLOWED_SHA: ${{ vars.ORBITA_ALLOWED_MIGRATION_SHA }}',entry)
        for name in ['migration-preview','migration-apply']:
            section=job_section(name)
            self.assertIn('needs: [sql, cli-safety, migration_entry]',section)
            self.assertIn('environment: '+LOCK['environment'],section)
            self.assertIn('          ORBITA_REPO_ENABLED: ${{ needs.migration_entry.outputs.repo_enabled }}',section)
            self.assertIn('          ORBITA_ENV_ENABLED: ${{ vars.ORBITA_CLOUD_MIGRATIONS_ENABLED }}',section)
            self.assertIn('          ORBITA_ALLOWED_SHA: ${{ vars.ORBITA_ALLOWED_MIGRATION_SHA }}',section)
            self.assertLess(section.index('github_gate.py'),section.index('secrets.ORBITA_TEST_DB_PASSWORD'))
            self.assertNotIn('ORBITA_CLOUD_ENABLED:',section)

    def test_legacy_single_flag_or_missing_repository_receipt_cannot_authorize(self):
        for key in ['repo_enabled','env_enabled']:
            changed=copy.deepcopy(context());changed.pop(key);changed['enabled']='true'
            with self.subTest(key=key),self.assertRaises(GuardError):validate_request(changed,ROOT)


if __name__=='__main__':unittest.main(verbosity=2)
