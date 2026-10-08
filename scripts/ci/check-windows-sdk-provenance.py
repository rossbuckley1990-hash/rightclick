#!/usr/bin/env python3
"""Validate the immutable Windows-only MCP SDK source snapshot.

This checks source provenance, not native Windows build/runtime support. The
native Windows job must establish those independently.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys

UPSTREAM_COMMIT = "a0ae212ebf6eab5f754c3129608bc5557637e605"
ALLOWED_PATCH = "Sources/MCP/Base/Transports/HTTPClientTransport.swift"
PROVENANCE_HASH = "a49e695e940c767cb9926c5dda86748983cc009d8b1de1762708da466b3bdde5"


class ProvenanceError(ValueError):
    pass


def document(path: Path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ProvenanceError(f"Duplicate provenance key: {key}")
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def check(snapshot: Path, upstream: Path | None = None) -> dict:
    if snapshot.is_symlink() or not snapshot.is_dir():
        raise ProvenanceError("Missing or symlinked SDK snapshot")
    provenance = snapshot / "snapshot-provenance.json"
    if provenance.is_symlink() or hashlib.sha256(provenance.read_bytes()).hexdigest() != PROVENANCE_HASH:
        raise ProvenanceError("Immutable Windows SDK provenance pin changed")
    metadata = document(provenance)
    if (metadata.get("upstreamCommit") != UPSTREAM_COMMIT or metadata.get("version") != "0.12.1"
            or metadata.get("selection") != "Windows only" or metadata.get("allowedModifiedUpstreamSource") != ALLOWED_PATCH):
        raise ProvenanceError("Unexpected SDK identity or patch scope")
    expected = metadata.get("files")
    if not isinstance(expected, dict) or len(expected) != 50:
        raise ProvenanceError("Unexpected snapshot inventory")
    actual = set()
    for path in snapshot.rglob("*"):
        if path.is_symlink():
            raise ProvenanceError(f"Symlink in SDK snapshot: {path.relative_to(snapshot)}")
        if path.is_file() and path != provenance:
            actual.add(path.relative_to(snapshot).as_posix())
    if actual != set(expected):
        raise ProvenanceError("SDK inventory changed: missing=" + repr(sorted(set(expected) - actual))
                              + "; unexpected=" + repr(sorted(actual - set(expected))))
    for name, digest in expected.items():
        pure = PurePosixPath(name)
        if pure.is_absolute() or ".." in pure.parts or "\\" in name:
            raise ProvenanceError("Unsafe snapshot path")
        if hashlib.sha256((snapshot / name).read_bytes()).hexdigest() != digest:
            raise ProvenanceError(f"SDK source hash changed: {name}")
    swift_sources = sorted(name for name in expected if name.startswith("Sources/MCP/") and name.endswith(".swift"))
    if len(swift_sources) != 47:
        raise ProvenanceError("MCP source closure changed")
    changed_upstream = None
    if upstream is not None:
        head = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
        if head != UPSTREAM_COMMIT:
            raise ProvenanceError("Wrong upstream comparison revision")
        names = subprocess.check_output(["git", "-C", str(upstream), "ls-tree", "-r", "--name-only", "HEAD", "Sources/MCP"], text=True).splitlines()
        if set(names) != set(swift_sources):
            raise ProvenanceError("Snapshot does not preserve the exact upstream MCP source closure")
        changed_upstream = []
        for name in names:
            raw = subprocess.check_output(["git", "-C", str(upstream), "show", "HEAD:" + name])
            if hashlib.sha256(raw).hexdigest() != expected[name]:
                changed_upstream.append(name)
        if changed_upstream != [ALLOWED_PATCH]:
            raise ProvenanceError("Unreviewed upstream source modifications: " + repr(changed_upstream))
        original_license = subprocess.check_output(["git", "-C", str(upstream), "show", "HEAD:LICENSE"])
        if hashlib.sha256(original_license).hexdigest() != expected["LICENSE"]:
            raise ProvenanceError("Upstream license changed")
    return {"status": "passed", "upstreamCommit": UPSTREAM_COMMIT, "version": "0.12.1",
            "selection": "Windows only", "files": len(expected), "mcpSwiftSources": len(swift_sources),
            "provenanceSHA256": PROVENANCE_HASH, "comparedWithUpstream": upstream is not None,
            "modifiedUpstreamSources": changed_upstream,
            "nativeWindowsBuild": "not evaluated by this source provenance gate"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--upstream-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[2]
    try:
        result = check(args.snapshot or root / "Vendor/mcp-swift-sdk", args.upstream_root)
    except (ProvenanceError, OSError, ValueError, subprocess.CalledProcessError) as error:
        result = {"status": "failed", "error": str(error), "upstreamCommit": UPSTREAM_COMMIT}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("Windows SDK provenance: " + result["status"] + (": " + result["error"] if "error" in result else ""))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
