from pathlib import Path
import os,json,subprocess
root=Path('/private/tmp/rightclick-seven-effects-20261007')
env={k:v for k,v in os.environ.items() if not k.startswith('RIGHTCLICK_')}
env.update(RIGHTCLICK_KAFKA_CLIENT='/private/tmp/rightclick-kafka-toolchain/rpk',RIGHTCLICK_KAFKA_PUBLISHER_CONFIG='/private/tmp/rightclick-proof-lab-20261007/kafka-publisher.json',RIGHTCLICK_KAFKA_OBSERVER_CONFIG='/private/tmp/rightclick-proof-lab-20261007/kafka-observer.json',RIGHTCLICK_RCIR_CONFIG=str(root/'host.json'),RIGHTCLICK_CAPABILITY_EXPERIENCE='disabled',RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps([{'id':'actual-ai-kafka','kind':'kafka','endpointURL':'kafka://127.0.0.1:19092'}]))
def offsets():
 return json.loads(subprocess.check_output(['/private/tmp/rightclick-kafka-toolchain/rpk','--config','/private/tmp/rightclick-proof-lab-20261007/kafka-observer.json','topic','describe','rightclick.proof','--format','json'],timeout=8))
(root/'offsets-before.json').write_text(json.dumps(offsets(),indent=2)+'\n')
command=['python3',str(root/'probe.py'),'--runtime',str(root/'rightclick'),'--catalog-source','/private/tmp/rightclick-seven-agent-probe/catalog.json','--prompt-file',str(root/'prompt.txt')]
subprocess.run(command+['--run-name','capture-catalog-validated'],env=env,check=True)
captures=json.loads((root/'capture-catalog-validated/request-catalog.json').read_text())
canonical={'context_runtime','context_providers','context_inspect','context_actions','context_explain','context_run','context_run_status'}
def flatten(definitions):
 result=[]
 for tool in definitions:
  if tool.get('type')=='namespace':
   assert tool.get('name')=='functions'
   result.extend(flatten(tool['tools']))
  else:
   assert tool.get('type')=='function'
   result.append(tool['name'])
 return result
for request in captures:
 names=flatten(request['tools'])
 for block in request['additionalTools']:
  names.extend(flatten(block['tools']))
 assert len(names)==7 and set(names)==canonical
print('PASS: exact current outgoing inference catalogue has seven operations',flush=True)
subprocess.run(command+['--run-name','actual-kafka','--actual'],env=env,check=True)
(root/'offsets-after.json').write_text(json.dumps(offsets(),indent=2)+'\n')
