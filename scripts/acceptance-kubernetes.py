#!/usr/bin/env python3
"""Genuine namespaced Kubernetes pressure proof through seven canonical operations.
The host-provisioned writer and GET-only observer are never widened. Private
copied credential bytes and signing keys are never committed as evidence.
"""
import argparse
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path); parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--lab", type=pathlib.Path, default=pathlib.Path("/tmp/rightclick-proof-lab-20261007"))
    parser.add_argument("--client", type=pathlib.Path, default=pathlib.Path("/usr/local/bin/kubectl"))
    parser.add_argument("--expect-red", action="store_true")
    args = parser.parse_args(); out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    report, client = {"runKind": "NEW_RUN", "controls": {}}, args.client.resolve()
    with tempfile.TemporaryDirectory(prefix="rightclick-kubernetes-acceptance-") as temporary:
        tmp = pathlib.Path(temporary).resolve(); writer, reader = tmp / "writer.json", tmp / "reader.json"
        writer.write_bytes((args.lab / "scoped.kubeconfig").read_bytes()); writer.chmod(0o600)
        reader.write_bytes((args.lab / "observer.kubeconfig").read_bytes()); reader.chmod(0o600)
        config_bytes = json.loads(writer.read_text()); endpoint = config_bytes["clusters"][0]["cluster"]["server"]
        namespace = config_bytes["contexts"][0]["context"]["namespace"]; host = tmp / "host.json"
        trusted = canonical.signer(tmp, out)
        settings = {"version": 1, "revision": "kubernetes-acceptance-1", "deniedCapabilities": [], "signingKeyFile": str(tmp / "key.raw")}
        def save(): host.write_text(json.dumps(settings)); host.chmod(0o600)
        save()
        def kubectl(ref, *arguments, input=None):
            return subprocess.run([str(client), "--kubeconfig", str(ref), "--namespace", namespace, "--request-timeout=3s", *arguments],
                input=input, capture_output=True, text=True, timeout=10)
        for role, ref in (("writer", writer), ("observer", reader)):
            who = kubectl(ref, "auth", "whoami", "-o", "json"); assert who.returncode == 0
            report[role + "Principal"] = json.loads(who.stdout)["status"]["userInfo"]["username"]
        discovery = kubectl(writer, "get", "--raw", "/api/v1"); assert discovery.returncode == 0
        (out / "actual-api-resource-list.json").write_text(discovery.stdout)
        for label, ref, arguments in (("writerNodesForbidden", writer, ["get", "nodes", "-o", "json"]),
                ("writerDefaultNamespaceForbidden", writer, ["get", "configmaps", "--namespace", "default", "-o", "json"])):
            denied = kubectl(ref, *arguments); assert denied.returncode != 0 and "Forbidden" in denied.stderr
            report["controls"][label] = "PASS — actual API Forbidden"; (out / (label + ".txt")).write_text(denied.stderr)
        manifest = json.dumps({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "rightclick-denied-" + uuid.uuid4().hex}, "data": {"challenge": "denial", "value": "denial"}})
        denied = kubectl(reader, "create", "-f", "-", "-o", "json", input=manifest)
        assert denied.returncode != 0 and "Forbidden" in denied.stderr
        report["controls"]["observerWriteForbidden"] = "PASS — independent observer actual create Forbidden"
        (out / "observerWriteForbidden.txt").write_text(denied.stderr)
        runtime = canonical.Client(args.binary, out, {"RIGHTCLICK_CAPABILITY_ARTIFACTS": json.dumps([{"id": "proof-cluster", "kind": "kubernetes", "endpointURL": endpoint}]),
            "RIGHTCLICK_KUBERNETES_CLIENT": str(client), "RIGHTCLICK_KUBERNETES_WRITER_CONFIG": str(writer), "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG": str(reader),
            "RIGHTCLICK_KUBERNETES_NAMESPACE": namespace, "RIGHTCLICK_RCIR_CONFIG": str(host)})
        try:
            report.update(binary=str(runtime.binary), binarySHA256=runtime.sha256, runtime=runtime.runtime)
            item = "Disposable Kubernetes namespace pressure proof"
            runtime.call("context_inspect", {"item": item}); report["providersBefore"] = runtime.call("context_providers", {})
            actions = runtime.call("context_actions", {"item": item})["actions"]
            candidates = [a for a in actions if a["id"].startswith("kubernetes:")]
            if args.expect_red:
                assert not candidates
                report["status"] = "FROZEN_RED"
                report["genericDeficiency"] = "Authenticated resource metadata and independently observed assigned fields cannot reach common admission through ordinary descriptor composition."
                report["controls"]["readyProviderNoCapability"] = "RED — real discovery, principals and Forbidden controls passed; runtime acquired no Kubernetes capability"
                return
            assert len(candidates) == 1, candidates
            capability = candidates[0]
            report["explain"] = runtime.call("context_explain", {"item": item, "actionId": capability["id"]})
            name, challenge = "rightclick-proof-" + uuid.uuid4().hex, uuid.uuid4().hex
            arguments = {"name": name, "challenge": challenge, "value": "independently observed " + challenge}
            def invoke(confirmed=True): return runtime.call("context_run", {"item": item, "actionId": capability["id"], "confirmed": confirmed, "arguments": arguments})
            def absent():
                actual = kubectl(reader, "get", "configmap", name, "-o", "json")
                assert actual.returncode != 0 and "NotFound" in actual.stderr
            gated = invoke(False); assert gated["state"] == "awaiting_user"; absent()
            report["controls"]["confirmationDenial"] = "PASS — resource remains absent"
            settings["deniedCapabilities"] = [capability["id"]]; save()
            denied = invoke(); assert denied["state"] == "rejected"; absent()
            report["controls"]["policyDenial"] = "PASS — resource remains absent"
            settings["deniedCapabilities"] = []; save()
            result = invoke(); assert result["state"] == "succeeded", result
            assert result["rcir"]["leaseConsumed"] and result["rcir"]["outcome"] == "succeeded" and result["evidence"]["outcomeVerified"]
            status = runtime.call("context_run_status", {"executionId": result["executionId"]})
            assert status["rcir"]["signedReceipt"] == result["rcir"]["signedReceipt"]
            actual = kubectl(reader, "get", "configmap", name, "-o", "json"); assert actual.returncode == 0
            resource = json.loads(actual.stdout); assert resource["data"] == {"challenge": challenge, "value": arguments["value"]}
            assert resource["metadata"]["annotations"]["rightclick.io/invocation"] == result["rcir"]["taskID"]
            (out / "independent-resource.json").write_text(actual.stdout)
            receipt = canonical.verify(result, tmp, out, trusted)
            for value in [resource["metadata"]["uid"], resource["metadata"]["resourceVersion"], challenge, arguments["value"]]: assert value.encode() in receipt
            report["controls"]["signatureAssignedMetadata"] = "PASS — independently pinned OpenSSL Ed25519; genuine UID/resourceVersion and exact desired fields retained"
            report["controls"]["independentScopedRead"] = "PASS — distinct GET-only identity reads actual resource; provider result does not define acceptance"
            report["controls"]["hostInvocationMarkerVerified"] = "PASS — independent annotation equals the host task identity bound before dispatch"
            captured = writer.read_bytes(); writer.unlink()
            assert not any(a["id"] == capability["id"] for a in runtime.call("context_actions", {"item": item})["actions"])
            runtime.call("context_providers", {}); writer.write_bytes(captured); writer.chmod(0o600); time.sleep(5.1)
            assert any(a["id"] == capability["id"] for a in runtime.call("context_actions", {"item": item})["actions"])
            assert runtime.request("tools/list")["tools"] == runtime.tools
            report["controls"]["liveAuthorityMutation"] = "PASS — protected credential withdrawal/restoration removes/reacquires capabilities; seven tool definitions unchanged"
            report.update(toolCountBefore=7, toolCountAfter=7, providerSpecificToolsAdded=0, status="GREEN_FOR_THIS_BOUNDARY")
            report["lifecycleBoundary"] = "ConfigMap create is immediately stored. Async controllers, watches, Job completion and generic REST TLS transport remain RED."
            report["scopeBoundary"] = "Issuer namespace RBAC with separate GET-only service account; exact local argument/name/namespace lease. No cluster/admin or provider-selected credentials."
            report["restrictedAgentBoundary"] = "Engineering client restricted to seven operations; fresh AI eleven-substrate proof remains separate."
        finally:
            (out / "results.json").write_text(json.dumps(report, indent=2)); runtime.close()
    print("PASS: real Kubernetes through seven canonical operations")


if __name__ == "__main__": main()
