#!/usr/bin/env python3
"""Native D-Bus + private Unix principals through RIGHTCLICK's seven Core tools."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import time
import uuid

module = importlib.util.spec_from_file_location("canonical", pathlib.Path(__file__).with_name("canonical-mcp-proof-client.py"))
canonical = importlib.util.module_from_spec(module); module.loader.exec_module(canonical)
NAME, PATH, INTERFACE = "org.rightclick.Pressure", "/org/rightclick/Pressure", "org.rightclick.Pressure"

class WriterClient(canonical.Client):
    def __init__(self, binary, output, environment):
        self.binary = pathlib.Path(binary).resolve(); self.output = pathlib.Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True); self.transcript = []
        self.stderr = (self.output / "mcp.stderr.log").open("w")
        self.process = subprocess.Popen([str(self.binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.stderr, text=True, bufsize=1, env=dict(os.environ, **environment), user=1100, group=1100, extra_groups=[])
        self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "rightclick-native-dbus-proof", "version": "1"}})
        self.tools = self.request("tools/list")["tools"]
        assert {t["name"] for t in self.tools} == canonical.TOOLS
        self.runtime = self.call("context_runtime", {})
        self.sha256 = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        assert self.runtime["executableSHA256"] == self.sha256

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path); parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--expect-red", action="store_true"); args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    report = {"runKind": "NEW_NATIVE_LINUX_DBUS_RUN", "controls": {}, "principals": {"writerUID": 1100, "observerUID": 1101, "serviceUID": 1102}}
    processes = []; client = None
    with tempfile.TemporaryDirectory(prefix="rightclick-dbus-private-") as temporary:
        root = pathlib.Path(temporary).resolve(); root.chmod(0o711)
        for name, owner, group, mode in [("state", 1102, 1101, 0o750), ("records", 1102, 1101, 0o750), ("observer-state", 1101, 1101, 0o750), ("writer-state", 1100, 1100, 0o700)]:
            target = root / name; target.mkdir(); os.chown(target, owner, group); target.chmod(mode)
        token = uuid.uuid4().hex
        for target, owner in [(root / "observer.token", 1101), (root / "writer-state" / "observer.token", 1100)]:
            target.write_text(token); os.chown(target, owner, owner); target.chmod(0o600)
        config = root / "bus.conf"
        config.write_text(f'''<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:path={root / 'bus'}</listen><auth>EXTERNAL</auth>
<policy context="default"><allow user="*"/><deny own="*"/><deny send_destination="*"/><allow receive_sender="*"/><allow send_type="method_return" send_requested_reply="true"/><allow send_type="error" send_requested_reply="true"/>
<allow send_destination="org.freedesktop.DBus"/><allow send_interface="org.freedesktop.DBus.Introspectable"/></policy>
<policy user="root"><allow own="*"/><allow send_destination="*"/></policy>
<policy user="rcservice"><allow own="{NAME}"/></policy>
<policy user="rcwriter"><allow send_destination="{NAME}" send_interface="{INTERFACE}" send_member="Store"/><allow send_destination="{NAME}" send_interface="{INTERFACE}" send_member="EchoTags"/><allow send_destination="{NAME}" send_interface="{INTERFACE}" send_member="Acknowledge"/></policy>
<policy user="rcobserver"><allow send_destination="{NAME}" send_interface="{INTERFACE}" send_member="GetProof"/></policy>
</busconfig>''')
        (out / "private-bus-policy.xml").write_bytes(config.read_bytes())
        daemon = subprocess.Popen(["dbus-daemon", "--nofork", "--config-file=" + str(config)], stdout=subprocess.DEVNULL, stderr=(out / "bus.stderr.log").open("w")); processes.append(daemon)
        def wait(path):
            deadline = time.monotonic() + 10
            while not path.exists():
                assert time.monotonic() < deadline, str(path); time.sleep(.02)
        wait(root / "bus")
        fixture = str(pathlib.Path(__file__).with_name("dbus-private-fixture.py"))
        def start_service():
            (root / "state" / "service-ready").unlink(missing_ok=True)
            (root / "state" / "service-released").unlink(missing_ok=True)
            (root / "release-name").unlink(missing_ok=True)
            process = subprocess.Popen(["/usr/bin/python3", fixture, str(root), "service"], user=1102, group=1101, extra_groups=[], stdout=subprocess.DEVNULL, stderr=(out / "service.stderr.log").open("a"))
            processes.append(process); wait(root / "state" / "service-ready"); return process
        service = start_service()
        observer = subprocess.Popen(["/usr/bin/python3", fixture, str(root), "observer"], user=1101, group=1101, extra_groups=[], stdout=subprocess.DEVNULL, stderr=(out / "observer.stderr.log").open("w")); processes.append(observer)
        wait(root / "observer-state" / "port")
        address = "unix:path=" + str(root / "bus")
        def bus_call(member, signature="", parameters=(), uid=0, interface=INTERFACE, destination=NAME):
            return subprocess.run(["busctl", "--address=" + address, "--auto-start=no", "--json=short", "call", destination, PATH, interface, member, signature, *parameters], capture_output=True, text=True, user=uid, group=uid, extra_groups=[])
        metadata = bus_call("Introspect", interface="org.freedesktop.DBus.Introspectable")
        assert metadata.returncode == 0, metadata.stderr
        (out / "actual-introspection.json").write_text(metadata.stdout)
        (out / "actual-introspection.xml").write_text(json.loads(metadata.stdout)["data"][0])
        original_owner = (root / "state" / "service-ready").read_text()
        trusted = canonical.signer(root / "writer-state", out)
        for name in ["key.raw", "key.pem", "trusted.der"]: os.chown(root / "writer-state" / name, 1100, 1100)
        host = root / "writer-state" / "host.json"
        settings = {"version": 1, "revision": "native-dbus-pressure-1", "signingKeyFile": str(root / "writer-state" / "key.raw"), "deniedCapabilities": []}
        def save(): host.write_text(json.dumps(settings)); os.chown(host, 1100, 1100); host.chmod(0o600)
        save()
        # Standard session environment is sufficient; no per-provider artifacts.
        client = WriterClient(args.binary, out, {"DBUS_SESSION_BUS_ADDRESS": address, "RIGHTCLICK_RCIR_CONFIG": str(host), "RIGHTCLICK_DBUS_INVOCATION_ARGUMENT": "invocation"})
        try:
            report.update(runtime=client.runtime, binarySHA256=client.sha256, originalOwner=original_owner)
            item = "Native Linux session D-Bus proof"
            client.call("context_inspect", {"item": item}); client.call("context_providers", {})
            actions = client.call("context_actions", {"item": item})["actions"]
            store = [a for a in actions if a["title"] == "Store" and a.get("provider", {}).get("name") == NAME]
            if args.expect_red:
                assert not store
                report.update(status="FROZEN_NATIVE_DBUS_DISCOVERY_RED", toolCount=7)
                report["controls"]["realMetadataMissingFromRuntime"] = "RED — actual native service exports Store(ssbs)->s and typed EchoTags(as)->as; default runtime discovers neither"
                return
            assert len(store) == 1, actions
            capability = store[0]
            acknowledgement = next(a for a in actions if a["title"] == "Acknowledge")
            ack = client.call("context_run", {"item": item, "actionId": acknowledgement["id"], "confirmed": True})
            assert ack["state"] == "accepted" and ack.get("output") is None and ack["rcir"]["phase"] == "completed" and ack["rcir"]["outcome"] == "unverified", ack
            (out / "ack-unit-receipt.json").write_text(json.dumps(ack["rcir"]["signedReceipt"], indent=2))
            report["controls"]["nativeUnitCompletion"] = "PASS — actual zero-output native method completes without invented typed JSON and remains accepted/unverified"
            default = WriterClient(args.binary, out / "default-session", {"DBUS_SESSION_BUS_ADDRESS": address, "RIGHTCLICK_RCIR_CONFIG": str(host)})
            try:
                plain_actions = default.call("context_actions", {"item": item})["actions"]
                tags = next(a for a in plain_actions if a["title"] == "EchoTags")
                default.call("context_explain", {"item": item, "actionId": tags["id"]})
                values = ["safe native discovery", "literal $(no-shell)", "--address=unix:path=/must-not-connect"]
                tags_result = default.call("context_run", {"item": item, "actionId": tags["id"], "confirmed": True,
                    "arguments": {"values": json.dumps(["array", [["string", x] for x in values]])},
                    "expectedOutput": json.dumps(values, separators=(",", ":")).replace("/", "\\/")})
                assert tags_result["state"] == "succeeded", tags_result
                assert json.loads(tags_result["output"]) == values
                report["controls"]["defaultUsefulDiscovery"] = "PASS — native session environment alone discovers/executes exact typed EchoTags; no per-provider binder/adapter enablement"
            finally: default.close()
            explanation = client.call("context_explain", {"item": item, "actionId": capability["id"]})
            assert explanation["metadata"]["interfaceKind"] == "dbus"
            assert "UnsupportedVariant" not in [a["title"] for a in actions]
            schema = {"type": "object", "properties": {k: {"type": "string"} for k in ["challenge", "digest", "writerUID", "observerUID", "platform", "observation", "enabled", "invocation"]}, "additionalProperties": False}
            schema["required"] = list(schema["properties"])
            origin = "http://127.0.0.1:" + (root / "observer-state" / "port").read_text()
            settings["observers"] = {capability["id"]: {"urlTemplate": origin + "/observations/{challenge}", "trustedOrigin": origin, "credentialFile": str(root / "writer-state" / "observer.token"),
                "jsonObservation": {"schemaJSON": json.dumps(schema), "fields": {"challenge": {"path": ["challenge"], "argument": "challenge"}, "digest": {"path": ["digest"], "expectedOutput": True}}, "invocationBindingPath": ["invocation"]}}}
            save()
            challenge, value = uuid.uuid4().hex, "native typed D-Bus effect " + uuid.uuid4().hex
            digest = hashlib.sha256(value.encode()).hexdigest()
            def invoke(confirmed=True, current=challenge, expected=digest, enabled='["boolean",true]'):
                return client.call("context_run", {"item": item, "actionId": capability["id"], "confirmed": confirmed,
                    "arguments": {"challenge": current, "value": value, "enabled": enabled}, "expectedOutput": expected})
            def observation_for(task_id):
                rows = [json.loads(line) for line in (root / "observer-state" / "observations.jsonl").read_text().splitlines()]
                matching = [row for row in rows if row.get("requestInvocation") == task_id]
                assert len(matching) == 1, "Expected one independently journaled observation for this task"
                return matching[0]
            assert invoke(False)["state"] == "awaiting_user" and not (root / "records" / challenge).exists()
            settings["deniedCapabilities"] = [capability["id"]]; save()
            assert invoke()["state"] == "rejected" and not (root / "records" / challenge).exists()
            settings["deniedCapabilities"] = []; save()
            wrong_challenge = uuid.uuid4().hex
            wrong = client.request("tools/call", {"name": "context_run", "arguments": {"item": item, "actionId": capability["id"], "confirmed": True,
                "arguments": {"challenge": wrong_challenge, "value": value, "enabled": "true"}, "expectedOutput": digest}})
            assert wrong.get("isError") and not (root / "records" / wrong_challenge).exists()
            result = invoke()
            assert result["state"] == "succeeded" and result["rcir"]["outcome"] == "succeeded", result
            assert observation_for(result["rcir"]["taskID"])["invocation"] == result["rcir"]["taskID"]
            raw = canonical.verify(result, root / "writer-state", out, trusted)
            for marker in [challenge, digest, "1100", "1101", "Linux"]: assert marker.encode() in raw
            status = client.call("context_run_status", {"executionId": result["executionId"]})
            assert status["rcir"]["signedReceipt"] == result["rcir"]["signedReceipt"]
            report["controls"]["independentNativeEffect"] = "PASS — Linux UID1100 D-Bus mutation; UID1101 bus read + independent actual-file digest; invocation marker stored at provider ingress"
            report["controls"]["confirmationPolicyTypedGate"] = "PASS — confirmation/policy and wrong Boolean encoding produce no effect"
            report["controls"]["signature"] = "PASS — independently pinned OpenSSL Ed25519 signature"
            forbidden_write = bus_call("Store", "ssbs", [uuid.uuid4().hex, "forbidden", "true", "forbidden"], uid=1101)
            forbidden_read = bus_call("GetProof", "s", [challenge], uid=1100)
            (out / "provider-enforced-denials.json").write_text(json.dumps({"observerWrite": {"exit": forbidden_write.returncode, "stderr": forbidden_write.stderr}, "writerRead": {"exit": forbidden_read.returncode, "stderr": forbidden_read.stderr}}, indent=2))
            assert forbidden_write.returncode != 0 and forbidden_read.returncode != 0
            report["controls"]["unixPrincipalLeastAuthority"] = "PASS — bus daemon EXTERNAL kernel UID enforces writer/observer method separation; direct forbidden calls fail"
            (root / "no-effect").touch()
            noop = invoke(current=uuid.uuid4().hex)
            assert noop["state"] != "succeeded" and noop["rcir"]["outcome"] != "succeeded"
            replay = invoke()
            assert replay["state"] != "succeeded" and replay["rcir"]["outcome"] != "succeeded"
            replay_observation = observation_for(replay["rcir"]["taskID"])
            assert replay_observation["invocation"] == result["rcir"]["taskID"]
            assert replay_observation["invocation"] != replay_observation["requestInvocation"]
            (root / "no-effect").unlink()
            (root / "release-name").touch(); wait(root / "state" / "service-released")
            still_callable = bus_call("Introspect", interface="org.freedesktop.DBus.Introspectable", destination=original_owner)
            assert still_callable.returncode == 0 and service.poll() is None
            assert not any(a["id"] == capability["id"] for a in client.call("context_actions", {"item": item})["actions"])
            service.terminate(); service.wait(timeout=10)
            assert not any(a["id"] == capability["id"] for a in client.call("context_actions", {"item": item})["actions"])
            service = start_service(); new_owner = (root / "state" / "service-ready").read_text(); assert new_owner != original_owner
            restored = client.call("context_actions", {"item": item})["actions"]
            assert any(a["id"] == capability["id"] for a in restored)
            fresh = client.call("context_explain", {"item": item, "actionId": capability["id"]})
            assert fresh["metadata"]["dbusUniqueOwner"] == new_owner
            assert fresh["metadata"]["descriptorSHA256"] != explanation["metadata"]["descriptorSHA256"]
            restored_result = invoke(current=uuid.uuid4().hex)
            assert restored_result["state"] == "succeeded", restored_result
            assert observation_for(restored_result["rcir"]["taskID"])["invocation"] == restored_result["rcir"]["taskID"]
            assert client.request("tools/list")["tools"] == client.tools
            report.update(status="SCOPED_NATIVE_LINUX_DBUS_GREEN", restoredOwner=new_owner, toolCountBefore=7, toolCountAfter=7, providerSpecificToolsAdded=0)
            report["controls"]["ownerWithdrawalRestoration"] = "PASS — ReleaseName withdraws capabilities while old unique connection remains callable; new unique owner changes descriptor binding; fresh invocation succeeds"
            report["controls"]["noEffectAcceptance"] = "PASS — no-effect ACK and previously matching state with an old invocation marker cannot become current mutation success"
        finally:
            if client: client.close()
            for source in [root / "state" / "effects.jsonl", root / "observer-state" / "observations.jsonl"]:
                if source.exists(): (out / source.name).write_bytes(source.read_bytes())
            (out / "results.json").write_text(json.dumps(report, indent=2))
            for process in reversed(processes):
                if process.poll() is None: process.terminate(); process.wait(timeout=10)
    print("PASS: scoped native Linux direct D-Bus proof")

if __name__ == "__main__": main()
