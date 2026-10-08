#!/usr/bin/env python3
"""Legacy-only control adapted from acceptance-graphql-typed.py and the repository canonical client.

The official GraphQL server scaffold is reused with prior String/record shapes.
No typed-receipt, descriptor-artifact, issuer, stream or new substrate feature is exercised.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid

import graphql
from graphql import build_schema, graphql_sync

ROOT = Path('/private/tmp/rightclick-root-stream-integration-20261007')
spec = importlib.util.spec_from_file_location('repository_canonical_client', ROOT / 'scripts/canonical-mcp-proof-client.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
Client = module.Client
SDL = '''input LegacyRecordInput { label: String! }
type LegacyRecord { label: String! }
type Query { legacyParityEcho(value: String!): String! }
type Mutation { legacyParityRecord(input: LegacyRecordInput!): LegacyRecord! }
'''


def require(condition, message):
    if not condition: raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args(); out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    (out / 'schema.graphql').write_text(SDL)
    # Discard unrelated inherited attachments from this isolated engineering process.
    for key in list(os.environ):
        if key.startswith('RIGHTCLICK_'): os.environ.pop(key)
    service_name = 'RIGHTCLICK legacy GraphQL parity ' + uuid.uuid4().hex[:12]
    hostname = 'rightclick-gql-parity-' + uuid.uuid4().hex[:12] + '.local.'
    lock = threading.Lock(); requests = []; effects = []
    schema = build_schema(SDL)
    schema.get_type('Query').fields['legacyParityEcho'].resolve = lambda *_, value: value

    def mutation(_root, _info, input):
        result = {'label': input['label']}
        destination = out / ('effect-' + hashlib.sha256(input['label'].encode()).hexdigest() + '.json')
        with lock:
            destination.write_text(json.dumps(result, sort_keys=True))
            row = {'input': input, 'value': result, 'file': str(destination), 'time': time.time()}
            effects.append(row)
            with (out / 'effects.jsonl').open('a') as handle: handle.write(json.dumps(row) + '\n')
        return result

    schema.get_type('Mutation').fields['legacyParityRecord'].resolve = mutation

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            size = int(self.headers.get('Content-Length', '0'))
            if self.path != '/graphql' or not 0 < size <= 65536:
                self.send_error(400); return
            request = json.loads(self.rfile.read(size))
            result = graphql_sync(schema, request['query'], variable_values=request.get('variables'),
                                  operation_name=request.get('operationName'))
            response = result.formatted
            row = {'request': request, 'response': response, 'introspection': '__schema' in request['query'],
                   'authorizationPresent': bool(self.headers.get('Authorization')),
                   'cookiePresent': bool(self.headers.get('Cookie')), 'time': time.time()}
            with lock:
                requests.append(row)
                with (out / 'provider-requests.jsonl').open('a') as handle: handle.write(json.dumps(row) + '\n')
            body = json.dumps(response).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    (out / 'provider-port').write_text(str(server.server_port))
    advertisement_output = (out / 'advertisement.log').open('wb')
    advertisement_error = (out / 'advertisement.stderr').open('wb')
    advertisement = subprocess.Popen(['/usr/bin/dns-sd', '-lo', '-P', service_name, '_rightclick._tcp', 'local.',
        str(server.server_port), hostname, '127.0.0.1', 'kind=graphql', 'scheme=http', 'endpoint=/graphql'],
        stdout=advertisement_output, stderr=advertisement_error)
    home = out / 'host-home'; home.mkdir(mode=0o700)
    client = None; report = {'result': 'FAIL', 'scope': 'Stable-supported GraphQL strings and input records only',
        'graphqlCoreVersion': graphql.__version__, 'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'schemaSHA256': hashlib.sha256(SDL.encode()).hexdigest(), 'serviceName': service_name, 'host': hostname,
        'exclusions': ['new typed GraphQL controls', 'MCP descriptor substrate', 'issuer authority or authentication proof',
                       'streams', 'all eleven substrates', 'shipping']}

    def call(name, arguments):
        value = client.call(name, arguments)
        if name == 'context_actions':
            filtered = dict(value, actions=[row for row in value['actions'] if
                (row.get('provider') or {}).get('name') == service_name])
            client.transcript[-1]['response']['result']['content'][0]['text'] = json.dumps(filtered)
        elif name == 'context_providers':
            count = len(value) if isinstance(value, list) else len(value['providers'])
            client.transcript[-1]['response']['result']['content'][0]['text'] = json.dumps({'providerCount': count})
        return value

    def effects_count():
        with lock: return len(effects)

    def operations_count():
        with lock: return sum(not row['introspection'] for row in requests)

    try:
        client = Client(args.binary, out, {'CFFIXED_USER_HOME': str(home), 'RIGHTCLICK_CAPABILITY_EXPERIENCE': 'disabled'})
        require(client.runtime['pid'] == client.process.pid, 'runtime PID differs from launched process')
        report['runtime'] = client.runtime; report['tools'] = client.tools
        call('context_providers', {})
        call('context_inspect', {'item': 'RIGHTCLICK legacy GraphQL parity'})
        deadline = time.monotonic() + 25; actions = []
        while time.monotonic() < deadline:
            actions = [row for row in call('context_actions', {'item': 'RIGHTCLICK legacy GraphQL parity'})['actions']
                       if (row.get('provider') or {}).get('name') == service_name]
            if len(actions) == 2: break
            time.sleep(.15)
        require(len(actions) == 2, 'owned legacy GraphQL capabilities not acquired')
        reports = []
        for title, argument_name in [('GraphQL query: legacyParityEcho', 'value'),
                                     ('GraphQL mutation: legacyParityRecord', 'input')]:
            action = next(row for row in actions if row['title'] == title)
            require(action['requiresConfirmation'] is True and action['invocation'] != 'unsupported', 'prior confirmation policy changed')
            explanation = call('context_explain', {'item': 'RIGHTCLICK legacy GraphQL parity', 'actionId': action['id']})
            require(explanation['metadata']['endpointURL'] == 'http://' + hostname.rstrip('.') + ':' + str(server.server_port) + '/graphql',
                    'discovered endpoint differs from announced provider')
            challenge = 'gql-parity-' + uuid.uuid4().hex
            supplied = challenge if argument_name == 'value' else json.dumps({'label': challenge})
            invocation = {'item': 'RIGHTCLICK legacy GraphQL parity', 'actionId': action['id'],
                          'arguments': {argument_name: supplied}}
            before_requests, before_effects = operations_count(), effects_count()
            gated = call('context_run', invocation)
            require(gated['state'] == 'awaiting_user' and operations_count() == before_requests and effects_count() == before_effects,
                    'unconfirmed call dispatched')
            record = call('context_run', {**invocation, 'confirmed': True})
            require(record['state'] == 'accepted' and record['evidence']['outcomeVerified'] is False,
                    'valid legacy GraphQL call failed or acceptance promoted to truth')
            expected = challenge if argument_name == 'value' else {'label': challenge}
            require(json.loads(record['output']) == {'rightclickResult': expected}, 'returned legacy JSON differs')
            status = call('context_run_status', {'executionId': record['executionId']})
            require(status == record, 'full retained result differs')
            require(operations_count() == before_requests + 1, 'expected exactly one actual GraphQL operation')
            file_effect = None
            if argument_name == 'input':
                file_effect = out / ('effect-' + hashlib.sha256(challenge.encode()).hexdigest() + '.json')
                require(json.loads(file_effect.read_text()) == {'label': challenge} and effects_count() == before_effects + 1,
                        'independent mutation file differs')
            reports.append({'capability': action, 'explanation': explanation, 'challenge': challenge, 'confirmation': gated,
                            'invocation': record, 'status': status, 'exactNativeCallCount': 1,
                            'externalEffect': str(file_effect) if file_effect else None,
                            'externalTruth': 'owned file bytes independently read' if file_effect else 'provider-returned echo only'})
        require(all(not row['authorizationPresent'] and not row['cookiePresent'] for row in requests),
                'unrelated credentials propagated to owned provider')
        require(effects_count() == 1 and operations_count() == 2, 'unexpected total native operations/effects')
        report.update(result='PASS', controls=reports, nativeOperations=2, nativeMutations=1,
                      credentialsPropagated=False, canonicalOperationsUsed=sorted({row['request']['params']['name']
                      for row in client.transcript if row['request']['method'] == 'tools/call'}))
    except Exception as error:
        report['unexpectedFailure'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        if client: client.close()
        advertisement.terminate(); advertisement.wait(timeout=5)
        advertisement_output.close(); advertisement_error.close()
        server.shutdown(); server.server_close()
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': report['result'], 'output': str(out), 'failure': report.get('unexpectedFailure')}))
    return 0 if report['result'] == 'PASS' else 1


if __name__ == '__main__': raise SystemExit(main())
