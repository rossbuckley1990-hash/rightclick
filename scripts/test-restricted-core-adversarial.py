#!/usr/bin/env python3
"""Frozen review controls: explicit catalogue fixtures plus real child cleanup."""
import argparse,copy,hashlib,importlib.util,inspect,json,os,pathlib,signal,subprocess,sys
NAMES=['context_runtime','context_inspect','context_actions','context_explain','context_run','context_run_status','context_providers']
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--driver',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 spec=importlib.util.spec_from_file_location('restricted_driver',a.driver);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 schema={'type':'object','properties':{},'additionalProperties':False}
 expected=[{'type':'function','name':n,'description':'Fixture only','inputSchema':copy.deepcopy(schema),'deferLoading':False} for n in NAMES]
 valid={'tools':[],'additionalTools':[{'type':'additional_tools','tools':[{'type':'namespace','name':'functions','tools':[{'type':'function','name':n,'description':'Fixture only','parameters':copy.deepcopy(schema),'strict':False} for n in NAMES]}]}],'otherToolFields':{'tool_choice':'auto','parallel_tool_calls':False}}
 results={}
 for label in ['changed_parameter_schema','undeclared_builtin_tool_field']:
  record=copy.deepcopy(valid)
  if label=='changed_parameter_schema':record['additionalTools'][0]['tools'][0]['tools'][4]['parameters']={'type':'object','properties':{'shell':{'type':'string'}},'required':['shell'],'additionalProperties':False}
  else:record['otherToolFields']['builtin_tools']=[{'type':'shell'}]
  try:
   if len(inspect.signature(module.validate_capture).parameters)==1:module.validate_capture([record])
   else:module.validate_capture([record],expected)
   results[label]={'result':'FAIL','reason':'Invalid catalogue accepted'}
  except RuntimeError as error:results[label]={'result':'PASS','reason':str(error)}
  except Exception as error:results[label]={'result':'FAIL','setupOrUnexpectedFailure':str(error)}
 case=out/'cleanup';case.mkdir();rpc=module.RPC([sys.executable,'-c','import time; time.sleep(90)'],case,'owned-child',dict(os.environ));original=module.save
 def failed_save(*_):raise OSError('Controlled evidence write failure')
 module.save=failed_save
 try:
  try:rpc.close()
  except OSError:pass
  alive=rpc.process.poll() is None
  results['evidence_failure_still_terminates_owned_child']={'result':'FAIL' if alive else 'PASS','childStillRunning':alive,'pid':rpc.process.pid,'failure':'Controlled save OSError'}
 finally:
  module.save=original
  if rpc.process.poll() is None:os.killpg(rpc.process.pid,signal.SIGKILL);rpc.process.wait()
  rpc.stderr.close();rpc.trace.close()
 report={'proofKind':'CLIENT_SECURITY_FIXTURES_AND_ACTUAL_OWNED_CHILD_NOT_PROVIDER_OR_AI_ACCEPTANCE','driverSHA256':hashlib.sha256(a.driver.read_bytes()).hexdigest(),'controlSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'controls':results,'result':'PASS' if all(v['result']=='PASS' for v in results.values()) else 'FAIL'}
 (out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));return 0 if report['result']=='PASS' else 1
if __name__=='__main__':raise SystemExit(main())
