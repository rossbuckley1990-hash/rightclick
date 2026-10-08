#!/usr/bin/env python3
"""Frozen public seven-operation regression for caller-held contract fingerprints.

A controlled MCP provider exercises real HTTP and the production RIGHTCLICK MCP
boundary. This is an engineering regression, not eleven-world fresh-AI proof.
The separate encoder checks the existing exact ABI hash independently.
"""
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import selectors
import subprocess
import tempfile
import threading
import time

TOOLS = {"context_runtime", "context_providers", "context_inspect", "context_actions",
         "context_explain", "context_run", "context_run_status"}


def canonical(value):
    def frame(tag, data):
        return tag + str(len(data)).encode() + b":" + data

    def encode(value):
        if value is None:
            return b"n"
        if isinstance(value, bool):
            return b"b1" if value else b"b0"
        if isinstance(value, int):
            return frame(b"i", str(value).encode())
        if isinstance(value, str):
            return frame(b"s", value.encode("utf-8"))
        if isinstance(value, list):
            return b"a" + str(len(value)).encode() + b":" + b"".join(map(encode, value))
        if isinstance(value, dict):
            keys = sorted(value, key=lambda key: key.encode("utf-8"))
            return b"o" + str(len(keys)).encode() + b":" + b"".join(
                encode(key) + encode(value[key]) for key in keys)
        raise ValueError("unsupported frozen declaration value")

    return b"RIGHTCLICK-VALUE-1\0" + encode(value)


