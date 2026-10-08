#!/usr/bin/env python3
"""Audit the real elapsed-time lease control without inferring an external write.

The frozen native run consumed a lease and returned UNKNOWN after protected
signer validation outlived its expiry. Its fixture saw no requests or effects.
Uses the existing independent decoder/Ed25519 verifier, never a new engine.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("receipt", Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec); spec.loader.exec_module(receipt)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
args = parser.parse_args()
def read(path):
    with path.open("rb") as file: data = file.read(33_554_433)
    assert len(data) <= 33_554_432
    return data
def document(path): return json.loads(read(path), object_pairs_hook=receipt.unique)
def binary(value):
    assert isinstance(value, str) and len(value) <= 1_500_000
    data = base64.b64decode(value, validate=True)
    assert base64.b64encode(data).decode("ascii") == value
    return data
cases = [case for case in args.evidence.iterdir() if case.is_dir()]
assert len(cases) == 1
case = cases[0]
assert "testActualLeaseExpiryDuringProtectedSigningValidationHasZeroEffects" in case.name
summary = document(case / "control-summary.json")
assert summary["runtimeReceiptPolicySeam"] == "HOST_PROTECTED_POLICY_REFERENCE"
assert summary["actualHostClockReachedLeaseExpiry"] is True
assert type(summary["leaseExpiresAt"]) is int and summary["leaseExpiresAt"] >= 0
assert summary["requests"] == summary["effects"] == 0
assert all(not read(case / name) for name in ("requests.jsonl", "effects.jsonl", "observations.jsonl", "polls.jsonl"))
history = [json.loads(line, object_pairs_hook=receipt.unique) for line in read(case / "policy-history.jsonl").splitlines()]
assert len(history) == 1
event = history[0]
assert set(event) == {"sequence", "observedAtMilliseconds", "reference", "sourceSHA256", "publicPolicyBase64"}
assert type(event["sequence"]) is int and event["sequence"] == 1
assert type(event["observedAtMilliseconds"]) is int and event["observedAtMilliseconds"] >= 0
assert event["reference"] == "host-policy"
policy_bytes = binary(event["publicPolicyBase64"])
assert len(policy_bytes) <= 131_072 and hashlib.sha256(policy_bytes).hexdigest() == event["sourceSHA256"]
assert policy_bytes == read(case / "host-policy-current.json")
policy = document(case / "host-policy-current.json"); receipt._trust_policy(policy)
assert policy["issuerID"] == "issuer:production-fixture" and len(policy["keys"]) == 1
key = policy["keys"][0]
assert key["revoked"] is False and key["retiredAt"] is None
assert binary(key["publicKey"]) == read(case / "key-0-public.raw")
assert key["notBefore"] <= summary["leaseExpiresAt"] < key["notAfter"]
records = document(case / "runtime-records.json")
assert len(records) == 1
final = records[0]; rcir = final["rcir"]
assert final["state"] == "unknown" and final["evidence"]["outcomeVerified"] is False
assert rcir["leaseConsumed"] is True and rcir["phase"] == rcir["outcome"] == "unknown"
payload = binary(rcir["receipt"])
assert len(payload) <= receipt.MAX_PAYLOAD
claims = receipt._signed_claims(payload)
assert claims["taskID"] == rcir["taskID"] and claims["leaseID"] == rcir["leaseID"]
canonical = receipt._domain(payload, "RECEIPT")
bound = receipt._domain(canonical["request"], "REQUEST")
assert bound["expiresAt"] == summary["leaseExpiresAt"] and bound["expiresAt"] - bound["issuedAt"] == 30_000
assert claims["lastObservationTime"] >= bound["expiresAt"]
assert canonical["observation"] is None and canonical["observedAt"] is None
arguments = receipt._value(bound["arguments"])
assert set(arguments) == {"message"}
message = json.loads(arguments["message"], object_pairs_hook=receipt.unique)
assert set(message) == {"challenge", "value"} and message["value"] == "production-trust-effect"
signed = rcir["signedReceipt"]
assert binary(signed["payload"]) == payload
with tempfile.TemporaryDirectory(prefix="rcir-lease-clock-public-audit-") as temporary:
    wire = Path(temporary) / "receipt.json"; wire.write_text(json.dumps(signed))
    verified = receipt.verify(wire, case / "key-0-public.raw", expected_outcome="unknown",
        expected_task_id=rcir["taskID"], expected_lease_id=rcir["leaseID"])
    assert verified["signedClaims"] == claims
    receipt.verify_with_policy(wire, case / "host-policy-current.json", mode="live",
        expected_issuer="issuer:production-fixture", expected_task_id=rcir["taskID"],
        expected_lease_id=rcir["leaseID"], expected_outcome="unknown",
        verification_time=claims["lastObservationTime"])
print(json.dumps({"admissionLeaseClock":"RED_CONFIRMED", "actualFixtureRequests":0,
    "actualFixtureEffects":0, "actualFixtureObservations":0, "actualWaitMarker":True,
    "runtimeLeaseClaim":"CONSUMED", "canonicalLeaseExpiry":"MATCHED",
    "runtimeOutcome":"UNKNOWN_WITHOUT_VERIFICATION", "signature":"VALID",
    "currentKeyPolicyAtReplayObservationTime":"ACCEPTED",
    "policyTimeScope":"UNSIGNED_FIXTURE_WRITE_JOURNAL",
    "expiredExternalWrite":"NOT_DEMONSTRATED", "transportFailureCause":"UNPROVEN",
    "overallProgramme":"RED"}, indent=2))
