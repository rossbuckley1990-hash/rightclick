#!/usr/bin/env python3
"""Read-only, bounded RIGHTCLICK stdio example; Python standard library only."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time

TOOLS = {"context_runtime", "context_inspect", "context_providers", "context_actions",
         "context_explain", "context_run", "context_run_status"}


def main():
    selected = os.environ.get("RIGHTCLICK_BIN", "rightclick")
    executable = Path(shutil.which(selected) or selected).resolve(strict=True)
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    with tempfile.TemporaryFile(mode="w+t") as errors:
        process = subprocess.Popen([str(executable), "mcp"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors,
                                   text=True, bufsize=1)
        sequence = 0

        def rpc(method, params=None):
            nonlocal sequence
            sequence += 1
            message = {"jsonrpc": "2.0", "id": sequence, "method": method}
            if params is not None:
                message["params"] = params
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
            deadline = time.monotonic() + 30
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while time.monotonic() < deadline:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        break
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError("RIGHTCLICK exited before replying")
                    result = json.loads(line)
                    if result.get("id") != sequence:
                        continue
                    if "error" in result:
                        raise RuntimeError("MCP request rejected: " + method)
                    return result["result"]
            raise TimeoutError("Bounded MCP deadline: " + method)

        def call(name, arguments):
            result = rpc("tools/call", {"name": name, "arguments": arguments})
            if result.get("isError"):
                raise RuntimeError("Tool rejected: " + name)
            return json.loads(result["content"][0]["text"])

        try:
            rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                               "clientInfo": {"name": "rightclick-example", "version": "1"}})
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            process.stdin.flush()
            declarations = rpc("tools/list")["tools"]
            assert len(declarations) == 7 and {x["name"] for x in declarations} == TOOLS
            runtime = call("context_runtime", {})
            assert runtime["executableSHA256"] == digest
            assert Path(runtime["executableRealPath"]).resolve() == executable
            assert runtime["transport"] == "stdio"
            item = "RightClick capability discovery example"
            inspected = call("context_inspect", {"item": item})
            actions = call("context_actions", {"item": item})["actions"]
            selected_id = actions[0]["id"] if actions else None
            if selected_id:
                explained = call("context_explain", {"item": item, "actionId": selected_id})
                assert explained["id"] == selected_id
            print(json.dumps({"toolCount": len(declarations), "version": runtime["version"],
                              "executableSHA256": digest, "itemKind": inspected["kind"],
                              "discoveredCount": len(actions), "explainedDiscoveredID": selected_id,
                              "invokedCapabilities": 0}, indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
