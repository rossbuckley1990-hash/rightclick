#!/usr/bin/env python3
"""Actual loopback HTTP boundaries for native bounded transport tests."""
import http.server
from fixture_http import LoopbackThreadingHTTPServer
import pathlib
import sys
import time
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def do_GET(self):
        with (root / "requests.log").open("a") as record: record.write(self.path + "\n")
        if self.path == "/redirect":
            self.send_response(302); self.send_header("Location", "/trap"); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path == "/chunked-oversize":
            self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            try: self.wfile.write(b"40\r\n" + b"x" * 64 + b"\r\n1\r\nx\r\n0\r\n\r\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path == "/declared-oversize":
            self.send_response(200); self.send_header("Content-Length", "65"); self.end_headers()
            try: self.wfile.write(b"x" * 65)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path == "/early-close":
            self.send_response(200); self.send_header("Content-Length", "64"); self.end_headers()
            self.wfile.write(b"xx"); self.wfile.flush(); self.close_connection = True; return
        if self.path == "/slow": time.sleep(1)
        status, body = (500, b"native error") if self.path == "/error" else (200, b"x" * 64)
        self.send_response(status); self.send_header("Content-Length", str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = LoopbackThreadingHTTPServer(("127.0.0.1", 0), Handler)
pending = root / "port.tmp"
pending.write_text(str(server.server_address[1]))
pending.replace(root / "port")
server.serve_forever()
