"""Bounded disposable-fixture startup and private diagnostics.

Public metadata never contains child stderr or arguments. Real stderr/optional
slow-start stack stays in a separate owner-only temporary directory on POSIX;
Windows retains bounded bytes in memory without claiming private-file ACL proof.
"""
import faulthandler
import ast
import functools
import hashlib
import json
import os
import pathlib
import re
import runpy
import stat
import subprocess
import sys
import sysconfig
import tempfile
import threading
import time

MAX_STDERR = 65_536
MAX_CHILDREN = 16
MAX_STARTUP_SECONDS = 10
MAX_PUBLIC_FRAMES = 32
PUBLIC_EXCEPTION_TYPES = {"ImportError", "ModuleNotFoundError", "OSError", "PermissionError",
    "FileNotFoundError", "ValueError", "RuntimeError", "SyntaxError", "TimeoutError",
    "TypeError", "NameError", "AttributeError", "SystemExit"}

@functools.lru_cache(maxsize=64)
def _standard_library_functions(source):
    try:
        if source.stat().st_size > 2_097_152:
            return set()
        return {node.name for node in ast.walk(ast.parse(source.read_text(encoding="utf-8")))
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    except (OSError, UnicodeError, SyntaxError):
        return set()

def sanitized_stack(prefix):
    """Only known stdlib stack locations and exception classes, never messages."""
    standard_library = pathlib.Path(sysconfig.get_path("stdlib")).resolve()
    frames, exception_types = [], []
    for line in bytes(prefix).decode("utf-8", errors="replace").splitlines():
        match = re.fullmatch(r'\s*File "([^"\r\n]{1,1024})", line ([0-9]{1,7})(?:,)? in ([A-Za-z_][A-Za-z0-9_]{0,63})', line)
        if match and len(frames) < MAX_PUBLIC_FRAMES:
            source = pathlib.Path(match[1])
            try:
                relative = source.resolve().relative_to(standard_library)
            except (OSError, ValueError):
                continue
            # Site packages and arbitrary provider/fixture filenames never
            # enter public diagnostics. Python module basenames are bounded.
            if "site-packages" in relative.parts or "dist-packages" in relative.parts:
                continue
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}\.py", source.name) and match[3] in _standard_library_functions(source.resolve()):
                frames.append({"moduleFile": source.name, "line": int(match[2]), "function": match[3]})
        exception = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]{0,63})(?::.*)?", line)
        if exception and exception[1] in PUBLIC_EXCEPTION_TYPES and exception[1] not in exception_types:
            exception_types.append(exception[1])
    return {"standardLibraryFrames": frames, "exceptionTypes": exception_types,
        "frameLimit": MAX_PUBLIC_FRAMES, "scope": "Observed child stderr metadata; no messages, arguments, source lines or full paths."}

class FixtureStartupError(RuntimeError):
    def __init__(self, label, reason):
        super().__init__(f"fixture {label}: {reason}")

class _Child:
    def __init__(self, label, script, arguments, readiness, private_directory):
        self.label, self.readiness = label, pathlib.Path(readiness)
        self.state, self.exit_at_readiness, self.cleanup = "starting", None, "pending"
        self.started = time.monotonic()
        self.readiness_elapsed = None
        self.stderr_bytes, self.stderr_prefix = 0, bytearray()
        self.stderr_digest, self.lock = hashlib.sha256(), threading.Lock()
        self.private_file = None if private_directory is None else private_directory / (label + ".stderr.private")
        self.process = subprocess.Popen([sys.executable, "-u", str(pathlib.Path(__file__).resolve()),
            "--fixture-child", str(pathlib.Path(script).resolve()), str(self.readiness.resolve()), *arguments],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()

    def _drain(self):
        try:
            while True:
                data = self.process.stderr.read1(4096)
                if not data: break
                with self.lock:
                    self.stderr_bytes += len(data)
                    self.stderr_digest.update(data)
                    self.stderr_prefix.extend(data[:max(0, MAX_STDERR - len(self.stderr_prefix))])
        except (OSError, ValueError):
            pass

    def snapshot(self):
        with self.lock:
            return {"label": self.label, "readiness": self.state,
                "readinessElapsedMilliseconds": self.readiness_elapsed,
                "lifetimeMilliseconds": int((time.monotonic() - self.started) * 1000),
                "exitAtReadiness": self.exit_at_readiness, "cleanup": self.cleanup,
                "finalReturnCode": self.process.poll(), "stderrBytes": self.stderr_bytes,
                "stderrSHA256": self.stderr_digest.hexdigest(),
                "stderrRetainedBytes": len(self.stderr_prefix),
                "stderrTruncated": self.stderr_bytes > MAX_STDERR,
                "sanitizedStack": sanitized_stack(self.stderr_prefix),
                "privateRawStderrPersisted": self.private_file is not None and self.private_file.exists()}

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
                self.cleanup = "terminated"
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=1)
                self.cleanup = "killed"
        else:
            self.cleanup = "already_exited"
        self.reader.join(timeout=1)
        if not self.reader.is_alive(): self.process.stderr.close()
        if self.private_file is not None:
            with self.lock: prefix = bytes(self.stderr_prefix)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(self.private_file, flags, 0o600)
            with os.fdopen(descriptor, "wb") as handle: handle.write(prefix)

