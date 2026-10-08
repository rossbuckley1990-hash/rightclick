from pathlib import Path
import json,subprocess,hashlib,importlib.util,base64
root=Path('/private/tmp/rightclick-seven-effects-20261007');source=Path('/Users/ross/.codex/.chatgpt-projects/g-p-6ac33d82393c8191a661a30d2e144882/work/rightclick-universal')
trace=json.loads((root/'actual-kafka/rightclick-transcript.json').read_text())
requests={x['message']['id']:x['message'] for x in trace if x['direction']=='client' and 'id' in x['message']}
executions=[]
for line in trace:
 message=line['message']; request=requests.get(message.get('id'),{})
 if line['direction']=='server' and request.get('method')=='tools/call' and request.get('params',{}).get('name')=='context_run':
  executions.append({'arguments':request['params']['arguments'],'record':json.loads(message['result']['content'][0]['text'])})
assert len(executions)==2
assert executions[0]['record']['state']=='awaiting_user' and not executions[0]['arguments'].get('confirmed',False)
assert executions[1]['arguments'].get('confirmed') is True
success=executions[1]['record'];assert success['state']=='succeeded' and success['evidence']['outcomeVerified']
challenge=json.loads((root/'challenge.json').read_text())
assert executions[1]['arguments']['arguments']==challenge
before=json.loads((root/'offsets-before.json').read_text());after=json.loads((root/'offsets-after.json').read_text())
assert after[0]['partitions'][0]['high_watermark']-before[0]['partitions'][0]['high_watermark']==1
ack=json.loads(success['output'])
external=json.loads(subprocess.check_output(['/private/tmp/rightclick-kafka-toolchain/rpk','--config','/private/tmp/rightclick-proof-lab-20261007/kafka-observer.json','topic','consume','rightclick.proof','-p',str(ack['partition']),'-o',str(ack['offset']),'-n','1','--format','json','--pretty-print=false'],timeout=8))
assert external['key']==challenge['key'] and external['value']==challenge['payload']
headers=[v for v in external.get('headers',[]) if v['key']=='rightclick.invocation'];assert len(headers)==1 and headers[0]['value']==success['rcir']['taskID']
file=root/'actual-kafka/verified-receipt.json';file.write_text(json.dumps(success['rcir']['signedReceipt'],indent=2)+'\n')
spec=importlib.util.spec_from_file_location('verifier',source/'scripts/verify-rcir-receipt.py');verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
report=verifier.verify(file,root/'trusted-public-key.raw',expected_outcome='succeeded',expected_task_id=success['rcir']['taskID'],expected_lease_id=success['rcir']['leaseID'])
receipt=verifier._domain(base64.b64decode(success['rcir']['signedReceipt']['payload']),'RECEIPT');observed=verifier._value(receipt['observation'])
normalized={k:external[k] for k in ('topic','partition','offset','key','value','timestamp')};normalized['invocationID']=headers[0]['value'];assert observed==normalized
(root/'actual-kafka/independent-record.json').write_text(json.dumps(external,indent=2)+'\n')
(root/'actual-kafka/trusted-public-key.raw').write_bytes((root/'trusted-public-key.raw').read_bytes())
report.update(status='GREEN_FOR_FRESH_AI_KAFKA_BOUNDARY',expectedConfirmedMutations=1,observedHighWatermarkDelta=1,confirmationFirstRunNoEffect=True,independentRecordMatchesSignedObservation=True,hostInvocationMarkerMatches=True,binarySHA256=hashlib.sha256((root/'rightclick').read_bytes()).hexdigest(),scope='Fresh AI single-substrate production/readback/signature boundary. No final eleven-substrate/native platform/productionkey lifecycle/graph mutation claim.')
(root/'actual-kafka/independent-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
