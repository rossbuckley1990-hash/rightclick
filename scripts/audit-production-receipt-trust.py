#!/usr/bin/env python3
"""Replay public production-trust RED evidence with an independent decoder.

The policy clock is the receipt's observation time, solely an evidence replay.
This does not establish current policy freshness or the missing runtime seam.
"""
import argparse
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("receipt", Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
args = parser.parse_args()
expected = {
    "testActiveIssuerControlProducesOneTrustedObservedEffect": (1, True),
    "testLegalHostKeyRotationControlUsesFreshTrustedKey": (2, True),
    "testPreRevokedPolicyDeniesAdmissionWithZeroProviderEffects": (1, False),
    "testRevokedPolicyAfterAdmissionWithholdsSignatureAndRetainsRealTruth": (1, False),
}
cases = {}
for case in args.evidence.iterdir():
    if case.is_dir():
        matching = [name for name in expected if name in case.name]
        assert len(matching) == 1, case.name
        assert matching[0] not in cases, "duplicate case"
        cases[matching[0]] = case
assert set(cases) == set(expected), "incomplete evidence"
results = []
for name, (count, trusted) in expected.items():
    case = cases[name]
    records = json.loads((case / "runtime-records.json").read_text())
    summary = json.loads((case / "control-summary.json").read_text())
    policy = case / "host-policy-current.json"
    finals = {}
    for record in records:
        finals[record["executionId"]] = record
    assert len(finals) == count
    def rows(file):
        return [json.loads(line) for line in (case / file).read_text().splitlines()]
    requests, effects, observations = [rows(file) for file in ("requests.jsonl", "effects.jsonl", "observations.jsonl")]
    assert len(requests) == len(effects) == len(observations) == count
    assert len({row["challenge"] for row in requests}) == count
    assert {row["challenge"] for row in requests} == {row["challenge"] for row in effects} == {row["challenge"] for row in observations}
    by_challenge = [{row["challenge"]: row for row in group} for group in (requests, effects, observations)]
    verified = []
    for slot, final in enumerate(finals.values()):
        runtime = final["rcir"]
        assert final["state"] == runtime["outcome"] == "succeeded"
        assert final["evidence"]["outcomeVerified"] is True
        request, effect, observed = [group[requests[slot]["challenge"]] for group in by_challenge]
        assert request["method"] == "message/send"
        assert request["invocation"] == observed["invocation"] == runtime["taskID"]
        assert request["taskID"] == effect["taskID"]
        assert observed["observed"] == effect["value"]
        assert json.loads(observed["observed"]) == {"challenge": effect["challenge"], "value": "production-trust-effect"}
        with tempfile.TemporaryDirectory(prefix="rcir-production-public-audit-") as temporary:
            wire = Path(temporary) / "receipt.json"
            wire.write_text(json.dumps(runtime["signedReceipt"]))
            decoded = receipt.verify(wire, case / f"key-{slot if count == 2 else 0}-public.raw",
                expected_outcome="succeeded", expected_task_id=runtime["taskID"], expected_lease_id=runtime["leaseID"])
            policy_accepted = None
            if slot == count - 1:
                replay_time = decoded["signedClaims"]["lastObservationTime"]
                try:
                    receipt.verify_with_policy(wire, policy, mode="live", expected_issuer="issuer:production-fixture",
                        expected_task_id=runtime["taskID"], expected_lease_id=runtime["leaseID"],
                        expected_outcome="succeeded", verification_time=replay_time)
                    policy_accepted = True
                except ValueError as error:
                    assert not trusted and str(error) == "untrusted or revoked key", "different rejection"
                    policy_accepted = False
                assert policy_accepted == trusted
        verified.append({"slot": slot, "signature": decoded["signature"], "expectedTaskAndLease": "MATCHED",
            "providerTaskAndSeparateObserver": "MATCHED", "currentPolicyAtReplayTimeAccepted": policy_accepted})
    assert summary["currentPolicyAccepted"] == trusted
    if not trusted:
        assert summary["privateKeyUnchanged"] is True
        assert summary["policyRejectedBecauseRevoked"] is True
        assert all(record["rcir"]["signedReceipt"] for record in finals.values())
    if count == 2:
        assert (case / "key-0-public.raw").read_bytes() != (case / "key-1-public.raw").read_bytes()
    assert summary["runtimeReceiptPolicySeam"] == "MISSING_IN_FROZEN_BASELINE"
    results.append({"case": name, "requests": count, "effects": count, "separateObservations": count,
        "runtimeEmittedSignatureAfterPolicyRevocation": not trusted, "receipts": verified})
print(json.dumps({"independentMathAndJournalAudit": "PASS", "effects": sum(row["effects"] for row in results),
    "policyReplayClock": "SIGNED_OBSERVATION_TIME_FOR_EVIDENCE_REPLAY_ONLY",
    "currentPolicyProvenance": "CALLER_PROVISIONED_TEST_SIDECAR",
    "productionPolicySeam": "MISSING", "overallGoal": "RED", "results": results}, indent=2))
