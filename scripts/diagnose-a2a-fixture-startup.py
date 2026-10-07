#!/usr/bin/env python3
"""Observe actual disposable A2A startup without a runtime build or invocation."""
import argparse
import hashlib
import json
import pathlib
import socket
import sys
import tempfile
import urllib.request

from fixture_startup import FixtureProcesses, FixtureStartupError

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = pathlib.Path(__file__).resolve().parent
report = {"status": "FIXTURE_STARTUP_RED", "pythonVersion": list(sys.version_info[:3]),
    "sourceHashes": {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
        for name in ["fixture_startup.py", "fixture_http.py", "a2a-proof-agent.py", "a2a-proof-observer.py"]},
    "boundary": "Disposable recorded-source fixture startup only; no runtime or external effect acceptance claim."}
with tempfile.TemporaryDirectory(prefix="rightclick-a2a-startup-diagnostic-") as temporary:
    directory = pathlib.Path(temporary)
    with FixtureProcesses(args.output / "fixture-startup.json") as fixtures:
        for label, script, marker in [("agent", "a2a-proof-agent.py", "port"), ("observer", "a2a-proof-observer.py", "observer-port")]:
            fixtures.launch(label, root / script, [str(directory)], directory / marker)
        try:
            agent = fixtures.wait_for_port("agent")
            observer = fixtures.wait_for_port("observer")
            # Actual independent socket/HTTP readiness, beyond a marker file.
            with urllib.request.urlopen("http://127.0.0.1:" + agent + "/.well-known/agent.json", timeout=2) as response:
                assert json.load(response)["protocolVersion"] == "0.2.6"
            with socket.create_connection(("127.0.0.1", int(observer)), timeout=2):
                pass
            report["status"] = "FIXTURE_STARTUP_GREEN"
            report["observerPortPublished"] = bool(observer)
        except FixtureStartupError:
            pass
(args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(report["status"])
raise SystemExit(0 if report["status"] == "FIXTURE_STARTUP_GREEN" else 1)
