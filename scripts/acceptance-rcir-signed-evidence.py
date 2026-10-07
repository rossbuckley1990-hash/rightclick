#!/usr/bin/env python3
"""Check signed outcome claims against separately captured real provider logs.

Consumes the existing live seven-operation OpenAPI proof and native lost-reply
control. This is disclosed engineering acceptance, not a restricted AI agent.
"""
import argparse
import base64
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("receipt_verifier", Path(__file__).with_name("verify-rcir-receipt.py"))
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)
TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}


def read(path):
    with path.open("rb") as file: data = file.read(4_194_305)
    if len(data) > 4_194_304: raise ValueError("evidence size limit")
    return json.loads(data, object_pairs_hook=verifier.unique)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    transcript = read(args.public / "transcript.json")
    listings = [pair["response"]["result"]["tools"] for pair in transcript if pair["request"]["method"] == "tools/list"]
    assert listings and all(len(tools) == 7 and {tool["name"] for tool in tools} == TOOLS for tools in listings)
    calls = [pair for pair in transcript if pair["request"]["method"] == "tools/call"]
    assert all(pair["request"]["params"]["name"] in TOOLS for pair in calls)
    records = [json.loads(pair["response"]["result"]["content"][0]["text"]) for pair in calls
               if pair["request"]["params"]["name"] == "context_run"]
    effects = [json.loads(line) for line in (args.public / "effects.jsonl").read_text().splitlines()]
    pinned = args.public / "trusted-public-key.raw"
    results = []
    for outcome in ("succeeded", "failed", "unverified"):
        record = next(record for record in records if record.get("rcir", {}).get("outcome") == outcome)
        task = record["rcir"]["taskID"]
        assert len([effect for effect in effects if effect["correlationID"] == task]) == 1
        receipt = args.output / (outcome + "-receipt.json")
        receipt.write_text(json.dumps(record["rcir"]["signedReceipt"], sort_keys=True) + "\n")
        verified = verifier.verify(receipt, pinned, expected_outcome=outcome, expected_task_id=task,
                                   expected_lease_id=record["rcir"]["leaseID"])
        assert verified["signedClaims"]["scopeCount"] == 1
        results.append(verified)
        if outcome != "succeeded":
            try: verifier.verify(receipt, pinned, expected_outcome="succeeded")
            except verifier.ReceiptClaimMismatch: pass
            else: raise AssertionError("A signature promoted a non-success claim")
    unknown = args.native / "lost-response-receipt.json"
    unknown_key = args.native / "lost-response-public-key.raw"
    effect_log = next(path for path in args.native.glob("*.json") if "testLostResponseRetainsSignedUnknownAndDoesNotRetry" in path.name)
    lost = read(effect_log)["effects"]
    assert len(lost) == 1, "Lost reply caused another mutation"
    results.append(verifier.verify(unknown, unknown_key, expected_outcome="unknown", expected_task_id=lost[0]["taskID"]))
    try: verifier.verify(unknown, unknown_key, expected_outcome="succeeded")
    except verifier.ReceiptClaimMismatch: pass
    else: raise AssertionError("A signed unknown was promoted to success")

    good = args.output / "succeeded-receipt.json"
    tampered = read(good); payload = bytearray(base64.b64decode(tampered["payload"])); payload[-1] ^= 1
    tampered["payload"] = base64.b64encode(payload).decode()
    changed = args.output / "tampered-negative.json"; changed.write_text(json.dumps(tampered) + "\n")
    try: verifier.verify(changed, pinned)
    except Exception: pass
    else: raise AssertionError("Tampered receipt was accepted")
    wrong_key = args.output / "wrong-key-negative.raw"; wrong_key.write_bytes(b"z" * 32)
    try: verifier.verify(good, wrong_key)
    except ValueError: pass
    else: raise AssertionError("Untrusted key was accepted")
    report = {"result": "PASS", "proofKind": "ENGINEERING_ACCEPTANCE_NOT_RESTRICTED_AI_AGENT",
              "operations": sorted(TOOLS), "toolSchemaSHA256": read(args.public / "results.json")["toolSchemaSHA256"],
              "claims": results, "nonSuccessPromotionRejected": ["failed", "unknown", "unverified"],
              "tamperedReceiptRejected": True, "untrustedKeyRejected": True,
              "authorityBoundary": "Exact-resource in-process leases, not issuer-downscoped provider credentials",
              "signerBoundary": "Separately pinned disposable fixture keys, not production signer trust",
              "verificationBoundary": "Host-selected read-back independent of invocation response; same service trust source"}
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"result": "PASS", "signedOutcomes": [result["signedClaims"]["semanticOutcome"] for result in results]}))


if __name__ == "__main__": main()
