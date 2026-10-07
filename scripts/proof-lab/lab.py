#!/usr/bin/env python3
"""Disposable real infrastructure controls. These are NOT seven-operation acceptance.

No default kubeconfig is read or written. Secret state lives only in a private
temporary directory. Every removal checks the exact resource's ownership label.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
CLUSTER = "rightclick-proof"
LINUX = "rightclick-proof-linux"
KAFKA = "rightclick-proof-kafka"
LABEL = "io.rightclick.proof-lab"
REDPANDA = "docker.redpanda.com/redpandadata/redpanda:v26.2.3"
KIND_IMAGE = "kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"


def command(args, *, stdin=None, timeout=45, check=True, sensitive=False):
    try:
        p = subprocess.run(args, input=stdin, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{args[0]} operation timed out after {timeout}s") from None
    if check and p.returncode:
        detail = "credential operation failed (details withheld)" if sensitive else p.stderr[-2000:]
        raise RuntimeError(f"{args[0]} failed with exit {p.returncode}: {detail}")
    return p


def docker(*args, **kwargs):
    return command(["docker", *args], **kwargs)


def private_write(path, content):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o600)


def kubectl(state, role, *args, **kwargs):
    return command(["kubectl", "--kubeconfig", str(state / (role + ".kubeconfig")),
                    "--request-timeout=20s", *args], **kwargs)


def owned(name):
    p = docker("inspect", name, check=False)
    if p.returncode:
        return False
    resource = json.loads(p.stdout)[0]
    labels = resource.get("Config", {}).get("Labels", {})
    valid = labels.get(LABEL) == CLUSTER
    if name == CLUSTER + "-control-plane":
        valid = labels.get("io.x-k8s.kind.cluster") == CLUSTER
    if not valid:
        raise RuntimeError(f"Refusing to modify {name}: proof ownership label absent")
    return True


def await_ready(probe, seconds=120):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            return probe()
        except (RuntimeError, OSError, ValueError) as exc:
            last = str(exc)
            time.sleep(2)
    raise RuntimeError("readiness deadline exceeded: " + str(last))


def request(path, token=None, payload=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None if payload is None else json.dumps(payload).encode()
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:19141" + path,
                                                     data=body, headers=headers), timeout=10) as response:
        return response.status, json.load(response)


def rpk(*args, identity=None, **kwargs):
    options = [] if identity is None else ["--config", "/tmp/rightclick-" + identity + ".yaml"]
    return docker("exec", "-i", KAFKA, "rpk", *options, *args, **kwargs)


def prepare_kafka(state):
    # Admin API remains private to this container. Only the SASL-protected Kafka
    # listener is mapped to loopback; provider identities receive topic ACLs.
    rpk("topic", "create", "rightclick.proof", "rightclick.forbidden", "-p", "1", "-r", "1")
    credentials = {}
    for identity in ("publisher", "observer"):
        username = "rightclick-proof-" + identity
        password = secrets.token_urlsafe(32)
        rpk("security", "user", "create", username, "-p", password, sensitive=True)
        rpk("security", "acl", "create", "--allow-principal", "User:" + username,
            "--operation", "write,describe" if identity == "publisher" else "read,describe",
            "--topic", "rightclick.proof")
        config = {"rpk": {"kafka_api": {"brokers": ["127.0.0.1:19092"], "sasl": {
            "user": username, "password": password, "mechanism": "SCRAM-SHA-256"}}}}
        private_write(state / ("kafka-" + identity + ".json"), json.dumps(config))
        docker("exec", "-i", KAFKA, "sh", "-c",
               "umask 077; cat > /tmp/rightclick-" + identity + ".yaml",
               stdin=json.dumps(config), sensitive=True)
        credentials[identity] = {"source": "private-file", "reference": str(state / ("kafka-" + identity + ".json")),
                                 "principal": username, "authority": "topic:rightclick.proof:" +
                                 ("write,describe" if identity == "publisher" else "read,describe")}
    rpk("cluster", "config", "set", "enable_sasl", "true")
    return credentials


def prepare_kubernetes(state):
    kubectl(state, "admin", "apply", "-f", str(HERE / "kubernetes-authority.json"))
    token = kubectl(state, "admin", "-n", CLUSTER, "create", "token", CLUSTER, "--duration=1h", sensitive=True).stdout.strip()
    private_write(state / "kubernetes-token", token)
    admin = json.loads(kubectl(state, "admin", "config", "view", "--raw", "--minify", "-o", "json", sensitive=True).stdout)
    cluster = admin["clusters"][0]
    config = {"apiVersion": "v1", "kind": "Config", "clusters": [cluster],
              "users": [{"name": CLUSTER, "user": {"token": token}}],
              "contexts": [{"name": CLUSTER, "context": {"cluster": cluster["name"], "user": CLUSTER, "namespace": CLUSTER}}],
              "current-context": CLUSTER}
    private_write(state / "scoped.kubeconfig", json.dumps(config))
    import base64
    claims = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
    return {"source": "Kubernetes TokenRequest", "reference": str(state / "kubernetes-token"),
            "kubeconfigReference": str(state / "scoped.kubeconfig"),
            "principal": "system:serviceaccount:rightclick-proof:rightclick-proof",
            "authority": "namespace:rightclick-proof:configmaps:get,create,update,patch,delete",
            "expiry": dt.datetime.fromtimestamp(claims["exp"], dt.timezone.utc).isoformat(),
            "server": cluster["cluster"]["server"]}


def up(state, image):
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.chmod(0o700)
    for name in (LINUX, KAFKA, CLUSTER + "-control-plane"):
        if owned(name):
            raise RuntimeError("Existing proof lab found; use its state or run explicit teardown first")
    # Small host service: non-root, no host-write bind, read-only filesystem.
    token = secrets.token_urlsafe(32)
    private_write(state / "linux.env", "RIGHTCLICK_PROOF_HOST_TOKEN=" + token + "\n")
    docker("run", "-d", "--name", LINUX, "--label", LABEL + "=" + CLUSTER,
           "--user", "1000:1000", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
           "--read-only", "--pids-limit", "32", "--memory", "64m", "--cpus", "0.5",
           "--tmpfs", "/state:rw,noexec,nosuid,size=4m,uid=1000,gid=1000,mode=0700",
           "--env-file", str(state / "linux.env"), "-p", "127.0.0.1:19141:8080",
           "--mount", "type=bind,src=" + str(HERE / "host-service.py") + ",dst=/app/service.py,readonly",
           "python:3.12-alpine", "python", "-B", "/app/service.py", timeout=180)
    await_ready(lambda: request("/health"))
    docker("run", "-d", "--name", KAFKA, "--label", LABEL + "=" + CLUSTER,
           "--memory", "1g", "--cpus", "1", "--pids-limit", "128", "-p", "127.0.0.1:19092:19092",
           REDPANDA, "redpanda", "start", "--smp", "1", "--memory", "512M", "--reserve-memory", "0M",
           "--overprovisioned", "--check=false", "--kafka-addr", "0.0.0.0:19092",
           "--advertise-kafka-addr", "127.0.0.1:19092", "--set", "redpanda.auto_create_topics_enabled=false", timeout=300)
    await_ready(lambda: rpk("cluster", "info"))
    kafka_credentials = prepare_kafka(state)
    command(["kind", "create", "cluster", "--name", CLUSTER, "--image", image,
             "--config", str(HERE / "kind.yaml"), "--kubeconfig", str(state / "admin.kubeconfig"),
             "--wait", "120s"], timeout=360)
    (state / "admin.kubeconfig").chmod(0o600)
    kubernetes_credential = prepare_kubernetes(state)
    provenance = {}
    for name in (LINUX, KAFKA, CLUSTER + "-control-plane"):
        inspected = json.loads(docker("inspect", name).stdout)[0]
        provenance[name] = {"imageReference": inspected["Config"]["Image"], "imageSHA256": inspected["Image"]}
    metadata = {"schemaVersion": 1, "acceptanceScope": "infrastructure readiness only",
                "credentials": {"linux": {"source": "private-env-file", "reference": str(state / "linux.env"),
                                          "authority": "isolated proof effect endpoint", "principal": "container uid1000"},
                                "kafka": kafka_credentials, "kubernetes": kubernetes_credential},
                "resources": {"linux": LINUX, "kafka": KAFKA, "cluster": CLUSTER, "namespace": CLUSTER},
                "endpoints": {"linux": "http://127.0.0.1:19141", "kafka": "127.0.0.1:19092", "kubernetes": "https://127.0.0.1:16443"},
                "providerProvenance": provenance}
    private_write(state / "metadata.json", json.dumps(metadata, indent=2))
    return metadata


def verify(state):
    metadata = json.loads((state / "metadata.json").read_text())
    challenge = "rcproof_" + uuid.uuid4().hex
    linux_token = (state / "linux.env").read_text().strip().split("=", 1)[1]
    accepted, _ = request("/proof", token=linux_token, payload={"challenge": challenge})
    effect = json.loads(docker("exec", LINUX, "cat", "/state/" + challenge + ".json").stdout)
    assert accepted == 202 and effect["platform"] == "Linux" and effect["uid"] == 1000
    assert effect["result"] == hashlib.sha256(("RIGHTCLICK:" + challenge).encode()).hexdigest()
    try:
        request("/proof", token="unavailable", payload={"challenge": challenge + "_denied"})
        raise AssertionError("invalid Linux credential accepted")
    except urllib.error.HTTPError as err:
        assert err.code == 401
    payload = {"challenge": challenge, "message": "hello from RIGHTCLICK"}
    ack = rpk("topic", "produce", "rightclick.proof", "-k", challenge,
              identity="publisher", stdin=json.dumps(payload) + "\n").stdout
    event = re.search(r"partition (\d+) at offset (\d+)", ack)
    assert event is not None, "Producer event identity was not reported"
    partition, offset = map(int, event.groups())
    consumed = rpk("topic", "consume", "rightclick.proof", "-p", str(partition), "-o", str(offset), "-n", "1",
                   "--format", "json", "--pretty-print=false", identity="observer").stdout
    record = json.loads(consumed)
    assert record["topic"] == "rightclick.proof" and record["partition"] == partition and record["offset"] == offset
    assert json.loads(record["value"]) == payload and record["key"] == challenge
    forbidden = rpk("topic", "produce", "rightclick.forbidden", identity="publisher",
                    stdin=json.dumps(payload) + "\n", check=False, timeout=30)
    assert forbidden.returncode != 0 and "authorization" in (forbidden.stdout + forbidden.stderr).lower()
    name = "proof-" + challenge.lower().replace("_", "-")
    resource = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": CLUSTER}, "data": payload}
    accepted_cm = json.loads(kubectl(state, "scoped", "create", "-f", "-", "-o", "json", stdin=json.dumps(resource)).stdout)
    observed = json.loads(kubectl(state, "admin", "-n", CLUSTER, "get", "configmap", name, "-o", "json").stdout)
    assert observed["data"] == payload and observed["metadata"]["uid"] == accepted_cm["metadata"]["uid"]
    denied = kubectl(state, "scoped", "get", "nodes", "-o", "json", check=False)
    assert denied.returncode != 0 and "Forbidden" in denied.stderr
    namespace_denied = kubectl(state, "scoped", "-n", "default", "get", "configmap", "out-of-scope", check=False)
    assert namespace_denied.returncode != 0 and "Forbidden" in namespace_denied.stderr
    unavailable = json.loads((state / "scoped.kubeconfig").read_text())
    unavailable["users"][0]["user"]["token"] = "unavailable-proof-authority"
    private_write(state / "unavailable.kubeconfig", json.dumps(unavailable))
    unavailable_result = kubectl(state, "unavailable", "-n", CLUSTER, "get", "configmap", name, check=False)
    assert unavailable_result.returncode != 0 and "Unauthorized" in unavailable_result.stderr
    (state / "unavailable.kubeconfig").unlink()
    return {**metadata, "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(), "challenge": challenge,
            "linux": {"state": "GREEN", "acceptedHTTP": accepted, "independentFileReadback": effect, "invalidCredentialHTTP": 401},
            "kafka": {"state": "GREEN", "producerACK": ack, "independentConsumerRecord": record,
                      "differentProducerObserverPrincipals": True, "outOfScopeTopicDenied": True},
            "kubernetes": {"state": "GREEN", "acceptedUID": accepted_cm["metadata"]["uid"],
                           "observedUID": observed["metadata"]["uid"], "observedResourceVersion": observed["metadata"]["resourceVersion"],
                           "observedData": observed["data"], "clusterWideDenied": True, "otherNamespaceDenied": True,
                           "denialEvidence": denied.stderr.strip(), "unavailableAuthorityDenied": True},
            "sevenOperationRuntimeAcceptance": "RED: infrastructure controls do not exercise the runtime"}


def down(state):
    if owned(CLUSTER + "-control-plane"):
        command(["kind", "delete", "cluster", "--name", CLUSTER, "--kubeconfig", str(state / "admin.kubeconfig")], timeout=120)
    for name in (KAFKA, LINUX):
        if owned(name):
            docker("rm", "-f", name, timeout=60)
    # Only explicit secret files created by this script are removed, never a
    # supplied directory or unrelated files. Evidence lives outside this state.
    for name in ("admin.kubeconfig", "scoped.kubeconfig", "unavailable.kubeconfig", "kubernetes-token", "linux.env",
                 "kafka-publisher.json", "kafka-observer.json", "metadata.json"):
        (state / name).unlink(missing_ok=True)
    return {"teardown": "GREEN", "resourceNames": [CLUSTER, KAFKA, LINUX]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["up", "verify", "down", "health"])
    parser.add_argument("--state", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--kind-image", default=KIND_IMAGE)
    args = parser.parse_args()
    state = args.state or Path(tempfile.mkdtemp(prefix="rightclick-proof-"))
    if args.operation == "health":
        result = {"docker": json.loads(docker("info", "--format", "{{json .}}", timeout=15).stdout)}
    elif args.operation == "up":
        result = up(state, args.kind_image)
    elif args.operation == "verify":
        result = verify(state)
    else:
        result = down(state)
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
