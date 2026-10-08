import base64, hashlib, json, os, ssl, time, urllib.error, urllib.parse, urllib.request

NS = os.environ.get("NAMESPACE","rc-fabric")
MODULE_SHA = os.environ["MODULE_SHA"]
TOKEN = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
API = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT_HTTPS']}"
CTX = ssl.create_default_context(cafile=CA)
events, negotiations, graph_nodes, graph_edges, http_tx = [], [], [], [], []

def kreq(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API+path, data=data, method=method)
    req.add_header("Authorization","Bearer "+TOKEN)
    if data is not None:
        req.add_header("Content-Type","application/json")
    with urllib.request.urlopen(req, context=CTX, timeout=15) as r:
        raw=r.read().decode()
        return json.loads(raw) if raw else {}

def kdelete(path):
    try:
        return kreq("DELETE", path)
    except Exception:
        return {}

def http_json(url, method="GET", body=None, timeout=8):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type","application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw=r.read().decode()
            http_tx.append({"method":method,"url":url,"status":r.status})
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw=e.read().decode()
        http_tx.append({"method":method,"url":url,"status":e.code})
        return e.code, json.loads(raw) if raw else {}

def discover(retries=20):
    for _ in range(retries):
        svcs=kreq("GET", f"/api/v1/namespaces/{NS}/services?labelSelector="+urllib.parse.quote("a2a-agent=true"))
        cards=[]
        for s in svcs.get("items",[]):
            name=s["metadata"]["name"]
            try:
                code,card=http_json(f"http://{name}:8080/.well-known/agent-card.json",timeout=3)
                if code==200:
                    cards.append(card)
            except Exception:
                pass
        if cards:
            return cards
        time.sleep(1)
    return []

def select_agent(exclude=None):
    exclude=set(exclude or [])
    cards=discover()
    candidates=[c for c in cards if c["name"] not in exclude and c["active"] < c["capacity"]]
    if not candidates:
        raise RuntimeError("no agent capacity available")
    ranked=sorted(candidates, key=lambda c:(c["capacity"]-c["active"], c["capacity"], c["name"]), reverse=True)
    selected=ranked[0]
    negotiations.append({
      "candidates":[{"name":c["name"],"capacity":c["capacity"],"active":c["active"],
                     "free":c["capacity"]-c["active"]} for c in cards],
      "excluded":sorted(exclude),
      "selected":selected["name"],
      "policy":"max live free capacity; ties by capacity/name"
    })
    return selected

def assign(task, exclude=None, delay=1):
    card=select_agent(exclude)
    payload={"task_id":task["task_id"],"start":task["start"],"end":task["end"],
             "module_sha256":MODULE_SHA,"delay":delay}
    code,resp=http_json(card["url"]+"/tasks","POST",payload)
    if code != 202:
        raise RuntimeError(f"assignment rejected {code} {resp}")
    events.append({"event":"accepted","task_id":task["task_id"],"agent":resp["agent"],"job":resp["job"]})
    graph_nodes.extend([
      {"id":"agent:"+resp["agent"],"type":"a2a-agent"},
      {"id":"job:"+resp["job"],"type":"kubernetes-job"},
      {"id":"wasm:"+MODULE_SHA,"type":"wasm-capsule"}
    ])
    graph_edges.extend([
      {"from":"coordinator","to":"agent:"+resp["agent"],"kind":"a2a-http"},
      {"from":"agent:"+resp["agent"],"to":"job:"+resp["job"],"kind":"materializes"},
      {"from":"job:"+resp["job"],"to":"wasm:"+MODULE_SHA,"kind":"executes"}
    ])
    return {"task":task,"agent":resp["agent"],"url":card["url"],"job":resp["job"]}

def kill_accepted(a):
    pods=kreq("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector="+urllib.parse.quote("app="+a["agent"]))
    pod=pods["items"][0]["metadata"]["name"] if pods.get("items") else None
    kdelete(f"/apis/batch/v1/namespaces/{NS}/jobs/{a['job']}?propagationPolicy=Foreground")
    if pod:
        kdelete(f"/api/v1/namespaces/{NS}/pods/{pod}")
    events.append({"event":"interrupted","task_id":a["task"]["task_id"],"agent":a["agent"],
                   "job":a["job"],"pod":pod,"cause":"forced failure injection"})
    return pod

