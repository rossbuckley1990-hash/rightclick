#!/usr/bin/env python3
"""Own one genuine MCP SDK server, finite readiness and private effects cleanup."""
import argparse
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("evidence", type=pathlib.Path)
    parser.add_argument("--component", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rightclick-mcp-effects-") as temporary:
        private = pathlib.Path(temporary).resolve()
        private.chmod(0o700)
        effects = private / "effects"
        effects.mkdir(mode=0o700)
        with (private / "provider.stderr").open("wb") as diagnostic:
            provider = subprocess.Popen([sys.executable, "examples/universal-descriptors/mcp-proof-server.py",
                                         "--directory", str(effects)], stdout=subprocess.DEVNULL, stderr=diagnostic)
            try:
                deadline = time.monotonic() + 30
                ready = False
                while time.monotonic() < deadline:
                    if provider.poll() is not None:
                        raise RuntimeError("Official MCP SDK fixture exited before readiness; private stderr withheld")
                    try:
                        with urllib.request.urlopen("http://127.0.0.1:19143/observe/not-ready", timeout=1):
                            ready = True
                    except urllib.error.HTTPError as failure:
                        ready = failure.code == 404
                    except (OSError, urllib.error.URLError):
                        pass
                    if ready:
                        break
                    time.sleep(0.1)
                if not ready:
                    raise RuntimeError("Official MCP SDK fixture exceeded its readiness bound")
                subprocess.run([sys.executable, "scripts/acceptance-capability-interfaces.py", str(args.binary),
                                str(args.evidence / "public"), "--component", str(args.component),
                                "--runtime", os.environ["RIGHTCLICK_WASM_RUNTIME"],
                                "--tools", os.environ["RIGHTCLICK_WASM_TOOLS"], "--mcp-effects", str(effects)],
                               check=True, timeout=420)
            finally:
                if provider.poll() is None:
                    provider.terminate()
                    try:
                        provider.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        provider.kill()
                        provider.wait(timeout=5)


if __name__ == "__main__":
    main()
