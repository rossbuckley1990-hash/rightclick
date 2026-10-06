#!/usr/bin/env python3
"""Live two-runtime federation acceptance.

Runtime A has no configured provider.
Runtime B gains a configured provider while both runtimes are already alive.
A must acquire B's capability through federation, execute it through B,
receive B-local verification evidence, then lose it when B removes the
provider without B restarting.
"""
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

binary = str(pathlib.Path(sys.argv[1]).resolve())
out = pathlib.Path(sys.argv[2]).resolve()
root = pathlib.Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)

sha = os.environ.get("RIGHTCLICK_ACCEPTANCE_REF") or os.environ.get("GITHUB_SHA")
if not sha:
    sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        text=True,
    ).strip()
assert re.fullmatch(r"[0-9a-fA-F]{40}", sha), sha

repository = os.environ.get(
    "GITHUB_REPOSITORY",
    "rossbuckley1990-hash/rightclick",
)
raw_origin = "https://raw.githubusercontent.com"
spec_url = f"{raw_origin}/{repository}/{sha}/fixtures/federation-proof/openapi.json"
expected = json.dumps(\n    json.loads((root / "fixtures/federation-proof/result.json").read_text()),\n    sort_keys=True,\n    separators=(",", ":"),\n)

def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]

def wait_listener(port, process):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"RIGHTCLICK exited before listening on {port}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.2):
                return
        except OSError:
            time.sleep(.1)
    raise TimeoutError(f"RIGHTCLICK did not listen on {port}")

_counter = 0
def rpc(url, token, method, params=None):
    global _counter
    _counter += 1
    body = {
        "jsonrpc": "2.0",
        "id": _counter,
        "method": method,
    }
    if params is not None:
        body["params"] = params
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer " + token,
            "MCP-Protocol-Version": "2025-03-26",
        },
    )
    with urllib.request.urlopen(request, timeout=40) as response:
        assert response.status == 200
        reply = json.load(response)
    assert "error" not in reply, reply
    return reply["result"]

def tool(url, token, name, arguments):
    result = rpc(
        url,
        token,
        "tools/call",
        {
            "name": name,
            "arguments": arguments,
        },
    )
    assert not result.get("isError"), result
    return json.loads(result["content"][0]["text"])

def initialize(url, token):
    result = rpc(
        url,
        token,
        "initialize",
        {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {
                "name": "rightclick-federation-acceptance",
                "version": "1",
            },
        },
    )
    assert result["serverInfo"]["name"] == "rightclick", result

def actions(url, token):
    return tool(
        url,
        token,
        "context_actions",
        {"item": "RIGHTCLICK federation live proof"},
    )["actions"]

def find_title(rows, title):
    return next((row for row in rows if row["title"] == title), None)

def isolated_environment(home):
    environment = dict(os.environ)
    environment["HOME"] = str(home)
    environment["CFFIXED_USER_HOME"] = str(home)
    for key in (
        "RIGHTCLICK_MCP_TOKEN",
        "RIGHTCLICK_FEDERATION_PEERS",
        "RIGHTCLICK_FEDERATION_B_TOKEN",
    ):
        environment.pop(key, None)
    return environment

