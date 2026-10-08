#!/usr/bin/env python3
"""Independent observer process; no A2A response or artifact chooses its result."""
import argparse
import json
import pathlib
from http.server import BaseHTTPRequestHandler
from fixture_http import LoopbackThreadingHTTPServer
from urllib.parse import unquote

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=pathlib.Path)
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            if not self.path.startswith("/observations/") or len(self.path) > 262144:
                raise ValueError("unsupported observation")
            message = unquote(self.path[len("/observations/"):])
            challenge = json.loads(message)["challenge"]
            if not challenge or not challenge.isascii() or not all(c.isalnum() or c == "-" for c in challenge):
                raise ValueError("invalid challenge")
            with (args.directory / "observation-attempts.jsonl").open("a") as handle:
                handle.write(json.dumps({"challenge": challenge, "invocation": self.headers.get("X-RightClick-Invocation")}, sort_keys=True) + "\n")
            result = (args.directory / "effects" / challenge).read_bytes()
            if len(result) > 65536:
                raise ValueError("bounded observation required")
            with (args.directory / "observations.jsonl").open("a") as handle:
                handle.write(json.dumps({"challenge": challenge, "observed": result.decode(),
                                         "invocation": self.headers.get("X-RightClick-Invocation")}, sort_keys=True) + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)
        except (ValueError, KeyError, FileNotFoundError):
            self.send_error(404)

server = LoopbackThreadingHTTPServer(("127.0.0.1", args.port), Handler)
pending = args.directory / "observer-port.tmp"
pending.write_text(str(server.server_port))
pending.replace(args.directory / "observer-port")
server.serve_forever()
