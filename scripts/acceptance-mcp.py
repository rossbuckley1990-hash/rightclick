#!/usr/bin/env python3
"""Acceptance of a concrete binary through stdio and authenticated HTTP.
No tunnel, persisted credential, or remote exposure is created.
"""
import hashlib
import json
import os
import pathlib
import selectors
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

binary = str(pathlib.Path(sys.argv[1]).resolve())
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
records = []
expected_tools = {"context_inspect", "context_actions", "context_run", "context_run_status", "context_explain", "context_providers"}
fullwidth = "service:com.apple.ChineseTextConverterService:convertTextToFullWidth"

def message(i, method, params=None):
    d = {"jsonrpc": "2.0", "id": i, "method": method}
    if params is not None:
        d["params"] = params
    return d

def payload(reply):
    assert not reply.get("error"), reply
    result = reply["result"]
    assert not result.get("isError"), result
    return json.loads(result["content"][0]["text"])

def exercise(request, label):
    init = request(message(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "rightclick-acceptance", "version": "1"}}))
    assert init["result"]["serverInfo"]["version"] == "0.1.1", init
    tools = request(message(2, "tools/list"))
    assert {t["name"] for t in tools["result"]["tools"]} == expected_tools
    inspected = payload(request(message(7, "tools/call", {"name": "context_inspect", "arguments": {"item": "RightClick"}})))
    assert inspected["kind"] == "text" and inspected["text"] == "RightClick", inspected
    assert inspected["typeIdentifier"] == "public.plain-text" and inspected["byteCount"] == 10, inspected
    actions = payload(request(message(3, "tools/call", {"name": "context_actions", "arguments": {"item": "RightClick"}})))
    assert any(a["id"] == fullwidth for a in actions["actions"])
    gated = payload(request(message(4, "tools/call", {"name": "context_run", "arguments": {"item": "https://example.com/rightclick-policy", "actionId": "AirDrop"}})))
    assert gated["state"] == "awaiting_user" and "CONFIRMATION_REQUIRED" in gated["message"], gated
    result = payload(request(message(5, "tools/call", {"name": "context_run", "arguments": {"item": "RightClick", "actionId": fullwidth, "confirmed": True, "expectedOutput": "ＲｉｇｈｔＣｌｉｃｋ"}})))
    assert result["output"] == "ＲｉｇｈｔＣｌｉｃｋ", result
    assert result["state"] == "succeeded" and result["evidence"]["outcomeVerified"], result
    assert result["evidence"]["type"] == "returned_text_postcondition", result
    status = payload(request(message(6, "tools/call", {"name": "context_run_status", "arguments": {"executionId": result["executionId"]}})))
    assert status["output"] == "ＲｉｇｈｔＣｌｉｃｋ", status
    assert status["state"] == result["state"] and status["evidence"] == result["evidence"], status
    records.append({"transport": label, "initialize": init, "tools": tools, "inspect": inspected, "actions": actions, "confirmation": gated, "fullWidth": result, "status": status, "OUTCOME_VERIFIED": "exact full-width pasteboard output"})
    print(label + ": PASS — six tools, exact inspection, contextual discovery, confirmation, exact full-width output, retained status")

with (out / "stdio.stderr.log").open("w") as err:
    process = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1)
    def stdio(d):
        process.stdin.write(json.dumps(d) + "\n")
        process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 40
        try:
            while time.monotonic() < deadline:
                if selector.select(max(0, deadline - time.monotonic())):
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError("stdio ended unexpectedly")
                    response = json.loads(line)
                    if response.get("id") == d["id"]:
                        return response
            raise TimeoutError("stdio response timed out")
        finally:
            selector.close()
    try:
        exercise(stdio, "stdio")
    finally:
        process.terminate()
        process.wait(timeout=10)

with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
token = uuid.uuid4().hex + uuid.uuid4().hex
environment = dict(os.environ, RIGHTCLICK_MCP_TOKEN=token)
with (out / "http.stderr.log").open("w") as err:
    process = subprocess.Popen([binary, "mcp", "--http", "--port", str(port)], env=environment, stdout=subprocess.DEVNULL, stderr=err)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError("HTTP server did not start")
        binding = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], text=True)
        assert f"n127.0.0.1:{port}" in binding and "n*:" not in binding, binding
        (out / "listener.txt").write_text(binding)
        url = f"http://127.0.0.1:{port}/mcp"
        # Framing is parsed before authentication; malformed input must not kill
        # the listener or ask it to buffer an unbounded body.
        for framing in ("Content-Length: -1", "Content-Length: nonsense", "Content-Length: 2000001", "Transfer-Encoding: chunked"):
            with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                connection.sendall(("POST /mcp HTTP/1.1\r\nHost: localhost\r\n" + framing + "\r\n\r\n").encode())
                response = connection.recv(4096)
                assert response.startswith(b"HTTP/1.1 400 "), (framing, response)
            assert process.poll() is None, "Malformed request terminated the server"
        print("HTTP framing: PASS — negative, invalid, oversized and unsupported framing rejected; listener stays alive")
        def http(d, bearer=token):
            headers = {"Content-Type": "application/json", "Accept": "application/json", "MCP-Protocol-Version": "2025-03-26"}
            if bearer is not None:
                headers["Authorization"] = "Bearer " + bearer
            req = urllib.request.Request(url, data=json.dumps(d).encode(), headers=headers)
            with urllib.request.urlopen(req, timeout=40) as response:
                assert response.status == 200
                return json.load(response)
        for bearer in (None, "invalid-test-credential"):
            try:
                http(message(1, "initialize", {}), bearer)
                raise AssertionError("Unauthenticated request accepted")
            except urllib.error.HTTPError as e:
                assert e.code == 401, e.code
        print("HTTP policy: PASS — loopback binding; missing and incorrect credentials return 401")
        exercise(http, "authenticated HTTP")
    finally:
        process.terminate()
        process.wait(timeout=10)

summary = {"binary": binary, "sha256": hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(), "records": records, "authentication": "missing and invalid token: 401", "exposure": "127.0.0.1 only; no tunnel"}
(out / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
