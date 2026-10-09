#!/usr/bin/env python3
"""Disposable independent observer that waits behind an explicit test gate."""
import argparse
import http.server
from pathlib import Path
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--state-dir", type=Path, required=True)
args = parser.parse_args()


class Observer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        (args.state_dir / "observer-started").write_text("started")
        deadline = time.monotonic() + 10
        while not (args.state_dir / "release").exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"wanted")
        (args.state_dir / "observer-finished").write_text("finished")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Observer)
# Publish readiness only after all port bytes are present. An existence-only
# reader must never see the empty file created by write_text before its write.
pending_port = args.state_dir / "port.pending"
pending_port.write_text(str(server.server_port))
pending_port.replace(args.state_dir / "port")
server.serve_forever()
