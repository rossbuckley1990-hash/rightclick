#!/usr/bin/env python3
"""Reproducible actual seven-operation boundary proof for MCP + WASM.

The isolated SDK server and official component tools are engineering workbench
infrastructure. This deterministic transcript driver is not the final fresh-AI
eleven-substrate acceptance run. It only sends the seven canonical operations.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import selectors
import shutil
import subprocess
import tempfile
import time
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

parser = argparse.ArgumentParser()
parser.add_argument("binary", type=pathlib.Path)
parser.add_argument("evidence", type=pathlib.Path)
parser.add_argument("--component", type=pathlib.Path, required=True)
parser.add_argument("--runtime", type=pathlib.Path, required=True)
parser.add_argument("--tools", type=pathlib.Path, required=True)
parser.add_argument("--mcp-effects", type=pathlib.Path, default=pathlib.Path("/private/tmp/rightclick-descriptor-mcp-effects"))
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
evidence = args.evidence.resolve(); evidence.mkdir(parents=True, exist_ok=True)
temporary = tempfile.TemporaryDirectory(prefix="rightclick-interface-acceptance-")
lab = pathlib.Path(temporary.name).resolve(); lab.chmod(0o700)
component = lab / "fingerprint.component.wasm"; shutil.copyfile(args.component, component)
unseen = lab / "unseen.component.wasm"
trap = lab / "trap.component.wasm"
subprocess.run([str(args.tools.resolve()), "parse", str(root / "examples/universal-descriptors/trap.component.wat"),
                "-o", str(trap)], check=True)
signer = Ed25519PrivateKey.generate()
key = lab / "signing-key.raw"
key.write_bytes(signer.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))
key.chmod(0o600)
public_key = evidence / "trusted-public-key.raw"
public_key.write_bytes(signer.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
config = lab / "host.json"
configuration = {"version": 1, "revision": "descriptor-proof-1", "deniedCapabilities": [],
                 "signingKeyFile": str(key), "observers": {}}


def configure():
    config.write_text(json.dumps(configuration)); config.chmod(0o600)


configure()
environment = dict(os.environ)
environment.update(RIGHTCLICK_WASM_TOOLS=str(args.tools.resolve()), RIGHTCLICK_WASM_RUNTIME=str(args.runtime.resolve()),
                   RIGHTCLICK_RCIR_CONFIG=str(config), RIGHTCLICK_CAPABILITY_EXPERIENCE="disabled",
                   RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([
                       {"id": "controlled-mcp", "kind": "mcp", "endpointURL": "http://127.0.0.1:19143/mcp"},
                       {"id": "controlled-wasm", "kind": "wasm", "specificationURL": component.as_uri()},
                       {"id": "unseen-wasm", "kind": "wasm", "specificationURL": unseen.as_uri()},
                       {"id": "trap-wasm", "kind": "wasm", "specificationURL": trap.as_uri()}]))
transcript = []
process = subprocess.Popen([str(args.binary.resolve()), "mcp"], env=environment, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=(evidence / "runtime.stderr").open("w"), text=True, bufsize=1)
selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)


def rpc(method, params=None):
    request = {"jsonrpc": "2.0", "id": len(transcript) + 1, "method": method}
    if params is not None:
        request["params"] = params
    process.stdin.write(json.dumps(request) + "\n"); process.stdin.flush()
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        if selector.select(deadline - time.monotonic()):
            raw = process.stdout.readline()
            if not raw:
                raise RuntimeError("runtime exited")
            reply = json.loads(raw)
            if reply.get("id") == request["id"]:
                transcript.append({"request": request, "response": reply})
                assert "error" not in reply, reply
                return reply["result"]
    raise TimeoutError(method)


def call(name, arguments, allow_error=False):
    result = rpc("tools/call", {"name": name, "arguments": arguments})
    if result.get("isError"):
        assert allow_error, result
        return result
    return json.loads(result["content"][0]["text"])


canonical = {"context_runtime", "context_inspect", "context_actions", "context_explain", "context_run", "context_run_status", "context_providers"}
mcp_id = "mcp:controlled-mcp:record_challenge"
wasm_id = "wasm:controlled-wasm:challenge-fingerprint"
new_id = "wasm:unseen-wasm:challenge-fingerprint"
reports = {}
receipt_spec = importlib.util.spec_from_file_location("receipt_verifier", root / "scripts/verify-rcir-receipt.py")
receipt_verifier = importlib.util.module_from_spec(receipt_spec); receipt_spec.loader.exec_module(receipt_verifier)


def verify_receipt(label, result, outcome):
    envelope = evidence / (label + "-receipt.json")
    envelope.write_text(json.dumps(result["rcir"]["signedReceipt"], indent=2))
    verified = receipt_verifier.verify(envelope, public_key, expected_outcome=outcome,
                                       expected_task_id=result["rcir"]["taskID"], expected_lease_id=result["rcir"]["leaseID"])
    reports[label] = verified


def actions():
    return call("context_actions", {"item": "RIGHTCLICK descriptor proof"})["actions"]


try:
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "seven-operation-descriptor-proof", "version": "1"}})
    before = rpc("tools/list")["tools"]
    assert {tool["name"] for tool in before} == canonical
    runtime = call("context_runtime", {})
    call("context_inspect", {"item": "RIGHTCLICK descriptor proof"})
    provider_before = call("context_providers", {})
    discovered = actions(); assert {mcp_id, wasm_id}.issubset({a["id"] for a in discovered})
    assert new_id not in {a["id"] for a in discovered}
    mcp_explain = call("context_explain", {"item": "RIGHTCLICK descriptor proof", "actionId": mcp_id})
    wasm_explain = call("context_explain", {"item": "RIGHTCLICK descriptor proof", "actionId": wasm_id})
    gated = call("context_run", {"item": "proof", "actionId": mcp_id, "arguments": {"challenge": "must-not-dispatch"}})
    assert gated["state"] == "awaiting_user"
    nonce = "proof_" + uuid.uuid4().hex
    accepted = call("context_run", {"item": "proof", "actionId": mcp_id, "confirmed": True, "arguments": {"challenge": nonce}})
    assert accepted["state"] == "accepted" and not accepted["evidence"]["outcomeVerified"]
    verify_receipt("mcp-accepted", accepted, "unverified")
    configuration["observers"] = {mcp_id: {"urlTemplate": "http://127.0.0.1:19143/observe/{challenge}", "expectedArgument": "challenge"}}
    configure()
    verified_nonce = "proof_" + uuid.uuid4().hex
    mcp = call("context_run", {"item": "proof", "actionId": mcp_id, "confirmed": True, "arguments": {"challenge": verified_nonce}})
    assert mcp["state"] == "succeeded" and mcp["evidence"]["outcomeVerified"]
    status = call("context_run_status", {"executionId": mcp["executionId"]}); assert status["rcir"] == mcp["rcir"]
    effect = args.mcp_effects / (hashlib.sha256(verified_nonce.encode()).hexdigest() + ".txt")
    assert effect.read_text() == verified_nonce  # Separate filesystem observer, not the MCP response.
    verify_receipt("mcp-verified", mcp, "succeeded")
    challenge = "RIGHTCLICK:" + uuid.uuid4().hex
    expected = 2166136261
    for byte in challenge.encode():
        expected = ((expected ^ byte) * 16777619) & 0xFFFFFFFF
    wasm = call("context_run", {"item": "proof", "actionId": wasm_id, "confirmed": True,
                                "arguments": {"challenge": challenge}, "expectedOutput": str(expected)})
    assert wasm["state"] == "succeeded" and wasm["output"] == str(expected)
    verify_receipt("wasm-verified", wasm, "succeeded")
    mismatch = call("context_run", {"item": "proof", "actionId": wasm_id, "confirmed": True,
                                    "arguments": {"challenge": challenge}, "expectedOutput": str(expected ^ 1)})
    assert mismatch["state"] == "failed" and not mismatch["evidence"]["outcomeVerified"]
    verify_receipt("wasm-mismatch", mismatch, "failed")
    trapped = call("context_run", {"item": "proof", "actionId": "wasm:trap-wasm:trap", "confirmed": True,
                                   "arguments": {"challenge": challenge}, "expectedOutput": "0"})
    assert trapped["state"] == "unknown" and not trapped["evidence"]["outcomeVerified"]
    verify_receipt("wasm-trap", trapped, "unknown")
    effects_before = args.mcp_effects.joinpath("effects.jsonl").read_text()
    configuration["deniedCapabilities"] = [mcp_id]; configure()
    denied = call("context_run", {"item": "proof", "actionId": mcp_id, "confirmed": True, "arguments": {"challenge": "policy-must-not-dispatch"}})
    assert denied["state"] == "rejected" and args.mcp_effects.joinpath("effects.jsonl").read_text() == effects_before
    configuration["deniedCapabilities"] = []; configure()
    malformed = args.mcp_effects / "malformed-descriptor"; malformed.write_text("1")
    time.sleep(5.2)
    assert mcp_id not in {a["id"] for a in actions()}
    malformed.unlink(); time.sleep(5.2)
    assert mcp_id in {a["id"] for a in actions()}
    offline = component.with_suffix(".offline"); component.rename(offline)
    time.sleep(5.2)
    assert wasm_id not in {a["id"] for a in actions()}
    shutil.copyfile(args.component, unseen)
    time.sleep(5.2)
    introduced = actions(); assert new_id in {a["id"] for a in introduced}
    after = rpc("tools/list")["tools"]; assert {tool["name"] for tool in after} == canonical
    result = {"runtime": runtime, "substrates": ["MCP", "WASM"], "toolCountBefore": len(before), "toolCountAfter": len(after),
              "providerSpecificToolsAdded": 0, "acceptedRemainsUnverified": True, "mcpIndependentFilesystemVerification": str(effect),
              "wasmIndependentAlgorithm": "FNV-1a32 over exact UTF-8 challenge; separate Python calculation",
              "wasmChallenge": challenge, "wasmExpected": expected, "wasmActual": wasm["output"],
              "malformedDescriptorRemoved": True, "offlineComponentRemoved": True, "unseenComponentDiscoveredLive": True,
              "policyDenialNoEffect": True, "receiptReports": reports,
              "wasmTrapFailsClosed": True, "wasmTrapBoundary": "Consumed process invocation failed; generic host conservatively reports unknown, never success.",
              "capabilityEvidence": {"mcp": mcp_explain, "wasm": wasm_explain},
              "boundary": "Real MCP/WASM seven-operation transcript proof. Final fresh-AI eleven-substrate acceptance remains a separate required gate."}
    (evidence / "results.json").write_text(json.dumps(result, indent=2))
    print("PASS: genuine MCP/WASM acquisition, invocation, independent outcomes, signed receipts, policy denial and live graph mutation; seven operations unchanged.")
finally:
    (evidence / "transcript.json").write_text(json.dumps(transcript, indent=2))
    selector.close()
    try:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
    finally:
        args.mcp_effects.joinpath("malformed-descriptor").unlink(missing_ok=True)
        temporary.cleanup()
