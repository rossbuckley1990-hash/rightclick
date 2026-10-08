"""Compile the existing native C dependency for standalone Core harnesses.

This is test provisioning, not a product backend. The harness links the same
HostFiles.c and public header as SwiftPM; no source is replaced or stubbed.
"""
import hashlib
import json
import pathlib
import subprocess


def host_file_arguments(root: pathlib.Path, work: pathlib.Path,
                        evidence: pathlib.Path) -> tuple[list[str], dict]:
    source = root / "Sources/RightClickHostFiles/HostFiles.c"
    header = root / "Sources/RightClickHostFiles/include/RightClickHostFiles.h"
    module = work / "host-files-module"
    module.mkdir()
    (module / "module.modulemap").write_text(
        "module RightClickHostFiles {\n  header " + json.dumps(str(header)) + "\n  export *\n}\n"
    )
    object_file = work / "HostFiles.o"
    command = ["xcrun", "clang", "-c", str(source), "-I", str(header.parent), "-o", str(object_file)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (evidence / "compile-host-files.txt").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Actual native HostFiles dependency did not compile: " + result.stderr)
    provenance = {
        "source": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (source, header)},
        "objectSHA256": hashlib.sha256(object_file.read_bytes()).hexdigest(),
        "compilerCommand": command,
        "scope": "Existing native C backend compiled and linked; no substitute implementation.",
    }
    return ["-I", str(module), str(object_file)], provenance
