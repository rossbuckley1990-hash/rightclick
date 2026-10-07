#!/usr/bin/env python3
"""Audit real effect evidence for the frozen production receipt-admission races.

This checks an unsigned fixture write journal and unsigned runtime assertions;
it does not authenticate their timestamps or fabricate signature verification.
Canonical bytes are decoded by the existing independent receipt verifier.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("receipt", Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
args = parser.parse_args()
allowed = {
    "testConfigurationRefreshRevokesPolicyBeforeFinalAdmissionHasZeroEffects": "revokedDuringFinalAdmissionRefresh",
    "testConsumptionCallbackRevokesPolicyBeforeFinalAdmissionHasZeroEffects": "revokedDuringConsumptionCallback",
}
def read(path):
    with path.open("rb") as file:
        data = file.read(33_554_433)
    assert len(data) <= 33_554_432
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

cases = [case for case in args.evidence.iterdir() if case.is_dir()]
assert len(cases) == 1
case = cases[0]
names = [name for name in allowed if name in case.name]
assert len(names) == 1
name = names[0]
summary = document(case / "control-summary.json")
assert summary["runtimeReceiptPolicySeam"] == "HOST_PROTECTED_POLICY_REFERENCE"
assert summary[allowed[name]] is True
assert summary["requests"] == summary["effects"] == 1
if name.startswith("testConfiguration"):
    assert summary["configurationReadsAfterBoundary"] >= 5
history = rows(case, "policy-history.jsonl")
assert len(history) == 2
policies = []
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
    policy = json.loads(public_bytes, object_pairs_hook=receipt.unique)
    receipt._trust_policy(policy)
    assert policy["issuerID"] == "issuer:production-fixture"
    policies.append(policy)
assert read(case / "host-policy-current.json") == binary(history[-1]["publicPolicyBase64"])
before, after = [policy["keys"][0] for policy in policies]
assert before["revoked"] is False and after["revoked"] is True
assert before["publicKey"] == after["publicKey"]
assert binary(after["publicKey"]) == read(case / "key-0-public.raw")
records = document(case / "runtime-records.json")
finals = {record["executionId"]: record for record in records}
assert len(finals) == 1
final = next(iter(finals.values()))
assert final["state"] == "succeeded" and final["evidence"]["outcomeVerified"] is True
assert records[0]["state"] == "started"
rcir = final["rcir"]
assert rcir["leaseConsumed"] is True and rcir["phase"] == "completed" and rcir["outcome"] == "succeeded"
assert not rcir.get("signedReceipt")
assert "RCIR signed receipt withheld because current provisioned signing authority is unavailable." in final["events"]
payload = binary(rcir["receipt"])
assert len(payload) <= receipt.MAX_PAYLOAD
claims = receipt._signed_claims(payload)
assert claims["taskID"] == rcir["taskID"] and claims["leaseID"] == rcir["leaseID"]
assert claims["startedAt"] <= history[1]["observedAtMilliseconds"] <= claims["lastObservationTime"]
for record in records:
    if record.get("rcir"):
        assert record["rcir"]["taskID"] == rcir["taskID"]
        assert record["rcir"]["leaseID"] == rcir["leaseID"]
journals = [rows(case, file) for file in ("requests.jsonl", "effects.jsonl", "observations.jsonl")]
assert all(len(journal) == 1 for journal in journals)
request, effect, observation = [journal[0] for journal in journals]
assert request["method"] == "message/send"
assert request["invocation"] == observation["invocation"] == rcir["taskID"]
assert request["taskID"] == effect["taskID"]
assert request["challenge"] == effect["challenge"] == observation["challenge"]
assert observation["observed"] == effect["value"]
assert json.loads(effect["value"], object_pairs_hook=receipt.unique) == {
    "challenge": request["challenge"], "value": "production-trust-effect"}
canonical = receipt._domain(payload, "RECEIPT")
bound = receipt._domain(canonical["request"], "REQUEST")
assert receipt._value(bound["arguments"]) == {"message": effect["value"]}
assert receipt._value(canonical["observation"]) == observation["observed"]
print(json.dumps({"admissionRace": "RED_CONFIRMED", "case": name,
    "actualRequests": 1, "actualEffects": 1, "separateReadbacks": 1,
    "callbackRevocationExercised": True, "publicPolicyByteDigests": "MATCHED",
    "currentPolicySnapshot": "SAME_KEY_REVOKED",
    "policyTimeScope": "UNSIGNED_FIXTURE_WRITE_JOURNAL",
    "canonicalTaskAndLease": "MATCHED", "boundArgumentsAndObservationBytes": "MATCHED",
    "signedReceipts": 0, "runtimeAssertion": "UNSIGNED_STRUCTURALLY_VALID",
    "unsignedAuthenticity": "NOT_ESTABLISHED", "overallProgramme": "RED"}, indent=2))
