#!/usr/bin/env python3
"""Frozen native COM metadata/effect/withdrawal boundary, not eleven-world proof.

Windows SDK MIDL produces new randomized member names; a native out-of-process
IDispatch provider publishes them through ROT/ITypeInfo. Production RIGHTCLICK
must discover, compile and invoke without containing the provider's catalogue.
The infrastructure owner independently reads the disposable effect bytes.
"""
import argparse
import hashlib
import json
import os
import pathlib
import queue
import struct
import subprocess
import threading
import time
import uuid

TOOLS = {"context_runtime", "context_providers", "context_inspect", "context_actions",
         "context_explain", "context_run", "context_run_status"}


def prepare(directory):
    directory.mkdir(parents=True, exist_ok=True)
    identity = {"libraryGUID": str(uuid.uuid4()), "interfaceGUID": str(uuid.uuid4()),
                "classGUID": str(uuid.uuid4()), "member": "Commit_" + uuid.uuid4().hex,
                "moniker": "rightclick.native.test." + uuid.uuid4().hex,
                "message": "native-" + uuid.uuid4().hex + " café\u0000世界\n",
                "count": 9007199254740993, "flag": False}
    declaration = f'''import "oaidl.idl";
import "ocidl.idl";
[uuid({identity['libraryGUID']}), version(1.0)]
library DisposableNativeLibrary {{
  importlib("stdole2.tlb");
  [uuid({identity['interfaceGUID']})]
  dispinterface DisposableNativeInterface {{
    properties:
    methods:
      [id(41)] BSTR {identity['member']}([in] BSTR message, [in] hyper count, [in] VARIANT_BOOL flag);
  }};
  [uuid({identity['classGUID']})]
  coclass DisposableNativeClass {{ [default] dispinterface DisposableNativeInterface; }};
}};
'''
    (directory / "proof.idl").write_text(declaration, encoding="utf-8")
    (directory / "fixture-context.json").write_text(json.dumps(identity, ensure_ascii=False, indent=2), encoding="utf-8")


class Runtime:
    def __init__(self, binary, errors, environment, transcript):
        self.sequence, self.transcript = 0, transcript
        self.process = subprocess.Popen([str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=errors, text=True, encoding="utf-8", bufsize=1, env=environment)
        self.replies = queue.Queue()
        def read():
            for line in self.process.stdout:
                try: self.replies.put(json.loads(line))
                except Exception as error: self.replies.put(error)
            self.replies.put(None)
        threading.Thread(target=read, daemon=True).start()
        self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "frozen-native-windows-com-proof", "version": "1"}})

    def request(self, method, params, allow_error=False):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n"); self.process.stdin.flush()
        while True:
            response = self.replies.get(timeout=40)
            assert isinstance(response, dict), "runtime ended or emitted invalid JSON"
            if response.get("id") == self.sequence: break
        self.transcript.append({"request": request, "response": response})
        if "error" in response and allow_error: return {"protocolError": response["error"]}
        assert "error" not in response, response
        return response["result"]

    def call(self, name, arguments, allow_error=False):
        result = self.request("tools/call", {"name": name, "arguments": arguments}, allow_error=allow_error)
        if allow_error and "protocolError" in result: return result
        if allow_error and result.get("isError"): return {"toolError": result["content"]}
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])


def wait_for(path, timeout=15):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline: raise TimeoutError("native fixture readiness")
        time.sleep(.02)


