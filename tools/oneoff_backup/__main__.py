"""Manual-only one-off export/isolated-restore; no migration or arbitrary SQL mode."""
from pathlib import Path
import os
import sys
import tempfile

from . import core as b


def main(args):
    os.umask(0o077)
    require = b.require
    require(args in (['--check-source'],['--check-github'],['--check-approved'],['export'],['restore']), 'ARGUMENTS_REJECTED')
    phrase = os.environ.get('ORBITA_ONEOFF_PASSPHRASE','')
    if args == ['restore']:
        isolation = b.isolated_network()
        with tempfile.TemporaryDirectory(prefix='orbita-oneoff-restore-') as directory:
            b.accept(Path('/input'),Path('/output/accepted'),phrase,Path(directory),b.base.PG_BIN,isolation=isolation)
        print('ONEOFF_LOGICAL_RESTORE_VERIFIED; encrypted artifact only; no cloud connection.')
        return
    sha = b.source(os.environ,Path(os.environ['GITHUB_WORKSPACE']))
    if args == ['--check-source']:
        print('ONEOFF_SOURCE_VERIFIED; no database connection.')
        return
    b.gate(os.environ,approved=args in (['--check-approved'],['export']))
    if args != ['export']:
        print('ONEOFF_GITHUB_GATE_VERIFIED; no database connection.')
        return
    password = os.environ.get('ORBITA_ONEOFF_READER_PASSWORD','')
    require(password != phrase and len(phrase)>=24, 'SEPARATE_BACKUP_PHRASE_REQUIRED')
    with tempfile.TemporaryDirectory(prefix='orbita-oneoff-export-') as directory:
        temporary = Path(directory)
        certificate = os.environ.get('ORBITA_ONEOFF_CA_PEM','')
        require(certificate.startswith('-----BEGIN CERTIFICATE-----') and 'PRIVATE KEY' not in certificate, 'CA_REQUIRED')
        ca = temporary/'ca.pem'; ca.write_text(certificate)
        with b.base.ReadSession(b.connection(password,ca)) as session:
            manifest = b.export(session,b.base.PG_BIN,temporary/'database.dump',temporary)
        manifest.update(source_sha=sha,run_id=os.environ['GITHUB_RUN_ID'])
        b.base.package(temporary/'database.dump',manifest,phrase,temporary,Path('/output/staging'),sha,os.environ['GITHUB_RUN_ID'])
    print('ONEOFF_ENCRYPTED_EXPORT_READY; restore still required; do not publish staging.')


if __name__=='__main__':
    try:
        main(sys.argv[1:])
    except BaseException as error:
        category = str(error) if isinstance(error,b.base.BackupError) else 'INTERNAL_FAILURE'
        print('ONEOFF_BACKUP_FAILED: category='+category+'; no raw errors; no automatic retry.')
        raise SystemExit(1) from None
