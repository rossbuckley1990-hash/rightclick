#!/usr/bin/env python3
"""Controlled create-before-write race; private actual-fixture copies only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request

repository = Path(__file__).resolve().parents[3]
fixture = Path(__file__).with_name("port-publication-baseline-fixture.py")
original = fixture.read_text()
old = '(root / (role + "-port")).write_text(str(server.server_address[1])); server.serve_forever()'
replacement = '(root / (role + "-port.pending")).write_text(str(server.server_address[1]))\n(root / (role + "-port.pending")).replace(root / (role + "-port"))\nserver.serve_forever()'
if original.count(old) != 1:
    raise RuntimeError("Exact baseline fixture publication boundary changed")

launcher = r'''
import pathlib, runpy, sys, time
root = pathlib.Path(sys.argv[1])
target = root / sys.argv[2]
original_write = pathlib.Path.write_text
def gated(self, data, *args, **kwargs):
    if self != target:
        return original_write(self, data, *args, **kwargs)
    # Same creation/truncation and buffered write semantics as Path.write_text;
    # force a scheduler pause immediately after open, before any digits exist.
    with self.open("w", encoding="ascii") as opened:
        (root / "publication-opened").touch()
        deadline = time.monotonic() + 5
        while not (root / "release-publication").exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("Controlled publication barrier not released")
            time.sleep(0.005)
        return opened.write(data)
pathlib.Path.write_text = gated
sys.argv = [str(root / "fixture.py"), str(root), "provider"]
runpy.run_path(sys.argv[0], run_name="__main__")
'''

def strict(contents):
    if not contents or len(contents) > 5 or any(x < 48 or x > 57 for x in contents):
        raise ValueError("Not a complete bounded ASCII decimal port")
    port = int(contents)
    if not 1 <= port <= 65535:
        raise ValueError("Port outside valid range")
    return port

observations = []
parent = "/private/tmp" if sys.platform == "darwin" else tempfile.gettempdir()
with tempfile.TemporaryDirectory(prefix="rightclick-port-publication-", dir=parent) as temporary:
    owned = Path(temporary)
    for mode in ["baseline", "atomic-candidate"]:
        root = owned / mode
        root.mkdir(mode=0o700)
        (root / "fixture.py").write_text(original if mode == "baseline" else original.replace(old, replacement))
        port_file = root / "provider-port"
        child = subprocess.Popen([sys.executable, "-c", launcher, str(root), "provider-port" if mode == "baseline" else "provider-port.pending"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            env={"PATH": os.defpath, "HOME": str(root), "CFFIXED_USER_HOME": str(root), "TMPDIR": str(root)})
        try:
            deadline = time.monotonic() + 4
            while not (root / "publication-opened").exists():
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Actual fixture failed before controlled write boundary")
                time.sleep(0.005)
            visible = port_file.exists()
            early = port_file.read_bytes() if visible else None
            # Existing native readiness considers file existence sufficient.
            observation = {"mode": mode, "barrierReached": True,
                "consumerExistencePredicate": visible,
                "visiblePortBytesBeforeWrite": None if early is None else early.decode("ascii"),
                "prematureReady": visible and early == b""}
            (root / "release-publication").touch()
            deadline = time.monotonic() + 3
            while True:
                try:
                    with port_file.open("rb") as recorded:
                        contents = recorded.read(6)
                    port = strict(contents)
                    break
                except (FileNotFoundError, ValueError):
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Fixture never published complete valid port")
                    time.sleep(0.005)
            response = urllib.request.urlopen("http://127.0.0.1:" + str(port) + "/openapi.json", timeout=2)
            document = json.loads(response.read(65536))
            observation.update({"strictConsumerReadyAfterRelease": True, "publishedPort": port,
                "httpStatus": response.status, "providerOperation": document["paths"]["/records"]["post"]["operationId"]})
            observations.append(observation)
        finally:
            if child.poll() is None:
                child.kill()
            _, error = child.communicate(timeout=3)
            if error:
                raise RuntimeError("Fixture stderr: " + error.decode(errors="replace"))

invalid = [b"", b"0", b"65536", b"-1", b"+1", b"1\n", b" 1", b"123456", b"\xff"]
for value in invalid:
    try:
        strict(value)
    except ValueError:
        continue
    raise RuntimeError("Invalid port accepted: " + repr(value))
if not observations[0]["prematureReady"] or observations[1]["consumerExistencePredicate"]:
    raise RuntimeError("Controlled baseline RED / candidate GREEN was not observed")
report = {"scope": "Deterministic actual Python fixture publication-boundary scheduling experiment; no Swift build or observation outcome changes.",
    "causalLimit": "Reproduces a feasible readiness race. Does not establish that this race caused any historical intermittent native test failure.",
    "baselineFixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
    "candidatePublication": replacement, "observations": observations,
    "invalidPortCasesRejected": [repr(x) for x in invalid], "cleanedPrivateTemporaryPaths": True}
output = repository / "evidence/adoption-20261007/qa/port-publication-controlled-red-green.json"
output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
