#!/usr/bin/env python3
"""Prepare the immutable, reproducible Homebrew source asset and formula.

Only build inputs and their licences are packaged. No checkout, build cache,
personal configuration, credentials, or private evidence enters this asset.
"""
import gzip
import hashlib
import pathlib
import tarfile

root = pathlib.Path(__file__).resolve().parent.parent
version = "0.1.0"
output = root / "dist" / f"rightclick-{version}-source.tar.gz"
inputs = ["Package.swift", "Package.resolved", "LICENSE", "Sources", "Tests",
          "fixtures", "packaging/ThirdPartyLicenses", "scripts/build-cli.sh"]
paths = []
for name in inputs:
    path = root / name
    assert path.exists(), name
    paths.append(path)
    if path.is_dir():
        paths.extend(path.rglob("*"))
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for path in sorted(set(paths)):
                assert not path.is_symlink(), path
                relative = path.relative_to(root)
                assert ".DS_Store" not in relative.parts, relative
                info = archive.gettarinfo(str(path), arcname=f"rightclick-{version}/{relative}")
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 1767225600
                info.mode = 0o755 if path.is_dir() or relative.as_posix() == "scripts/build-cli.sh" else 0o644
                if info.isfile():
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
                else:
                    archive.addfile(info)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
template = (root / "packaging/homebrew/rightclick.rb.in").read_text()
formula = template.replace("@SOURCE_SHA256@", digest)
for name in ["packaging/homebrew/rightclick.rb", "packaging/tap/Formula/rightclick.rb"]:
    (root / name).write_text(formula)
(output.parent / "SHA256SUMS-source").write_text(f"{digest}  {output.name}\n")
print(f"{digest}  {output.name}")
