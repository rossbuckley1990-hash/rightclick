#!/usr/bin/env python3
"""Independent strict Ed25519/claim audit plus actual fixture journal counts.

Reads only public receipts, the separately captured fixture public-key pin and
effect journals. No provisioning secret or private key is read or retained.
"""
import argparse
import base64
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("receipt", Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
parser.add_argument("--expect-green", action="store_true")
args = parser.parse_args()
results = []
for directory in sorted(args.evidence.iterdir()):
    if not directory.is_dir() or not (directory / "runtime-records.json").exists():
        continue
    records = json.loads((directory / "runtime-records.json").read_text())
    final = records[-1]
    evidence = final.get("rcir")
    if "AdmissionBoundary" in directory.name:
        assert evidence is None and final["state"] == "rejected"
        assert not rows(directory / "requests.jsonl") and not rows(directory / "effects.jsonl")
        results.append({"case":directory.name, "state":"rejected", "requests":0, "realEffects":0})
        continue
    decoded = receipt._signed_claims(base64.b64decode(evidence["receipt"], validate=True))
    for field, expected in (("semanticOutcome", evidence["outcome"]), ("taskID", evidence["taskID"]), ("leaseID", evidence["leaseID"])):
        assert decoded[field] == expected
    envelope = evidence.get("signedReceipt")
    valid = False
    fresh = "FreshInvocation" in directory.name
    if envelope:
        with tempfile.TemporaryDirectory(prefix="rcir-public-audit-") as temporary:
            wire = Path(temporary) / "receipt.json"
            wire.write_text(json.dumps(envelope))
            pin = directory / ("fresh-public-key.raw" if fresh else "original-public-key.raw")
            receipt.verify(wire, pin, expected_outcome=evidence["outcome"],
                           expected_task_id=evidence["taskID"], expected_lease_id=evidence["leaseID"])
            valid = True
    requests, effects = rows(directory / "requests.jsonl"), rows(directory / "effects.jsonl")
    unary = "UnaryHTTP" in directory.name
    if unary:
        effects = rows(directory / "unary-effects.jsonl")
        assert not requests and len(effects) == 1 and effects[0]["taskID"] == evidence["taskID"]
    else:
        assert len(requests) == len(effects) == (2 if fresh else 1)
        assert {row["challenge"] for row in effects} == {row["challenge"] for row in requests}
    control = "UnchangedProvisioned" in directory.name or fresh
    if fresh:
        previous = [record for record in records if record["executionId"] != final["executionId"]][-1]
        assert previous["rcir"].get("signedReceipt") is None
        assert previous["rcir"]["taskID"] != evidence["taskID"]
    if args.expect_green:
        assert valid if control else not envelope
        assert evidence.get("receipt")
    results.append({"case":directory.name, "state":final["state"], "outcome":evidence["outcome"],
        "requests":len(effects) if unary else len(requests), "realEffects":len(effects), "signatureMatchesSeparatePin":valid,
        "pin":"fresh-key" if fresh else "original-key", "provisionedPinShouldRemainCurrent":control,
        "unsignedReceiptPresent":bool(evidence.get("receipt"))})
assert len(results) == (8 if args.expect_green else 5)
print(json.dumps({"auditor":"strict Python canonical decoder plus independently pinned Ed25519",
    "externalTruth":"fixture journals, separately from signature", "results":results}, indent=2))
