#!/usr/bin/env python3
"""Compare safe existing OpenAPI/Core7 behavior against an immutable binary.

Disposable private loopback provider; no provider secrets or user data. New RCIR
and contract-pin features are checked when advertised, not required of 0.2.2.
"""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT=Path(__file__).resolve().parents[1]
module=importlib.util.spec_from_file_location('verifier',ROOT/'scripts/verify-rcir-receipt.py')
verifier=importlib.util.module_from_spec(module); module.loader.exec_module(verifier)
CORE={'context_runtime','context_providers','context_inspect','context_actions','context_explain','context_run','context_run_status'}


def main():
    baseline,candidate,evidence=map(lambda p:Path(p).resolve(),sys.argv[1:4])
    evidence.mkdir(parents=True,exist_ok=True)
    events=[]; sessions=[]
    body_schema={'type':'object','additionalProperties':False,'required':['value','priority'],
        'properties':{'value':{'type':'string'},'priority':{'type':'string','enum':['low','high']}}}
    result_schema={'type':'object','additionalProperties':False,'required':['value'],
        'properties':{'value':{'type':'string'}}}
    def operation(name,kind='json',path=False,unsupported=None):
        value={'operationId':name,'summary':name,'responses':{'200':{'description':'Accepted','content':{
            'text/plain' if kind=='text' else 'application/json':{'schema':{'type':'string'} if kind=='text' else result_schema}}}}}
        if name!='Read path':
            value['requestBody']={'required':True,'content':{
                'text/plain' if kind=='text' else 'application/json':{'schema':{'type':'string'} if kind=='text' else body_schema}}}
        if path:value['parameters']=[{'name':'id','in':'path','required':True,'schema':{'type':'string'}}]
        if unsupported:value['parameters']=[{'name':'variation','in':unsupported,'required':False,'schema':{'type':'string'}}]
        return value
    descriptor={'openapi':'3.0.3','info':{'title':'Private release compatibility','version':'1'},'paths':{
        '/text':{'post':operation('Write text','text')},
        '/record':{'post':operation('Write JSON')},
        '/records/{id}':{'get':operation('Read path',path=True)},
        '/combined/{id}':{'post':operation('Write combined',path=True)},
        '/query':{'post':operation('Query variation',unsupported='query')},
        '/header':{'post':operation('Header variation',unsupported='header')},
        '/cookie':{'post':operation('Cookie variation',unsupported='cookie')},
        '/protected':{'post':dict(operation('Missing provider authority'),security=[{'DisposableBearer':[]}])}},
        'components':{'securitySchemes':{'DisposableBearer':{'type':'http','scheme':'bearer'}}}}
    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def reply(self,data,kind='application/json'):
            payload=data.encode() if kind=='text/plain' else json.dumps(data,sort_keys=True,separators=(',',':')).encode()
            self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(payload)))
            self.end_headers();self.wfile.write(payload)
        def do_GET(self):
            if self.path=='/openapi.json':self.reply(descriptor);return
            self.invoke()
        def do_POST(self):self.invoke()
        def invoke(self):
            body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
            parsed=json.loads(body) if self.headers.get('Content-Type','').startswith('application/json') else None
            events.append({'method':self.command,'path':self.path,'contentType':self.headers.get('Content-Type'),
                'body':body,'JSONBody':parsed,'taskID':self.headers.get('X-RightClick-Invocation')})
            if self.path=='/text':self.reply(body,'text/plain')
            elif self.command=='GET':self.reply({'value':urllib.parse.unquote(self.path.rsplit('/',1)[-1])})
            else:self.reply({'value':parsed['value']})
    provider=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
    threading.Thread(target=provider.serve_forever,daemon=True).start()
    provider_base='http://127.0.0.1:'+str(provider.server_port)
    def stop(process):
        process.terminate()
        try:process.wait(timeout=10)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=10)
    try:
        with tempfile.TemporaryDirectory(prefix='rightclick-core-compat-') as temporary:
            private_dir=Path(temporary);os.chmod(private_dir,0o700)
            private=Ed25519PrivateKey.generate();key=private_dir/'signer.private'
            key.write_bytes(private.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption()));os.chmod(key,0o600)
            pin=evidence/'trusted-public-key.raw';pin.write_bytes(private.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw))
            config=private_dir/'policy.json';config.write_text(json.dumps({'version':1,'revision':'compatibility-1','deniedCapabilities':[],'signingKeyFile':str(key)}));os.chmod(config,0o600)
            env={k:v for k,v in os.environ.items() if not k.startswith('RIGHTCLICK_')}
            env.update(RIGHTCLICK_EXPERIENCE='off',RIGHTCLICK_RCIR_CONFIG=str(config),RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([
                {'id':'private-release-compatibility','kind':'openapi','specificationURL':provider_base+'/openapi.json','baseURL':provider_base}]))
            def exercise(request,label,transport,binary):
                seq=0;cases=[]
                def rpc(method,params):
                    nonlocal seq
                    seq+=1;reply=request({'jsonrpc':'2.0','id':seq,'method':method,'params':params})
                    assert 'error' not in reply,'Protocol error';return reply['result']
                def call(name,args):
                    reply=rpc('tools/call',{'name':name,'arguments':args})
                    if reply.get('isError'):return {'toolError':reply['content'][0]['text']}
                    return json.loads(reply['content'][0]['text'])
                rpc('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'private-compatibility-control','version':'1'}})
                tools=rpc('tools/list',{})['tools'];assert {t['name'] for t in tools}==CORE
                runtime=call('context_runtime',{});assert runtime['executableSHA256']==hashlib.sha256(binary.read_bytes()).hexdigest() and runtime['transport']==transport
                call('context_providers',{});call('context_inspect',{'item':'safe-text'})
                actions=call('context_actions',{'item':'safe-text'})['actions']
                actions={a['title']:a for a in actions if a.get('provider',{}).get('name')=='Private release compatibility'}
                for title,arguments,expected_output,path in [
                    ('Write text',None,'safe-text','/text'),
                    ('Write JSON',{'value':'safe-json','priority':'high'},'{"value":"safe-json"}','/record'),
                    ('Read path',{'id':'name with space-é'},'{"value":"name with space-é"}','/records/name%20with%20space-%C3%A9'),
                    ('Write combined',{'id':'part with space','value':'safe-combined','priority':'low'},'{"value":"safe-combined"}','/combined/part%20with%20space')]:
                    action=actions[title];call('context_explain',{'item':'safe-text','actionId':action['id']})
                    args={'item':'safe-text','actionId':action['id']}
                    if arguments is not None:args['arguments']=arguments
                    start=len(events);gated=call('context_run',args)
                    assert gated['state']=='awaiting_user' and len(events)==start,title+' confirmation control'
                    malformed=call('context_run',dict(args,confirmed=True,arguments={'unexpected':'field'}))
                    malformed_effects=len(events)-start
                    if label=='baseline' and title=='Write text' and malformed['state']=='accepted':
                        assert malformed_effects==1 and events[-1]['body']=='safe-text','Baseline undeclared text argument behavior'
                    else:
                        assert malformed['state'] in ['failed','rejected','unavailable'] and malformed_effects==0,title+' malformed control'
                    print(json.dumps({'control':label+' '+transport+' '+title,'malformedState':malformed['state'],'malformedActualRequests':malformed_effects}),flush=True)
                    start=len(events)
                    pin_control=None
                    if action.get('contractSHA256'):
                        bad=call('context_run',dict(args,confirmed=True,contractSHA256='0'*64))
                        assert bad['state'] in ['rejected','unavailable'] and len(events)==start,title+' changed pin control'
                        pin_control=bad['state'];args['contractSHA256']=action['contractSHA256']
                    record=call('context_run',dict(args,confirmed=True))
                    assert record['state']=='accepted' and len(events)==start+1,title+' legal invocation'
                    actual=events[-1]
                    assert actual['path']==path,title+' request target'
                    expected_body='' if title=='Read path' else 'safe-text' if title=='Write text' else json.dumps({k:v for k,v in arguments.items() if k!='id'},sort_keys=True,separators=(',',':'))
                    assert actual['body']==expected_body,title+' exact body'
                    assert record['output']==expected_output,title+' retained result'
                    assert not record.get('evidence',{}).get('outcomeVerified',False),title+' unverified control'
                    status=call('context_run_status',{'executionId':record['executionId']})
                    assert status['state']==record['state'] and status['output']==record['output'],title+' status'
                    rcir=record.get('rcir');verified=False
                    if rcir:
                        assert rcir['leaseConsumed'] and rcir['outcome']=='unverified' and actual['taskID']==rcir['taskID']
                        assert status['rcir']==rcir
                        receipt=evidence/(label+'-'+transport+'-'+title.lower().replace(' ','-')+'-receipt.json')
                        receipt.write_text(json.dumps(rcir['signedReceipt'],indent=2)+'\n')
                        verifier.verify(receipt,pin,expected_outcome='unverified');verified=True
                    cases.append({'title':title,'record':record,'actualRequest':actual,'confirmation':gated['state'],'malformed':malformed['state'],
                        'malformedActualRequests':malformed_effects,'exactBody':True,'retainedResult':True,'statusMatches':True,'wrongPinDenied':pin_control,'independentSignedCorrelation':verified})
                    print(json.dumps({'progress':label+' '+transport+' '+title,'state':record['state']}),flush=True)
                variations=[]
                for title in ['Query variation','Header variation','Cookie variation','Missing provider authority']:
                    a=actions[title];call('context_explain',{'item':'safe-text','actionId':a['id']});before=len(events)
                    result=call('context_run',{'item':'safe-text','actionId':a['id'],'confirmed':True,'arguments':{'value':'safe','priority':'low'}})
                    requests=len(events)-before
                    if title=='Missing provider authority':
                        assert result['state'] not in ['accepted','succeeded','started'] and requests==0,title+' abstention'
                    else:
                        assert result['state']=='accepted' and requests==1,title+' omitted optional parameter'
                        assert events[-1]['body']=='{\"priority\":\"low\",\"value\":\"safe\"}' and events[-1]['path']=='/'+title.split()[0].lower()
                        before_extra=len(events)
                        extra=call('context_run',{'item':'safe-text','actionId':a['id'],'confirmed':True,'arguments':{'value':'safe','priority':'low','variation':'bounded'}})
                        assert extra['state']=='failed' and len(events)==before_extra,title+' unsupported argument control'
                    variations.append({'title':title,'state':result['state'],'action':a,'result':result,'providerRequests':requests,'optionalParameterArgumentRejected':title!='Missing provider authority'})
                sessions.append({'label':label,'transport':transport,'runtime':runtime,'cases':cases,'parameterAndAuthorityVariations':variations,'CoreTools':sorted(CORE)})
                (evidence/(label+'-'+transport+'-session.json')).write_text(json.dumps(sessions[-1],indent=2,sort_keys=True)+'\n')
            for label,binary in [('baseline',baseline),('candidate',candidate)]:
                with (evidence/(label+'-stdio.stderr.log')).open('w') as errors:
                    process=subprocess.Popen([str(binary),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,text=True,encoding='utf-8',bufsize=1,env=env)
                    replies=queue.Queue()
                    def reader(p=process,q=replies):
                        for line in p.stdout:q.put(json.loads(line))
                        q.put(None)
                    threading.Thread(target=reader,daemon=True).start()
                    def stdio(payload,p=process,q=replies):
                        p.stdin.write(json.dumps(payload)+'\n');p.stdin.flush()
                        while True:
                            response=q.get(timeout=45);assert response is not None,'stdio ended'
                            if response.get('id')==payload['id']:return response
                    try:exercise(stdio,label,'stdio',binary)
                    finally:stop(process)
                with socket.socket() as port_socket:port_socket.bind(('127.0.0.1',0));port=port_socket.getsockname()[1]
                token=os.urandom(32).hex();httpenv=dict(env,RIGHTCLICK_MCP_TOKEN=token)
                with (evidence/(label+'-http.stderr.log')).open('w') as errors:
                    process=subprocess.Popen([str(binary),'mcp','--http','--port',str(port)],stdout=subprocess.DEVNULL,stderr=errors,env=httpenv)
                    try:
                        for _ in range(200):
                            try:
                                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                            except OSError:time.sleep(.1)
                        else:raise RuntimeError('listener did not start')
                        def http_request(payload,bearer=token):
                            headers={'Content-Type':'application/json','Accept':'application/json','MCP-Protocol-Version':'2025-03-26'}
                            if bearer is not None:headers['Authorization']='Bearer '+bearer
                            query=urllib.request.Request('http://127.0.0.1:'+str(port)+'/mcp',json.dumps(payload).encode(),headers)
                            with urllib.request.urlopen(query,timeout=45) as response:return json.load(response)
                        for invalid in [None,'wrong-disposable-token']:
                            before=len(events)
                            try:http_request({'jsonrpc':'2.0','id':1,'method':'tools/list','params':{}},invalid);raise AssertionError('Invalid token accepted')
                            except urllib.error.HTTPError as error:assert error.code==401 and len(events)==before
                        exercise(http_request,label,'http',binary);sessions[-1]['missingAndWrongHTTPTokenDenied']=True
                    finally:stop(process)
        comparisons=[]
        for transport in ['stdio','http']:
            old=next(s for s in sessions if s['label']=='baseline' and s['transport']==transport)
            new=next(s for s in sessions if s['label']=='candidate' and s['transport']==transport)
            for before,after in zip(old['cases'],new['cases']):
                assert before['title']==after['title']
                assert before['record']['state']==after['record']['state'] and before['record']['output']==after['record']['output']
                assert before['actualRequest']['body']==after['actualRequest']['body'] and before['actualRequest']['path']==after['actualRequest']['path']
                comparisons.append({'transport':transport,'title':before['title'],'behaviorPreserved':True,'newSignedEvidence':after['independentSignedCorrelation'] and not before['independentSignedCorrelation'],'newContractPin':after['wrongPinDenied'] is not None and before['wrongPinDenied'] is None,'undeclaredTextArgumentsNowRejected':before['title']=='Write text' and before['malformedActualRequests']>0 and after['malformedActualRequests']==0})
            for old_variation,new_variation in zip(old['parameterAndAuthorityVariations'],new['parameterAndAuthorityVariations']):
                assert old_variation['title']==new_variation['title'] and old_variation['state']==new_variation['state'] and old_variation['providerRequests']==new_variation['providerRequests']
        report={'status':'PASS','introducedLosses':[],'sessions':sessions,'comparisons':comparisons,'actualProviderInvocations':len(events),'actualProviderRequests':events,
            'scope':'Actual published installed0.2.2 and exact candidate6642 public Core7, stdio and authenticated loopback HTTP. Supported text/JSON body/path/path+JSON; optional query/header/cookie omission controls and missing-bearer abstention. No system TLS trust change or actual provider bearer token provisioned.',
            'inheritedMissingFunction':['Installed0.2.2 lacks OpenAPI RCIR receipt/task correlation and advertised caller contract-pin control on this tested public path.','0.2.2 ignores undeclared arguments on text-body operations; candidate rejects them before dispatch (input-contract hardening, not a supported safe-function loss).','Optional query/header/cookie omission on JSON-body operations remains accepted; supplying these as body arguments fails in both, so native parameter transport support is not claimed.','Unavailable HTTP-origin bearer stays non-invokable in both versions.','Authenticated public invocation subject/audience attachment remains missing; not implemented by this comparison.'],
            'notProved':['Live credential-backed product TLS/public session compatibility without fixture bridge.','All provider substrates/all OS release acceptance.','Issuer downscope, caller-specific policy or individual AI principal.']}
        (evidence/'summary.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
        print(json.dumps({'status':'PASS','introducedLosses':[],'supportedComparisons':len(comparisons),'actualProviderInvocations':len(events),'actualProviderRequests':events,'newSignedReceipts':sum(c['newSignedEvidence'] for c in comparisons),'newPinControls':sum(c['newContractPin'] for c in comparisons)}))
        return 0
    finally:provider.shutdown()


if __name__=='__main__':raise SystemExit(main())
