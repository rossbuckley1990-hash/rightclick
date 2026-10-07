#!/usr/bin/env python3
"""Generic authenticated structured HTTP observation through seven fixed tools.
This actual HTTP/process fixture is not a claim of Windows/Linux native proof.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location("canonical", pathlib.Path(__file__).with_name("canonical-mcp-proof-client.py"))
canonical = importlib.util.module_from_spec(spec); spec.loader.exec_module(canonical)


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("binary", type=pathlib.Path); parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--expect-red", action="store_true"); parser.add_argument("--acknowledgement-only", action="store_true")
    parser.add_argument("--causal", action="store_true", help="Require an independently read host invocation marker; include old/no-op and protected-secret controls.")
    args = parser.parse_args()
    if args.expect_red and args.acknowledgement_only: parser.error("Legacy text RED and ACK-only proof are separate boundaries.")
    if args.expect_red and args.causal: parser.error("The legacy whole-text RED cannot express structured causal observation.")
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    report, processes = {"runKind": "NEW_RUN", "controls": {}}, []
    with tempfile.TemporaryDirectory(prefix="rightclick-http-json-acceptance-") as temporary:
        tmp = pathlib.Path(temporary)
        if args.acknowledgement_only: (tmp / "ack-response").write_text("fixture declaration has no output")
        if args.causal: (tmp / "include-invocation").write_text("host marker required")
        for name in ["observer.token", "writer.token"]:
            (tmp / name).write_text(uuid.uuid4().hex); (tmp / name).chmod(0o600)
        for role in ["provider", "observer", "trap"]:
            process = subprocess.Popen(["python3", str(pathlib.Path(__file__).with_name("rcir-http-json-fixture.py")), str(tmp), role], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process); deadline = time.monotonic() + 10
            while not (tmp / (role + "-port")).exists():
                assert time.monotonic() < deadline; time.sleep(.01)
        provider = "http://127.0.0.1:" + (tmp / "provider-port").read_text()
        observer = "http://127.0.0.1:" + (tmp / "observer-port").read_text()
        trusted = canonical.signer(tmp, out); host = tmp / "host.json"
        settings = {"version": 1, "revision": "http-json-acceptance-1", "deniedCapabilities": [], "signingKeyFile": str(tmp / "key.raw")}
        def save(): host.write_text(json.dumps(settings)); host.chmod(0o600)
        save()
        runtime = canonical.Client(args.binary, out, {"RIGHTCLICK_CAPABILITY_ARTIFACTS": json.dumps([{"id": "independent-json-http", "kind": "openapi", "specificationURL": provider + "/openapi.json", "baseURL": provider}]), "RIGHTCLICK_RCIR_CONFIG": str(host)})
        try:
            report.update(runtime=runtime.runtime, binary=str(runtime.binary), binarySHA256=runtime.sha256)
            item = "Genuine separate HTTP JSON observer pressure proof"
            runtime.call("context_inspect", {"item": item}); runtime.call("context_providers", {})
            actions = runtime.call("context_actions", {"item": item})["actions"]
            capability = next(a for a in actions if a["title"] == "Store dedicated HTTP observation challenge")
            explanation = runtime.call("context_explain", {"item": item, "actionId": capability["id"]})
            if args.acknowledgement_only:
                assert explanation["output"] == [] and explanation["metadata"]["resultValidation"] == "no_declared_output"
            schema = {"type": "object", "properties": {k: {"type": "string"} for k in ["challenge", "result", "machine", "observation", "observerPrincipal", "platform", "principal"]}, "additionalProperties": False}
            schema["properties"]["uid"] = {"type": "null"}; schema["required"] = list(schema["properties"])
            if args.causal:
                schema["properties"]["invocationID"] = {"type": "string"}; schema["required"].append("invocationID")
            settings["observers"] = {capability["id"]: {"urlTemplate": observer + "/observations/{id}", "trustedOrigin": observer, "credentialFile": str(tmp / "observer.token"),
                "jsonObservation": {"schemaJSON": json.dumps(schema), "fields": {"challenge": {"path": ["challenge"], "argument": "id"}, "result": {"path": ["result"], "expectedOutput": True}}}}}
            if args.causal: settings["observers"][capability["id"]]["jsonObservation"]["invocationBindingPath"] = ["invocationID"]
            if args.expect_red:
                settings["observers"] = {capability["id"]: {"urlTemplate": observer + "/public-json/{id}", "trustedOrigin": observer, "expectedArgument": "id"}}
            save()
            challenge, value = uuid.uuid4().hex, "independent file effect " + uuid.uuid4().hex
            digest = hashlib.sha256(value.encode()).hexdigest()
            def invoke(confirmed=True):
                query = {"item": item, "actionId": capability["id"], "confirmed": confirmed, "arguments": {"id": challenge, "value": value}}
                if not args.expect_red: query["expectedOutput"] = digest
                return runtime.call("context_run", query)
            gated = invoke(False); assert gated["state"] == "awaiting_user" and not (tmp / "records" / challenge).exists()
            settings["deniedCapabilities"] = [capability["id"]]; save()
            denied = invoke(); assert denied["state"] == "rejected" and not (tmp / "records" / challenge).exists()
            settings["deniedCapabilities"] = []; save()
            if args.causal:
                old_marker = "11111111-1111-4111-8111-111111111111"
                (tmp / "records" / challenge).write_text(value); (tmp / "records" / (challenge + ".invocation")).write_text(old_marker)
                (tmp / "noop-provider").write_text("accept without mutation")
                old = invoke(); assert old["state"] == "failed" and old["rcir"]["outcome"] == "failed"
                rows = [json.loads(row) for row in (tmp / "effects.jsonl").read_text().splitlines()]
                assert len(rows) == 1 and rows[0]["mutationApplied"] is False
                assert (tmp / "records" / (challenge + ".invocation")).read_text() == old_marker
                canonical.verify(old, tmp, out, trusted); (out / "success-receipt.json").rename(out / "old-marker-failed-receipt.json")
                (tmp / "noop-provider").unlink(); (tmp / "records" / challenge).unlink(); (tmp / "records" / (challenge + ".invocation")).unlink()
                report["controls"]["oldMatchingArtifact"] = "PASS — actual no-op acknowledgement and independently read old matching artifact produce signed failed outcome; original marker unchanged"
            result = invoke(); assert (tmp / "records" / challenge).read_text() == value
            if args.expect_red:
                assert result["state"] == "failed" and result["rcir"]["outcome"] == "failed"
                report["status"] = "FROZEN_LEGACY_CONTRACT_RED"
                report["controls"]["exactEffectButUnrepresentableStructuredPostcondition"] = "RED — legacy whole-text observation fails although independently stored bytes and digest are correct"
                canonical.verify(result, tmp, out, trusted)
                (out / "success-receipt.json").rename(out / "legacy-failed-receipt.json")
                return
            assert result["state"] == "succeeded" and result["rcir"]["outcome"] == "succeeded", result
            if args.acknowledgement_only: assert result.get("output") is None
            receipt = canonical.verify(result, tmp, out, trusted)
            if args.causal:
                assert (tmp / "records" / (challenge + ".invocation")).read_text() == result["rcir"]["taskID"]
                report["controls"]["invocationBinding"] = "PASS — independently stored marker exactly matches current host task identity before semantic success"
            for field in [challenge, digest, "fixture-readonly", "independent-file-sha256"]: assert field.encode() in receipt
            status = runtime.call("context_run_status", {"executionId": result["executionId"]})
            assert status["rcir"]["signedReceipt"] == result["rcir"]["signedReceipt"]
            report["controls"]["independentStructuredDigest"] = "PASS — distinct read-only credential/origin/process reads actual file and computes expected caller digest; complete metadata signed"
            report["controls"]["signature"] = "PASS — separately pinned OpenSSL Ed25519 verification"
            report["controls"]["confirmationPolicy"] = "PASS — both denials leave resource absent"
            if args.causal:
                (tmp / "echo-observer-credential").write_text("raw")
                contaminated = invoke(); assert contaminated["state"] == "accepted" and contaminated["rcir"]["outcome"] == "unverified"
                token = (tmp / "observer.token").read_bytes()
                import base64
                payload = base64.b64decode(contaminated["rcir"]["receipt"], validate=True)
                assert token not in payload and token not in json.dumps(contaminated).encode()
                canonical.verify(contaminated, tmp, out, trusted); (out / "success-receipt.json").rename(out / "credential-reflection-unverified-receipt.json")
                # Preserve the independently verified success receipt separately.
                (out / "success-receipt.json").write_text(json.dumps(result["rcir"]["signedReceipt"], indent=2))
                report["controls"]["protectedCredentialReflection"] = "PASS — real observer echoes private bearer into declared metadata; runtime abstains and emits uncontaminated signed unverified receipt"
            processes[0].terminate(); processes[0].wait(timeout=10); time.sleep(5.1)
            assert not any(a["id"] == capability["id"] for a in runtime.call("context_actions", {"item": item})["actions"])
            assert runtime.request("tools/list")["tools"] == runtime.tools
            report.update(toolCountBefore=7, toolCountAfter=7, providerSpecificToolsAdded=0, status="GREEN_FOR_GENERIC_HTTP_BOUNDARY")
            if args.acknowledgement_only:
                report["status"] = "GREEN_FOR_GENERIC_ACK_ONLY_BOUNDARY"
                report["controls"]["noDeclaredOutput"] = "PASS — acquired202 ACK declaration emits no typed provider value; independently verified external file effect determines success"
            report["controls"]["liveProviderRemoval"] = "PASS — dynamically acquired operation disappears; seven tool definitions unchanged"
            if args.causal:
                report["status"] = "GREEN_FOR_GENERIC_HTTP_CAUSAL_AND_PROTECTED_OBSERVER_BOUNDARY"
            report["substrateBoundary"] = "Actual generic HTTP fixture/process proof; native Windows/Linux effects are separately required."
        finally:
            (out / "results.json").write_text(json.dumps(report, indent=2)); runtime.close()
            for name in ["effects.jsonl", "observations.jsonl", "trap.jsonl"]:
                if (tmp / name).exists(): (out / name).write_bytes((tmp / name).read_bytes())
            for process in processes:
                if process.poll() is None: process.terminate(); process.wait(timeout=10)
    print("PASS: generic structured HTTP read-back through seven canonical operations")


if __name__ == "__main__": main()
