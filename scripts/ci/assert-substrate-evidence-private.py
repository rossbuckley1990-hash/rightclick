#!/usr/bin/env python3
"""Refuse evidence upload if any staged credential value appears in artifacts.

Only explicit public evidence directories are uploaded; private lab state is
never an artifact input. This additional check prints no credential values.
"""
import argparse
import json
import pathlib


def sensitive_values(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key.casefold() in {"token", "password", "client-key-data", "client-secret"} and isinstance(child, str):
                yield child.encode()
            else:
                yield from sensitive_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from sensitive_values(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-inputs", type=pathlib.Path, required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    args = parser.parse_args()
    secrets = set()
    for name in ["scoped.kubeconfig", "observer.kubeconfig", "kafka-publisher.json", "kafka-observer.json"]:
        secrets.update(sensitive_values(json.loads((args.private_inputs / name).read_text())))
    if not secrets or any(not value for value in secrets):
        raise SystemExit("No complete scoped credential set available for the artifact boundary check")
    for path in args.evidence.rglob("*"):
        if path.is_symlink():
            raise SystemExit("Public evidence contains a symlink")
        if path.is_file():
            if path.stat().st_size > 16 * 1024 * 1024:
                raise SystemExit("Public evidence file exceeded the inspection bound; upload forbidden")
            data = path.read_bytes()
            if any(secret in data for secret in secrets):
                raise SystemExit("Private credential detected in public evidence; upload forbidden")
    print("Public evidence does not contain any staged scoped credential values")


if __name__ == "__main__":
    main()
