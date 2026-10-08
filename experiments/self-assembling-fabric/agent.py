import json, os, ssl, threading, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAMESPACE = os.environ.get("NAMESPACE", "rc-fabric")
AGENT = os.environ["AGENT_NAME"]
CAPACITY = int(os.environ["CAPACITY"])
MODULE_SHA = os.environ["MODULE_SHA"]
EXECUTOR_IMAGE = os.environ.get("EXECUTOR_IMAGE", "rc-wasm-executor:local")
TOKEN = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
API = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT_HTTPS']}"
CTX = ssl.create_default_context(cafile=CA)
tasks = {}
lock = threading.RLock()

def kreq(method, path, body=None, text=False):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=CTX, timeout=15) as r:
        raw = r.read().decode()
        if text:
            return raw
        return json.loads(raw) if raw else {}

def create_job(task_id, start, end, delay):
    safe = task_id.lower().replace("_", "-")
    name = f"wasm-{AGENT}-{safe}"[:63].rstrip("-")
    body = {
      "apiVersion": "batch/v1", "kind": "Job",
      "metadata": {"name": name, "namespace": NAMESPACE,
                   "labels": {"experiment": "self-assembling", "task-id": safe, "assigned-agent": AGENT}},
      "spec": {"backoffLimit": 0, "template": {
        "metadata": {"labels": {"experiment": "self-assembling", "task-id": safe, "assigned-agent": AGENT}},
        "spec": {"restartPolicy": "Never", "containers": [{
          "name": "wasm", "image": EXECUTOR_IMAGE, "imagePullPolicy": "Never",
          "env": [
            {"name":"TASK_ID","value":task_id},
            {"name":"ASSIGNED_AGENT","value":AGENT},
            {"name":"START","value":str(start)},
            {"name":"END","value":str(end)},
            {"name":"MODULE_SHA","value":MODULE_SHA},
            {"name":"DELAY","value":str(delay)}
          ]
        }]}
      }}
    }
    kreq("POST", f"/apis/batch/v1/namespaces/{NAMESPACE}/jobs", body)
    return name

def task_status(rec):
    job = kreq("GET", f"/apis/batch/v1/namespaces/{NAMESPACE}/jobs/{rec['job']}")
    status = job.get("status", {})
    if status.get("succeeded", 0) >= 1:
        pods = kreq("GET", f"/api/v1/namespaces/{NAMESPACE}/pods?labelSelector=" +
                    urllib.parse.quote("job-name=" + rec["job"]))
        pod = pods["items"][0]["metadata"]["name"]
        log = kreq("GET", f"/api/v1/namespaces/{NAMESPACE}/pods/{pod}/log", text=True).strip()
        envelope = json.loads(log.splitlines()[-1])
        with lock:
            rec["state"] = "completed"
            rec["result"] = envelope
            rec["pod"] = pod
        return {"task_id": rec["task_id"], "state": "completed", "agent": AGENT,
                "job": rec["job"], "pod": pod, "result": envelope}
    if status.get("failed", 0) >= 1:
        with lock:
            rec["state"] = "failed"
        return {"task_id": rec["task_id"], "state": "failed", "agent": AGENT, "job": rec["job"]}
    return {"task_id": rec["task_id"], "state": "running", "agent": AGENT, "job": rec["job"]}

def active_count():
    with lock:
        return sum(1 for r in tasks.values() if r.get("state") not in ("completed","failed"))

class H(BaseHTTPRequestHandler):
    def sendj(self, code, obj):
        raw = json.dumps(obj, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/.well-known/agent-card.json":
            self.sendj(200, {
              "name": AGENT,
              "url": f"http://{AGENT}:8080",
              "protocolVersion": "A2A-minimal-experiment-v1",
              "standardsConformance": False,
              "skills": [{"id":"wasm-shard","name":"Execute content-addressed WASM shard"}],
              "capacity": CAPACITY,
              "active": active_count(),
              "module_sha256": MODULE_SHA
            })
            return
        if self.path.startswith("/tasks/"):
            tid = self.path.split("/",2)[2]
            with lock:
                rec = tasks.get(tid)
            if rec is None:
                self.sendj(404, {"error":"unknown task"})
                return
            try:
                self.sendj(200, task_status(rec))
            except Exception as e:
                self.sendj(503, {"task_id":tid,"state":"unavailable","error":str(e)})
            return
        self.sendj(404, {"error":"not found"})

    def do_POST(self):
        if self.path != "/tasks":
            self.sendj(404, {"error":"not found"})
            return
        length = int(self.headers.get("Content-Length","0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if body.get("module_sha256") != MODULE_SHA:
            self.sendj(409, {"error":"module hash refused"})
            return
        tid = body["task_id"]
        with lock:
            if active_count() >= CAPACITY:
                self.sendj(429, {"error":"capacity exhausted","agent":AGENT})
                return
            if tid in tasks:
                self.sendj(409, {"error":"duplicate task","agent":AGENT})
                return
        try:
            job = create_job(tid, int(body["start"]), int(body["end"]), float(body.get("delay",0)))
            rec = {"task_id":tid,"state":"accepted","job":job,"start":int(body["start"]),"end":int(body["end"])}
            with lock:
                tasks[tid] = rec
            self.sendj(202, {"task_id":tid,"state":"accepted","agent":AGENT,"job":job,
                             "module_sha256":MODULE_SHA})
        except Exception as e:
            self.sendj(500, {"error":str(e),"agent":AGENT})

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("0.0.0.0",8080), H).serve_forever()
