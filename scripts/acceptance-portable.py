#!/usr/bin/env python3
"""Exercise the same seven operations and a real reflected provider on every OS."""
import hashlib
import http.server
import json
import os
import pathlib
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}
binary = pathlib.Path(sys.argv[1]).resolve()
schema = {"type": "object", "additionalProperties": False, "required": ["value"],
          "properties": {"value": {"type": "string"}}}
spec = {"openapi": "3.0.3", "info": {"title": "Portable acceptance", "version": "1"},
        "paths": {"/record": {"post": {"operationId": "writeRecord", "summary": "Write test record",
          "requestBody": {"required": True, "content": {"application/json": {"schema": schema}}},
          "responses": {"200": {"description": "Accepted", "content": {"application/json": {"schema": schema}}}}}}}}
effects = []
class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    def do_GET(self): self.reply(spec)
    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        effects.append(value)
        self.reply(value)

provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=provider.serve_forever, daemon=True).start()
base = "http://127.0.0.1:" + str(provider.server_port)

def exercise(request, transport):
    sequence = 0
    def req(method, params):
        nonlocal sequence
        sequence += 1
        result = request({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params})
        assert "error" not in result, result
        return result["result"]
    def call(name, arguments):
        result = req("tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])
    req("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "portable-acceptance", "version": "1"}})
    assert {t["name"] for t in req("tools/list", {})["tools"]} == TOOLS
    runtime = call("context_runtime", {})
    assert runtime["transport"] == transport, runtime
    assert runtime["executableSHA256"] == hashlib.sha256(binary.read_bytes()).hexdigest(), runtime
    assert runtime["platform"] in ("macOS", "Linux", "Windows"), runtime
    item = call("context_inspect", {"item": "portable input"})
    assert item["kind"] == "text" and item["typeIdentifier"] == "public.plain-text", item
    actions = call("context_actions", {"item": "portable input"})["actions"]
    action = next(a for a in actions if a.get("provider", {}).get("name") == "Portable acceptance")
    if runtime["platform"] != "macOS":
        assert not any(a["source"] in ("service", "sharing_service", "action_extension") for a in actions)
    explained = call("context_explain", {"item": "portable input", "actionId": action["id"]})
    assert explained["metadata"]["baseURL"].rstrip("/") == base, explained
    arguments = {"item": "portable input", "actionId": action["id"], "arguments": {"value": "portable result"}}
    count = len(effects)
    gated = call("context_run", arguments)
    assert gated["state"] == "awaiting_user" and len(effects) == count, gated
    bad = call("context_run", dict(arguments, confirmed=True, arguments={"undeclared": "value"}))
    assert bad["state"] == "failed" and len(effects) == count, bad
    accepted = call("context_run", dict(arguments, confirmed=True))
    assert accepted["state"] == "accepted" and not accepted["evidence"]["outcomeVerified"], accepted
    assert effects[-1] == {"value": "portable result"} and len(effects) == count + 1
    assert accepted["rcir"]["leaseConsumed"] is True, accepted
    status = call("context_run_status", {"executionId": accepted["executionId"]})
    assert status["state"] == accepted["state"] and status["rcir"] == accepted["rcir"], status
    assert any(p["name"] == "Portable acceptance" for p in call("context_providers", {}))
    print(transport + ": PASS (seven operations, runtime provenance, real provider invocation, confirmation and argument gates, unverified acceptance, retained status)")

with tempfile.TemporaryDirectory(prefix="rightclick-portable-") as temp:
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("RIGHTCLICK_"): del env[key]
    env.update(RIGHTCLICK_EXPERIENCE="off", RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([
        {"id": "portable-test", "kind": "openapi", "specificationURL": base + "/openapi.json", "baseURL": base}]))
    # Isolate every platform's state paths; no caller client configuration is touched.
    env.update(HOME=temp, USERPROFILE=temp, LOCALAPPDATA=temp, XDG_STATE_HOME=temp)
    with open(pathlib.Path(temp) / "stdio.log", "w") as errors:
        process = subprocess.Popen([str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=errors, text=True, encoding="utf-8", bufsize=1, env=env)
        replies = queue.Queue()
        def reader():
            for line in process.stdout: replies.put(json.loads(line))
            replies.put(None)
        threading.Thread(target=reader, daemon=True).start()
        def stdio(request):
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            while True:
                response = replies.get(timeout=40)
                assert response is not None, "stdio ended before response"
                if response.get("id") == request["id"]: return response
        try: exercise(stdio, "stdio")
        finally:
            process.terminate()
            process.wait(timeout=10)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    token = os.urandom(32).hex()
    env["RIGHTCLICK_MCP_TOKEN"] = token
    with open(pathlib.Path(temp) / "http.log", "w") as errors:
        process = subprocess.Popen([str(binary), "mcp", "--http", "--port", str(port)],
            stderr=errors, stdout=subprocess.DEVNULL, env=env)
        endpoint = "http://127.0.0.1:" + str(port) + "/mcp"
        try:
            for _ in range(200):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1): break
                except OSError: time.sleep(.1)
            else: raise RuntimeError("HTTP listener did not start")
            def http(request, authenticated=True):
                headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
                if authenticated: headers["Authorization"] = "Bearer " + token
                query = urllib.request.Request(endpoint, json.dumps(request).encode(), headers)
                with urllib.request.urlopen(query, timeout=40) as response:
                    data = response.read().decode()
                    if response.headers.get("Content-Type", "").startswith("text/event-stream"):
                        return next(json.loads(line[6:]) for line in data.splitlines() if line.startswith("data: "))
                    return json.loads(data)
            try:
                http({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, authenticated=False)
                raise AssertionError("HTTP accepted an unauthenticated request")
            except urllib.error.HTTPError as error: assert error.code == 401, error
            exercise(http, "http")
        finally:
            process.terminate()
            process.wait(timeout=10)
provider.shutdown()
