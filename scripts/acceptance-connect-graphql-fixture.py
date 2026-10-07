#!/usr/bin/env python3
"""Real connected GraphQL transport and acquisition bounds; logs presence only."""
import http.server
import json
from pathlib import Path
import sys
import time

directory = Path(sys.argv[1])
cookie_name = sys.argv[2]
schema = {"data": {"__schema": {"queryType": {"name": "Query"}, "types": [
    {"kind": "OBJECT", "name": "Query", "fields": [
        {"name": "current", "args": [], "type": {"kind": "SCALAR", "name": "String"}}]},
    {"kind": "SCALAR", "name": "String"}]}}}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 65536:
            self.send_error(413)
            return
        request = json.loads(self.rfile.read(size))
        with (directory / "requests.jsonl").open("a") as log:
            log.write(json.dumps({"path": self.path, "operation": request.get("operationName"),
                                  "cookiePresent": bool(self.headers.get("Cookie")),
                                  "authorizationPresent": bool(self.headers.get("Authorization"))}) + "\n")
        if self.path == "/oversize":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(16_777_217))
            self.end_headers()
            # CFNetwork defers a headers-only response callback until its first
            # body byte or EOF. Flush one byte to deliver headers, then stall the
            # remaining declared body. The size cap must reject before completion.
            try:
                self.wfile.write(b"{")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(2)
            return
        body = json.dumps(schema if request.get("operationName") == "RightClickIntrospection"
                          else {"data": {"rightclickResult": "accepted"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Set-Cookie", cookie_name + "=unrelated-authority; Path=/")
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(directory / "port").write_text(str(server.server_address[1]))
server.serve_forever()
