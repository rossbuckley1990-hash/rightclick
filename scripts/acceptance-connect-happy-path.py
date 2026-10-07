#!/usr/bin/env python3
"""Blackbox CLI connect -> live Core7 graph gain/withdrawal for supplied bytes.

Uses only an owned temporary HOME and a loopback MCP declaration fixture. This
does not attest an installed AI client, capability effects, clean distribution
installation, or the eleven-world universal release objective.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import tempfile
import time
import uuid


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1_048_576), b""):
            result.update(block)
    return result.hexdigest()


def within(path: Path, root: Path) -> Path:
    if not path.is_absolute():
        raise ValueError("Connection returned a relative configuration path")
    path.relative_to(root)
    selected = path.resolve(strict=True)
    selected.relative_to(root)
    return selected


def isolated_environment(home: Path) -> dict[str, str]:
    # An allowlist avoids importing credentials, provider descriptors, proxies
    # and dynamic-loader configuration from the operator's real environment.
    result = {key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}
    result.update({"PATH": os.defpath, "HOME": str(home), "CFFIXED_USER_HOME": str(home),
        "USERPROFILE": str(home), "LOCALAPPDATA": str(home / "AppData/Local"),
        "XDG_STATE_HOME": str(home / ".local/state"), "XDG_CONFIG_HOME": str(home / ".config"),
        "TMPDIR": str(home / "tmp"), "TMP": str(home / "tmp"), "TEMP": str(home / "tmp")})
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if not stat.S_ISREG(binary.stat().st_mode) or not os.access(binary, os.X_OK):
        parser.error("--binary must select a regular executable")
    scripts = Path(__file__).resolve().parent
    helper = scripts / "acceptance-adoption-security.py"
    fixture_script = scripts / "acceptance-adoption-mcp-fixture.py"
    module_spec = importlib.util.spec_from_file_location("rightclick_adoption_security", helper)
    if module_spec is None or module_spec.loader is None:
        raise RuntimeError("Independent Core7 MCPChild helper is unavailable")
    module = importlib.util.module_from_spec(module_spec)
    sys.dont_write_bytecode = True
    module_spec.loader.exec_module(module)
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    report: dict = {"scope": "Supplied executable; isolated HOME; real CLI connection and same-PID dynamic MCP graph only",
        "status": "FAILED", "startedUTC": datetime.now(timezone.utc).isoformat(),
        "binary": str(binary), "binarySHA256": digest(binary), "platform": platform.system(),
        "architecture": platform.machine(), "scriptSHA256": digest(Path(__file__)),
        "helperSHA256": digest(helper), "fixtureSHA256": digest(fixture_script),
        "realAIClient": "NOT_OBSERVED", "providerExecution": "NOT_RUN", "effectVerification": "NOT_RUN",
        "cleanReleaseInstall": "NOT_RUN", "elevenWorldProof": "NOT_RUN", "phases": []}
    started = time.monotonic()
    child = None
    fixture = None

    def phase(name: str, began: float, details: dict) -> None:
        report["phases"].append({"phase": name, "elapsedSeconds": round(time.monotonic() - began, 3), **details})

    def shutdown() -> None:
        # Called before TemporaryDirectory leaves scope, so the retained runtime
        # cannot recreate its HOME after the owned tree has been removed.
        nonlocal child, fixture
        for name, process in (("runtime", child), ("fixture", fixture)):
            if process is None:
                continue
            try:
                if name == "runtime":
                    process.close()
                elif process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
            except Exception as error:
                report.setdefault("cleanupErrors", []).append({"process": name, "error": str(error)[:2048]})
                report["status"] = "FAILED"
        child = None
        fixture = None

    try:
        with ExitStack() as resources:
            temporary_parent = "/private/tmp" if sys.platform == "darwin" else str(Path(tempfile.gettempdir()).resolve(strict=True))
            temporary = resources.enter_context(tempfile.TemporaryDirectory(prefix="rightclick-connect-live-", dir=temporary_parent))
            resources.callback(shutdown)
            home = Path(temporary).resolve(strict=True)
            (home / "tmp").mkdir(mode=0o700)
            fixture_directory = home / "fixture"
            fixture_directory.mkdir(mode=0o700)
            environment = isolated_environment(home)
            identifier = "adoption-live-" + uuid.uuid4().hex[:16]
            reflector_id = "mcp:" + identifier
            action_id = reflector_id + ":echo"
            challenge = "RIGHTCLICK declaration discovery " + identifier
            report["isolatedHome"] = str(home)
            began = time.monotonic()
            fixture = subprocess.Popen([sys.executable, str(fixture_script), str(fixture_directory), "owned-fixture-cookie"],
                env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            port_file = fixture_directory / "port"
            readiness = time.monotonic() + 5
            while not port_file.is_file() and fixture.poll() is None and time.monotonic() < readiness:
                time.sleep(0.02)
            port = int(port_file.read_text())
            assert 1 <= port <= 65535, "Fixture did not publish a valid loopback port"
            endpoint = f"http://127.0.0.1:{port}/mcp"
            phase("loopback declaration fixture ready", began, {"endpoint": endpoint, "fixturePID": fixture.pid})

            # Start before connection to prove live graph gain as well as loss.
            child = module.MCPChild(binary, environment)
            child.initialize()

            def tools() -> dict:
                result = child.request("tools/list")
                rows = result["tools"]
                names = [row["name"] for row in rows]
                assert len(names) == 7 and set(names) == module.CORE7, "Runtime changed its Core7 surface"
                assert result.get("nextCursor") is None, "Core7 catalogue unexpectedly paginated"
                return {"names": names, "schemaSHA256": hashlib.sha256(
                    json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}

            def runtime() -> dict:
                value = child.runtime()
                assert value["pid"] == child.process.pid, "Runtime PID differs from actual stdio child"
                assert value["executableSHA256"] == report["binarySHA256"], "Runtime attested different executable bytes"
                assert Path(value["executableRealPath"]).resolve(strict=True) == binary, "Runtime attested another executable"
                assert value["transport"] == "stdio", "Runtime attested another transport"
                return value

            def acquired() -> list[dict]:
                actions = child.tool("context_actions", {"item": challenge})["actions"]
                return [row for row in actions if row["id"].startswith(reflector_id + ":")]

            began = time.monotonic()
            catalogue_before = tools()
            runtime_before = runtime()
            assert acquired() == [], "Owned declaration unexpectedly existed before CLI connection"
            phase("real stdio Core7 baseline", began, {"pid": child.process.pid, "catalogue": catalogue_before,
                "runtime": runtime_before, "ownedCapabilities": 0})

            began = time.monotonic()
            connected = subprocess.run([str(binary), "connect", endpoint, "--id", identifier, "--json"],
                env=environment, capture_output=True, text=True, timeout=20)
            assert connected.returncode == 0, "CLI connection failed: " + connected.stdout[:4096]
            assert len(connected.stdout) <= 65_536, "Connection report exceeds its evidence bound"
            result = json.loads(connected.stdout)
            assert result["status"] == "CONNECTED" and result["id"] == identifier and result["kind"] == "mcp", result
            assert result["credentialStored"] is False and result["execution"] == "NOT_RUN", result
            # Prove confinement BEFORE reading, changing or unlinking the
            # returned path. Never repair or delete a default host registry.
            configuration = within(Path(result["configuration"]), home)
            assert configuration.name == "capability-providers.json" and configuration.parent.name == "Connections"
            information = configuration.lstat()
            assert stat.S_ISREG(information.st_mode) and information.st_nlink == 1
            if os.name != "nt":
                assert information.st_uid == os.geteuid() and information.st_mode & 0o077 == 0
                assert configuration.parent.stat().st_mode & 0o077 == 0
            registry_bytes = configuration.read_bytes()
            registry = json.loads(registry_bytes)
            assert registry == {"schemaVersion": 1, "providers": [{"id": identifier, "kind": "mcp", "endpointURL": endpoint}]}, registry
            registry_hash = hashlib.sha256(registry_bytes).hexdigest()
            phase("actual CLI connect persisted only owned declaration", began,
                {"configuration": str(configuration), "registrySHA256": registry_hash, "result": result})

            began = time.monotonic()
            gain_deadline = time.monotonic() + 25
            rows: list[dict] = []
            while time.monotonic() < gain_deadline:
                rows = acquired()
                if rows:
                    break
                time.sleep(0.1)
            assert len(rows) == 1 and rows[0]["id"] == action_id, "Persisted declaration never entered the live Core7 graph"
            explained = child.tool("context_explain", {"item": challenge, "actionId": action_id})
            assert explained["reflectorID"] == reflector_id
            assert explained["metadata"]["interfaceKind"] == "mcp"
            assert explained["metadata"]["descriptorSource"] == endpoint
            assert explained["metadata"]["operationName"] == "echo"
            providers = child.tool("context_providers", {})
            assert any(row["name"] == identifier for row in providers), "Owned provider is absent from context_providers"
            assert runtime()["pid"] == runtime_before["pid"]
            assert tools() == catalogue_before, "Connecting a provider changed the Core7 tool schemas"
            phase("live descriptor gain in unchanged stdio process", began,
                {"pid": child.process.pid, "capability": rows[0], "explanation": explained})

            began = time.monotonic()
            # Remove exclusively the validated registry we created. Refuse any
            # concurrently changed path or bytes rather than touching them.
            assert within(configuration, home) == configuration
            current = configuration.lstat()
            assert stat.S_ISREG(current.st_mode) and current.st_nlink == 1
            assert (current.st_dev, current.st_ino) == (information.st_dev, information.st_ino)
            assert digest(configuration) == registry_hash, "Registry changed after its owned connection; preserved"
            configuration.unlink()
            loss_deadline = time.monotonic() + 25
            while time.monotonic() < loss_deadline:
                if not acquired():
                    break
                time.sleep(0.1)
            assert acquired() == [], "Owned provider survived removal in the retained runtime"
            assert not any(row["name"] == identifier for row in child.tool("context_providers", {}))
            assert runtime()["pid"] == runtime_before["pid"]
            assert tools() == catalogue_before, "Withdrawing a provider changed the Core7 tool schemas"
            phase("owned registry removal withdraws graph in same PID", began,
                {"pid": child.process.pid, "ownedCapabilities": 0, "catalogue": catalogue_before})

            requests = [json.loads(line) for line in (fixture_directory / "requests.jsonl").read_text().splitlines()]
            assert len(requests) >= 6, "CLI and retained runtime did not both negotiate real MCP declarations"
            assert all(row["method"] in {"initialize", "notifications/initialized", "tools/list"} for row in requests), "Acceptance unexpectedly invoked a provider effect"
            assert all(not row["cookiePresent"] and not row["authorizationPresent"] for row in requests)
            report["fixtureRequests"] = requests
            report["sevenOperationsUnchanged"] = True
            report["sameRuntimePID"] = child.process.pid
            report["status"] = "PASSED"
    except Exception as error:
        report["status"] = "FAILED"
        report["error"] = str(error)[:8192]
    finally:
        shutdown()
        report["elapsedSeconds"] = round(time.monotonic() - started, 3)
        report["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        try:
            report["binaryUnchanged"] = digest(binary) == report["binarySHA256"]
        except OSError as error:
            report["binaryUnchanged"] = False
            report["binaryReadError"] = str(error)[:2048]
        if not report["binaryUnchanged"]:
            report["status"] = "FAILED"
        (evidence / "connect-acceptance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    return 0 if report["status"] == "PASSED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
