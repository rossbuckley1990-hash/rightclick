"""Synthetic evidence tests; none of these claim a Swift product test ran."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/check-reconciliation-tests.py"
spec = importlib.util.spec_from_file_location("reconciliation_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def baseline(rows=None):
    return {"schemaVersion": 1, "sourceHeads": gate.HEADS, "platform": "macos-arm64",
            "identityCount": len(rows or [["SampleTests.testExisting", "passed", None]]),
            "tests": rows or [["SampleTests.testExisting", "passed", None]]}


def discovery(identities=None, module="RightClickCoreTests"):
    return "\n".join(module + "." + identity.replace(".", "/")
                     for identity in identities or ["SampleTests.testExisting"])


def log(cases=None, root="All tests", mac=True):
    cases = cases or {"SampleTests.testExisting": "passed"}
    lines = [f"Test Suite '{root}' started at 2026-10-08 10:00:00.000.",
             "Test Suite 'Synthetic.xctest' started at 2026-10-08 10:00:00.000."]
    classes = {}
    for identity, outcome in cases.items():
        cls, method = identity.split(".")
        classes.setdefault(cls, []).append((identity, method, outcome))
    def summary(selected):
        skipped = sum(outcome == "skipped" for outcome in selected)
        failed = sum(outcome == "failed" for outcome in selected)
        return f"\t Executed {len(selected)} tests, with " + (f"{skipped} tests skipped and " if skipped else "") + f"{failed} failures (0 unexpected) in 0.001 (0.001) seconds"
    for cls, entries in classes.items():
        lines.append(f"Test Suite '{cls}' started at 2026-10-08 10:00:00.000.")
        for identity, method, outcome in entries:
            raw = f"-[RightClickCoreTests.{cls} {method}]" if mac else identity
            lines.extend([f"Test Case '{raw}' started.", f"Test Case '{raw}' {outcome} (0.001 seconds)."])
        state = "failed" if any(outcome == "failed" for _, _, outcome in entries) else "passed"
        lines.extend([f"Test Suite '{cls}' {state} at 2026-10-08 10:00:00.001.",
                      summary([outcome for _, _, outcome in entries])])
    state = "failed" if "failed" in cases.values() else "passed"
    for name in ["Synthetic.xctest", root]:
        lines.extend([f"Test Suite '{name}' {state} at 2026-10-08 10:00:00.001.", summary(list(cases.values()))])
    lines.extend(["◇ Test run started.", "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."])
    return "\n".join(lines)


class ReconciliationGateTests(unittest.TestCase):
    def testValidMacEvidence(self):
        result = gate.validate(baseline(), gate.parse_discovery(discovery()), gate.parse_log(log()), {})
        self.assertEqual((result["discovered"], result["completed"], result["status"]), (1, 1, "passed"))

    def testValidLinuxEvidenceAndCRLF(self):
        run = gate.parse_log(log(mac=False).replace("\n", "\r\n"))
        self.assertEqual(gate.validate(baseline(), gate.parse_discovery(discovery()), run, {})["status"], "passed")

    def testBlankLinesBetweenSuiteAndSummaryAllowed(self):
        self.assertEqual(gate.parse_log(log().replace("\n", "\n\n"))["summary"]["total"], 1)

    def testDiscoveryAllowsKnownBuildDiagnostics(self):
        self.assertEqual(len(gate.parse_discovery("[0/1] Planning build\nBuild complete! (0.01s)\n" + discovery())), 1)

    def testCompilerDiagnosticContainingTestPathIsNotADiscoveryEntry(self):
        diagnostics = "/fixture/test.swift:1: warning: unused symbol\nwarning: /test/fixture was skipped during resource enumeration\n"
        self.assertEqual(len(gate.parse_discovery(diagnostics + discovery())), 1)

    def testDuplicateDiscoveryRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Duplicate/colliding"):
            gate.parse_discovery(discovery() + "\n" + discovery())

    def testCrossModuleDiscoveryCollisionRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "colliding"):
            gate.parse_discovery(discovery() + "\n" + discovery(module="RightClickMCPTests"))

    def testUnknownModuleRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Unknown test module"):
            gate.parse_discovery(discovery(module="SpoofedTests"))

    def testMalformedDiscoveryRejected(self):
        with self.assertRaises(gate.EvidenceError):
            gate.parse_discovery(discovery() + "\nRightClickCoreTests.SampleTests/test existing")

    def testEmptyDiscoveryRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "No test identities"):
            gate.parse_discovery("Build complete! (0.1s)")

    def testMissingBaselineRejected(self):
        identities = {"SampleTests.testNew": "passed"}
        with self.assertRaisesRegex(gate.EvidenceError, "Baseline regression"):
            gate.validate(baseline(), gate.parse_discovery(discovery(list(identities))), gate.parse_log(log(identities)), {})

    def testPassToSkipRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "pass-to-nonpass"):
            gate.validate(baseline(), gate.parse_discovery(discovery()), gate.parse_log(log({"SampleTests.testExisting": "skipped"})), {})

    def testSkippedBaselineRetainedAndMayImprove(self):
        skipped = baseline([["SampleTests.testExisting", "skipped", None]])
        for outcome in ["skipped", "passed"]:
            self.assertEqual(gate.validate(skipped, gate.parse_discovery(discovery()), gate.parse_log(log({"SampleTests.testExisting": outcome})), {})["status"], "passed")

    def testAnyNewFailureRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Failed suite"):
            gate.parse_log(log({"SampleTests.testExisting": "failed"}))

    def testDiscoveredButUnexecutedRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Discovery/execution mismatch"):
            gate.validate(baseline(), gate.parse_discovery(discovery(["SampleTests.testExisting", "SampleTests.testNew"])), gate.parse_log(log()), {})

    def testExecutedButUndiscoveredRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "undiscovered"):
            gate.validate(baseline(), gate.parse_discovery(discovery()), gate.parse_log(log({"SampleTests.testExisting": "passed", "SampleTests.testNew": "passed"})), {})

    def testModuleSubstitutionRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "module collision"):
            gate.validate(baseline(), gate.parse_discovery(discovery(module="RightClickMCPTests")), gate.parse_log(log()), {})

    def testTruncatedAfterCasesRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Incomplete"):
            gate.parse_log(log().split("Test Suite 'SampleTests' passed")[0])

    def testMissingRootSummaryRejected(self):
        text = log()
        last = text.rfind("\t Executed")
        with self.assertRaisesRegex(gate.EvidenceError, "Missing summary"):
            gate.parse_log(text[:last] + "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.")

    def testSummaryCountMismatchRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Summary/case discrepancy"):
            gate.parse_log(log().replace("Executed 1 tests", "Executed 2 tests"))

    def testSummarySkipMismatchRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Summary/case discrepancy"):
            gate.parse_log(log().replace("with 0 failures", "with 1 tests skipped and 0 failures"))

    def testDuplicateTerminalOutcomeRejected(self):
        terminal = "Test Case '-[RightClickCoreTests.SampleTests testExisting]' passed (0.001 seconds)."
        with self.assertRaisesRegex(gate.EvidenceError, "duplicate case completion"):
            gate.parse_log(log().replace(terminal, terminal + "\n" + terminal))

    def testDuplicateRunRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Multiple test runs"):
            gate.parse_log(log() + "\n" + log())

    def testSignalCrashRejectedEvenAfterAppendedGreenFooter(self):
        with self.assertRaisesRegex(gate.EvidenceError, "crashed"):
            gate.parse_log(log() + "\nerror: Exited with unexpected signal code 5\n✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.")

    def testMalformedCaseRejected(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Malformed XCTest event"):
            gate.parse_log(log().replace(" passed (0.001 seconds).", " succeeded (0.001 seconds)."))

    def testNonzeroSwiftTestingNotSilentlyOmitted(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Additional Swift Testing"):
            gate.parse_log(log().replace("with 0 tests in 0 suites", "with 1 test in 1 suite"))

    def testOnlyReviewedRenameAccepted(self):
        path = SCRIPT.parents[2] / "docs/reconciliation-baselines/reviewed-test-mappings.json"
        document = gate.read_json(path)
        mapping = gate.mapping_document(document, "macos-arm64")
        old, new = gate.ALLOWED_RENAME
        result = gate.validate(baseline([[old, "passed", "passed"]]), gate.parse_discovery(discovery([new])), gate.parse_log(log({new: "passed"})), mapping)
        self.assertEqual(result["status"], "passed")
        document["renames"][0]["to"] = "PolicyTests.testEasyReplacement"
        with self.assertRaisesRegex(gate.EvidenceError, "Unreviewed"):
            gate.mapping_document(document, "macos-arm64")

    def testRenamingCannotCombineTwoOriginalIdentities(self):
        rows = [["SampleTests.testExisting", "passed", None], ["SampleTests.testOther", "passed", None]]
        with self.assertRaisesRegex(gate.EvidenceError, "Mapped identities collide"):
            gate.validate(baseline(rows), gate.parse_discovery(discovery()), gate.parse_log(log()), {"SampleTests.testOther": "SampleTests.testExisting"})

    def testReviewedPolicyReplacementAccountsForBothExactHeadIdentities(self):
        old, new = gate.ALLOWED_RENAME
        rows = [[old, "passed", None], [new, None, "passed"]]
        result = gate.validate(baseline(rows), gate.parse_discovery(discovery([new])), gate.parse_log(log({new: "passed"})), {old: new})
        self.assertEqual((result["baselineIdentities"], result["baselineExecutionTargets"], result["requiredPassTargets"]), (2, 1, 1))

    def testProvisionedFixtureSkipRejected(self):
        cases = {"SampleTests.testExisting": "passed", "FixtureTests.testProvisioned": "skipped"}
        with self.assertRaisesRegex(gate.EvidenceError, "Provisioned fixture"):
            gate.validate(baseline(), gate.parse_discovery(discovery(list(cases))), gate.parse_log(log(cases)), {}, require_pass=["FixtureTests.testProvisioned"])

    def testSelectedFixtureExplicitlyScoped(self):
        identities = ["SampleTests.testExisting", "FixtureTests.testProvisioned"]
        result = gate.validate(baseline(), gate.parse_discovery(discovery(identities)), gate.parse_log(log({identities[1]: "passed"}, root="Selected tests"), "fixture"), {}, require_pass=[identities[1]], selection="^FixtureTests\\.")
        self.assertEqual((result["scope"], result["completed"]), ("fixture", 1))

    def testSelectedLogCannotSatisfyFullSuite(self):
        with self.assertRaisesRegex(gate.EvidenceError, "Expected 'All tests'"):
            gate.parse_log(log(root="Selected tests"))

    def testDuplicateJSONKeysRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"test":1,"test":2}')
            with self.assertRaisesRegex(gate.EvidenceError, "Duplicate JSON key"):
                gate.read_json(path)

    def testSourceScannerIgnoresCommentsStringsAndNestedHelpers(self):
        source = '''final class SampleTests: XCTestCase {
          // func testForged() {}
          let fake = "func testString() {}"
          let raw = #"class ForgedTests { func testRaw() {} }"#
          let multiline = """func testMultiline() { }"""
          /* nested /* class Fake { func testFalse() {} } */ comment */
          func testExisting() { func testLocalHelper() {} }
          private class Helper { func helper() {} }
        }
        extension SampleTests { func testExtension() {} }
        '''
        self.assertEqual(gate.source_declarations(source), ["SampleTests.testExisting", "SampleTests.testExtension"])

    def testConditionalSourceDeclarationCannotDisappear(self):
        sb = {"schemaVersion":1, "sourceHeads":gate.HEADS, "candidates":[{"files":[{"declaredTests":["SampleTests.testExisting", "NativeTests.testConditional"]}]}]}
        with self.assertRaisesRegex(gate.EvidenceError, "Source test declarations disappeared"):
            gate.validate(baseline(), gate.parse_discovery(discovery()), gate.parse_log(log()), {}, sb, {"SampleTests.testExisting":["Sample.swift"]})

    def testPinnedManifestModificationRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "baseline-macos-arm64.json"
            path.write_text(json.dumps(baseline()))
            with self.assertRaisesRegex(gate.EvidenceError, "Immutable baseline pin mismatch"):
                gate.pinned_manifest(Path(directory), path.name)


if __name__ == "__main__":
    unittest.main()
