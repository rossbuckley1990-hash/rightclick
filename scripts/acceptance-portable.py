#!/usr/bin/env python3
"""Offline, live-process acceptance: a real fixture server, real RIGHTCLICK,
seven real MCP operations, confirmation, verification, shutdown and HTTP auth.
No third-party accounts, credentials, installed services or user config required.
"""
from __future__ import annotations
import argparse
import base64
import http.client
import json
import os
import pathlib
import queue
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

TOOLS = sorted(['context_runtime', 'context_inspect', 'context_actions', 'context_explain',
                'context_run', 'context_run_status', 'context_providers'])

class Fixture(BaseHTTPRequestHandler):
    calls: list[bytes] = []
    specification: dict[str, Any] = {}
    def log_message(self, *_: Any) -> None:
        pass
    def reply(self, status: int, body: bytes, kind: str) -> None:
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self) -> None:
        if self.path == '/openapi.json':
            self.reply(200, json.dumps(self.specification).encode(), 'application/json')
        else:
            self.reply(404, b'', 'text/plain')
    def do_POST(self) -> None:
        if self.path != '/upper':
            self.reply(404, b'', 'text/plain'); return
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 <= length <= 4096:
            self.reply(413, b'', 'text/plain'); return
        body = self.rfile.read(length)
        self.calls.append(body)
        self.reply(200, body.upper(), 'text/plain')

class MCP:
    def __init__(self, command: list[str], env: dict[str, str], directory: pathlib.Path) -> None:
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, env=env, cwd=directory)
        self.messages: queue.Queue[Any] = queue.Queue()
        self.sequence = 0
        def collect() -> None:
            assert self.process.stdout is not None
            try:
                for line in self.process.stdout:
                    self.messages.put(json.loads(line))
            except Exception as error:
                self.messages.put(error)
            self.messages.put(EOFError('MCP stdout closed'))
        threading.Thread(target=collect, daemon=True).start()
    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.sequence += 1
        request = {'jsonrpc': '2.0', 'id': self.sequence, 'method': method}
        if params is not None:
            request['params'] = params
        assert self.process.stdin is not None
        self.process.stdin.write((json.dumps(request) + '\n').encode()); self.process.stdin.flush()
        deadline = time.monotonic() + 30
        while True:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if message.get('id') != self.sequence:
                if time.monotonic() >= deadline:
                    raise TimeoutError('MCP response missing')
                continue
            assert 'error' not in message, message
            return message['result']
    def call(self, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        result = self.request('tools/call', {'name': name, 'arguments': arguments or {},
            '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28'}})
        assert not result.get('isError'), result
        texts = [x['text'] for x in result['content'] if x['type'] == 'text']
        assert len(texts) == 1, result
        return json.loads(texts[0])
    def close(self) -> None:
        if self.process.poll() is None:
            assert self.process.stdin is not None
            self.process.stdin.close()
            try:
                code = self.process.wait(timeout=10)
                assert code == 0, ('EOF exit code', code)
            except Exception:
                self.process.kill(); self.process.wait(timeout=5); raise
        self.stderr.close()

