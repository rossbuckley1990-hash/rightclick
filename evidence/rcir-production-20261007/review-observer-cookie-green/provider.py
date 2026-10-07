import http.server,json,pathlib,sys
out=pathlib.Path(sys.argv[1]); values={}
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); values[body['id']]=body['value']
  with (out/'effects.jsonl').open('a') as f: f.write(json.dumps({'id':body['id']})+'\n')
  self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Set-Cookie','RCIR_REVIEW_DISPOSABLE_SESSION=synthetic; Path=/'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
 def do_GET(self):
  ident=self.path.removeprefix('/records/'); authorised='RCIR_REVIEW_DISPOSABLE_SESSION=synthetic' in (self.headers.get('Cookie') or '')
  with (out/'observations.jsonl').open('a') as f: f.write(json.dumps({'path':self.path,'disposableAuthCookieReceived':authorised})+'\n')
  self.send_response(200 if authorised else 401); self.send_header('Content-Type','text/plain'); self.end_headers(); self.wfile.write(values.get(ident,'missing').encode() if authorised else b'authority required')
server=http.server.HTTPServer(('127.0.0.1',0),Handler); (out/'port').write_text(str(server.server_address[1])); server.serve_forever()
