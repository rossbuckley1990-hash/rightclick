#!/usr/bin/env python3
"""Check exact owned-proof projection hashes and retained receipt equality.
With --private, compare against locally retained originals. Without it, check
bundle hashes only. No signature verification or authority/truth promotion.
"""
import argparse
import hashlib
import json
from pathlib import Path


def load(path): return json.loads(path.read_text())
def pin(path):
    data=path.read_bytes(); return {'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}


def walk(value):
    yield value
    if isinstance(value,dict):
        for item in value.values(): yield from walk(item)
    elif isinstance(value,list):
        for item in value: yield from walk(item)
    elif isinstance(value,str):
        try: decoded=json.loads(value)
        except (ValueError,TypeError): return
        if not isinstance(decoded,str): yield from walk(decoded)


def receipt_values(value):
    return [(key,item) for node in walk(value) if isinstance(node,dict)
            for key,item in node.items() if 'receipt' in key.lower()]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',type=Path,default=Path(__file__).resolve().parent)
    parser.add_argument('--private',action='store_true')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args();base=args.base.resolve();manifest=load(base/'projection-manifest.json')
    projected=0;receipts=0;secret_fields=[];provider_totals=0;signed=0
    for entry in manifest['files']:
        owned=base/entry['file'];assert pin(owned)==entry['ownedProof'],entry['file']
        original=Path(entry['privatePath'])
        if args.private:
            assert pin(original)==entry['rawPrivate'],entry['file']
        if not isinstance(entry['projection'],list):
            if args.private: assert original.read_bytes()==owned.read_bytes(),entry['file']
        else:
            raw=load(original) if args.private else None;public=load(owned)
            changed={item['exchangeIndex'] for item in entry['projection']};projected+=len(changed)
            if args.private:
                assert len(raw)==len(public) and receipt_values(raw)==receipt_values(public)
                for i,(before,after) in enumerate(zip(raw,public)):
                    if i not in changed: assert before==after
                    else:
                        assert before['request']==after['request'] and before['request']['params']['name']=='context_providers'
                        before_content=before['response']['result']['content'][0]
                        after_content=after['response']['result']['content'][0]
                        assert set(json.loads(before_content['text']))=={'providerCount'}
                        assert json.loads(after_content['text'])=={'ownedProofProjection':{
                            'operation':'context_providers','successfulRead':True,
                            'omitted':'unrelated provider inventory/count'}}
                        # The sole allowed change is this content text.
                        before_content['text']=after_content['text'];assert before==after
        if owned.suffix in {'.json','.jsonl'}:
            values=[load(owned)] if owned.suffix=='.json' else [json.loads(line) for line in owned.read_text().splitlines()]
            for value in values:
                receipts+=len(receipt_values(value))
                for node in walk(value):
                    if not isinstance(node,dict):continue
                    provider_totals+=int('providerCount' in node)
                    for key,item in node.items():
                        normalized=key.lower().replace('_','').replace('-','')
                        if normalized in {'token','accesstoken','refreshtoken','privatekey','authorization','bearer'} and isinstance(item,str) and item:
                            secret_fields.append({'file':entry['file'],'field':key})
                        if key=='signedReceipt' and item:signed+=1
    assert not secret_fields and provider_totals==0,(secret_fields,provider_totals)
    report={'audit':'PASS_OWNED_PROOF_PROJECTION','files':len(manifest['files']),
        'projectedProviderReadExchanges':projected,'unrelatedProviderTotalsRemaining':provider_totals,
        'receiptValuesRetained':receipts,'signedReceiptsPresent':signed,
        'actualCredentialPrivateKeyFieldsFound':len(secret_fields),
        'privateOriginalHashAndSemanticComparison':args.private,
        'scope':'Exact owned proof retained; no signature verification, authority grant, fresh live action, or outcome promotion.'}
    if args.output:args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':main()
