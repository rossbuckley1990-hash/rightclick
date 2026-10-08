#!/usr/bin/env python3
"""Download official pinned native component tooling; fail on digest mismatch."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import tarfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("evidence", type=pathlib.Path)
    args = parser.parse_args()
    root = args.destination.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    pins = json.loads(pathlib.Path(__file__).with_name("fixture-tools.json").read_text())
    architecture = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    operating_system = {"Darwin": "macos", "Linux": "linux"}.get(platform.system())
    if architecture is None or operating_system is None:
        raise SystemExit("No verified native component tool artifacts for this host")
    tools = []
    for name, version, prefix, extension in [
        ("wasmtime", pins["wasmtimeVersion"], "wasmtime-v", ".tar.xz"),
        ("wasm-tools", pins["wasmToolsVersion"], "wasm-tools-", ".tar.gz"),
    ]:
        stem = prefix + version + "-" + architecture + "-" + operating_system
        asset = stem + extension
        digest = pins["assets"].get(asset)
        if digest is None:
            raise SystemExit("No independently recorded official SHA-256 pin for " + asset)
        url = "https://github.com/bytecodealliance/" + name + "/releases/download/v" + version + "/" + asset
        archive = root / asset
        total = 0
        with urllib.request.urlopen(url, timeout=120) as response, archive.open("xb") as output:
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > 200 * 1024 * 1024:
                    raise RuntimeError("Component tool archive exceeded the fixture download bound")
                output.write(block)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != digest:
            raise RuntimeError("Official component tool digest mismatch for " + asset)
        with tarfile.open(archive) as package:
            if any(pathlib.PurePosixPath(entry.name).parts[0] != stem for entry in package.getmembers()):
                raise RuntimeError("Unexpected component tool archive root")
            package.extractall(root, filter="data")
        binary = root / stem / name
        version_output = subprocess.check_output([str(binary), "--version"], text=True).strip()
        if version not in version_output:
            raise RuntimeError("Component tool version does not match the pinned release")
        tools.append({"name": name, "url": url, "archiveSHA256": actual, "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                      "version": version_output, "nativeArchitecture": architecture, "os": operating_system})
        with open(os.environ["GITHUB_ENV"], "a") as environment:
            environment.write(("RIGHTCLICK_WASM_RUNTIME" if name == "wasmtime" else "RIGHTCLICK_WASM_TOOLS") + "=" + str(binary) + "\n")
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps({"schemaVersion": 1, "tools": tools}, indent=2) + "\n")


if __name__ == "__main__":
    main()
