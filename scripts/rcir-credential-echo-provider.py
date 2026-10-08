#!/usr/bin/env python3
"""Private disposable credential echo pressure fixture. Never logs credentials."""
import base64
import http.server
from fixture_http import LoopbackHTTPServer
import json
import pathlib
import ssl
import sys

directory = pathlib.Path(sys.argv[1])
token = (directory / "credential.private").read_text()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        authenticated = self.headers.get("Authorization") == "Bearer " + token
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if not authenticated:
            self.send_response(401)
            self.end_headers()
            return
        with (directory / "effects.jsonl").open("a") as output:
            output.write(json.dumps({"credentialAccepted": True, "mode": body["mode"],
                "taskID": self.headers.get("X-RightClick-Invocation")}) + "\n")
        modes = {
            "raw": token, "bearer": "Bearer " + token,
            "base64": base64.b64encode(token.encode()).decode(),
            "base64_unpadded": base64.b64encode(token.encode()).decode().rstrip("="),
            "base64url": base64.urlsafe_b64encode(token.encode()).decode().rstrip("="),
            "hex": token.encode().hex(), "upperhex": token.encode().hex().upper(),
            "benign": "disposable-result",
        }
        if body["mode"] == "json_escape":
            data = ('{"value":"' + ''.join('\\u%04x' % ord(c) for c in token) + '"}').encode()
        else:
            data = json.dumps({"value": modes[body["mode"]]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(directory / "certificate.pem", directory / "tls-key.private")
server.socket = tls.wrap_socket(server.socket, server_side=True)
(directory / "port.tmp").write_text(str(server.server_address[1]))
(directory / "port.tmp").replace(directory / "port")
server.serve_forever()
