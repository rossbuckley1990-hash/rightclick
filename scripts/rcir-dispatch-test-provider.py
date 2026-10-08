#!/usr/bin/env python3
"""Disposable actual HTTP provider for native dispatch fault controls."""
import hashlib, http.server, json, pathlib, sys
from fixture_http import LoopbackHTTPServer
out=pathlib.Path(sys.argv[1]); out.mkdir(parents=True,exist_ok=True)
values={}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        if self.path == '/openapi.json':
            spec=out/'spec.json'
            data=spec.read_bytes() if spec.exists() else None
            with (out/'spec-observations.jsonl').open('a') as f:
                f.write(json.dumps({'path':self.path,'sha256':hashlib.sha256(data).hexdigest() if data else None})+'\n')
            self.send_response(200 if data else 404)
            self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(data or b'missing'); return
        ident=self.path.removeprefix('/records/')
        if (out/'cookie-required.json').exists():
            cookie=json.loads((out/'cookie-required.json').read_text())
            received=(cookie['name']+'='+cookie['value']) in self.headers.get('Cookie','').split('; ')
            with (out/'observations.jsonl').open('a') as f:
                f.write(json.dumps({'path':self.path,'disposableAuthCookieReceived':received})+'\n')
            if not received:
                self.send_response(401); self.end_headers(); self.wfile.write(b'credential required'); return
        self.send_response(200 if ident in values else 404)
        self.send_header('Content-Type','text/plain'); self.end_headers()
        self.wfile.write(values.get(ident,'missing').encode())
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (out/'effects.jsonl').open('a') as f:
            f.write(json.dumps({'path':self.path,'body':body,'taskID':self.headers.get('X-RightClick-Invocation')})+'\n')
        values[body['id']]=body['value']
        if body['id']=='drop-response':
            # Preserve the after-effect response-loss control without replay.
            self.close_connection=True
            return
        if (out/'drift-after-write').exists():
            spec=json.loads((out/'spec.json').read_text()); spec['info']['version']='2'
            (out/'spec.tmp').write_text(json.dumps(spec)); (out/'spec.tmp').replace(out/'spec.json')
        self.send_response(200); self.send_header('Content-Type','application/json')
        if (out/'cookie-required.json').exists():
            cookie=json.loads((out/'cookie-required.json').read_text())
            self.send_header('Set-Cookie',cookie['name']+'='+cookie['value']+'; Path=/records; SameSite=Strict')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
server=LoopbackHTTPServer(('127.0.0.1',0),Handler)
(out/'port.tmp').write_text(str(server.server_address[1]))
(out/'port.tmp').replace(out/'port')
server.serve_forever()
