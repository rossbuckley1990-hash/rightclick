#!/usr/bin/env python3
"""Exercise real generic setup and doctor repair against supplied executable bytes.

All writable state and reported local paths must stay in a private temporary
HOME. The supplied binary is a read-only input; identical bytes are copied into
that HOME before invocation. JSON evidence goes to stdout. This observes local
stdio and registration behavior, never an AI client handshake or a release.
The independent owner/mode proof currently requires a POSIX host.
Normally exited CLI invocations are reaped for their exit status; that path is
not a blanket adversarial descendant-cleanup proof. Native product containment
has separate acceptance tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

CORE7 = {
    "context_runtime", "context_inspect", "context_actions", "context_explain",
    "context_run", "context_run_status", "context_providers",
}
LIMIT = 1024 * 1024


class Failure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def decode(data: bytes | str):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "JSON contains a duplicate key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


class OwnedHome:
    def __init__(self):
        self.path = Path(tempfile.mkdtemp(prefix="rightclick-setup-lifecycle-")).resolve()
        self.identity = self.path.stat()
        require(stat.S_IMODE(self.identity.st_mode) == 0o700, "Temporary HOME is not private")
        self.aliases = [self.path]
        if sys.platform == "darwin":
            # Foundation may report these system aliases. Admit only aliases
            # which resolve to this exact owned HOME, never arbitrary links.
            for alias, actual in ((Path("/var"), Path("/private/var")),
                                  (Path("/tmp"), Path("/private/tmp"))):
                try:
                    candidate = alias / self.path.relative_to(actual)
                except ValueError:
                    continue
                if candidate.resolve() == self.path:
                    self.aliases.append(candidate)

    def checked(self, raw: str | Path) -> Path:
        path = Path(raw)
        require(path.is_absolute(), "Reported path is not absolute")
        path = Path(os.path.abspath(path))
        relative = None
        for root in self.aliases:
            try:
                relative = path.relative_to(root)
                break
            except ValueError:
                continue
        require(relative is not None, "Reported path escapes the owned temporary HOME")
        path = self.path / relative
        current_root = self.path.lstat()
        require((current_root.st_dev, current_root.st_ino) ==
                (self.identity.st_dev, self.identity.st_ino), "Temporary HOME identity changed")
        require(not stat.S_ISLNK(current_root.st_mode), "Temporary HOME became a symbolic link")
        current = self.path
        for component in path.relative_to(self.path).parts:
            current /= component
            try:
                information = current.lstat()
            except FileNotFoundError:
                continue
            require(not stat.S_ISLNK(information.st_mode), "Owned path contains a symbolic link")
            require(information.st_uid == os.geteuid(), "Owned path has a different owner")
            if stat.S_ISREG(information.st_mode):
                require(information.st_nlink == 1, "Owned path contains a hard-linked file")
        require(os.path.commonpath([str(self.path), str(path.resolve())]) == str(self.path),
                "Resolved path escapes the owned temporary HOME")
        return path

    def mkdir(self, path: Path) -> Path:
        target = self.checked(path)
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
        return self.checked(target)

    def read(self, path: Path, maximum: int = LIMIT) -> bytes:
        target = self.checked(path)
        information = target.lstat()
        require(stat.S_ISREG(information.st_mode) and information.st_nlink == 1,
                "Owned input is not a singly linked regular file")
        require(information.st_size <= maximum, "Owned input exceeds the size bound")
        with target.open("rb") as handle:
            data = handle.read(maximum + 1)
        require(len(data) <= maximum, "Owned input grew past the size bound")
        return data

    def write(self, path: Path, data: bytes, mode: int = 0o600) -> None:
        target = self.checked(path)
        self.mkdir(target.parent)
        target.write_bytes(data)
        os.chmod(self.checked(target), mode)

    def reported(self, value) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key in {"configuration", "configurationPath", "command", "backup",
                           "executablePath", "executableRealPath"} and isinstance(child, str):
                    self.checked(child)
                self.reported(child)
        elif isinstance(value, list):
            for child in value:
                self.reported(child)

    def cleanup(self) -> None:
        def remove(directory):
            for name in os.listdir(self.checked(directory)):
                target = self.checked(directory / name)
                information = target.lstat()
                if stat.S_ISDIR(information.st_mode):
                    remove(target)
                else:
                    require(stat.S_ISREG(information.st_mode), "Refusing an unexpected cleanup file type")
                    self.checked(target).unlink()
            self.checked(directory).rmdir()
        remove(self.path)


class Child:
    def __init__(self, binary: Path, arguments: list[str], environment: dict[str, str], home: OwnedHome):
        self.process = subprocess.Popen([str(home.checked(binary)), *arguments],
            cwd=home.checked(home.path), env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.messages: queue.Queue[bytes | None] = queue.Queue(maxsize=128)
        self.overflow = threading.Event()
        self.stop = threading.Event()
        self.stderr = bytearray()
        self.received = 0
        self.lock = threading.Lock()

        def read(pipe, is_stdout):
            try:
                while not self.stop.is_set():
                    line = pipe.readline(LIMIT + 1)
                    if not line:
                        break
                    with self.lock:
                        self.received += len(line)
                        if self.received > LIMIT:
                            self.overflow.set()
                            break
                        if not is_stdout:
                            self.stderr.extend(line)
                    if is_stdout:
                        while not self.stop.is_set():
                            try:
                                self.messages.put(line, timeout=0.1)
                                break
                            except queue.Full:
                                continue
            finally:
                if is_stdout:
                    while not self.stop.is_set():
                        try:
                            self.messages.put(None, timeout=0.1)
                            break
                        except queue.Full:
                            continue
        self.readers = [threading.Thread(target=read, args=(self.process.stdout, True), daemon=True),
                        threading.Thread(target=read, args=(self.process.stderr, False), daemon=True)]
        for reader in self.readers:
            reader.start()

    def line(self, deadline: float) -> bytes | None:
        while True:
            require(not self.overflow.is_set(), "Child output exceeded the acceptance size bound")
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Child output exceeded the acceptance deadline")
            try:
                return self.messages.get(timeout=min(0.1, remaining))
            except queue.Empty:
                continue

    def send(self, message: dict) -> None:
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def close(self) -> None:
        self.stop.set()
        # Do not poll/reap the direct PID before disposing its initial group.
        # This keeps the group identity tied to this invocation during teardown.
        if self.process.returncode is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=3)
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            pipe.close()
        for reader in self.readers:
            reader.join(timeout=1)
        require(not any(reader.is_alive() for reader in self.readers), "Child reader did not stop")
        require(not self.overflow.is_set(), "Child output exceeded the acceptance size bound")


def run_cli(binary: Path, arguments: list[str], environment: dict[str, str], home: OwnedHome):
    child = Child(binary, arguments, environment, home)
    try:
        child.process.stdin.close()
        deadline = time.monotonic() + 30
        output = bytearray()
        while (line := child.line(deadline)) is not None:
            output.extend(line)
        # Preserve the actual CLI exit status. Its native product descendants
        # have separate containment tests; this already-exited path is not an
        # adversarial process-tree cleanup proof.
        status = child.process.wait(timeout=max(0.01, deadline - time.monotonic()))
        payload = decode(output)
        require(isinstance(payload, dict), "CLI did not return one JSON object")
        home.reported(payload)
        return status, payload
    finally:
        child.close()


def stdio_probe(binary: Path, digest: str, environment: dict[str, str], home: OwnedHome) -> dict:
    child = Child(binary, ["mcp"], environment, home)
    deadline = time.monotonic() + 10
    seen = set()
    def request(identifier, method, params):
        child.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        while True:
            frame = child.line(deadline)
            require(frame is not None, "MCP exited before responding")
            response = decode(frame)
            require(response.get("jsonrpc") == "2.0", "Invalid JSON-RPC response")
            if "id" not in response and isinstance(response.get("method"), str):
                continue
            require(response.get("id") == identifier and identifier not in seen,
                    "MCP returned an unexpected or duplicate response ID")
            seen.add(identifier)
            require("error" not in response and isinstance(response.get("result"), dict), "MCP request failed")
            return response["result"]
    try:
        initialized = request(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "independent-setup-lifecycle", "version": "1"}})
        require(initialized.get("protocolVersion") == "2025-11-25", "MCP protocol differs")
        require(initialized.get("serverInfo", {}).get("name") == "rightclick", "Unexpected MCP server")
        child.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        listing = request(2, "tools/list", {})
        tools = listing.get("tools", [])
        names = [tool.get("name") for tool in tools]
        require(len(names) == 7 and set(names) == CORE7 and "nextCursor" not in listing,
                "MCP did not expose exactly the complete seven Core7 tools")
        call = request(3, "tools/call", {"name": "context_runtime", "arguments": {}})
        content = call.get("content", [])
        require(not call.get("isError") and len(content) == 1 and content[0].get("type") == "text",
                "Runtime attestation was not one successful text result")
        runtime = decode(content[0]["text"])
        home.reported(runtime)
        require(runtime.get("pid") == child.process.pid and runtime.get("transport") == "stdio",
                "Runtime attestation does not belong to the launched stdio child")
        require(runtime.get("executableSHA256") == digest and runtime.get("product") == "RIGHTCLICK",
                "Runtime attestation does not match the supplied bytes")
        require(home.checked(runtime["executablePath"]) == binary
                and home.checked(runtime["executableRealPath"]) == binary,
                "Runtime paths do not match the isolated copied executable")
        require(any(profile.get("id") == "core" and len(profile.get("operations", [])) == 7
                    and set(profile.get("operations", [])) == CORE7
                    for profile in runtime.get("agentABIProfiles", [])), "Runtime Core7 profile differs")
        return {"status": "VERIFIED", "tools": sorted(names), "pid": child.process.pid,
                "executableSHA256": digest, "transport": "stdio", "realAIClient": "NOT_OBSERVED"}
    finally:
        child.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path, help="Built RIGHTCLICK executable; read-only input")
    args = parser.parse_args()
    report = {"acceptance": "generic setup and owned doctor repair", "host": sys.platform,
              "realAIClient": "NOT_OBSERVED", "cases": []}
    home = None
    try:
        require(os.name == "posix", "Independent private owner/mode acceptance currently requires POSIX")
        supplied = args.binary.resolve(strict=True)
        require(supplied.is_file() and os.access(supplied, os.X_OK), "Supplied binary is not executable")
        source = supplied.read_bytes()
        digest = hashlib.sha256(source).hexdigest()
        report["binarySHA256"] = digest
        home = OwnedHome()
        binary = home.path / "bin/rightclick"
        home.write(binary, source, mode=0o700)
        environment = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
        environment.update({"HOME": str(home.path), "CFFIXED_USER_HOME": str(home.path),
            "USERPROFILE": str(home.path), "LOCALAPPDATA": str(home.path / "AppData/Local"),
            "XDG_STATE_HOME": str(home.path / ".local/state"), "XDG_CONFIG_HOME": str(home.path / ".config"),
            "TMPDIR": str(home.mkdir(home.path / "tmp"))})
        config = home.path / "client/mcp.json"
        unrelated = {"command": str(binary), "args": ["--version"]}
        initial = {"mcpServers": {"unrelated": unrelated}, "sentinel": {"preserve": True}}
        home.write(config, (json.dumps(initial, indent=2) + "\n").encode())
        setup = ["setup", "--client", "generic", "--config", str(config), "--yes", "--json"]
        doctor = ["doctor", "--fix", "--json"]
        def record(name, details):
            report["cases"].append({"case": name, "passed": True, "details": details})
        def local_report(payload, both=False):
            for key in (["preflightProbe", "localProbe"] if both else ["localProbe"]):
                value = payload.get(key, "")
                require(value.startswith("VERIFIED:") and "exact Core7" in value
                        and "PID/path/SHA256" in value and "NOT_OBSERVED" in value,
                        "CLI did not report the exact Core7 local identity probe")
            require(payload.get("mcpConnection") in {"NOT_OBSERVED", "NOT_VERIFIED"},
                    "Generic setup claimed an observed AI client handshake")
        def config_value():
            value = decode(home.read(config))
            home.reported(value)
            require(value["mcpServers"]["unrelated"] == unrelated and value["sentinel"] == initial["sentinel"],
                    "Unrelated client configuration changed")
            return value

        record("independent stdio before setup", stdio_probe(binary, digest, environment, home))
        status, applied = run_cli(binary, setup, environment, home)
        require(status == 0 and applied.get("status") == "CONFIGURED"
                and applied.get("configurationChanged") == "true", "Generic setup did not configure the selected file")
        require(home.checked(applied.get("configuration", "")) == config, "Generic setup selected another configuration")
        local_report(applied)
        value = config_value()
        recipe = value["mcpServers"]["rightclick"]
        require(set(recipe) == {"command", "args", "type"} and home.checked(recipe["command"]) == binary
                and recipe["args"] == ["mcp"] and recipe["type"] == "stdio",
                "Generic registration recipe differs")
        record("explicit generic setup preserves unrelated registration", applied)
        record("independent stdio after setup", stdio_probe(binary, digest, environment, home))
        ledger = home.path / ("Library/Application Support/RIGHTCLICK/client-ownership.json"
                            if sys.platform == "darwin" else ".local/state/rightclick/client-ownership.json")
        ownership = decode(home.read(ledger))
        home.reported(ownership)
        require(ownership.get("schemaVersion") == 1 and len(ownership.get("clients", [])) == 1,
                "Ownership ledger contract differs")
        entry = ownership["clients"][0]
        require(entry.get("clientID") == "generic" and home.checked(entry.get("configurationPath", "")) == config
                and home.checked(entry.get("command", "")) == binary and entry.get("arguments") == ["mcp"]
                and entry.get("executableSHA256") == digest, "Ownership does not bind the selected registration and bytes")
        information = home.checked(ledger).stat()
        require(information.st_uid == os.geteuid() and stat.S_IMODE(information.st_mode) == 0o600,
                "Ownership ledger is not private to the current owner")
        record("private ownership ledger binds supplied bytes", {"mode": "0600", "executableSHA256": digest})

        before = (home.read(config), home.read(ledger))
        status, second = run_cli(binary, setup, environment, home)
        require(status == 0 and second.get("status") == "ALREADY_CONFIGURED"
                and second.get("configurationChanged") == "false", "Second setup was not a no-op")
        local_report(second)
        require((home.read(config), home.read(ledger)) == before, "Idempotent setup changed config or ownership bytes")
        record("setup idempotence", second)
        status, noop = run_cli(binary, doctor, environment, home)
        require(status == 0 and noop.get("status") == "REPAIRED" and noop.get("configurationChanged") is False,
                "Already configured doctor repair was not a no-op")
        local_report(noop, both=True)
        require((home.read(config), home.read(ledger)) == before, "No-op doctor changed config or ownership bytes")
        record("doctor no-op with pre/post probes", noop)

        removed = config_value()
        del removed["mcpServers"]["rightclick"]
        home.write(config, (json.dumps(removed, indent=2) + "\n").encode())
        before_dry_run = (home.read(config), home.read(ledger))
        status, preview = run_cli(binary, doctor + ["--dry-run"], environment, home)
        require(status == 0 and preview.get("status") == "DRY_RUN" and preview.get("localProbe") == "NOT_RUN",
                "Doctor dry-run did not remain a preview")
        require((home.read(config), home.read(ledger)) == before_dry_run, "Dry-run changed config or ownership bytes")
        record("dry-run leaves removed registration and ledger bytes untouched", preview)
        status, repaired = run_cli(binary, doctor, environment, home)
        require(status == 0 and repaired.get("status") == "REPAIRED" and repaired.get("configurationChanged") is True,
                "Doctor did not repair the removed owned registration")
        local_report(repaired, both=True)
        require(config_value()["mcpServers"]["rightclick"] == value["mcpServers"]["rightclick"],
                "Doctor repair registered a different recipe")
        require(home.read(ledger) == before_dry_run[1], "Repair changed an unchanged ownership contract")
        record("removed owned registration repaired with pre/post probes", repaired)

        conflicting = config_value()
        conflicting["mcpServers"]["rightclick"] = {"command": str(binary), "args": ["foreign"], "type": "stdio"}
        home.write(config, (json.dumps(conflicting, indent=2) + "\n").encode())
        conflict_before = (home.read(config), home.read(ledger))
        status, refused = run_cli(binary, doctor, environment, home)
        require(status != 0 and refused.get("status") == "FAILED", "Doctor accepted a conflicting newer registration")
        require((home.read(config), home.read(ledger)) == conflict_before, "Doctor overwrote conflicting newer state")
        require(config_value() == conflicting, "Conflict preservation changed unrelated fields")
        record("conflicting newer registration refused and preserved", refused)
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        if home is not None:
            try:
                home.cleanup()
                report["temporaryHomeCleanup"] = "COMPLETED"
            except Exception as error:
                report["passed"] = False
                report["temporaryHomeCleanup"] = "REFUSED"
                report["cleanupError"] = f"{type(error).__name__}: {error}"
        print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
