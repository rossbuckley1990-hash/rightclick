#!/usr/bin/env python3
"""Fixture owner only: stop/restart one existing owned broker without replacement.

No provider/runtime process imports this module or obtains Docker authority.
The handshake directory carries no secrets and the controller binds the exact
container ID at start as well as rechecking the existing ownership label.
"""
import argparse
import importlib.util
import json
import os
import pathlib
import signal
import stat
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", type=pathlib.Path, required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 900:
        raise SystemExit("Invalid bounded controller lifetime")
    control = args.control.resolve(strict=True)
    mode = control.stat()
    if mode.st_uid != os.geteuid() or stat.S_IMODE(mode.st_mode) != 0o700:
        raise SystemExit("Controller directory must be owner-private")
    if any(control.iterdir()):
        raise SystemExit("Controller handshake directory must initially be empty")
    spec = importlib.util.spec_from_file_location("rightclick_fixture_lab", pathlib.Path(__file__).with_name("lab.py"))
    lab = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lab)
    if not lab.owned(lab.KAFKA):
        raise SystemExit("No existing owned broker")
    original = json.loads(lab.docker("inspect", lab.KAFKA).stdout)[0]["Id"]
    deadline = time.monotonic() + args.timeout
    stopped = False
    events = []
    def exact_owned():
        if not lab.owned(lab.KAFKA):
            raise RuntimeError("Owned broker disappeared")
        current = json.loads(lab.docker("inspect", lab.KAFKA).stdout)[0]
        if current["Id"] != original:
            raise RuntimeError("Broker was replaced during fixture control")
        return current
    def await_signal(stage):
        path = control / (stage + "-ready")
        while time.monotonic() < deadline:
            exact_owned()
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    current = os.fstat(fd)
                    if not stat.S_ISREG(current.st_mode) or current.st_uid != os.geteuid() or current.st_nlink != 1 or current.st_size > 512:
                        raise RuntimeError("Invalid fixture handshake file")
                    os.read(fd, 513)
                    return
                finally:
                    os.close(fd)
            except FileNotFoundError:
                time.sleep(0.1)
        raise TimeoutError("Fixture controller handshake timed out")
    def complete(stage):
        temporary = control / (stage + ".private")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write("Exact owned broker " + stage + " complete\n")
            output.flush()
            os.fsync(output.fileno())
        temporary.rename(control / (stage + "-done"))
        events.append(stage)
    def interrupted(_number, _frame):
        raise InterruptedError("Fixture controller was stopped")
    signal.signal(signal.SIGTERM, interrupted)
    ready = control / "controller-ready"
    ready.write_text("Existing owned broker bound before product invocation\n")
    ready.chmod(0o600)
    try:
        await_signal("withdraw")
        exact_owned()
        lab.docker("stop", "--time", "5", lab.KAFKA, timeout=20)
        stopped = True
        if exact_owned()["State"]["Running"]:
            raise RuntimeError("Broker did not stop")
        complete("withdraw")
        await_signal("restore")
        exact_owned()
        lab.docker("start", lab.KAFKA, timeout=20)
        stopped = False
        lab.await_ready(lambda: lab.rpk("topic", "list", "--format", "json", identity="publisher"), seconds=35)
        exact_owned()
        complete("restore")
    finally:
        if stopped:
            exact_owned()
            lab.docker("start", lab.KAFKA, timeout=20)
            events.append("cleanup-restored-original")
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps({"schemaVersion": 1, "containerID": original,
            "ownershipLabel": lab.LABEL, "events": events, "replacement": False,
            "providerDockerAuthority": False}, indent=2) + "\n")


if __name__ == "__main__":
    main()
