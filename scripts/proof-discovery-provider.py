#!/usr/bin/env python3
"""Disposable loopback discovery provider. No credentials or remote exposure."""
import argparse
import http.server
from fixture_http import LoopbackThreadingHTTPServer
import json
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=0)
parser.add_argument("--operation", default="proof-v1")
parser.add_argument("--evidence", type=pathlib.Path, required=True)
args = parser.parse_args()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with args.evidence.open("a") as log:
            log.write(json.dumps({"path": self.path, "operation": args.operation}) + "\n")
        if self.path != "/openapi.json":
            self.send_error(404)
            return
        body = json.dumps({
            "openapi": "3.0.3",
            "info": {"title": "Disposable lifecycle provider", "version": "1"},
            "paths": {"/proof": {"get": {
                "operationId": args.operation,
                "responses": {"200": {"description": "proof", "content": {
                    "text/plain": {"schema": {"type": "string"}}
                }}}
            }}}
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *unused):
        pass


server = LoopbackThreadingHTTPServer(("127.0.0.1", args.port), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
