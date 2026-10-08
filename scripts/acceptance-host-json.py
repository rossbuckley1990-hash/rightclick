#!/usr/bin/env python3
"""Real TLS host effects through the seven canonical operations.

This disclosed engineering client is not the final fresh-AI acceptance run.
Private bearer values are read from protected references and never recorded.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location("canonical", pathlib.Path(__file__).with_name("canonical-mcp-proof-client.py"))
canonical = importlib.util.module_from_spec(spec); spec.loader.exec_module(canonical)
spec = importlib.util.spec_from_file_location("receipt", pathlib.Path(__file__).with_name("verify-rcir-receipt.py"))
receipt = importlib.util.module_from_spec(spec); spec.loader.exec_module(receipt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--references", type=pathlib.Path, required=True)
    parser.add_argument("--platform", choices=["Windows", "Linux"], required=True)
    parser.add_argument("--expect-red", action="store_true")
    parser.add_argument("--withdraw", action="store_true")
    args = parser.parse_args(); refs = json.loads(args.references.read_text())
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    writer, observer = refs["writerOrigin"], refs["observerOrigin"]
    credentials = refs["credentialReferences"]
    # References contain only paths. Credential bytes stay in process memory.
    writer_token = pathlib.Path(credentials["writer"]).read_text().strip()
    observer_token = pathlib.Path(credentials["observer"]).read_text().strip()
    report = {"scope": "Engineering seven-operation proof; final fresh-AI acceptance is separate.", "platform": args.platform}
    def read(origin, path, token, method="GET"):
        request = urllib.request.Request(origin + path, headers={"Authorization": "Bearer " + token}, method=method)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())
    controls = report["controls"] = {}
    with tempfile.TemporaryDirectory(prefix="rightclick-host-json-acceptance-") as temporary:
        tmp = pathlib.Path(temporary); trusted = canonical.signer(tmp, out)
        host = tmp / "host.json"
        settings = {"version": 1, "revision": "host-json-observation-1", "deniedCapabilities": [], "signingKeyFile": str(tmp / "key.raw")}
        def save(): host.write_text(json.dumps(settings)); host.chmod(0o600)
        save()
        authority_args = [str(args.binary.resolve()), "authority", "set", "--origin", writer, "--scheme", "proofBearer"]
        installed = subprocess.run(authority_args, input=writer_token + "\n", text=True, capture_output=True, timeout=20)
        assert installed.returncode == 0, "Scoped proof authority could not be stored"
        runtime = None
        try:
            runtime = canonical.Client(args.binary, out, {"RIGHTCLICK_RCIR_CONFIG": str(host),
                "RIGHTCLICK_CAPABILITY_EXPERIENCE": "disabled", "RIGHTCLICK_CAPABILITY_ARTIFACTS": json.dumps([
                    {"id": "proof-" + args.platform.lower(), "kind": "openapi", "specificationURL": writer + "/openapi.json",
                     "baseURL": writer, "authorityScheme": "proofBearer"}])})
            report.update(binarySHA256=runtime.sha256, runtime=runtime.runtime, providers=runtime.call("context_providers", {}))
            item = "Disposable " + args.platform + " host effect proof"
            runtime.call("context_inspect", {"item": item})
            actions = runtime.call("context_actions", {"item": item})["actions"]
            candidates = [a for a in actions if a["id"].endswith(":hostWriteProof")]
            if args.expect_red and not candidates:
                code, declaration = read(writer, "/openapi.json", writer_token)
                assert code == 200 and declaration["paths"]["/proof"]["post"]["operationId"] == "hostWriteProof"
                (out / "actual-openapi.json").write_text(json.dumps(declaration, indent=2))
                code, native = read(observer, "/health", observer_token)
                assert code == 200 and native["platform"] == args.platform and native["readOnly"]
                report.update(status="FROZEN_RED", actualProviderReadiness=native,
                    genericDeficiency="Closed string-contract importer cannot retain and enforce a bounded declared pattern; actual host operation is omitted.")
                return
            assert len(candidates) == 1, "Actual host OpenAPI operation was not discovered"
            action = candidates[0]["id"]
            report["explanation"] = runtime.call("context_explain", {"item": item, "actionId": action})
            names = ["challenge", "result", "machine", "observation", "observerPrincipal", "platform", "principal", "uid"]
            schema = {"type": "object", "additionalProperties": False, "required": names,
                "properties": {name: {"type": "string"} for name in names}}
            schema["properties"]["uid"] = {"type": "null" if args.platform == "Windows" else "integer"}
            settings["observers"] = {action: {"urlTemplate": observer + "/proof/{challenge}", "trustedOrigin": observer,
                "credentialFile": credentials["observer"], "jsonObservation": {"schemaJSON": json.dumps(schema), "fields": {
                    "challenge": {"path": ["challenge"], "argument": "challenge"},
                    "result": {"path": ["result"], "expectedOutput": True}}}}}
            save()
            challenge = "host-proof-" + uuid.uuid4().hex
            expected = hashlib.sha256(("RIGHTCLICK:" + challenge).encode()).hexdigest()
            def absent(): assert read(observer, "/proof/" + challenge, observer_token)[0] == 404
            def invoke(confirmed=True):
                return runtime.call("context_run", {"item": item, "actionId": action, "confirmed": confirmed,
                    "arguments": {"challenge": challenge}, "expectedOutput": expected})
            absent()
            if args.expect_red:
                red = invoke(); absent()
                assert red["state"] != "succeeded" and not red["evidence"]["outcomeVerified"]
                report.update(status="FROZEN_RED", result=red,
                    genericDeficiency="Host-selected HTTP observations cannot bind typed JSON fields to original arguments and an independent expected output.")
                return
            gated = invoke(False); absent(); assert gated["state"] == "awaiting_user"
            controls["confirmationNoEffect"] = True
            settings["deniedCapabilities"] = [action]; save()
            denied = invoke(); absent(); assert denied["state"] == "rejected"
            controls["policyNoEffect"] = True
            settings["deniedCapabilities"] = []; save()
            result = invoke(); assert result["state"] == "succeeded" and result["evidence"]["outcomeVerified"], result
            report["verifiedExecution"] = result
            status = runtime.call("context_run_status", {"executionId": result["executionId"]})
            assert status["rcir"]["signedReceipt"] == result["rcir"]["signedReceipt"]
            code, observed = read(observer, "/proof/" + challenge, observer_token)
            assert code == 200 and observed["challenge"] == challenge and observed["result"] == expected
            assert observed["platform"] == args.platform and observed["principal"] != observed["observerPrincipal"]
            payload = canonical.verify(result, tmp, out, trusted)
            document = receipt._domain(payload, "RECEIPT")
            assert receipt._value(document["observation"]) == observed
            report["independentWorkbenchObservation"] = observed
            controls["independentPinnedSignatureAndFullObservation"] = True
            controls["crossTokenRejected"] = read(observer, "/proof/" + challenge, writer_token)[0] == 401
            controls["observerWriteForbidden"] = read(observer, "/proof", observer_token, "POST")[0] == 403
            assert controls["crossTokenRejected"] and controls["observerWriteForbidden"]
            if args.withdraw:
                connection = json.loads(pathlib.Path(refs["privateConnectionReference"]).read_text())
                control_token = pathlib.Path(credentials["operator"]).read_text().strip()
                code, _ = read(writer, connection["controlPath"], control_token, "POST")
                assert code in (200, 202, 204)
                unavailable = invoke()
                assert unavailable["state"] != "succeeded" and not unavailable["evidence"]["outcomeVerified"]
                controls["issuerWithdrawalBlocksStaleInvocation"] = True
            assert runtime.request("tools/list")["tools"] == runtime.tools
            report.update(status="GREEN_FOR_THIS_BOUNDARY", toolCountBefore=7, toolCountAfter=7, providerSpecificAITools=0)
        finally:
            (out / "results.json").write_text(json.dumps(report, indent=2))
            if runtime: runtime.close()
            deleted = subprocess.run([str(args.binary.resolve()), "authority", "delete", "--origin", writer, "--scheme", "proofBearer"],
                capture_output=True, text=True, timeout=20)
            assert deleted.returncode == 0, "Disposable proof authority cleanup failed"
    print("PASS: real " + args.platform + " JSON observation through seven operations")


if __name__ == "__main__": main()
