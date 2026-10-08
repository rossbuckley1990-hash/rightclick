#!/usr/bin/env python3
"""Optional acceptance adapter: one writer-owned graph, public evidence only.

This does not grant authority or execute D-Bus directly. The existing restricted
writer UID invokes the canonical coexistence client against the live private bus.
"""
import hashlib
import json
import os
import pathlib
import signal
import stat
import subprocess

WRITER = 1100
CONTROLLED = ("openapi", "graphql", "grpc", "ard", "mcp", "a2a", "wasm")
FAMILIES = (*CONTROLLED, "dbus", "macos", "kafka", "kubernetes")
TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}
VALUES = ["same-client native Linux EchoTags", "literal $(no-shell)",
          "--address=unix:path=/must-not-connect"]
MAX_REPORT = 2 * 1024 * 1024


def manifest(address):
    if not isinstance(address, str) or not address.startswith("unix:path=/") or "\n" in address:
        raise ValueError("Expected the existing private Unix session bus")
    expected = json.dumps(VALUES, separators=(",", ":")).replace("/", "\\/")
    return {"schemaVersion": 1, "runtimeUID": WRITER,
        "environment": {"DBUS_SESSION_BUS_ADDRESS": address}, "rows": {"dbus": {
            "selector": {"idPrefix": "dbus:", "title": "EchoTags", "providerName": "org.rightclick.Pressure"},
            "invoke": {"arguments": {"values": json.dumps(["array", [["string", value] for value in VALUES]])},
                       "expectedOutput": expected},
            "readback": {"type": "returned-text", "expected": expected}, "requireVerified": True,
            "verificationBoundary": "Actual native Linux EchoTags(as)->as; exact independently constructed typed array and returned JSON bytes; no mutated-state or same-graph D-Bus withdrawal claim"
        }}}


def selected_paths(environment):
    names = ("RIGHTCLICK_COEXISTENCE_PYTHON", "RIGHTCLICK_WASM_COMPONENT",
             "RIGHTCLICK_WASM_RUNTIME", "RIGHTCLICK_WASM_TOOLS")
    paths = []
    for name in names:
        raw = environment.get(name)
        if not raw or not pathlib.Path(raw).is_absolute():
            raise ValueError("Required genuine coexistence fixture tool was not selected")
        # Keep the venv Python spelling: resolving its symlink loses pyvenv.cfg.
        path = pathlib.Path(raw).absolute()
        if not path.is_file() or not os.access(path, os.R_OK if name.endswith("COMPONENT") else os.R_OK | os.X_OK):
            raise ValueError("Selected coexistence fixture tool is unavailable")
        paths.append(path)
    return paths


def command(binary, output, repository, configuration, paths):
    python, component, runtime, tools = map(str, paths)
    argv = [python, str(repository / "scripts/acceptance-substrate-coexistence.py"),
        str(binary), str(output), "--repository", str(repository), "--controlled", "--a2a",
        "--graphql-python", python, "--grpc-python", python, "--mcp-python", python,
        "--component", component, "--wasm-runtime", runtime, "--wasm-tools", tools,
        "--manifest", str(configuration)]
    for family in (*CONTROLLED, "dbus"):
        argv += ["--require", family, "--require-verified", family]
        if family in CONTROLLED:
            argv += ["--require-withdrawal", family]
    return argv


def child_environment(repository):
    # No inherited provider credential/configuration, private observer token,
    # root HOME, or ambient D-Bus/RIGHTCLICK authority enters the writer process.
    environment = {"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
        "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory",
        "GIT_CONFIG_VALUE_0": str(repository)}
    for name in ("LANG", "LC_ALL", "LC_CTYPE", "TZ"):
        if name in os.environ:
            environment[name] = os.environ[name]
    return environment


def private_directory(path):
    path.mkdir(mode=0o700)
    os.chown(path, WRITER, WRITER)
    path.chmod(0o700)


def private_file(path, data):
    # Exclusive creation in the already-private parent; no shared names.
    with path.open("xb") as output:
        output.write(data)
    os.chown(path, WRITER, WRITER)
    path.chmod(0o600)


def run_writer(argv, environment, log_path):
    private_file(log_path, b"")
    with log_path.open("ab") as log:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            env=environment, user=WRITER, group=WRITER, extra_groups=[], start_new_session=True)
        try:
            return process.wait(timeout=600)
        finally:
            # The helper has bounded per-fixture cleanup. A timed-out helper or
            # abandoned descendant additionally has one bounded process group.
            for termination in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, termination)
                except ProcessLookupError:
                    break
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    continue
            if process.poll() is None:
                raise TimeoutError("Writer coexistence process did not terminate")


