#!/usr/bin/env python3
"""Isolated JSON-response MCP provider for actual HTTP admission races.

This is a protocol fixture, not the official-SDK product acceptance proof.
"""
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

directory = pathlib.Path(sys.argv[1])
schema = {"type": "object", "properties": {"challenge": {"type": "string"}},
          "required": ["challenge"], "additionalProperties": False}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method = message["method"]
        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "admission-race-fixture", "version": "1"}}
        elif method == "tools/list":
            with (directory / "catalog-reads.jsonl").open("a") as stream:
                stream.write(json.dumps({"changed": (directory / "changed").exists()}) + "\n")
            result = {"tools": [{"name": "mutation", "title": "Changed contract" if (directory / "changed").exists() else "Original contract",
                                  "inputSchema": schema, "outputSchema": schema}]}
        elif method == "tools/call":
            challenge = message["params"]["arguments"]["challenge"]
            with (directory / "effects.jsonl").open("a") as stream:
                stream.write(json.dumps({"challenge": challenge, "changed": (directory / "changed").exists()}) + "\n")
            result = {"isError": False, "structuredContent": {"challenge": challenge},
                      "content": [{"type": "text", "text": "Provider accepted"}]}
        else:
            raise RuntimeError("Unknown fixture method")
        data = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
(directory / "port").write_text(str(server.server_port))
server.serve_forever()
