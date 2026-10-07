#!/usr/bin/env python3
"""Seven-operation public A2A proof with separate agent/observer processes.

This is repeatable engineering acceptance, not the fresh AI eleven-substrate run.
Private signer material stays disposable and outside the committed evidence.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import selectors
import subprocess
import tempfile
import time
import uuid
from fixture_startup import FixtureProcesses

TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    binary, out = args.binary.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path(__file__).resolve().parent
    transcript, processes, report = [], [], {"runKind": "NEW_RUN", "controls": {}}
    report["binary"] = str(binary)
    report["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="rightclick-a2a-acceptance-") as temporary, FixtureProcesses(out / "fixture-startup.json") as fixtures:
        tmp = pathlib.Path(temporary)
        def launch(script):
            label, marker = ("agent", "port") if script == "a2a-proof-agent.py" else ("observer", "observer-port")
            p = fixtures.launch(label, root / script, [str(tmp)] + (["--hold-until-file"] if label == "agent" else []), tmp / marker)
            processes.append(p)
            return p
        def port(filename):
            return fixtures.wait_for_port("agent" if filename == "port" else "observer", timeout=10)
        agent = launch("a2a-proof-agent.py")
        launch("a2a-proof-observer.py")
        base = "http://127.0.0.1:" + port("port")
        observer = "http://127.0.0.1:" + port("observer-port")
        providers, config = tmp / "providers.json", tmp / "host.json"
        providers.write_text(json.dumps({"version": 1, "agentCards": [base + "/.well-known/agent.json"]}))
        providers.chmod(0o600)
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(tmp / "key.pem")], check=True, stdout=subprocess.DEVNULL)
        private = subprocess.check_output(["openssl", "pkey", "-in", str(tmp / "key.pem"), "-outform", "DER"])
        (tmp / "key.raw").write_bytes(private[-32:]); (tmp / "key.raw").chmod(0o600)
        trusted = subprocess.check_output(["openssl", "pkey", "-in", str(tmp / "key.pem"), "-pubout", "-outform", "DER"])
        (out / "trusted-public-key.raw").write_bytes(trusted[-32:])
        (tmp / "trusted.der").write_bytes(trusted)
        settings = {"version": 1, "revision": "a2a-acceptance-1", "deniedCapabilities": [], "signingKeyFile": str(tmp / "key.raw")}
        def save_config():
            config.write_text(json.dumps(settings)); config.chmod(0o600)
        save_config()
        stderr = (out / "mcp.stderr.log").open("w")
        process = subprocess.Popen([str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr, text=True, bufsize=1,
            env=dict(os.environ, RIGHTCLICK_A2A_PROVIDERS=str(providers), RIGHTCLICK_RCIR_CONFIG=str(config)))
        processes.append(process)
        def request(method, params=None):
            identity = len(transcript) + 1
            query = {"jsonrpc": "2.0", "id": identity, "method": method}
            if params is not None: query["params"] = params
            process.stdin.write(json.dumps(query) + "\n"); process.stdin.flush()
            selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
            try:
                deadline = time.monotonic() + 40
                while time.monotonic() < deadline:
                    if selector.select(max(0, deadline - time.monotonic())):
                        raw = process.stdout.readline()
                        if not raw: raise RuntimeError("MCP ended")
                        response = json.loads(raw)
                        if response.get("id") == identity:
                            transcript.append({"request": query, "response": response})
                            assert "error" not in response, response
                            return response["result"]
                raise TimeoutError("MCP response")
            finally: selector.close()
        def call(name, arguments):
            result = request("tools/call", {"name": name, "arguments": arguments})
            assert not result.get("isError"), result
            return json.loads(result["content"][0]["text"])
        def verify(record, label):
            envelope = record["rcir"]["signedReceipt"]
            assert base64.b64decode(envelope["publicKey"], validate=True) == trusted[-32:]
            (out / (label + "-receipt.json")).write_text(json.dumps(envelope, indent=2))
            payload, signature = base64.b64decode(envelope["payload"], validate=True), base64.b64decode(envelope["signature"], validate=True)
            (tmp / "receipt.raw").write_bytes(payload); (tmp / "signature.raw").write_bytes(signature)
            check = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(tmp / "trusted.der"),
                "-keyform", "DER", "-rawin", "-in", str(tmp / "receipt.raw"), "-sigfile", str(tmp / "signature.raw")],
                capture_output=True, text=True)
            assert check.returncode == 0, check.stderr
            report["controls"][label + "Signature"] = "PASS — independently pinned OpenSSL Ed25519"
        try:
            request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "rightclick-a2a-acceptance", "version": "1"}})
            tools_before = request("tools/list")["tools"]
            assert {tool["name"] for tool in tools_before} == TOOLS
            report["runtime"] = call("context_runtime", {})
            assert report["runtime"]["executableSHA256"] == report["binarySHA256"]
            item = "Disposable delegated A2A proof"
            call("context_inspect", {"item": item})
            providers_before = call("context_providers", {})
            actions = call("context_actions", {"item": item})["actions"]
            capability = next(a for a in actions if a["id"].startswith("a2a:"))
            call("context_explain", {"item": item, "actionId": capability["id"]})
            settings["observers"] = {capability["id"]: {"urlTemplate": observer + "/observations/{message}",
                "expectedArgument": "message", "trustedOrigin": observer}}
            save_config()
            def invoke(value, confirmed=True):
                challenge = uuid.uuid4().hex
                message = json.dumps({"challenge": challenge, "value": value}, sort_keys=True, separators=(",", ":"))
                result = call("context_run", {"item": item, "actionId": capability["id"], "confirmed": confirmed,
                    "arguments": {"message": message}})
                return result, challenge, message
            gated, _, _ = invoke("confirmation-control", False)
            assert gated["state"] == "awaiting_user"
            report["controls"]["confirmationDenial"] = "PASS — zero delegated requests"
            initial, challenge, message = invoke("hello from RIGHTCLICK")
            assert initial["state"] == "started" and initial["rcir"]["phase"] == "accepted"
            assert "receipt" not in initial["rcir"] and not (tmp / "effects" / challenge).exists()
            pending = call("context_run_status", {"executionId": initial["executionId"]})
            assert pending["state"] == "started" and not pending["evidence"]["outcomeVerified"]
            report["controls"]["acceptedIsNotVerified"] = "PASS — pending task, no effect, no terminal receipt"
            (tmp / "release").write_bytes(b"")
            def finish(start):
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    result = call("context_run_status", {"executionId": start["executionId"]})
                    if result["state"] not in ("started", "awaiting_user"): return result
                    time.sleep(.03)
                raise TimeoutError("remote task lifecycle")
            success = finish(initial)
            assert success["state"] == "succeeded" and success["rcir"]["outcome"] == "succeeded"
            assert (tmp / "effects" / challenge).read_text() == message
            assert success["evidence"]["outcomeVerified"]
            verify(success, "success")
            report["controls"]["independentEffect"] = "PASS — separate observer process/origin reads exact nonce-bound bytes"
            mismatch, _, _ = invoke("mismatch-effect"); mismatch = finish(mismatch)
            assert mismatch["state"] == "failed" and mismatch["rcir"]["outcome"] == "failed"
            verify(mismatch, "mismatch")
            missing, _, _ = invoke("missing-effect"); missing = finish(missing)
            assert missing["state"] == "accepted" and missing["rcir"]["outcome"] == "unverified"
            verify(missing, "missing")
            settings["deniedCapabilities"] = [capability["id"]]; save_config()
            denied, _, _ = invoke("policy-control")
            assert denied["state"] == "rejected"
            report["controls"]["policyDenial"] = "PASS — denied before provider dispatch"
            agent.terminate(); agent.wait(timeout=10)
            after = call("context_actions", {"item": item})["actions"]
            assert not any(a["id"] == capability["id"] for a in after)
            call("context_providers", {})
            tools_after = request("tools/list")["tools"]
            assert tools_after == tools_before
            report["controls"]["liveProviderRemoval"] = "PASS — A2A capability disappears; tool definitions unchanged"
            report["toolCountBefore"] = report["toolCountAfter"] = 7
            report["providerSpecificToolsAdded"] = 0
            report["scopeBoundary"] = "Local exact endpoint/message lease and confirmation policy; public A2A endpoint, no authenticated issuer downscoping claim."
            report["restrictedAgentBoundary"] = "Engineering MCP client uses only seven operations; fresh AI eleven-substrate proof remains a separate acceptance requirement."
            report["providersBefore"] = providers_before
            requests = [json.loads(line) for line in (tmp / "requests.jsonl").read_text().splitlines()]
            assert len(requests) == 3, "confirmation/policy/status must not add mutation requests"
            report["controls"]["noStatusReplay"] = "PASS — exactly three separately admitted tasks, no replay during status"
            report["status"] = "GREEN_FOR_THIS_BOUNDARY"
        finally:
            (out / "results.json").write_text(json.dumps(report, indent=2))
            (out / "transcript.json").write_text(json.dumps(transcript, indent=2))
            for filename in ("requests.jsonl", "polls.jsonl", "effects.jsonl", "observations.jsonl"):
                if (tmp / filename).exists(): (out / filename).write_bytes((tmp / filename).read_bytes())
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
                    try: p.wait(timeout=10)
                    except subprocess.TimeoutExpired: p.kill(); p.wait()
            stderr.close()
    print("PASS: seven-operation A2A lifecycle, separate effect observation, independent receipt checks, denial and live removal")


if __name__ == "__main__":
    main()
