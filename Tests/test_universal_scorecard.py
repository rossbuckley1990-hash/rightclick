import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("scorecard_gate", ROOT / "scripts/check-universal-scorecard.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class UniversalScorecardTests(unittest.TestCase):
    def setUp(self):
        self.scorecard = json.loads((ROOT / "docs/universal-substrate-scorecard.json").read_text())

    def test_red_inventory_validates_but_cannot_pass_release(self):
        self.assertEqual(GATE.validate(self.scorecard, ROOT)["green_substrates"], 0)
        with self.assertRaisesRegex(GATE.InvalidScorecard, "remains RED"):
            GATE.validate(self.scorecard, ROOT, require_green=True)

    def test_provider_specific_operation_is_rejected(self):
        self.scorecard["canonical_operations"].append("kubernetes_create_pod")
        with self.assertRaisesRegex(GATE.InvalidScorecard, "precisely the seven"):
            GATE.validate(self.scorecard, ROOT)

    def test_duplicate_world_cannot_hide_a_missing_world(self):
        self.scorecard["substrates"][-1] = copy.deepcopy(self.scorecard["substrates"][0])
        with self.assertRaisesRegex(GATE.InvalidScorecard, "missing, duplicate"):
            GATE.validate(self.scorecard, ROOT)

    def test_green_from_source_or_unit_tests_is_rejected(self):
        row = self.scorecard["substrates"][0]
        row["stages"]["acquisition"] = {"status": "GREEN", "evidence": [row["implementation_reference"]]}
        with self.assertRaisesRegex(GATE.InvalidScorecard, "before the restricted-agent"):
            GATE.validate(self.scorecard, ROOT)

    def test_green_requires_independent_observations_and_receipts(self):
        self.scorecard["restricted_agent_experiment"] = {"status": "GREEN", "evidence": None}
        with self.assertRaisesRegex(GATE.InvalidScorecard, "evidence reference"):
            GATE.validate(self.scorecard, ROOT)

    def test_only_async_stream_can_be_inapplicable(self):
        self.scorecard["substrates"][0]["stages"]["authority"] = {
            "status": "NOT_APPLICABLE", "reason": "this provider says it is safe", "evidence": []}
        with self.assertRaisesRegex(GATE.InvalidScorecard, "only async/stream"):
            GATE.validate(self.scorecard, ROOT)

    def test_evidence_bytes_are_pinned(self):
        self.scorecard["substrates"][0]["implementation_reference"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(GATE.InvalidScorecard, "digest mismatch"):
            GATE.validate(self.scorecard, ROOT)

    def test_evidence_path_cannot_escape_even_through_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            root.mkdir()
            outside = Path(directory) / "outside.json"
            outside.write_text("{}")
            (root / "escape").symlink_to(outside)
            with self.assertRaisesRegex(GATE.InvalidScorecard, "escapes"):
                GATE.evidence_reference({"path": "escape", "sha256": "0" * 64}, root)

    def test_malformed_tool_counter_cannot_claim_zero(self):
        self.scorecard["provider_specific_top_level_tools_added"] = False
        with self.assertRaisesRegex(GATE.InvalidScorecard, "forbidden"):
            GATE.validate(self.scorecard, ROOT)


if __name__ == "__main__":
    unittest.main()
