"""Frozen filesystem-specific SYNTHETIC role-separation control.

Added after the protected-read fixes. A case-sensitive filesystem explicitly
skips this real-filesystem control; such a skip does not prove this boundary.
"""
import copy
import os
from pathlib import Path
import tempfile
import unittest

from Tests.test_universal_scorecard_adversarial import GATE, SyntheticStructuralFixture


class UniversalScorecardCaseAliasTests(unittest.TestCase):
    def test_case_alias_cannot_reuse_another_roles_supporting_artifact(self):
        with tempfile.TemporaryDirectory(prefix="rightclick-synthetic-case-alias-") as directory:
            root = Path(directory) / "repository"
            root.mkdir()
            fixture = SyntheticStructuralFixture(root)
            artifact = copy.deepcopy(fixture.report(
                "macos", "restricted_agent_acceptance")["supporting_artifacts"][0])
            original = root / artifact["path"]
            relative = Path(artifact["path"])
            artifact["path"] = str(relative.parent / relative.name.upper())
            alias = root / artifact["path"]
            if not alias.exists():
                self.skipTest("case-sensitive filesystem; case-alias boundary remains untested")
            self.assertTrue(os.path.samefile(original, alias), "Control requires one physical file")
            report = fixture.report("macos", "independent_observation")
            report["supporting_artifacts"] = [artifact]
            fixture.update_report("macos", "independent_observation", report)
            with self.assertRaises(GATE.InvalidScorecard):
                fixture.validate()


if __name__ == "__main__":
    unittest.main()
