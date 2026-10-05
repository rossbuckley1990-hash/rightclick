#!/usr/bin/env python3
"""Minimal stdio MCP client for RIGHTCLICK. Stdlib only."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any


def main() -> int:
    binary = os.environ.get("RIGHTCLICK_BIN", "rightclick")
    proc = subprocess.Popen(
        [binary, "mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert proc.stdin and proc.stdout

    next_id = 1

    def rpc(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        nonlocal next_id
        msg: dict[str, Any] = {"jsonrpc": "2.0", "id": next_id, "method": method}
        next_id += 1
        if params is not None:
            msg["params"] = params
        line = json.dumps(msg)
        proc.stdin.write(line + "\n")
        proc.stdin.flush()
        while True:
            raw = proc.stdout.readline()
            if not raw:
                err = proc.stderr.read() if proc.stderr else ""
                raise RuntimeError(f"server closed; stderr={err!r}")
            raw = raw.strip()
            if not raw:
                continue
            data = json.loads(raw)
            if data.get("id") == msg["id"]:
                if "error" in data:
                    raise RuntimeError(data["error"])
                return data["result"]

    def notify(method: str, params: dict[str, Any] | None = None) -> None:
        msg: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    try:
        init = rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "rightclick-example", "version": "0.1.0"},
            },
        )
        print("server:", init.get("serverInfo"))
        notify("notifications/initialized")

        tools = rpc("tools/list")
        names = [t["name"] for t in tools.get("tools", [])]
        print("tools:", ", ".join(names))

        item = "RightClick third party capability test"
        actions = rpc("tools/call", {"name": "context_actions", "arguments": {"item": item}})
        print("context_actions result keys:", sorted(actions.keys()) if isinstance(actions, dict) else type(actions))

        # Content is often MCP content blocks; print truncated JSON
        print(json.dumps(actions, indent=2)[:1200], "...\n")

        # Optional explain of a known BBEdit id when present in the environment
        explain_id = "service:com.barebones.bbedit:openSelectionService"
        try:
            explained = rpc(
                "tools/call",
                {"name": "context_explain", "arguments": {"item": item, "actionId": explain_id}},
            )
            print("explain:", json.dumps(explained, indent=2)[:800], "...\n")
        except Exception as exc:  # noqa: BLE001
            print("explain skipped:", exc)

        # Confirmed run is intentionally NOT executed here.
        print(
            "example confirmed run payload (NOT sent):\n",
            json.dumps(
                {
                    "name": "context_run",
                    "arguments": {
                        "item": item,
                        "actionId": explain_id,
                        "confirmed": True,
                    },
                },
                indent=2,
            ),
        )
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
