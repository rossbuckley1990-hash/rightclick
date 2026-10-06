#!/usr/bin/env python3
"""Verify explicit-consent local setup through a real PATH invocation."""

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1]).absolute()

assert binary.is_file(), binary
assert os.access(binary, os.X_OK), binary

with tempfile.TemporaryDirectory(
    prefix="rightclick-setup-acceptance-"
) as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    work = root / "outside-checkout"

    home.mkdir()
    work.mkdir()

    cursor = home / ".cursor"
    cursor.mkdir()

    config = cursor / "mcp.json"

    original = {
        "mcpServers": {
            "unrelated": {
                "command": "/usr/bin/true",
                "args": [],
            }
        },
        "sentinel": {
            "preserve": True,
            "value": "RIGHTCLICK setup acceptance",
        },
    }

    original_bytes = (
        json.dumps(
            original,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode()

    config.write_bytes(original_bytes)

    environment = dict(os.environ)

    environment["PATH"] = (
        str(binary.parent)
        + os.pathsep
        + environment.get("PATH", "")
    )

    environment["HOME"] = str(home)
    environment["CFFIXED_USER_HOME"] = str(home)

    def run(*arguments):
        return subprocess.run(
            [binary.name, "setup", *arguments],
            cwd=work,
            env=environment,
            text=True,
            capture_output=True,
            timeout=60,
        )

    consent = run(
        "--client",
        "cursor",
        "--json",
    )

    assert consent.returncode == 3, (
        consent.returncode,
        consent.stdout,
        consent.stderr,
    )

    consent_payload = json.loads(consent.stdout)

    assert consent_payload["status"] == "CONSENT_REQUIRED"
    assert consent_payload["configurationChanged"] == "false"
    assert consent_payload["mcpConnection"] == "NOT_VERIFIED"
    assert consent_payload["outcomeVerification"] == "NOT_RUN"

    assert config.read_bytes() == original_bytes, (
        "setup changed configuration without explicit consent"
    )

    applied = run(
        "--client",
        "cursor",
        "--yes",
        "--json",
    )

    assert applied.returncode == 0, (
        applied.returncode,
        applied.stdout,
        applied.stderr,
    )

    applied_payload = json.loads(applied.stdout)

    assert applied_payload["status"] == "CONFIGURED"
    assert applied_payload["configurationChanged"] == "true"
    assert applied_payload["localProbe"].startswith("PASS:")

    updated_bytes = config.read_bytes()
    updated = json.loads(updated_bytes)

    entry = updated["mcpServers"]["rightclick"]

    command = pathlib.Path(entry["command"])

    assert command.is_absolute()
    assert command.is_file()
    assert command.resolve() == binary.resolve()

    assert entry["type"] == "stdio"
    assert entry["args"] == ["mcp"]

    assert updated["mcpServers"]["unrelated"] == (
        original["mcpServers"]["unrelated"]
    )

    assert updated["sentinel"] == original["sentinel"]

    mode = stat.S_IMODE(config.stat().st_mode)

    assert mode == 0o600, oct(mode)

    second = run(
        "--client",
        "cursor",
        "--yes",
        "--json",
    )

    assert second.returncode == 0, (
        second.returncode,
        second.stdout,
        second.stderr,
    )

    second_payload = json.loads(second.stdout)

    assert second_payload["status"] == "ALREADY_CONFIGURED"
    assert second_payload["configurationChanged"] == "false"

    assert config.read_bytes() == updated_bytes, (
        "idempotent setup changed configuration bytes"
    )

    disconnected = run(
        "--client",
        "cursor",
        "--disconnect",
        "--yes",
        "--json",
    )

    assert disconnected.returncode == 0, (
        disconnected.returncode,
        disconnected.stdout,
        disconnected.stderr,
    )

    disconnected_payload = json.loads(disconnected.stdout)

    assert disconnected_payload["status"] == "DISCONNECTED"
    assert disconnected_payload["configurationChanged"] == "true"

    final = json.loads(config.read_bytes())

    assert "rightclick" not in final["mcpServers"]

    assert final["mcpServers"]["unrelated"] == (
        original["mcpServers"]["unrelated"]
    )

    assert final["sentinel"] == original["sentinel"]

    print(
        "PASS: local setup requires explicit consent, "
        "writes the PATH-resolved executable, preserves unrelated "
        "configuration, is idempotent, and disconnects cleanly"
    )
