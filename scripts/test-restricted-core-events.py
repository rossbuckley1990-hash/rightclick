#!/usr/bin/env python3
"""Controlled fake RPC notifications test attribution, never real AI inference."""
import argparse, collections, contextlib, hashlib, importlib.util, io, json, pathlib, sys

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args(); out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('driver', args.driver)
    driver = importlib.util.module_from_spec(spec); spec.loader.exec_module(driver)
    catalog = out / 'public-fixture-catalog.json'; catalog.write_text(json.dumps({'models': [{'slug': 'controlled-fixture'}]}))
    schema = {'type': 'object', 'properties': {}, 'additionalProperties': False}
    tools = [{'name': name, 'description': 'Controlled client fixture', 'inputSchema': schema} for name in sorted(driver.CANONICAL)]
    state = {'events': [], 'runtimeRunCalls': 0}
    class FakeRPC:
        def __init__(self, command, root, label, environment, jsonrpc=False):
            self.runtime = jsonrpc; self.next_id = 100; self.events = collections.deque(state['events'])
        def call(self, method, params=None, timeout=55):
            if method == 'initialize': return {}
            if method == 'tools/list': return {'tools': tools}
            if method == 'tools/call':
                if params['name'] == 'context_run': state['runtimeRunCalls'] += 1
                value = {'executableSHA256': driver.digest(pathlib.Path(sys.executable).resolve()), 'controlledClientFixture': True}
                return {'content': [{'type': 'text', 'text': json.dumps(value)}]}
            if method == 'thread/start': return {'thread': {'id': 'owned-thread', 'sessionId': 'owned-session'}, 'model': 'controlled-fixture'}
            if method == 'turn/start': return {'turn': {'id': 'owned-turn'}}
            raise RuntimeError('Unexpected fixture request: ' + method)
        def receive(self, timeout): return self.events.popleft()
        def send(self, value): pass
        def close(self): pass
    driver.RPC = FakeRPC
    driver.native_client = lambda _: pathlib.Path(sys.executable).resolve()
    original_argv = sys.argv
    def run(name, proof=None, discovery=False):
        target = out / name
        sys.argv = ['controlled-fixture', '--actual', '--runtime', sys.executable, '--codex', sys.executable, '--catalog-source', str(catalog), '--output', str(target)]
        if proof: sys.argv += ['--catalog-proof', str(proof)]
        if discovery: sys.argv += ['--discovery-only']
        with contextlib.redirect_stdout(io.StringIO()): code = driver.main()
        return code, json.loads((target / 'summary.json').read_text())
    try:
        _, seed = run('preflight-seed')
        capture = out / 'request-catalog.json'
        capture.write_text(json.dumps([{'tools': [{'type': 'function', 'name': t['name'], 'description': t['description'], 'parameters': schema, 'strict': False} for t in tools], 'otherToolFields': {'tool_choice': 'auto', 'parallel_tool_calls': False}}]))
        proof = out / 'proof.json'; seed.update(clientBoundary='PASS', actualAIInference=False, captureCatalogSHA256=driver.digest(capture)); proof.write_text(json.dumps(seed))
        results = {}
        for case in ['owned_message', 'foreign_thread', 'foreign_turn']:
            params = {'threadId': 'foreign' if case == 'foreign_thread' else 'owned-thread', 'turnId': 'foreign' if case == 'foreign_turn' else 'owned-turn', 'itemId': 'controlled-item', 'delta': 'Controlled fixture text'}
            state['events'] = [{'method': 'item/agentMessage/delta', 'params': params}, {'method': 'turn/completed', 'params': {'threadId': 'owned-thread', 'turn': {'id': 'owned-turn', 'status': 'completed'}}}]
            code, summary = run(case, proof)
            passed = code == 0 if case == 'owned_message' else code != 0 and summary['actualAIInference'] is False
            results[case] = {'result': 'PASS' if passed else 'FAIL', 'driverExit': code, 'driverInferenceClaimFromControlledFixture': summary['actualAIInference'], 'failure': summary.get('failure')}
        report = {'proofKind': 'CONTROLLED_RPC_NOTIFICATION_FIXTURES_NO_ACTUAL_INFERENCE', 'driverSHA256': driver.digest(args.driver), 'controlSHA256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(), 'controls': results, 'result': 'PASS' if all(x['result'] == 'PASS' for x in results.values()) else 'FAIL'}
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))
        return 0 if report['result'] == 'PASS' else 1
    finally: sys.argv = original_argv

if __name__ == '__main__': raise SystemExit(main())
