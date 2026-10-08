#!/usr/bin/env python3
"""Actual MCP HTTP and isolated-process portable bilateral acceptance.

The optional proof executable is explicit test composition, not normal startup.
All identities, credentials and counter effects are disposable. Two processes on
one host prove process/network isolation, not a cross-machine deployment.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}
RECEIPT_PREFIX = b"RIGHTCLICK-RCIR-RECEIPT-1\0"
MAX_RESPONSE = 1_500_000


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def protected(path: Path, value: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(value)


class MCP:
    def __init__(self, listener: int, token: str, evidence: Path):
        self.url = f"http://127.0.0.1:{listener}/mcp"
        self.token = token
        self.sequence = 0
        self.evidence = evidence
        self.transcript = []

    def request(self, method: str, params=None, *, authenticated=True):
        self.sequence += 1
        query = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}}
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if authenticated:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.url, data=json.dumps(query).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read(MAX_RESPONSE + 1)
        assert len(raw) <= MAX_RESPONSE, "MCP reply exceeded acceptance bound"
        reply = json.loads(raw)
        self.transcript.append({"request": query, "response": reply})
        save(self.evidence, self.transcript)
        assert reply.get("id") == query["id"] and "error" not in reply, reply
        return reply["result"]

    def call(self, name: str, arguments=None):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        assert not result.get("isError"), result
        content = result["content"]
        assert content and content[0].get("type") == "text", result
        return json.loads(content[0]["text"])

    def initialize(self):
        self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "portable-bilateral-acceptance", "version": "1"}})
        names = [tool["name"] for tool in self.request("tools/list")["tools"]]
        assert len(names) == 7 and set(names) == TOOLS, names
        try:
            self.request("tools/list", authenticated=False)
            raise AssertionError("Loopback MCP credential was bypassed")
        except urllib.error.HTTPError as error:
            assert error.code == 401, error
        runtime = self.call("context_runtime")
        assert runtime["transport"] == "http", runtime
        return runtime


class Processes:
    def __init__(self, executable: Path, output: Path):
        self.executable, self.output = executable, output
        self.running = []
        self.inventory = []

    def launch(self, role: str, arguments: list[str], environment: dict, listener: int):
        out = (self.output / f"{role}.stdout.log").open("w")
        err = (self.output / f"{role}.stderr.log").open("w")
        process = subprocess.Popen([str(self.executable)] + arguments, env=environment, stdout=out, stderr=err)
        self.running.append((process, out, err))
        self.inventory.append({"role": role, "pid": process.pid, "arguments": arguments,
            "listener": {"host": "127.0.0.1", "port": listener}})
        save(self.output / "processes.json", self.inventory)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            assert process.poll() is None, f"{role} exited {process.returncode}; see its stderr log"
            try:
                with socket.create_connection(("127.0.0.1", listener), timeout=.2):
                    return process
            except OSError:
                time.sleep(.05)
        raise TimeoutError(f"{role} did not establish its loopback listener")

    def stop(self):
        for process, out, err in reversed(self.running):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            out.close(); err.close()
        self.running.clear()


def identity(executable: Path, key: Path, environment: dict) -> dict:
    result = subprocess.run([str(executable), "identity", "--key", str(key)], env=environment,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True)
    row = json.loads(result.stdout)
    public = base64.b64decode(row["publicKey"], validate=True)
    assert len(public) == 32
    digest = hashlib.sha256(public).hexdigest()
    assert row["runtimeID"] == "runtime:" + digest and row["deviceID"] == "device:" + digest
    return row


def broker_negative_checks(listener: int, target_runtime: str) -> dict:
    """Independent socket clients cannot forge routing completion or displace a host."""
    fake_result = json.dumps({"kind": "result", "routeID": str(uuid.uuid4()).upper(),
        "runtimeID": target_runtime}, sort_keys=True, separators=(",", ":")).encode()
    duplicate_registration = json.dumps({"kind": "register", "routeID": str(uuid.uuid4()).upper(),
        "runtimeID": target_runtime}, sort_keys=True, separators=(",", ":")).encode()
    unknown_field = json.dumps({"kind": "register", "routeID": str(uuid.uuid4()).upper(),
        "runtimeID": "fixture:untrusted", "confirmed": True}, sort_keys=True, separators=(",", ":")).encode()
    attacks = {
        "zeroLength": struct.pack(">I", 0),
        "oversizedLength": struct.pack(">I", 131_073),
        "unknownField": struct.pack(">I", len(unknown_field)) + unknown_field,
        "forgedRoutingResult": struct.pack(">I", len(fake_result)) + fake_result,
        "duplicateHostRegistration": struct.pack(">I", len(duplicate_registration)) + duplicate_registration,
    }
    for name, packet in attacks.items():
        with socket.create_connection(("127.0.0.1", listener), timeout=3) as attacker:
            attacker.sendall(packet)
            try:
                assert attacker.recv(1) == b"", f"Broker accepted {name}"
            except ConnectionResetError:
                pass
    with socket.create_connection(("127.0.0.1", listener), timeout=3):
        pass
    return {name: "REJECTED" for name in attacks} | {"listenerRemainsAvailable": True}


def receipt_check(record: dict, pinned_public: dict, temporary: Path, openssl: str) -> dict:
    evidence = record["rcir"]
    assert evidence["leaseConsumed"] is True
    envelope = evidence["signedReceipt"]
    assert envelope["version"] == 1 and envelope["algorithm"] == "Ed25519"
    trusted = base64.b64decode(pinned_public["publicKey"], validate=True)
    assert base64.b64decode(envelope["publicKey"], validate=True) == trusted, "Receipt did not match independently provisioned pin"
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    assert payload.startswith(RECEIPT_PREFIX) and len(signature) == 64
    assert base64.b64decode(evidence["receipt"], validate=True) == payload
    public_path, payload_path, signature_path = [temporary / ("verify-" + UUID + name)
        for UUID, name in [(uuid.uuid4().hex, ".der"), (uuid.uuid4().hex, ".payload"), (uuid.uuid4().hex, ".signature")]]
    protected(public_path, bytes.fromhex("302a300506032b6570032100") + trusted)
    protected(payload_path, payload)
    protected(signature_path, signature)
    command = [openssl, "pkeyutl", "-verify", "-pubin", "-inkey", str(public_path),
        "-keyform", "DER", "-rawin", "-in", str(payload_path), "-sigfile", str(signature_path)]
    verified = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    assert verified.returncode == 0, "Independent Ed25519 receipt verification failed"
    signature_path.write_bytes(bytes([signature[0] ^ 1]) + signature[1:])
    tampered = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    assert tampered.returncode != 0, "Tampered receipt signature was accepted"
    return {"signature": "VALID", "algorithm": "Ed25519", "pinnedKeyMatched": True,
        "payloadBytes": len(payload), "tamperedSignatureRejected": True,
        "semanticClaim": "UNVERIFIED_PROVIDER_COMPLETION"}


def exercise(client: MCP, *, remote: bool, effect_path: Path, secret: str) -> dict:
    runtime = client.initialize()
    item = "portable proof"
    assert client.call("context_inspect", {"item": item})["kind"] == "text"
    actions = client.call("context_actions", {"item": item})["actions"]
    action = next(action for action in actions if action["title"] == "Portable deferred acceptance fixture")
    assert action["id"].startswith("remote:") is remote, action
    assert client.call("context_explain", {"item": item, "actionId": action["id"]})["id"] == action["id"]
    client.call("context_providers")
    started = time.monotonic()
    initial = client.call("context_run", {"item": item, "actionId": action["id"]})
    initial_seconds = time.monotonic() - started
    assert initial["state"] == "started", initial
    execution = initial["executionId"]
    first = client.call("context_run_status", {"executionId": execution, "cursor": 0, "limit": 1, "maximumBytes": 16_384})
    assert first.get("lifecycle", {}).get("terminal") is False, first
    statuses = [first]
    observed_working = first["lifecycle"]["phase"] == "working"
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        status = client.call("context_run_status", {"executionId": execution, "cursor": 0, "maximumBytes": 16_384})
        statuses.append(status)
        if status["lifecycle"]["phase"] == "working":
            observed_working = True
        if status["lifecycle"]["terminal"]:
            terminal = status
            break
        time.sleep(.05)
    else:
        raise TimeoutError("Live execution did not terminalize")
    assert observed_working, "MCP wire did not observe a working phase before completion"
    assert terminal["lifecycle"]["phase"] == "completed" and terminal["lifecycle"]["terminal"] is True, terminal
    assert terminal["state"] == "accepted" and terminal["lifecycle"]["semanticOutcome"] == "unverified", terminal
    assert terminal["lifecycle"]["verification"] == "UNVERIFIED", terminal
    assert terminal["evidence"]["outcomeVerified"] is False, terminal
    assert terminal["result"] == ["integer", "7"], terminal
    assert terminal["lifecycle"]["receiptAvailable"] and terminal["lifecycle"]["signedReceiptAvailable"], terminal
    terminal_page = client.call("context_run_status", {"executionId": execution, "cursor": 0, "limit": 1, "maximumBytes": 16_384})
    assert terminal_page["rcirEventPage"]["terminal"] is True and terminal_page["rcirEventPage"]["hasMore"] is True
    assert terminal_page["rcirEventPage"]["nextCursor"] == 1
    rest = client.call("context_run_status", {"executionId": execution, "cursor": 1, "maximumBytes": 16_384})
    events = terminal_page["rcirEventPage"]["events"] + rest["rcirEventPage"]["events"]
    assert [event["sequence"] for event in events] == [1, 2, 3], events
    assert [event["kind"] for event in events] == ["accepted", "working", "completed"], events
    assert events[-1]["value"] == ["integer", "7"], events
    again = client.call("context_run_status", {"executionId": execution, "cursor": 0, "maximumBytes": 16_384})
    assert again["lifecycle"] == terminal["lifecycle"] and again["result"] == terminal["result"], again
    assert int(effect_path.read_text()) == 1, "Observed more than one provider dispatch"
    assert secret not in json.dumps(client.transcript), "Execution-node fixture credential escaped through MCP"
    if remote:
        assert "rcir" not in terminal, "Raw RCIR receipt must remain on the execution node"
        assert terminal["lifecycle"]["runtimeID"].startswith("runtime:")
    return {"runtime": runtime, "action": action, "initial": initial, "firstStatus": first,
        "terminalStatus": terminal, "statusSamples": len(statuses), "observedWorking": observed_working,
        "initialResponseSeconds": initial_seconds, "effectCount": 1,
        "sevenOperations": True, "loopbackAuthenticationRequired": True,
        "typedTerminalResult": ["integer", "7"], "credentialSentinelAbsent": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "local", "distributed"], default="all")
    parser.add_argument("--openssl", default=shutil.which("openssl"))
    args = parser.parse_args()
    binary, output = args.executable.resolve(), args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    assert binary.is_file() and args.openssl, "Proof executable and OpenSSL are required"
    repository = Path(__file__).resolve().parent.parent
    metadata = {"binary": str(binary), "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "hostOS": platform.system(), "hostArchitecture": platform.machine(),
        "gitHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
        "gitStatus": subprocess.check_output(["git", "status", "--short"], cwd=repository, text=True).splitlines(),
        "deploymentScope": "Isolated processes and encrypted outbound loopback transport on one actual host; no cross-machine claim"}
    save(output / "provenance.json", metadata)
    processes = Processes(binary, output)
    summary = {"status": "RUNNING", "provenance": metadata, "proofs": {}}
    try:
        # Keep the protected journal under the supplied workspace. Foundation on
        # macOS preserves different system aliases than pathlib.resolve(); a
        # workspace path avoids aliases without relaxing journal validation.
        with tempfile.TemporaryDirectory(prefix="rightclick-bilateral-proof-", dir=output.parent) as temporary_name:
            temporary = Path(temporary_name).resolve()
            base = {key: value for key, value in os.environ.items() if not key.startswith("RIGHTCLICK_")}
            base.update(RIGHTCLICK_EXPERIENCE="off", XDG_CONFIG_HOME=str(temporary), XDG_STATE_HOME=str(temporary), CFFIXED_USER_HOME=str(temporary))
            keys = {}
            for role in ["local", "caller", "target"]:
                keys[role] = temporary / (role + ".key")
                protected(keys[role], os.urandom(32))
            pins = {role: identity(binary, key, base) for role, key in keys.items()}
            save(output / "public-identities.json", pins)
            token = uuid.uuid4().hex + uuid.uuid4().hex
            secret = "TEST-ONLY-EXECUTION-NODE-CREDENTIAL-" + uuid.uuid4().hex
            def host_environment(role):
                config = temporary / (role + ".json")
                protected(config, json.dumps({"version": 1, "revision": "bilateral-proof-1",
                    "deniedCapabilities": [], "signingKeyFile": str(keys[role])}).encode())
                return dict(base, RIGHTCLICK_MCP_TOKEN=token, RIGHTCLICK_RCIR_CONFIG=str(config), RIGHTCLICK_FABRIC_PROOF_SECRET=secret)
            if args.mode in ["all", "local"]:
                listener, effects = port(), temporary / "local-effects.txt"
                processes.launch("local", ["local", "--key", str(keys["local"]), "--mcp-port", str(listener), "--effects", str(effects)], host_environment("local"), listener)
                client = MCP(listener, token, output / "local-mcp-wire.json")
                result = exercise(client, remote=False, effect_path=effects, secret=secret)
                result["receiptVerification"] = receipt_check(result["terminalStatus"], pins["local"], temporary, args.openssl)
                summary["proofs"]["localMCPHTTP"] = result
                save(output / "local-proof.json", result)
                print("PASS local actual MCP HTTP: live -> working -> immutable terminal; typed result integer7; independently pinned Ed25519 receipt; effects=1", flush=True)
                processes.stop()
            if args.mode in ["all", "distributed"]:
                broker_port, target_port, caller_port = port(), port(), port()
                effects = temporary / "target-effects.txt"
                processes.launch("broker", ["broker", "--port", str(broker_port)], base, broker_port)
                processes.launch("target", ["target", "--key", str(keys["target"]), "--mcp-port", str(target_port),
                    "--broker-port", str(broker_port), "--caller-public-key", pins["caller"]["publicKey"],
                    "--ledger", str(temporary / "target-journal"), "--effects", str(effects)], host_environment("target"), target_port)
                network_negatives = broker_negative_checks(broker_port, pins["target"]["runtimeID"])
                save(output / "broker-negative-proof.json", network_negatives)
                processes.launch("caller", ["caller", "--key", str(keys["caller"]), "--mcp-port", str(caller_port),
                    "--broker-port", str(broker_port), "--target-public-key", pins["target"]["publicKey"]],
                    dict(base, RIGHTCLICK_MCP_TOKEN=token), caller_port)
                caller = MCP(caller_port, token, output / "distributed-mcp-wire.json")
                result = exercise(caller, remote=True, effect_path=effects, secret=secret)
                result["brokerNegatives"] = network_negatives
                remote_lifecycle = result["terminalStatus"]["lifecycle"]
                assert remote_lifecycle["runtimeID"] == pins["target"]["runtimeID"]
                target = MCP(target_port, token, output / "execution-node-mcp-wire.json")
                target.initialize()
                record = target.call("context_run_status", {"executionId": remote_lifecycle["executionID"]})
                assert record["lifecycle"]["taskID"] == remote_lifecycle["taskID"]
                result["receiptVerification"] = receipt_check(record, pins["target"], temporary, args.openssl)
                result["targetReceiptRetainedLocally"] = True
                save(output / "execution-node-terminal-evidence.json", record)
                summary["proofs"]["distributedActualProcesses"] = result
                save(output / "distributed-proof.json", result)
                print("PASS two actual isolated RIGHTCLICK runtimes + outbound encrypted broker: discovery/routing, live -> working -> terminal, node pin, typed integer7, target credential retained, effects=1", flush=True)
            summary["status"] = "PASS"
            summary["limitations"] = ["Actual proof processes run on one host; cross-machine deployment is not demonstrated.",
                "Provider completion remains semantically unverified; cryptographic authentication does not prove an external postcondition.",
                "Repeated status observation effects=1 is demonstrated here; consequential same-intent retries require the separate Link duplicate/reconnect proof."]
            return 0
    except Exception as error:
        summary["status"] = "FAIL"
        summary["failure"] = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        processes.stop()
        save(output / "summary.json", summary)


if __name__ == "__main__":
    raise SystemExit(main())
