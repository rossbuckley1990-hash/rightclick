#!/usr/bin/env python3
"""Engineering proof of real local DNS-SD acquisition and Core7 stream use.

Fixture provisioning and external receipt/oracle checks run outside the agent.
The runtime client uses only the existing seven canonical MCP operations.
Requires macOS dns-sd and separate provisioned grpc/cryptography interpreters.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--grpc-python", required=True)
parser.add_argument("--regression-unary", action="store_true", help="Exercise the prior supported unary path on either version")
args = parser.parse_args()
binary = args.binary.resolve(); output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False, mode=0o700)
root = Path(__file__).resolve().parent.parent
fixture = root / "scripts/grpc-stream-pressure-provider.py"
children = []; files = []; request_id = 0; exchanges = []
expected_tools = {"context_runtime", "context_providers", "context_inspect", "context_actions",
                  "context_explain", "context_run", "context_run_status"}

def launch(command, label, **options):
    error = (output / (label + ".stderr")).open("wb"); files.append(error)
    process = subprocess.Popen(command, stderr=error, **options); children.append(process)
    return process

def bounded_wait(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    raise TimeoutError("required bounded native evidence was not published")

def port(role):
    path = output / (role + "-port")
    return bounded_wait(lambda: int(path.read_text()) if path.exists() else None)

def rows(name):
    path = output / name
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_bytes().splitlines(keepends=True) if line.endswith(b"\n")]

def request(method, parameters=None):
    global request_id
    request_id += 1
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if parameters is not None:
        message["params"] = parameters
    client.stdin.write(json.dumps(message) + "\n"); client.stdin.flush()
    selector = selectors.DefaultSelector(); selector.register(client.stdout, selectors.EVENT_READ)
    try:
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if selector.select(max(0, deadline - time.monotonic())):
                line = client.stdout.readline()
                if not line:
                    raise RuntimeError("native MCP process ended before its reply")
                reply = json.loads(line)
                if reply.get("id") == request_id:
                    assert "error" not in reply, "canonical operation failed"
                    return reply["result"]
        raise TimeoutError("canonical operation reply deadline")
    finally:
        selector.close()

def call(name, arguments):
    assert name in expected_tools
    result = request("tools/call", {"name": name, "arguments": arguments})
    assert not result.get("isError"), "canonical operation returned a tool error"
    value = json.loads(result["content"][0]["text"])
    # Only retain the owned fixture capability, not unrelated machine inventory.
    retained = value
    if name == "context_actions":
        retained = {"actions": [row for row in value["actions"] if (row.get("provider") or {}).get("name") == service_name]}
    elif name == "context_providers":
        retained = {"providerCount": len(value) if isinstance(value, list) else len(value["providers"])}
    exchanges.append({"operation": name, "response": retained})
    return value

try:
    provider = launch([args.grpc_python, str(fixture), "--directory", str(output)], "provider", stdout=subprocess.DEVNULL)
    observer = launch([args.grpc_python, str(fixture), "--directory", str(output), "--observer"], "observer", stdout=subprocess.DEVNULL)
    provider_port = port("provider"); observer_port = port("observer")
    service_name = "RIGHTCLICK owned stream " + uuid.uuid4().hex[:12]
    hostname = "rightclick-stream-" + uuid.uuid4().hex[:12] + ".local."
    advertisement_log = (output / "advertisement.log").open("wb"); files.append(advertisement_log)
    advertisement = launch(["/usr/bin/dns-sd", "-lo", "-P", service_name, "_rightclick._tcp", "local.",
                            str(provider_port), hostname, "127.0.0.1", "kind=grpc", "scheme=grpc"],
                           "advertisement", stdout=advertisement_log)
    private = Ed25519PrivateKey.generate()
    key_path = output / "signer.raw"
    key_path.write_bytes(private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))
    key_path.chmod(0o600)
    public_path = output / "trusted-public-key.raw"
    public_path.write_bytes(private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
    config_path = output / "host-config.json"
    config_path.write_text(json.dumps({"version": 1, "revision": "native-stream-proof-1", "deniedCapabilities": [],
                                     "signingKeyFile": str(key_path)})); config_path.chmod(0o600)
    child_environment = dict(os.environ, RIGHTCLICK_RCIR_CONFIG=str(config_path))
    if args.regression_unary:
        # Compare the existing native behavior without imposing a newly added
        # RCIR configuration that the prior release does not implement.
        child_environment.pop("RIGHTCLICK_RCIR_CONFIG", None)
    # CF's child-specific home override avoids acquiring the operator's provider
    # configuration. It changes no user home, connection, or installed runtime.
    child_environment["CFFIXED_USER_HOME"] = str(output / "host-home")
    (output / "host-home").mkdir(mode=0o700)
    for name in ["RIGHTCLICK_A2A_PROVIDERS", "RIGHTCLICK_CAPABILITY_ARTIFACTS", "RIGHTCLICK_ARD_REGISTRIES"]:
        child_environment.pop(name, None)
    client = launch([str(binary), "mcp"], "mcp", env=child_environment,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    initialized = request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "native-core7-stream-engineering-control", "version": "1"}})
    tools = request("tools/list")
    assert {tool["name"] for tool in tools["tools"]} == expected_tools and len(tools["tools"]) == 7
    (output / "tools.json").write_text(json.dumps(tools, indent=2))
    runtime = call("context_runtime", {})
    assert runtime["pid"] == client.pid and runtime["executableSHA256"] == hashlib.sha256(binary.read_bytes()).hexdigest()
    expected_version = subprocess.check_output([str(binary), "version"], text=True).strip()
    assert runtime["version"] == initialized["serverInfo"]["version"] == expected_version
    call("context_providers", {}); call("context_inspect", {"item": "Native stream Core7 pressure"})
    def discovered():
        actions = call("context_actions", {"item": "Native stream Core7 pressure"})["actions"]
        method = "Echo" if args.regression_unary else "Read"
        return next((row for row in actions if row["title"] == "gRPC rightclick.pressure.Streams/" + method
                     and (row.get("provider") or {}).get("name") == service_name), None)
    capability = bounded_wait(discovered, seconds=20)
    (output / "capability.json").write_text(json.dumps(capability, indent=2))
    assert capability["invocation"] != "unsupported"
    explanation = call("context_explain", {"item": "Native stream Core7 pressure", "actionId": capability["id"]})
    assert hostname.rstrip(".") in explanation["metadata"]["endpoint"]
    if args.regression_unary:
        challenge = "parity-" + uuid.uuid4().hex
        invocation = {"item": "Native stream Core7 pressure", "actionId": capability["id"], "arguments": {"challenge": challenge}}
        gated = call("context_run", invocation)
        assert gated["state"] == "awaiting_user" and not rows("stream-events.jsonl")
        result = call("context_run", {**invocation, "confirmed": True})
        assert result["state"] in ("accepted", "succeeded"), result["state"]
        assert json.loads(result["output"]) == {"value": challenge}
        retained = call("context_run_status", {"executionId": result["executionId"]})
        assert retained["state"] == result["state"] and retained["output"] == result["output"]
        assert len(rows("stream-events.jsonl")) == 1 and rows("stream-events.jsonl")[0]["challenge"] == challenge
        assert (output / ("echo-" + challenge + ".txt")).read_text() == challenge
        (output / "runtime-records.json").write_text(json.dumps([result, retained], indent=2))
        (output / "exchanges.json").write_text(json.dumps(exchanges, indent=2))
        summary = {"result": "PASS", "runtime": runtime, "test": "previous supported native unary acquisition and invocation",
            "canonicalOperationsUsed": sorted({row["operation"] for row in exchanges}), "toolCount": 7,
            "discovery": "Actual local-only DNS-SD advertisement, Cocoa acquisition and official gRPC reflection",
            "nativeCallCount": 1, "exactExternalFileAndReturnedValue": True,
            "state": result["state"], "outputRetained": True,
            "excluded": ["new stream support", "fresh restricted AI", "issuer authentication/downscoping", "all eleven", "shipping"]}
        (output / "results.json").write_text(json.dumps(summary, indent=2)); print(json.dumps(summary))
        raise SystemExit(0)
    origin = "http://127.0.0.1:" + str(observer_port)
    observation_schema = {"type": "object", "additionalProperties": False,
        "required": ["challenge", "digest", "phase", "count", "invocation"], "properties": {
            "challenge": {"type": "string"}, "digest": {"type": "string"}, "phase": {"type": "string", "enum": ["completed"]},
            "count": {"type": "integer"}, "invocation": {"type": "string"}}}
    config = {"version": 1, "revision": "native-stream-proof-1", "deniedCapabilities": [],
        "signingKeyFile": str(key_path), "observers": {capability["id"]: {
        "urlTemplate": origin + "/observations/{challenge}", "trustedOrigin": origin, "jsonObservation": {
            "schemaJSON": json.dumps(observation_schema), "fields": {
                "challenge": {"path": ["challenge"], "argument": "challenge"},
                "digest": {"path": ["digest"], "argument": "expected_digest"}}, "invocationBindingPath": ["invocation"]}}}}
    config_path.write_text(json.dumps(config)); config_path.chmod(0o600)
    challenge = "public-core7-" + uuid.uuid4().hex
    digest = hashlib.sha256("".join(str(i) + ":" + challenge + ":" + str(i) + "\n" for i in range(1, 4)).encode()).hexdigest()
    invocation = {"item": "Native stream Core7 pressure", "actionId": capability["id"],
        "arguments": {"challenge": challenge, "count": "3", "mode": "burst", "expected_digest": digest}}
    gated = call("context_run", invocation)
    assert gated["state"] == "awaiting_user" and not rows("stream-events.jsonl")
    initial = call("context_run", {**invocation, "confirmed": True})
    assert initial["state"] == "started"
    def terminal():
        value = call("context_run_status", {"executionId": initial["executionId"]})
        return value if value["state"] not in ("started", "awaiting_user") else None
    final = bounded_wait(terminal, seconds=8)
    assert final["state"] == "succeeded" and final["evidence"]["outcomeVerified"]
    assert final["rcir"]["outcome"] == "succeeded" and len(final["rcir"]["taskEvents"]) == 5
    starts = [row for row in rows("stream-events.jsonl") if row["kind"] == "started"]
    assert len(starts) == 1 and starts[0]["invocation"] == final["rcir"]["taskID"]
    assert len(rows("observations.jsonl")) == 1 and rows("observations.jsonl")[0]["markerMatched"]
    (output / "runtime-records.json").write_text(json.dumps([initial, final], indent=2))
    (output / "tools.json").write_text(json.dumps(tools, indent=2))
    (output / "exchanges.json").write_text(json.dumps(exchanges, indent=2))
    (output / "receipt-envelope.json").write_text(json.dumps(final["rcir"]["signedReceipt"]))
    # This is a separate, caller-pinned verifier, never the provider's key.
    from importlib.util import module_from_spec, spec_from_file_location
    spec = spec_from_file_location("existing_receipt_verifier", root / "scripts/verify-rcir-receipt.py")
    verifier = module_from_spec(spec); spec.loader.exec_module(verifier)
    verified = verifier.verify(output / "receipt-envelope.json", public_path,
        expected_outcome="succeeded", expected_task_id=final["rcir"]["taskID"], expected_lease_id=final["rcir"]["leaseID"])
    (output / "independent-signature.json").write_text(json.dumps(verified, indent=2))
    summary = {"result": "PASS", "runtime": runtime, "nativeServiceAcquired": True,
        "discovery": "Actual local-only DNS-SD advertisement, Cocoa acquisition and official gRPC reflection",
        "canonicalOperationsUsed": sorted({row["operation"] for row in exchanges}),
        "toolCount": 7, "nativeCallCount": len(starts), "nativeElements": 3, "independentReadbackCount": 1,
        "outOfBandPinnedSignature": "PASS", "phase": final["rcir"]["phase"], "outcome": final["rcir"]["outcome"],
        "excluded": ["fresh restricted AI", "issuer authentication/downscoping", "Windows/Linux native gRPC", "all eleven", "shipping"]}
    (output / "results.json").write_text(json.dumps(summary, indent=2)); print(json.dumps(summary))
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=3)
    for file in files:
        file.close()
    # Private signing authority and its references are never retained as proof.
    for filename in ["signer.raw", "host-config.json"]:
        (output / filename).unlink(missing_ok=True)
    if exchanges and not (output / "exchanges.json").exists():
        (output / "exchanges.json").write_text(json.dumps(exchanges, indent=2))
