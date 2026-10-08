#!/usr/bin/env python3
"""Prepare the immutable, reproducible Homebrew source asset and formula.

Only build inputs and their licences are packaged. No checkout, build cache,
personal configuration, credentials, or private evidence enters this asset.
"""
import gzip
import subprocess
import sys
import hashlib
import json
import pathlib
import re
import tarfile
from ci.archive_inputs import tracked_archive_inputs

root = pathlib.Path(__file__).resolve().parent.parent
version = re.search(r'current = "([0-9]+\.[0-9]+\.[0-9]+)"', (root / "Sources/RightClickProviders/ProductSurface.swift").read_text())[1]
output = root / "dist" / f"rightclick-{version}-source.tar.gz"
# Durably record substrate kinds inside the immutable source asset so
# detect-bottle-alignment.py can inventory a published bottle without guessing.
manifest = root / "packaging" / "substrate-kinds.json"
subprocess.check_call(
    [sys.executable, str(root / "scripts" / "detect-bottle-alignment.py"),
     "--write-manifest", str(manifest)],
    cwd=str(root),
)

inputs = ["Package.swift", "Package.resolved", "LICENSE", "Sources", "Tests", "Vendor",
          "fixtures", "packaging/ThirdPartyLicenses", "packaging/substrate-kinds.json",
          "scripts/build-cli.sh", "docs/substrate-contract.json", "docs/reconciliation-baselines",
          "examples/universal-descriptors", "examples/rcir-authority-benchmark"]
# Git supplies allowed names/modes for every directory. Only tracked inputs and
# their working-tree source bytes enter the archive, never generated/private files.
archive_inputs = tracked_archive_inputs(root, inputs)
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for selected in archive_inputs:
                relative = selected.relative
                path = root / relative
                assert not path.is_symlink(), path
                assert ".DS_Store" not in relative.parts, relative
                info = archive.gettarinfo(str(path), arcname=f"rightclick-{version}/{relative}")
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 1767225600
                info.mode = selected.mode
                if info.isfile():
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
                else:
                    archive.addfile(info)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
template = (root / "packaging/homebrew/rightclick.rb.in").read_text()
bottle = root / "packaging/homebrew/bottle.json"
block = ""
if bottle.exists():
    metadata = json.loads(bottle.read_text())
    # Legacy metadata belongs to the immutable 0.1.0 release. Never attach it
    # to a different version or relax its source hash check.
    if metadata.get("version", "0.1.0") == version:
        if metadata["source_sha256"] != digest:
            raise RuntimeError("The published bottle pins different source. Prepare a new version; do not replace the published artifact.")
        block = metadata["dsl"] + "\n"
formula = template.replace("@VERSION@", version).replace("@SOURCE_SHA256@", digest).replace("@BOTTLE_BLOCK@\n", block)
for name in ["packaging/homebrew/rightclick.rb", "packaging/tap/Formula/rightclick.rb"]:
    (root / name).write_text(formula)
(output.parent / "SHA256SUMS-source").write_text(f"{digest}  {output.name}\n")
print(f"{digest}  {output.name}")