def verify_envelope(task, env):
    if env["task_id"] != task["task_id"]: return False
    if env["module_sha256"] != MODULE_SHA: return False
    ih=hashlib.sha256(f"{task['start']}:{task['end']}".encode()).hexdigest()
    if env["input_hash"] != ih: return False
    oh=hashlib.sha256(str(env["result"]).encode()).hexdigest()
    return env["output_hash"] == oh

N=10000
width=N//4
tasks=[]
start=1
for i in range(4):
    end=N if i==3 else start+width-1
    tasks.append({"task_id":f"shard-{i}","start":start,"end":end})
    start=end+1

initial_cards=discover()
if len(initial_cards) < 3:
    raise SystemExit(f"need 3 agents, found {len(initial_cards)}")

graph_nodes.append({"id":"coordinator","type":"coordinator"})

victim=assign(tasks[0],delay=12)
time.sleep(1)
victim_pod=kill_accepted(victim)
recovered=assign(tasks[0],exclude={victim["agent"]},delay=1)
events.append({"event":"reassigned","task_id":tasks[0]["task_id"],
               "from":victim["agent"],"to":recovered["agent"],"job":recovered["job"]})

assignments=[recovered]
for t in tasks[1:]:
    assignments.append(assign(t,delay=1))

results={}
deadline=time.time()+180
for a in assignments:
    tid=a["task"]["task_id"]
    while time.time() < deadline:
        try:
            code,st=http_json(a["url"]+"/tasks/"+tid)
        except Exception:
            code,st=503,{}
        if code==200 and st.get("state")=="completed":
            env=st["result"]
            if not verify_envelope(a["task"],env):
                raise SystemExit("cryptographic envelope verification failed for "+tid)
            results[tid]=env
            events.append({"event":"completed","task_id":tid,"agent":a["agent"],"job":a["job"],
                           "result":env["result"],"verified_envelope":True})
            break
        if code==200 and st.get("state")=="failed":
            raise SystemExit("executor failed for "+tid)
        time.sleep(1)
    else:
        raise SystemExit("timeout waiting for "+tid)

observed=sum(int(results[t["task_id"]]["result"]) for t in tasks)
expected=N*(N+1)*(2*N+1)//6
failure={
  "task_id":tasks[0]["task_id"],
  "victim_agent":victim["agent"],
  "victim_job":victim["job"],
  "victim_pod":victim_pod,
  "recovery_agent":recovered["agent"],
  "recovery_job":recovered["job"],
  "same_module_sha256":MODULE_SHA,
  "recovered": tasks[0]["task_id"] in results and victim["agent"] != recovered["agent"]
}
evidence={
  "protocol":{"a2a_http":True,"agent_card_path":"/.well-known/agent-card.json",
              "task_submit_path":"/tasks","task_status_path":"/tasks/{id}",
              "standards_conformance":False,
              "statement":"Minimal A2A-style HTTP surface used for the experiment; no claim of full A2A SDK conformance."},
  "agent_cards":initial_cards,
  "negotiations":negotiations,
  "events":events,
  "http_transactions":http_tx,
  "execution_graph":{"nodes":graph_nodes,"edges":graph_edges},
  "failure_injection":failure,
  "results":results,
  "final_verification":{"n":N,"expected":expected,"observed":observed,
                        "coordinator_verified":observed==expected,
                        "result_sha256":hashlib.sha256(str(observed).encode()).hexdigest()}
}
print("EVIDENCE_B64="+base64.b64encode(json.dumps(evidence,separators=(",",":")).encode()).decode(),flush=True)
print(f"RESULT VERIFIED={str(observed==expected).lower()} OBSERVED={observed} EXPECTED={expected} RECOVERED={str(failure['recovered']).lower()}",flush=True)
if observed != expected or not failure["recovered"]:
    raise SystemExit(2)
