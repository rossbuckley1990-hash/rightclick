from pathlib import Path
import subprocess,json,hashlib,time,concurrent.futures
work=Path(__file__).parent;e=work/'evidence';copy=work/'checkout';binary=work/'extracted/rightclick-0.2.2/.build/arm64-apple-macosx/debug/rightclick'
expected='9b6564c49112debe54efc8f6cb53a62a337e4240fa389506386cde086b71d464';assert hashlib.sha256(binary.read_bytes()).hexdigest()==expected
runs=[('acceptance-rcir-openapi.py','packaged-public-seven'),('acceptance-rcir-openapi-freshness.py','packaged-public-freshness-ten')]
def run(item):
 name,label=item;script=copy/'scripts'/name;frozen=copy/'evidence/rcir-production-20261007/preregistration'/name;assert script.read_bytes()==frozen.read_bytes();target=e/label;assert not target.exists();cmd=['/usr/bin/python3',str(script),str(binary),str(target)]
 started=time.monotonic()
 with (e/(label+'.log')).open('w') as log:status=subprocess.run(cmd,cwd=copy,stdout=log,stderr=subprocess.STDOUT)
 (e/(label+'.exit')).write_text(str(status.returncode)+'\n')
 record={'runKind':'NEW_RUN','sourceCommit':'3320d2fbf3fad75e337622da72f8d2dbec6acb65','script':str(script),'scriptSHA256':hashlib.sha256(script.read_bytes()).hexdigest(),'preregistrationByteIdentical':True,'binary':str(binary),'binarySHA256':expected,'binarySHA256AfterRun':hashlib.sha256(binary.read_bytes()).hexdigest(),'argv':cmd,'cwd':str(copy),'exit':status.returncode,'elapsedSeconds':round(time.monotonic()-started,3),'evidenceDirectory':str(target),'boundary':'Engineering public MCP proof against a fresh source-package build; disposable Bonjour/HTTP provider and ephemeral fixture signer. Not published/installed bottle or restricted eleven-substrate proof agent.'}
 (e/(label+'-run.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True);return record
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,runs))
(e/'packaged-public-runs.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['exit']==0 for r in results) else 1)
