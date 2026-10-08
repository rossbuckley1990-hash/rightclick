"""Fixture-gate regression tests; these are not substrate execution evidence."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


class FixtureOutcomeGateTests(unittest.TestCase):
    def run_gate(self, lines, *options):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Tests").mkdir()
            (root / "Tests" / "FixtureCase.swift").write_text("func testOne() {}\nfunc testTwo() {}\n")
            log = root / "test.log"
            log.write_text("\n".join(lines) + "\n")
            output = root / "outcomes.json"
            gate = pathlib.Path(__file__).parents[1] / "check-fixture-test-outcomes.py"
            process = subprocess.run([sys.executable, str(gate), "--repo", str(root), "--log", str(log),
                "--output", str(output), "--require-class", "FixtureCase", *options], capture_output=True, text=True)
            return process.returncode, json.loads(output.read_text())

    terminal = "Test Suite 'Selected tests' passed at 2026-10-08 00:00:00.000."
    one = "Test Case '-[Module.FixtureCase testOne]' passed (0.010 seconds)."
    two = "Test Case 'FixtureCase.testTwo' passed (0.010 seconds)."

    def test_mac_and_linux_identity_styles_are_preserved(self):
        code, report = self.run_gate([self.one, self.two, self.terminal])
        self.assertEqual(code, 0)
        self.assertEqual(report["outcomes"], {"FixtureCase/testOne": "passed", "FixtureCase/testTwo": "passed"})

    def test_missing_fixture_case_fails(self):
        code, report = self.run_gate([self.one, self.terminal])
        self.assertNotEqual(code, 0)
        self.assertIn("FixtureCase/testTwo: not completed", report["errors"])

    def test_unexpected_fixture_skip_fails(self):
        code, report = self.run_gate([self.one, self.two.replace("passed", "skipped"), self.terminal])
        self.assertNotEqual(code, 0)
        self.assertIn("FixtureCase/testTwo: skipped", report["errors"])

    def test_explicit_unrelated_fixture_skip_is_reported(self):
        code, report = self.run_gate([self.one, self.two.replace("passed", "skipped"), self.terminal],
                                    "--allow-skip", "FixtureCase/testTwo")
        self.assertEqual(code, 0)
        self.assertEqual(report["allowSkip"], ["FixtureCase/testTwo"])

    def test_failed_case_fails_even_with_suite_pass_marker(self):
        code, report = self.run_gate([self.one, self.two.replace("passed", "failed"), self.terminal])
        self.assertNotEqual(code, 0)
        self.assertIn("A selected test failed", report["errors"])

    def test_repeated_completed_identity_fails(self):
        code, report = self.run_gate([self.one, self.one, self.two, self.terminal])
        self.assertNotEqual(code, 0)
        self.assertIn("Repeated completed test identity: FixtureCase/testOne", report["errors"])

    def test_incomplete_suite_fails(self):
        code, report = self.run_gate([self.one, self.two])
        self.assertNotEqual(code, 0)
        self.assertIn("Selected test suite did not complete", report["errors"])

    def test_failed_selected_suite_cannot_claim_pass(self):
        code, report = self.run_gate([self.one, self.two, self.terminal.replace("passed", "failed")])
        self.assertNotEqual(code, 0)
        self.assertIn("Selected test suite did not complete", report["errors"])

    def test_source_only_conditional_case_is_explicit(self):
        code, report = self.run_gate([self.one, self.terminal], "--not-compiled", "FixtureCase/testTwo")
        self.assertEqual(code, 0)
        self.assertEqual(report["notCompiled"], ["FixtureCase/testTwo"])

    def test_compiled_case_cannot_hide_behind_source_only_exception(self):
        code, report = self.run_gate([self.one, self.two, self.terminal], "--not-compiled", "FixtureCase/testTwo")
        self.assertNotEqual(code, 0)
        self.assertIn("A source-only exception unexpectedly appears in executable outcomes", report["errors"])


if __name__ == "__main__":
    unittest.main()
