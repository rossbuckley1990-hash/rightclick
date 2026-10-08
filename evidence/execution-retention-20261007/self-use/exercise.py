"""Actual stable RIGHTCLICK self-use for the bounded-retention engineering task."""
import hashlib, json, os, pathlib, selectors, subprocess, time
out = pathlib.Path(__file__).resolve().parent
root = out.parents[2]
binary = pathlib.Path('/opt/homebrew/bin/rightclick').resolve()
source = root / 'Sources/RightClickCore/Capability.swift'
transcript = []
environment = {k:v for k,v in os.environ.items() if not k.startswith('RIGHTCLICK_')}
environment['RIGHTCLICK_CAPABILITY_EXPERIENCE'] = 'disabled'
process = subprocess.Popen([str(binary), 'mcp'], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=(out / 'runtime.stderr').open('w'), text=True, bufsize=1)
selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
def rpc(method, params=None):
    request = {'jsonrpc':'2.0','id':len(transcript)+1,'method':method}
    if params is not None: request['params'] = params
    process.stdin.write(json.dumps(request)+'\n'); process.stdin.flush()
    deadline = time.monotonic()+40
    while time.monotonic()<deadline:
        if selector.select(max(0,deadline-time.monotonic())):
            reply = json.loads(process.stdout.readline())
            if reply.get('id')==request['id']:
                transcript.append({'request':request,'response':reply})
                assert not reply.get('error'), reply
                return reply['result']
    raise TimeoutError(method)
def call(name, arguments):
    result=rpc('tools/call',{'name':name,'arguments':arguments})
    assert not result.get('isError'), result
    return json.loads(result['content'][0]['text'])
try:
    rpc('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'retention-self-use','version':'1'}})
    runtime=call('context_runtime',{})
    tools=rpc('tools/list')['tools']
    assert {t['name'] for t in tools}=={'context_runtime','context_inspect','context_actions','context_explain','context_run','context_run_status','context_providers'}
    call('context_inspect',{'item':str(source)})
    actions=call('context_actions',{'item':str(source)})
    native=call('context_actions',{'item':'RIGHTCLICK retention'})
    action='service:com.apple.ChineseTextConverterService:convertTextToFullWidth'
    assert any(a['id']==action for a in native['actions'])
    explanation=call('context_explain',{'item':'RIGHTCLICK retention','actionId':action})
    result=call('context_run',{'item':'RIGHTCLICK retention','actionId':action,'confirmed':True,'expectedOutput':'ＲＩＧＨＴＣＬＩＣＫ　ｒｅｔｅｎｔｉｏｎ'})
    assert result['state']=='succeeded' and result['evidence']['outcomeVerified'], result
    status=call('context_run_status',{'executionId':result['executionId']})
    assert status['output']==result['output']
    summary={'runtime':runtime,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
             'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
             'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
             'sourceHasUncommittedRetentionChange':True,'topLevelToolCount':len(tools),
             'taskSourceActionCount':len(actions['actions']), 'nativeAction':action,'nativeOutput':result['output'],
             'proceduralMemory':'No verified executable procedure was discovered; stable lacks the new retention primitive.',
             'scope':'Actual stable runtime self-use. Not evidence that this stable binary contains the retention fix.'}
    (out/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
finally:
    (out/'transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    selector.close(); process.terminate(); process.wait(timeout=10)