def http_request(port: int, body: dict[str, Any], token: str | None) -> tuple[int, bytes]:
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=20)
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
               'MCP-Protocol-Version': '2025-11-25'}
    if token is not None:
        headers['Authorization'] = 'Bearer ' + token
    try:
        connection.request('POST', '/mcp', json.dumps(body), headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=pathlib.Path)
    parser.add_argument('--http', action='store_true')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    results: dict[str, Any] = {'scope': 'Offline fixture; no production credentials or external providers.', 'checks': []}
    def passed(name: str) -> None:
        results['checks'].append(name)
        print('PASS ' + name, flush=True)
    with tempfile.TemporaryDirectory(prefix='rightclick-portable-acceptance-') as raw:
        directory = pathlib.Path(raw)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        origin = 'http://127.0.0.1:' + str(server.server_port)
        Fixture.specification = {
            'openapi': '3.0.3', 'info': {'title': 'Portable acceptance fixture', 'version': '1'},
            'servers': [{'url': origin}], 'paths': {'/upper': {'post': {
                'operationId': 'portable-upper', 'summary': 'Portable acceptance upper', 'security': [],
                'requestBody': {'required': True, 'content': {'text/plain': {'schema': {'type': 'string'}}}},
                'responses': {'200': {'description': 'Uppercase text', 'content': {'text/plain': {'schema': {'type': 'string'}}}}}
            }}}}
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {key: value for key, value in os.environ.items() if not key.startswith('RIGHTCLICK_')}
        env.update({'HOME': raw, 'XDG_CONFIG_HOME': raw + '/config', 'XDG_STATE_HOME': raw + '/state'})
        config_output = subprocess.check_output([str(binary), 'connect', '--openapi', origin + '/openapi.json',
            '--base-url', origin], env=env, timeout=15, text=True)
        config = json.loads(config_output)['mcpServers']['rightclick']
        assert config['args'] == ['mcp']; assert config['command'] == str(binary)
        env.update(config['env'])
        passed('generated client configuration uses existing artifact resolver')
        platform = json.loads(subprocess.check_output([str(binary), 'platform', '--json'], env=env, timeout=15))
        assert platform['fileAndTextVerification']; assert 'openapi' in platform['networkCapabilityKinds']
        results['platform'] = platform['platform']; results['architecture'] = platform['architecture']
        passed('host capabilities reported without invoking a provider')
        client = MCP([str(binary), 'mcp', '--isolated'], env, directory)
        try:
            discovery = client.request('server/discover')
            assert '2026-07-28' in discovery['supportedVersions']
            listing = client.request('tools/list', {'_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28'}})
            assert sorted(tool['name'] for tool in listing['tools']) == TOOLS
            passed('same seven tools in modern discovery')
            runtime = client.call('context_runtime'); assert runtime['product'] == 'RIGHTCLICK'
            assert len(runtime['executableSHA256']) == 64
            inspected = client.call('context_inspect', {'item': 'portable proof'})
            assert inspected['kind'] == 'text'
            actions = client.call('context_actions', {'item': 'portable proof'})['actions']
            action = next(x for x in actions if x['title'] == 'Portable acceptance upper')
            explained = client.call('context_explain', {'item': 'portable proof', 'actionId': action['id']})
            assert explained['id'] == action['id']; assert explained['requiresConfirmation']
            passed('live OpenAPI discovery and explanation')
            refused = client.call('context_run', {'item': 'portable proof', 'actionId': action['id']})
            assert refused['state'] == 'awaiting_user'; assert Fixture.calls == []
            passed('unconfirmed invocation makes zero provider calls')
            accepted = client.call('context_run', {'item': 'portable proof', 'actionId': action['id'], 'confirmed': True})
            assert accepted['state'] == 'accepted'; assert not accepted['evidence']['outcomeVerified']
            assert accepted['output'] == 'PORTABLE PROOF'; assert Fixture.calls == [b'portable proof']
            passed('real provider response remains accepted without postconditions')
            verified = client.call('context_run', {'item': 'portable proof', 'actionId': action['id'], 'confirmed': True,
                'verification': {'predicates': [{'type': 'text_equals', 'value': 'PORTABLE PROOF'}]}})
            assert verified['state'] == 'succeeded'; assert verified['evidence']['outcomeVerified']
            assert Fixture.calls == [b'portable proof', b'portable proof']
            status = client.call('context_run_status', {'executionId': verified['executionId']})
            assert status['state'] == 'succeeded'
            passed('declared returned-text postcondition verified; independent fixture readback matches')
            rejected = client.call('context_run', {'item': 'portable proof', 'actionId': action['id'], 'confirmed': True,
                'verification': {'predicates': [{'type': 'text_equals', 'value': 'wrong'}]}})
            assert rejected['state'] == 'failed'
            assert not rejected['evidence']['outcomeVerified']
            passed('wrong expected result produces failure, not success')
            providers = client.call('context_providers')
            assert any(x['source'] == 'openapi' for x in providers)
        finally:
            client.close()
        passed('stdio EOF shuts down the process cleanly')
        # Compatibility is checked independently from the modern discovery flow.
        legacy = MCP([str(binary), 'mcp', '--isolated'], env, directory)
        try:
            initialized = legacy.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                'clientInfo': {'name': 'portable-acceptance', 'version': '1'}})
            assert initialized['protocolVersion'] == '2025-11-25'
            assert len(legacy.request('tools/list')['tools']) == 7
        finally:
            legacy.close()
        passed('legacy initialize and tools/list remain compatible')
        if args.http:
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
            http_env = dict(env, RIGHTCLICK_MCP_TOKEN='fixture-only-http-token')
            stderr = tempfile.TemporaryFile()
            process = subprocess.Popen([str(binary), 'mcp', '--http', '--isolated', '--port', str(port)],
                env=http_env, cwd=directory, stdout=subprocess.DEVNULL, stderr=stderr)
            try:
                deadline = time.monotonic() + 15
                while True:
                    if process.poll() is not None:
                        raise AssertionError('HTTP process exited before readiness')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.3):
                            break
                    except OSError:
                        if time.monotonic() >= deadline: raise
                        time.sleep(0.1)
                request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}
                assert http_request(port, request, None)[0] == 401
                assert http_request(port, request, 'wrong')[0] == 401
                status, body = http_request(port, request, 'fixture-only-http-token')
                assert status == 200, (status, body)
                assert sorted(x['name'] for x in json.loads(body)['result']['tools']) == TOOLS
                passed('HTTP authentication is enforced by shared dispatcher')
                for bad in [b'Content-Length: -1\r\n', b'Content-Length: 2000001\r\n',
                            b'Transfer-Encoding: chunked\r\n', b'Content-Length: 1\r\nContent-Length: 2\r\n']:
                    with socket.create_connection(('127.0.0.1', port), timeout=3) as connection:
                        connection.settimeout(3)
                        connection.sendall(b'POST /mcp HTTP/1.1\r\nHost: localhost\r\n' + bad + b'\r\n')
                        try: reply = connection.recv(4096)
                        except ConnectionResetError: reply = b''
                        assert not reply.startswith(b'HTTP/1.1 200'), reply
                passed('malformed or oversized HTTP framing is never dispatched')
            finally:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
                stderr.close()
        server.shutdown(); server.server_close()
    results['result'] = 'PASS'
    print(json.dumps(results, indent=2))

if __name__ == '__main__':
    main()
