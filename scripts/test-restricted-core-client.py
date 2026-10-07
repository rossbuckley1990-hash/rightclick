#!/usr/bin/env python3
"""Frozen client-isolation controls. MCP is an explicit fixture, never substrate proof."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

NAMES = ['context_runtime', 'context_inspect', 'context_actions', 'context_explain', 'context_run', 'context_run_status', 'context_providers']
FIXTURE = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys
names=['context_runtime','context_inspect','context_actions','context_explain','context_run','context_run_status','context_providers']
mode=os.environ['RC_CLIENT_CONTROL_MODE']
if mode=='duplicate':names.append('context_runtime')
if mode=='extra':names.append('unexpected_provider_tool')
for line in sys.stdin:
 q=json.loads(line); method=q['method']; args=q.get('params',{})
 with open(os.environ['RC_CLIENT_CONTROL_TRACE'],'a') as log:log.write(json.dumps({'method':method,'tool':args.get('name')})+'\n')
 if 'id' not in q:continue
 if method=='initialize':result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'name':'explicit-client-control-fixture','version':'1'}}
 elif method=='tools/list':result={'tools':[{'name':n,'description':'Client isolation fixture only','inputSchema':{'type':'object','properties':{},'additionalProperties':False}} for n in names]}
 elif method=='tools/call':
  value={'providers':[]}
  if args.get('name')=='context_runtime':value={'executableSHA256':'0'*64 if mode=='forged_sha' else hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'executablePath':str(pathlib.Path(__file__).resolve()),'fixture':True}
  result={'content':[{'type':'text','text':json.dumps(value)}]}
 else:raise RuntimeError(method)
 print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':result}),flush=True)
'''

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--driver',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--catalog-source',type=pathlib.Path,required=True);a=p.parse_args()
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);results={}
 for mode in ['valid','forged_sha','duplicate','extra']:
  case=out/mode;case.mkdir();source=case/'source';source.mkdir();driver=source/'restricted-core-probe.py';shutil.copyfile(a.driver,driver)
  fixture=case/'fixture-runtime';fixture.write_text(FIXTURE);fixture.chmod(0o755)
  run=case/'run';env=dict(os.environ,RC_CLIENT_CONTROL_MODE=mode,RC_CLIENT_CONTROL_TRACE=str(case/'runtime-calls.jsonl'))
  cmd=[sys.executable,str(driver),'--runtime',str(fixture),'--catalog-source',str(a.catalog_source.resolve()),'--run-name',str(run)]
  try:
   with (case/'stdout.log').open('w') as stdout,(case/'stderr.log').open('w') as stderr:
    child=subprocess.run(cmd,env=env,stdout=stdout,stderr=stderr,timeout=120)
   capture=run/'request-catalog.json'; dynamic=run/'dynamic-tools.json'
   if mode=='valid':
    records=json.loads(capture.read_text());observed=[]
    def names(tools):
     for tool in tools:
      if tool.get('type')=='namespace':names(tool.get('tools',[]))
      else:observed.append(tool.get('name'))
    names(records[0]['tools'])
    for item in records[0].get('additionalTools',[]):names(item.get('tools',[]))
    passed=child.returncode==0 and len(observed)==7 and set(observed)==set(NAMES)
    reason='Exactly seven outgoing functions captured by actual native client against a local inference fixture.'
   else:
    passed=child.returncode!=0 and not capture.exists() and not dynamic.exists()
    reason='Invalid runtime identity/catalogue must be rejected before dynamic catalogue publication or model request.'
   results[mode]={'result':'PASS' if passed else 'FAIL','exitCode':child.returncode,'modelRequestCaptured':capture.exists(),'dynamicCataloguePublished':dynamic.exists(),'sourceDirectoryCatalogCreated':(source/'catalog.json').exists(),'boundary':reason}
  except Exception as error:results[mode]={'result':'FAIL','setupOrUnexpectedFailure':str(error)}
  print(json.dumps({mode:results[mode]}),flush=True)
 report={'proofKind':'CLIENT_BOUNDARY_FIXTURES_NOT_PROVIDER_OR_AI_ACCEPTANCE','driverSHA256':hashlib.sha256(a.driver.read_bytes()).hexdigest(),'controlSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'controls':results,'result':'PASS' if all(v['result']=='PASS' for v in results.values()) else 'FAIL'}
 (out/'results.json').write_text(json.dumps(report,indent=2)+'\n');return 0 if report['result']=='PASS' else 1
if __name__=='__main__':raise SystemExit(main())
