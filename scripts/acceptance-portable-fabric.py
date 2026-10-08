#!/usr/bin/env python3
"""Real binary, portable provider, seven operations, independent host readback.
All effects/configuration are disposable; no native desktop capability is used.
"""
import base64
import hashlib
import http.server
import json
import os
import pathlib
import selectors
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

binary = str(pathlib.Path(sys.argv[1]).resolve())
tools = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}
value = "portable independently observed value"
effects = []

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path.startswith("/invoke/"): effects.append(self.headers.get("X-RightClick-Task-ID"))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(value.encode())

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = "http://127.0.0.1:" + str(server.server_port)
spec = {"openapi":"3.0.3", "info":{"title":"Portable fixture", "version":"1"},
        "paths":{"/invoke/{expected}":{"get":{"operationId":"portableRead", "summary":"Read portable fixture",
            "parameters":[{"name":"expected","in":"path","required":True,"schema":{"type":"string"}}],
            "responses":{"200":{"description":"Returned text", "content":{"text/plain":{"schema":{"type":"string"}}}}}}}}}

with tempfile.TemporaryDirectory(prefix="rightclick-portable-acceptance-") as directory:
    directory = str(pathlib.Path(directory).resolve())
    config = pathlib.Path(directory) / "host.json"
    host = {"version":1,"revision":"portable-acceptance-1","deniedCapabilities":[]}
    def configure():
        config.write_text(json.dumps(host)); config.chmod(0o600)
    configure()
    artifact = {"id":"portable-fixture", "kind":"openapi", "baseURL":base,
                "inlineData":base64.b64encode(json.dumps(spec).encode()).decode()}
    env = dict(os.environ, RIGHTCLICK_EXPERIENCE="off", RIGHTCLICK_RCIR_CONFIG=str(config),
        RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([artifact]), XDG_CONFIG_HOME=directory,
        XDG_STATE_HOME=directory, CFFIXED_USER_HOME=directory)
    sequence = 0
    def message(method, params=None):
        global sequence
        sequence += 1
        return {"jsonrpc":"2.0", "id":sequence,"method":method,"params":params or {}}
    def payload(reply):
        assert "error" not in reply, reply
        result = reply["result"]
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])
    def exercise(request, transport):
        init = request(message("initialize", {"protocolVersion":"2025-03-26", "capabilities":{},
            "clientInfo":{"name":"portable-acceptance", "version":"1"}}))
        assert "result" in init, init
        assert {t["name"] for t in request(message("tools/list"))["result"]["tools"]} == tools
        def call(name, args=None): return payload(request(message("tools/call", {"name":name,"arguments":args or {}})))
        runtime = call("context_runtime")
        assert runtime["transport"] == transport and runtime["executableSHA256"] == hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest()
        assert call("context_inspect", {"item":"portable fixture"})["kind"] == "text"
        actions = call("context_actions", {"item":"portable fixture"})["actions"]
        action = next(a["id"] for a in actions if a["title"] == "Read portable fixture")
        assert call("context_explain", {"item":"portable fixture","actionId":action})["id"] == action
        call("context_providers")
        host["observers"] = {action:{"urlTemplate":base+"/observe","expectedArgument":"expected"}}
        configure()
        before = len(effects)
        pending = call("context_run", {"item":"portable fixture","actionId":action,"arguments":{"expected":value}})
        assert pending["state"] == "awaiting_user" and len(effects) == before
        result = call("context_run", {"item":"portable fixture","actionId":action,"arguments":{"expected":value},"confirmed":True})
        assert result["state"] == "succeeded" and result["evidence"]["outcomeVerified"], result
        assert result["rcir"]["leaseConsumed"] and len(effects) == before+1, result
        status = call("context_run_status", {"executionId":result["executionId"]})
        assert status["state"] == result["state"] and status["rcir"] == result["rcir"]
        host["deniedCapabilities"] = [action]; configure()
        denied = call("context_run", {"item":"portable fixture","actionId":action,"arguments":{"expected":value},"confirmed":True})
        assert denied["state"] in ("rejected", "failed", "unavailable") and len(effects) == before+1
        host["deniedCapabilities"] = []; configure()
        print(transport + ": PASS seven operations, actual portable provider, consumed RCIR lease, verification, retained evidence, local policy denial")
    with open(os.devnull,"w") as err:
        process = subprocess.Popen([binary,"mcp"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True,bufsize=1)
        def stdio(query):
            process.stdin.write(json.dumps(query)+"\n"); process.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout,selectors.EVENT_READ)
                deadline = time.monotonic()+40
                while time.monotonic()<deadline:
                    if selector.select(max(0,deadline-time.monotonic())):
                        line = process.stdout.readline()
                        assert line, "MCP ended"
                        reply = json.loads(line)
                        if reply.get("id") == query["id"]: return reply
                raise TimeoutError("MCP response")
        try: exercise(stdio,"stdio")
        finally: process.terminate(); process.wait(timeout=10)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1",0)); port = probe.getsockname()[1]
        token = uuid.uuid4().hex+uuid.uuid4().hex
        process = subprocess.Popen([binary,"mcp","--http","--port",str(port)],env=dict(env,RIGHTCLICK_MCP_TOKEN=token),stdout=err,stderr=err)
        url = f"http://127.0.0.1:{port}/mcp"
        def http(query, bearer=token):
            headers = {"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
            if bearer is not None: headers["Authorization"] = "Bearer "+bearer
            with urllib.request.urlopen(urllib.request.Request(url,data=json.dumps(query).encode(),headers=headers),timeout=40) as response:
                return json.load(response)
        try:
            for _ in range(200):
                try:
                    with socket.create_connection(("127.0.0.1",port),timeout=.2): break
                except OSError: time.sleep(.05)
            for framing in ("Content-Length: -1", "Content-Length: nonsense", "Content-Length: 2000001", "Transfer-Encoding: chunked"):
                with socket.create_connection(("127.0.0.1",port),timeout=5) as connection:
                    connection.sendall(("POST /mcp HTTP/1.1\r\nHost: localhost\r\n"+framing+"\r\n\r\n").encode())
                    response=connection.recv(4096)
                    assert response.startswith(b"HTTP/1.1 400 "), (framing,response)
                assert process.poll() is None, "Malformed request terminated the server"
            for bearer in (None,"invalid-test-credential"):
                try: http(message("tools/list"),bearer); raise AssertionError("authentication bypass")
                except urllib.error.HTTPError as error: assert error.code == 401
            print("http safety: PASS negative/invalid/oversized/unsupported framing, missing/incorrect credentials, listener remains available")
            exercise(http,"http")
        finally: process.terminate(); process.wait(timeout=10)
server.shutdown()
print("PASS portable binary acceptance; external readback is a host-owned observation, not provider 2xx")
