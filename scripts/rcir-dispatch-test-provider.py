#!/usr/bin/env python3
"""Disposable actual HTTP provider for native dispatch fault controls."""
import http.server, json, pathlib, sys
out=pathlib.Path(sys.argv[1]); out.mkdir(parents=True,exist_ok=True)
values={}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        ident=self.path.removeprefix('/records/')
        self.send_response(200 if ident in values else 404)
        self.send_header('Content-Type','text/plain'); self.end_headers()
        self.wfile.write(values.get(ident,'missing').encode())
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (out/'effects.jsonl').open('a') as f:
            f.write(json.dumps({'path':self.path,'body':body,'taskID':self.headers.get('X-RightClick-Invocation')})+'\n')
        values[body['id']]=body['value']
        if body['id']=='drop-response':
            # Deliberate fixture fault after the durable effect log, before any
            # acceptance response. The production transport must retain unknown
            # and must not send another mutation to recover the missing reply.
            self.close_connection=True
            return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
(out/'port.tmp').write_text(str(server.server_address[1]))
(out/'port.tmp').replace(out/'port')
server.serve_forever()