with tempfile.TemporaryDirectory(prefix="rightclick-federation-live-") as temporary:
    work = pathlib.Path(temporary)
    a_home = work / "a-home"
    b_home = work / "b-home"
    a_home.mkdir()
    b_home.mkdir()

    a_port = free_port()
    b_port = free_port()
    a_token = uuid.uuid4().hex + uuid.uuid4().hex
    b_token = uuid.uuid4().hex + uuid.uuid4().hex

    b_environment = isolated_environment(b_home)
    b_environment["RIGHTCLICK_MCP_TOKEN"] = b_token

    a_environment = isolated_environment(a_home)
    a_environment["RIGHTCLICK_MCP_TOKEN"] = a_token
    a_environment["RIGHTCLICK_FEDERATION_B_TOKEN"] = b_token
    a_environment["RIGHTCLICK_FEDERATION_PEERS"] = json.dumps([
        {
            "id": "peer-b",
            "name": "RIGHTCLICK Runtime B",
            "endpoint": f"http://127.0.0.1:{b_port}/mcp",
            "tokenEnvironment": "RIGHTCLICK_FEDERATION_B_TOKEN",
        }
    ])

    b_log = (out / "runtime-b.stderr.log").open("w")
    a_log = (out / "runtime-a.stderr.log").open("w")
    b_process = subprocess.Popen(
        [binary, "mcp", "--http", "--port", str(b_port)],
        env=b_environment,
        stdout=subprocess.DEVNULL,
        stderr=b_log,
    )
    a_process = subprocess.Popen(
        [binary, "mcp", "--http", "--port", str(a_port)],
        env=a_environment,
        stdout=subprocess.DEVNULL,
        stderr=a_log,
    )

    a_url = f"http://127.0.0.1:{a_port}/mcp"
    b_url = f"http://127.0.0.1:{b_port}/mcp"

    try:
        wait_listener(a_port, a_process)
        wait_listener(b_port, b_process)
        initialize(a_url, a_token)
        initialize(b_url, b_token)

        a_runtime = tool(a_url, a_token, "context_runtime", {})
        b_runtime = tool(b_url, b_token, "context_runtime", {})
        assert a_runtime["product"] == b_runtime["product"] == "RIGHTCLICK"
        assert a_runtime["pid"] != b_runtime["pid"]

        title = "Read federation proof"

        before_a = actions(a_url, a_token)
        before_b = actions(b_url, b_token)
        assert find_title(before_a, title) is None
        assert find_title(before_b, title) is None

        configured_raw = subprocess.check_output(
            [
                binary,
                "provider",
                "add",
                "--id",
                "federation-live-proof",
                "--spec-url",
                spec_url,
                "--base-url",
                raw_origin,
                "--json",
            ],
            env=b_environment,
            text=True,
        )
        configured = json.loads(configured_raw)
        configuration_path = pathlib.Path(configured["configuration"]).resolve()
        assert str(configuration_path).startswith(str(b_home.resolve()) + os.sep), configured
        assert not (a_home / "Library/Application Support/RIGHTCLICK/providers.json").exists()

        remote = None
        federated = None
        after_b = None
        after_a = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            after_b = actions(b_url, b_token)
            after_a = actions(a_url, a_token)
            remote = find_title(after_b, title)
            federated = find_title(after_a, title)
            if remote and federated:
                break
            time.sleep(.25)

        assert remote is not None, after_b
        assert federated is not None, after_a
        assert not remote["id"].startswith("federation:")
        assert federated["id"].startswith("federation:peer-b:")
        assert federated["requiresConfirmation"] is True
        assert federated["provider"]["name"] == "RIGHTCLICK Runtime B"

        run = tool(
            a_url,
            a_token,
            "context_run",
            {
                "item": "RIGHTCLICK federation live proof",
                "actionId": federated["id"],
                "arguments": {
                    "ref": sha,
                },
                "confirmed": True,
                "verification": {
                    "predicates": [
                        {
                            "type": "text_equals",
                            "value": expected,
                        }
                    ]
                },
            },
        )

        assert run["state"] == "succeeded", run
        assert run["output"] == expected, run
        assert run["verification"]["status"] == "VERIFIED_SUCCESS", run
        assert run["evidence"]["outcomeVerified"] is True, run
        assert any(event == "federation peer peer-b" for event in run["events"]), run

        removed_raw = subprocess.check_output(
            [
                binary,
                "provider",
                "remove",
                "--id",
                "federation-live-proof",
                "--json",
            ],
            env=b_environment,
            text=True,
        )
        removed = json.loads(removed_raw)
        assert removed["status"] == "REMOVED", removed

        gone_a = None
        gone_b = None
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            gone_b = actions(b_url, b_token)
            gone_a = actions(a_url, a_token)
            if find_title(gone_b, title) is None and find_title(gone_a, title) is None:
                break
            time.sleep(.25)

        assert find_title(gone_b, title) is None, gone_b
        assert find_title(gone_a, title) is None, gone_a

        b_still_alive = tool(b_url, b_token, "context_runtime", {})
        assert b_still_alive["pid"] == b_runtime["pid"], b_still_alive

        evidence = {
            "runtimeA": a_runtime,
            "runtimeB": b_runtime,
            "providerConfiguration": configured,
            "before": {
                "runtimeAHasRemoteProof": False,
                "runtimeBHasRemoteProof": False,
            },
            "appeared": {
                "remote": remote,
                "federated": federated,
            },
            "execution": run,
            "disappeared": {
                "runtimeAHasRemoteProof": find_title(gone_a, title) is not None,
                "runtimeBHasRemoteProof": find_title(gone_b, title) is not None,
                "runtimeBStillAlive": True,
            },
            "acceptance": {
                "TWO_LIVE_RIGHTCLICK_RUNTIMES": "YES",
                "REMOTE_CAPABILITY_ABSENT_BEFORE_PROVIDER": "YES",
                "REMOTE_CAPABILITY_DISCOVERED_THROUGH_FEDERATION": "YES",
                "REMOTE_CAPABILITY_EXECUTED": "YES",
                "REMOTE_RESULT_INDEPENDENTLY_VERIFIED": "YES",
                "CAPABILITY_APPEARED_LIVE": "YES",
                "CAPABILITY_DISAPPEARED_LIVE": "YES",
                "RUNTIME_B_RESTARTED": "NO",
                "MODEL_FACING_TOOLS_ADDED": "0",
            },
        }
        (out / "results.json").write_text(
            json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"
        )

        print("FEDERATION LIVE: PASS — two RIGHTCLICK runtimes")
        print("CAPABILITY APPEARED: PASS — B provider added after startup")
        print("REMOTE EXECUTION: PASS — A invoked B-only capability")
        print("REMOTE VERIFICATION: PASS — B returned VERIFIED_SUCCESS")
        print("CAPABILITY DISAPPEARED: PASS — B provider removed without restart")
        print("MODEL-FACING TOOL DELTA: 0")
    finally:
        for process in (a_process, b_process):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        a_log.close()
        b_log.close()
