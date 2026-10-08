#!/usr/bin/env python3
"""Record exact checked-out source, platform and package provenance."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--expected-arch", required=True)
    args = parser.parse_args()
    expected = os.environ["RIGHTCLICK_CI_SOURCE"]
    source = command("git", "-c", "safe.directory=" + str(pathlib.Path.cwd()), "rev-parse", "HEAD")
    if source != expected or platform.machine() != args.expected_arch:
        raise SystemExit("Exact source or native architecture does not match the job")
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in [pathlib.Path("Package.swift"), pathlib.Path("Package.resolved")]}
    report = {"schemaVersion": 1, "candidateSHA": source, "expectedCandidateSHA": expected,
              "sourcesTree": command("git", "-c", "safe.directory=" + str(pathlib.Path.cwd()),
                                     "rev-parse", "HEAD:Sources"),
              "platform": platform.platform(), "machine": platform.machine(),
              "swift": command("swift", "--version"), "sha256": hashes,
              "package": json.loads(command("swift", "package", "describe", "--type", "json")),
              "releasePerformed": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("Recorded exact candidate", source, "native", platform.machine())


if __name__ == "__main__":
    main()
