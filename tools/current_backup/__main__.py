"""Manual backup only. No arbitrary SQL, target URL, migration or restore arguments."""
from pathlib import Path
import os
import sys
import tempfile

from .backup import (BackupError, require, validate_source, connection_env, ReadSession,
                     PG_BIN, export, package)


def main(args):
    os.umask(0o077)
    root = Path(os.environ['GITHUB_WORKSPACE'])
    require(args in ([], ['--check-source']), 'ARGUMENTS_REJECTED')
    validate_source(os.environ,root)
    if args:
        print('BACKUP_SOURCE_VERIFIED; no database connection.')
        return
    password = os.environ.get('ORBITA_BACKUP_READER_PASSWORD','')
    phrase = os.environ.get('ORBITA_CURRENT_BACKUP_PASSPHRASE','')
    require(password != phrase and len(phrase) >= 24, 'SEPARATE_BACKUP_PHRASE_REQUIRED')
    base = Path(os.environ['RUNNER_TEMP'])
    with tempfile.TemporaryDirectory(prefix='orbita-current-backup-',dir=base) as directory:
        work = Path(directory); ca = work/'ca.pem'
        certificate = os.environ.get('ORBITA_BACKUP_CA_PEM','')
        require(certificate.startswith('-----BEGIN CERTIFICATE-----') and
                'PRIVATE KEY' not in certificate, 'CA_REQUIRED')
        ca.write_text(certificate)
        env = connection_env(password,ca)
        with ReadSession(env) as session:
            manifest = export(session,PG_BIN,work/'database.dump')
        package(work/'database.dump',manifest,phrase,work,base/'orbita-current-backup-artifact',
                os.environ['GITHUB_SHA'],os.environ['GITHUB_RUN_ID'])
    print('BACKUP_ENCRYPTED_AND_VERIFIED; no cloud restore or migration was executed.')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except BaseException as error:
        category = str(error) if isinstance(error,BackupError) else 'INTERNAL_FAILURE'
        # Categories are fixed in source; no client output, raw exceptions or data.
        print('BACKUP_FAILED: category='+category+'; no raw errors; no automatic retry.')
        raise SystemExit(1) from None
