#!/usr/bin/env python3
"""Frozen engineering pressure test; only RIGHTCLICK's seven public operations.

This deterministic workbench is not the fresh-AI eleven-world acceptance run.
An actual no-import component must be absent, introduced, acquired, typed,
invoked and withdrawn. Expected results are computed independently in Python.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("binary", type=Path)
parser.add_argument("component", type=Path)
parser.add_argument("evidence", type=Path)
parser.add_argument("--tools", type=Path, required=True)
parser.add_argument("--runtime", type=Path, required=True)
parser.add_argument("--source-sha", required=True)
args = parser.parse_args()
evidence = args.evidence.resolve()
evidence.mkdir(parents=True, exist_ok=True)
lab = Path(tempfile.mkdtemp(prefix="rightclick-wit-typed-", dir="/private/tmp"))
lab.chmod(0o700)
component = lab / "introduced.component.wasm"
key = lab / "signing-key.raw"
key.write_bytes(os.urandom(32))  # Disposable Ed25519 seed, never retained.
key.chmod(0o600)
config = lab / "host.json"
configuration = {"version": 1, "revision": "typed-wit-proof-1", "deniedCapabilities": [],
                 "signingKeyFile": str(key), "observers": {}}


def configure():
    config.write_text(json.dumps(configuration))
    config.chmod(0o600)


configure()
environment = dict(os.environ)
environment.update(RIGHTCLICK_WASM_TOOLS=str(args.tools.resolve()),
                   RIGHTCLICK_WASM_RUNTIME=str(args.runtime.resolve()),
                   RIGHTCLICK_RCIR_CONFIG=str(config),
                   RIGHTCLICK_CAPABILITY_EXPERIENCE="disabled",
                   RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([
                       {"id": "typed-component", "kind": "wasm", "specificationURL": component.as_uri()}]))
environment.pop("RIGHTCLICK_INVOCATION_JOURNAL", None)
transcript = []
process = subprocess.Popen([str(args.binary.resolve()), "mcp"], env=environment,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=(evidence / "runtime.stderr").open("w"), text=True, bufsize=1)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
canonical = {"context_runtime", "context_providers", "context_inspect", "context_actions",
             "context_explain", "context_run", "context_run_status"}
prefix = "wasm:typed-component:proof:typed/api."
record_id, list_id, unit_id = [prefix + name for name in ["challenge-record", "echo-octets", "finish"]]
report = {"sourceSHA": args.source_sha, "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
          "componentSHA256": hashlib.sha256(args.component.read_bytes()).hexdigest(),
          "toolsSHA256": hashlib.sha256(args.tools.read_bytes()).hexdigest(),
          "runtimeSHA256": hashlib.sha256(args.runtime.read_bytes()).hexdigest(),
          "expectedActions": [record_id, list_id, unit_id],
          "boundary": "Actual typed component/public seven-operation engineering proof; no fresh-AI or portable-release claim."}


def rpc(method, params=None):
    request = {"jsonrpc": "2.0", "id": len(transcript) + 1, "method": method}
    if params is not None:
        request["params"] = params
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        if selector.select(deadline - time.monotonic()):
            raw = process.stdout.readline()
            if not raw:
                raise RuntimeError("runtime exited")
            reply = json.loads(raw)
            if reply.get("id") == request["id"]:
                transcript.append({"request": request, "response": reply})
                if "error" in reply:
                    raise AssertionError(reply)
                return reply["result"]
    raise TimeoutError(method)


def call(name, arguments, allow_error=False):
    result = rpc("tools/call", {"name": name, "arguments": arguments})
    if result.get("isError"):
        if not allow_error:
            raise AssertionError(result)
        return result
    return json.loads(result["content"][0]["text"])


def actions():
    return call("context_actions", {"item": "RIGHTCLICK typed component proof"})["actions"]


def tagged(value):
    if isinstance(value, bool):
        return ["boolean", value]
    if isinstance(value, int):
        return ["integer", str(value)]
    if isinstance(value, str):
        return ["string", value]
    if isinstance(value, list):
        return ["array", [tagged(element) for element in value]]
    if isinstance(value, dict):
        return ["object", [[key, tagged(value[key])] for key in sorted(value)]]
    raise ValueError("unsupported fixture type")


def wire(value):
    return json.dumps(tagged(value), separators=(",", ":"), ensure_ascii=False)


def run(action, arguments, expected=None, allow_error=False):
    request = {"item": "RIGHTCLICK typed component proof", "actionId": action,
               "confirmed": True, "arguments": arguments}
    if expected is not None:
        request["expectedOutput"] = expected
    return call("context_run", request, allow_error)


try:
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                       "clientInfo": {"name": "typed-wit-seven-operation-proof", "version": "1"}})
    before = rpc("tools/list")["tools"]
    assert {tool["name"] for tool in before} == canonical
    report["toolCountBefore"] = len(before)
    report["runtime"] = call("context_runtime", {})
    assert report["runtime"]["executableSHA256"] == report["binarySHA256"]
    call("context_providers", {})
    call("context_inspect", {"item": "RIGHTCLICK typed component proof"})
    absent = actions()
    assert not any(action["id"].startswith("wasm:typed-component:") for action in absent)
    report["absentBeforeIntroduction"] = True
    shutil.copyfile(args.component, component)
    time.sleep(5.3)
    introduced = actions()
    report["actualTypedActions"] = [action["id"] for action in introduced if action["id"].startswith("wasm:typed-component:")]
    assert {record_id, list_id, unit_id}.issubset(set(report["actualTypedActions"])), "Valid typed component was not acquired"
    explanation = call("context_explain", {"item": "RIGHTCLICK typed component proof", "actionId": record_id})
    report["recordContract"] = explanation
    assert explanation["metadata"]["coreArgumentEncoding"] == "taggedNonStrings"
    challenge = 'RIGHTCLICK:' + uuid.uuid4().hex + '\n"\\☃\x00'
    request = {"enabled": True, "offset": -7, "challenge": challenge}
    fingerprint = 2166136261
    for byte in challenge.encode("utf-8"):
        fingerprint = ((fingerprint ^ byte) * 16777619) & 0xFFFFFFFF
    expected = {"enabled": True, "fingerprint": (fingerprint - 7) & 0xFFFFFFFF}
    expected_text = json.dumps(expected, separators=(",", ":"), sort_keys=True)
    accepted = run(record_id, {"request": wire(request)})
    assert accepted["state"] == "accepted" and not accepted["evidence"]["outcomeVerified"]
    record = run(record_id, {"request": wire(request)}, expected_text)
    assert record["state"] == "succeeded" and json.loads(record["output"]) == expected
    status = call("context_run_status", {"executionId": record["executionId"]})
    assert status["rcir"] == record["rcir"]
    report["independentRecordExpected"] = expected
    report["recordResult"] = record
    report["recordAccepted"] = accepted
    mismatch = run(record_id, {"request": wire(request)}, json.dumps({"enabled": True, "fingerprint": expected["fingerprint"] ^ 1}, separators=(",", ":"), sort_keys=True))
    assert mismatch["state"] == "failed" and not mismatch["evidence"]["outcomeVerified"]
    report["mismatchResult"] = mismatch
    octets = [0, 1, 127, 128, 255]
    list_result = run(list_id, {"octets": wire(octets)}, json.dumps(octets, separators=(",", ":")))
    assert list_result["state"] == "succeeded" and json.loads(list_result["output"]) == octets
    report["listResult"] = list_result
    unit = run(unit_id, {})
    assert unit["state"] == "accepted" and unit.get("output") is None
    assert unit["rcir"]["phase"] == "completed" and unit["rcir"]["outcome"] == "unverified"
    report["unitResult"] = unit
    for invalid in [{**request, "enabled": 1}, {**request, "offset": 2147483648}, {**request, "offset": -2147483649},
                    {**request, "unexpected": "field"}, {"enabled": True, "offset": -7}]:
        negative = run(record_id, {"request": wire(invalid)}, allow_error=True)
        assert negative.get("isError") or negative.get("state") == "rejected"
    negative = run(list_id, {"octets": wire([256])}, allow_error=True)
    assert negative.get("isError") or negative.get("state") == "rejected"
    report["invalidTypedInputsRejected"] = True
    configuration["deniedCapabilities"] = [record_id]
    configure()
    denied = run(record_id, {"request": wire(request)})
    assert denied["state"] == "rejected"
    report["deniedResult"] = denied
    component.unlink()
    time.sleep(5.3)
    assert not any(action["id"].startswith("wasm:typed-component:") for action in actions())
    report["withdrawnAfterRemoval"] = True
    after = rpc("tools/list")["tools"]
    assert {tool["name"] for tool in after} == canonical
    report["toolCountAfter"] = len(after)
    report["result"] = "GREEN"
    print("GREEN: actual typed WIT record/list/unit through seven operations; external expected calculation and withdrawal.")
except Exception as error:
    report["result"] = "RED"
    report["failure"] = str(error)
    print("RED:", error)
    raise
finally:
    (evidence / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    (evidence / "transcript.json").write_text(json.dumps(transcript, indent=2, ensure_ascii=False))
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    key.unlink(missing_ok=True)
    shutil.rmtree(lab)
