#!/usr/bin/env python3
"""Independent read-only client-session structure check, never world acceptance."""
import argparse, hashlib, json, pathlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--completed-phases', type=int, required=True)
args = parser.parse_args(); root = args.output.resolve()
def records(name): return [json.loads(line) for line in (root / name).read_text().splitlines()]
app = records('app-server-transcript.jsonl'); runtime = records('rightclick-transcript.jsonl')
calls = [r['message']['params'] for r in app if r['direction'] == 'server' and r['message'].get('method') == 'item/tool/call']
turns = [r['message']['params'] for r in app if r['direction'] == 'client' and r['message'].get('method') == 'turn/start']
starts = [r for r in app if r['direction'] == 'client' and r['message'].get('method') == 'thread/start']
request_ids = {r['message']['id'] for r in runtime if r['direction'] == 'client' and r['message'].get('method') == 'tools/call' and r['message']['params']['name'] == 'context_runtime'}
attestations = [json.loads(r['message']['result']['content'][0]['text']) for r in runtime if r['direction'] == 'server' and r['message'].get('id') in request_ids and 'result' in r['message']]
expected = json.loads((root / 'runtime.json').read_text())
canonical = {'context_runtime', 'context_providers', 'context_inspect', 'context_actions', 'context_explain', 'context_run', 'context_run_status'}
checks = {'oneFreshThread': len(starts) == 1 and starts[0]['message']['params']['ephemeral'] is True,
          'sameThreadAcrossTurns': len(turns) == args.completed_phases and len({t['threadId'] for t in turns}) == 1,
          'modelCallsUseOnlyCanonicalSeven': bool(calls) and all(c['tool'] in canonical for c in calls),
          'noCapabilityDispatch': not any(c['tool'] == 'context_run' for c in calls),
          'modelRuntimeAndProviderCallsEachPhase': all(sum(c['tool'] == 'context_runtime' for c in calls if c['threadId'] == t['threadId']) >= args.completed_phases for t in turns) and sum(c['tool'] == 'context_providers' for c in calls) >= args.completed_phases,
          'sameServingRuntimePIDAndBytes': len(attestations) >= args.completed_phases + 1 and all(a['pid'] == expected['pid'] and a['executableSHA256'] == expected['executableSHA256'] for a in attestations)}
report = {'proofKind': 'ACTUAL_CLIENT_READONLY_SESSION_STRUCTURE_NOT_UNIVERSAL_ACCEPTANCE', 'checks': checks, 'runtimePID': expected['pid'], 'runtimeBinarySHA256': expected['executableSHA256'], 'modelCallCount': len(calls), 'transcriptSHA256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in ['app-server-transcript.jsonl', 'rightclick-transcript.jsonl']}, 'result': 'PASS' if all(checks.values()) else 'FAIL'}
target = root / ('independent-session-phase-' + str(args.completed_phases) + '.json'); target.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2)); raise SystemExit(0 if report['result'] == 'PASS' else 1)
