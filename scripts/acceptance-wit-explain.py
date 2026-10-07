#!/usr/bin/env python3
"""Seven-operation explain pressure; inputs come from the acquired WIT graph.

This deterministic engineering control is not fresh-AI acceptance. It requires
readable acquired nested fields and exact WIT native widths, then constructs the
existing Core tagged arguments without reading source, WAT, or WIT fixture JSON.
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
args.evidence.mkdir(parents=True, exist_ok=True)
lab = Path(tempfile.mkdtemp(prefix="rightclick-wit-explain-", dir="/private/tmp"))
lab.chmod(0o700)
component = lab / "introduced.component.wasm"
key = lab / "signing-key.raw"
key.write_bytes(os.urandom(32))
key.chmod(0o600)
config = lab / "host.json"
config.write_text(json.dumps({"version": 1, "revision": "wit-explain-pressure", "deniedCapabilities": [],
                              "signingKeyFile": str(key), "observers": {}}))
config.chmod(0o600)
environment = dict(os.environ)
environment.update(RIGHTCLICK_WASM_TOOLS=str(args.tools.resolve()),
                   RIGHTCLICK_WASM_RUNTIME=str(args.runtime.resolve()),
                   RIGHTCLICK_RCIR_CONFIG=str(config), RIGHTCLICK_CAPABILITY_EXPERIENCE="disabled",
                   RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([
                       {"id": "explain-component", "kind": "wasm", "specificationURL": component.as_uri()}]))
environment.pop("RIGHTCLICK_INVOCATION_JOURNAL", None)
process = subprocess.Popen([str(args.binary.resolve()), "mcp"], env=environment, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=(args.evidence / "runtime.stderr").open("w"),
                           text=True, bufsize=1)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
transcript = []
report = {"sourceSHA": args.source_sha, "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
          "componentSHA256": hashlib.sha256(args.component.read_bytes()).hexdigest(),
          "toolsSHA256": hashlib.sha256(args.tools.read_bytes()).hexdigest(),
          "runtimeSHA256": hashlib.sha256(args.runtime.read_bytes()).hexdigest(),
          "boundary": "Actual context_explain engineering control; no fresh-AI/all-world/release claim."}


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
                assert "error" not in reply, reply
                return reply["result"]
    raise TimeoutError(method)


def call(name, arguments):
    reply = rpc("tools/call", {"name": name, "arguments": arguments})
    assert not reply.get("isError"), reply
    return json.loads(reply["content"][0]["text"])


def untag(value):
    tag = value[0]
    if tag == "null":
        return None
    if tag in ["string", "boolean"]:
        return value[1]
    if tag == "integer":
        return int(value[1])
    if tag == "array":
        return [untag(element) for element in value[1]]
    if tag == "object":
        return {name: untag(element) for name, element in value[1]}
    raise ValueError("unsupported declaration value")


def tagged(value):
    if isinstance(value, bool):
        return ["boolean", value]
    if isinstance(value, int):
        return ["integer", str(value)]
    if isinstance(value, str):
        return ["string", value]
    if isinstance(value, dict):
        return ["object", [[name, tagged(element)] for name, element in sorted(value.items())]]
    raise ValueError("unsupported control value")


try:
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                       "clientInfo": {"name": "wit-explanation-control", "version": "1"}})
    tools = rpc("tools/list")["tools"]
    canonical = {"context_runtime", "context_providers", "context_inspect", "context_actions",
                 "context_explain", "context_run", "context_run_status"}
    assert {tool["name"] for tool in tools} == canonical
    report["toolCount"] = len(tools)
    report["runtime"] = call("context_runtime", {})
    assert report["runtime"]["executableSHA256"] == report["binarySHA256"]
    call("context_providers", {})
    call("context_inspect", {"item": "WIT explanation pressure"})
    assert not any(action["id"].startswith("wasm:explain-component:") for action in
                   call("context_actions", {"item": "WIT explanation pressure"})["actions"])
    shutil.copyfile(args.component, component)
    time.sleep(5.3)
    actions = call("context_actions", {"item": "WIT explanation pressure"})["actions"]
    record = next(action for action in actions if action["id"].endswith("proof:typed/api.challenge-record"))
    explanation = call("context_explain", {"item": "WIT explanation pressure", "actionId": record["id"]})
    report["explanation"] = explanation
    metadata = explanation["metadata"]
    assert metadata["interfaceDeclarationEncoding"] == "CapabilityValue tagged JSON"
    assert metadata["coreArgumentEncoding"] == "taggedNonStrings"
    guidance = metadata["coreArgumentEncodingGuidance"]
    for token in ['["boolean",true]', '["integer","-7"]', '["string","text"]', '"object"', 'JSON string']:
        assert token in guidance, ("missing encoding guidance", token)
    declaration = untag(json.loads(metadata["interfaceDeclaration"]))
    assert declaration["export"] == metadata["operationName"]
    definitions = {definition["id"]: definition["type"] for definition in declaration["types"]}
    parameter, = declaration["function"]["params"]
    fields = definitions[parameter["type"]]["kind"]["record"]["fields"]
    fields_by_name = {field["name"]: field["type"] for field in fields}
    assert fields_by_name == {"enabled": "bool", "offset": "s32", "challenge": "string"}
    result_fields = definitions[declaration["function"]["result"]]["kind"]["record"]["fields"]
    assert {field["name"]: field["type"] for field in result_fields} == {"enabled": "bool", "fingerprint": "u32"}
    # Native WIT names retain exact domains; no binary schema decoding or source
    # access is used to obtain the record fields, parameter name, or type names.
    report["readableDomains"] = {"s32": [-2147483648, 2147483647], "u32": [0, 4294967295]}
    challenge = "RIGHTCLICK:explain:" + uuid.uuid4().hex + '\n"\\☃\x00'
    values = {"bool": True, "s32": -7, "string": challenge}
    request = {field["name"]: values[field["type"]] for field in fields}
    fingerprint = 2166136261
    for byte in challenge.encode("utf-8"):
        fingerprint = ((fingerprint ^ byte) * 16777619) & 0xFFFFFFFF
    expected = {"enabled": True, "fingerprint": (fingerprint - 7) & 0xFFFFFFFF}
    arguments = {parameter["name"]: json.dumps(tagged(request), separators=(",", ":"), ensure_ascii=False)}
    result = call("context_run", {"item": "WIT explanation pressure", "actionId": record["id"], "confirmed": True,
                                 "arguments": arguments, "expectedOutput": json.dumps(expected, sort_keys=True, separators=(",", ":"))})
    assert result["state"] == "succeeded" and json.loads(result["output"]) == expected
    assert call("context_run_status", {"executionId": result["executionId"]})["rcir"] == result["rcir"]
    report["argumentsInferredFromAcquiredDeclaration"] = arguments
    report["independentExpected"] = expected
    report["resultRecord"] = result
    report["result"] = "GREEN"
    print("GREEN: context_explain includes acquired nested WIT fields/native domains and existing typed argument guidance.")
except Exception as error:
    report["result"] = "RED"
    report["failure"] = str(error)
    print("RED:", repr(error))
    raise
finally:
    (args.evidence / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    (args.evidence / "transcript.json").write_text(json.dumps(transcript, indent=2, ensure_ascii=False))
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    key.unlink(missing_ok=True)
    shutil.rmtree(lab)
