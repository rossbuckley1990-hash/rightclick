#!/usr/bin/env python3
"""Independent strict Ed25519/claim audit plus actual fixture journal counts.

Reads only public receipts, the separately captured fixture public-key pin and
effect journals. No provisioning secret or private key is read or retained.
"""
import argparse
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
    evidence = final["rcir"]
    envelope = evidence.get("signedReceipt")
    valid = False
    if envelope:
        with tempfile.TemporaryDirectory(prefix="rcir-public-audit-") as temporary:
            wire = Path(temporary) / "receipt.json"
            wire.write_text(json.dumps(envelope))
            receipt.verify(wire, directory / "original-public-key.raw", expected_outcome=evidence["outcome"],
                           expected_task_id=evidence["taskID"], expected_lease_id=evidence["leaseID"])
            valid = True
    requests, effects = rows(directory / "requests.jsonl"), rows(directory / "effects.jsonl")
    assert len(requests) == len(effects) == 1
    assert effects[0]["challenge"] == requests[0]["challenge"]
    control = "UnchangedProvisioned" in directory.name
    if args.expect_green:
        assert valid if control else not envelope
        assert evidence.get("receipt")
    results.append({"case":directory.name, "state":final["state"], "outcome":evidence["outcome"],
        "requests":len(requests), "realEffects":len(effects), "signedWithOriginalKey":valid,
        "originalKeyShouldRemainCurrent":control, "unsignedReceiptPresent":bool(evidence.get("receipt"))})
assert len(results) == 5
print(json.dumps({"auditor":"strict Python canonical decoder plus independently pinned Ed25519",
    "externalTruth":"fixture journals, separately from signature", "results":results}, indent=2))
