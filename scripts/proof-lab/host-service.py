#!/usr/bin/env python3
"""Small real host capability; observable effects live outside HTTP response."""
import getpass
import hashlib
import hmac
import json
import os
import platform
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

if len(sys.argv) > 1:
    os.environ.update(json.loads(Path(sys.argv[1]).read_text()))
ROOT = Path(os.environ.get("RIGHTCLICK_PROOF_EFFECTS", "/state"))
TOKEN = os.environ["RIGHTCLICK_PROOF_HOST_TOKEN"]
ORIGIN = os.environ.get("RIGHTCLICK_PROOF_HOST_ORIGIN", "http://127.0.0.1:19141")
ROOT.mkdir(parents=True, exist_ok=True)
if os.name == "nt":
    # Query the actual Windows process identity rather than inherited USERNAME.
    import ctypes
    name = ctypes.create_unicode_buffer(257)
    length = ctypes.c_ulong(257)
    if not ctypes.windll.advapi32.GetUserNameW(name, ctypes.byref(length)):
        raise ctypes.WinError()
    PRINCIPAL = name.value
else:
    try:
        PRINCIPAL = getpass.getuser()
    except KeyError:
        PRINCIPAL = str(os.getuid())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, status, data):
        raw = json.dumps(data, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self):
        return hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + TOKEN)

    def do_GET(self):
        if self.path == "/health":
            return self.send(200, {"platform": platform.system(), "machine": platform.machine()})
        if self.path == "/openapi.json":
            return self.send(200, {
                "openapi": "3.0.3", "info": {"title": "RIGHTCLICK isolated " + platform.system() + " service", "version": "1"},
                "servers": [{"url": ORIGIN}],
                "components": {"securitySchemes": {"proofBearer": {"type": "http", "scheme": "bearer"}}},
                "security": [{"proofBearer": []}],
                "paths": {"/proof": {"post": {
                    "operationId": "hostWriteProof", "summary": "Write a harmless isolated host proof effect",
                    "requestBody": {"required": True, "content": {"application/json": {"schema": {
                        "type": "object", "required": ["challenge"], "additionalProperties": False,
                        "properties": {"challenge": {"type": "string", "pattern": "^[A-Za-z0-9_-]{8,128}$"}}
                    }}}}, "responses": {"202": {"description": "Effect accepted; verify file independently"}}
                }}}
            })
        if self.path == "/authority-check" and self.authorized():
            protected = os.environ.get("RIGHTCLICK_PROOF_PROTECTED_PATH")
            if not protected:
                return self.send(404, {"error": "authority challenge unavailable"})
            try:
                Path(protected).read_bytes()
                denied = False
            except PermissionError:
                denied = True
            return self.send(200, {"principal": PRINCIPAL, "platform": platform.system(),
                                   "protectedReadDenied": denied})
        if self.path.startswith("/proof/") and self.authorized():
            challenge = self.path.removeprefix("/proof/")
            if re.fullmatch(r"[A-Za-z0-9_-]{8,128}", challenge):
                path = ROOT / (challenge + ".json")
                if path.exists():
                    return self.send(200, json.loads(path.read_text()))
            return self.send(404, {"error": "missing effect"})
        self.send(401 if not self.authorized() else 404, {"error": "unauthorized or missing"})

    def do_POST(self):
        if not self.authorized():
            return self.send(401, {"error": "unauthorized"})
        if self.path != "/proof":
            return self.send(404, {"error": "unknown capability"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 512:
                raise ValueError("bounded request required")
            payload = json.loads(self.rfile.read(length))
            challenge = payload["challenge"]
            if set(payload) != {"challenge"} or not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", challenge):
                raise ValueError("invalid challenge")
        except (ValueError, KeyError, TypeError):
            return self.send(400, {"error": "invalid challenge"})
        effect = {"challenge": challenge, "result": hashlib.sha256(("RIGHTCLICK:" + challenge).encode()).hexdigest(),
                  "platform": platform.system(), "machine": platform.machine(),
                  "uid": getattr(os, "getuid", lambda: None)(), "principal": PRINCIPAL}
        path = ROOT / (challenge + ".json")
        if path.exists():
            return self.send(409, {"error": "replayed challenge"})
        with path.open("x") as stream:
            json.dump(effect, stream, sort_keys=True)
        self.send(202, {"accepted": True, "challenge": challenge,
                        "verification": "Independent observer must read the host effect file"})


if __name__ == "__main__":
    ThreadingHTTPServer((os.environ.get("RIGHTCLICK_PROOF_BIND", "0.0.0.0"),
                         int(os.environ.get("RIGHTCLICK_PROOF_PORT", "8080"))), Handler).serve_forever()
