"""Секреты БД не передаются version/GPG, CLI получает поддерживаемый opt-out."""
from pathlib import Path
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import backup
import cloud_run
from dbtools import Database


class VersionReached(Exception):
    pass


class PreviewProcessPrivacyTests(unittest.TestCase):
    secrets={'PGPASSWORD':'artificial-database-only','SUPABASE_ACCESS_TOKEN':'artificial-api-only',
             'GH_TOKEN':'artificial-github-only','GITHUB_TOKEN':'artificial-github-only',
             'ORBITA_BACKUP_PASSPHRASE':'artificial-backup-only',
             'ORBITA_DATABASE_URL':'artificial-configuration-only',
             'ORBITA_DATABASE_CA_PEM':'artificial-configuration-only',
             'SUPABASE_TELEMETRY_DISABLED':'0','DO_NOT_TRACK':'0'}

    def assert_private_environment(self,env,*,database=False):
        for key in self.secrets:
            if key in ('SUPABASE_TELEMETRY_DISABLED','DO_NOT_TRACK') or (database and key=='PGPASSWORD'):
                continue
            self.assertTrue(key not in env,'Unnecessary sensitive environment key: '+key)
        self.assertTrue(env.get('SUPABASE_TELEMETRY_DISABLED')=='1','CLI telemetry is not explicitly disabled')
        self.assertTrue(env.get('DO_NOT_TRACK')=='1','DO_NOT_TRACK is not enabled')
        self.assertTrue('SUPABASE_TELEMETRY_OPTOUT' not in env,'Unsupported telemetry flag remains')

    def test_database_clients_use_supported_opt_out(self):
        with patch.dict(os.environ,self.secrets):
            db=Database('postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full',
                        'a'*20,'artificial-local-db-password','/tmp/artificial-ca.pem')
        self.assert_private_environment(db.env,database=True)
        self.assertTrue(db.env['PGPASSWORD']=='artificial-local-db-password')

    def test_first_cli_version_process_has_no_database_or_api_secrets(self):
        captured={}
        def version(args,**kwargs):
            captured.update(kwargs.get('env',os.environ))
            raise VersionReached()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'orbita-migration-gate.json').write_text(json.dumps({'context':{
                'sha':'a'*40,'expected_ref':'a'*20,'operation':'preview'}}))
            with patch.dict(os.environ,{**self.secrets,'GITHUB_WORKSPACE':directory,'RUNNER_TEMP':directory}),\
                 patch.object(cloud_run,'validate_request'),patch.object(cloud_run,'validate_connection'),\
                 patch.object(cloud_run.shutil,'which',return_value='/artificial/supabase'),\
                 patch.object(cloud_run.subprocess,'check_output',return_value='a'*40+'\n'),\
                 patch.object(cloud_run.subprocess,'run',side_effect=version),\
                 self.assertRaises(VersionReached):
                cloud_run.main()
        self.assert_private_environment(captured)

    def test_gpg_does_not_inherit_database_or_api_secrets(self):
        captured={}
        def checked(args,**kwargs):
            captured.update(kwargs['env'])
            return b''
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.dict(os.environ,self.secrets),patch.object(backup,'checked',side_effect=checked):
                backup.crypt_file(root/'source',root/'encrypted','artificial-local-passphrase-only',root/'gpg')
        self.assert_private_environment(captured)


if __name__=='__main__':unittest.main(verbosity=2)
