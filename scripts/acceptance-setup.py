#!/usr/bin/env python3
"""Verify the real end-user PATH invocation without retaining config changes."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1]).absolute()
assert binary.is_file(), binary
config = pathlib.Path.home() / ".cursor/mcp.json"
original = config.read_bytes() if config.exists() else None
previous = json.loads(original) if original is not None else {}
environment = dict(os.environ, PATH=str(binary.parent) + os.pathsep + os.environ.get("PATH", ""))
try:
    with tempfile.TemporaryDirectory(prefix="rightclick-setup-") as directory:
        process = subprocess.run([binary.name, "setup", "--json"], cwd=directory,
                                 env=environment, text=True, capture_output=True, timeout=60)
        assert process.returncode == 0, process.stderr
        updated = json.loads(config.read_bytes())
        entry = updated["mcpServers"]["rightclick"]
        command = pathlib.Path(entry["command"])
        assert command.is_absolute() and command.is_file(), "setup wrote a nonexistent executable"
        assert command.resolve() == binary.resolve(), "setup selected a different executable"
        assert entry["args"] == ["mcp"], "setup wrote incorrect MCP arguments"
        old_servers = previous.get("mcpServers", {})
        assert {k: v for k, v in updated["mcpServers"].items() if k != "rightclick"} == {
            k: v for k, v in old_servers.items() if k != "rightclick"
        }, "setup changed unrelated servers"
        assert {k: v for k, v in updated.items() if k != "mcpServers"} == {
            k: v for k, v in previous.items() if k != "mcpServers"
        }, "setup changed unrelated configuration"
        print("PASS: setup through PATH outside checkout writes the actual executable and preserves unrelated configuration")
finally:
    if original is None:
        config.unlink(missing_ok=True)
    else:
        config.write_bytes(original)
