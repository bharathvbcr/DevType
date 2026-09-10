#!/usr/bin/env python3
"""Exercise the real stress runner with controlled test-process outcomes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class StressRunnerTests(unittest.TestCase):
    def run_fixture(self, output, *, status=0, rounds="1"):
        with tempfile.TemporaryDirectory(prefix="devtype-stress-fixture-") as directory:
            scripts = Path(directory) / "Scripts"
            scripts.mkdir()
            shutil.copy2(Path(__file__).with_name("stress-productivity.sh"), scripts)
            test = scripts / "test.sh"
            test.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$FIXTURE_OUTPUT\"\nexit \"$FIXTURE_STATUS\"\n")
            test.chmod(0o755)
            return subprocess.run(
                [str(scripts / "stress-productivity.sh")], capture_output=True, text=True,
                env=dict(os.environ, FIXTURE_OUTPUT=output, FIXTURE_STATUS=str(status), DEVTYPE_STRESS_ROUNDS=rounds),
                timeout=5, check=False,
            )

    @staticmethod
    def summary(count=3, skipped=0):
        skip = f"{skipped} test skipped and " if skipped else ""
        return ("Test Suite 'Selected tests' passed at 2026-09-10 00:00:00.000.\n"
                f"\t Executed {count} tests, with {skip}0 failures (0 unexpected) in 0.001 seconds\n"
                "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.")

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("stress rounds passed", result.stdout)

    def test_no_matching_tests_is_not_success(self):
        self.assert_rejected(self.run_fixture("warning: No matching test cases were run"))

    def test_zero_selected_tests_is_not_success(self):
        self.assert_rejected(self.run_fixture(self.summary(count=0)))

    def test_skipped_tests_are_not_a_complete_stress_round(self):
        self.assert_rejected(self.run_fixture(self.summary(skipped=1)))

    def test_missing_parent_summary_is_not_success(self):
        self.assert_rejected(self.run_fixture("Test Suite 'AChild' passed.\nExecuted 3 tests, with 0 failures"))

    def test_failing_process_cannot_be_rescued_by_success_text(self):
        self.assert_rejected(self.run_fixture(self.summary(), status=7, rounds="3"))

    def test_all_requested_rounds_run_with_real_counts(self):
        result = self.run_fixture(self.summary(), rounds="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("==> Stress round "), 3)
        self.assertIn("All 3 stress rounds passed", result.stdout)

    def test_invalid_round_counts_never_start(self):
        for rounds in ["0", "-1", "101", "1.5", "NaN", "999999999999999999999999"]:
            with self.subTest(rounds=rounds):
                result = self.run_fixture(self.summary(), rounds=rounds)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("==> Stress round ", result.stdout)


if __name__ == "__main__":
    unittest.main()
