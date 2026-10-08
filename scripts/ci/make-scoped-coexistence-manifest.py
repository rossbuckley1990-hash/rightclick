#!/usr/bin/env python3
"""Reuse exactly four provisioned scoped files; never import lab/admin state.

The proof-lab already owns the authority/RBAC controls and cleanup. This adapter
selects the identical Kafka topic and namespaced Kubernetes contract for the
same-client coexistence run, using separate native read-only observations.
"""
import argparse
import json
import os
import pathlib
import stat


def protected(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o777 != 0o600 or metadata.st_nlink != 1:
            raise ValueError("The staged scoped reference is not private and owned by the execution principal")
        data = os.read(descriptor, 262145)
        if len(data) > 262144:
            raise ValueError("The staged scoped reference exceeded its bound")
        return json.loads(data)
    finally:
        os.close(descriptor)


def build(inputs, rpk, kubectl):
    inputs, rpk, kubectl = inputs.resolve(strict=True), rpk.resolve(strict=True), kubectl.resolve(strict=True)
    references = {name: inputs / name for name in ("scoped.kubeconfig", "observer.kubeconfig", "kafka-publisher.json", "kafka-observer.json")}
    values = {name: protected(path) for name, path in references.items()}
    writer, reader = values["scoped.kubeconfig"], values["observer.kubeconfig"]
    endpoint = writer["clusters"][0]["cluster"]["server"]
    namespace = writer["contexts"][0]["context"]["namespace"]
    if reader["clusters"][0]["cluster"]["server"] != endpoint or reader["contexts"][0]["context"]["namespace"] != namespace or namespace != "rightclick-proof" or not endpoint.startswith("https://"):
        raise ValueError("Scoped Kubernetes references do not preserve the existing private TLS proof namespace")
    if values["scoped.kubeconfig"] == values["observer.kubeconfig"] or values["kafka-publisher.json"] == values["kafka-observer.json"]:
        raise ValueError("Writer/publisher and observer references must remain separate")
    environment = {"RIGHTCLICK_KAFKA_CLIENT": str(rpk), "RIGHTCLICK_KAFKA_PUBLISHER_CONFIG": str(references["kafka-publisher.json"]),
                   "RIGHTCLICK_KAFKA_OBSERVER_CONFIG": str(references["kafka-observer.json"]), "RIGHTCLICK_KUBERNETES_CLIENT": str(kubectl),
                   "RIGHTCLICK_KUBERNETES_WRITER_CONFIG": str(references["scoped.kubeconfig"]),
                   "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG": str(references["observer.kubeconfig"]), "RIGHTCLICK_KUBERNETES_NAMESPACE": namespace}
    return {"schemaVersion": 1, "runtimeUID": os.geteuid(), "environment": environment,
        "artifacts": [{"id": "coexistence-kafka", "kind": "kafka", "endpointURL": "kafka://127.0.0.1:19092"},
                      {"id": "coexistence-kubernetes", "kind": "kubernetes", "endpointURL": endpoint}],
        "rows": {
            "kafka": {"selector": {"id": "kafka:coexistence-kafka:publish.rightclick.proof"}, "invoke": {"arguments": {"key": "${nonce}", "payload": "${value}"}},
                "requireVerified": True, "verificationBoundary": "Actual disposable broker; separate SASL read-only principal; exact fresh key/value and host task marker at acknowledged coordinates",
                "readback": {"type": "command-json", "command": [str(rpk), "--config", str(references["kafka-observer.json"]), "topic", "consume", "rightclick.proof", "-p", "${partition}", "-o", "${offset}", "-n", "1", "--format", "json", "--pretty-print=false"],
                    "fields": [{"path": ["topic"], "expected": "rightclick.proof"}, {"path": ["partition"], "expected": "${partition}"}, {"path": ["offset"], "expected": "${offset}"},
                               {"path": ["key"], "expected": "${nonce}"}, {"path": ["value"], "expected": "${value}"},
                               {"path": ["headers", "0", "key"], "expected": "rightclick.invocation"}, {"path": ["headers", "0", "value"], "expected": "${taskID}"}]}},
            "kubernetes": {"selector": {"id": "kubernetes:coexistence-kubernetes:create.configmaps"}, "invoke": {"arguments": {"name": "${name}", "challenge": "${nonce}", "value": "${value}"}},
                "requireVerified": True, "verificationBoundary": "Actual namespaced RBAC writer; distinct GET-only observer; desired bytes and exact host task annotation checked independently",
                "readback": {"type": "command-json", "command": [str(kubectl), "--kubeconfig", str(references["observer.kubeconfig"]), "--namespace", namespace, "--request-timeout=3s", "get", "configmap", "${name}", "-o", "json"],
                    "fields": [{"path": ["metadata", "name"], "expected": "${name}"}, {"path": ["metadata", "namespace"], "expected": namespace},
                               {"path": ["data", "challenge"], "expected": "${nonce}"}, {"path": ["data", "value"], "expected": "${value}"},
                               {"path": ["metadata", "annotations", "rightclick.io/invocation"], "expected": "${taskID}"}]}}
        }}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--rpk", required=True, type=pathlib.Path)
    parser.add_argument("--kubectl", required=True, type=pathlib.Path)
    args = parser.parse_args()
    value = build(args.inputs, args.rpk, args.kubectl)
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.output.write_text(json.dumps(value, indent=2) + "\n")
    args.output.chmod(0o600)
    print("Staged reference-only Kafka/Kubernetes coexistence manifest; no admin authority or credential bytes published")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit("Scoped coexistence manifest failed: " + type(error).__name__) from None
