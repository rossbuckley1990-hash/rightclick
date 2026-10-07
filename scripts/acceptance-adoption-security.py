#!/usr/bin/env python3
"""Independent blackbox adoption checks against supplied built bytes.

Uses an isolated HOME and a local stdio MCP child. Does not claim installed AI
client connectivity, native capability outcomes, portable release, or a deploy.
"""
from __future__ import annotations

if not __debug__:
    raise SystemExit("Acceptance requires Python assertions enabled; optimized mode is unsupported.")

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import unquote, urlparse

CORE7 = {
    "context_runtime", "context_inspect", "context_actions", "context_explain",
    "context_run", "context_run_status", "context_providers",
}


class MCPChild:
    def __init__(self, binary: Path, environment: dict[str, str], arguments: list[str] | None = None):
        self.process = subprocess.Popen(
            [str(binary)] + (arguments or ["mcp"]), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=environment, bufsize=1,
        )
        self.messages: queue.Queue[str | None] = queue.Queue()
        self.stderr: list[str] = []
        self.transcript: list[dict] = []
        self.next_id = 0

        def read_stdout():
            for line in self.process.stdout:
                self.messages.put(line)
            self.messages.put(None)

        def read_stderr():
            for line in self.process.stderr:
                # Retain a bounded diagnostic; never collect unlimited output.
                if sum(map(len, self.stderr)) < 262144:
                    self.stderr.append(line)

        threading.Thread(target=read_stdout, daemon=True).start()
        threading.Thread(target=read_stderr, daemon=True).start()

    def request(self, method: str, params: dict | None = None) -> dict:
        self.next_id += 1
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method,
                   "params": params or {}}
        self.transcript.append({"direction": "request", "message": request})
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 12
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"MCP response timed out for {method}")
            line = self.messages.get(timeout=remaining)
            if line is None:
                raise RuntimeError(f"MCP child exited before {method} response")
            if len(line) > 4 * 1024 * 1024:
                raise RuntimeError("MCP response exceeds acceptance size bound")
            response = json.loads(line)
            self.transcript.append({"direction": "response", "message": response})
            if response.get("id") == request["id"]:
                if "error" in response:
                    raise RuntimeError(f"MCP rejected {method}: {response['error']}")
                return response["result"]

    def initialize(self):
        self.request("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "independent-adoption-security", "version": "1"},
        })
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.process.stdin.flush()

    def runtime(self) -> dict:
        return self.tool("context_runtime", {})

    def tool(self, name: str, arguments: dict) -> dict:
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(f"{name} returned an error")
        return json.loads(next(item["text"] for item in result["content"] if item["type"] == "text"))

    def close(self):
        if self.process.poll() is None:
            # EOF permits the server to finish and disposable fixtures to clean
            # up. Forced termination remains a final bounded fallback.
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)


