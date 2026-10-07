from pathlib import Path
import subprocess,json,hashlib,sys,time,os,urllib.request,urllib.error,re
work=Path(__file__).parent; evidence=work/'evidence'; root=work/'extracted/rightclick-0.2.2';copy=work/'checkout'
provider=root/'scripts/rcir-dispatch-test-provider.py';test=root/'Tests/RightClickCoreTests/RCIRProductionDispatchTests.swift'
state=work/'startup-provider-state-green';state.mkdir(exist_ok=True)
launch=['/usr/bin/python3',str(provider),str(state)]
with (evidence/'provider-startup-green.log').open('w') as output:
 process=subprocess.Popen(launch,cwd=root,stdout=output,stderr=output)
 deadline=time.monotonic()+10
 while time.monotonic()<deadline and not (state/'port').exists():
  assert process.poll() is None,'packaged provider exited';time.sleep(.02)
 port=int((state/'port').read_text());assert port>0
 try:urllib.request.urlopen(f'http://127.0.0.1:{port}/openapi.json',timeout=5)
 except urllib.error.HTTPError as error:status=error.code;assert status==404
 finally:process.terminate();process.wait(timeout=5)
startup={'argv':launch,'cwd':str(root),'pid':process.pid,'port':port,'httpGet':'/openapi.json','httpStatus':status,'exitAfterRequestedTermination':process.returncode,'outcome':'PASS; actual packaged provider listened/responded. Startup only, no RCIR invocation claimed.'}
(evidence/'provider-startup-green.json').write_text(json.dumps(startup,indent=2)+'\n')
packhashes=[hashlib.sha256((work/f'package-{n}.tar.gz').read_bytes()).hexdigest() for n in [1,2]]
manifest=copy/'evidence/rcir-production-20261007/implementation-source.sha256';manifesthash=hashlib.sha256(manifest.read_bytes()).hexdigest();mismatches=[]
for line in manifest.read_text().splitlines():
 sha,p=line.split(None,1);p=p.lstrip('* ');f=copy/p
 if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest()!=sha:mismatches.append(p)
env=dict(os.environ,RCIR_DISPATCH_EVIDENCE=str(evidence/'native-provider-effects'),CLANG_MODULE_CACHE_PATH=str(work/'module-cache/clang'),SWIFTPM_MODULECACHE_OVERRIDE=str(work/'module-cache/swift'))
command=['swift','test','--force-resolved-versions','--filter','RCIRProductionDispatchTests']
record={'runKind':'NEW_RUN','sourceCommit':'3320d2fbf3fad75e337622da72f8d2dbec6acb65','sourceManifestSHA256':manifesthash,'sourceManifestMismatches':mismatches,'gitArchiveSHA256':hashlib.sha256((work/'git-archive.tar').read_bytes()).hexdigest(),'packageSHA256':packhashes,'identicalPackageBytes':packhashes[0]==packhashes[1],'packageExits':[int((evidence/f'package-{n}.exit').read_text()) for n in [1,2]],'extractedRoot':str(root),'providerSHA256':hashlib.sha256(provider.read_bytes()).hexdigest(),'testSHA256':hashlib.sha256(test.read_bytes()).hexdigest(),'unchangedProvider':provider.read_bytes()==(copy/'scripts/rcir-dispatch-test-provider.py').read_bytes(),'unchangedProductionTests':test.read_bytes()==(copy/'Tests/RightClickCoreTests/RCIRProductionDispatchTests.swift').read_bytes(),'providerStartup':startup,'initialSandboxAttempt':'FAIL: loopback bind PermissionError Errno1; preserved provider-startup.log; environment failure, not production RED','nativeTestCommand':command,'nativeTestCwd':str(root),'nativeTests':'IN_PROGRESS','environment':{'swift':subprocess.check_output(['swift','--version'],text=True).strip(),'os':subprocess.check_output(['sw_vers'],text=True).strip(),'uname':subprocess.check_output(['uname','-sm'],text=True).strip(),'python':subprocess.check_output(['/usr/bin/python3','--version'],text=True).strip(),'explicitOverrides':{k:env[k] for k in ['RCIR_DISPATCH_EVIDENCE','CLANG_MODULE_CACHE_PATH','SWIFTPM_MODULECACHE_OVERRIDE']},'permissions':'Authorised escalated build and local loopback fixture route'},'boundary':'Disposable development package only. Maintainer source/formula, release pins, tags and clients untouched. Not publication, bottle, fresh-install or full client proof.'}
(evidence/'result.json').write_text(json.dumps(record,indent=2)+'\n');(evidence/'native-command.json').write_text(json.dumps({'argv':command,'cwd':str(root),'explicitEnv':record['environment']['explicitOverrides']},indent=2)+'\n')
print(json.dumps({'evidenceDirectory':str(evidence),'packageHashes':packhashes,'sourceManifestSHA256':manifesthash,'sourceManifestMismatches':mismatches,'providerStartup':'PASS','nativeTests':'IN_PROGRESS'}),flush=True)
started=time.monotonic()
with (evidence/'native.log').open('w') as out:run=subprocess.run(command,cwd=root,env=env,stdout=out,stderr=subprocess.STDOUT)
(evidence/'native.exit').write_text(str(run.returncode)+'\n')
record['nativeExit']=run.returncode;record['nativeElapsedSeconds']=round(time.monotonic()-started,3);record['nativeTests']='PASS' if run.returncode==0 else 'FAIL';record['summaryLines']=[l for l in (evidence/'native.log').read_text().splitlines() if 'Executed ' in l][-3:]
record['builtBinaries']={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'.build').rglob('*') if p.is_file() and (p.name=='rightclick' or p.name=='rightclick-mcpPackageTests')}
files=list((evidence/'native-provider-effects').glob('*.json'));record['actualProviderEvidenceFiles']=len(files);record['providerEffectCounts']={f.name:len(json.loads(f.read_text())['effects']) for f in files}
(evidence/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2),flush=True);sys.exit(run.returncode)
