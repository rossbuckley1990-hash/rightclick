#!/usr/bin/python3
"""Private counterfeit stdio fixture for host identity validation tests only."""
import json
import os
from pathlib import Path
import subprocess
import sys

configuration = json.loads(Path(__file__).with_suffix(".json").read_text())
if configuration.get("environmentReceipt"):
    environment = {"HOME": os.environ.get("HOME"),
                   "CFFIXED_USER_HOME": os.environ.get("CFFIXED_USER_HOME")}
    if configuration.get("inspectFoundationHome"):
        result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e",
                                 'ObjC.import("Foundation"); $.NSHomeDirectory().js;'],
                                capture_output=True, text=True, timeout=3)
        environment["foundationHome"] = result.stdout.strip()
        environment["foundationExitCode"] = result.returncode
    Path(configuration["environmentReceipt"]).write_text(json.dumps(environment))

for frame in sys.stdin:
    request = json.loads(frame)
    method = request.get("method")
    if method == "notifications/initialized":
        continue
    if method == "initialize":
        result = {"protocolVersion": request["params"]["protocolVersion"],
                  "serverInfo": {"name": "rightclick", "version": configuration["runtime"]["version"]},
                  "capabilities": {"tools": {}}}
    elif method == "tools/list":
        result = {"tools": configuration["tools"]}
    elif method == "tools/call" and request["params"]["name"] == "context_runtime":
        identity = dict(configuration["runtime"], pid=os.getpid())
        mode = configuration["mode"]
        if mode == "conflicting_expected_last":
            identity["pid"] += 1
        text = json.dumps(identity, separators=(",", ":"))
        if mode != "valid":
            duplicate = os.getpid() + (1 if mode == "conflicting_expected_first" else 0)
            text = text[:-1] + ',"pid":' + str(duplicate) + "}"
        result = {"content": [{"type": "text", "text": text}], "isError": False}
    else:
        raise RuntimeError("Unexpected fixture method")
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
