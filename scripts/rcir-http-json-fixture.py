#!/usr/bin/env python3
"""Actual separate mutation, read-only observer and redirect trap HTTP processes.
Fixture tokens stay in protected disposable files, never logs or tool payloads.
"""
import base64
import hashlib
import http.server
import json
import pathlib
import sys
import urllib.parse

root, role = pathlib.Path(sys.argv[1]), sys.argv[2]
root.mkdir(parents=True, exist_ok=True); (root / "records").mkdir(exist_ok=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        if role != "provider": self.send_error(403); return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        challenge, value = body["id"], body["value"]
        if not challenge or not all(c.isascii() and (c.isalnum() or c == "-") for c in challenge): self.send_error(400); return
        mutate = value != "missing" and not (root / "noop-provider").exists()
        marker = self.headers.get("X-RightClick-Invocation", "")
        with (root / "effects.jsonl").open("a") as handle: handle.write(json.dumps({"challenge": challenge, "value": value, "mutationApplied": mutate, "invocationID": marker}) + "\n")
        if mutate:
            (root / "records" / challenge).write_bytes(("different" if value == "mismatch" else value).encode())
            if (root / "include-invocation").exists(): (root / "records" / (challenge + ".invocation")).write_text(marker)
        acknowledgement = (root / "ack-response").exists()
        response = json.dumps({"providerClaim": "effect verified", "undeclared": body} if acknowledgement else body).encode()
        status = int((root / "ack-status").read_text()) if acknowledgement and (root / "ack-status").exists() else (202 if acknowledgement else 200)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response))); self.end_headers(); self.wfile.write(response)
    def do_GET(self):
        if role == "trap":
            with (root / "trap.jsonl").open("a") as handle: handle.write(json.dumps({"authorizationPresent": "Authorization" in self.headers, "cookiePresent": "Cookie" in self.headers}) + "\n")
            self.send_response(200); self.end_headers(); return
        if role == "provider" and self.path == "/openapi.json":
            schema = {"type": "object", "additionalProperties": False, "required": ["id", "value"], "properties": {"id": {"type": "string"}, "value": {"type": "string"}}}
            content = {"application/json": {"schema": schema}}
            spec = {"openapi": "3.0.3", "info": {"title": "Actual HTTP JSON fixture", "version": "1"}, "paths": {"/records": {"post": {
                "operationId": "write", "summary": "Store dedicated HTTP observation challenge", "requestBody": {"required": True, "content": content},
                "responses": {"200": {"description": "Stored", "content": content}}}}}}
            if (root / "ack-response").exists():
                spec["paths"]["/records"]["post"]["responses"] = {"202": {"description": "Effect accepted; verify file independently"}}
            response = json.dumps(spec).encode(); self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response))); self.end_headers(); self.wfile.write(response); return
        if role != "observer": self.send_error(403); return
        authorization = self.headers.get("Authorization", "")
        readonly = (root / "observer.token").read_text().strip()
        credential_role = "readonly" if authorization == "Bearer " + readonly else "none-or-wrong"
        with (root / "observations.jsonl").open("a") as handle:
            handle.write(json.dumps({"path": self.path, "credentialRole": credential_role, "cookiePresent": "Cookie" in self.headers, "authorizationKind": authorization.split(" ")[0] if authorization else "none"}) + "\n")
        public = self.path.startswith("/public-json/")
        if not public and credential_role != "readonly":
            self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="rightclick-observer-fixture"'); self.end_headers(); return
        challenge = urllib.parse.unquote(self.path.split("/")[-1])
        if challenge == "redirect":
            self.send_response(302); self.send_header("Location", "http://127.0.0.1:" + (root / "trap-port").read_text() + "/stolen"); self.end_headers(); return
        if not challenge or not all(c.isascii() and (c.isalnum() or c == "-") for c in challenge): self.send_error(400); return
        try: artifact = (root / "records" / challenge).read_bytes()
        except FileNotFoundError: self.send_error(404); return
        body = {"challenge": challenge, "result": hashlib.sha256(artifact).hexdigest(), "machine": "disposable-native-http-fixture", "observation": "independent-file-sha256",
            "observerPrincipal": "fixture-readonly", "platform": "fixture", "principal": "fixture-writer", "uid": None}
        if (root / "include-invocation").exists():
            marker = root / "records" / (challenge + ".invocation")
            if marker.exists(): body["invocationID"] = marker.read_text()
        echo = root / "echo-observer-credential"
        mode = echo.read_text() if echo.exists() else "none"
        if mode == "raw" or mode == "json-unicode": body["machine"] = readonly
        elif mode == "base64": body["machine"] = base64.b64encode(readonly.encode()).decode()
        elif mode == "base64url": body["machine"] = base64.urlsafe_b64encode(readonly.encode()).decode().rstrip("=")
        elif mode == "base64-authorization": body["machine"] = base64.b64encode(("Bearer " + readonly).encode()).decode()
        elif mode == "hex": body["machine"] = readonly.encode().hex()
        if challenge == "extra": body["undeclared"] = "rejected"
        response_text = json.dumps(body)
        if mode == "json-unicode":
            escaped = '"' + ''.join('\\u%04x' % ord(c) for c in readonly) + '"'
            response_text = response_text.replace(json.dumps(readonly), escaped)
        response = response_text.encode(); self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "rightclick-injected=must-not-persist; Path=/")
        self.send_header("Content-Length", str(len(response))); self.end_headers(); self.wfile.write(response)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
# Closing a staged same-directory file before replacement makes existence of
# the published path mean that its complete port value is available.
published_port = root / (role + "-port")
staged_port = root / (role + "-port.pending")
staged_port.write_text(str(server.server_address[1]), encoding="ascii")
staged_port.replace(published_port)
server.serve_forever()
