import copy
import io
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

from tools.orders_migration import runner
from tools.orders_migration.admission import GuardError
from tools.orders_migration.backup import PreviewPhase, compare_restore


class PreviewDiagnosticTests(unittest.TestCase):
    def test_only_fixed_phase_can_escape_a_private_failure(self):
        private = "synthetic-private-canary"
        for stage, expected in [(runner.PreviewPhase.COMPARE_RESTORE, "COMPARE_RESTORE"),
                                (private, "UNKNOWN")]:
            def fail(diagnostic):
                diagnostic.update(stage=stage)
                raise RuntimeError(private)

            output = io.StringIO()
            with patch.object(runner, "main", fail), redirect_stdout(output), redirect_stderr(output):
                self.assertEqual(runner.cli(), 1)
            self.assertIn("stage=" + expected + ";", output.getvalue())
            self.assertNotIn(private, output.getvalue())

    def test_restore_difference_remains_fatal_without_disclosing_values(self):
        baseline = dict.fromkeys(('protected_catalog', 'rows', 'history', 'client_safe',
                                  'dependency_ok', 'host_rls'), True)
        baseline['catalog'] = {'schemas': [], 'relations': [], 'functions': []}
        for path, phase in [(('rows',), PreviewPhase.RESTORED_ROWS_OR_SEQUENCES),
                            (('catalog', 'schemas'), PreviewPhase.RESTORED_SCHEMAS),
                            (('history',), PreviewPhase.RESTORED_HISTORY),
                            (('unexpected_field',), PreviewPhase.COMPARE_RESTORE)]:
            with self.subTest(path=path):
                actual = copy.deepcopy(baseline)
                target = actual if len(path) == 1 else actual[path[0]]
                target[path[-1]] = 'synthetic-private-canary'
                phases = []
                with self.assertRaises(GuardError) as error:
                    compare_restore(baseline, actual, phases.append)
                self.assertEqual(phases[-1], phase)
                self.assertNotIn('synthetic-private-canary', str(error.exception))
