#!/usr/bin/env python3
"""Reproduce two malformed-input controls against exact existing codec sources."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    evidence = Path(__file__).resolve().parent
    root = evidence.parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    probe = output / "main.swift"
    probe.write_bytes((evidence / "main.swift").read_bytes())
    results = {}
    for label, source in [
        ("baseline", evidence / "GRPCWireCodec-baseline.swift"),
        ("candidate", root / "Sources/RightClickCore/GRPCWireCodec.swift"),
    ]:
        binary = output / (label + "-probe")
        subprocess.run([
            "swiftc", "-module-cache-path", str(output / "module-cache"),
            str(source), str(probe), "-o", str(binary),
        ], check=True, timeout=60)
        cases = []
        for case, arguments in [("length", []), ("overwide-varint", ["varint"])]:
            run = subprocess.run([str(binary), *arguments], capture_output=True, timeout=5)
            cases.append({
                "case": case, "returnCode": run.returncode,
                "stdout": run.stdout.decode("utf-8"),
                "stderrBytes": len(run.stderr),
                "stderrSHA256": hashlib.sha256(run.stderr).hexdigest(),
            })
        results[label] = {
            "codecSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "results": cases,
        }
        (output / (label + "-results.json")).write_text(json.dumps(results[label], indent=2) + "\n")
    assert results["baseline"]["results"][0]["returnCode"] < 0, "Missing crash control"
    assert results["baseline"]["results"][1]["returnCode"] == 2, "Missing oversized-varint control"
    assert all(case["returnCode"] == 0 and case["stdout"] == "bounded_encoding_rejected\n"
               for case in results["candidate"]["results"]), "Bounded rejection failed"
    print(json.dumps({"result": "PASS", "scope": "isolated native codec, no provider dispatch", **results}))


if __name__ == "__main__":
    main()
