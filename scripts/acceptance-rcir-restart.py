#!/usr/bin/env python3
"""Frozen real-process crash boundary, not universal restricted-agent acceptance.

A genuine acquired A2A task writes a disposable effect. SIGKILL arrives before
RIGHTCLICK observes completion. Restart must retain safe identity, report UNKNOWN
and never replay or resume the old mutation/authority. No private key is used.
"""
import argparse
import hashlib
import json
import os
import pathlib
import queue
import subprocess
import tempfile
import threading
import time
import uuid

TOOLS = {"context_runtime", "context_providers", "context_inspect", "context_actions",
         "context_explain", "context_run", "context_run_status"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    binary, out = args.binary.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path(__file__).resolve().parent
    transcript, processes = [], []
    report = {"binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "harnessSHA256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
              "status": "RED", "scope": "Real A2A process + native MCP crash/restart, synthetic disposable effect"}
    with tempfile.TemporaryDirectory(prefix="rightclick-journal-proof-") as temporary:
        tmp = pathlib.Path(temporary).resolve()
        try:
            agent = subprocess.Popen(["python3", str(root / "a2a-proof-agent.py"), str(tmp), "--hold-until-file"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(agent)
            deadline = time.monotonic() + 10
            while not (tmp / "port").exists():
                if time.monotonic() >= deadline: raise TimeoutError("provider startup")
                time.sleep(.01)
            base = "http://127.0.0.1:" + (tmp / "port").read_text()
            providers = tmp / "providers.json"
            providers.write_text(json.dumps({"version": 1, "agentCards": [base + "/.well-known/agent.json"]}))
            providers.chmod(0o600)
            journal = tmp / "journal"
            journal.mkdir(mode=0o700)
            env = {k: v for k, v in os.environ.items() if not k.startswith("RIGHTCLICK_")}
            env.update(HOME=str(tmp), USERPROFILE=str(tmp), LOCALAPPDATA=str(tmp), XDG_STATE_HOME=str(tmp),
                       RIGHTCLICK_A2A_PROVIDERS=str(providers), RIGHTCLICK_EXPERIENCE="off",
                       RIGHTCLICK_INVOCATION_JOURNAL=str(journal))

            class Runtime:
                def __init__(self, label):
                    self.label, self.sequence = label, 0
                    self.errors = (out / (label + ".stderr")).open("w")
                    self.process = subprocess.Popen([str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=self.errors, text=True, bufsize=1, env=env)
                    processes.append(self.process)
                    self.replies = queue.Queue()
                    def reader():
                        for line in self.process.stdout: self.replies.put(json.loads(line))
                        self.replies.put(None)
                    threading.Thread(target=reader, daemon=True).start()
                    self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                        "clientInfo": {"name": "rcir-crash-acceptance", "version": "1"}})
                    assert {tool["name"] for tool in self.request("tools/list", {})["tools"]} == TOOLS
                def request(self, method, params):
                    self.sequence += 1
                    query = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
                    self.process.stdin.write(json.dumps(query) + "\n"); self.process.stdin.flush()
                    while True:
                        response = self.replies.get(timeout=40)
                        assert response is not None, "MCP ended before reply"
                        if response.get("id") == self.sequence: break
                    transcript.append({"runtime": self.label, "request": query, "response": response})
                    assert "error" not in response, response
                    return response["result"]
                def call(self, name, arguments):
                    result = self.request("tools/call", {"name": name, "arguments": arguments})
                    assert not result.get("isError"), result
                    return json.loads(result["content"][0]["text"])
                def crash(self):
                    self.process.kill(); self.process.wait(timeout=10)
                    self.errors.close()

            original = Runtime("before-crash")
            report["beforeRuntime"] = original.call("context_runtime", {})
            assert report["beforeRuntime"]["executableSHA256"] == report["binarySHA256"]
            item = "Disposable journal crash proof"
            original.call("context_inspect", {"item": item})
            original.call("context_providers", {})
            capability = next(a for a in original.call("context_actions", {"item": item})["actions"] if a["id"].startswith("a2a:"))
            original.call("context_explain", {"item": item, "actionId": capability["id"]})
            challenge = uuid.uuid4().hex
            sentinel = "argument-must-not-enter-journal-" + uuid.uuid4().hex
            message = json.dumps({"challenge": challenge, "value": sentinel}, separators=(",", ":"))
            initial = original.call("context_run", {"item": item, "actionId": capability["id"], "confirmed": True,
                "arguments": {"message": message}})
            assert initial["state"] == "started" and initial["rcir"]["phase"] == "accepted", initial
            report["executionID"], report["taskID"] = initial["executionId"], initial["rcir"]["taskID"]
            (tmp / "release").write_bytes(b"")
            deadline = time.monotonic() + 10
            effect = tmp / "effects" / challenge
            while not effect.exists():
                if time.monotonic() >= deadline: raise TimeoutError("external effect")
                time.sleep(.01)
            assert effect.read_text() == message
            report["independentEffectMatched"] = True
            original.crash()
            restarted = Runtime("after-crash")
            report["afterRuntime"] = restarted.call("context_runtime", {})
            assert report["afterRuntime"]["pid"] != report["beforeRuntime"]["pid"]
            recovered = restarted.call("context_run_status", {"executionId": report["executionID"]})
            report["recoveredStatus"] = recovered
            assert recovered["state"] == "unknown" and not recovered["evidence"]["outcomeVerified"], recovered
            assert recovered["evidence"]["type"] == "rcir_recovered_journal", "restart lost durable invocation identity"
            assert report["taskID"] in json.dumps(recovered), "restart lost original task identity"
            for _ in range(3):
                again = restarted.call("context_run_status", {"executionId": report["executionID"]})
                assert again == recovered, "recovery status is not stable"
            requests = [json.loads(line) for line in (tmp / "requests.jsonl").read_text().splitlines()]
            assert len(requests) == 1, "crash/status replayed original mutation"
            assert not (tmp / "polls.jsonl").exists(), "restart restored remote polling without fresh authority"
            stored = b"".join(path.read_bytes() for path in journal.iterdir() if path.is_file())
            assert sentinel.encode() not in stored and challenge.encode() not in stored and base.encode() not in stored
            assert message.encode() not in stored, "journal retained invocation arguments"
            report.update(status="GREEN_FOR_CRASH_IDENTITY_BOUNDARY", providerMutations=1,
                          automaticRemotePolls=0, journalPayloadAbsent=True, toolCount=7, providerSpecificToolsAdded=0)
            restarted.crash()
        except Exception as error:
            report["failure"] = str(error)
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
            for name in ("requests.jsonl", "effects.jsonl", "polls.jsonl"):
                if (tmp / name).exists(): (out / name).write_bytes((tmp / name).read_bytes())
            (out / "results.json").write_text(json.dumps(report, indent=2))
            (out / "transcript.json").write_text(json.dumps(transcript, indent=2))
    print("PASS: real effect, SIGKILL, durable UNKNOWN identity, zero replay/poll, payload absent, seven operations")


if __name__ == "__main__":
    main()
