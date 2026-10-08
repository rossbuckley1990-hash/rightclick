#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Test-owned real HTTP servers record only dummy-authority matches and closed
/// header facts. No provider response is used as independent semantic proof.
final class CredentialIsolationHTTPFixture {
    let directory: URL, base: URL, realm: String, cookieName: String, responseCookieName: String
    let process: Process
    static let dummyUser = "rightclick-h6-dummy-user"
    static let dummyPassword = "rightclick-h6-dummy-password"
    static let dummyBearer = "rightclick-h6-explicit-dummy-bearer"

    init(tls: Bool = false) throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("h6-http-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        let ownedRoot = directory
        var initialized = false, launched: Process?
        defer {
            if !initialized {
                if let launched { try? Self.stop(launched) }
                try? FileManager.default.removeItem(at: ownedRoot)
            }
        }
        realm = "h6-realm-" + UUID().uuidString
        cookieName = "h6-ambient-" + UUID().uuidString
        responseCookieName = "h6-response-" + UUID().uuidString
        let script = directory.appendingPathComponent("provider.py")
        try NativeHTTPFixture.writePrivate(Data(Self.python.utf8), to: script)
        if tls {
            let config = directory.appendingPathComponent("tls.conf")
            try NativeHTTPFixture.writePrivate(Data("[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=v3\n[subject]\nCN=127.0.0.1\n[v3]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n".utf8), to: config)
            _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
                arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", config.path,
                            "-keyout", directory.appendingPathComponent("tls-key.private").path,
                            "-out", directory.appendingPathComponent("certificate.pem").path], timeout: 10, maximumBytes: 4096)
            try NativeHTTPFixture.protect(directory.appendingPathComponent("tls-key.private"))
            _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
                arguments: ["x509", "-in", directory.appendingPathComponent("certificate.pem").path, "-outform", "DER",
                            "-out", directory.appendingPathComponent("certificate.der").path], timeout: 3, maximumBytes: 4096)
        }
        process = Process(); process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [script.path, directory.path, realm, cookieName, responseCookieName, tls ? "tls" : "http"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        launched = process
        try NativeHTTPFixture.runFixture(process)
        let port = try NativeHTTPFixture.waitForPort(directory.appendingPathComponent("port"), process: process)
        base = try XCTUnwrap(URL(string: "\(tls ? "https" : "http")://127.0.0.1:\(port)"))
        initialized = true
    }

    private static func stop(_ process: Process) throws {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                // Only this exact owned leaf PID; the fixture starts no children.
                _ = kill(process.processIdentifier, SIGKILL)
                let killDeadline = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            }
            guard !process.isRunning else { throw RightClickError("Owned HTTP fixture did not terminate within its bound.") }
            process.waitUntilExit()
        }
    }

    func close() throws {
        try Self.stop(process)
        try FileManager.default.removeItem(at: directory)
    }

    func rows(_ filename: String = "requests.jsonl") throws -> [[String: Any]] {
        try FixtureLineFraming.objects(at: directory.appendingPathComponent(filename))
    }

    func card(endpoint: String = "/a2a") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": "0.2.6", "name": "Owned credential isolation agent",
            "url": base.absoluteString + endpoint, "preferredTransport": "JSONRPC", "defaultInputModes": ["text/plain"],
            "defaultOutputModes": ["text/plain"], "skills": [["id": "proof", "name": "Proof", "description": "Dummy task", "tags": ["fixture"]]]])
    }

    static let python = #"""
import base64,json,os,pathlib,ssl,sys,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=pathlib.Path(sys.argv[1]);realm,cookie,response_cookie,mode=sys.argv[2:6]
basic='Basic '+base64.b64encode(b'rightclick-h6-dummy-user:rightclick-h6-dummy-password').decode()
bearer='Bearer rightclick-h6-explicit-dummy-bearer'
os.umask(0o077);lock=threading.Lock()
def record(name,row):
 with lock:
  with (root/name).open('a',encoding='utf-8') as stream:stream.write(json.dumps(row,sort_keys=True)+'\n')
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def reply(self,status,obj=None,extra=None):
  data=b'' if obj is None else json.dumps(obj,sort_keys=True).encode()
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)))
  for k,v in (extra or {}).items():self.send_header(k,v)
  self.end_headers();self.wfile.write(data)
 def measured(self,method):
  authorization=self.headers.get('Authorization','');cookies=self.headers.get('Cookie','')
  record('requests.jsonl',{'path':self.path,'rpc':method,'cookiePresent':bool(cookies),
    'ambientCookieMatched':cookie+'=owned-dummy-cookie' in cookies,
    'authorizationKind':authorization.split(' ',1)[0] if authorization else 'none',
    'ambientBasicMatched':authorization==basic,'explicitBearerMatched':authorization==bearer,
    'sessionPresent':self.headers.get('MCP-Session-Id')=='h6-owned-session',
    'invocationPresent':bool(self.headers.get('X-RightClick-Invocation'))})
 def do_GET(self):
  self.measured('ambient-control')
  if self.path!='/ambient-control':return self.reply(404)
  if self.headers.get('Authorization')!=basic:return self.reply(401,extra={'WWW-Authenticate':'Basic realm="'+realm+'"'})
  self.reply(200,{'ok':True})
 def do_POST(self):
  count=int(self.headers.get('Content-Length','0'))
  if not 0<count<=16384:return self.reply(413)
  body=json.loads(self.rfile.read(count));method=body.get('method','');self.measured(method)
  if self.path.endswith('-challenge') and self.headers.get('Authorization')!=basic:
   return self.reply(401,extra={'WWW-Authenticate':'Basic realm="'+realm+'"'})
  if self.path=='/mcp-redirect':return self.reply(302,extra={'Location':(root/'redirect-target').read_text(encoding='utf-8')})
  if self.path=='/mcp-authorized' and self.headers.get('Authorization')!=bearer:return self.reply(403)
  result=None
  if method=='message/send':
   record('effects.jsonl',{'method':method,'invocationPresent':bool(self.headers.get('X-RightClick-Invocation'))})
   result={'kind':'task','id':'owned-h6-task','status':{'state':'submitted'}}
  elif method=='tasks/get':result={'kind':'task','id':'owned-h6-task','status':{'state':'completed'},'artifacts':[{'parts':[{'kind':'text','text':'owned result'}]}]}
  elif method=='initialize':result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'owned-h6','version':'1'}}
  elif method=='notifications/initialized':return self.reply(200)
  elif method=='tools/list':result={'tools':[{'name':'echo','inputSchema':{'type':'object','properties':{'message':{'type':'string'}},'required':['message'],'additionalProperties':False},'outputSchema':{'type':'object','properties':{'message':{'type':'string'}},'required':['message'],'additionalProperties':False}}]}
  elif method=='tools/call':
   record('effects.jsonl',{'method':method,'sessionPresent':self.headers.get('MCP-Session-Id')=='h6-owned-session'})
   result={'isError':False,'structuredContent':body['params']['arguments']}
  else:return self.reply(400)
  self.reply(200,{'jsonrpc':'2.0','id':body['id'],'result':result},{'MCP-Session-Id':'h6-owned-session','Set-Cookie':response_cookie+'=must-not-persist; Path=/'})
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
if mode=='tls':
 context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(root/'certificate.pem',root/'tls-key.private');server.socket=context.wrap_socket(server.socket,server_side=True)
(root/'port').write_text(str(server.server_address[1]),encoding='ascii');server.serve_forever()
"""#
}

#endif
