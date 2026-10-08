#!/usr/bin/env python3
"""Actual seven-operation Kafka proof; external lab owner controls withdrawal.

This engineering transcript driver is not the final fresh-AI eleven-substrate
acceptance run. rpk readbacks below are separate workbench observations.
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, selectors, subprocess, time, uuid
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('evidence', type=pathlib.Path)
parser.add_argument('--client', type=pathlib.Path, required=True)
parser.add_argument('--publisher-config', type=pathlib.Path, required=True)
parser.add_argument('--observer-config', type=pathlib.Path, required=True)
parser.add_argument('--mutation-directory', type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
out = args.evidence.resolve(); out.mkdir(parents=True, exist_ok=True)
lab = pathlib.Path('/private/tmp') / ('rightclick-kafka-acceptance-' + uuid.uuid4().hex); lab.mkdir(mode=0o700)
key = Ed25519PrivateKey.generate(); keyfile = lab/'signer.raw'
keyfile.write_bytes(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())); keyfile.chmod(0o600)
public = out/'trusted-public-key.raw'; public.write_bytes(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
config = lab/'host.json'
configuration = {'version':1,'revision':'kafka-seven-operation-proof-1','deniedCapabilities':[],'signingKeyFile':str(keyfile)}
def configure():
    config.write_text(json.dumps(configuration)); config.chmod(0o600)
configure()
env = {k:v for k,v in os.environ.items() if not k.startswith('RIGHTCLICK_')}
env.update(RIGHTCLICK_KAFKA_CLIENT=str(args.client.resolve()), RIGHTCLICK_KAFKA_PUBLISHER_CONFIG=str(args.publisher_config.resolve()),
           RIGHTCLICK_KAFKA_OBSERVER_CONFIG=str(args.observer_config.resolve()), RIGHTCLICK_RCIR_CONFIG=str(config),
           RIGHTCLICK_CAPABILITY_EXPERIENCE='disabled',
           RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([{'id':'controlled-kafka','kind':'kafka','endpointURL':'kafka://127.0.0.1:19092'}]))
transcript=[]; reports={}; canonical={'context_runtime','context_providers','context_inspect','context_actions','context_explain','context_run','context_run_status'}
process=subprocess.Popen([str(args.binary.resolve()),'mcp'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                         stderr=(out/'runtime.stderr').open('w'),text=True,bufsize=1)
selector=selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ)
def rpc(method,params=None):
    request={'jsonrpc':'2.0','id':len(transcript)+1,'method':method}
    if params is not None:request['params']=params
    process.stdin.write(json.dumps(request)+'\n');process.stdin.flush();deadline=time.monotonic()+40
    while time.monotonic()<deadline:
        if selector.select(max(0,deadline-time.monotonic())):
            raw=process.stdout.readline()
            if not raw:raise RuntimeError('candidate runtime exited')
            reply=json.loads(raw)
            if reply.get('id')==request['id']:
                transcript.append({'request':request,'response':reply});assert not reply.get('error'),reply
                return reply['result']
    raise TimeoutError(method)
def call(name,arguments):
    result=rpc('tools/call',{'name':name,'arguments':arguments});assert not result.get('isError'),result
    return json.loads(result['content'][0]['text'])
def actions():return call('context_actions',{'item':'Kafka exact UTF-8 record proof'})['actions']
def read(arguments):
    return json.loads(subprocess.check_output([str(args.client.resolve()),'--config',str(args.observer_config.resolve())]+arguments,timeout=8))
def offsets():return read(['topic','describe','rightclick.proof','--format','json'])
def highwatermark(metadata):return metadata[0]['partitions'][0]['high_watermark']
spec=importlib.util.spec_from_file_location('receipt_verifier',root/'scripts/verify-rcir-receipt.py')
verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
action='kafka:controlled-kafka:publish.rightclick.proof'
try:
    rpc('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'seven-operation-kafka-proof','version':'1'}})
    runtime=call('context_runtime',{})
    before=rpc('tools/list')['tools'];assert {t['name'] for t in before}==canonical
    providers=call('context_providers',{})
    call('context_inspect',{'item':'Kafka exact UTF-8 record proof'})
    discovered=actions();assert action in {a['id'] for a in discovered}
    explanation=call('context_explain',{'item':'Kafka exact UTF-8 record proof','actionId':action})
    initial=offsets()
    gated=call('context_run',{'item':'Kafka proof','actionId':action,'arguments':{'key':'unconfirmed','payload':'must-not-publish'}})
    assert gated['state']=='awaiting_user' and highwatermark(offsets())==highwatermark(initial)
    nonce='kafka-proof-'+uuid.uuid4().hex;payload='RIGHTCLICK exact UTF-8 payload\nsecond line\n'+nonce
    result=call('context_run',{'item':'Kafka proof','actionId':action,'confirmed':True,'arguments':{'key':nonce,'payload':payload}})
    assert result['state']=='succeeded' and result['evidence']['outcomeVerified'] and result['rcir']['outcome']=='succeeded',result
    status=call('context_run_status',{'executionId':result['executionId']});assert status['rcir']==result['rcir']
    ack=json.loads(result['output']);assert ack['topic']=='rightclick.proof' and ack['key']==nonce and ack['value']==payload
    external=read(['topic','consume','rightclick.proof','-p',str(ack['partition']),'-o',str(ack['offset']),'-n','1','--format','json','--pretty-print=false'])
    assert all(external[k]==ack[k] for k in ('topic','partition','offset','key','value'))
    envelope=out/'verified-receipt.json';envelope.write_text(json.dumps(result['rcir']['signedReceipt'],indent=2)+'\n')
    reports['receipt']=verifier.verify(envelope,public,expected_outcome='succeeded',expected_task_id=result['rcir']['taskID'],expected_lease_id=result['rcir']['leaseID'])
    receipt=verifier._domain(base64.b64decode(result['rcir']['signedReceipt']['payload']),'RECEIPT')
    observed=verifier._value(receipt['observation'])
    markers=[h for h in external.get('headers',[]) if h.get('key')=='rightclick.invocation']
    assert len(markers)==1 and markers[0]['value']==result['rcir']['taskID']
    normalized={k:external[k] for k in ('topic','partition','offset','key','value','timestamp')}
    normalized['invocationID']=markers[0]['value'];assert observed==normalized
    reports['fullSignedObservation']=observed;reports['independentWorkbenchObservation']=external
    reports['hostInvocationMarkerVerified']=True
    policyBefore=offsets();configuration['deniedCapabilities']=[action];configure()
    denied=call('context_run',{'item':'Kafka proof','actionId':action,'confirmed':True,'arguments':{'key':'policy-denied-'+nonce,'payload':'must-not-publish'}})
    assert denied['state']=='rejected' and highwatermark(offsets())==highwatermark(policyBefore)
    configuration['deniedCapabilities']=[];configure()
    mutation={'status':'RED: external lab withdrawal not requested'}
    if args.mutation_directory:
        control=args.mutation_directory.resolve();control.mkdir(parents=True,exist_ok=True)
        def signal(stage):
            (control/(stage+'-ready')).write_text('Only lab owner may change the controlled broker.\n')
            deadline=time.monotonic()+60
            while not (control/(stage+'-done')).exists():
                if time.monotonic()>deadline:raise TimeoutError('lab '+stage)
                time.sleep(.2)
        signal('withdraw')
        deadline=time.monotonic()+30
        while action in {a['id'] for a in actions()}:
            if time.monotonic()>deadline:raise TimeoutError('live graph withdrawal')
            time.sleep(1)
        offline=call('context_run',{'item':'Kafka proof','actionId':action,'confirmed':True,'arguments':{'key':'offline-'+nonce,'payload':'must-not-publish'}})
        assert offline['state'] in ('unavailable','unsupported','rejected','unknown') and not offline['evidence']['outcomeVerified']
        signal('restore')
        deadline=time.monotonic()+30
        while action not in {a['id'] for a in actions()}:
            if time.monotonic()>deadline:raise TimeoutError('live graph restoration')
            time.sleep(1)
        restored=offsets();assert highwatermark(restored)==highwatermark(policyBefore)
        mutation={'status':'GREEN','brokerWithdrawn':True,'capabilityRemoved':True,'staleRun':offline,'brokerRestored':True,'capabilityRediscovered':True,'noOfflineReplay':True}
    after=rpc('tools/list')['tools'];assert {t['name'] for t in after}==canonical
    summary={'runtime':runtime,'binarySHA256':hashlib.sha256(args.binary.resolve().read_bytes()).hexdigest(),
             'clientSHA256':hashlib.sha256(args.client.resolve().read_bytes()).hexdigest(),
             'topLevelToolsBefore':len(before),'topLevelToolsAfter':len(after),'providerSpecificAITools':0,
             'verifiedExecution':result,'observerReports':reports,'policyDenied':denied,'confirmationNoEffect':True,
             'liveGraphMutation':mutation,'scope':'Engineering seven-operation proof; final fresh-AI eleven-substrate acceptance is separate.'}
    (out/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
finally:
    (out/'transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    selector.close();process.terminate();process.wait(timeout=10)
