#!/usr/bin/env python3
"""Loopback MCP fixture recording authority presence, never header contents."""
import http.server
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
injected_cookie_name = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 65536:
            self.send_error(413)
            return
        request = json.loads(self.rfile.read(size))
        method = request.get("method")
        with (directory / "requests.jsonl").open("a") as log:
            log.write(json.dumps({"method": method, "cookiePresent": bool(self.headers.get("Cookie")),
                                  "authorizationPresent": bool(self.headers.get("Authorization"))}) + "\n")
        if method == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "Independent adoption fixture", "version": "1"}}
        elif method == "tools/list":
            schema = {"type": "object", "additionalProperties": False,
                      "properties": {"value": {"type": "string"}}, "required": ["value"]}
            result = {"tools": [{"name": "echo", "inputSchema": schema, "outputSchema": schema}]}
        elif method == "notifications/initialized":
            result = {}
        else:
            self.send_error(400)
            return
        response = {"jsonrpc": "2.0", "result": result}
        if "id" in request:
            response["id"] = request["id"]
        body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Set-Cookie", injected_cookie_name + "=unrelated-authority; Path=/")
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(directory / "port").write_text(str(server.server_address[1]))
server.serve_forever()
