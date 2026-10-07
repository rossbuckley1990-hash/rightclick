"""Additional frozen controls: disposable SYNTHETIC structure, not acceptance.

These controls supplement the unchanged original adversarial tests. Passing any
control certifies neither real provider effects nor evidence/signature truth.
"""
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Tests.test_universal_scorecard_adversarial import GATE, SyntheticStructuralFixture


class UniversalScorecardPathNumericTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rightclick-synthetic-scorecard-extra-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "repository"
        self.root.mkdir()
        self.fixture = SyntheticStructuralFixture(self.root)

    def test_supporting_artifact_cannot_reuse_normalized_path_alias(self):
        report = self.fixture.report("macos", "independent_observation")
        artifact = copy.deepcopy(self.fixture.report(
            "macos", "restricted_agent_acceptance")["supporting_artifacts"][0])
        artifact["path"] = artifact["path"].replace("/macos/", "/macos/./")
        report["supporting_artifacts"] = [artifact]
        self.fixture.update_report("macos", "independent_observation", report)
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_supporting_artifact_cannot_reuse_in_repository_symlink_alias(self):
        report = self.fixture.report("macos", "independent_observation")
        artifact = copy.deepcopy(self.fixture.report(
            "macos", "restricted_agent_acceptance")["supporting_artifacts"][0])
        alias = "evidence/macos/independent-observation-alias.txt"
        (self.root / alias).symlink_to(self.root / artifact["path"])
        artifact["path"] = alias
        report["supporting_artifacts"] = [artifact]
        self.fixture.update_report("macos", "independent_observation", report)
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_one_role_cannot_duplicate_support_with_normalized_alias(self):
        report = self.fixture.report("macos", "receipt_verification")
        alias = copy.deepcopy(report["supporting_artifacts"][0])
        alias["path"] = alias["path"].replace("/macos/", "/macos/./")
        report["supporting_artifacts"].append(alias)
        self.fixture.update_report("macos", "receipt_verification", report)
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_overflowing_json_exponents_are_rejected(self):
        for raw in [b'{"measurement":1e999}', b'{"measurement":-1e999}',
                    b'{"nested":{"measurement":[1e999]}}']:
            with self.subTest(raw=raw):
                with self.assertRaises(GATE.InvalidScorecard):
                    GATE.strict_json(raw)

    def test_manifest_with_overflowing_extra_measurement_is_rejected(self):
        reference = self.fixture.scorecard["restricted_agent_experiment"]["evidence"]
        checked = (self.root / reference["path"]).read_bytes()
        self.fixture.commit_manifest(raw=checked[:-1] + b',"synthetic_measurement":1e999}')
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_evidence_cannot_escape_after_resolve_before_read(self):
        inside = self.root / "evidence/synthetic-race.txt"
        outside = Path(self.directory.name) / "outside-synthetic-race.txt"
        inside.write_bytes(b"SYNTHETIC unchecked interior bytes\n")
        inside = inside.resolve()
        expected = b"SYNTHETIC exterior bytes; not authorized as repository evidence\n"
        outside.write_bytes(expected)
        reference = {"path": "evidence/synthetic-race.txt",
                     "sha256": hashlib.sha256(expected).hexdigest()}
        original = Path.read_bytes
        swapped = []

        def replace_then_read(path):
            if path == inside and not swapped:
                inside.unlink()
                inside.symlink_to(outside)
                swapped.append(True)
            return original(path)

        with patch.object(Path, "read_bytes", new=replace_then_read):
            with self.assertRaises((GATE.InvalidScorecard, OSError)):
                GATE.evidence_reference(reference, self.root)


if __name__ == "__main__":
    unittest.main()
