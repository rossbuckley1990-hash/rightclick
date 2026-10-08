"""Independent signed delegation-claim validation; live revocation is not a receipt claim."""
import base64, importlib.util, json, tempfile, unittest, os
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('receipt',ROOT/'scripts/verify-rcir-receipt.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
EVIDENCE=Path(os.environ.get('RIGHTCLICK_AUTHORITY_RECEIPT_EVIDENCE',ROOT/'evidence/agency-authority-20261007/dispatch'))
EXPECTED={'subject':'agent:bob','audiences':['runtime:proof'],'ancestorSubjects':['agent:alice'],'issuer':'issuer:host','invocationLimit':1,'delegationDepth':0}

def encode(value):
    def frame(tag,raw):return tag+str(len(raw)).encode()+b':'+raw
    def body(value):
        if value is None:return b'n'
        if type(value) is bool:return b'b1' if value else b'b0'
        if type(value) is int:return frame(b'i',str(value).encode())
        if isinstance(value,str):return frame(b's',value.encode('utf-8'))
        if isinstance(value,bytes):return frame(b'x',value)
        if isinstance(value,list):return b'a'+str(len(value)).encode()+b':'+b''.join(body(x) for x in value)
        if isinstance(value,dict):return b'o'+str(len(value)).encode()+b':'+b''.join(body(k)+body(value[k]) for k in sorted(value,key=lambda k:k.encode('utf-8')))
        raise TypeError('unsupported test fixture value')
    return b'RIGHTCLICK-VALUE-1\0'+body(value)

def domain(name,value):return ('RIGHTCLICK-RCIR-'+name+'-1\0').encode()+encode(value)

class AuthorityReceiptVerifierTests(unittest.TestCase):
    def test_real_child_receipt_matches_expected_ancestry_and_external_effect(self):
        r=v.verify(EVIDENCE/'legal-child-receipt.json',EVIDENCE/'trusted-public-key.raw',expected_outcome='succeeded',expected_authority=EXPECTED)
        effects=json.loads(next(EVIDENCE.glob('*testLegalChildProducesIndependentlyObservedSignedEffect*.json')).read_text())['effects']
        self.assertEqual(len(effects),1);self.assertEqual(effects[0]['taskID'],r['signedClaims']['taskID'])
        self.assertEqual(effects[0]['body'],{'id':'bounded-child','value':'requested'})
        self.assertEqual(r['signedClaims']['authority']['ancestorSubjects'],['agent:alice'])
    def test_wrong_expected_subject_audience_or_parent_is_rejected(self):
        for name,value in [('subject','agent:mallory'),('audiences',['runtime:other']),('ancestorSubjects',['agent:mallory'])]:
            expected=dict(EXPECTED);expected[name]=value
            with self.subTest(name=name),self.assertRaises(v.ReceiptClaimMismatch):
                v.verify(EVIDENCE/'legal-child-receipt.json',EVIDENCE/'trusted-public-key.raw',expected_authority=expected)
    def test_valid_signature_cannot_promote_widened_or_unknown_authority_claims(self):
        envelope=json.loads((EVIDENCE/'legal-child-receipt.json').read_text())
        payload=base64.b64decode(envelope['payload'])
        key=Ed25519PrivateKey.generate();public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
        changes={
            'unknown_field':lambda g:g.update(unknown=True),
            'audience':lambda g:g['request']['audiences'].append('runtime:other'),
            'resource':lambda g:g['request']['scopes'].append({'resource':'urn:other','effect':'write'}),
            'effect':lambda g:g['request']['scopes'].append({'resource':'urn:other','effect':'delete'}),
            'expiry':lambda g:g['request'].update(expiresAt=3001),
            'count':lambda g:g['request'].update(invocationLimit=2),
            'depth':lambda g:g['request'].update(delegationDepth=1),
            'arguments':lambda g:g['request'].update(arguments=None),
            'provider':lambda g:g['request']['targets'][0].update(provider='provider:other'),
            'task_shape':lambda g:g['request']['taskShapes'].append('deferred')}
        for name,change in changes.items():
            with self.subTest(name=name),tempfile.TemporaryDirectory() as temporary:
                receipt=v._domain(payload,'RECEIPT');request=v._domain(receipt['request'],'REQUEST');grant=v._domain(request['authority'],'AUTHORITY')
                change(grant);request['authority']=domain('AUTHORITY',grant);receipt['request']=domain('REQUEST',request);changed=domain('RECEIPT',receipt)
                d=Path(temporary);(d/'key').write_bytes(public)
                (d/'receipt').write_text(json.dumps({'version':1,'algorithm':'Ed25519','payload':base64.b64encode(changed).decode(),'signature':base64.b64encode(key.sign(changed)).decode(),'publicKey':base64.b64encode(public).decode()}))
                with self.assertRaises(v.ReceiptStructureError):v.verify(d/'receipt',d/'key')
    def test_unknown_request_field_is_rejected(self):
        envelope=json.loads((EVIDENCE/'legal-child-receipt.json').read_text())
        receipt=v._domain(base64.b64decode(envelope['payload']),'RECEIPT')
        request=v._domain(receipt['request'],'REQUEST');request['unknown']=True
        receipt['request']=domain('REQUEST',request);payload=domain('RECEIPT',receipt)
        key=Ed25519PrivateKey.generate();public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
        with tempfile.TemporaryDirectory() as temporary:
            d=Path(temporary);(d/'key').write_bytes(public)
            (d/'receipt').write_text(json.dumps({'version':1,'algorithm':'Ed25519','payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(key.sign(payload)).decode(),'publicKey':base64.b64encode(public).decode()}))
            with self.assertRaises(v.ReceiptStructureError):v.verify(d/'receipt',d/'key')
    def test_summary_minimizes_payload(self):
        r=v.verify(EVIDENCE/'legal-child-receipt.json',EVIDENCE/'trusted-public-key.raw',expected_authority=EXPECTED)
        self.assertNotIn('requested',json.dumps(r));self.assertNotIn('arguments',r['signedClaims'])
        self.assertNotIn('observation',r['signedClaims']);self.assertNotIn('targets',r['signedClaims']['authority'])

if __name__=='__main__':unittest.main()
