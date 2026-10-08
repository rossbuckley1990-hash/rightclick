#!/usr/bin/env python3
"""Controlled loopback adaptation of repository acceptance-federation.py.

Reuse the unchanged federation-proof OpenAPI/response fixtures at an immutable HTTPS ref.
All runtime capability operations use the existing seven public RIGHTCLICK tools.
Fixture provisioning remains separate; no descriptors or new substrate features.
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path('/private/tmp/rightclick-root-stream-integration-20261007')
NAMES = {'context_runtime', 'context_providers', 'context_inspect', 'context_actions',
         'context_explain', 'context_run', 'context_run_status'}
REF = '7a935fea719601492fe05beba1a4223c283eb350'
TITLE = 'Read federation proof'


def require(condition, message):
    if not condition: raise AssertionError(message)


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args(); out = args.output.resolve(); binary = args.binary.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    specification = (ROOT / 'fixtures/federation-proof/openapi.json').read_bytes()
    expected_bytes = (ROOT / 'fixtures/federation-proof/result.txt').read_bytes()
    expected = expected_bytes.decode()
    (out / 'openapi.json').write_bytes(specification); (out / 'provider-source.txt').write_bytes(expected_bytes)
    route = '/rossbuckley1990-hash/rightclick/' + REF + '/fixtures/federation-proof/result.txt'
    provider_journal = []; lock = threading.Lock()

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if self.path == '/openapi.json':
                data, content_type = specification, 'application/json'
            elif self.path == route:
                data, content_type = expected_bytes, 'text/plain'
            else:
                self.send_error(404); return
            row = {'path': self.path, 'method': 'GET', 'bodySHA256': hashlib.sha256(data).hexdigest(),
                   'authorizationPresent': bool(self.headers.get('Authorization')),
                   'cookiePresent': bool(self.headers.get('Cookie')), 'time': time.time()}
            with lock:
                provider_journal.append(row)
                with (out / 'provider-requests.jsonl').open('a') as handle: handle.write(json.dumps(row) + '\n')
            self.send_response(200); self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

    # The prior configured-provider profile requires HTTPS. Use its original
    # immutable repository-owned fixture rather than weakening that restriction.
    origin = 'https://raw.githubusercontent.com'
    spec_url = origin + '/rossbuckley1990-hash/rightclick/' + REF + '/fixtures/federation-proof/openapi.json'
    independent_reads = []
    for url, expected_source, filename in [(spec_url, specification, 'independent-specification.json'),
                                          (origin + route, expected_bytes, 'independent-source.txt')]:
        with urllib.request.urlopen(url, timeout=15) as response:
            require(response.status == 200, 'immutable HTTPS fixture unavailable')
            observed = response.read(65537)
        require(observed == expected_source, 'immutable HTTPS fixture differs from local fixture')
        (out / filename).write_bytes(observed)
        independent_reads.append({'url': url, 'sha256': hashlib.sha256(observed).hexdigest(), 'bytes': len(observed)})
    homes = {}; environments = {}; processes = {}; logs = {}; urls = {}; tokens = {}; transcripts = {'a': [], 'b': []}
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest(); request_id = 0
    report = {'result': 'FAIL', 'binary': str(binary), 'binarySHA256': binary_hash,
              'scope': 'existing authenticated loopback MCP HTTP and RIGHTCLICK federation over prior immutable HTTPS OpenAPI fixture',
              'fixtureSpecificationSHA256': hashlib.sha256(specification).hexdigest(),
              'fixtureTextSHA256': hashlib.sha256(expected_bytes).hexdigest(),
              'providerOrigin': origin, 'expectedReadPath': route, 'independentSourceReads': independent_reads,
              'exclusions': ['MCP descriptor acquisition substrate', 'new streams or auth mechanisms',
                             'issuer authentication or downscoping', 'fresh restricted AI', 'all eleven substrates', 'shipping']}

    def read_count():
        with lock: return sum(row['path'] == route for row in provider_journal)

    def rpc(role, method, params=None, bearer=True):
        nonlocal request_id
        request_id += 1
        body = {'jsonrpc': '2.0', 'id': request_id, 'method': method}
        if params is not None: body['params'] = params
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json', 'MCP-Protocol-Version': '2025-03-26'}
        if bearer is True: headers['Authorization'] = 'Bearer ' + tokens[role]
        elif bearer is not None: headers['Authorization'] = 'Bearer ' + bearer
        request = urllib.request.Request(urls[role], data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=40) as response:
            require(response.status == 200, 'MCP HTTP status differs'); reply = json.load(response)
        require('error' not in reply, 'public JSON-RPC error: ' + json.dumps(reply))
        transcripts[role].append({'request': body, 'response': reply})
        return reply['result']

    def call(role, name, arguments):
        require(name in NAMES, 'unexpected runtime operation')
        value = rpc(role, 'tools/call', {'name': name, 'arguments': arguments})
        require(not value.get('isError'), 'canonical operation error: ' + json.dumps(value))
        decoded = json.loads(value['content'][0]['text'])
        if name == 'context_actions':
            value['content'][0]['text'] = json.dumps(dict(decoded, actions=[row for row in decoded['actions'] if row['title'] == TITLE]))
        elif name == 'context_providers':
            count = len(decoded) if isinstance(decoded, list) else len(decoded['providers'])
            value['content'][0]['text'] = json.dumps({'providerCount': count})
        return decoded

    def actions(role):
        return call(role, 'context_actions', {'item': 'RIGHTCLICK existing federation parity'})['actions']

    def find(rows): return next((row for row in rows if row['title'] == TITLE), None)

    def wait_listener(role):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            require(processes[role].poll() is None, 'runtime exited before HTTP listener')
            try:
                with socket.create_connection(('127.0.0.1', ports[role]), timeout=.2): return
            except OSError: time.sleep(.1)
        raise TimeoutError('HTTP listener did not start')

    def configure(command):
        raw = subprocess.check_output([str(binary), 'provider', *command, '--json'], env=environments['b'], text=True)
        return json.loads(raw)

    ports = {'a': free_port(), 'b': free_port()}
    try:
        for role in ('b', 'a'):
            home = out / (role + '-home'); home.mkdir(mode=0o700); homes[role] = home
            environment = {key: value for key, value in os.environ.items() if not key.startswith('RIGHTCLICK_')}
            environment['CFFIXED_USER_HOME'] = str(home)
            token = uuid.uuid4().hex + uuid.uuid4().hex; tokens[role] = token
            environment['RIGHTCLICK_MCP_TOKEN'] = token
            environment['RIGHTCLICK_CAPABILITY_EXPERIENCE'] = 'disabled'
            if role == 'a':
                environment['RIGHTCLICK_FEDERATION_B_TOKEN'] = tokens['b']
                environment['RIGHTCLICK_FEDERATION_PEERS'] = json.dumps([{'id': 'peer-b', 'name': 'RIGHTCLICK Runtime B',
                    'endpoint': 'http://127.0.0.1:' + str(ports['b']) + '/mcp', 'tokenEnvironment': 'RIGHTCLICK_FEDERATION_B_TOKEN'}])
            environments[role] = environment
            logs[role] = (out / ('runtime-' + role + '.stderr.log')).open('w')
            processes[role] = subprocess.Popen([str(binary), 'mcp', '--http', '--port', str(ports[role])],
                env=environment, stdout=subprocess.DEVNULL, stderr=logs[role])
            urls[role] = 'http://127.0.0.1:' + str(ports[role]) + '/mcp'
        runtime_rows = {}; catalogues = {}; authority_controls = []
        for role in ('a', 'b'):
            wait_listener(role)
            binding = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-p', str(processes[role].pid),
                '-iTCP', '-sTCP:LISTEN', '-Fn'], text=True)
            require('n127.0.0.1:' + str(ports[role]) in binding and 'n*:' not in binding, 'listener is not loopback only')
            (out / ('listener-' + role + '.txt')).write_text(binding)
            for bearer in (None, 'invalid-controlled-test-token'):
                try:
                    rpc(role, 'initialize', {}, bearer=bearer)
                    raise AssertionError('missing or incorrect HTTP bearer accepted')
                except urllib.error.HTTPError as error:
                    require(error.code == 401, 'incorrect HTTP credential response')
                    authority_controls.append({'role': role, 'credential': 'absent' if bearer is None else 'incorrect', 'status': error.code})
            initialized = rpc(role, 'initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                'clientInfo': {'name': 'existing-federation-parity', 'version': '1'}})
            catalogue = rpc(role, 'tools/list')['tools']; catalogues[role] = catalogue
            require(len(catalogue) == 7 and {tool['name'] for tool in catalogue} == NAMES, 'canonical catalogue changed')
            runtime = call(role, 'context_runtime', {}); runtime_rows[role] = runtime
            require(runtime['executableSHA256'] == binary_hash and runtime['pid'] == processes[role].pid and runtime['transport'] == 'http',
                    'runtime provenance differs from actual process')
            require(initialized['serverInfo']['version'] == runtime['version'], 'initialize version differs')
            call(role, 'context_providers', {})
            call(role, 'context_inspect', {'item': 'RIGHTCLICK existing federation parity'})
            require(find(actions(role)) is None, 'remote fixture existed before provisioning')
        require(runtime_rows['a']['pid'] != runtime_rows['b']['pid'], 'runtimes are not independent')
        configured = configure(['add', '--id', 'federation-live-proof', '--spec-url', spec_url, '--base-url', origin])
        require(Path(configured['configuration']).resolve().is_relative_to(homes['b'].resolve()), 'provider escaped private B home')
        require(not (homes['a'] / 'Library/Application Support/RIGHTCLICK/providers.json').exists(), 'A has a local fixture provider')
        deadline = time.monotonic() + 30; remote = federated = None
        while time.monotonic() < deadline:
            remote, federated = find(actions('b')), find(actions('a'))
            if remote and federated: break
            time.sleep(.2)
        require(remote and federated, 'live remote capability did not appear')
        require(not remote['id'].startswith('federation:') and federated['id'].startswith('federation:peer-b:') and
                federated['provider']['name'] == 'RIGHTCLICK Runtime B' and federated['requiresConfirmation'] is True,
                'remote confirmation or identity changed')
        explanation = call('a', 'context_explain', {'item': 'RIGHTCLICK existing federation parity', 'actionId': federated['id']})
        require(explanation['metadata']['federationRuntimeSHA256'] == binary_hash, 'peer binary attestation changed')
        invocation = {'item': 'RIGHTCLICK existing federation parity', 'actionId': federated['id'], 'arguments': {'ref': REF}}
        gated = call('a', 'context_run', invocation)
        require(gated['state'] == 'awaiting_user', 'remote confirmation gate changed')
        accepted = call('a', 'context_run', {**invocation, 'confirmed': True})
        require(accepted['state'] == 'accepted' and accepted['output'] == expected and accepted['evidence']['outcomeVerified'] is False,
                'remote acceptance/output changed')
        retained = call('a', 'context_run_status', {'executionId': accepted['executionId']})
        require(retained == accepted, 'accepted retained status differs')
        verified = call('a', 'context_run', {**invocation, 'confirmed': True,
            'verification': {'predicates': [{'type': 'text_equals', 'value': expected}]}})
        require(verified['state'] == 'succeeded' and verified['output'] == expected and verified['evidence']['outcomeVerified'] is True and
                verified['verification']['status'] == 'VERIFIED_SUCCESS', 'prior caller text postcondition changed')
        verified_status = call('a', 'context_run_status', {'executionId': verified['executionId']})
        require(verified_status == verified, 'verified retained status differs')
        require('federation peer peer-b' in verified['events'], 'no genuine federation execution evidence')
        removed = configure(['remove', '--id', 'federation-live-proof'])
        require(removed['status'] == 'REMOVED', 'provider removal failed')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if find(actions('b')) is None and find(actions('a')) is None: break
            time.sleep(.2)
        else: raise AssertionError('remote capability did not disappear live')
        after_removal = call('a', 'context_run_status', {'executionId': verified['executionId']})
        require(after_removal == verified, 'retained history lost after withdrawal')
        for role in ('a', 'b'):
            require(call(role, 'context_runtime', {})['pid'] == runtime_rows[role]['pid'], 'runtime restarted')
        report.update(result='PASS', runtimes=runtime_rows, tools=catalogues, authorityControls=authority_controls,
            remoteCapability=remote, federatedCapability=federated, explanation=explanation, confirmation=gated,
            accepted=accepted, retained=retained, verifiedReturnedText=verified, verifiedStatus=verified_status,
            retainedAfterWithdrawal=after_removal, successfulFederatedInvocations=2, appearedLive=True, disappearedLive=True,
            runtimesRestarted=False, upstreamNativeCallCount='NOT_INDEPENDENTLY_OBSERVED',
            upstreamRequestHeaders='NOT_INDEPENDENTLY_OBSERVED',
            externalTruthBoundary='accepted remains unverified; caller text_equals establishes returned-text postcondition. Immutable HTTPS source bytes independently match local fixture bytes; no broader remote state change or exact upstream native call count claimed.',
            canonicalOperationsUsed=sorted({row['request']['params']['name'] for row in transcripts['a']
                if row['request']['method'] == 'tools/call'}))
    except Exception as error:
        report['unexpectedFailure'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        for role in ('a', 'b'):
            if role in processes and processes[role].poll() is None:
                processes[role].terminate()
                try: processes[role].wait(timeout=8)
                except subprocess.TimeoutExpired: processes[role].kill(); processes[role].wait(timeout=3)
            if role in logs: logs[role].close()
            (out / ('transcript-' + role + '.json')).write_text(json.dumps(transcripts[role], indent=2) + '\n')
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': report['result'], 'output': str(out), 'failure': report.get('unexpectedFailure')}))
    return 0 if report['result'] == 'PASS' else 1


if __name__ == '__main__': raise SystemExit(main())
