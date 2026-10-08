#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

EXPECTED = {
    "context_runtime",
    "context_inspect",
    "context_actions",
    "context_explain",
    "context_run",
    "context_run_status",
    "context_providers",
}

class MCP:
    def __init__(self, exe):
        self.p = subprocess.Popen(
            [str(exe)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 1

    def send(self, method, params=None, notify=False):
        obj = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            obj["params"] = params
        if not notify:
            obj["id"] = self.next_id
            self.next_id += 1
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        line = self.p.stdout.readline()
        if not line:
            err = self.p.stderr.read()
            raise RuntimeError(f"RIGHTCLICK closed stdout while waiting for {method}: {err}")
        msg = json.loads(line)
        if "error" in msg:
            raise RuntimeError(f"{method} failed: {msg['error']}")
        return msg["result"]

    def tool(self, name, arguments):
        return self.send("tools/call", {"name": name, "arguments": arguments})

def tool_text(result):
    for part in result.get("content", []):
        if part.get("type") == "text":
            return part.get("text", "")
    return ""

def parse_tool_json(result):
    text = tool_text(result)
    try:
        return json.loads(text)
    except Exception:
        return {"raw": text}

def main():
    exe = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/rightclick")
    if not exe.exists():
        raise SystemExit(f"RIGHTCLICK executable not found: {exe}")

    mcp = MCP(exe)
    init = mcp.send("initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "clodfarm-rightclick-experiment", "version": "0.1"},
    })
    print("INITIALIZE", json.dumps(init, sort_keys=True))
    mcp.send("notifications/initialized", notify=True)

    listed = mcp.send("tools/list", {})
    names = {t["name"] for t in listed.get("tools", [])}
    print("TOOLS", json.dumps(sorted(names)))
    if names != EXPECTED:
        raise SystemExit(f"Expected exactly seven RIGHTCLICK tools, got: {sorted(names)}")

    runtime = parse_tool_json(mcp.tool("context_runtime", {}))
    print("RUNTIME", json.dumps(runtime, sort_keys=True))

    providers = parse_tool_json(mcp.tool("context_providers", {}))
    print("PROVIDERS", json.dumps(providers, sort_keys=True))

    actions_doc = parse_tool_json(mcp.tool("context_actions", {"item": "RIGHTCLICK Clodfarm interoperability probe"}))
    actions = actions_doc.get("actions", [])
    print("ACTION_COUNT", len(actions))

    if not actions:
        print("NO_APPLICABLE_ACTIONS")
        return 0

    harmless = None
    for a in actions:
        safety = a.get("safety", "")
        if safety not in {"external_share", "destructive", "security_change", "code_execution"}:
            harmless = a
            break
    if harmless is None:
        harmless = actions[0]

    print("SELECTED_ACTION", json.dumps({
        "id": harmless.get("id"),
        "title": harmless.get("title"),
        "safety": harmless.get("safety"),
        "requiresConfirmation": harmless.get("requiresConfirmation"),
    }, sort_keys=True))

    explain = parse_tool_json(mcp.tool("context_explain", {
        "actionId": harmless["id"],
        "item": "RIGHTCLICK Clodfarm interoperability probe",
    }))
    print("EXPLAIN", json.dumps(explain, sort_keys=True))

    run = parse_tool_json(mcp.tool("context_run", {
        "actionId": harmless["id"],
        "item": "RIGHTCLICK Clodfarm interoperability probe",
        "confirmed": True,
    }))
    print("RUN", json.dumps(run, sort_keys=True))

    execution_id = run.get("executionId")
    if execution_id:
        status = parse_tool_json(mcp.tool("context_run_status", {"executionId": execution_id}))
        print("STATUS", json.dumps(status, sort_keys=True))

    state = run.get("state")
    allowed = {"started", "awaiting_user", "unsupported", "unavailable", "rejected", "accepted", "succeeded", "failed", "cancelled", "unknown"}
    if state not in allowed:
        raise SystemExit(f"Unexpected RIGHTCLICK run state: {state}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