def file_snapshot(root: Path) -> dict[str, str]:
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob("*") if path.is_file() and not path.is_symlink()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--symlink-retarget", action="store_true",
                        help="Also challenge identity when launch symlink changes after MCP initialization")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    args.evidence.mkdir(parents=True, exist_ok=True)
    cases: list[dict] = []

    def check(name, body):
        try:
            details = body()
            cases.append({"case": name, "passed": True, "details": details})
        except Exception as error:
            cases.append({"case": name, "passed": False, "error": str(error)})

    temporary_parent = "/private/tmp" if sys.platform == "darwin" else str(Path(tempfile.gettempdir()).resolve())
    with tempfile.TemporaryDirectory(prefix="rightclick-adoption-security-", dir=temporary_parent) as directory:
        home = Path(directory).resolve()
        (home / "tmp").mkdir(mode=0o700)
        environment = {key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}
        environment.update({"PATH": os.defpath, "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                            "USERPROFILE": str(home),
                            "LOCALAPPDATA": str(home / "AppData/Local"),
                            "XDG_STATE_HOME": str(home / ".local/state"),
                            "XDG_CONFIG_HOME": str(home / ".config"),
                            "TMPDIR": str(home / "tmp"), "TMP": str(home / "tmp"), "TEMP": str(home / "tmp")})

        def live_runtime():
            child = MCPChild(binary, environment)
            try:
                child.initialize()
                tools = child.request("tools/list")["tools"]
                names = [tool["name"] for tool in tools]
                assert len(names) == 7 and set(names) == CORE7, names
                runtime = child.runtime()
                assert runtime["pid"] == child.process.pid, runtime
                assert runtime["transport"] == "stdio", runtime
                assert runtime["executableSHA256"] == digest, runtime
                assert Path(runtime["executableRealPath"]).resolve() == binary, runtime
                assert runtime.get("agentABIProfiles"), "Missing ABI profile attestation"
                (args.evidence / "core7-live-transcript.json").write_text(json.dumps(child.transcript, indent=2) + "\n")
                return {"pid": child.process.pid, "runtime": runtime, "tools": names}
            finally:
                child.close()

        check("live Core7 catalogue and executable/PID identity", live_runtime)

        help_result = subprocess.run([str(binary), "--help"], env=environment,
                                     capture_output=True, text=True, timeout=15)
        adoption_available = "rightclick connect" in (help_result.stdout + help_result.stderr)
        cases.append({"case": "connect adoption command available", "passed": adoption_available})
        if adoption_available:
            hits: list[bool] = []

            class RejectionTrap(http.server.BaseHTTPRequestHandler):
                def log_message(self, *unused):
                    pass

                def do_GET(self):
                    hits.append(True)
                    self.send_error(400)

                def do_POST(self):
                    hits.append(True)
                    self.send_error(400)

            trap = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RejectionTrap)
            threading.Thread(target=trap.serve_forever, daemon=True).start()
            port = trap.server_address[1]
            for label, target, token in [
                ("URL userinfo", f"http://user:adoption-secret-7a9@127.0.0.1:{port}/openapi.json", "adoption-secret-7a9"),
                ("URL query", f"http://127.0.0.1:{port}/openapi.json?token=adoption-secret-3c8", "adoption-secret-3c8"),
                ("URL fragment", f"http://127.0.0.1:{port}/openapi.json#token=adoption-secret-5d1", "adoption-secret-5d1"),
            ]:
                def rejected_source(target=target, token=token):
                    before = file_snapshot(home)
                    request_count = len(hits)
                    started = time.monotonic()
                    result = subprocess.run([str(binary), "connect", target, "--json"], env=environment,
                                            capture_output=True, text=True, timeout=10)
                    assert result.returncode != 0, "Credential-bearing source was accepted"
                    assert token not in result.stdout + result.stderr, "Credential echoed in diagnostic"
                    assert len(hits) == request_count, "Credential-bearing target reached the network before rejection"
                    assert file_snapshot(home) == before, "Rejected source changed persisted configuration"
                    return {"exitCode": result.returncode, "elapsedSeconds": round(time.monotonic() - started, 3)}
                check(f"reject {label} without persistence or secret echo", rejected_source)
            trap.shutdown()
            trap.server_close()

        sandbox_available = "rightclick sandbox" in (help_result.stdout + help_result.stderr)
        cases.append({"case": "sandbox adoption command available", "passed": sandbox_available})
        if sandbox_available:
            def sandbox_core7():
                # A real host configuration must not be imported by this fixture.
                host_config = home / "unrelated-host-policy.json"
                host_config.write_text(json.dumps({"version": 1, "revision": "unrelated-host-only",
                    "deniedCapabilities": ["sandbox:fixture:record_challenge"],
                    "signingKeyFile": str(home / "unrelated-host-key")}) + "\n")
                host_config.chmod(0o600)
                sandbox_environment = dict(environment, RIGHTCLICK_RCIR_CONFIG=str(host_config))
                child = MCPChild(binary, sandbox_environment, ["sandbox", "--mcp"])
                fixture_directory: Path | None = None
                try:
                    child.initialize()
                    names = [tool["name"] for tool in child.request("tools/list")["tools"]]
                    assert len(names) == 7 and set(names) == CORE7, names
                    runtime = child.runtime()
                    assert runtime["pid"] == child.process.pid and runtime["executableSHA256"] == digest
                    challenge = "independent_sandbox_challenge"
                    assert child.tool("context_inspect", {"item": challenge})["kind"] == "text"
                    providers = child.tool("context_providers", {})
                    assert len(providers) == 1 and providers[0]["name"] == "Disposable provider fixture", providers
                    actions = child.tool("context_actions", {"item": challenge})["actions"]
                    assert len(actions) == 1 and actions[0]["id"] == "sandbox:fixture:record_challenge", actions
                    explanation = child.tool("context_explain", {"item": challenge, "actionId": actions[0]["id"]})
                    source = urlparse(explanation["metadata"]["descriptorSource"])
                    assert source.scheme == "file", source
                    fixture_directory = Path(unquote(source.path))
                    assert fixture_directory.name.startswith("rightclick-sandbox-") and fixture_directory.is_dir()
                    assert not list(fixture_directory.iterdir())
                    arguments = {"item": challenge, "actionId": actions[0]["id"], "arguments": {"challenge": challenge}}
                    denied = child.tool("context_run", arguments)
                    assert denied["state"] == "awaiting_user", denied
                    assert not list(fixture_directory.iterdir()), "Unconfirmed request caused an effect"
                    traversal = child.request("tools/call", {"name": "context_run", "arguments": {
                        **arguments, "confirmed": True, "arguments": {"challenge": "../outside"}}})
                    assert traversal.get("isError") or json.loads(traversal["content"][0]["text"])["state"] == "rejected"
                    assert not list(fixture_directory.iterdir()), "Schema-invalid challenge caused an effect"
                    executed = child.tool("context_run", {**arguments, "confirmed": True})
                    assert executed["state"] == "succeeded" and executed["evidence"]["outcomeVerified"], executed
                    assert not executed["rcir"].get("signedReceipt"), "Fixture imported host production signing trust"
                    status = child.tool("context_run_status", {"executionId": executed["executionId"]})
                    assert status["state"] == "succeeded" and status["rcir"]["taskID"] == executed["rcir"]["taskID"]
                    effects = list(fixture_directory.iterdir())
                    assert len(effects) == 1
                    effect = json.loads(effects[0].read_text())
                    assert effect == {"challenge": challenge, "taskID": executed["rcir"]["taskID"]}, effect
                    if os.name != "nt":
                        assert fixture_directory.stat().st_mode & 0o077 == 0
                        assert effects[0].stat().st_mode & 0o077 == 0
                    (args.evidence / "sandbox-core7-transcript.json").write_text(json.dumps(child.transcript, indent=2) + "\n")
                finally:
                    child.close()
                assert fixture_directory is not None and not fixture_directory.exists(), "Graceful sandbox EOF left fixture state"
                return {"tools": names, "pid": runtime["pid"], "hostConfigIgnored": True,
                        "confirmationRequired": True, "traversalRejected": True,
                        "readbackBoundToInvocation": True, "gracefulCleanup": True}
            check("real sandbox Core7, independent effect readback and graceful cleanup", sandbox_core7)

        if args.symlink_retarget:
            def changed_launch_alias():
                if os.name == "nt":
                    raise RuntimeError("Symlink identity challenge requires a POSIX host")
                launch = home / "launch-rightclick"
                launch.symlink_to(binary)
                child = MCPChild(launch, environment)
                try:
                    child.initialize()
                    initial = child.runtime()
                    launch.unlink()
                    launch.symlink_to(Path("/bin/echo"))
                    after = child.runtime()
                    assert after["pid"] == child.process.pid
                    assert initial["executableSHA256"] == digest
                    assert after["executableSHA256"] == digest, "Launch alias changed process executable identity"
                    assert Path(after["executableRealPath"]).resolve() == binary, "Runtime attested replacement target as loaded image"
                    return {"before": initial, "after": after}
                finally:
                    child.close()
            check("live identity survives retargeted launch symlink", changed_launch_alias)

    report = {"scope": "Local built executable blackbox security acceptance; no installed client or portable release attestation",
              "binary": str(binary), "binarySHA256": digest,
              "passed": sum(case["passed"] for case in cases),
              "failed": sum(not case["passed"] for case in cases), "cases": cases}
    (args.evidence / "acceptance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("scope", "binarySHA256", "passed", "failed", "cases")}, indent=2))
    return 1 if report["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
