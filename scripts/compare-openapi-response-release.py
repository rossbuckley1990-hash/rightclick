#!/usr/bin/env python3
"""Actual safe OpenAPI error/argument/auth-scope comparison on public HTTP MCP."""
import hashlib,http.server,importlib.util,json,os,socket,subprocess,sys,tempfile,threading,time,urllib.error,urllib.request
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('receipt_verifier',ROOT/'scripts/verify-rcir-receipt.py')
verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
CORE={'context_runtime','context_providers','context_inspect','context_actions','context_explain','context_run','context_run_status'}

def main():
    baseline,candidate,evidence=map(lambda p:Path(p).resolve(),sys.argv[1:4]);evidence.mkdir(parents=True,exist_ok=True)
    # A retained immutable baseline directory avoids invoking the old binary
    # again. Check its manifest and session bytes before comparing fresh effects.
    baseline_provenance=None
    saved_baseline=None
    if baseline.is_dir():
        manifest_path=baseline/'manifest.json';session_path=baseline/'baseline-session.json'
        manifest=json.loads(manifest_path.read_text());raw=session_path.read_bytes()
        declared=next(row for row in manifest['artifacts'] if row['path']=='baseline-session.json')
        assert hashlib.sha256(raw).hexdigest()==declared['SHA256']
        saved_baseline=json.loads(raw)
        assert saved_baseline['runtime']['version']=='0.2.2'
        assert saved_baseline['runtime']['executableSHA256']==manifest['baseline']['SHA256']=='d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d'
        assert saved_baseline['label']=='baseline' and saved_baseline['CoreTools']==sorted(CORE)
        assert saved_baseline['wrongAndMissingHTTPBearerDenied'] and len(saved_baseline['cases'])==9
        (evidence/'baseline-session.json').write_bytes(raw)
        baseline_provenance={'kind':'reused actual immutable installed 0.2.2 evidence','sessionSHA256':declared['SHA256'],'sourceManifestSHA256':hashlib.sha256(manifest_path.read_bytes()).hexdigest(),'sourceEvidencePath':str(baseline),'newBaselineInvocations':0}
    schema={'type':'object','additionalProperties':False,'required':['value','priority'],'properties':{'value':{'type':'string'},'priority':{'type':'string','enum':['low','high']}}}
    result={'type':'object','additionalProperties':False,'required':['value'],'properties':{'value':{'type':'string'}}}
    def operation(title):return {'operationId':title,'summary':title,'security':[],'requestBody':{'required':True,'content':{'application/json':{'schema':schema}}},'responses':{'200':{'description':'Accepted','content':{'application/json':{'schema':result}}}}}
    paths={('/'+name):{'post':operation(title)} for name,title in [('valid','Valid JSON'),('cleared','Cleared bearer requirement'),('malformed','Malformed response'),('wrongtype','Wrong response type'),('unavailable','HTTP unavailable'),('missing','Missing bearer requirement')]}
    paths['/missing']['post']['security']=[{'DisposableBearer':[]}]
    query=operation('GET query unsupported');query.pop('requestBody');query['parameters']=[{'name':'filter','in':'query','required':False,'schema':{'type':'string'}}]
    paths['/query']={'get':query}
    document={'openapi':'3.0.3','info':{'title':'Private response compatibility','version':'1'},'security':[{'DisposableBearer':[]}],'components':{'securitySchemes':{'DisposableBearer':{'type':'http','scheme':'bearer'}}},'paths':paths}
    requests=[];sessions=[saved_baseline] if saved_baseline else []
    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def respond(self,body,status=200,kind='application/json'):
            data=body.encode();self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def do_GET(self):
            if self.path=='/openapi.json':self.respond(json.dumps(document));return
            self.invoke()
        def do_POST(self):self.invoke()
        def invoke(self):
            body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode();value=json.loads(body) if body else None
            write=self.path!='/unavailable';requests.append({'method':self.command,'path':self.path,'body':body,'actualWrite':write,'taskID':self.headers.get('X-RightClick-Invocation'),'authorizationAbsent':self.headers.get('Authorization') is None})
            if self.path=='/malformed':self.respond('{')
            elif self.path=='/wrongtype':self.respond('{"value":42}')
            elif self.path=='/unavailable':self.respond('benign-provider-error',503,'text/plain')
            else:self.respond(json.dumps({'value':value['value']},sort_keys=True,separators=(',',':')))
    provider=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider);threading.Thread(target=provider.serve_forever,daemon=True).start()
    def stop(p):
        p.terminate()
        try:p.wait(timeout=10)
        except subprocess.TimeoutExpired:p.kill();p.wait(timeout=10)
    try:
        with tempfile.TemporaryDirectory(prefix='rightclick-response-compat-') as temporary:
            private_dir=Path(temporary);os.chmod(private_dir,0o700);key=Ed25519PrivateKey.generate();key_file=private_dir/'signer.private';key_file.write_bytes(key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption()));os.chmod(key_file,0o600)
            pin=evidence/'trusted-public-key.raw';pin.write_bytes(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw))
            config=private_dir/'policy.private';config.write_text(json.dumps({'version':1,'revision':'response-compatibility-1','deniedCapabilities':[],'signingKeyFile':str(key_file)}));os.chmod(config,0o600)
            base='http://127.0.0.1:'+str(provider.server_port)
            env={k:v for k,v in os.environ.items() if not k.startswith('RIGHTCLICK_')};env.update(RIGHTCLICK_EXPERIENCE='off',RIGHTCLICK_RCIR_CONFIG=str(config),RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([{'id':'private-response-compat','kind':'openapi','specificationURL':base+'/openapi.json','baseURL':base}]))
            for label,binary in [('baseline',baseline),('candidate',candidate)]:
                if label=='baseline' and saved_baseline:continue
                with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
                token=os.urandom(32).hex();environment=dict(env,RIGHTCLICK_MCP_TOKEN=token)
                with (evidence/(label+'.stderr.log')).open('w') as error:
                    process=subprocess.Popen([str(binary),'mcp','--http','--port',str(port)],stdout=subprocess.DEVNULL,stderr=error,env=environment)
                    try:
                        for _ in range(200):
                            try:
                                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                            except OSError:time.sleep(.1)
                        else:raise RuntimeError('HTTP listener did not start')
                        sequence=0
                        def rpc(method,parameters,bearer=token):
                            nonlocal sequence
                            sequence+=1;headers={'Content-Type':'application/json','Accept':'application/json','MCP-Protocol-Version':'2025-03-26'}
                            if bearer is not None:headers['Authorization']='Bearer '+bearer
                            request=urllib.request.Request('http://127.0.0.1:'+str(port)+'/mcp',json.dumps({'jsonrpc':'2.0','id':sequence,'method':method,'params':parameters}).encode(),headers)
                            with urllib.request.urlopen(request,timeout=45) as response:reply=json.load(response)
                            assert 'error' not in reply;return reply['result']
                        def call(name,args):
                            value=rpc('tools/call',{'name':name,'arguments':args});assert not value.get('isError');return json.loads(value['content'][0]['text'])
                        for bad in [None,'wrong-disposable-token']:
                            before=len(requests)
                            try:rpc('tools/list',{},bad);raise AssertionError('Unauthorized request accepted')
                            except urllib.error.HTTPError as failure:assert failure.code==401 and len(requests)==before
                        rpc('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'untrusted-test-label','version':'1'}})
                        assert {t['name'] for t in rpc('tools/list',{})['tools']}==CORE
                        runtime=call('context_runtime',{});assert runtime['executableSHA256']==hashlib.sha256(binary.read_bytes()).hexdigest()
                        call('context_providers',{});call('context_inspect',{'item':'safe-response'})
                        catalog=call('context_actions',{'item':'safe-response'})['actions'];actions={a['title']:a for a in catalog if a.get('provider',{}).get('name')=='Private response compatibility'}
                        cases=[]
                        for title,args,expected_requests in [('Valid JSON',{'value':'safe-response','priority':'high'},1),('Cleared bearer requirement',{'value':'cleared-authority','priority':'low'},1),('Invalid enum',{'value':'safe-response','priority':'invalid'},0),('Missing field',{'priority':'high'},0),('GET query unsupported',{'filter':'bounded'},0),('Missing bearer requirement',{'value':'safe-response','priority':'high'},0),('Malformed response',{'value':'safe-malformed','priority':'high'},1),('Wrong response type',{'value':'safe-type','priority':'low'},1),('HTTP unavailable',{'value':'safe-http-error','priority':'low'},1)]:
                            name='Valid JSON' if title in ['Invalid enum','Missing field'] else title
                            if name not in actions:
                                assert title=='GET query unsupported' and expected_requests==0
                                cases.append({'title':title,'action':None,'record':None,'actualRequests':[],'discoveryStatus':'absent','catalogueTitles':sorted(actions),'noInvocationAttempted':True,'independentSignedTaskCorrelation':False,'statusMatches':False})
                                print(json.dumps({'progress':label+' '+title,'discoveryStatus':'absent','requests':0}),flush=True)
                                continue
                            action=actions[name];call('context_explain',{'item':'safe-response','actionId':action['id']})
                            parameters={'item':'safe-response','actionId':action['id'],'confirmed':True,'arguments':args}
                            if action.get('contractSHA256'):parameters['contractSHA256']=action['contractSHA256']
                            before=len(requests);record=call('context_run',parameters);actual=requests[before:]
                            assert len(actual)==expected_requests,title+' unexpected dispatch count'
                            assert not record.get('evidence',{}).get('outcomeVerified',False)
                            if title in ['Valid JSON','Cleared bearer requirement']:
                                assert record['state']=='accepted' and json.loads(record['output'])=={'value':args['value']}
                                assert actual[0]['body']==json.dumps(args,sort_keys=True,separators=(',',':')) and actual[0]['authorizationAbsent']
                            else:assert record['state'] not in ['accepted','succeeded','started'],title+' unsupported success claim'
                            status=call('context_run_status',{'executionId':record['executionId']});assert status['state']==record['state'] and status.get('output')==record.get('output')
                            verified=False
                            if record.get('rcir',{}).get('signedReceipt'):
                                rcir=record['rcir'];assert actual and actual[0]['taskID']==rcir['taskID'];assert status['rcir']==rcir
                                path=evidence/(label+'-'+title.lower().replace(' ','-')+'-receipt.json');path.write_text(json.dumps(rcir['signedReceipt'],indent=2)+'\n');verifier.verify(path,pin,expected_outcome=rcir['outcome']);verified=True
                            cases.append({'title':title,'action':action,'record':record,'actualRequests':actual,'independentSignedTaskCorrelation':verified,'statusMatches':True})
                            print(json.dumps({'progress':label+' '+title,'state':record['state'],'requests':len(actual),'actualWrites':sum(r['actualWrite'] for r in actual)}),flush=True)
                        sessions.append({'label':label,'runtime':runtime,'transport':'http','cases':cases,'wrongAndMissingHTTPBearerDenied':True,'CoreTools':sorted(CORE)})
                        (evidence/(label+'-session.json')).write_text(json.dumps(sessions[-1],indent=2,sort_keys=True)+'\n')
                    finally:stop(process)
        comparisons=[]
        for old,new in zip(sessions[0]['cases'],sessions[1]['cases']):
            assert old['title']==new['title'] and len(old['actualRequests'])==len(new['actualRequests'])
            assert (old['action'] is not None)==(new['action'] is not None)
            assert (old['record'] is not None)==(new['record'] is not None)
            if old['record']:
                assert old['record']['state']==new['record']['state']
                assert (old['record'].get('output') is not None)==(new['record'].get('output') is not None)
                assert old['statusMatches'] and new['statusMatches']
            for prior,current in zip(old['actualRequests'],new['actualRequests']):
                for field in ['method','path','body','actualWrite','authorizationAbsent']:assert prior[field]==current[field]
            legal=old['title'] in ['Valid JSON','Cleared bearer requirement']
            if legal:assert old['record']['state']==new['record']['state'] and old['record']['output']==new['record']['output'] and old['actualRequests'][0]['body']==new['actualRequests'][0]['body']
            comparisons.append({'title':old['title'],'baselineDiscovered':old['action'] is not None,'candidateDiscovered':new['action'] is not None,'baselineState':old['record']['state'] if old['record'] else None,'candidateState':new['record']['state'] if new['record'] else None,'baselineOutputPresent':old['record'] is not None and old['record'].get('output') is not None,'candidateOutputPresent':new['record'] is not None and new['record'].get('output') is not None,'actualRequestCount':len(new['actualRequests']),'classification':'declared valid behavior preserved' if legal else 'existing safe abstention preserved' if not new['actualRequests'] else 'post-dispatch failure boundary; raw states retained, no verified success claimed'})
        report={'status':'PASS','introducedLossesOnDeclaredValidCalls':[],'baselineProvenance':baseline_provenance,'sessions':sessions,'comparisons':comparisons,'actualProviderRequests':requests,'actualWriteCount':sum(r['actualWrite'] for r in requests),'scope':'Actual immutable installed0.2.2 baseline (retained when baselineProvenance is present) compared with fresh exact candidate public authenticated HTTP Core7; private loopback OpenAPI provider. Counts describe fresh calls only. No provider token is provisioned; bearer override/missing-scope behavior only.','notProved':['Actual provider credential-backed TLS authority on product public path','Issuer downscoping or authenticated subject broker','All platforms/substrates release acceptance']}
        (evidence/'summary.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n');print(json.dumps({'status':'PASS','casesPerVersion':9,'actualRequests':len(requests),'actualWrites':report['actualWriteCount']}));return 0
    finally:provider.shutdown()

if __name__=='__main__':raise SystemExit(main())
