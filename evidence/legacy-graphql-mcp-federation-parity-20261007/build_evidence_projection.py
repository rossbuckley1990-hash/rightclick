#!/usr/bin/env python3
"""Project privately retained collection artifacts to owned-proof-only evidence.
No receipt, invocation, retained status, native journal, or owned capability row is modified.
This is a file projection, not an authority/signature/outcome verifier.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil

PRIVATE = Path('/private/tmp/rightclick-graphql-mcp-federation-parity-independent-20261007')
EXCLUDED = {'source-snapshots/acceptance-graphql-typed-reference.py',
            'source-snapshots/prior-independent-catalogue-checker.py'}


def pin(path):
    data = path.read_bytes()
    return {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}


def receipts(value):
    result = []
    if isinstance(value, dict):
        for key, item in value.items():
            if 'receipt' in key.lower(): result.append((key, item))
            result += receipts(item)
    elif isinstance(value, list):
        for item in value: result += receipts(item)
    elif isinstance(value, str):
        try: result += receipts(json.loads(value))
        except (ValueError, TypeError): pass
    return result


def project_transcript(raw):
    result = copy.deepcopy(raw); changes = []
    for index, row in enumerate(result):
        request = row['request']
        if request.get('method') != 'tools/call' or request['params']['name'] != 'context_providers': continue
        content = row['response']['result']['content']
        assert len(content) == 1 and content[0]['type'] == 'text'
        value = json.loads(content[0]['text'])
        assert set(value) == {'providerCount'}
        content[0]['text'] = json.dumps({'ownedProofProjection': {
            'operation': 'context_providers', 'successfulRead': True,
            'omitted': 'unrelated provider inventory/count'}})
        changes.append({'exchangeIndex': index, 'operation': 'context_providers',
                        'rule': 'omit previously retained providerCount; preserve outer success envelope/request'})
    assert receipts(raw) == receipts(result), 'receipt value changed'
    for index, (before, after) in enumerate(zip(raw, result)):
        if index not in {item['exchangeIndex'] for item in changes}: assert before == after
    return result, changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args(); destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((PRIVATE / 'final-evidence-manifest.json').read_text())
    files = [Path(name) for name in manifest['files']]
    files += [PRIVATE / 'final-evidence-manifest.json', PRIVATE / 'build_evidence_projection.py']
    # Final candidate controls are separate new artifacts; existing baseline/c61 files stay frozen.
    for name in ('graphql-final-candidate-valid', 'federation-final-candidate-https-valid'):
        directory = PRIVATE / name
        if directory.exists(): files += [p for p in directory.iterdir() if p.is_file()]
    for name in ('independent-release-final-audit.json', 'independent-published-audit.json', 'final-release-review.json',
                 'final-candidate-private-manifest.json', 'audit_published_evidence.py', 'verify_owned_projection.py'):
        if (PRIVATE / name).exists(): files.append(PRIVATE / name)
    snapshots = PRIVATE / 'source-snapshots/finalRelease'
    if snapshots.exists(): files += [p for p in snapshots.rglob('*') if p.is_file()]
    for name in ('bd5-vs-final-focused-scope.patch', 'stable-vs-final-focused-scope.patch'):
        if (PRIVATE / name).exists(): files.append(PRIVATE / name)
    entries = []; omitted = []
    for path in sorted(set(files)):
        relative = str(path.relative_to(PRIVATE))
        if relative in EXCLUDED:
            omitted.append({'privatePath': str(path), 'rawPrivate': pin(path),
                            'reason': 'reference source extends beyond this owned proof; hash retained without unrelated body'})
            continue
        target = destination / relative; target.parent.mkdir(parents=True, exist_ok=True)
        changes = []
        if path.name.startswith('transcript') and path.suffix == '.json':
            projected, changes = project_transcript(json.loads(path.read_text()))
            if changes: target.write_text(json.dumps(projected, indent=2) + '\n')
            else: shutil.copyfile(path, target)
        else: shutil.copyfile(path, target)
        entries.append({'file': relative, 'privatePath': str(path), 'rawPrivate': pin(path),
                        'ownedProof': pin(target), 'projection': changes or 'byte-for-byte'})
    description = {'scope': 'Lossless to the retained owned proof, with explicit omission of unrelated provider counts.',
        'rawMeaning': 'Raw private hashes identify the exact privately retained collection artifacts. context_actions was filtered at collection to owned capability rows and context_providers was reduced to a total; these artifacts are not complete original wire payloads.',
        'preserved': ['all owned capability rows and contracts', 'seven operation requests and success envelopes',
                      'all invocation/status records and receipt values exactly', 'native journals and independently read owned effect files'],
        'omitted': 'Only context_providers providerCount in retained transcript content; full unrelated inventory was never retained here.',
        'receipts': 'No signature verification or outcome promotion claimed; all receipt strings unchanged.',
        'privateOriginals': 'Retained privately outside Git; no bearer or private key included in selected artifacts.',
        'files': entries, 'omittedReferenceBodies': omitted}
    (destination / 'projection-manifest.json').write_text(json.dumps(description, indent=2) + '\n')
    print(json.dumps({'result': 'PASS', 'files': len(entries), 'projectedExchanges': sum(len(x['projection']) for x in entries if isinstance(x['projection'], list)), 'destination': str(destination)}))


if __name__ == '__main__': main()
