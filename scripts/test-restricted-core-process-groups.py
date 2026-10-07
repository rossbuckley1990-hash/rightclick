import argparse, importlib.util, json, os, pathlib, signal, subprocess, sys, tempfile, time

parser=argparse.ArgumentParser(); parser.add_argument('--driver',type=pathlib.Path,required=True); args=parser.parse_args(); source=args.driver.resolve()
spec = importlib.util.spec_from_file_location('reviewed_broker', source)
broker = importlib.util.module_from_spec(spec); spec.loader.exec_module(broker)
root = pathlib.Path(tempfile.mkdtemp(prefix='rightclick-broker-a081-owned-diagnostic-'))
child_source = root / 'owned-group.py'
child_source.write_text('''import os,pathlib,signal,sys,time
pid=os.fork()
if pid == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
    time.sleep(120)
else:
    if len(sys.argv) > 2 and sys.argv[2] == 'exit-leader':
        time.sleep(.1)
    else:
        time.sleep(120)
''')
results=[]
for kind in ['RPC.close', 'RPC.close_leader_already_exited', 'host_timeout']:
    pidfile = root / (kind + '.pid')
    endpoint = None
    original_popen = broker.subprocess.Popen
    owned=[]
    def recording_popen(*args, **kwargs):
        process=original_popen(*args, **kwargs); owned.append(process); return process
    broker.subprocess.Popen=recording_popen
    try:
        argv=[sys.executable, str(child_source), str(pidfile)]
        if kind.startswith('RPC.close'):
            if kind.endswith('already_exited'): argv.append('exit-leader')
            endpoint=broker.RPC(argv, root, 'owned-rpc', os.environ.copy())
            deadline=time.monotonic()+5
            while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.02)
            if not pidfile.exists(): raise RuntimeError('diagnostic descendant did not start')
            if kind.endswith('already_exited'): endpoint.process.wait(timeout=5)
            endpoint.close()
        else:
            try: broker.host_command(root, 0, 'owned-timeout', argv, os.environ.copy(), .5)
            except subprocess.TimeoutExpired: pass
        descendant=int(pidfile.read_text())
        time.sleep(.1)
        try: os.kill(descendant, 0); alive=True
        except ProcessLookupError: alive=False
        results.append({'control':kind,'leaderExited':owned[0].poll() is not None,'ownedDescendantStillAlive':alive,'leaderPID':owned[0].pid,'descendantPID':descendant})
    finally:
        broker.subprocess.Popen=original_popen
        for process in owned:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
(root/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps({'source':str(source),'diagnosticOutput':str(root),'controls':results},indent=2))

raise SystemExit(1 if any(case['ownedDescendantStillAlive'] for case in results) else 0)
