#!/usr/bin/env python3
"""Independently audit the twelve actual production-trust GREEN controls.

Unsigned canonical receipts are runtime assertions, never authenticated receipts.
Separate fixture journals establish the observed effect. Policy replay uses the
receipt's signed/asserted observation time; it is not live snapshot freshness.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("receipt", Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
intermediate = parser.add_mutually_exclusive_group()
intermediate.add_argument("--intermediate-ten", action="store_true", help="Audit the explicitly intermediate ten-case source before the consumption-callback repair")
intermediate.add_argument("--intermediate-eleven", action="store_true", help="Audit the explicitly intermediate eleven-case source before actual lease-expiry repair")
args = parser.parse_args()
# requests/effects/observations, rejected executions, actually signed receipts.
expected = {
    "testActiveIssuerControlProducesOneTrustedObservedEffect": (1, 0, 1),
    "testLegalHostKeyRotationControlUsesFreshTrustedKey": (2, 0, 2),
    "testPreRevokedPolicyDeniesAdmissionWithZeroProviderEffects": (0, 1, 0),
    "testRevokedPolicyAfterAdmissionWithholdsSignatureAndRetainsRealTruth": (1, 0, 0),
    "testRestoredOlderPolicyCannotResurrectObservedRevocation": (1, 1, 0),
    "testDeletedPolicyAfterAdmissionPreservesObservedUnsignedTruth": (1, 0, 0),
    "testMalformedPolicyBeforeAdmissionHasZeroProviderEffects": (0, 1, 0),
    "testActuallyExpiredKeyBeforeAdmissionHasZeroProviderEffects": (0, 1, 0),
    "testActualClockExpiryAfterHeldAdmissionWithholdsSignature": (1, 0, 0),
    "testConfigurationRefreshRevokesPolicyBeforeFinalAdmissionHasZeroEffects": (0, 1, 0),
    "testConsumptionCallbackRevokesPolicyBeforeFinalAdmissionHasZeroEffects": (0, 1, 0),
    "testActualLeaseExpiryDuringProtectedSigningValidationHasZeroEffects": (0, 1, 0),
}
if args.intermediate_ten or args.intermediate_eleven:
    del expected["testActualLeaseExpiryDuringProtectedSigningValidationHasZeroEffects"]
if args.intermediate_ten:
    del expected["testConsumptionCallbackRevokesPolicyBeforeFinalAdmissionHasZeroEffects"]
def read(path):
    with path.open("rb") as file:
        data = file.read(33_554_433)
    assert len(data) <= 33_554_432, "audit file bound"
    return data
def document(path):
    return json.loads(read(path), object_pairs_hook=receipt.unique)
def rows(case, name):
    return [json.loads(line, object_pairs_hook=receipt.unique) for line in read(case / name).splitlines()]
def binary(value):
    assert isinstance(value, str) and len(value) <= 1_500_000
    data = base64.b64decode(value, validate=True)
    assert base64.b64encode(data).decode("ascii") == value
    return data

cases = {}
for case in args.evidence.iterdir():
    if case.is_dir():
        matching = [name for name in expected if name in case.name]
        assert len(matching) == 1, "unknown or ambiguous case"
        assert matching[0] not in cases, "duplicate case"
        cases[matching[0]] = case
assert set(cases) == set(expected), "incomplete exact control evidence"
results = []
all_tasks = set()
withheld = "RCIR signed receipt withheld because current provisioned signing authority is unavailable."
for name, (count, rejected_count, signed_count) in expected.items():
    case = cases[name]
    records = document(case / "runtime-records.json")
    summary = document(case / "control-summary.json")
    assert summary["runtimeReceiptPolicySeam"] == "HOST_PROTECTED_POLICY_REFERENCE"
    history = rows(case, "policy-history.jsonl")
    assert 1 <= len(history) <= 16
    policies, history_bytes = [], []
    previous_time = 0
    for sequence, event in enumerate(history, 1):
        assert set(event) == {"sequence", "observedAtMilliseconds", "reference", "sourceSHA256", "publicPolicyBase64"}
        assert type(event["sequence"]) is int and event["sequence"] == sequence
        assert type(event["observedAtMilliseconds"]) is int and event["observedAtMilliseconds"] >= previous_time
        previous_time = event["observedAtMilliseconds"]
        assert event["reference"] == "host-policy"
        public_bytes = binary(event["publicPolicyBase64"])
        assert len(public_bytes) <= 131_072
        assert hashlib.sha256(public_bytes).hexdigest() == event["sourceSHA256"]
        history_bytes.append(public_bytes)
        try:
            policy = json.loads(public_bytes, object_pairs_hook=receipt.unique)
            receipt._trust_policy(policy)
            assert policy["issuerID"] == "issuer:production-fixture"
            policies.append(policy)
        except ValueError:
            assert name == "testMalformedPolicyBeforeAdmissionHasZeroProviderEffects" and sequence == len(history)
            policies.append(None)
    if (case / "host-policy-current.json").exists():
        assert read(case / "host-policy-current.json") == history_bytes[-1]
    finals = {}
    for record in records:
        finals[record["executionId"]] = record
    rejected = [record for record in finals.values() if record["state"] == "rejected"]
    completed = [record for record in finals.values() if record["state"] == "succeeded"]
    assert len(rejected) == rejected_count and len(completed) == count
    assert len(finals) == rejected_count + count
    requests, effects, observations = [rows(case, file) for file in ("requests.jsonl", "effects.jsonl", "observations.jsonl")]
    assert len(requests) == len(effects) == len(observations) == count
    by_invocation = {row["invocation"]: row for row in requests}
    assert len(by_invocation) == count
    by_challenge = [{row["challenge"]: row for row in group} for group in (requests, effects, observations)]
    assert len(by_challenge[0]) == count
    assert set(by_challenge[0]) == set(by_challenge[1]) == set(by_challenge[2])
    for record in rejected:
        rcir = record.get("rcir") or {}
        assert not rcir.get("signedReceipt") and not rcir.get("receipt")
        assert not record["evidence"]["outcomeVerified"]
        assert not rcir.get("taskID") or rcir["taskID"] not in by_invocation
    receipts = []
    for slot, final in enumerate(completed):
        rcir = final["rcir"]
        assert rcir["outcome"] == "succeeded" and rcir["phase"] == "completed"
        assert rcir["leaseConsumed"] is True and final["evidence"]["outcomeVerified"] is True
        assert rcir["taskID"] not in all_tasks
        all_tasks.add(rcir["taskID"])
        request = by_invocation[rcir["taskID"]]
        challenge = request["challenge"]
        effect, observation = [group[challenge] for group in by_challenge[1:]]
        assert request["method"] == "message/send"
        assert request["taskID"] == effect["taskID"]
        assert observation["invocation"] == request["invocation"]
        assert observation["observed"] == effect["value"]
        assert json.loads(effect["value"]) == {"challenge": challenge, "value": "production-trust-effect"}
        payload = binary(rcir["receipt"])
        assert len(payload) <= receipt.MAX_PAYLOAD
        claims = receipt._signed_claims(payload)
        canonical = receipt._domain(payload, "RECEIPT")
        request_binding = receipt._domain(canonical["request"], "REQUEST")
        assert receipt._value(request_binding["arguments"]) == {"message": effect["value"]}
        assert receipt._value(canonical["observation"]) == observation["observed"]
        assert claims["taskID"] == rcir["taskID"] and claims["leaseID"] == rcir["leaseID"]
        assert claims["semanticOutcome"] == "succeeded" and claims["phase"] == "completed"
        for earlier in records:
            if earlier["executionId"] == final["executionId"] and earlier.get("rcir"):
                assert earlier["rcir"]["taskID"] == rcir["taskID"]
                assert earlier["rcir"]["leaseID"] == rcir["leaseID"]
        signed = rcir.get("signedReceipt")
        verdict = "UNSIGNED_RUNTIME_ASSERTION"
        policy_accepted = None
        if signed is not None:
            assert binary(signed["payload"]) == payload
            with tempfile.TemporaryDirectory(prefix="rcir-green-public-audit-") as temporary:
                wire = Path(temporary) / "receipt.json"
                wire.write_text(json.dumps(signed))
                checked = receipt.verify(wire, case / f"key-{slot if count == 2 else 0}-public.raw",
                    expected_outcome="succeeded", expected_task_id=rcir["taskID"], expected_lease_id=rcir["leaseID"])
                assert checked["signedClaims"] == claims
                verdict = checked["signature"]
                receipt.verify_with_policy(wire, case / "host-policy-current.json", mode="live",
                    expected_issuer="issuer:production-fixture", expected_task_id=rcir["taskID"],
                    expected_lease_id=rcir["leaseID"], expected_outcome="succeeded",
                    verification_time=claims["lastObservationTime"])
                policy_accepted = True
        else:
            assert withheld in final["events"]
        receipts.append({"slot": slot, "signature": verdict, "canonicalClaims": "STRUCTURALLY_VALID",
            "expectedTaskAndLease": "MATCHED", "separateEffectAndObserver": "MATCHED",
            "boundArgumentsAndObservationBytes": "MATCHED",
            "currentPolicyAtReplayTimeAccepted": policy_accepted})
    assert sum(row["signature"] == "VALID" for row in receipts) == signed_count
    if "RevokedPolicyAfter" in name or "PreRevokedPolicy" in name:
        assert summary["privateKeyUnchanged"] is True
        assert len(history) == 2 and policies[0]["keys"][0]["revoked"] is False and policies[1]["keys"][0]["revoked"] is True
        assert policies[0]["keys"][0]["publicKey"] == policies[1]["keys"][0]["publicKey"]
        if count:
            assert claims["startedAt"] <= history[1]["observedAtMilliseconds"] <= claims["lastObservationTime"]
    if "RestoredOlderPolicy" in name:
        assert summary["restoredOldPolicyDenied"] is True
        assert len(history) == 3 and history_bytes[0] == history_bytes[2]
        assert policies[0]["keys"][0]["revoked"] is False and policies[1]["keys"][0]["revoked"] is True
        assert claims["startedAt"] <= history[1]["observedAtMilliseconds"] <= claims["lastObservationTime"]
        assert history[2]["observedAtMilliseconds"] >= claims["lastObservationTime"]
    if "ConfigurationRefreshRevokes" in name:
        assert summary["revokedDuringFinalAdmissionRefresh"] is True
        assert summary["configurationReadsAfterBoundary"] >= 5
        assert len(history) == 2 and policies[0]["keys"][0]["revoked"] is False and policies[1]["keys"][0]["revoked"] is True
    if "ConsumptionCallbackRevokes" in name:
        assert summary["revokedDuringConsumptionCallback"] is True
        assert not summary.get("revocationWriteFailed")
        assert len(history) == 2 and policies[0]["keys"][0]["revoked"] is False and policies[1]["keys"][0]["revoked"] is True
    if "ActualLeaseExpiryDuring" in name:
        assert summary["actualHostClockReachedLeaseExpiry"] is True
        assert type(summary["leaseExpiresAt"]) is int and summary["leaseExpiresAt"] >= 0
        assert len(history) == 1 and policies[0]["keys"][0]["revoked"] is False
        key = policies[0]["keys"][0]
        assert key["notBefore"] <= summary["leaseExpiresAt"] < key["notAfter"]
    if "ActualClockExpiryAfter" in name:
        assert summary["actualHostClockReachedExpiry"] is True
        policy = document(case / "host-policy-current.json")
        assert claims["lastObservationTime"] >= policy["keys"][0]["notAfter"]
    if "DeletedPolicy" in name:
        assert not (case / "host-policy-current.json").exists()
    if "MalformedPolicy" in name:
        assert policies[-1] is None
    if "ActuallyExpiredKeyBefore" in name:
        assert history[-1]["observedAtMilliseconds"] >= policies[-1]["keys"][0]["notAfter"]
    if count == 2:
        assert read(case / "key-0-public.raw") != read(case / "key-1-public.raw")
    results.append({"case": name, "requests": count, "effects": count, "separateObservations": count,
        "rejectedExecutions": rejected_count, "actuallySignedReceipts": signed_count,
        "policyWriteHistoryRows": len(history), "policyHistoryDigests": "MATCHED", "receipts": receipts})
print(json.dumps({"independentCanonicalMathAndJournalAudit": "PASS", "cases": len(results),
    "evidenceStage": "INTERMEDIATE_TEN" if args.intermediate_ten else "INTERMEDIATE_ELEVEN" if args.intermediate_eleven else "FINAL_TWELVE",
    "actualEffects": sum(row["effects"] for row in results), "rejectedExecutions": sum(row["rejectedExecutions"] for row in results),
    "signedReceiptsVerified": sum(row["actuallySignedReceipts"] for row in results),
    "unsignedAssertions": sum(len(row["receipts"]) - row["actuallySignedReceipts"] for row in results),
    "policyClock": "OBSERVATION_TIME_FOR_EVIDENCE_REPLAY_ONLY",
    "intermediatePolicyHistory": "UNSIGNED_FIXTURE_WRITE_JOURNAL_DIGESTS_AND_CURRENT_SNAPSHOT_MATCHED",
    "unsignedAuthenticity": "NOT_ESTABLISHED", "overallProgramme": "RED", "results": results}, indent=2))
