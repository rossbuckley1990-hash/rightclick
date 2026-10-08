#!/usr/bin/env python3
"""Evidence audit only. Reuses the unchanged repository canonical receipt verifier.
Signatures authenticate claims; native journal and invocation binding are checked separately.
"""
import argparse, hashlib, importlib.util, json, re, subprocess
from pathlib import Path
EXPECTED_HEAD='8f7372226749550767548352c5d6463f305a8794'
EXPECTED_TREE='c7414e1dc9cf28c98262aa933e40166113f66ba8'
COLLECTOR_HASHES={
 'scripts/dbus-private-fixture.py':'b24cbda9d8b0eb952ad866a573ce46a5879266b13fe03b1caee4fc47342e6f21',
 'scripts/acceptance-linux-dbus.py':'14111d166de07d698b77ffac362ca2e8b2eacb745638fee621172c24587e418e'}
CORE={'context_runtime','context_providers','context_inspect','context_actions','context_explain','context_run','context_run_status'}
def load(path):return json.loads(path.read_text())
def pin(path):
 data=path.read_bytes();return {'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
def lines(path):
 data=path.read_bytes();assert data.endswith(b'\n'),str(path)
 return [json.loads(line) for line in data.splitlines()]
def calls(trace):
 records=[]; tools=[]; names=set()
 for row in trace:
  query,reply=row['request'],row['response']; assert query['id']==reply['id'] and 'error' not in reply
  if query['method']=='tools/list':tools.append(reply['result']['tools'])
  if query['method']!='tools/call':continue
  name=query['params']['name'];names.add(name)
  result=reply['result'];text=result['content'][0]['text']
  try:value=json.loads(text)
  except ValueError:assert result.get('isError');value={'isError':True}
  records.append((name,query['params']['arguments'],value))
 assert tools and len(tools[0])==7 and {t['name'] for t in tools[0]}==CORE
 assert all(t==tools[0] for t in tools)
 return records,tools[0],names

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('artifacts',type=Path);parser.add_argument('repo',type=Path);parser.add_argument('ci',type=Path);parser.add_argument('output',type=Path)
 a=parser.parse_args();data=a.artifacts/'seven-core';a.output.mkdir(parents=True,exist_ok=True)
 ci=load(a.ci); assert ci['headSha']==EXPECTED_HEAD and ci['status']=='completed' and ci['conclusion']=='success'
 assert ci['headBranch']=='diagnostic/dbus-observer-journal-preservation-20261007' and ci['event']=='push'
 artifacts_metadata=load(a.ci.with_name('ci-artifacts-37700326321.json'))
 assert artifacts_metadata['total_count']==1
 artifact=artifacts_metadata['artifacts'][0]
 assert artifact['name']=='native-dbus-observer-journal-'+EXPECTED_HEAD and artifact['expired'] is False
 assert artifact['workflow_run']['head_sha']==EXPECTED_HEAD
 jobs=ci['jobs'];assert len(jobs)==1;job=jobs[0];assert job['name']=='native-linux-dbus' and job['conclusion']=='success'
 steps={x['name']:x for x in job['steps']}
 for name in ['Typed compiler and real final-gate owner controls','Build the single runtime','Seven operations, automatic discovery and independent native effect']:
  assert steps[name]['conclusion']=='success',name
 assert (a.artifacts/'source.txt').read_text().strip()==EXPECTED_HEAD
 assert (a.artifacts/'sources-tree.txt').read_text().strip()==EXPECTED_TREE
 pinned_collectors={line.split()[1]:line.split()[0] for line in (a.artifacts/'collector-source-sha256.txt').read_text().splitlines()}
 assert pinned_collectors==COLLECTOR_HASHES
 for name,sha in COLLECTOR_HASHES.items():assert pin(a.repo/name)['sha256']==sha
 assert subprocess.check_output(['git','rev-parse',EXPECTED_HEAD+':Sources'],cwd=a.repo,text=True).strip()==EXPECTED_TREE
 tests=(a.artifacts/'native-tests.log').read_text(); summaries=re.findall(r'Executed (\d+) tests, (?:with (\d+) tests skipped and )?(?:with )?(\d+) failures',tests)
 assert summaries and summaries[-1]==('13','','0'),summaries[-1:]
 execution_start = tests.rfind("Test Suite 'Selected tests' started")
 assert execution_start >= 0
 execution_log = tests[execution_start:]
 # Compiler diagnostics can quote XCTSkip in unrelated tests; only executed-test skips count.
 assert 'XCTSkip' not in execution_log and 'Test skipped' not in execution_log and ' skipped - ' not in execution_log
 spec=importlib.util.spec_from_file_location('existing_receipt_verifier',a.repo/'scripts/verify-rcir-receipt.py')
 verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
 records,tools,names=calls(load(data/'transcript.json'));assert names==CORE
 default_records,default_tools,default_names=calls(load(data/'default-session/transcript.json'));assert default_tools==tools
 runtime=next(v for n,_,v in records if n=='context_runtime');reported=load(data/'results.json')
 binary=(a.artifacts/'binary-sha256.txt').read_text().split()[0]
 assert runtime['platform']=='Linux' and runtime['version']=='0.2.3' and runtime['executableSHA256']==binary==reported['binarySHA256']
 assert next(v for n,_,v in default_records if n=='context_runtime')['executableSHA256']==binary
 assert reported['status']=='SCOPED_NATIVE_LINUX_DBUS_GREEN' and reported['toolCountBefore']==reported['toolCountAfter']==7 and reported['providerSpecificToolsAdded']==0
 assert reported['principals']=={'writerUID':1100,'observerUID':1101,'serviceUID':1102}
 effects=lines(data/'effects.jsonl');observations=lines(data/'observations.jsonl');assert len(effects)==4 and len(observations)==3
 assert all(r['writerUID']==1100 and r['enabled'] is True for r in effects)
 assert all(set(r)=={'challenge','digest','writerUID','observerUID','platform','observation','enabled','invocation','requestInvocation'} for r in observations)
 assert all(r['writerUID']=='1100' and r['observerUID']=='1101' and r['platform']=='Linux' and r['observation']=='independent-file-sha256' and r['enabled']=='true' for r in observations)
 main_runs=[(args,value) for name,args,value in records if name=='context_run' and value.get('rcir',{}).get('signedReceipt')]
 default_runs=[(args,value) for name,args,value in default_records if name=='context_run' and value.get('rcir',{}).get('signedReceipt')]
 assert len(main_runs)==5 and len(default_runs)==1
 stores=[(args,value) for args,value in main_runs if args['actionId'].endswith('.Store')];assert len(stores)==4
 first=stores[0][1]['rcir']['taskID']; replay=stores[2][1]['rcir']['taskID'];restored=stores[3][1]['rcir']['taskID']
 expected=[('unit',main_runs[0],'accepted','unverified'),('positive',stores[0],'succeeded','succeeded'),('missing',stores[1],'accepted','unverified'),('replay',stores[2],'failed','failed'),('restored',stores[3],'succeeded','succeeded'),('typed-array',default_runs[0],'succeeded','succeeded')]
 receipts=[];task_ids=set();leases=set()
 for label,(args,result),state,outcome in expected:
  rcir=result['rcir'];assert result['state']==state and rcir['outcome']==outcome and rcir['phase']=='completed' and rcir['leaseConsumed'] is True
  task,lease=rcir['taskID'],rcir['leaseID'];assert task not in task_ids and lease not in leases;task_ids.add(task);leases.add(lease)
  path=a.output/(label+'-receipt.json');path.write_text(json.dumps(rcir['signedReceipt'],indent=2)+'\n')
  verdict=verifier.verify(path,data/'trusted-public-key.raw',expected_task_id=task,expected_lease_id=lease,expected_outcome=outcome)
  payload,_,_=verifier._envelope(path);receipt=verifier._domain(payload,'RECEIPT');request=verifier._domain(receipt['request'],'REQUEST');bound=verifier._value(request['arguments'])
  event=verifier._value(receipt['events'][-1]);observation=verifier._value(receipt['observation']) if receipt['observation'] else None
  if isinstance(observation,dict) and isinstance(observation.get('value'),bytes):observation=verifier._value(observation['value'])
  entry={'control':label,'taskID':task,'leaseID':lease,'state':state,'outcome':outcome,'canonicalSignatureAndBoundClaims':'PASS','argumentBinding':'PASS'}
  if label=='unit':
   assert args['actionId'].endswith('.Acknowledge') and bound=={} and result.get('output') is None and observation is None
   assert event['kind']=='completedWithoutOutput' and event['value'] is None
  elif label=='typed-array':
   vals=[x[1] for x in json.loads(args['arguments']['values'])[1]];assert bound=={'values':vals}
   assert json.loads(result['output'])==vals and event['kind']=='completed' and event['value']==vals
   entry['typedCompletedArray']=vals
  else:
   supplied=args['arguments'];assert bound=={'challenge':supplied['challenge'],'value':supplied['value'],'enabled':True}
   assert any(r['challenge']==supplied['challenge'] for r in effects)
   digest=hashlib.sha256(supplied['value'].encode()).hexdigest();assert args['expectedOutput']==digest
   assert event['kind']=='completed' and event['value']=='accepted' and result.get('output')=='accepted'
   matching=[r for r in observations if r['requestInvocation']==task]
   if label=='missing':assert observation is None and not matching
   else:
    assert len(matching)==1;row=matching[0];assert observation=={k:v for k,v in row.items() if k!='requestInvocation'}
    assert observation['challenge']==supplied['challenge'] and observation['digest']==digest
    if label=='replay':assert row['invocation']==first and row['invocation']!=row['requestInvocation']==replay
    else:assert row['invocation']==row['requestInvocation']==task
    entry['exactNativeJournalVsSignedObservation']='PASS';entry['independentlyDerivedDigest']=digest;entry['markers']={'observedInvocation':row['invocation'],'requestInvocation':row['requestInvocation']}
  receipts.append(entry)
 assert load(data/'ack-unit-receipt.json')==main_runs[0][1]['rcir']['signedReceipt']
 assert load(data/'success-receipt.json')==stores[0][1]['rcir']['signedReceipt']
 status=next(v for n,_,v in records if n=='context_run_status');assert status==stores[0][1]
 refusals=[(args,v) for n,args,v in records if n=='context_run' and not v.get('rcir',{}).get('signedReceipt')]
 assert [v.get('state') or ('isError' if v.get('isError') else None) for _,v in refusals]==['awaiting_user','rejected','isError']
 assert refusals[0][0]['confirmed'] is False and all(r['challenge']!=refusals[2][0]['arguments']['challenge'] for r in effects)
 denials=load(data/'provider-enforced-denials.json');assert set(denials)=={'observerWrite','writerRead'} and all(r['exit']!=0 and 'Access denied' in r['stderr'] for r in denials.values())
 action_lists=[v['actions'] for n,_,v in records if n=='context_actions'];store_id=stores[0][0]['actionId']
 assert any(r['id']==store_id for r in action_lists[0]);assert len(action_lists)==4
 assert all(not any(r['id']==store_id for r in page) for page in action_lists[1:3]);assert any(r['id']==store_id for r in action_lists[3])
 explanations=[v for n,args,v in records if n=='context_explain' and args['actionId']==store_id];assert len(explanations)==2
 old,new=reported['originalOwner'],reported['restoredOwner'];assert old!=new
 assert explanations[0]['metadata']['dbusUniqueOwner']==old and explanations[1]['metadata']['dbusUniqueOwner']==new
 assert explanations[0]['metadata']['descriptorSHA256']!=explanations[1]['metadata']['descriptorSHA256']
 assert [r['owner'] for r in effects]==[old,old,old,new]
 summary={'status':'GREEN_SCOPED_NATIVE_DBUS_JOURNAL_PRESERVATION','source':EXPECTED_HEAD,'sourcesTree':EXPECTED_TREE,'ci':{'runID':ci['databaseId'],'jobID':job['databaseId'],'url':ci['url'],'event':ci['event'],'branch':ci['headBranch'],'artifactID':artifact['id'],'artifactAdvertisedDigest':artifact['digest'],'artifactDigestScope':'GitHub advertised archive digest; extracted artifact files independently hashed below.'},'collectorSourceSHA256':pinned_collectors,'runtimeSHA256':binary,'nativeTests':{'tests':13,'skips':0,'failures':0},'publicCore7':'PASS; exact catalogue unchanged before/after; actual calls to all seven operations','allTerminalReceiptsChecked':len(receipts),'receiptResults':receipts,'retainedStatus':'Exact first-success record and receipt retained','nativeJournal':{'effects':4,'observations':3,'positiveObservedEqualsRequest':True,'replayObservedPriorMarkerAndDifferentRequest':True,'restoredObservedEqualsRequest':True},'leastAuthority':{'methodDenials':denials,'scope':'Private Linux bus daemon EXTERNAL kernel UID enforces writer1100/observer1101 method separation; scoped host lease/policy. No issuer/delegation claim.'},'ownerLifecycle':{'originalOwner':old,'restoredOwner':new,'actualGraphWithdrawalRestoration':'PASS','changedDescriptorBinding':'PASS','scope':'CI acceptance source also asserts old unique connection remains callable after ReleaseName; raw retained capability transcripts and owned effects confirm withdrawal/restoration.'},'pin':pin(data/'trusted-public-key.raw'),'unchangedVerifier':pin(a.repo/'scripts/verify-rcir-receipt.py'),'externalTruth':'Actual separate native observer read bus and stored file, computing digest over provider bytes; exact preserved journal equals signed observation and digest is independently rederived from supplied owned value. Temporary record files were cleaned after CI and cannot be reread offline. Signature alone does not establish external truth.','exclusions':['all eleven substrates','fresh restricted AI','generic stream functionality','production issuer delegation','production persistent key/trust lifecycle','arbitrary Linux capabilities','fresh installed release'],'artifactPins':{str(p.relative_to(a.artifacts)):pin(p) for p in sorted(a.artifacts.rglob('*')) if p.is_file()}}
 (a.output/'independent-native-green-audit.json').write_text(json.dumps(summary,indent=2)+'\n')
 print(json.dumps({'status':summary['status'],'receipts':len(receipts),'source':EXPECTED_HEAD,'runtimeSHA256':binary,'output':str(a.output/'independent-native-green-audit.json')}))
if __name__=='__main__':main()
