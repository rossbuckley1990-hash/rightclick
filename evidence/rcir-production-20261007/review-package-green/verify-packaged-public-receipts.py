from pathlib import Path
import base64,json,subprocess,tempfile,hashlib,struct
work=Path(__file__).parent;e=work/'evidence';report=[]
def decode(data):
 if data.startswith(b'RIGHTCLICK-VALUE-1\0'):p=len(b'RIGHTCLICK-VALUE-1\0')
 else:
  p=data.index(b'\0')+1;assert data[p:].startswith(b'RIGHTCLICK-VALUE-1\0');p+=len(b'RIGHTCLICK-VALUE-1\0')
 def value():
  nonlocal p
  tag=data[p:p+1];p+=1
  if tag==b'n':return None
  if tag==b'b':b=data[p:p+1];p+=1;return b==b'1'
  if tag==b'd':v=struct.unpack('>d',data[p:p+8])[0];p+=8;return v
  colon=data.index(b':',p);n=int(data[p:colon]);p=colon+1
  if tag in (b's',b'x',b'i'):
   raw=data[p:p+n];p+=n;return raw if tag==b'x' else int(raw) if tag==b'i' else raw.decode()
  if tag==b'a':return [value() for _ in range(n)]
  if tag==b'o':
   result={}
   for _ in range(n):k=value();result[k]=value()
   return result
  raise ValueError(tag)
 result=value();assert p==len(data);return result
