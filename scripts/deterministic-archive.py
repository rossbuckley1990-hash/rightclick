#!/usr/bin/env python3
"""Reproducible archive of the same payload, including signature and ticket.
Separate builds or Apple signing runs need not reproduce the same bytes.
"""
import gzip
import pathlib
import sys
import tarfile

app = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
assert app.is_dir() and app.name == "RIGHTCLICK.app"
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for path in [app, *sorted(app.rglob("*"))]:
                info = archive.gettarinfo(str(path), arcname=str(path.relative_to(app.parent)))
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 1767225600
                info.mode = 0o755 if path.is_dir() or info.mode & 0o111 else 0o644
                if info.isfile():
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
                else:
                    archive.addfile(info)
