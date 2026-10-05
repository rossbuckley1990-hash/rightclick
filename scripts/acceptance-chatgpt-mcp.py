#!/usr/bin/env python3

import json
import pathlib
import selectors
import subprocess
import sys
import time

binary = str(pathlib.Path(sys.argv[1]).resolve())

expected_tools = {
    "context_inspect",
    "context_actions",
    "context_explain",
    "context_run",
    "context_run_status",
    "context_providers",
}

modern_meta = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {
        "name": "chatgpt-acceptance",
        "version": "1",
    },
    "io.modelcontextprotocol/clientCapabilities": {},
}


def request(process, message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    deadline = time.monotonic() + 30

    try:
        while time.monotonic() < deadline:
            remaining = max(0, deadline - time.monotonic())

            if not selector.select(remaining):
                continue

            line = process.stdout.readline()

            if not line:
                raise RuntimeError("RIGHTCLICK stdio ended unexpectedly")

            response = json.loads(line)

            if response.get("id") == message.get("id"):
                return response

        raise TimeoutError(
            f"Timed out waiting for response to {message['method']}"
        )
    finally:
        selector.close()


process = subprocess.Popen(
    [binary, "mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

try:
    discover = request(
        process,
        {
            "jsonrpc": "2.0",
            "id": "openai-mcp-discover",
            "method": "server/discover",
            "params": {
                "_meta": modern_meta,
            },
        },
    )

    assert "error" not in discover, discover

    discovery = discover["result"]

    assert discovery["resultType"] == "complete", discovery
    assert "2026-07-28" in discovery["supportedVersions"], discovery
    assert "tools" in discovery["capabilities"], discovery

    tools = request(
        process,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {
                "_meta": modern_meta,
            },
        },
    )

    assert "error" not in tools, tools

    tool_result = tools["result"]

    assert tool_result["resultType"] == "complete", tool_result
    assert tool_result["ttlMs"] == 0, tool_result
    assert tool_result["cacheScope"] == "private", tool_result

    names = {
        tool["name"]
        for tool in tool_result["tools"]
    }

    assert names == expected_tools, names

    inspected = request(
        process,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "_meta": modern_meta,
                "name": "context_inspect",
                "arguments": {
                    "item": "RightClick",
                },
            },
        },
    )

    assert "error" not in inspected, inspected

    inspect_result = inspected["result"]

    assert inspect_result["resultType"] == "complete", inspect_result
    assert not inspect_result.get("isError"), inspect_result

    payload = json.loads(
        inspect_result["content"][0]["text"]
    )

    assert payload["kind"] == "text", payload
    assert payload["typeIdentifier"] == "public.plain-text", payload
    assert payload["text"] == "RightClick", payload

    print(
        "CHATGPT MODERN MCP: PASS — "
        "server/discover + six tools + "
        "MCP 2026-07-28 result semantics + live context_inspect"
    )

finally:
    process.terminate()

    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
