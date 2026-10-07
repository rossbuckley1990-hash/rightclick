"""Measure actual RIGHTCLICK subprocess acceptance. No mock success paths."""
from __future__ import annotations
import json, math, os, queue, statistics, subprocess, sys, threading, time
from pathlib import Path
from portable_common import ROOT, SHA, sha256, host, clean_environment, stop_tree, write_json

def sample(binary, http, script, cleaned=False):
    started = time.perf_counter(); lines = []; milestones = {}; messages = queue.Queue()
    command = [sys.executable, "-u", str(script), str(binary)] + (['--http'] if http else [])
    kwargs = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == 'nt' else {'start_new_session': True}
    p = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding='utf-8', errors='replace', env=clean_environment() if cleaned else None, **kwargs)
    def collect():
        try:
            for line in p.stdout: messages.put((time.perf_counter(), line))
        finally: messages.put((time.perf_counter(), None))
    threading.Thread(target=collect, daemon=True).start()
    result = {'result': 'FAIL', 'milestones_ms': milestones}
    try:
        deadline = started + 180
        while True:
            stamp,line = messages.get(timeout=max(0.01,deadline-time.perf_counter()))
            if line is None: break
            lines.append(line)
            if len(''.join(lines)) > 2_000_000: raise RuntimeError('Acceptance output exceeded bound')
            for marker,key in [('PASS generated client configuration','configuration_ready'),
                               ('PASS declared returned-text postcondition','first_verified_action')]:
                if line.startswith(marker): milestones.setdefault(key,round((stamp-started)*1000,3))
        code = p.wait(timeout=max(0.01,deadline-time.perf_counter()))
        output = ''.join(lines); start = output.rfind('\n{')
        if code != 0 or start < 0: raise RuntimeError('Acceptance failed with exit ' + str(code))
        receipt = json.loads(output[start:])
        if receipt.get('result') != 'PASS' or len(receipt.get('checks',[])) < 10 or 'first_verified_action' not in milestones:
            raise RuntimeError('Incomplete acceptance receipt')
        result.update(result='PASS',checks=receipt['checks'],platform=receipt.get('platform'))
    except Exception as error:
        result['error'] = str(error); stop_tree(p)
    finally:
        result['elapsed_ms'] = round((time.perf_counter()-started)*1000,3)
        result['log_tail'] = ''.join(lines)[-12000:]
        if p.stdout: p.stdout.close()
    return result

def measure(binary, output, source, count=3, http=False, script=None, cleaned=False):
    binary = Path(binary).resolve(strict=True)
    if not SHA.fullmatch(source): raise ValueError('Expected a full source commit SHA')
    if not 1 <= count <= 20: raise ValueError('samples must be 1..20')
    script = Path(script or ROOT/'scripts/acceptance-portable.py').resolve(strict=True)
    report = {'schema':1,'scenario':'portable-local-fixture-v1','sourceSHA':source,
        'binarySHA256':sha256(binary),'host':host(),'http':http,'cleaned_environment':cleaned,
        'measurement_boundary':'Observer wall time from acceptance subprocess start; includes local fixture setup and safety checks. Not human onboarding time or a performance comparison.',
        'baseline':None,'samples':[],'result':'FAIL'}
    for _ in range(count):
        run = sample(binary,http,script,cleaned); report['samples'].append(run)
        write_json(output,report)
        if run['result'] != 'PASS': return report
    values = sorted(r['milestones_ms']['first_verified_action'] for r in report['samples'])
    report.update(result='PASS',summary={'first_verified_action_ms':{'median':statistics.median(values),'p95':values[math.ceil(.95*len(values))-1]},'successful_runs':len(values),'attempted_runs':len(report['samples'])})
    write_json(output,report); return report