def run(binary, fixture, directory):
    assert os.name == "nt", "native Windows is required; fixtures on another host cannot pass"
    binary, fixture, directory = binary.resolve(), fixture.resolve(), directory.resolve()
    context = json.loads((directory / "fixture-context.json").read_text(encoding="utf-8"))
    report = {"scope": "Native Windows COM disposable provider + production seven-operation transport; not eleven-world restricted-agent acceptance",
              "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "fixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
              "harnessSHA256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
              "controls": {name: {"result": "NOT_RUN", "detail": None} for name in [
                  "native_dynamic_metadata_oracle", "exactly_seven_operations", "production_dynamic_native_acquisition",
                  "confirmation_required_zero_native_effects", "typed_schema_mismatch_zero_native_effects",
                  "typed_native_invoke_separately_observed_effect", "acceptance_not_semantic_success",
                  "common_execution_identity_status", "live_rot_withdrawal_removes_capability", "stale_native_identity_zero_effects"]},
              "status": "RED"}
    transcript, processes = [], []
    control = lambda name, passed, detail=None: report["controls"].update({name: {"result": "PASS" if passed else "FAIL", "detail": detail}})
    try:
        with (directory / "fixture.stderr.log").open("w", encoding="utf-8") as errors:
            provider = subprocess.Popen([str(fixture), "serve", str(directory), str(directory / "proof.tlb"),
                "{" + context["interfaceGUID"] + "}", context["moniker"]], stdout=subprocess.DEVNULL, stderr=errors)
            processes.append(provider); wait_for(directory / "ready.json")
            moniker = json.loads((directory / "ready.json").read_text(encoding="utf-8"))["moniker"]
            oracle = subprocess.run([str(fixture), "inspect", moniker], capture_output=True, encoding="utf-8", timeout=20, check=True)
            metadata = json.loads(oracle.stdout); (directory / "native-metadata-oracle.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
            member = next(m for m in metadata["members"] if m["names"][0] == context["member"])
            assert member["parameterTypes"] == [8, 20, 11] and member["returnType"] == 8 and member["kind"] == 1
            control("native_dynamic_metadata_oracle", True)
            environment = {k: v for k, v in os.environ.items() if not k.startswith("RIGHTCLICK_")}
            environment["RIGHTCLICK_EXPERIENCE"] = "off"
            with (directory / "runtime.stderr.log").open("w", encoding="utf-8") as errors:
                runtime = Runtime(binary, errors, environment, transcript); processes.append(runtime.process)
                catalogue = runtime.request("tools/list", {})
                control("exactly_seven_operations", {t["name"] for t in catalogue["tools"]} == TOOLS)
                report["runtime"] = runtime.call("context_runtime", {})
                assert report["runtime"]["platform"] == "Windows" and report["runtime"]["executableSHA256"] == report["binarySHA256"]
                item = "Disposable native metadata capability proof"
                runtime.call("context_inspect", {"item": item}); runtime.call("context_providers", {})
                actions = runtime.call("context_actions", {"item": item})["actions"]
                native = [a for a in actions if a.get("metadata", {}).get("interfaceKind") == "windows.com" and a["title"] == context["member"]]
                control("production_dynamic_native_acquisition", len(native) == 1, {"nativeMatches": len(native)})
                assert len(native) == 1, "production runtime does not acquire the native type-information declaration"
                action = native[0]; args = {"message": context["message"], "count": json.dumps(["integer", str(context["count"])]),
                                         "flag": json.dumps(["boolean", context["flag"]])}
                runtime.call("context_explain", {"item": item, "actionId": action["id"]})
                denied = runtime.call("context_run", {"item": item, "actionId": action["id"], "confirmed": False, "arguments": args})
                control("confirmation_required_zero_native_effects", denied["state"] in ["rejected", "awaiting_user"] and not (directory / "effect-count").exists(), denied["state"])
                malformed = dict(args); malformed["count"] = json.dumps(["number", "3ff0000000000000"])
                invalid = runtime.call("context_run", {"item": item, "actionId": action["id"], "confirmed": True, "arguments": malformed}, allow_error=True)
                rejected = invalid.get("state") in ["rejected", "failed"] or "toolError" in invalid or "protocolError" in invalid
                control("typed_schema_mismatch_zero_native_effects", rejected and not (directory / "effect-count").exists(), invalid)
                accepted = runtime.call("context_run", {"item": item, "actionId": action["id"], "confirmed": True, "arguments": args})
                report["execution"] = accepted; wait_for(directory / "effect-count")
                data = (directory / "effect-1.bin").read_bytes(); length = struct.unpack_from("<I", data)[0]
                message = data[4:4+length].decode("utf-8"); count = struct.unpack_from("<q", data, 4+length)[0]; flag = data[12+length]
                exact = len(data) == length+13 and message == context["message"] and count == context["count"] and flag == 0
                control("typed_native_invoke_separately_observed_effect", exact and (directory / "effect-count").read_text() == "1", {"byteCount": len(data), "effectSHA256": hashlib.sha256(data).hexdigest()})
                control("acceptance_not_semantic_success", accepted["state"] == "accepted" and not accepted["evidence"]["outcomeVerified"])
                status = runtime.call("context_run_status", {"executionId": accepted["executionId"]})
                control("common_execution_identity_status", status["executionId"] == accepted["executionId"] and status.get("rcir", {}).get("leaseConsumed") is True)
                (directory / "withdraw").write_bytes(b""); wait_for(directory / "withdrawn")
                after = runtime.call("context_actions", {"item": item})["actions"]
                control("live_rot_withdrawal_removes_capability", not any(a["id"] == action["id"] for a in after))
                stale = runtime.call("context_run", {"item": item, "actionId": action["id"], "confirmed": True, "arguments": args})
                control("stale_native_identity_zero_effects", stale["state"] in ["unavailable", "rejected"] and (directory / "effect-count").read_text() == "1", stale["state"])
                report["status"] = "GREEN_FOR_NATIVE_COM_BOUNDARY" if all(c["result"] == "PASS" for c in report["controls"].values()) else "RED"
                assert report["status"] == "GREEN_FOR_NATIVE_COM_BOUNDARY", report["controls"]
    except Exception as error:
        report["failure"] = str(error); raise
    finally:
        (directory / "stop").write_bytes(b"")
        for process in reversed(processes):
            if process.poll() is None:
                if process is processes[0]:
                    try: process.wait(timeout=5); continue
                    except subprocess.TimeoutExpired: pass
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        (directory / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        (directory / "transcript.json").write_text(json.dumps(transcript, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", type=pathlib.Path)
    parser.add_argument("--binary", type=pathlib.Path); parser.add_argument("--fixture", type=pathlib.Path)
    parser.add_argument("--directory", type=pathlib.Path)
    options = parser.parse_args()
    if options.prepare: prepare(options.prepare)
    else: run(options.binary, options.fixture, options.directory)
