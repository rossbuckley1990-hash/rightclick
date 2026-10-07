#!/usr/bin/env python3
"""Live, isolated RIGHTCLICK GraphQL+gRPC proof via the seven generic MCP tools.
All execution goes through RIGHTCLICK. Independent verification uses raw
GraphQL HTTP and grpcurl only AFTER RIGHTCLICK operations complete.
Never mark provider acceptance as semantic success.
"""
import datetime
import hashlib
import json
import os
import pathlib
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

ARTIFACTS = [
    {"id": "countries-graphql-live", "kind": "graphql",
     "endpointURL": "https://countries.trevorblades.com/"},
    {"id": "grpcbin-grpc-live", "kind": "grpc",
     "endpointURL": "grpcs://grpcb.in:9001"},
]
EXPECTED_TOOLS = {
    "context_runtime", "context_inspect", "context_actions", "context_explain",
    "context_run", "context_run_status", "context_providers",
}
ITEM = "RIGHTCLICK remote GraphQL and gRPC acceptance 2026-10-07"
COUNTRY = "GB"


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def remote_country():
    payload = json.dumps({
        "query": 'query IndependentReadback { country(code: "GB") { code name } }',
        "operationName": "IndependentReadback",
    }).encode("utf-8")
    request = urllib.request.Request(
        "https://countries.trevorblades.com/",
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        data = json.load(response)
    if data.get("errors") or not isinstance(data.get("data", {}).get("country"), dict):
        raise ValueError("Independent GraphQL readback lacked an error-free country")
    return data["data"]["country"]


class Client:
    def __init__(self, binary):
        self.errors = tempfile.TemporaryFile(mode="w+t")
        self.process = subprocess.Popen(
            [str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.errors, text=True, bufsize=1,
        )
        self.counter = 0

    def request(self, method, params=None):
        self.counter += 1
        rid = self.counter
        packet = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            packet["params"] = params
        self.process.stdin.write(json.dumps(packet) + "\n")
        self.process.stdin.flush()
        with selectors.DefaultSelector() as sel:
            sel.register(self.process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 95
            while time.monotonic() < deadline:
                if not sel.select(max(0, deadline - time.monotonic())):
                    break
                line = self.process.stdout.readline()
                if not line:
                    raise RuntimeError("RIGHTCLICK MCP process closed stdout")
                reply = json.loads(line)
                if reply.get("id") != rid:
                    continue
                if "error" in reply:
                    raise RuntimeError("MCP error: " + str(reply["error"]))
                return reply["result"]
        raise TimeoutError("RIGHTCLICK MCP timeout for " + method)

    def call(self, name, args):
        result = self.request("tools/call", {"name": name, "arguments": args})
        if result.get("isError"):
            raise RuntimeError(name + ": " + str(result.get("content"))[:800])
        return json.loads(result["content"][0]["text"])

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.errors.seek(0)
        return self.errors.read()[-4000:]


def graphql_proof(client, actions):
    candidates = [
        cap for cap in actions
        if cap.get("metadata", {}).get("substrate") == "graphql"
        and cap.get("metadata", {}).get("field") == "country"
        and cap.get("metadata", {}).get("operationKind") == "query"
        and cap.get("invocation") != "unsupported"
    ]
    if len(candidates) != 1:
        raise AssertionError("Expected exactly one reflected GraphQL country query; found " + str(len(candidates)))
    cap = candidates[0]
    detail = client.call("context_explain", {"actionId": cap["id"], "item": ITEM})
    if detail["id"] != cap["id"]:
        raise AssertionError("GraphQL explanation did not match discovered capability")
    invoked = client.call("context_run", {
        "actionId": cap["id"], "item": ITEM, "arguments": {"code": COUNTRY},
        "confirmed": True,
    })
    retained = client.call("context_run_status", {"executionId": invoked["executionId"]})
    if retained["state"] != invoked["state"] or retained.get("output") != invoked.get("output"):
        raise AssertionError("GraphQL status retention mismatch")
    if invoked["state"] not in ("accepted", "succeeded"):
        raise AssertionError("GraphQL run: " + invoked["state"] + " - " + invoked.get("message", ""))
    parsed = json.loads(invoked["output"])
    reflected = parsed.get("data", {}).get("rightclickResult")
    if not isinstance(reflected, dict):
        raise AssertionError("GraphQL operation returned no structured country")
    independently = remote_country()
    matched = [
        field for field in ("name", "code")
        if field in reflected and reflected[field] == independently.get(field)
    ]
    if not matched:
        raise AssertionError("GraphQL RIGHTCLICK result did not match independent API readback")
    return {
        "state": invoked["state"], "actionId": cap["id"],
        "executionId": invoked["executionId"], "retainedState": retained["state"],
        "reflected": reflected, "independentReadback": independently,
        "matchedFields": matched, "independentlyVerified": True,
        "rightclickOutcomeVerified": bool(invoked.get("evidence", {}).get("outcomeVerified", False)),
    }


def grpc_proof(client, actions):
    preferred = ("Empty", "Index", "SayHello")
    candidates = [
        cap for cap in actions
        if cap.get("metadata", {}).get("substrate") == "grpc"
        and cap.get("invocation") != "unsupported"
        and cap.get("metadata", {}).get("method") in preferred
    ]
    candidates.sort(key=lambda cap: preferred.index(cap["metadata"]["method"]))
    if not candidates:
        raise AssertionError("No supported reflected grpcbin read-only unary method")
    # Whitelist methods: do not exercise generic service writes or unknown RPC effects.
    for cap in candidates:
        detail = client.call("context_explain", {"actionId": cap["id"], "item": ITEM})
        schema = json.loads(detail.get("metadata", {}).get("argumentsSchema", '{"properties":{},"required":[]}'))
        required = schema.get("required", [])
        if required:
            continue
        if detail.get("metadata", {}).get("callType") != "unary":
            continue
        chosen = (cap, detail)
        break
    else:
        raise AssertionError("No safe zero-argument unary reflected RPC")
    cap, detail = chosen
    method = detail["metadata"]["rpcPath"].lstrip("/")
    invoked = client.call("context_run", {
        "actionId": cap["id"], "item": ITEM,
        "arguments": {}, "confirmed": True,
    })
    retained = client.call("context_run_status", {"executionId": invoked["executionId"]})
    if retained["state"] != invoked["state"] or retained.get("output") != invoked.get("output"):
        raise AssertionError("gRPC retained execution disagrees with invocation")
    if invoked["state"] not in ("accepted", "succeeded"):
        raise AssertionError("gRPC run: " + invoked["state"] + " - " + invoked.get("message", ""))
    direct = json.loads(invoked["output"])
    verifier = shutil.which("grpcurl")
    if not verifier:
        raise AssertionError("Independent grpcurl verifier is not installed")
    proc = subprocess.run(
        [verifier, "-max-time", "20", "-d", "{}", "grpcb.in:9001", method],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode:
        raise AssertionError("Independent grpcurl failed: " + proc.stderr[-600:])
    external = json.loads(proc.stdout)
    if direct != external:
        raise AssertionError("gRPC response differs from independent grpcurl readback")
    return {
        "state": invoked["state"], "method": method,
        "actionId": cap["id"], "executionId": invoked["executionId"],
        "retainedState": retained["state"], "rightclickResult": direct,
        "independentGrpcurlResult": external, "independentlyVerified": True,
        "rightclickOutcomeVerified": bool(invoked.get("evidence", {}).get("outcomeVerified", False)),
    }


def main(binary, receipt):
    os.environ["RIGHTCLICK_CAPABILITY_ARTIFACTS"] = json.dumps(ARTIFACTS)
    result = {
        "startedUTC": now(), "scope": "isolated GitHub macOS runner; public remote services",
        "protocols": [a["kind"] for a in ARTIFACTS],
        "configuredArtifacts": ARTIFACTS,
        "verificationPolicy": "independent readback required; acceptance is not success",
        "checks": {},
    }
    client = None
    try:
        binary = pathlib.Path(binary).resolve(strict=True)
        result["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        result["binaryVersion"] = subprocess.check_output(
            [str(binary), "version"], text=True, timeout=20,
        ).strip()
        client = Client(binary)
        init = client.request("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "rightclick-cloud-protocol-proof", "version": "1"},
        })
        if init["serverInfo"]["version"] != result["binaryVersion"]:
            raise AssertionError("MCP and binary version mismatch")
        client.process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "method": "notifications/initialized",
        }) + "\n")
        client.process.stdin.flush()
        names = set(tool["name"] for tool in client.request("tools/list")["tools"])
        if names != EXPECTED_TOOLS:
            raise AssertionError("Seven-primitive ABI mismatch " + str(sorted(names)))
        result["sevenPrimitives"] = sorted(names)
        runtime = client.call("context_runtime", {})
        if runtime["executableSHA256"] != result["binarySHA256"]:
            raise AssertionError("Runtime binary attestation mismatch")
        result["runtime"] = runtime
        providers = client.call("context_providers", {})
        result["providerSummary"] = [
            {"name": p["name"], "source": p["source"],
             "capabilityCount": len(p.get("capabilityTitles", []))}
            for p in providers if p.get("source") in ("graphql", "grpc")
        ]
        actions = client.call("context_actions", {"item": ITEM})["actions"]
        result["reflectedCounts"] = {
            kind: sum(1 for cap in actions if cap.get("metadata", {}).get("substrate") == kind)
            for kind in ("graphql", "grpc")
        }
        for kind, runner in (("graphql", graphql_proof), ("grpc", grpc_proof)):
            try:
                result["checks"][kind] = runner(client, actions)
                print("PASS: " + kind + " reflection, invocation and independent verification", flush=True)
            except Exception as exc:
                result["checks"][kind] = {"independentlyVerified": False, "failure": repr(exc)}
                print("FAIL: " + kind + " " + repr(exc), flush=True)
        result["verified"] = (
            all(result["checks"].get(k, {}).get("independentlyVerified") for k in ("graphql", "grpc"))
            and all(result["reflectedCounts"][k] > 0 for k in ("graphql", "grpc"))
        )
    except Exception as exc:
        result["failure"] = repr(exc)
        result["verified"] = False
    finally:
        if client is not None:
            result["runtimeStderrTail"] = client.close()
        result["finishedUTC"] = now()
        receipt = pathlib.Path(receipt)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({
            "verified": result.get("verified"), "checks": result.get("checks", {}),
            "failure": result.get("failure"), "receipt": str(receipt),
        }, indent=2), flush=True)
    return 0 if result.get("verified") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
