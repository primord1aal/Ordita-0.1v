"""Backup failures expose fixed stages/categories, never secrets; no cloud or Docker."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock,patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import backup
import cloud_run
import dbtools

PRIVATE='artificial-private-backup-error-with-password-and-url'
PHRASE='artificial-backup-passphrase-for-tests'


class BackupDiagnosticTests(unittest.TestCase):
    def capture(self,*,failure=None,category='DB_PERMISSION_DENIED',phrase=PHRASE,rows=None):
        db=Mock();db.failure_category=category
        def query(sql):
            stage='BACKUP_ROLES' if 'pg_roles' in sql else 'BACKUP_AUTH_TRIGGERS'
            if failure==stage:raise RuntimeError(PRIVATE)
            return '[]'
        db.query.side_effect=query
        db.dump.return_value=b'PGDMP-artificial-only'
        if failure=='BACKUP_DUMP':db.dump.side_effect=RuntimeError(PRIVATE)
        def public_rows(_):
            if failure=='BACKUP_PUBLIC_ROWS':raise RuntimeError(PRIVATE)
            return {} if rows is None else rows
        def crypt(source,destination,passphrase,home,decrypt=False):
            stage='BACKUP_DECRYPT' if decrypt else 'BACKUP_ENCRYPT'
            if failure==stage:raise RuntimeError(PRIVATE)
            Path(destination).write_bytes(b'artificial-tampered-archive' if decrypt and failure=='BACKUP_VERIFY' else Path(source).read_bytes())
        def restore(*args,**kwargs):kwargs['on_phase']('LOCAL_RESTORE')
        phases=[]
        with tempfile.TemporaryDirectory() as directory:
            temporary=Path(directory)
            def action(mark):
                def phase(name):phases.append(name);mark(name)
                phase('BACKUP')
                backup.create_backup(db,{'history_table':False,'versions':[]},phrase,temporary,
                    temporary/'encrypted',ROOT,on_phase=phase)
            with patch.object(backup,'public_rows',side_effect=public_rows),\
                 patch.object(backup,'crypt_file',side_effect=crypt),\
                 patch.object(backup,'restore_local',side_effect=restore) as restored,\
                 redirect_stdout(StringIO()) as output:
                code=cloud_run.run_safely(action)
        return code,output.getvalue(),phases,db,restored

    def assert_private(self,output):
        for value in [PRIVATE,PHRASE,'Traceback']:
            self.assertNotIn(value,output)

    def test_invalid_passphrase_is_identified_before_any_database_export(self):
        for phrase in ['short',PHRASE+'\n',PHRASE+'\x00']:
            with self.subTest(phrase_type='invalid'):
                code,out,phases,db,restored=self.capture(phrase=phrase)
                self.assertEqual(code,1)
                self.assertIn('ORBITA_CLOUD_FAILURE_PHASE=BACKUP_PASSPHRASE',out)
                db.query.assert_not_called();db.dump.assert_not_called();restored.assert_not_called()
                self.assert_private(out)

    def test_database_substeps_have_fixed_safe_category_and_distinct_phase(self):
        for phase in ['BACKUP_PUBLIC_ROWS','BACKUP_ROLES','BACKUP_AUTH_TRIGGERS','BACKUP_DUMP']:
            with self.subTest(phase=phase):
                code,out,_,_,restored=self.capture(failure=phase)
                self.assertEqual(code,1)
                self.assertIn('ORBITA_CLOUD_FAILURE_PHASE='+phase,out)
                self.assertIn('ORBITA_BACKUP_ERROR_CATEGORY=DB_PERMISSION_DENIED',out)
                restored.assert_not_called();self.assert_private(out)

    def test_nonempty_source_is_identified_and_never_exported(self):
        code,out,_,db,restored=self.capture(rows={'artificial_table':1})
        self.assertEqual(code,1)
        self.assertIn('ORBITA_CLOUD_FAILURE_PHASE=BACKUP_EMPTY_CHECK',out)
        db.dump.assert_not_called();restored.assert_not_called();self.assert_private(out)

    def test_encryption_decryption_and_integrity_failures_are_distinct(self):
        for phase in ['BACKUP_ENCRYPT','BACKUP_DECRYPT','BACKUP_VERIFY']:
            with self.subTest(phase=phase):
                code,out,_,_,restored=self.capture(failure=phase)
                self.assertEqual(code,1)
                self.assertIn('ORBITA_CLOUD_FAILURE_PHASE='+phase,out)
                restored.assert_not_called();self.assert_private(out)

    def test_untrusted_error_category_is_never_printed(self):
        code,out,_,_,_=self.capture(failure='BACKUP_DUMP',category=PRIVATE+'\nORBITA_FORGED=TRUE')
        self.assertEqual(code,1)
        self.assertIn('ORBITA_BACKUP_ERROR_CATEGORY=UNKNOWN_PRIVATE_ERROR',out)
        self.assertNotIn('ORBITA_FORGED',out);self.assert_private(out)

    def test_success_preserves_encryption_restore_and_order(self):
        code,out,phases,db,restored=self.capture()
        self.assertEqual(code,0)
        self.assertEqual(phases,['BACKUP','BACKUP_PASSPHRASE','BACKUP_PUBLIC_ROWS','BACKUP_EMPTY_CHECK',
            'BACKUP_ROLES','BACKUP_AUTH_TRIGGERS','BACKUP_DUMP','BACKUP_ARCHIVE','BACKUP_ENCRYPT',
            'BACKUP_DECRYPT','BACKUP_VERIFY','LOCAL_RESTORE'])
        db.dump.assert_called_once_with(['public']);restored.assert_called_once();self.assert_private(out)

    def test_dump_version_and_permissions_have_safe_classification(self):
        for text,expected in [
                ('pg_dump: error: aborting because of server version mismatch','PG_DUMP_VERSION_MISMATCH'),
                ('pg_dump: error: permission denied for table artificial','DB_PERMISSION_DENIED')]:
            with self.subTest(category=expected):
                self.assertEqual(dbtools._connection_error_category((text+' '+PRIVATE).encode()),expected)


if __name__=='__main__':unittest.main(verbosity=2)
