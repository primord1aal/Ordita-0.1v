"""Stable, non-secret cloud failure phases; no external services are contacted."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import cloud_run


class CloudFailurePhaseTests(unittest.TestCase):
    def test_failure_reports_only_fixed_phase_not_sensitive_exception(self):
        output=StringIO()
        def fail(mark):
            mark('READ_ONLY_CONNECTION')
            raise RuntimeError('password=artificial-secret sql=private-data host=private.example')
        with redirect_stdout(output):
            code=cloud_run.run_safely(fail)
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CLOUD_FAILURE_PHASE=READ_ONLY_CONNECTION',output.getvalue())
        for value in ('artificial-secret','private-data','private.example','RuntimeError','Traceback'):
            self.assertNotIn(value,output.getvalue())

    def test_unrecognised_code_cannot_be_printed(self):
        output=StringIO()
        with redirect_stdout(output):
            code=cloud_run.run_safely(lambda mark:mark('password=artificial-secret'))
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CLOUD_FAILURE_PHASE=START',output.getvalue())
        self.assertNotIn('artificial-secret',output.getvalue())

    def test_main_distinguishes_version_stage_without_forwarding_raw_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'orbita-migration-gate.json').write_text(
                '{"context":{"sha":"'+('a'*40)+'","expected_ref":"'+('a'*20)+'","operation":"preview"}}')
            output=StringIO()
            with patch.dict(os.environ,{'GITHUB_WORKSPACE':directory,'RUNNER_TEMP':directory,
                     'ORBITA_DATABASE_URL':'postgresql://postgres@db.'+('a'*20)+'.supabase.co:5432/postgres?sslmode=verify-full'}),\
                 patch.object(cloud_run,'validate_request'),\
                 patch.object(cloud_run.subprocess,'check_output',return_value='a'*40),\
                 patch.object(cloud_run.shutil,'which',return_value='/artificial/supabase'),\
                 patch.object(cloud_run.subprocess,'run',side_effect=OSError('password=artificial-secret')),\
                 redirect_stdout(output):
                code=cloud_run.run_safely(cloud_run.main)
            self.assertEqual(code,1)
            self.assertIn('ORBITA_CLOUD_FAILURE_PHASE=CLI_VERSION',output.getvalue())
            self.assertNotIn('artificial-secret',output.getvalue())

    def test_execute_marks_dry_run_failure(self):
        class FakeDb:
            def cli(self,*args):
                raise RuntimeError('artificial-secret')
        phases=[]
        with patch.object(cloud_run,'inspect',return_value={'auth_users':0}),\
             patch.object(cloud_run,'require_initial'),\
             patch.object(cloud_run,'baseline_fingerprint',return_value='fake-fingerprint'):
            with self.assertRaises(RuntimeError):
                cloud_run.execute({'operation':'apply'},FakeDb(),'/tmp','/tmp',
                    '/tmp','/tmp','/tmp','fake-passphrase',on_phase=phases.append)
        self.assertEqual(phases,['DB_INSPECT','BASELINE','CLI_DRY_RUN'])

    def test_local_plan_failure_is_distinct_from_cloud_dry_run(self):
        phases=[]
        def local_failure(*args,**kwargs):
            kwargs['on_phase']('LOCAL_CLI_DRY_RUN')
            raise RuntimeError('artificial-secret')
        with patch.object(cloud_run,'inspect',return_value={'auth_users':0}),\
             patch.object(cloud_run,'require_initial'),\
             patch.object(cloud_run,'baseline_fingerprint',return_value='fake-fingerprint'),\
             patch.object(cloud_run,'create_backup',side_effect=local_failure):
            with self.assertRaises(RuntimeError):
                cloud_run.execute({'operation':'preview'},object(),'/tmp','/tmp','/tmp','/tmp','/tmp',
                    'fake-passphrase',on_phase=phases.append,cli_binary='/artificial/supabase')
        self.assertEqual(phases,['DB_INSPECT','BASELINE','BACKUP','LOCAL_CLI_DRY_RUN'])


if __name__=='__main__':unittest.main(verbosity=2)
