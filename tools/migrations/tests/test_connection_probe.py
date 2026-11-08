"""Safe connection categories in the existing runner; every process is mocked."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import cloud_run
import dbtools
from policy import GuardError

SECRET='artificial-diagnostic-secret'
URL='postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full'
ERRORS=[
    ('could not translate host name "private.example" to address','DNS_LOOKUP_FAILED'),
    ('Connection refused','TCP_CONNECTION_REFUSED'),
    ('Network is unreachable','NETWORK_UNREACHABLE'),
    ('connection to server failed: timeout expired','CONNECTION_TIMEOUT'),
    ('SSL error: certificate verify failed','TLS_CERTIFICATE_VERIFY_FAILED'),
    ('server certificate for "private.example" does not match host name "other.example"','TLS_HOSTNAME_MISMATCH'),
    ('root certificate file "/private/ca.pem" does not exist','TLS_CA_FILE_INVALID'),
    ('SSL error: unsupported protocol','TLS_NEGOTIATION_FAILED'),
    ('FATAL: password authentication failed for user "private-user"','DB_PASSWORD_REJECTED'),
    ('FATAL: Tenant or user not found','POOLER_TENANT_OR_USER_NOT_FOUND'),
    ('FATAL: unsupported startup parameter: options','STARTUP_PARAMETER_REJECTED'),
    ('session is not read-only','READ_ONLY_SESSION_REJECTED'),
    ('FATAL: no pg_hba.conf entry for host "private.example"','DB_CONNECTION_POLICY_REJECTED'),
    ('server closed the connection unexpectedly','CONNECTION_CLOSED'),
    ('Error response from daemon: OCI runtime create failed','DOCKER_CLIENT_FAILED'),
    ('unrecognised private error','UNKNOWN_PRIVATE_ERROR'),
]


class ConnectionDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.db=dbtools.Database(URL,'a'*20,SECRET,'/tmp/artificial-ca.pem',read_only=True)
        self.calls=[];self.token=None

    def processes(self,*,stdout=b'on\n',stderr=b'',returncode=0,timeout=False,setup_error=False,cleanup_error=False):
        def run(args,**kwargs):
            self.calls.append((args,kwargs))
            if 'create' in args:
                self.token=kwargs['env']['PGAPPNAME'];output=('c'*64).encode()
                if setup_error:return subprocess.CompletedProcess(args,1,stdout=b'',stderr=b'Connection refused '+SECRET.encode())
            elif 'inspect' in args:
                output=(json.dumps('c'*64)+'\n'+json.dumps(self.token)+'\n').encode()
            elif 'start' in args:
                if timeout:raise subprocess.TimeoutExpired(args,60,output=SECRET.encode(),stderr=SECRET.encode())
                return subprocess.CompletedProcess(args,returncode,stdout=stdout,stderr=stderr)
            elif 'rm' in args:
                if cleanup_error:return subprocess.CompletedProcess(args,1,stdout=b'',stderr=SECRET.encode())
                output=b''
            else:raise AssertionError('Unexpected subprocess')
            return subprocess.CompletedProcess(args,0,stdout=output,stderr=b'')
        return run

    def run_existing_main(self,processes,*,end_error=None):
        with tempfile.TemporaryDirectory() as directory:
            context={'sha':'a'*40,'expected_ref':'a'*20,'operation':'preview'}
            (Path(directory)/'orbita-migration-gate.json').write_text(json.dumps({'context':context}))
            env={'GITHUB_WORKSPACE':str(ROOT),'RUNNER_TEMP':directory,'ORBITA_DATABASE_URL':URL,
                'PGPASSWORD':SECRET,'ORBITA_DATABASE_CA_PEM':'-----BEGIN CERTIFICATE-----\nartificial\n-----END CERTIFICATE-----'}
            def command(args,**kwargs):
                if args==['/artificial/supabase','--version']:
                    return subprocess.CompletedProcess(args,0,stdout=cloud_run.LOCK['cli_version'],stderr='')
                return processes(args,**kwargs)
            with patch.dict(os.environ,env,clear=True),patch.object(cloud_run,'validate_request'),\
                 patch.object(cloud_run.subprocess,'check_output',return_value='a'*40),\
                 patch.object(cloud_run.shutil,'which',return_value='/artificial/supabase'),\
                 patch.object(cloud_run,'Database',return_value=self.db),\
                 patch.object(self.db,'_end_sql',side_effect=end_error) as cancel,\
                 patch.object(cloud_run.subprocess,'run',side_effect=command),\
                 patch.object(cloud_run,'execute') as execute,redirect_stdout(StringIO()) as output:
                code=cloud_run.run_safely(cloud_run.main)
            return code,output.getvalue(),cancel.call_count,execute.call_count

    def assert_private(self,output):
        for value in [SECRET,'private.example','private-user','/private/ca.pem',URL,'Traceback']:
            self.assertNotIn(value,output)

    def test_existing_cloud_main_distinguishes_errors_without_workflow_change(self):
        for text,expected in ERRORS:
            with self.subTest(category=expected):
                self.calls=[]
                code,output,cancel,execute=self.run_existing_main(self.processes(stderr=(text+' '+SECRET).encode(),returncode=2))
                self.assertEqual(code,1)
                self.assertIn('ORBITA_CLOUD_FAILURE_PHASE=READ_ONLY_CONNECTION',output)
                self.assertIn('ORBITA_CONNECTION_ERROR_CATEGORY='+expected,output)
                self.assertEqual(cancel,1)
                self.assertEqual(execute,0)
                self.assert_private(output)

    def test_database_cleanup_failure_cannot_replace_first_connection_error(self):
        def cancel(_):
            self.db._record_failure('CONNECTION_TIMEOUT')
            raise OSError(SECRET)
        code,output,cancel_count,execute=self.run_existing_main(
            self.processes(stderr=b'certificate verify failed '+SECRET.encode(),returncode=2),end_error=cancel)
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CONNECTION_ERROR_CATEGORY=TLS_CERTIFICATE_VERIFY_FAILED',output)
        self.assertNotIn('ORBITA_CONNECTION_ERROR_CATEGORY=CONNECTION_TIMEOUT',output)
        self.assertEqual((cancel_count,execute),(1,0))
        self.assert_private(output)

    def test_docker_cleanup_failure_preserves_first_connection_error(self):
        code,output,cancel,execute=self.run_existing_main(
            self.processes(stderr=b'password authentication failed '+SECRET.encode(),returncode=2,cleanup_error=True))
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CONNECTION_ERROR_CATEGORY=DB_PASSWORD_REJECTED',output)
        self.assertEqual((cancel,execute),(1,0))
        self.assert_private(output)

    def test_docker_setup_failure_is_not_reported_as_database_network_failure(self):
        code,output,_,execute=self.run_existing_main(self.processes(setup_error=True))
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CONNECTION_ERROR_CATEGORY=DOCKER_CLIENT_FAILED',output)
        self.assertFalse(any('start' in args for args,_ in self.calls))
        self.assertEqual(execute,0)
        self.assert_private(output)

    def test_timeout_keeps_existing_cancellation_and_does_not_retry_original_query(self):
        code,output,cancel,execute=self.run_existing_main(self.processes(timeout=True),end_error=OSError(SECRET))
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CONNECTION_ERROR_CATEGORY=CLIENT_DEADLINE_UNCERTAIN',output)
        self.assertEqual((cancel,execute),(1,0))
        self.assertEqual(len([1 for args,_ in self.calls if 'start' in args]),1)
        self.assertTrue(any('rm' in args for args,_ in self.calls))
        self.assert_private(output)

    def test_read_only_mismatch_is_distinct_and_never_reaches_next_stage(self):
        for stdout in [b'off\n',b'',b'on\n'+SECRET.encode()]:
            with self.subTest(stdout=stdout):
                code,output,cancel,execute=self.run_existing_main(self.processes(stdout=stdout))
                self.assertEqual(code,1)
                self.assertIn('ORBITA_CONNECTION_ERROR_CATEGORY=READ_ONLY_NOT_CONFIRMED',output)
                self.assertEqual((cancel,execute),(0,0))
                self.assert_private(output)

    def test_success_preserves_original_sql_tls_limits_and_secret_boundaries(self):
        with patch.dict(os.environ,{'GH_TOKEN':'artificial-gh','SUPABASE_ACCESS_TOKEN':'artificial-api',
                'ORBITA_BACKUP_PASSPHRASE':'artificial-backup','PGSERVICE':'unsafe'}):
            db=dbtools.Database(URL,'a'*20,SECRET,'/tmp/artificial-ca.pem',read_only=True)
        with patch('subprocess.run',side_effect=self.processes()):
            self.assertEqual(db.query('show default_transaction_read_only;'),'on')
        starts=[kw for args,kw in self.calls if 'start' in args]
        self.assertEqual(len(starts),1)
        kw=starts[0]
        self.assertEqual(kw['input'],b'BEGIN TRANSACTION READ ONLY;\nshow default_transaction_read_only;\nROLLBACK;')
        for name,value in [('PGSSLMODE','verify-full'),('PGTARGETSESSIONATTRS','read-only'),
                ('PGSSLROOTCERT','/run/orbita-ca.pem'),('PGCONNECT_TIMEOUT','10')]:self.assertEqual(kw['env'][name],value)
        self.assertIn('default_transaction_read_only=on',kw['env']['PGOPTIONS'])
        self.assertIn('statement_timeout=30000',kw['env']['PGOPTIONS'])
        for args,kw in self.calls:
            self.assertNotIn(SECRET,' '.join(args))
            for name in ['GH_TOKEN','SUPABASE_ACCESS_TOKEN','ORBITA_BACKUP_PASSPHRASE','PGSERVICE']:
                self.assertNotIn(name,kw['env'])

    def test_next_operation_does_not_reuse_old_error_category(self):
        with patch('subprocess.run',side_effect=self.processes(stderr=b'certificate verify failed',returncode=2)),\
             patch.object(self.db,'_end_sql'),self.assertRaises(GuardError):self.db.query('show default_transaction_read_only;')
        self.assertEqual(self.db.failure_category,'TLS_CERTIFICATE_VERIFY_FAILED')
        with patch('subprocess.run',side_effect=self.processes(stderr=b'password authentication failed',returncode=2)),\
             patch.object(self.db,'_end_sql'),self.assertRaises(GuardError):self.db.query('show default_transaction_read_only;')
        self.assertEqual(self.db.failure_category,'DB_PASSWORD_REJECTED')

    def test_invalid_or_unexpected_error_categories_cannot_publish_arbitrary_text(self):
        self.db._record_failure(SECRET)
        self.assertEqual(self.db.failure_category,'UNKNOWN_PRIVATE_ERROR')
        self.db._failure_code=SECRET
        self.assertEqual(self.db.failure_category,'UNKNOWN_PRIVATE_ERROR')


if __name__=='__main__':unittest.main(verbosity=2)