def fingerprint(capability):
    provider = capability.get("provider") or {}
    metadata = {key: value for key, value in capability["metadata"].items()
                if not key.startswith("experience.")}
    declaration = {"title": capability["title"], "source": capability["source"],
                   "providerName": provider.get("name"), "providerBundleID": provider.get("bundleIdentifier"),
                   "inputs": capability["inputs"], "outputs": capability["output"],
                   "safety": capability["safety"], "invocation": capability["invocation"],
                   "supportLevel": capability["supportLevel"],
                   "requiresConfirmation": capability["requiresConfirmation"], "metadata": metadata}
    contract = {"version": 1, "capability": capability["id"], "reflector": capability["reflectorID"],
                "provider": metadata.get("providerIdentity") or provider.get("bundleIdentifier") or capability["reflectorID"],
                "arguments": None, "result": None, "declaration": declaration}
    return hashlib.sha256(b"RIGHTCLICK-CONTRACT-1\0" + canonical(contract)).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    transcript, requests, effects, controls = [], [], [], {}
    mode = {"generation": 1}
    action_id = "mcp:contract-pin-regression:record"
    item = "caller-held contract regression"

    def tool():
        properties = {"challenge": {"type": "string"}}
        if mode["generation"] == 2:
            properties["label"] = {"type": "string"}
        return {"name": "record", "title": "Record challenge", "description": "controlled generation " + str(mode["generation"]),
                "inputSchema": {"type": "object", "properties": properties, "required": ["challenge"], "additionalProperties": False},
                "outputSchema": {"type": "object", "properties": {"challenge": {"type": "string"}},
                                 "required": ["challenge"], "additionalProperties": False}}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            query = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(query)
            if "id" not in query:
                self.send_response(202)
                self.end_headers()
                return
            method = query["method"]
            if method == "initialize":
                result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "controlled-contract-pin", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [tool()]}
            elif method == "tools/call":
                effect = {"generation": mode["generation"], "arguments": query["params"]["arguments"]}
                effects.append(effect)
                result = {"structuredContent": {"challenge": effect["arguments"]["challenge"]}, "content": []}
            else:
                raise ValueError(method)
            data = json.dumps({"jsonrpc": "2.0", "id": query["id"], "result": result}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="rightclick-contract-pin-") as temporary:
        config = pathlib.Path(temporary) / "host.json"
        config.write_text(json.dumps({"version": 1, "revision": "controlled-pin-1", "deniedCapabilities": []}))
        config.chmod(0o600)
        environment = dict(os.environ, RIGHTCLICK_RCIR_CONFIG=str(config), RIGHTCLICK_EXPERIENCE="off",
                           RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([{"id": "contract-pin-regression", "kind": "mcp",
                               "endpointURL": "http://127.0.0.1:" + str(server.server_port) + "/mcp"}]))
        error_stream = (output / "runtime.stderr.log").open("w")
        process = subprocess.Popen([str(binary), "mcp"], env=environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=error_stream, text=True, bufsize=1)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def rpc(method, params):
            identifier = len(transcript) + 1
            query = {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}
            process.stdin.write(json.dumps(query) + "\n")
            process.stdin.flush()
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                if selector.select(max(0, deadline - time.monotonic())):
                    raw = process.stdout.readline()
                    if not raw:
                        raise RuntimeError("RIGHTCLICK process ended")
                    reply = json.loads(raw)
                    if reply.get("id") == identifier:
                        transcript.append({"request": query, "response": reply})
                        if "error" in reply:
                            raise RuntimeError(reply)
                        return reply["result"]
            raise TimeoutError(method)

        def call(name, arguments):
            result = rpc("tools/call", {"name": name, "arguments": arguments})
            if result.get("isError"):
                return {"toolError": result}
            return json.loads(result["content"][0]["text"])

        def check(name, condition, detail=None):
            controls[name] = {"result": "PASS" if condition else "FAIL", "detail": detail}

        def run(challenge, pin=None, alias=None):
            arguments = {"item": item, "actionId": alias or action_id, "confirmed": True,
                         "arguments": {"challenge": challenge}}
            if pin is not None:
                arguments["contractSHA256"] = pin
            return call("context_run", arguments)

        def rejected(record):
            return "toolError" in record or record.get("state") in {"unavailable", "rejected", "failed"}

        report = {"baseline": "2dd7bd2fafbbaa994812d1bc904730b74aa74816",
                  "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "controls": controls,
                  "boundary": "Controlled provider / real production MCP transport; not restricted fresh-AI eleven-world acceptance."}
        try:
            rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                               "clientInfo": {"name": "frozen-contract-pin-regression", "version": "1"}})
            tools = rpc("tools/list", {})["tools"]
            check("exactly_seven_operations", {row["name"] for row in tools} == TOOLS)
            report["runtime"] = call("context_runtime", {})
            call("context_providers", {})
            call("context_inspect", {"item": item})
            actions = call("context_actions", {"item": item})["actions"]
            first_action = next(row for row in actions if row["id"] == action_id)
            first = call("context_explain", {"item": item, "actionId": action_id})
            first_pin = fingerprint(first)
            check("actions_and_explain_exact_independent_hash", first_action.get("contractSHA256") == first_pin == first.get("contractSHA256"))
            initial = run("fresh-first", first_pin)
            check("fresh_pin_admitted_once", initial.get("state") == "accepted" and len(effects) == 1)
            if initial.get("executionId"):
                status = call("context_run_status", {"executionId": initial["executionId"]})
                check("status_preserves_execution", status.get("actionId") == action_id)
            for index, malformed in enumerate(["", "abc", "A" * 64, "f" * 63, "0" * 64 + "\n", 7, {}, []]):
                before_requests, before_effects = len(requests), len(effects)
                record = run("malformed-" + str(index), malformed)
                check("malformed_pin_" + str(index) + "_zero_provider_requests",
                      rejected(record) and len(requests) == before_requests and len(effects) == before_effects,
                      {"providerRequestDelta": len(requests) - before_requests, "effectDelta": len(effects) - before_effects})
            mode["generation"] = 2
            time.sleep(5.2)  # Existing bounded acquisition cache expires; no runtime restart.
            second_actions = call("context_actions", {"item": item})["actions"]
            second_action = next(row for row in second_actions if row["id"] == action_id)
            second = call("context_explain", {"item": item, "actionId": action_id})
            second_pin = fingerprint(second)
            check("same_id_real_schema_drift", first["id"] == second["id"] and first_pin != second_pin)
            before = len(effects)
            stale = run("stale-reviewed-generation", first_pin)
            check("caller_held_stale_contract_zero_effect", rejected(stale) and len(effects) == before,
                  {"state": stale.get("state"), "effectDelta": len(effects) - before})
            before = len(effects)
            fresh = run("fresh-second", second_pin)
            check("rediscovered_contract_admitted_once", fresh.get("state") == "accepted" and len(effects) == before + 1)
            before = len(effects)
            alias = run("title-alias", second_pin, second["title"])
            check("title_alias_same_pin", alias.get("state") == "accepted" and len(effects) == before + 1)
            before = len(effects)
            stale_alias = run("stale-title-alias", first_pin, second["title"])
            check("title_alias_cannot_bypass_stale_pin", rejected(stale_alias) and len(effects) == before)
            before = len(effects)
            legacy = run("legacy-unpinned")
            check("legacy_unpinned_fresh_resolution_retained", legacy.get("state") == "accepted" and len(effects) == before + 1)
            check("second_catalog_exact_pin", second_action.get("contractSHA256") == second_pin == second.get("contractSHA256"))
            check("tool_catalog_unchanged_during_drift", rpc("tools/list", {})["tools"] == tools)
            report["result"] = "PASS" if all(row["result"] == "PASS" for row in controls.values()) else "FAIL"
        finally:
            (output / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
            (output / "provider-requests.json").write_text(json.dumps(requests, indent=2) + "\n")
            (output / "provider-effects.json").write_text(json.dumps(effects, indent=2) + "\n")
            (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
            process.terminate()
            process.wait(timeout=5)
            selector.close()
            error_stream.close()
            server.shutdown()
    print(json.dumps(report, indent=2))
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
