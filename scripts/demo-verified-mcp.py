#!/usr/bin/env python3
"""Exercise an installed RIGHTCLICK binary over real MCP stdio.
Only the local full-width text conversion is invoked. AirDrop is requested
without confirmation solely to prove the confirmation gate; it must not run.
No persistent client configuration, tunnel or repository is changed.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import selectors
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='/opt/homebrew/bin/rightclick')
    parser.add_argument('--receipt', required=True, type=pathlib.Path)
    args = parser.parse_args()
    binary = pathlib.Path(args.binary).resolve(strict=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    version = subprocess.check_output([str(binary), 'version'], text=True, timeout=15).strip()
    record = {'started_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'binary_sha256': digest, 'version': version, 'mode': 'real_mcp_stdio',
              'scope': 'local returned-text outcome; no external side effect is claimed'}
    expected_tools = {'context_runtime', 'context_inspect', 'context_providers',
                      'context_actions', 'context_explain', 'context_run', 'context_run_status'}
    action = 'service:com.apple.ChineseTextConverterService:convertTextToFullWidth'
    def show(line):
        print(line, flush=True)
        time.sleep(0.25)
    with tempfile.TemporaryFile(mode='w+t') as errors:
        process = subprocess.Popen([str(binary), 'mcp'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)
        sequence = 0
        def request(method, params=None):
            nonlocal sequence
            sequence += 1
            data = {'jsonrpc': '2.0', 'id': sequence, 'method': method}
            if params is not None:
                data['params'] = params
            process.stdin.write(json.dumps(data) + '\n')
            process.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if not selector.select(timeout=max(0, deadline - time.monotonic())):
                        break
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError('MCP process exited before replying')
                    reply = json.loads(line)
                    if reply.get('id') != sequence:
                        continue
                    if reply.get('error'):
                        raise RuntimeError('MCP error: ' + json.dumps(reply['error']))
                    return reply['result']
            raise TimeoutError('MCP request timed out: ' + method)
        def call(name, arguments):
            result = request('tools/call', {'name': name, 'arguments': arguments})
            if result.get('isError'):
                raise RuntimeError('Tool failed: ' + name)
            return json.loads(result['content'][0]['text'])
        try:
            init = request('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                           'clientInfo': {'name': 'rightclick-verified-demo', 'version': '1'}})
            assert init['serverInfo']['version'] == version
            process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
            process.stdin.flush()
            show('RIGHTCLICK ' + version + ' | live MCP / stdio')
            tools = request('tools/list')['tools']
            assert {tool['name'] for tool in tools} == expected_tools
            record['tools'] = sorted(expected_tools)
            show('PASS  Seven generic operations. No app-specific MCP tool.')
            runtime = call('context_runtime', {})
            assert runtime['version'] == version and runtime['executableSHA256'] == digest
            assert pathlib.Path(runtime['executableRealPath']).resolve() == binary
            assert runtime['transport'] == 'stdio'
            record['runtime'] = runtime
            show('PASS  Runtime SHA256 matches the executable bytes.')
            inspected = call('context_inspect', {'item': 'RightClick'})
            assert inspected['kind'] == 'text' and inspected['byteCount'] == 10
            record['inspection'] = inspected
            show('PASS  Inspect: plain text / 10 bytes.')
            actions = call('context_actions', {'item': 'RightClick'})['actions']
            assert any(cap['id'] == action for cap in actions)
            explained = call('context_explain', {'actionId': action, 'item': 'RightClick'})
            assert explained['id'] == action
            record['selected_capability'] = explained
            show('PASS  Discover + explain: native text conversion.')
            gated = call('context_run', {'actionId': 'AirDrop',
                         'item': 'https://example.com/rightclick-policy', 'confirmed': False})
            assert gated['state'] == 'awaiting_user' and 'CONFIRMATION_REQUIRED' in gated['message']
            record['confirmation_control'] = {'state': gated['state'], 'message': gated['message']}
            show('PASS  Unapproved external action stays awaiting_user.')
            result = call('context_run', {'actionId': action, 'item': 'RightClick',
                          'confirmed': True, 'expectedOutput': 'ＲｉｇｈｔＣｌｉｃｋ'})
            assert result['state'] == 'succeeded' and result['output'] == 'ＲｉｇｈｔＣｌｉｃｋ'
            assert result['evidence']['outcomeVerified'] is True
            assert result['evidence']['type'] == 'returned_text_postcondition'
            record['conversion'] = result
            show('PASS  Invoke: RightClick -> ' + result['output'])
            status = call('context_run_status', {'executionId': result['executionId']})
            assert status['state'] == result['state'] and status['output'] == result['output']
            assert status['evidence'] == result['evidence']
            record['retained_status'] = status
            show('PASS  Exact returned-text outcome verified; status retained.')
            record['verified'] = True
            record['finished_at_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(record, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
            show('Evidence saved. Acceptance was not substituted for success.')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('DEMO FAILED: ' + str(exc), file=sys.stderr)
        sys.exit(1)
