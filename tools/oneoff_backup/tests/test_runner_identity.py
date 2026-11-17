"""Local Git permissions and the export/restore user boundary; no credentials."""
from pathlib import Path
import os
import stat
import tempfile
import unittest
from unittest.mock import patch

import yaml

from tools.oneoff_backup import core as b


ROOT = Path(__file__).resolve().parents[3]


def source_env(sha):
    return {
        'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'GITHUB_REPOSITORY': b.base.REPOSITORY,
        'GITHUB_REF': b.BRANCH,
        'GITHUB_ACTOR': 'primord1aal',
        'GITHUB_TRIGGERING_ACTOR': 'primord1aal',
        'GITHUB_RUN_ATTEMPT': '1',
        'GITHUB_SHA': sha,
        'ORBITA_ONEOFF_APPROVED_SHA': sha,
        'ORBITA_ONEOFF_PROJECT_REF': b.base.PROJECT,
        'ORBITA_ONEOFF_ACK': b.ACK,
    }


class RunnerIdentityTests(unittest.TestCase):
    def test_restrictive_source_check_can_make_a_clean_git_index_private(self):
        original_umask = os.umask(0o022)
        try:
            with tempfile.TemporaryDirectory(prefix='oneoff-index-fixture-') as directory:
                root = Path(directory)
                git = ['git', '-c', 'safe.directory='+str(root), '-C', str(root)]
                b.base.run(git+['-c', 'init.defaultRefFormat=files', 'init',
                                '--quiet', '--object-format=sha1'])
                tracked = root/'tracked.txt'
                tracked.write_text('synthetic fixture only\n')
                b.base.run(git+['add', 'tracked.txt'])
                b.base.run(git+['-c', 'user.name=Synthetic',
                                '-c', 'user.email=synthetic@example.invalid',
                                '-c', 'commit.gpgsign=false',
                                'commit', '--quiet', '-m', 'synthetic fixture'])
                sha = b.base.run(git+['rev-parse', 'HEAD']).decode().strip()
                index = root/'.git/index'
                self.assertEqual(stat.S_IMODE(index.stat().st_mode), 0o644)

                # Content stays identical; changed stat data makes status refresh
                # the index through a new lock file under the CLI's private umask.
                before = tracked.stat()
                os.utime(tracked, ns=(before.st_atime_ns, before.st_mtime_ns+2_000_000_000))
                prior_umask = os.umask(0o077)
                try:
                    self.assertEqual(b.source(source_env(sha), root), sha)
                finally:
                    os.umask(prior_umask)

                self.assertEqual(stat.S_IMODE(index.stat().st_mode), 0o600)
                self.assertEqual(b.base.run(git+['status', '--porcelain']), b'')
                self.assertEqual(tracked.read_text(), 'synthetic fixture only\n')
        finally:
            os.umask(original_umask)

    def test_git_head_failure_has_a_fixed_source_category(self):
        with patch.object(b.base, 'run', side_effect=b.base.BackupError('CLIENT_FAILED')) as run:
            with self.assertRaisesRegex(b.base.BackupError, '^SOURCE_GIT_HEAD_CLIENT_FAILED$'):
                b.source(source_env('a'*40), Path('/repo'))
        self.assertEqual(run.call_count, 1)

    def test_git_status_failure_has_a_fixed_source_category(self):
        with patch.object(b.base, 'run', side_effect=[b'a'*40+b'\n', b.base.BackupError('CLIENT_FAILED')]) as run:
            with self.assertRaisesRegex(b.base.BackupError, '^SOURCE_GIT_STATUS_CLIENT_FAILED$'):
                b.source(source_env('a'*40), Path('/repo'))
        self.assertEqual(run.call_count, 2)

    def test_workflow_checks_source_and_exports_as_the_checkout_owner(self):
        workflow = yaml.load((ROOT/'.github/workflows/orbita-oneoff-backup.yml').read_text(),
                             Loader=yaml.BaseLoader)
        steps = workflow['jobs']['backup']['steps']
        source = next(step for step in steps
                      if 'orbita-oneoff-tools -m tools.oneoff_backup --check-source' in step.get('run', ''))
        export = next(step for step in steps
                      if 'orbita-oneoff-tools -m tools.oneoff_backup export' in step.get('run', ''))
        self.assertLess(steps.index(source), steps.index(export))
        self.assertIn('--network none', source['run'])
        for step in (source, export):
            self.assertIn('--user "$(id -u):$(id -g)"', step['run'])
            self.assertNotIn('--user postgres', step['run'])
            self.assertIn('dst=/repo,readonly', step['run'])
        for name in ('GITHUB_TOKEN', 'ORBITA_ONEOFF_READER_PASSWORD',
                     'ORBITA_ONEOFF_PASSPHRASE', 'ORBITA_ONEOFF_CA_PEM'):
            self.assertNotIn(name, source.get('env', {}))
            self.assertNotIn(name, source['run'])
        prepare = next(step for step in steps if 'docker build' in step.get('run', ''))
        self.assertIn('mkdir -m 700 "$RUNNER_TEMP/orbita-oneoff"', prepare['run'])
        self.assertNotIn('999', prepare['run'])

    def test_workflow_hands_only_encrypted_staging_to_isolated_postgres_restore(self):
        workflow = yaml.load((ROOT/'.github/workflows/orbita-oneoff-backup.yml').read_text(),
                             Loader=yaml.BaseLoader)
        steps = workflow['jobs']['backup']['steps']
        restore = next(step for step in steps
                       if 'orbita-oneoff-tools -m tools.oneoff_backup restore' in step.get('run', ''))
        run = restore['run']
        docker_start = run.index('docker run')
        self.assertRegex(run[:docker_start],
                         r'chown\s+(?:-R\s+)?999:999\s+"\$RUNNER_TEMP/orbita-oneoff/staging"')
        self.assertIn('--network none --user postgres', run[docker_start:])
        self.assertIn('src="$RUNNER_TEMP/orbita-oneoff/staging",dst=/input,readonly', run)
        for name in ('GITHUB_TOKEN', 'ORBITA_ONEOFF_READER_PASSWORD', 'ORBITA_ONEOFF_CA_PEM'):
            self.assertNotIn(name, restore.get('env', {}))
            self.assertNotIn(name, run)
        upload = next(step for step in steps if 'upload-artifact@' in step.get('uses', ''))
        self.assertLess(steps.index(restore), steps.index(upload))


if __name__ == '__main__':
    unittest.main()
