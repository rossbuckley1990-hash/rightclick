#!/usr/bin/python3
"""Controlled transport fixture; never contacts a broker or cluster."""
import json
import pathlib
import sys

state = pathlib.Path(__STATE_DIRECTORY_JSON__)
args = sys.argv[1:]
mode = (state / "mode").read_text()
old = "11111111-1111-4111-8111-111111111111"
if "--config" in args:
    if "list" in args:
        print(json.dumps([{"name": "rightclick.proof", "partitions": 1}]))
    elif "produce" in args:
        wire = sys.stdin.buffer.read()
        marker = next((a.split(":", 1)[1] for a in args if a.startswith("--header=rightclick.invocation:")), old)
        key = next(a.split("=", 1)[1] for a in args if a.startswith("--key="))
        (state / "record").write_text(json.dumps({"topic": "rightclick.proof", "partition": 0, "offset": 3,
            "key": key, "value": wire[4:].decode(), "timestamp": 1,
            "headers": [{"key": "rightclick.invocation", "value": marker}]}))
        print(json.dumps({"topic": "rightclick.proof", "partition": 0, "offset": 3}))
    elif "consume" in args:
        record = json.loads((state / "record").read_text())
        if mode == "stale":
            record["headers"][0]["value"] = old
        print(json.dumps(record))
    else:
        raise SystemExit(1)
else:
    config = json.loads(pathlib.Path(args[args.index("--kubeconfig") + 1]).read_text())
    principal = config["users"][0]["name"]
    if "whoami" in args:
        print(json.dumps({"status": {"userInfo": {"username": "system:serviceaccount:rightclick-proof:" + principal}}}))
    elif "can-i" in args:
        verb = args[args.index("can-i") + 1]
        ns = args[-1]
        permitted = ns == "rightclick-proof" and ((principal == "writer" and verb == "create") or (principal == "reader" and verb == "get"))
        print("yes" if permitted else "no")
        raise SystemExit(0 if permitted else 1)
    elif "--raw" in args:
        print(json.dumps({"kind": "APIResourceList", "groupVersion": "v1", "resources": [
            {"name": "configmaps", "kind": "ConfigMap", "namespaced": True, "verbs": ["get", "create"]}]}))
    elif "create" in args:
        manifest = json.load(sys.stdin)
        manifest["metadata"].update({"uid": "controlled-uid", "resourceVersion": "1"})
        (state / "resource").write_text(json.dumps(manifest))
        print(json.dumps(manifest))
    elif "configmap" in args:
        manifest = json.loads((state / "resource").read_text())
        if mode == "stale":
            manifest["metadata"]["annotations"] = {"rightclick.io/invocation": old}
        print(json.dumps(manifest))
    else:
        raise SystemExit(1)
