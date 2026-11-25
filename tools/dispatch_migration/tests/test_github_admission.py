from contextlib import redirect_stdout
from io import StringIO
import unittest
from unittest.mock import patch

from tools.dispatch_migration import github_gate, recovery
from tools.dispatch_migration.policy import GuardError


class GitHubAdmissionTests(unittest.TestCase):
    def test_reads_every_history_page_without_cli_pagination_flags(self):
        runs = [{'id': number} for number in range(101)]
        with patch.object(github_gate, 'github', side_effect=[
            {'total_count': 101, 'workflow_runs': runs[:100]},
            {'total_count': 101, 'workflow_runs': runs[100:]},
        ]) as api:
            self.assertEqual(github_gate.dispatch_runs('repos/example/test'), runs)
        self.assertEqual([call.args for call in api.call_args_list], [
            ('repos/example/test/actions/workflows/425221225/runs?per_page=100&page=1',),
            ('repos/example/test/actions/workflows/425221225/runs?per_page=100&page=2',),
        ])

    def test_rejects_empty_page_and_changed_history_count(self):
        first = {'total_count': 101, 'workflow_runs': [{}] * 100}
        for second in ({'total_count': 101, 'workflow_runs': []},
                       {'total_count': 102, 'workflow_runs': [{}]}):
            with self.subTest(second=second), patch.object(github_gate, 'github', side_effect=[first, second]):
                with self.assertRaises(GuardError):
                    github_gate.dispatch_runs('repos/example/test')

    def test_recovery_precheck_reports_stage_without_exception_data(self):
        def fail(phase):
            phase('RECOVERY_LOG')
            raise RuntimeError('synthetic-private-detail')

        output = StringIO()
        with patch.object(github_gate, 'recovery_precheck', side_effect=fail), redirect_stdout(output):
            self.assertEqual(github_gate.cli(['recovery-precheck']), 1)
        self.assertIn('stage=RECOVERY_LOG', output.getvalue())
        self.assertNotIn('synthetic-private-detail', output.getvalue())

    def test_reviewed_log_proves_empty_inputs_and_pre_write_stop(self):
        recovery._validate_guarded_log(recovery.reviewed_guarded_log())
        with patch.object(recovery.Path, 'read_bytes', return_value=b'edited excerpt'):
            with self.assertRaises(GuardError):
                recovery.reviewed_guarded_log()