def private_read(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != WRITER or metadata.st_nlink != 1 or metadata.st_mode & 0o077 or metadata.st_size > limit:
            raise ValueError("Unsafe public evidence source")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            data = source.read(limit + 1)
        if len(data) > limit:
            raise ValueError("Public evidence exceeded the bound")
        return data
    finally:
        os.close(descriptor)


def no_private_fields(value):
    forbidden = {"environment", "credentialFile", "signingKeyFile", "signature", "payload", "token", "privateKey"}
    if isinstance(value, dict):
        if forbidden & set(value):
            raise ValueError("Private authority material is not public evidence")
        for item in value.values():
            no_private_fields(item)
    elif isinstance(value, list):
        for item in value:
            no_private_fields(item)


def check_report(report, binary_digest):
    if report.get("status") != "PARTIAL_BOUNDARY_PASS" or report.get("errors") != []:
        raise ValueError("Same-client native Linux coexistence was not proven")
    if report.get("singleClient") is not True or report.get("singleRuntimeProcess") is not True or report.get("clientProcessCount") != 1:
        raise ValueError("Coexistence proof did not retain one client/runtime")
    if set(report.get("canonicalOperations", [])) != TOOLS or len(report.get("canonicalOperations", [])) != 7:
        raise ValueError("Coexistence proof changed the seven canonical operations")
    if report.get("runtimePlatform") != "linux" or report.get("binarySHA256") != binary_digest:
        raise ValueError("Coexistence proof used another platform/runtime")
    if set(report.get("oneGraphSuppliedFamilies", [])) != set((*CONTROLLED, "dbus")):
        raise ValueError("Native D-Bus did not coexist with all seven controlled families")
    rows = report.get("rows", {})
    if set(rows) != set(FAMILIES):
        raise ValueError("Required eleven-row truth inventory is incomplete")
    for family in (*CONTROLLED, "dbus"):
        row = rows[family]
        if any(row.get(field) is not True for field in ("discovered", "executed", "executionNodeVerified", "verified")) or row.get("status") != "VERIFIED" or row.get("platformsTested") != ["linux"]:
            raise ValueError("A required native coexistence row remains unproven")
        if not row.get("independentObservation", {}).get("exactExpectedMatched") or row.get("receipt", {}).get("independentSignatureVerified") is not True or row["receipt"].get("selectedCapabilityMatched") is not True:
            raise ValueError("A coexistence row lost observation or receipt binding")
        if family in CONTROLLED and row.get("liveWithdrawalTested") is not True:
            raise ValueError("Owned controlled acquisition did not withdraw live")
    if rows["dbus"].get("independentObservation", {}).get("kind") != "returned-text":
        raise ValueError("Native EchoTags verification must remain a returned-byte boundary")
    if rows["dbus"].get("liveWithdrawalTested") is not None:
        raise ValueError("This hook cannot claim same-graph D-Bus withdrawal")
    for family in ("macos", "kafka", "kubernetes"):
        if rows[family].get("status") != "UNPROVEN" or any(rows[family].get(field) is not None for field in ("discovered", "executed", "executionNodeVerified", "verified", "liveWithdrawalTested")) or rows[family].get("platformsTested") != []:
            raise ValueError("An absent substrate acquired an unsupported success claim")


def publish(source, destination, forbidden_bytes):
    # Only these two public filenames are read/copied. Logs, configuration,
    # transcripts, bearer tokens and raw receipts remain in writer-private temp.
    data = private_read(source / "results.json", MAX_REPORT)
    if any(secret and secret in data for secret in forbidden_bytes):
        raise ValueError("Private authority material escaped into public results")
    report = json.loads(data)
    no_private_fields(report)
    public_key = None
    if (source / "trusted-public-key.raw").exists():
        public_key = private_read(source / "trusted-public-key.raw", 32)
        if len(public_key) != 32:
            raise ValueError("Invalid public verification key")
    destination.mkdir(mode=0o700)
    (destination / "results.json").write_bytes(data)
    if public_key is not None:
        (destination / "trusted-public-key.raw").write_bytes(public_key)
    return report


def run(binary, writer_state, output, address, token, repository):
    repository, binary = pathlib.Path(repository).resolve(), pathlib.Path(binary).resolve(strict=True)
    paths = selected_paths(os.environ)
    root = pathlib.Path(writer_state) / "coexistence"
    private_directory(root)
    evidence = root / "public"
    private_directory(evidence)
    configuration = root / "dbus-manifest.json"
    private_file(configuration, (json.dumps(manifest(address)) + "\n").encode())
    exit_code = run_writer(command(binary, evidence, repository, configuration, paths), child_environment(repository), root / "helper.log")
    report = publish(evidence, pathlib.Path(output) / "coexistence", (token.encode(), address.encode()))
    if exit_code != 0:
        raise ValueError("Writer coexistence helper failed; public rows retain their actual state")
    check_report(report, hashlib.sha256(binary.read_bytes()).hexdigest())
    return {"status": "PARTIAL_BOUNDARY_PASS", "writerUID": WRITER, "writerGID": WRITER,
        "supplementaryGroups": [], "verifiedFamilies": sorted((*CONTROLLED, "dbus")),
        "unprovenFamilies": ["macos", "kafka", "kubernetes"], "dbusSameGraphWithdrawal": "UNPROVEN",
        "evidence": "coexistence/results.json"}
