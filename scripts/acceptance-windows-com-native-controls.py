#!/usr/bin/env python3
"""Actual native transport identity/width/replay/deadline controls, not policy or eleven-world proof."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import queue
import struct
import subprocess
import threading
import time
import uuid

spec = importlib.util.spec_from_file_location("frozen_com_controls", pathlib.Path(__file__).with_name("acceptance-windows-com.py"))
frozen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frozen)


def prepare(directory):
    frozen.prepare(directory)
    context_path = directory / "fixture-context.json"
    context = json.loads(context_path.read_text(encoding="utf-8"))
    context["narrowMember"], context["variantMember"] = "Width_" + uuid.uuid4().hex, "Variant_" + uuid.uuid4().hex
    declaration = (directory / "proof.idl").read_text(encoding="utf-8")
    declaration = declaration.replace("  };", f"      [id(42)] BSTR {context['narrowMember']}([in] long narrowed);\n"
                                            f"      [id(43)] VARIANT {context['variantMember']}([in] VARIANT untyped);\n  }};", 1)
    (directory / "proof.idl").write_text(declaration, encoding="utf-8")
    context_path.write_text(json.dumps(context, indent=2, ensure_ascii=False), encoding="utf-8")


class Probe:
    def __init__(self, executable, errors, transcript):
        self.transcript = transcript
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=errors, text=True, encoding="utf-8", bufsize=1)
        self.responses = queue.Queue()
        def reader():
            for line in self.process.stdout:
                try: self.responses.put(json.loads(line))
                except Exception as error: self.responses.put(error)
            self.responses.put(None)
        threading.Thread(target=reader, daemon=True).start()
    def command(self, *parts):
        started = time.monotonic()
        self.process.stdin.write("\t".join(map(str, parts)) + "\n"); self.process.stdin.flush()
        response = self.responses.get(timeout=8)
        assert isinstance(response, dict), "native probe ended or invalid wire"
        self.transcript.append({"command": list(parts), "response": response, "elapsed": time.monotonic() - started})
        return response


def native_args(context):
    text = context["message"].encode("utf-8")
    return (struct.pack("<IH I", 3, 8, len(text)) + text + struct.pack("<HqHB", 20, context["count"], 11, int(context["flag"]))).hex()


def run(binary, fixture, paused_fixture, probe_path, directory):
    assert os.name == "nt", "actual Windows native controls required"
    binary, fixture, paused_fixture, probe_path, directory = [p.resolve() for p in [binary, fixture, paused_fixture, probe_path, directory]]
    context = json.loads((directory / "fixture-context.json").read_text(encoding="utf-8"))
    report = {"scope": "Actual native COM transport controls + common production acquisition; not policy proof or eleven-world acceptance",
              "sourceSHA": os.environ.get("GITHUB_SHA"), "controls": {},
              "sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [binary, fixture, paused_fixture, probe_path, pathlib.Path(__file__)]}, "status": "RED"}
    transcript, providers, streams, runtime, probe = [], [], [], None, None
    def passed(name, detail=None): report["controls"][name] = {"result": "PASS", "detail": detail}
    def provider(name, moniker, executable=fixture):
        path = directory / name; path.mkdir()
        errors = (path / "stderr.log").open("w", encoding="utf-8"); streams.append(errors)
        process = subprocess.Popen([str(executable), "serve", str(path), str(directory / "proof.tlb"),
            "{" + context["interfaceGUID"] + "}", moniker], stdout=subprocess.DEVNULL, stderr=errors)
        providers.append((process, path)); frozen.wait_for(path / "ready.json")
        return path, json.loads((path / "ready.json").read_text(encoding="utf-8"))["moniker"]
    def catalog(moniker):
        response = probe.command("catalog"); assert response["status"] == 0, response
        return [e for e in response["catalog"] if e["moniker"] == moniker]
    def effect_count(path): return (path / "effect-count").read_text() if (path / "effect-count").exists() else "0"
    try:
        initial, moniker = provider("initial", context["moniker"])
        errors = (directory / "probe.stderr.log").open("w", encoding="utf-8"); streams.append(errors)
        probe = Probe(probe_path, errors, transcript)
        entry = catalog(moniker)[0]; old = entry["acquisitionID"]
        (directory / "native-bridge-catalog.json").write_text(json.dumps(entry, indent=2), encoding="utf-8")
        members = entry["declaration"]["members"]
        assert next(m for m in members if m["id"] == 42)["parameters"][0]["type"] == 3
        assert next(m for m in members if m["id"] == 43)["parameters"][0]["type"] == 12
        passed("actual_dynamic_unsupported_native_declarations_observed")
        narrow = probe.command("prepare", old, 42, struct.pack("<IHi", 1, 3, 1).hex())
        variant = probe.command("prepare", old, 43, struct.pack("<IH", 1, 12).hex())
        assert narrow["status"] == 2 and variant["status"] == 2 and effect_count(initial) == "0"
        passed("unsupported_native_types_rejected_before_enqueue_zero_effects")
        environment = {k: v for k, v in os.environ.items() if not k.startswith("RIGHTCLICK_")}
        errors = (directory / "runtime.stderr.log").open("w", encoding="utf-8"); streams.append(errors)
        runtime = frozen.Runtime(binary, errors, environment, transcript)
        actions = runtime.call("context_actions", {"item": "Native closed type controls"})["actions"]
        titles = {a["title"] for a in actions}
        assert context["member"] in titles and context["narrowMember"] not in titles and context["variantMember"] not in titles
        passed("common_compiler_omits_unsupported_native_members_preserves_supported")
        call = probe.command("prepare", old, 41, native_args(context)); assert call["status"] == 0, call
        (initial / "withdraw").write_bytes(b""); frozen.wait_for(initial / "withdrawn")
        replacement, replacement_moniker = provider("replacement", context["moniker"])
        assert replacement_moniker == moniker
        # Deliberately no absence/catalog query before enqueue: the final native
        # worker check must reject a different canonical object with same metadata.
        queued = probe.command("enqueue", call["call"])
        result = probe.command("wait", call["call"]) if queued["status"] == 0 else queued
        assert result["status"] != 0 and effect_count(initial) == effect_count(replacement) == "0"
        passed("retained_prepared_call_rejects_same_metadata_native_replacement_zero_effects", {"enqueue": queued["status"], "result": result["status"]})
        new = catalog(moniker)[0]["acquisitionID"]
        assert new != old and probe.command("validate", old)["status"] != 0
        passed("old_acquisition_never_revives_after_observed_replacement")
        current = probe.command("prepare", new, 41, native_args(context)); assert current["status"] == 0
        assert probe.command("enqueue", current["call"])["status"] == 0
        assert probe.command("wait", current["call"])["status"] == 0
        assert effect_count(replacement) == "1"
        assert probe.command("enqueue", current["call"])["status"] != 0 and effect_count(replacement) == "1"
        passed("native_enqueue_is_one_shot_no_replay")
        duplicate, _ = provider("duplicate", context["moniker"])
        peer, peer_moniker = provider("peer", context["moniker"] + ".peer", paused_fixture)
        assert catalog(moniker) == [] and probe.command("validate", new)["status"] != 0
        peer_id = catalog(peer_moniker)[0]["acquisitionID"]
        assert probe.command("validate", peer_id)["status"] == 0
        passed("equal_duplicate_monikers_fail_closed_other_provider_remains_available")
        peer_call = probe.command("prepare", peer_id, 41, native_args(context)); assert peer_call["status"] == 0
        (peer / "pause").write_bytes(b""); frozen.wait_for(peer / "paused")
        assert probe.command("enqueue", peer_call["call"])["status"] == 0
        started = time.monotonic(); timeout = probe.command("wait", peer_call["call"]); elapsed = time.monotonic() - started
        assert timeout["status"] == 3 and elapsed < 5
        started = time.monotonic(); assert probe.command("validate", peer_id)["status"] == 3
        assert time.monotonic() - started < .75
        started = time.monotonic(); assert probe.command("close")["status"] == 0
        assert time.monotonic() - started < .75
        passed("real_pending_native_rpc_deadline_quarantine_no_retry_bounded_close", {"elapsed": elapsed, "status": timeout["status"]})
        frozen.wait_for(peer / "unpaused", timeout=15)
        time.sleep(.1); assert effect_count(peer) == "0"
        passed("late_rpc_return_cannot_start_invocation_after_quarantine")
        report["status"] = "PASS_NATIVE_ENGINEERING_CONTROLS"
    except Exception as error:
        report["failure"] = str(error); raise
    finally:
        if runtime and runtime.process.poll() is None: runtime.process.terminate(); runtime.process.wait(timeout=5)
        if probe and probe.process.poll() is None: probe.process.terminate(); probe.process.wait(timeout=5)
        # These disposable providers share one randomized type library to isolate
        # canonical object replacement from metadata drift. Terminate earlier
        # instances; the final instance unregisters their single per-user entry.
        for process, path in providers[:-1]:
            if process.poll() is None: process.terminate(); process.wait(timeout=5)
        if providers:
            process, path = providers[-1]; (path / "stop").write_bytes(b"")
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=5)
        for stream in streams: stream.close()
        (directory / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        (directory / "transcript.json").write_text(json.dumps(transcript, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", type=pathlib.Path)
    for name in ["binary", "fixture", "paused-fixture", "probe", "directory"]: parser.add_argument("--" + name, type=pathlib.Path)
    options = parser.parse_args()
    if options.prepare: prepare(options.prepare)
    else: run(options.binary, options.fixture, options.paused_fixture, options.probe, options.directory)
