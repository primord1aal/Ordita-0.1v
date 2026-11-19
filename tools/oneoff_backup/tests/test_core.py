from pathlib import Path
import copy
import hashlib
import json
import os
import tempfile
import unittest
from unittest.mock import patch

import yaml
from tools.oneoff_backup import core as b

ROOT = Path(__file__).resolve().parents[3]


def facts():
    return {'current_user':b.READER,'session_user':b.READER,'read_only':'on','default_read_only':'on',
        'version':170011,'tls':True,'role':{'login':True,'inherit':True,'bypassrls':True,'default_ro':True,
        'super':False,'createdb':False,'createrole':False,'replication':False},'scoped_schemas':4,'missing_reads':0,
        'ownership':0,'grant_options':0,'schema_create':0,'table_writes':0,'sequence_writes':0}


def profile():
    return {'members':[{'name':'pg_read_all_data','inherit':True,'set':False,'admin':False}],
        'expires_soon':True,'connection_limit':2,'database_create':False,'scope_writes':0,
        'scope_sequence_writes':0,'large_objects':0,'direct_function_grants':0}


def client_tls():
    return {'client_tls_verified':True,'client_sslmode':'verify-full',
        'client_hostname_verified':True,'scope':'client_to_pooler'}


class OneoffUnitTests(unittest.TestCase):
    def test_supported_profile_is_explicit_not_the_strict_reader(self):
        b.validate(facts(),profile(),client_tls=client_tls())
        self.assertNotEqual(b.READER,b.base.READER)
        with self.assertRaises(b.base.BackupError):
            b.base.validate_facts(facts())

    def test_admin_identity_incomplete_scope_or_extra_privileges_fail(self):
        for mutate in [lambda f,p:f.update(current_user='postgres'),lambda f,p:f['role'].update(super=True),
            lambda f,p:f['role'].update(createrole=True),lambda f,p:f.update(missing_reads=1),
            lambda f,p:p['members'][0].update(set=True),lambda f,p:p['members'][0].update(admin=True),
            lambda f,p:p.update(expires_soon=False),lambda f,p:p.update(connection_limit=-1),
            lambda f,p:p.update(scope_writes=1),lambda f,p:p.update(large_objects=1),
            lambda f,p:f.update(table_writes=1),lambda f,p:f.update(sequence_writes=1),
            lambda f,p:p.update(direct_function_grants=1),
            lambda f,p:f.update(read_only='off')]:
            f,p=facts(),profile(); mutate(f,p)
            with self.subTest(mutate=mutate),self.assertRaises(b.base.BackupError):b.validate(f,p,client_tls=client_tls())

    def test_backend_flag_cannot_replace_same_connection_client_tls_proof(self):
        for backend_tls in (False,True):
            f=facts();f['tls']=backend_tls
            with self.subTest(backend_tls=backend_tls):
                with self.assertRaisesRegex(b.base.BackupError,'^CLIENT_TLS_REQUIRED$'):
                    b.validate(f,profile())
                b.validate(f,profile(),client_tls=client_tls())
                for key,value in [('client_tls_verified',False),('client_sslmode','require'),
                                  ('client_hostname_verified',False),('scope','backend_only')]:
                    proof=client_tls();proof[key]=value
                    with self.assertRaisesRegex(b.base.BackupError,'^CLIENT_TLS_REQUIRED$'):
                        b.validate(f,profile(),client_tls=proof)

    def test_old_strict_backup_still_requires_backend_tls(self):
        from tools.current_backup.tests.test_backup import valid_facts
        f=valid_facts();b.base.validate_facts(f)
        f['tls']=False
        with self.assertRaisesRegex(b.base.BackupError,'^TLS_REQUIRED$'):
            b.base.validate_facts(f)

    def test_connection_is_fixed_tls_and_separate_nonadmin_user(self):
        with patch.dict(os.environ,{'PGHOST':'unapproved','PGUSER':'postgres','PGPASSWORD':'unrelated'},clear=True):
            env=b.connection('synthetic-reader-password-only',Path('/private/ca.pem'))
        self.assertEqual(env['PGUSER'],b.READER+'.'+b.base.PROJECT)
        self.assertEqual(env['PGSSLMODE'],'verify-full')
        self.assertEqual(env['PGHOST'],'aws-0-eu-north-1.pooler.supabase.com')
        self.assertNotIn('PGTARGETSESSIONATTRS',env)

    def _metadata(self, path, env):
        if path.endswith('/approvals'):
            return [{'state':'approved','user':{'login':'primord1aal'},'environments':[{'name':b.ENVIRONMENT,'id':1234}]}]
        if '/deployment-branch-policies' in path:
            return {'total_count':1,'branch_policies':[{'type':'branch','name':b.BRANCH.removeprefix('refs/heads/')} ]}
        if path.startswith('/actions/runs/'):
            return {'event':'workflow_dispatch','head_sha':'a'*40,'head_branch':b.BRANCH.removeprefix('refs/heads/'),'run_attempt':1,
                'path':'.github/workflows/orbita-oneoff-backup.yml'}
        return {'name':b.ENVIRONMENT,'id':1234,'can_admins_bypass':False,'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True},
            'protection_rules':[{'type':'required_reviewers','prevent_self_review':False,
                'reviewers':[{'type':'User','reviewer':{'login':'primord1aal'}}]}]}

    def test_actual_environment_and_approval_are_required(self):
        env={'GITHUB_SHA':'a'*40,'GITHUB_RUN_ID':'123'}
        b.gate(env,approved=True,request=self._metadata)
        def no_approval(path,env):return [] if path.endswith('/approvals') else self._metadata(path,env)
        with self.assertRaisesRegex(b.base.BackupError,'ACTUAL_APPROVAL_UNCONFIRMED'):
            b.gate(env,approved=True,request=no_approval)
        def replaced_environment(path,env):
            value=self._metadata(path,env)
            if path.endswith('/approvals'):value[0]['environments'][0]['id']=4321
            return value
        with self.assertRaisesRegex(b.base.BackupError,'ACTUAL_APPROVAL_UNCONFIRMED'):
            b.gate(env,approved=True,request=replaced_environment)
        def broad_branch(path,env):
            value=self._metadata(path,env)
            if '/deployment-branch-policies' in path:value['branch_policies'][0]['name']='*'
            return value
        with self.assertRaisesRegex(b.base.BackupError,'EXACT_BRANCH_POLICY_REQUIRED'):
            b.gate(env,request=broad_branch)
        def admin_bypass(path,env):
            value=self._metadata(path,env)
            if path.startswith('/environments/') and '/deployment-' not in path:value['can_admins_bypass']=True
            return value
        with self.assertRaisesRegex(b.base.BackupError,'ADMIN_BYPASS_FORBIDDEN'):
            b.gate(env,request=admin_bypass)

    def test_github_403_is_fixed_blocker_never_a_bypass(self):
        with patch('urllib.request.urlopen',side_effect=PermissionError('synthetic private diagnostic')):
            with self.assertRaisesRegex(b.base.BackupError,'^GITHUB_PROTECTION_UNCONFIRMED$'):
                b.github('/environments/'+b.ENVIRONMENT,{'GITHUB_TOKEN':'synthetic-only'})

    def test_source_is_manual_owner_first_attempt_exact_sha_branch_and_ack(self):
        env={'GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_REPOSITORY':b.base.REPOSITORY,
            'GITHUB_REF':b.BRANCH,'GITHUB_ACTOR':'primord1aal','GITHUB_TRIGGERING_ACTOR':'primord1aal',
            'GITHUB_RUN_ATTEMPT':'1','GITHUB_SHA':'a'*40,'ORBITA_ONEOFF_APPROVED_SHA':'a'*40,
            'ORBITA_ONEOFF_PROJECT_REF':b.base.PROJECT,'ORBITA_ONEOFF_ACK':b.ACK}
        with patch.object(b.base,'run',side_effect=[('a'*40+'\n').encode(),b'']):b.source(env,Path('/repo'))
        for key,value in [('GITHUB_RUN_ATTEMPT','2'),('GITHUB_REF','refs/heads/main'),
            ('ORBITA_ONEOFF_ACK',''),('ORBITA_ONEOFF_PROJECT_REF',b.base.FORBIDDEN),('GITHUB_ACTOR','unapproved')]:
            with self.subTest(key=key),self.assertRaises(b.base.BackupError):b.source({**env,key:value},Path('/repo'))

    def test_failed_restore_creates_no_publishable_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); output=root/'accepted'
            with patch.object(b,'decrypt',return_value=(root/'dump',{})),patch.object(b,'restore',side_effect=b.base.BackupError('ISOLATED_RESTORE_FAILED')):
                with self.assertRaises(b.base.BackupError):b.accept(root/'staging',output,'synthetic',root,b.base.PG_BIN,isolation='test_unix_only')
            self.assertFalse(output.exists())

    def test_public_receipt_uses_only_fixed_transport_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);staging=root/'staging';staging.mkdir()
            for name in ('snapshot.tar.gpg','SHA256SUMS'):(staging/name).write_text('synthetic fixture')
            (staging/'receipt.json').write_text('{}')
            private='synthetic-private-transport-value'
            for index,proof in enumerate([dict(client_tls(),backend_tls_confirmed=False),
                    dict(client_tls(),client_sslmode=private)]):
                with patch.object(b,'decrypt',return_value=(root/'dump',{'transport':proof})), \
                        patch.object(b,'restore'):
                    receipt=b.accept(staging,root/str(index),'synthetic',root,b.base.PG_BIN,
                        isolation='synthetic_test_only')
                self.assertEqual(receipt['client_tls_verified'],index==0)
                self.assertEqual(receipt['client_sslmode'],'verify-full' if index==0 else None)
                self.assertFalse(receipt['end_to_end_tls_proven'])
                self.assertNotIn(private,json.dumps(receipt))

    def test_workflow_is_manual_and_restores_before_upload_without_db_credentials(self):
        text=(ROOT/'.github/workflows/orbita-oneoff-backup.yml').read_text()
        workflow=yaml.load(text,Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow['on']),{'workflow_dispatch'})
        self.assertEqual(workflow['jobs']['backup']['environment'],b.ENVIRONMENT)
        steps=workflow['jobs']['backup']['steps']
        restore=next(i for i,value in enumerate(steps) if '--network none' in value.get('run',''))
        upload=next(i for i,value in enumerate(steps) if 'upload-artifact' in value.get('uses',''))
        self.assertLess(restore,upload)
        self.assertNotIn('ORBITA_ONEOFF_READER_PASSWORD',steps[restore].get('env',{}))
        self.assertNotIn('GITHUB_TOKEN',steps[restore].get('env',{}))
        self.assertNotIn('ORBITA_TEST_DB_PASSWORD',text)
        self.assertEqual(set(workflow['jobs']['verify'].keys()) & {'environment'},set())
        self.assertEqual(steps[upload]['with']['retention-days'],'3')


if __name__=='__main__':unittest.main()
