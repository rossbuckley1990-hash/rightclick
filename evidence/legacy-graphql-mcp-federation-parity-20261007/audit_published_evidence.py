#!/usr/bin/env python3
"""Offline audit of privately retained or owned-proof projected parity artifacts.
This rechecks frozen records against declared binary pins, native journals and
owned file bytes. It does not relaunch a provider, rebuild a binary, verify a
signature, or make an authority/outcome assertion beyond the scoped evidence.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re

BASE = Path(__file__).resolve().parent
NAMES = {'context_runtime', 'context_providers', 'context_inspect', 'context_actions',
         'context_explain', 'context_run', 'context_run_status'}
BINARY_PINS = {
    'baseline': ('/opt/homebrew/Cellar/rightclick/0.2.2/bin/rightclick',
        'd31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d'),
    'candidate': ('/private/tmp/rightclick-parity-candidate-c61f0cb2',
        'c61f0cb2518ad8f728dddeeef7e4dd3f91ac7e15a608a7262b038bef9fd86b12'),
    'final-candidate': ('/private/tmp/rightclick-final-focused-release-frozen-20261007/rightclick',
        '23d92e6319b299e2c3c47c3c1c0702b9c88eb37db413c533ae0846b9f5cd85fa')}

def compare_tools(old, new):
    old_by_name = {row["name"]: row for row in old}
    new_by_name = {row["name"]: row for row in new}
    require([row["name"] for row in old] == [row["name"] for row in new], "tool ordering changed")
    differences = []
    for name in NAMES:
        if old_by_name[name] == new_by_name[name]:
            continue
        modified = copy.deepcopy(new_by_name[name])
        require(name == "context_run", "unexpected changed public tool")
        schema = modified["inputSchema"]
        require("contractSHA256" not in schema.get("required", []), "new contract pin became required")
        pin = schema["properties"].pop("contractSHA256")
        require(pin["type"] == "string", "unexpected contract pin type")
        require(modified == old_by_name[name], "legacy tool shape differs beyond the optional pin")
        differences.append({"tool": name, "change": "optional contractSHA256 string property only"})
    return {"audit": "PASS", "canonicalNamesAndOrderEqual": True,
            "legacyPropertiesAndRequiredFieldsEqual": True, "differences": differences}



def require(condition, message):
    if not condition: raise ValueError(message)


def load(path): return json.loads(path.read_text())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def rows(path):
    data = path.read_bytes()
    require(not data or data.endswith(b'\n'), 'incomplete native journal')
    return [json.loads(line) for line in data.splitlines()]


def transcript(path):
    raw = load(path); responses = {}; tools = None; names = set()
    for row in raw:
        query, reply = row['request'], row['response']
        require(query['id'] == reply['id'] and 'error' not in reply, 'JSON-RPC response mismatch')
        method = query['method']
        require(method in {'initialize', 'tools/list', 'tools/call'}, 'unexpected public protocol operation')
        if method == 'tools/list': tools = reply['result']['tools']
        if method != 'tools/call': continue
        name = query['params']['name']; names.add(name)
        require(name in NAMES and not reply['result'].get('isError'), 'extra/error runtime tool')
        value = json.loads(reply['result']['content'][0]['text'])
        responses.setdefault(name, []).append((query['params']['arguments'], value))
    require(tools and len(tools) == 7 and {tool['name'] for tool in tools} == NAMES, 'catalogue is not exact Core7')
    return responses, tools, names


def check_runtime(value, label, transport):
    require(value['product'] == 'RIGHTCLICK' and value['executableSHA256'] == BINARY_PINS[label][1], 'wrong binary identity')
    require(value['version'] == ('0.2.2' if label == 'baseline' else '0.2.3'), 'wrong version')
    require(value['transport'] == transport and Path(value['executableRealPath']).resolve() == Path(BINARY_PINS[label][0]).resolve(), 'wrong runtime path/transport')


def graphql(label):
    directory = BASE / ('graphql-' + label + '-valid')
    calls, tools, names = transcript(directory / 'transcript.json')
    require(names == NAMES, 'GraphQL did not use all seven canonical operations')
    runtime = calls['context_runtime'][0][1]; check_runtime(runtime, label, 'stdio')
    journal = rows(directory / 'provider-requests.jsonl')
    operations = [row for row in journal if not row['introspection']]
    require(len(operations) == 2 and all(not row['authorizationPresent'] and not row['cookiePresent'] for row in journal),
            'unexpected native operations or propagated credentials')
    confirms = [(args, value) for args, value in calls['context_run'] if args.get('confirmed') is True]
    gates = [(args, value) for args, value in calls['context_run'] if args.get('confirmed') is not True]
    require(len(confirms) == len(gates) == 2 and all(value['state'] == 'awaiting_user' for _, value in gates), 'confirmation changed')
    effects = rows(directory / 'effects.jsonl'); require(len(effects) == 1, 'expected one mutation effect')
    results = []
    for args, value in confirms:
        require(value['state'] == 'accepted' and value['evidence']['outcomeVerified'] is False, 'acceptance overstates truth')
        require(any(status['executionId'] == value['executionId'] and status == value for _, status in calls['context_run_status']),
                'retained public result differs')
        supplied = args['arguments']; mutation = 'input' in supplied
        native_variables = {'input': json.loads(supplied['input'])} if mutation else {'value': supplied['value']}
        matching = [row for row in operations if row['request']['variables'] == native_variables]
        require(len(matching) == 1, 'not exactly one native GraphQL call for the public request')
        require(json.loads(value['output']) == matching[0]['response']['data'] and 'errors' not in matching[0]['response'],
                'returned JSON differs from actual native GraphQL result')
        challenge = native_variables['input']['label'] if mutation else native_variables['value']
        require(re.fullmatch(r'gql-parity-[0-9a-f]{32}', challenge), 'wrong bounded challenge')
        external = None
        if mutation:
            require(effects[0]['input'] == native_variables['input'] and effects[0]['value'] == {'label': challenge}, 'native effect mismatch')
            file = directory / ('effect-' + hashlib.sha256(challenge.encode()).hexdigest() + '.json')
            require(not file.is_symlink() and file.resolve().parent == directory.resolve() and
                    load(file) == {'label': challenge}, 'independent file effect differs')
            external = {'file': str(file), 'sha256': digest(file)}
        if 'rcir' in value:
            require(value['rcir']['phase'] == 'completed' and value['rcir']['outcome'] == 'unverified', 'extra task assertion contradicts acceptance')
        results.append({'title': value['title'], 'state': value['state'], 'nativeCallCount': 1, 'challenge': challenge,
                        'retainedFullResultEqual': True, 'returnedJSONMatchesNative': True, 'independentFileEffect': external})
    explanations = {value['title']: value for _, value in calls['context_explain']}
    require(len(explanations) == 2, 'missing discovery explanation')
    announcement = (directory / 'advertisement.log').read_text()
    require('Using LocalOnly' in announcement and 'Name now registered and active' in announcement, 'native DNS-SD announcement missing')
    return {'audit': 'PASS', 'runtime': runtime, 'nativeOperations': 2, 'nativeMutations': 1, 'results': results,
            'credentialPropagation': False, 'gatingZeroDispatchScope': 'synchronous live harness count assertions retained in source; offline journal verifies total actual calls',
            'externalTruth': 'independent mutation file only; query echo and runtime acceptance are not external state proof'}, tools, explanations


def federation(label):
    directory = BASE / ('federation-' + label + '-https-valid')
    a, tools, names = transcript(directory / 'transcript-a.json')
    b, b_tools, b_names = transcript(directory / 'transcript-b.json')
    require(names == NAMES and b_names.issubset(NAMES), 'federation operation surface differs')
    require(tools == b_tools, 'runtime A/B catalogues differ')
    runtimes = [a['context_runtime'][0][1], b['context_runtime'][0][1]]
    for runtime in runtimes: check_runtime(runtime, label, 'http')
    require(runtimes[0]['pid'] != runtimes[1]['pid'], 'not two actual runtimes')
    for name in ('a', 'b'):
        pid = a['context_runtime'][0][1]['pid'] if name == 'a' else b['context_runtime'][0][1]['pid']
        listener = (directory / ('listener-' + name + '.txt')).read_text()
        require('p' + str(pid) in listener and 'n127.0.0.1:' in listener and 'n*:' not in listener, 'listener identity/exposure differs')
    explanation = a['context_explain'][0][1]
    remote_id = explanation['metadata']['federationRemoteActionID']
    require(explanation['id'] == 'federation:peer-b:' + remote_id and
            explanation['metadata']['federationRuntimeSHA256'] == BINARY_PINS[label][1], 'federated origin differs')
    require(any(any(row['id'] == remote_id for row in value['actions']) for _, value in b['context_actions']), 'B never advertised remote capability')
    require(a['context_actions'][0][1]['actions'] == [] and b['context_actions'][0][1]['actions'] == [] and
            a['context_actions'][-1][1]['actions'] == [] and b['context_actions'][-1][1]['actions'] == [], 'live appearance/withdrawal differs')
    expected = (directory / 'provider-source.txt').read_text()
    require((directory / 'independent-source.txt').read_bytes() == (directory / 'provider-source.txt').read_bytes(), 'separate HTTPS source read differs')
    require((directory / 'independent-specification.json').read_bytes() == (directory / 'openapi.json').read_bytes(), 'separate HTTPS specification read differs')
    runs = a['context_run']; require(len(runs) == 3 and runs[0][1]['state'] == 'awaiting_user', 'federation confirmation differs')
    accepted, verified = runs[1][1], runs[2][1]
    require(runs[1][0]['confirmed'] is True and runs[2][0]['confirmed'] is True, 'unconfirmed actual invocation')
    require(accepted['state'] == 'accepted' and accepted['output'] == expected and accepted['evidence']['outcomeVerified'] is False,
            'unverified remote acceptance differs')
    require(runs[2][0]['verification']['predicates'] == [{'type': 'text_equals', 'value': expected}] and
            verified['state'] == 'succeeded' and verified['output'] == expected and verified['verification']['status'] == 'VERIFIED_SUCCESS' and
            verified['evidence']['outcomeVerified'] is True, 'existing returned-text postcondition differs')
    require('federation peer peer-b' in accepted['events'] and 'federation peer peer-b' in verified['events'], 'direct execution substituted for federation')
    require(len(a['context_run_status']) == 3 and [x[1] for x in a['context_run_status']] == [accepted, verified, verified],
            'status lost or changed before/after withdrawal')
    require(a['context_runtime'][-1][1]['pid'] == runtimes[0]['pid'] and b['context_runtime'][-1][1]['pid'] == runtimes[1]['pid'], 'runtime restarted')
    report = load(directory / 'results.json')
    require(report['result'] == 'PASS' and len(report['authorityControls']) == 4 and all(row['status'] == 401 for row in report['authorityControls']),
            'live missing/invalid HTTP bearer controls failed')
    return {'audit': 'PASS', 'runtimes': runtimes, 'federatedOrigin': explanation['id'], 'confirmation': 'awaiting_user',
            'acceptedState': 'accepted/unverified', 'returnedTextPostcondition': 'succeeded/VERIFIED_SUCCESS', 'retainedAfterWithdrawal': True,
            'liveAppearanceWithdrawalWithoutRestart': True, 'HTTPMissingIncorrectCredentials': 'four live 401 controls',
            'independentSourceSHA256': digest(directory / 'independent-source.txt'),
            'externalTruth': 'separate immutable HTTPS source-byte correspondence only; VERIFIED_SUCCESS compares provider-returned text; upstream call count/headers not independently observed'}, tools


def main():
    global BASE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=BASE)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(); BASE = args.base.resolve()
    output = args.output
    results = {}; gql_tools = {}; explanations = {}; fed_tools = {}
    for label in ('baseline', 'candidate', 'final-candidate'):
        results['graphql-' + label], gql_tools[label], explanations[label] = graphql(label)
        results['federation-' + label], fed_tools[label] = federation(label)
    comparisons = {}
    for label in ('candidate', 'final-candidate'):
        comparisons[label] = {'graphqlCatalogueCompatibility': compare_tools(gql_tools['baseline'], gql_tools[label]),
            'httpFederationCatalogueCompatibility': compare_tools(fed_tools['baseline'], fed_tools[label])}
        for title in explanations['baseline']:
            old = explanations['baseline'][title]['metadata']; new = explanations[label][title]['metadata']
            for key in ('argumentsSchema', 'operationKind', 'field', 'schemaSHA256', 'graphqlReturnType', 'resultValidation'):
                require(old[key] == new[key], 'legacy GraphQL contract differs: ' + label + '/' + key)
    summary = {'audit': 'PASS_TESTED_LEGACY_GRAPHQL_MCP_FEDERATION_PARITY', 'results': results,
        'comparisonsWithStable0.2.2': comparisons,
        'verificationScope': 'offline comparison of frozen artifacts; no signature verification, binary rebuild or fresh external action',
        'legacyGraphQLReflectedContractEqual': True,
        'exclusions': ['new MCP descriptor substrate', 'new typed/stream features', 'issuer authority or downscoping',
                       'fresh restricted AI', 'all eleven substrates', 'every protocol version/capability/platform', 'shipping']}
    if output: output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'audit': summary['audit'], 'controls': len(results), 'output': str(output)}))


if __name__ == '__main__': main()
