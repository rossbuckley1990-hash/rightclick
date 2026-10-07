from pathlib import Path
import base64,copy,importlib.util,json,struct
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
root=Path(__file__).parent
spec=importlib.util.spec_from_file_location('reviewed_verifier',root/'scripts/verify-rcir-receipt.py')
v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
original=json.loads((root/'evidence/rcir-invocation-isolation-20261007/public-mcp/success-receipt.json').read_text())
base=v._domain(base64.b64decode(original['payload']),'RECEIPT')
def encode(value):
 if value is None:return b'n'
 if type(value) is bool:return b'b1' if value else b'b0'
 if type(value) is int: raw=str(value).encode();return b'i'+str(len(raw)).encode()+b':'+raw
 if type(value) is float:return b'd'+struct.pack('>d',value)
 if isinstance(value,str):raw=value.encode('utf-8');return b's'+str(len(raw)).encode()+b':'+raw
 if isinstance(value,bytes):return b'x'+str(len(value)).encode()+b':'+value
 if isinstance(value,list):return b'a'+str(len(value)).encode()+b':'+b''.join(map(encode,value))
 if isinstance(value,dict):return b'o'+str(len(value)).encode()+b':'+b''.join(encode(k)+encode(value[k]) for k in sorted(value,key=lambda k:k.encode('utf-8')))
 raise TypeError(type(value))
def value(x):return b'RIGHTCLICK-VALUE-1\0'+encode(x)
def domain(name,x):return ('RIGHTCLICK-RCIR-'+name+'-1\0').encode()+value(x)
key=Ed25519PrivateKey.generate(); public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
out=root/'adversarial';out.mkdir(exist_ok=True);pinned=out/'disposable-trust-pin.raw';pinned.write_bytes(public)
def invalid_contract(receipt):
 request=v._domain(receipt['request'],'REQUEST');binding=v._domain(request['binding'],'BINDING')
 binding['contract']=b'not a contract or ABI';binding['discovery']=b'not a graph declaration'
 request['binding']=domain('BINDING',binding);receipt['request']=domain('REQUEST',request)
def empty_policy(receipt):
 request=v._domain(receipt['request'],'REQUEST');request['policy']=domain('POLICY',{})
 receipt['request']=domain('REQUEST',request)
def contradictory_terminal(receipt):
 event=v._value(receipt['events'][-1]);event['kind']='cancelled';event['value']=None
 receipt['events'][-1]=value(event)
def missing_completion(receipt):
 receipt['events']=[];receipt['lastSequence']=0
results=[]
for label,mutate in [('malformed-bound-contract',invalid_contract),('malformed-empty-policy',empty_policy),('cancelled-event-succeeded-claim',contradictory_terminal),('succeeded-without-completion-event',missing_completion)]:
 receipt=copy.deepcopy(base);mutate(receipt);payload=domain('RECEIPT',receipt)
 envelope={'version':1,'algorithm':'Ed25519','payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(key.sign(payload)).decode(),'publicKey':base64.b64encode(public).decode()}
 path=out/(label+'.json');path.write_text(json.dumps(envelope)+'\n')
 try:
  verified=v.verify(path,pinned,expected_outcome='succeeded',expected_task_id=receipt['taskID'])
  row={'case':label,'expected':'REJECT_MALFORMED_OR_INCONSISTENT','observed':'ACCEPTED','result':verified}
 except Exception as e:row={'case':label,'expected':'REJECT_MALFORMED_OR_INCONSISTENT','observed':'REJECTED','error':type(e).__name__}
 results.append(row);print(label+': '+row['observed'])
(out/'results.json').write_text(json.dumps({'reviewed_source':'640a71f4ca8905a11111666ba959568a2ab9fb52','proof_kind':'DISPOSABLE_SIGNED_STRUCTURE_NEGATIVES_NOT_EXTERNAL_EFFECT_PROOF','results':results},indent=2)+'\n')
