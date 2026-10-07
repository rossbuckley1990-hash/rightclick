#!/usr/bin/env python3
"""Build, measure and verify portable candidates; never publish an unverified release."""
from __future__ import annotations
import argparse, json, os, platform, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from portable_common import ROOT, sha256, host, write_json
from portable_acceptance import measure
from portable_bundle import safe_name, verify_bundle, verify_sdk, bundle

def ci(output):
    """Run native builds/tests and retain evidence before making candidate archives."""
    output = Path(output).resolve(); output.mkdir(parents=True,exist_ok=True)
    source = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True,timeout=15).strip()
    record = {'schema':1,'sourceSHA':source,'host':host(),'result':'FAIL','stages':[]}
    def stage(name, command, timeout=1800):
        begin=time.perf_counter(); log=output/(name+'.log')
        with log.open('w',encoding='utf-8') as f:
            proc=subprocess.run(command,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,text=True,timeout=timeout)
        record['stages'].append({'name':name,'command':command,'exit':proc.returncode,
                                'elapsed_ms':round((time.perf_counter()-begin)*1000,3),'logSHA256':sha256(log)})
        write_json(output/'validation.json',record)
        if proc.returncode: raise RuntimeError(name+' failed; see '+str(log))
    try:
        stage('packaging-unit-tests',[sys.executable,'-m','unittest','discover','-s','Tests/Packaging','-v'],60)
        record['sdk']=verify_sdk()
        stage('toolchain',['swift','--version'],30)
        stage('native-build',['swift','build','--product','rightclick','--force-resolved-versions','--jobs','2'])
        stage('native-tests',['swift','test','--force-resolved-versions','--jobs','2']+
              (['--filter','RuntimePortabilityTests'] if os.name=='nt' else []))
        build=['swift','build','-c','release','--product','rightclick','--force-resolved-versions','--jobs','2']
        if platform.system()=='Linux': build += ['-Xlinker','-rpath','-Xlinker','$ORIGIN/../lib']
        stage('release-build',build)
        bin_dir=subprocess.check_output(['swift','build','-c','release','--show-bin-path','--force-resolved-versions'],cwd=ROOT,text=True,timeout=60).strip()
        binary=Path(bin_dir)/('rightclick.exe' if os.name=='nt' else 'rightclick')
        http=platform.system() in ('Darwin','Linux')
        proof=measure(binary,output/'measurements.json',source,count=3,http=http)
        if proof['result']!='PASS': raise RuntimeError('Live binary acceptance failed')
        packaged=bundle(binary,output/'measurements.json',output,source)
        manifest=verify_bundle(packaged['archive'],packaged['sha256'],output/'relocated')
        relocated=measure(output/'relocated'/manifest['executable'],output/'relocated-acceptance.json',source,count=1,http=http,cleaned=True)
        if relocated['result']!='PASS': raise RuntimeError('Relocated candidate failed native acceptance')
        record.update(result='PASS',bundle=packaged,measurement_summary=proof['summary'],
            boundary='Native runner plus relocated clean-PATH test. Linux no-toolchain acceptance is a separate required job. Candidate only, not a published release.')
        write_json(output/'validation.json',record)
        print(json.dumps(record,indent=2)); return 0
    except Exception as error:
        record['error']=str(error);write_json(output/'validation.json',record);raise

def main():
    p=argparse.ArgumentParser(description=__doc__); subs=p.add_subparsers(dest='command',required=True)
    m=subs.add_parser('measure'); m.add_argument('binary'); m.add_argument('--source-sha',required=True); m.add_argument('--output',required=True); m.add_argument('--samples',type=int,default=3); m.add_argument('--http',action='store_true'); m.add_argument('--clean',action='store_true')
    b=subs.add_parser('bundle'); b.add_argument('binary'); b.add_argument('--report',required=True); b.add_argument('--output',required=True); b.add_argument('--source-sha',required=True)
    v=subs.add_parser('verify'); v.add_argument('archive'); v.add_argument('--sha256',required=True); v.add_argument('--destination',required=True); v.add_argument('--execute-report'); v.add_argument('--http',action='store_true')
    subs.add_parser('sdk-check')
    c=subs.add_parser('ci'); c.add_argument('--output',required=True)
    a=p.parse_args()
    if a.command=='sdk-check': print(json.dumps(verify_sdk(),indent=2)); return 0
    if a.command=='ci': return ci(a.output)
    if a.command=='measure':
        result=measure(a.binary,a.output,a.source_sha,a.samples,a.http,cleaned=a.clean)
        print(json.dumps({k:v for k,v in result.items() if k!='samples'},indent=2)); return 0 if result['result']=='PASS' else 1
    if a.command=='bundle': print(json.dumps(bundle(a.binary,a.report,a.output,a.source_sha),indent=2)); return 0
    manifest=verify_bundle(a.archive,a.sha256,a.destination)
    if a.execute_report:
        if manifest['host']!=host(): raise ValueError('Cannot claim native proof for another host')
        result=measure(Path(a.destination)/manifest['executable'],a.execute_report,manifest['sourceSHA'],1,a.http,cleaned=True)
        print(json.dumps({k:v for k,v in result.items() if k!='samples'},indent=2)); return 0 if result['result']=='PASS' else 1
    print('PASS archive and member integrity; executable not run'); return 0

if __name__ == '__main__':
    try: sys.exit(main())
    except Exception as error: print('FAIL: '+str(error),file=sys.stderr); sys.exit(1)