for label in ['packaged-public-seven','packaged-public-freshness-ten']:
 d=e/label;r=json.loads((d/'results.json').read_text());t=json.loads((d/'transcript.json').read_text());effects=[json.loads(line) for line in (d/'effects.jsonl').read_text().splitlines()];observations=[json.loads(line) for line in (d/'observations.jsonl').read_text().splitlines()];runs={}
 assert r['result']=='PASS' and r['binarySHA256']=='9b6564c49112debe54efc8f6cb53a62a337e4240fa389506386cde086b71d464'
 tools=t[1]['response']['result']['tools'];assert len(tools)==7;assert r['toolSchemaSHA256']==hashlib.sha256(json.dumps(tools,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 for row in t:
  if row['request'].get('params',{}).get('name')=='context_run':
   ident=row['request']['params']['arguments']['arguments']['id'];runs[ident]=json.loads(row['response']['result']['content'][0]['text'])
 assert {v['arguments']['id'] for v in effects}=={ident for ident,v in runs.items() if v.get('rcir',{}).get('leaseConsumed')}
 assert not {'confirmation','policy','argument','stale-schema'} & {v['arguments']['id'] for v in effects}
 assert runs['good']['state']=='succeeded' and runs['wrong']['state']=='failed' and runs['missing']['state']=='accepted' and runs['missing']['rcir']['outcome']=='unverified'
 assert runs['good']['rcir']['leaseID']!=runs['repeat']['rcir']['leaseID']
 for effect in effects:
  ident=effect['arguments']['id'];assert effect['method']=='POST' and effect['path']=='/records';assert effect['correlationID']==runs[ident]['rcir']['taskID'];assert effect['arguments']=={'id':ident,'value':'useful verified output'}
 verifications=[]; backendCalls=[]
 for kind,ident in [('success','good'),('failure','wrong')]:
  envelope=json.loads((d/(kind+'-receipt.json')).read_text());pub=(d/'trusted-public-key.raw').read_bytes();assert base64.b64decode(envelope['publicKey'])==pub;assert envelope['version']==1 and envelope['algorithm']=='Ed25519';payload=base64.b64decode(envelope['payload']);signature=base64.b64decode(envelope['signature']);rcir=runs[ident]['rcir'];receipt=decode(payload)
  assert payload==base64.b64decode(rcir['receipt']);assert receipt['taskID']==rcir['taskID'] and receipt['leaseID']==rcir['leaseID'] and receipt['phase']==rcir['phase'] and receipt['semanticOutcome']==rcir['outcome']
  with tempfile.TemporaryDirectory(prefix='rightclick-packaged-independent-signature-') as tmp:
   tmp=Path(tmp);(tmp/'public.der').write_bytes(bytes.fromhex('302a300506032b6570032100')+pub);(tmp/'payload').write_bytes(payload);(tmp/'signature').write_bytes(signature)
   command=['openssl','pkeyutl','-verify','-pubin','-inkey',str(tmp/'public.der'),'-keyform','DER','-rawin','-in',str(tmp/'payload'),'-sigfile',str(tmp/'signature')]
   verified=subprocess.run(command,capture_output=True);assert verified.returncode==0
   backendCalls.append({'receipt':kind,'case':'valid','argv':command,'exit':verified.returncode,'stdout':verified.stdout.decode(),'stderr':verified.stderr.decode()})
   modified=bytearray(payload);modified[-1]^=1;(tmp/'payload').write_bytes(modified);payload_bad=subprocess.run(command,capture_output=True);assert payload_bad.returncode!=0
   backendCalls.append({'receipt':kind,'case':'tampered payload last byte xor1','argv':command,'exit':payload_bad.returncode,'stdout':payload_bad.stdout.decode(),'stderr':payload_bad.stderr.decode()})
   (tmp/'payload').write_bytes(payload);modified=bytearray(signature);modified[0]^=1;(tmp/'signature').write_bytes(modified);signature_bad=subprocess.run(command,capture_output=True);assert signature_bad.returncode!=0
   backendCalls.append({'receipt':kind,'case':'tampered signature first byte xor1','argv':command,'exit':signature_bad.returncode,'stdout':signature_bad.stdout.decode(),'stderr':signature_bad.stderr.decode()})
  verifications.append({'kind':kind,'algorithm':'Ed25519','separatelyPinnedKeySHA256':hashlib.sha256(pub).hexdigest(),'payloadSHA256':hashlib.sha256(payload).hexdigest(),'signatureSHA256':hashlib.sha256(signature).hexdigest(),'verificationExit':verified.returncode,'tamperedPayloadVerificationExit':payload_bad.returncode,'tamperedSignatureVerificationExit':signature_bad.returncode,'state':runs[ident]['state'],'signedOutcome':receipt['semanticOutcome'],'signedObservation':decode(receipt['observation']),'taskID':receipt['taskID'],'leaseID':receipt['leaseID'],'phase':receipt['phase'],'matchesPublicRCIREvidence':True})
 rec={'label':label,'outcome':'PASS','controlCount':len(r['controls']),'binarySHA256':r['binarySHA256'],'toolCount':len(tools),'toolSchemaSHA256':r['toolSchemaSHA256'],'effects':len(effects),'readbacks':len(observations),'effectTaskCorrelation':'PASS','deniedControlsProduceZeroEffects':'PASS','separatelyApprovedRepeatNewLease':'PASS','missingObservationOutcome':runs['missing']['rcir']['outcome'],'signatureVerification':verifications,'states':{ident:record['state'] for ident,record in runs.items()},'sourceCommit':'3320d2fbf3fad75e337622da72f8d2dbec6acb65','boundary':'Fixture key separately captured/pinned for this new run. Independent OpenSSL verification of CryptoKit signatures; same-service readback trust, not production issuer/signer trust or third-party attestation.'}
 (e/(label+'-openssl-raw.json')).write_text(json.dumps(backendCalls,indent=2)+'\n')
 report.append(rec)
(e/'packaged-public-independent-verification.json').write_text(json.dumps({'runKind':'NEW_RUN','verifier':'Independent Python canonical parser and OpenSSL Ed25519 verification; test source and receipt files unmodified','opensslVersion':subprocess.check_output(['openssl','version'],text=True).strip(),'runs':report},indent=2)+'\n')
print(json.dumps(report,indent=2))
