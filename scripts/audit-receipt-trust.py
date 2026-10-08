#!/usr/bin/env python3
"""Audit real same-host key-rotation receipts with an independent decoder/pin.

Reads only public evidence; issuer policy is explicitly an external requested
trust rule, not an identity magically established by receipt signature bytes.
"""
import argparse
import base64
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("receipt",Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec); spec.loader.exec_module(receipt)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence",type=Path)
args = parser.parse_args()
records = json.loads((args.evidence / "runtime-records.json").read_text())
def rows(name): return [json.loads(line) for line in (args.evidence / name).read_text().splitlines()]
requests,effects,observations = rows("requests.jsonl"),rows("effects.jsonl"),rows("observations.jsonl")
assert len(requests) == len(effects) == len(observations) == 2
assert {r["challenge"] for r in requests} == {r["challenge"] for r in effects} == {r["challenge"] for r in observations}
identifiers = list(dict.fromkeys(record["executionId"] for record in records))
assert len(identifiers) == 2
results = []
for index,identifier in enumerate(identifiers):
    final = [record for record in records if record["executionId"] == identifier][-1]
    evidence = final["rcir"]
    assert final["state"] == evidence["outcome"] == "succeeded"
    assert observations[index]["invocation"] == evidence["taskID"]
    with tempfile.TemporaryDirectory(prefix="rcir-public-trust-audit-") as directory:
        wire = Path(directory) / "receipt.json"; wire.write_text(json.dumps(evidence["signedReceipt"]))
        verdict = receipt.verify(wire,args.evidence / f"key-{index}-public.raw",expected_outcome="succeeded",
            expected_task_id=evidence["taskID"],expected_lease_id=evidence["leaseID"])
    results.append({"slot":index,"signature":verdict["signature"],"providerGeneration":verdict["signedClaims"]["providerGeneration"],
        "taskIDMatchedSeparateObservation":True,"requests":1,"realEffects":1,"separateObservations":1})
assert results[0]["providerGeneration"] == results[1]["providerGeneration"]
assert (args.evidence / "key-0-public.raw").read_bytes() != (args.evidence / "key-1-public.raw").read_bytes()
green = (args.evidence / "trust-results.json").exists()
matrix = json.loads((args.evidence / ("trust-results.json" if green else "legacy-results.json")).read_text())
independent = []
if green:
    policies = json.loads((args.evidence / "requested-policy-matrix.json").read_text())
    for case in policies:
        slot = 0 if case["receiptKey"] == "key-0" else 1
        record = [record for record in records if record["executionId"] == identifiers[slot]][-1]
        envelope = dict(record["rcir"]["signedReceipt"])
        if case["case"] == "live-tampered-signature":
            signature = bytearray(base64.b64decode(envelope["signature"])); signature[0] ^= 1
            envelope["signature"] = base64.b64encode(signature).decode("ascii")
        with tempfile.TemporaryDirectory(prefix="rcir-public-trust-policy-") as directory:
            wire = Path(directory) / "receipt.json"; wire.write_text(json.dumps(envelope))
            try:
                receipt.verify_with_policy(wire,case["trustPolicy"],mode=case["mode"],expected_issuer=case["expectedIssuer"],
                    expected_task_id=case["expectedTaskID"],expected_lease_id=case["expectedLeaseID"],
                    expected_outcome=case["expectedOutcome"],verification_time=case["verificationTime"])
                accepted = True
            except Exception:
                accepted = False
        assert accepted == case["expectedAccepted"], case["case"]
        independent.append({"case":case["case"],"accepted":accepted,"satisfied":True})
    assert all(row["satisfied"] for row in matrix)
print(json.dumps({"signatureAndExternalJournalAudit":"PASS","issuerAuthenticity":"external host policy, not established by v1 bytes",
    "results":results,"independentPolicyMatrix":independent,
    "goalTrustPolicyFailures":[row["case"] for row in matrix if not row["satisfied"]]},indent=2))
