#!/usr/bin/env python3
"""A separate local fixture process; not a production provider integration."""
import os
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("Expected a new result path and explicit fixture value")
path = Path(sys.argv[1])
# No overwrite, symlink following, network, credentials or shell invocation.
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as file:
    file.write(sys.argv[2])
    file.flush()
    os.fsync(file.fileno())
