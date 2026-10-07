#!/usr/bin/env python3
"""Meaningful tampering controls for the actual eleven-case evidence auditor.

Requires fresh native fixture evidence; runs the existing auditor, then mutates
only private temporary copies of those artifacts. No fabricated provider effect
or new signature engine is used.
"""
import argparse
import base64
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
args = parser.parse_args()
auditor = Path(__file__).with_name("audit-production-receipt-trust-green.py")
def audit(root):
    return subprocess.run([sys.executable, str(auditor), str(root)], capture_output=True)
def selected(root, name):
    cases = [case for case in root.iterdir() if case.is_dir() and name in case.name]
    assert len(cases) == 1
    return cases[0]
def rewrite(path, transform):
    value = json.loads(path.read_bytes())
    transform(value)
    path.write_text(json.dumps(value))
def missing_case(root):
    shutil.rmtree(selected(root, "testPreRevokedPolicy"))
def bad_signature(root):
    path = selected(root, "testActiveIssuer") / "runtime-records.json"
    def change(records):
        final = [record for record in records if record.get("rcir", {}).get("signedReceipt")][-1]
        signature = bytearray(base64.b64decode(final["rcir"]["signedReceipt"]["signature"], validate=True))
        signature[0] ^= 1
        final["rcir"]["signedReceipt"]["signature"] = base64.b64encode(signature).decode("ascii")
    rewrite(path, change)
def bad_pin(root):
    path = selected(root, "testActiveIssuer") / "key-0-public.raw"
    pin = bytearray(path.read_bytes()); pin[0] ^= 1; path.write_bytes(pin)
def swapped_effect(root):
    case = selected(root, "testActiveIssuer")
    challenge = "synthetic-journal-swap"
    value = json.dumps({"challenge":challenge, "value":"production-trust-effect"}, separators=(",", ":"), sort_keys=True)
    for name in ("requests.jsonl", "effects.jsonl", "observations.jsonl"):
        path = case / name
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        assert len(rows) == 1
        rows[0]["challenge"] = challenge
        if name == "effects.jsonl": rows[0]["value"] = value
        if name == "observations.jsonl": rows[0]["observed"] = value
        path.write_text(json.dumps(rows[0]) + "\n")
def bad_history_digest(root):
    path = selected(root, "testRevokedPolicyAfter") / "policy-history.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    rows[-1]["sourceSHA256"] = "0" * 64
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
def unexercised_callback(root):
    path = selected(root, "testConsumptionCallback") / "control-summary.json"
    rewrite(path, lambda value: value.update(revokedDuringConsumptionCallback=False))
def unsigned_claims_are_not_a_signature(root):
    path = selected(root, "testRevokedPolicyAfter") / "runtime-records.json"
    # Relabelling observed unsigned truth as a signed envelope lacks actual math.
    def change(records):
        final = records[-1]; rcir = final["rcir"]
        rcir["signedReceipt"] = {"version":1,"algorithm":"Ed25519","payload":rcir["receipt"],
            "publicKey":base64.b64encode((path.parent / "key-0-public.raw").read_bytes()).decode("ascii"),
            "signature":base64.b64encode(bytes(64)).decode("ascii")}
    rewrite(path, change)

baseline = audit(args.evidence)
assert baseline.returncode == 0, "actual evidence baseline must pass"
results = []
for name, mutation in [
    ("missing_required_control", missing_case),
    ("invalid_real_receipt_signature", bad_signature),
    ("wrong_out_of_band_pin", bad_pin),
    ("mutually_matching_journals_swap_bound_effect", swapped_effect),
    ("altered_public_policy_history_digest", bad_history_digest),
    ("unexercised_revocation_callback", unexercised_callback),
    ("unsigned_truth_relabelled_as_signature", unsigned_claims_are_not_a_signature),
]:
    with tempfile.TemporaryDirectory(prefix="rcir-evidence-audit-negative-") as temporary:
        root = Path(temporary) / "evidence"
        shutil.copytree(args.evidence, root)
        mutation(root)
        result = audit(root)
        assert result.returncode != 0, name + " was improperly accepted"
        results.append({"control":name, "tamperedEvidenceRejected":True})
print(json.dumps({"actualBaseline":"PASS", "tamperingControls":len(results),
    "results":results, "scope":"ARTIFACT_AUDITOR_ONLY;DOES_NOT_AUTHENTICATE_UNSIGNED_JOURNALS"}, indent=2))
