import io
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

from tools.orders_migration import runner


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
