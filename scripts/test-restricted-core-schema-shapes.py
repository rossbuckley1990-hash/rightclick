#!/usr/bin/env python3
"""Frozen schema-equivalence controls, using explicit client-only catalogues."""
import argparse, copy, hashlib, importlib.util, json, pathlib

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--driver', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('driver', a.driver)
    driver = importlib.util.module_from_spec(spec); spec.loader.exec_module(driver)
    schema = {'type': 'object', 'properties': {'arguments': {'type': 'object', 'additionalProperties': {'type': 'string'}}}, 'additionalProperties': False}
    expected = [{'name': n, 'description': 'Fixture only', 'inputSchema': copy.deepcopy(schema)} for n in sorted(driver.CANONICAL)]
    record = {'tools': [{'type': 'function', 'name': n, 'description': 'Fixture only', 'parameters': copy.deepcopy(schema), 'strict': False} for n in sorted(driver.CANONICAL)], 'otherToolFields': {'tool_choice': 'auto', 'parallel_tool_calls': False}}
    results = {}
    for label in ['sdk_empty_properties', 'added_constraint', 'default_payload_changed', 'example_payload_changed']:
        declared = copy.deepcopy(expected); captured = copy.deepcopy(record)
        captured['tools'][0]['parameters']['properties']['arguments']['properties'] = {}
        should_accept = label == 'sdk_empty_properties'
        if label == 'added_constraint': captured['tools'][0]['parameters']['properties']['arguments']['maxProperties'] = 0
        for key, name in [('default', 'default_payload_changed'), ('examples', 'example_payload_changed')]:
            if label == name:
                payload = {'type': 'object', 'meaning': 'opaque instance, not schema'}
                declared[0]['inputSchema'][key] = copy.deepcopy(payload)
                captured['tools'][0]['parameters'][key] = {**payload, 'properties': {}}
        try:
            driver.validate_capture([captured], declared); accepted = True
        except RuntimeError:
            accepted = False
        results[label] = {'result': 'PASS' if accepted == should_accept else 'FAIL', 'accepted': accepted, 'expectedAcceptance': should_accept}
    report = {'proofKind': 'SCHEMA_COMPARISON_FIXTURES_NOT_PROVIDER_OR_AI_ACCEPTANCE', 'driverSHA256': hashlib.sha256(a.driver.read_bytes()).hexdigest(), 'controlSHA256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(), 'controls': results, 'result': 'PASS' if all(v['result'] == 'PASS' for v in results.values()) else 'FAIL'}
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'PASS' else 1

if __name__ == '__main__': raise SystemExit(main())