class FixtureProcesses:
    def __init__(self, diagnostics_file):
        self.diagnostics_file = pathlib.Path(diagnostics_file)
        self.children = {}
        self.private_directory = None
        if os.name != "nt":
            self.private_directory = pathlib.Path(tempfile.mkdtemp(prefix="rightclick-fixture-stderr-"))
            os.chmod(self.private_directory, 0o700)

    def __enter__(self): return self
    def __exit__(self, *_):
        try:
            for child in reversed(list(self.children.values())): child.close()
        finally:
            self._save()

    def _save(self):
        self.diagnostics_file.write_text(json.dumps({"version": 1,
            "maximumStartupSeconds": MAX_STARTUP_SECONDS,
            "sameInterpreter": True, "pythonVersion": list(sys.version_info[:3]),
            "privateStderr": "SEPARATE_OWNER_ONLY_DIRECTORY" if self.private_directory else "BOUNDED_MEMORY_ONLY",
            "children": [child.snapshot() for child in self.children.values()]}, indent=2) + "\n")

    def launch(self, label, script, arguments, readiness):
        if not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", label) or label in self.children or len(self.children) >= MAX_CHILDREN:
            raise ValueError("invalid bounded fixture label")
        try: child = _Child(label, script, arguments, readiness, self.private_directory)
        except OSError: raise FixtureStartupError(label, "spawn_failed") from None
        self.children[label] = child; self._save()
        return child.process

    def wait_for_port(self, label, timeout=MAX_STARTUP_SECONDS):
        if not 0 < timeout <= MAX_STARTUP_SECONDS: raise ValueError("invalid bounded readiness timeout")
        child = self.children[label]
        deadline = time.monotonic() + timeout
        reason = "readiness_timeout"
        while time.monotonic() < deadline:
            code = child.process.poll()
            if code is not None:
                reason = "child_exited"; child.exit_at_readiness = code; break
            try:
                flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
                descriptor = os.open(child.readiness, flags)
                try:
                    if not stat.S_ISREG(os.fstat(descriptor).st_mode): raise ValueError("invalid readiness")
                    data = os.read(descriptor, 17)
                finally: os.close(descriptor)
                if data:
                    if not re.fullmatch(rb"[0-9]{1,5}\n?", data) or not 1 <= int(data) <= 65535:
                        reason = "invalid_readiness"; break
                    if child.process.poll() is not None:
                        reason = "child_exited"; child.exit_at_readiness = child.process.returncode; break
                    child.state = "ready"
                    child.readiness_elapsed = int((time.monotonic() - child.started) * 1000)
                    self._save(); return str(int(data))
            except FileNotFoundError:
                pass
            except (OSError, ValueError):
                reason = "readiness_read_failed"; break
            time.sleep(min(.01, max(0, deadline - time.monotonic())))
        child.state = reason
        child.readiness_elapsed = int((time.monotonic() - child.started) * 1000)
        self._save()
        raise FixtureStartupError(label, reason)

def _child_main():
    if len(sys.argv) < 4 or sys.argv[1] != "--fixture-child":
        raise SystemExit("fixture_child_usage")
    script, readiness, arguments = sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4:]
    stop = threading.Event()
    # Capture one private stack if startup remains blocked at half the unchanged
    # ten-second bound. Stop the timer once the readiness marker is nonempty.
    faulthandler.dump_traceback_later(5, file=sys.stderr)
    def monitor():
        while not stop.wait(.01):
            try:
                if readiness.stat().st_size:
                    faulthandler.cancel_dump_traceback_later(); return
            except OSError:
                pass
    threading.Thread(target=monitor, daemon=True).start()
    sys.argv = [script, *arguments]
    try: runpy.run_path(script, run_name="__main__")
    finally:
        stop.set(); faulthandler.cancel_dump_traceback_later()

if __name__ == "__main__": _child_main()
