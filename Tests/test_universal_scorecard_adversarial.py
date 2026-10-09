"""Frozen structural controls, using disposable SYNTHETIC data only.

No fixture in this module is a real restricted-agent run, external observation,
valid receipt, release binary or acceptance evidence. A positive result proves
only that the validator accepts a complete structural test input. All fixture
bytes live in temporary directories and are deleted after each test.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "scorecard_adversarial_gate", REPOSITORY / "scripts/check-universal-scorecard.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)

STREAM_WORLDS = {"grpc", "kafka", "kubernetes", "a2a"}
PROOF_KINDS = {
    "restricted_agent_acceptance", "independent_observation",
    "receipt_verification", "withdrawal_proof", "stale_binding_denial",
}
STAGE_ROLES = {
    "acquisition": ["restricted_agent_acceptance"],
    "common_abi": ["restricted_agent_acceptance"],
    "authority": ["restricted_agent_acceptance"],
    "policy": ["restricted_agent_acceptance"],
    "execution": ["restricted_agent_acceptance"],
    "async_stream": ["stream_lifecycle"],
    "independent_verification": ["independent_observation"],
    "receipt": ["receipt_verification"],
    "withdrawal": ["withdrawal_proof", "stale_binding_denial"],
    "real_world_proof": ["restricted_agent_acceptance"],
}


class SyntheticStructuralFixture:
    """Complete shape only: its asserted metadata is deliberately synthetic."""

    def __init__(self, root):
        self.root = root
        template = json.loads(
            (REPOSITORY / "docs/universal-substrate-scorecard.json").read_text())
        self.scorecard = copy.deepcopy(template)
        self.binary = self.write_bytes(
            "evidence/synthetic-rightclick.bin",
            b"SYNTHETIC structural fixture; not an executable or release\n")
        self.identity = {
            "source_commit": template["audited_candidate"],
            "binary_sha256": self.binary["sha256"],
            "session_id": "SYNTHETIC-STRUCTURAL-TEST-SESSION",
        }
        self.implementation = self.write_bytes(
            "Sources/synthetic.swift", b"// source code only; no acceptance proof\n")
        self.manifest = {
            "synthetic_test_fixture": True,
            "agent_kind": "fresh_restricted_ai",
            "same_live_session": True,
            "model_visible_operations": template["canonical_operations"],
            "provider_specific_tools_added": 0,
            **self.identity,
            "runtime_attestation": self.write_json("evidence/runtime-attestation.json", {
                "synthetic_test_fixture": True,
                "product": "RIGHTCLICK", "version": "0.0.0-synthetic-test",
                "platform": "synthetic", "pid": 123, "transport": "stdio",
                "executablePath": "/synthetic/rightclick",
                "executableRealPath": "/synthetic/rightclick",
                "executableSHA256": self.identity["binary_sha256"],
                "session_id": self.identity["session_id"],
            }),
            "binary_provenance": self.write_json("evidence/binary-provenance.json", {
                "synthetic_test_fixture": True, **self.identity,
                "binary_artifact": self.binary,
            }),
            "proofs": {},
        }
        for row in self.scorecard["substrates"]:
            world = row["id"]
            roles = PROOF_KINDS | {"stream_lifecycle"}
            self.manifest["proofs"][world] = []
            for kind in sorted(roles):
                artifact = self.write_bytes(
                    "evidence/" + world + "/" + kind + ".synthetic.txt",
                    ("SYNTHETIC " + world + " " + kind +
                     "; no real effect or signature is asserted by this test\n").encode())
                report = {
                    "type": "rightclick_universal_evidence_v1",
                    "synthetic_test_fixture": True,
                    "kind": kind, "substrate": world,
                    **self.identity, "outcome": "PASS",
                    "supporting_artifacts": [artifact],
                }
                reference = self.write_json(
                    "evidence/" + world + "/" + kind + ".json", report)
                self.manifest["proofs"][world].append({
                    **reference, "kind": kind, "substrate": world,
                    **self.identity, "real_environment": True,
                })
            row["status"] = "GREEN"
            row["implementation_reference"] = self.implementation
            row["supporting_evidence"] = []
            row["stages"] = {
                stage: {"status": "GREEN", "evidence": [
                    self.reference(world, kind) for kind in kinds]}
                for stage, kinds in STAGE_ROLES.items()
            }
        self.commit_manifest()

    def write_bytes(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"path": relative, "sha256": hashlib.sha256(data).hexdigest()}

    def write_json(self, relative, value):
        return self.write_bytes(relative, json.dumps(value, sort_keys=True).encode())

    def reference(self, world, kind):
        return next(item for item in self.manifest["proofs"][world]
                    if item["kind"] == kind)

    def row(self, world):
        return next(row for row in self.scorecard["substrates"] if row["id"] == world)

    def report(self, world, kind):
        return json.loads((self.root / self.reference(world, kind)["path"]).read_text())

    def update_report(self, world, kind, value=None, raw=None):
        reference = self.reference(world, kind)
        data = raw if raw is not None else json.dumps(value, sort_keys=True).encode()
        reference.update(self.write_bytes(reference["path"], data))
        self.commit_manifest()

    def commit_manifest(self, raw=None):
        encoded = raw if raw is not None else json.dumps(self.manifest, sort_keys=True).encode()
        reference = self.write_bytes("evidence/acceptance-manifest.json", encoded)
        self.scorecard["restricted_agent_experiment"] = {
            "status": "GREEN", "evidence": reference,
        }

    def validate(self):
        return GATE.validate(self.scorecard, self.root, require_green=True)


class UniversalScorecardAdversarialTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rightclick-synthetic-scorecard-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "repository"
        self.root.mkdir()
        self.fixture = SyntheticStructuralFixture(self.root)

    def test_complete_synthetic_structure_is_not_real_acceptance(self):
        result = self.fixture.validate()
        self.assertEqual(result["green_substrates"], 11)
        self.assertIn("Structural", result["boundary"])
        self.assertTrue(self.fixture.manifest["synthetic_test_fixture"])

    def test_manifest_is_parsed_from_exact_checked_bytes_after_path_replacement(self):
        fixture = self.fixture
        reference = fixture.scorecard["restricted_agent_experiment"]["evidence"]
        original = GATE.evidence_reference
        outside = Path(self.directory.name) / "outside-unchecked-manifest.json"
        bad = copy.deepcopy(fixture.manifest)
        bad["provider_specific_tools_added"] = 1
        outside.write_text(json.dumps(bad))
        swapped = []

        def check_then_replace(item, root):
            checked = original(item, root)
            if item["path"] == reference["path"] and not swapped:
                manifest_path = root / item["path"]
                manifest_path.unlink()
                manifest_path.symlink_to(outside)
                swapped.append(True)
            return checked

        with patch.object(GATE, "evidence_reference", side_effect=check_then_replace):
            result = fixture.validate()
        self.assertEqual(swapped, [True])
        self.assertEqual(result["green_substrates"], 11,
                         "The valid checked bytes must be parsed, never the replaced external path")

    def test_source_file_cannot_masquerade_as_acceptance_report(self):
        reference = self.fixture.reference("macos", "restricted_agent_acceptance")
        reference.update(self.fixture.implementation)
        self.fixture.commit_manifest()
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_unrelated_source_file_cannot_establish_green_stage(self):
        self.fixture.row("macos")["stages"]["authority"]["evidence"] = [self.fixture.implementation]
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_green_stage_must_use_its_world_and_matching_proof_role(self):
        for evidence in [self.fixture.reference("windows", "receipt_verification"),
                         self.fixture.reference("macos", "restricted_agent_acceptance")]:
            with self.subTest(evidence=evidence["path"]):
                self.fixture.row("macos")["stages"]["receipt"]["evidence"] = [evidence]
                with self.assertRaises(GATE.InvalidScorecard):
                    self.fixture.validate()

    def test_required_async_world_cannot_be_declared_inapplicable(self):
        for world in sorted(STREAM_WORLDS):
            with self.subTest(world=world):
                fixture = SyntheticStructuralFixture(self.root)
                fixture.row(world)["stages"]["async_stream"] = {
                    "status": "NOT_APPLICABLE", "reason": "not applicable", "evidence": []}
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_required_async_world_needs_stream_lifecycle_proof(self):
        for world in sorted(STREAM_WORLDS):
            with self.subTest(world=world):
                fixture = SyntheticStructuralFixture(self.root)
                fixture.manifest["proofs"][world] = [item for item in fixture.manifest["proofs"][world]
                                                     if item["kind"] != "stream_lifecycle"]
                fixture.row(world)["stages"]["async_stream"]["evidence"] = [
                    fixture.reference(world, "restricted_agent_acceptance")]
                fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_manifest_tool_counter_requires_exact_integer_zero(self):
        for counter in [False, 0.0]:
            with self.subTest(counter=repr(counter)):
                self.fixture.manifest["provider_specific_tools_added"] = counter
                self.fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    self.fixture.validate()

    def test_missing_and_added_tools_are_rejected(self):
        operations = self.fixture.manifest["model_visible_operations"]
        for bad in [operations[:-1], operations + ["grpc_read"]]:
            with self.subTest(operations=bad):
                self.fixture.manifest["model_visible_operations"] = bad
                self.fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    self.fixture.validate()

    def test_reference_source_binary_and_session_mismatch_is_rejected(self):
        for field, wrong in [("source_commit", "0" * 40), ("binary_sha256", "0" * 64),
                             ("session_id", "OTHER-SYNTHETIC-SESSION")]:
            with self.subTest(field=field):
                fixture = SyntheticStructuralFixture(self.root)
                fixture.reference("macos", "restricted_agent_acceptance")[field] = wrong
                fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_report_source_binary_session_kind_and_world_mismatch_is_rejected(self):
        for field, wrong in [("source_commit", "0" * 40), ("binary_sha256", "0" * 64),
                             ("session_id", "OTHER-SYNTHETIC-SESSION"),
                             ("kind", "independent_observation"), ("substrate", "windows")]:
            with self.subTest(field=field):
                fixture = SyntheticStructuralFixture(self.root)
                report = fixture.report("macos", "restricted_agent_acceptance")
                report[field] = wrong
                fixture.update_report("macos", "restricted_agent_acceptance", report)
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_missing_required_proof_kind_is_rejected(self):
        for kind in sorted(PROOF_KINDS):
            with self.subTest(kind=kind):
                fixture = SyntheticStructuralFixture(self.root)
                fixture.manifest["proofs"]["macos"] = [item for item in fixture.manifest["proofs"]["macos"]
                                                      if item["kind"] != kind]
                fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_report_requires_pass_outcome_and_supporting_artifact(self):
        for field, value in [("outcome", "FAIL"), ("supporting_artifacts", [])]:
            with self.subTest(field=field):
                fixture = SyntheticStructuralFixture(self.root)
                report = fixture.report("macos", "receipt_verification")
                report[field] = value
                fixture.update_report("macos", "receipt_verification", report)
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_proof_roles_cannot_reuse_the_same_supporting_artifact(self):
        report = self.fixture.report("macos", "independent_observation")
        report["supporting_artifacts"] = self.fixture.report(
            "macos", "restricted_agent_acceptance")["supporting_artifacts"]
        self.fixture.update_report("macos", "independent_observation", report)
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_supporting_artifact_drift_is_rejected(self):
        artifact = self.fixture.report("macos", "receipt_verification")["supporting_artifacts"][0]
        (self.root / artifact["path"]).write_text("SYNTHETIC tampered bytes\n")
        with self.assertRaises(GATE.InvalidScorecard):
            self.fixture.validate()

    def test_runtime_attestation_and_binary_provenance_must_match_manifest(self):
        for role, field, wrong in [("runtime_attestation", "executableSHA256", "0" * 64),
                                   ("runtime_attestation", "session_id", "OTHER-SYNTHETIC-SESSION"),
                                   ("binary_provenance", "source_commit", "0" * 40),
                                   ("binary_provenance", "binary_sha256", "0" * 64)]:
            with self.subTest(role=role, field=field):
                fixture = SyntheticStructuralFixture(self.root)
                reference = fixture.manifest[role]
                report = json.loads((self.root / reference["path"]).read_text())
                report[field] = wrong
                reference.update(fixture.write_json(reference["path"], report))
                fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_missing_runtime_attestation_or_provenance_is_rejected(self):
        for role in ["runtime_attestation", "binary_provenance"]:
            with self.subTest(role=role):
                fixture = SyntheticStructuralFixture(self.root)
                del fixture.manifest[role]
                fixture.commit_manifest()
                with self.assertRaises(GATE.InvalidScorecard):
                    fixture.validate()

    def test_duplicate_manifest_keys_are_rejected(self):
        encoded = json.dumps(self.fixture.manifest, sort_keys=True)
        raw = ('{"session_id":"CONFLICTING-SYNTHETIC-SESSION",' + encoded[1:]).encode()
        self.fixture.commit_manifest(raw=raw)
        with self.assertRaises((GATE.InvalidScorecard, ValueError)):
            self.fixture.validate()

    def test_duplicate_report_keys_are_rejected(self):
        encoded = json.dumps(self.fixture.report("macos", "receipt_verification"), sort_keys=True)
        raw = ('{"outcome":"FAIL",' + encoded[1:]).encode()
        self.fixture.update_report("macos", "receipt_verification", raw=raw)
        with self.assertRaises((GATE.InvalidScorecard, ValueError)):
            self.fixture.validate()


if __name__ == "__main__":
    unittest.main()
