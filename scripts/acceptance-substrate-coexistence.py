#!/usr/bin/env python3
"""One restricted client, one live RIGHTCLICK graph, independently reported rows.

Manifest inputs are trusted fixture-owner configuration, never model tools.
Missing optional infrastructure remains UNPROVEN. Required supplied fixtures
must be discovered/executed; verification and withdrawal are separate gates.
Raw runtime responses and private authority references remain in private scratch.
"""
import argparse
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import re
import subprocess
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid

FAMILIES = ("macos", "openapi", "graphql", "grpc", "ard", "mcp", "a2a", "kafka", "kubernetes", "wasm", "dbus")
ENVIRONMENT_KEYS = {"RIGHTCLICK_WASM_RUNTIME", "RIGHTCLICK_WASM_TOOLS", "RIGHTCLICK_KAFKA_CLIENT",
    "RIGHTCLICK_KAFKA_PUBLISHER_CONFIG", "RIGHTCLICK_KAFKA_OBSERVER_CONFIG", "RIGHTCLICK_KUBERNETES_CLIENT",
    "RIGHTCLICK_KUBERNETES_WRITER_CONFIG", "RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG", "RIGHTCLICK_KUBERNETES_NAMESPACE",
    "DBUS_SESSION_BUS_ADDRESS", "RIGHTCLICK_DBUS_INVOCATION_ARGUMENT"}


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source_content_digest(repository):
    paths = subprocess.check_output(["git", "-C", str(repository), "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
    digest = hashlib.sha256()
    count = 0
    for encoded in sorted(set(paths.split(b"\x00")) - {b""}):
        relative = encoded.decode()
        if not (relative.startswith(("Sources/", "Tests/", "scripts/", "docs/reconciliation-baselines/")) or relative in {"Package.swift", "Package.resolved", "docs/substrate-contract.json"}):
            continue
        path = repository / relative
        if not path.exists():
            continue
        if path.is_symlink():
            raise ValueError("Source provenance must not silently follow an external reference")
        with path.open("rb") as stream:
            data = stream.read(2_097_153)
        if len(data) > 2_097_152:
            raise ValueError("Source provenance input exceeded its bound")
        digest.update(encoded + b"\x00" + hashlib.sha256(data).digest())
        count += 1
    return {"algorithm": "sha256/path-nul-filehash-v1", "sha256": digest.hexdigest(), "fileCount": count,
            "scope": "Sources, Tests, scripts, manifests and reconciliation gates; tracked and untracked nonignored inputs"}


def private_json(path, value):
    data = json.dumps(value, sort_keys=True).encode()
    if len(data) > 262144:
        raise ValueError("Private proof configuration exceeded its bound")
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".pending-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        pathlib.Path(temporary).replace(path)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)


def close_client(client):
    """Same canonical client, bounded ownership cleanup and private transcript."""
    (client.output / "transcript.json").write_text(json.dumps(client.transcript, indent=2))
    try:
        if client.process.poll() is None:
            client.process.terminate()
            try:
                client.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.process.kill()
                client.process.wait(timeout=5)
    finally:
        for stream in [client.process.stdin, client.process.stdout, client.stderr]:
            if stream:
                stream.close()


def substitute(value, bindings):
    if isinstance(value, str):
        for key, replacement in bindings.items():
            token = "${" + key + "}"
            if value == token:
                return replacement
            value = value.replace(token, str(replacement))
        return value
    if isinstance(value, list):
        return [substitute(child, bindings) for child in value]
    if isinstance(value, dict):
        return {key: substitute(child, bindings) for key, child in value.items()}
    return value


def fnv32(value):
    result = 2166136261
    for byte in value.encode():
        result = ((result ^ byte) * 16777619) & 0xffffffff
    return str(result)


def fresh_bindings():
    nonce = uuid.uuid4().hex
    return {"nonce": nonce, "value": "crossgraph-" + nonce, "name": "crossgraph-" + nonce,
            "fnv": fnv32(nonce), "sha256Value": sha(("crossgraph-" + nonce).encode())}


def result_bindings(bound, result):
    result = dict(result)
    rcir = result.get("rcir") or {}
    updated = dict(bound, executionID=result.get("executionId"), taskID=rcir.get("taskID"), leaseID=rcir.get("leaseID"))
    output = result.get("output")
    if isinstance(output, str):
        try:
            acknowledgement = json.loads(output)
        except (ValueError, TypeError):
            acknowledgement = None
        if isinstance(acknowledgement, dict):
            # Only exact invocation coordinates, never arbitrary environment
            # variables or credential-bearing provider output, become bindings.
            for key in ("topic", "partition", "offset"):
                if key in acknowledgement:
                    updated[key] = acknowledgement[key]
    return updated


def matches(action, selector):
    # Select only the public CapabilityView. Internal metadata is intentionally
    # absent from the seven-operation API and must not become a fallback.
    if not selector or set(selector) - {"id", "idPrefix", "idSuffix", "title", "providerName"} or not ({"id", "idPrefix"} & set(selector)):
        return False
    if "id" in selector and action.get("id") != selector["id"]:
        return False
    if "idPrefix" in selector and not action.get("id", "").startswith(selector["idPrefix"]):
        return False
    if "idSuffix" in selector and not action.get("id", "").endswith(selector["idSuffix"]):
        return False
    if "title" in selector and action.get("title") != selector["title"]:
        return False
    if "providerName" in selector and (action.get("provider") or {}).get("name") != selector["providerName"]:
        return False
    return True


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def read_http(url, credential_file=None, trusted_origin=None, task_id=None):
    headers = {}
    if credential_file:
        parsed, origin = urllib.parse.urlsplit(url), urllib.parse.urlsplit(trusted_origin or "")
        if (parsed.scheme, parsed.netloc) != (origin.scheme, origin.netloc) or origin.path or origin.query or origin.fragment or parsed.username or parsed.password:
            raise ValueError("Protected observer reference is not pinned to its exact origin")
        if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}):
            raise ValueError("Protected observer credentials require TLS or explicit loopback fixture")
        descriptor = os.open(credential_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o777 not in {0o600, 0o400}:
                raise ValueError("Observer credential reference is not private and owned by this execution principal")
            token = os.read(descriptor, 4097).decode().strip()
            if not token or len(token.encode()) > 4096 or "\r" in token or "\n" in token:
                raise ValueError("Invalid bounded observer token")
            headers["Authorization"] = "Bearer " + token
        finally:
            os.close(descriptor)
    if task_id:
        headers["X-RightClick-Invocation"] = str(task_id)
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=3) as response:
            data = response.read(131073)
            if len(data) > 131072:
                raise ValueError("Independent proof observation exceeded its bound")
            return data
    except urllib.error.HTTPError as error:
        error.close()
        raise


def compare_json_fields(data, fields):
    value = json.loads(data)
    if isinstance(fields, dict):
        fields = [{"path": path.split("."), "expected": expected} for path, expected in fields.items()]
    if not isinstance(fields, list) or not 0 < len(fields) <= 16:
        raise ValueError("Independent JSON field constraints must be bounded")
    for field in fields:
        current = value
        if not isinstance(field["path"], list) or not 0 < len(field["path"]) <= 16:
            raise ValueError("Independent field path exceeded its bound")
        for component in field["path"]:
            current = current[int(component)] if isinstance(current, list) else current[component]
        if current != field["expected"]:
            raise ValueError("Native observer contradicted exact desired fields")


@contextlib.contextmanager
def isolated_authority_environment():
    removed = {key: value for key, value in os.environ.items() if key.startswith("RIGHTCLICK_") or key == "DBUS_SESSION_BUS_ADDRESS"}
    try:
        for key in removed:
            del os.environ[key]
        yield
    finally:
        os.environ.update(removed)


class Processes:
    def __init__(self, private):
        self.private = private
        self.children = {}
        self.diagnostics = []
    def start(self, label, command, marker, health=False):
        if label in self.children:
            raise ValueError("Duplicate owned fixture")
        descriptor = os.open(self.private / (label + ".stderr"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        diagnostic = os.fdopen(descriptor, "wb")
        try:
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=diagnostic)
        except Exception:
            diagnostic.close()
            raise
        self.children[label] = (process, diagnostic)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("Owned fixture " + label + " exited before readiness; private diagnostics withheld")
            if marker.exists():
                raw = marker.read_bytes()
                if len(raw) > 16 or not re.fullmatch(rb"[0-9]{1,5}\n?", raw) or not 0 < int(raw) <= 65535:
                    raise ValueError("Invalid owned fixture readiness")
                port = str(int(raw))
                if health:
                    try:
                        read_http("http://127.0.0.1:" + port + "/health")
                    except (OSError, urllib.error.URLError):
                        time.sleep(0.02)
                        continue
                self.diagnostics.append({"fixture": label, "ready": True})
                return port
            time.sleep(0.02)
        raise TimeoutError("Owned fixture " + label + " exceeded readiness deadline")
    def stop(self, label):
        process, _ = self.children[label]
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    def close(self):
        errors = []
        for label in reversed(self.children):
            try:
                self.stop(label)
            except Exception as error:
                errors.append(type(error).__name__)
            finally:
                self.children[label][1].close()
        if errors:
            raise RuntimeError("Owned fixture cleanup failed")


def controlled_fixtures(args, private, processes):
    fixture = pathlib.Path(__file__).with_name("coexistence-fixture.py")
    http = processes.start("http", [args.graphql_python, str(fixture), str(private), "http"], private / "http-port", True)
    observer = processes.start("observer", [sys.executable, str(fixture), str(private), "observer"], private / "observer-port", True)
    grpc = processes.start("grpc", [args.grpc_python, str(fixture), str(private), "grpc"], private / "grpc-port")
    base = "http://127.0.0.1:" + http
    observe = "http://127.0.0.1:" + observer
    rows = {}
    for family in ["openapi", "graphql", "grpc", "ard"]:
        rows[family] = {
            "invoke": {"arguments": {"challenge": "${nonce}", "value": "${value}"}},
            "observer": {"urlTemplate": observe + "/observe/" + family + "/{challenge}",
                         "trustedOrigin": observe, "expectedArgument": "value"},
            "readback": {"type": "http-text", "url": observe + "/observe/" + family + "/${nonce}", "expected": "${value}"},
            "requireVerified": True, "testPolicyAndConfirmation": True,
            "verificationBoundary": "Separate observer process reads exact fresh-challenge file; public loopback fixture, same OS principal",
            "withdrawal": {"type": "owned-marker", "marker": "withdraw-" + family}}
    rows["openapi"]["selector"] = {"idPrefix": "openapi:", "idSuffix": ":storeOpenapi", "title": "Store disposable openapi proof", "providerName": "Coexistence openapi"}
    rows["graphql"]["selector"] = {"idPrefix": "graphql:", "idSuffix": ":storeProof", "title": "GraphQL mutation: storeProof", "providerName": "GraphQL provider"}
    rows["grpc"]["selector"] = {"idPrefix": "grpc:", "idSuffix": ":rightclick.coexistence.Proof.Store", "title": "gRPC rightclick.coexistence.Proof/Store", "providerName": "gRPC 127.0.0.1:" + grpc}
    rows["grpc"]["withdrawal"] = {"type": "owned-process", "label": "grpc"}
    rows["ard"]["selector"] = {"idPrefix": "ard:coexistence-registry:openapi:", "idSuffix": ":storeArd", "title": "Store disposable ard proof", "providerName": "Coexistence ard"}
    artifacts = [{"id": "coexistence-openapi", "kind": "openapi", "baseURL": base, "specificationURL": base + "/openapi.json"},
                 {"id": "coexistence-graphql", "kind": "graphql", "endpointURL": base + "/graphql"},
                 {"id": "coexistence-grpc", "kind": "grpc", "endpointURL": "grpc://127.0.0.1:" + grpc}]
    return {"artifacts": artifacts, "rows": rows,
            "ardRegistries": [{"id": "coexistence-registry", "searchURL": base + "/ard/search"}]}, observe


def add_owned_mcp(manifest, args, private, processes, observer):
    port = processes.start("mcp", [args.mcp_python, str(pathlib.Path(__file__).with_name("coexistence-fixture.py")),
        str(private), "mcp"], private / "mcp-port", True)
    manifest["artifacts"].append({"id": "coexistence-mcp", "kind": "mcp", "endpointURL": "http://127.0.0.1:" + port + "/mcp"})
    manifest["rows"]["mcp"] = {"selector": {"id": "mcp:coexistence-mcp:record_challenge"},
        "invoke": {"arguments": {"challenge": "${nonce}"}}, "requireVerified": True, "testPolicyAndConfirmation": True,
        "observer": {"urlTemplate": observer + "/observe/mcp/{challenge}", "trustedOrigin": observer, "expectedArgument": "challenge"},
        "readback": {"type": "http-text", "url": observer + "/observe/mcp/${nonce}", "expected": "${nonce}"},
        "verificationBoundary": "Official MCP SDK dispatch with independent observer process/file; ACK is not verification",
        "withdrawal": {"type": "owned-marker", "marker": "withdraw-mcp"}}


def add_owned_a2a(manifest, args, private, processes):
    directory = private / "a2a"
    directory.mkdir(mode=0o700)
    scripts = args.repository / "scripts"
    agent = processes.start("a2a-agent", [sys.executable, str(scripts / "a2a-proof-agent.py"), str(directory), "--hold-until-file"], directory / "port")
    observer = processes.start("a2a-observer", [sys.executable, str(scripts / "a2a-proof-observer.py"), str(directory)], directory / "observer-port")
    origin = "http://127.0.0.1:" + observer
    manifest.setdefault("a2aAgentCards", []).append("http://127.0.0.1:" + agent + "/.well-known/agent.json")
    message = json.dumps({"challenge": "${nonce}", "value": "${value}"}, sort_keys=True, separators=(",", ":"))
    endpoint = "http://127.0.0.1:" + agent + "/a2a"
    manifest["rows"]["a2a"] = {"selector": {"id": "a2a:" + sha(endpoint.encode()) + ":delegate", "title": "Delegate a task to RIGHTCLICK disposable delegated agent", "providerName": "RIGHTCLICK disposable delegated agent"},
        "invoke": {"arguments": {"message": message}}, "requireVerified": True, "testPolicyAndConfirmation": True,
        "observer": {"urlTemplate": origin + "/observations/{message}", "trustedOrigin": origin, "expectedArgument": "message"},
        "readback": {"type": "owned-file", "relative": "a2a/effects/${nonce}", "expected": message},
        "release": "a2a/release", "requirePendingInitially": True,
        "verificationBoundary": "Real A2A deferred task plus independent observer process/file; original execution ID polled",
        "withdrawal": {"type": "owned-process", "label": "a2a-agent"}}


def add_owned_wasm(manifest, args, private):
    source = args.component.resolve(strict=True)
    component = private / "fingerprint.component.wasm"
    component.write_bytes(source.read_bytes())
    component.chmod(0o600)
    manifest["artifacts"].append({"id": "coexistence-wasm", "kind": "wasm", "specificationURL": component.as_uri()})
    manifest["environment"].update(RIGHTCLICK_WASM_RUNTIME=str(args.wasm_runtime.resolve(strict=True)),
                                   RIGHTCLICK_WASM_TOOLS=str(args.wasm_tools.resolve(strict=True)))
    manifest["rows"]["wasm"] = {"selector": {"id": "wasm:coexistence-wasm:challenge-fingerprint"},
        "invoke": {"arguments": {"challenge": "${nonce}"}, "expectedOutput": "${fnv}"},
        "requireVerified": True, "verificationBoundary": "Exact returned scalar compared with independent Python FNV-1a32; no external-state claim",
        "readback": {"type": "returned-text", "expected": "${fnv}"},
        "withdrawal": {"type": "owned-reference", "relative": "fingerprint.component.wasm"}}


def independent_read(spec, result, private, bindings):
    selected = substitute(spec, bindings)
    kind = selected["type"]
    if kind in {"http-text", "http-json"}:
        data = read_http(selected["url"], selected.get("credentialFile"), selected.get("trustedOrigin"), bindings.get("taskID"))
        if kind == "http-json":
            compare_json_fields(data, selected["fields"])
        elif data.decode() != selected["expected"]:
            raise ValueError("Independent HTTP observation contradicted the exact expected fixture state")
    elif kind == "owned-file":
        path = (private / selected["relative"]).resolve()
        if not path.is_relative_to(private):
            raise ValueError("Owned fixture readback escaped private scratch")
        data = path.read_bytes()
        if data.decode() != selected["expected"]:
            raise ValueError("Independent fixture file contradicted expected state")
    elif kind == "returned-text":
        data = result.get("output", "").encode()
        if data.decode() != selected["expected"]:
            raise ValueError("Actual component scalar contradicted the independently computed algorithm")
    elif kind == "command-json":
        if not isinstance(selected.get("command"), list):
            raise ValueError("Native observer argv must be an explicit array")
        command = [str(argument) for argument in selected["command"]]
        if not command or not pathlib.Path(command[0]).is_absolute():
            raise ValueError("Independent observer command must select one exact native executable")
        completed = subprocess.run(command, check=True, capture_output=True, timeout=10)
        data = completed.stdout
        if len(data) > 131072:
            raise ValueError("Native observer output exceeded the fixture bound")
        compare_json_fields(data, selected["fields"])
    else:
        raise ValueError("Unsupported independent readback fixture kind")
    return {"kind": kind, "exactExpectedMatched": True, "observationSHA256": sha(data)}


def absence_read(spec, private, bindings, result=None):
    selected = substitute(spec, bindings)
    if selected["type"] in {"http-text", "http-json"}:
        try:
            read_http(selected["url"], selected.get("credentialFile"), selected.get("trustedOrigin"))
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return
            raise
        raise ValueError("Denied/withdrawn invocation produced an independently readable effect")
    if selected["type"] == "owned-file":
        path = (private / selected["relative"]).resolve()
        if not path.is_relative_to(private) or path.exists():
            raise ValueError("Denied/withdrawn invocation produced a private fixture file")
    elif selected["type"] == "returned-text":
        if result and (result.get("output") is not None or result.get("rcir", {}).get("leaseConsumed")):
            raise ValueError("Withdrawn component still established invocation or output")
    else:
        raise ValueError("No independent absence control provided for this withdrawal kind")


def withdraw(spec, private, processes):
    if spec["type"] == "owned-marker":
        marker = spec["marker"]
        if not re.fullmatch(r"withdraw-[a-z]+", marker):
            raise ValueError("Invalid owned fixture withdrawal marker")
        (private / marker).write_text("withdraw\n")
    elif spec["type"] == "owned-process":
        processes.stop(spec["label"])
    elif spec["type"] == "owned-reference":
        path = (private / spec["relative"]).resolve(strict=True)
        if not path.is_relative_to(private):
            raise ValueError("Withdrawal escaped owned private scratch")
        path.rename(path.with_suffix(".withdrawn"))
    else:
        raise ValueError("External withdrawal requires its separately owned fixture controller; no admin command is accepted")


def checked_manifest(value):
    if not isinstance(value, dict) or value.get("schemaVersion", 1) != 1:
        raise ValueError("Unsupported coexistence fixture manifest")
    allowed = {"schemaVersion", "environment", "artifacts", "rows", "a2aAgentCards", "ardRegistries", "runtimeUID"}
    if set(value) - allowed or set(value.get("environment", {})) - ENVIRONMENT_KEYS or set(value.get("rows", {})) - set(FAMILIES):
        raise ValueError("Unsupported fixture input or authority environment key")
    if len(value.get("artifacts", [])) > 32 or len(value.get("rows", {})) > 11:
        raise ValueError("Too many coexistence fixtures")
    if "runtimeUID" in value and value["runtimeUID"] != os.geteuid():
        raise ValueError("Proof must run as the already provisioned execution principal; no UID/authority widening")
    for row in value.get("rows", {}).values():
        if not isinstance(row, dict) or not isinstance(row.get("selector"), dict) or not row["selector"]:
            raise ValueError("A supplied fixture must bind an explicit capability selector")
        if not isinstance(row.get("invoke", {}), dict):
            raise ValueError("Fixture invocation must select structured generic arguments")
    if any(not isinstance(value, str) for value in value.get("environment", {}).values()):
        raise ValueError("Fixture authority environment must contain exact string references")
    return value


def call_allow_error(client, name, arguments):
    if name not in client.canonical_names:
        raise ValueError("Noncanonical tool invocation forbidden")
    raw = client.request("tools/call", {"name": name, "arguments": arguments})
    return {"isError": True} if raw.get("isError") else json.loads(raw["content"][0]["text"])


def compilation_rows(args, source_head, source_clean):
    implementation = None
    if args.registration_evidence and args.registration_log and args.registration_test_gate:
        evidence = json.loads(args.registration_evidence.read_text())
        log_bytes = args.registration_log.read_bytes()
        log = log_bytes.decode(errors="replace")
        gate = json.loads(args.registration_test_gate.read_text())
        case = "testRequiredSubstratesRemainRegisteredInActualRuntimeComposition"
        identity = r"Test Case '[^']*SubstrateInventoryTests[ .]" + case + r"\]?' passed"
        if not source_clean or gate.get("status") != "passed" or gate.get("testedSourceHead") != source_head or gate.get("testExitCode") != 0 or gate.get("logSHA256") != sha(log_bytes):
            raise ValueError("Callable registration evidence is not bound to a passing exact-source test gate")
        if set(evidence.get("families", [])) != set(FAMILIES) or not re.search(identity, log):
            raise ValueError("Required callable registration test did not pass")
        if sorted(evidence.get("canonicalOperations", [])) != sorted(("context_runtime", "context_inspect", "context_actions", "context_explain", "context_run", "context_run_status", "context_providers")):
            raise ValueError("Callable registration evidence changed the canonical operations")
        if len(evidence.get("families", [])) == len(FAMILIES):
            implementation = {family: True for family in FAMILIES}
    builds = set()
    if args.compile_evidence:
        provenance = json.loads((args.compile_evidence / "source.json").read_text())
        if not source_clean or provenance.get("candidateSHA") != source_head:
            raise ValueError("Compile evidence belongs to another candidate source")
        for path in args.compile_evidence.glob("build-*.log"):
            module = path.stem.removeprefix("build-")
            text = path.read_text(errors="replace")
            if re.search(r"Build of target: '" + re.escape(module) + r"' complete!", text) and "error:" not in text:
                builds.add(module)
    modules = {family: "RightClickProviders" for family in FAMILIES}
    modules.update(macos="RightClickMacOS", dbus="RightClickLinux", ard="RightClickARD")
    return implementation, {family: True if module in builds else None for family, module in modules.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--repository", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--manifest", type=pathlib.Path)
    parser.add_argument("--controlled", action="store_true")
    parser.add_argument("--graphql-python", default=sys.executable)
    parser.add_argument("--grpc-python", default=sys.executable)
    parser.add_argument("--mcp-python")
    parser.add_argument("--a2a", action="store_true")
    parser.add_argument("--component", type=pathlib.Path)
    parser.add_argument("--wasm-runtime", type=pathlib.Path)
    parser.add_argument("--wasm-tools", type=pathlib.Path)
    parser.add_argument("--require", action="append", choices=FAMILIES, default=[])
    parser.add_argument("--require-verified", action="append", choices=FAMILIES, default=[])
    parser.add_argument("--require-withdrawal", action="append", choices=FAMILIES, default=[])
    parser.add_argument("--registration-evidence", type=pathlib.Path)
    parser.add_argument("--registration-log", type=pathlib.Path)
    parser.add_argument("--registration-test-gate", type=pathlib.Path)
    parser.add_argument("--compile-evidence", type=pathlib.Path)
    args = parser.parse_args()
    args.repository = args.repository.resolve()
    source_head = subprocess.check_output(["git", "-C", str(args.repository), "rev-parse", "HEAD"], text=True).strip()
    source_clean = not subprocess.check_output(["git", "-C", str(args.repository), "status", "--porcelain"], text=True).strip()
    source_content = source_content_digest(args.repository)
    canonical = load_module("canonical", args.repository / "scripts/canonical-mcp-proof-client.py")
    receipt = load_module("receipt", args.repository / "scripts/verify-rcir-receipt.py")
    args.output.mkdir(parents=True, exist_ok=True)
    implemented, compiled = compilation_rows(args, source_head, source_clean)
    native_platform = {"Darwin": "macos", "Linux": "linux"}.get(platform.system(), platform.system().lower())
    report = {"schemaVersion": 1, "sourceHead": source_head, "sourceClean": source_clean, "sourceContent": source_content,
        "singleClient": None, "singleRuntimeProcess": None, "clientProcessCount": 0,
        "rows": {family: {"implemented": None if implemented is None else implemented[family], "compiles": compiled[family],
            "discovered": None, "executed": None, "executionNodeVerified": None, "verified": None, "liveWithdrawalTested": None,
            "platformsTested": [], "status": "UNPROVEN"} for family in FAMILIES}, "errors": []}
    private_umask = os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="rightclick-substrate-coexistence-") as temporary:
        private = pathlib.Path(temporary).resolve()
        private.chmod(0o700)
        processes = Processes(private)
        client = None
        stage, family = "fixture-configuration", None
        try:
            manifest = {"schemaVersion": 1, "artifacts": [], "rows": {}, "environment": {}}
            if args.controlled:
                local, observer = controlled_fixtures(args, private, processes)
                manifest.update(local)
                if args.mcp_python:
                    add_owned_mcp(manifest, args, private, processes, observer)
            elif args.mcp_python:
                raise ValueError("Owned MCP fixture requires the controlled independent observer")
            if args.a2a:
                add_owned_a2a(manifest, args, private, processes)
            if args.component:
                if args.wasm_runtime is None or args.wasm_tools is None:
                    raise ValueError("Actual component proof requires both selected native tools")
                add_owned_wasm(manifest, args, private)
            if args.manifest:
                supplied = checked_manifest(json.loads(args.manifest.read_text()))
                if set(manifest["rows"]) & set(supplied.get("rows", {})):
                    raise ValueError("Supplied fixture replaces an owned family; choose one explicit acquisition")
                manifest["rows"].update(supplied.get("rows", {}))
                manifest["environment"].update(supplied.get("environment", {}))
                for name in ["artifacts", "a2aAgentCards", "ardRegistries"]:
                    manifest.setdefault(name, []).extend(supplied.get(name, []))
            checked_manifest(manifest)
            expected = set(args.require) | set(args.require_verified) | set(args.require_withdrawal)
            if not expected.issubset(manifest["rows"]):
                raise ValueError("A required fixture was not provisioned: " + ",".join(sorted(expected - set(manifest["rows"]))))
            if not manifest["rows"]:
                raise ValueError("No genuine coexistence fixtures supplied")
            canonical.signer(private, args.output)
            host = private / "host.json"
            settings = {"version": 1, "revision": "single-client-coexistence-1", "deniedCapabilities": [],
                        "signingKeyFile": str(private / "key.raw"), "observers": {}}
            private_json(host, settings)
            environment = dict(manifest["environment"], RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps(manifest["artifacts"]),
                RIGHTCLICK_ARD_REGISTRIES=json.dumps(manifest.get("ardRegistries", [])),
                RIGHTCLICK_RCIR_CONFIG=str(host))
            if manifest.get("a2aAgentCards"):
                cards = private / "a2a-providers.json"
                private_json(cards, {"version": 1, "agentCards": manifest["a2aAgentCards"]})
                environment["RIGHTCLICK_A2A_PROVIDERS"] = str(cards)
            stage = "runtime-start"
            # Assign before initialization: even an initialization failure leaves
            # an owned subprocess handle available to bounded cleanup.
            client = canonical.Client.__new__(canonical.Client)
            with isolated_authority_environment():
                canonical.Client.__init__(client, args.binary, private / "runtime", environment)
            client.canonical_names = canonical.TOOLS
            if len(client.tools) != 7 or len(canonical.TOOLS) != 7:
                raise ValueError("Runtime did not expose exactly seven distinct canonical tools")
            report.update(binarySHA256=client.sha256, runtimePlatform=native_platform,
                          runtimeArchitecture=platform.machine(), platformEvidence="Native local subprocess on measured proof host",
                          canonicalOperations=sorted(canonical.TOOLS), singleClient=True, singleRuntimeProcess=True,
                          toolSchemaSHA256=sha(json.dumps(client.tools, sort_keys=True).encode()))
            item = "RIGHTCLICK same-client substrate coexistence proof"
            client.call("context_inspect", {"item": item})
            client.call("context_providers", {})
            actions = client.call("context_actions", {"item": item})["actions"]
            report["graphActionCount"] = len(actions)
            stage = "shared-graph-discovery"
            selected = {}
            # Every supplied row is mandatory; absence cannot become a skipped
            # product success. One initial graph must contain every selected row.
            for family, fixture in manifest["rows"].items():
                if family == "macos" and native_platform != "macos" or family == "dbus" and native_platform != "linux":
                    raise ValueError("Native fixture belongs to another execution platform")
                candidates = [action for action in actions if matches(action, fixture["selector"])]
                row = report["rows"][family]
                row["discoveryMatchCount"] = len(candidates)
                row["discovered"] = len(candidates) == 1
                if len(candidates) != 1:
                    raise ValueError("Supplied " + family + " fixture did not compile/discover one exact capability")
                selected[family] = candidates[0]
                row.update(capabilityID=candidates[0]["id"], platformsTested=[report["runtimePlatform"]], status="DISCOVERED")
                pin = candidates[0].get("contractSHA256")
                if pin is not None and not re.fullmatch(r"[0-9a-f]{64}", pin):
                    raise ValueError("Discovery returned a malformed contract fingerprint")
                row["discoveryContractPinned"] = pin is not None
                client.call("context_explain", {"item": item, "actionId": candidates[0]["id"]})
                if fixture.get("observer"):
                    settings["observers"][candidates[0]["id"]] = fixture["observer"]
            private_json(host, settings)  # one merged observer map, never replace it per family
            report["initialGraphCapabilityIDs"] = sorted(action["id"] for action in selected.values())
            results = {}
            bindings = {}
            for family, fixture in manifest["rows"].items():
                stage = "invocation-policy-controls"
                action = selected[family]
                row = report["rows"][family]
                bound = fresh_bindings()
                bindings[family] = bound
                run = dict(substitute(fixture.get("invoke", {}), bound), item=fixture.get("item", item), actionId=action["id"], confirmed=True)
                if action.get("contractSHA256"):
                    run["contractSHA256"] = action["contractSHA256"]
                if fixture.get("testPolicyAndConfirmation"):
                    if not fixture.get("readback"):
                        raise ValueError("Policy controls require independent fresh-effect absence observation")
                    absence_read(fixture["readback"], private, bound)
                    if action.get("requiresConfirmation") is True:
                        gated = call_allow_error(client, "context_run", dict(run, confirmed=False))
                        if gated.get("state") != "awaiting_user":
                            raise ValueError("Confirmation requirement changed for " + family)
                        absence_read(fixture["readback"], private, bound, gated)
                        row["confirmationPreserved"] = True
                    settings["deniedCapabilities"] = [action["id"]]
                    private_json(host, settings)
                    denied = call_allow_error(client, "context_run", run)
                    if denied.get("state") != "rejected":
                        raise ValueError("Local policy denial changed for " + family)
                    absence_read(fixture["readback"], private, bound, denied)
                    settings["deniedCapabilities"] = []
                    private_json(host, settings)
                    row["policyPreserved"] = True
                stage = "existing-engine-invocation"
                result = client.call("context_run", run)
                if fixture.get("requirePendingInitially"):
                    if result.get("state") != "started" or result.get("evidence", {}).get("outcomeVerified"):
                        raise ValueError("Deferred acceptance was collapsed into verification")
                    row["initialAcceptanceUnverified"] = True
                if fixture.get("release"):
                    release = (private / fixture["release"]).resolve()
                    if not release.is_relative_to(private):
                        raise ValueError("Task release escaped owned fixture scratch")
                    release.write_text("release original task\n")
                deadline = time.monotonic() + 30
                while result.get("state") in {"started", "accepted"} and (result.get("rcir") or {}).get("phase") not in {"completed", "failed", "cancelled", "expired"}:
                    if time.monotonic() > deadline:
                        raise TimeoutError("Original " + family + " task did not settle; no retry performed")
                    time.sleep(0.05)
                    result = client.call("context_run_status", {"executionId": result["executionId"]})
                stage = "independent-verification"
                bound = result_bindings(bound, result)
                bindings[family] = bound
                native_execution = family == "macos" and not result.get("rcir") and fixture.get("readback")
                row["executed"] = result.get("state") in {"succeeded", "accepted"} and ((result.get("rcir") or {}).get("leaseConsumed") is True or bool(native_execution))
                row["executionNodeVerified"] = result.get("state") == "succeeded" and result.get("evidence", {}).get("outcomeVerified") is True
                # Preserve the node's assertion separately. This acceptance row
                # cannot claim verification before observation and integrity pass.
                row["verified"] = False
                row.update(executionState=result.get("state"), providerAcceptanceBoundary="Execution-node accepted invocation; independent effect is a separate field",
                           verificationBoundary=fixture.get("verificationBoundary", "Supplied host-selected observer/verification"))
                if not row["executed"]:
                    raise ValueError("Supplied " + family + " invocation did not establish execution")
                row["status"] = "EXECUTED_UNVERIFIED"
                if fixture.get("readback"):
                    row["independentObservation"] = independent_read(fixture["readback"], result, private, bound)
                envelope = (result.get("rcir") or {}).get("signedReceipt")
                if (result.get("rcir") or {}).get("leaseConsumed") is True and not envelope:
                    raise ValueError("Terminal admitted RCIR invocation lost its provisioned signed receipt")
                if envelope:
                    path = private / (family + "-receipt.json")
                    private_json(path, envelope)
                    receipt.verify(path, args.output / "trusted-public-key.raw", expected_outcome=result["rcir"]["outcome"],
                        expected_task_id=result["rcir"]["taskID"], expected_lease_id=result["rcir"]["leaseID"])
                    payload = base64.b64decode(envelope["payload"], validate=True)
                    claim = receipt._domain(payload, "RECEIPT")
                    request = receipt._domain(claim["request"], "REQUEST")
                    binding = receipt._domain(request["binding"], "BINDING")
                    contract = receipt._domain(binding["contract"], "CONTRACT")
                    prefix = b"RIGHTCLICK-CONTRACT-1\x00"
                    if not contract["abi"].startswith(prefix):
                        raise ValueError("Receipt lost its declared capability ABI")
                    declaration = receipt._value(contract["abi"][len(prefix):])
                    if declaration["capability"] != action["id"]:
                        raise ValueError("Signed receipt authenticated another capability")
                    row["receipt"] = {"independentSignatureVerified": True, "selectedCapabilityMatched": True, "payloadSHA256": sha(payload)}
                row["verified"] = row["executionNodeVerified"] and "independentObservation" in row
                if (fixture.get("requireVerified") or family in args.require_verified) and not row["verified"]:
                    raise ValueError("Supplied " + family + " outcome remained independently unverified")
                results[family] = result
                row["status"] = "VERIFIED" if row["verified"] else "EXECUTED_UNVERIFIED"
                if client.request("tools/list")["tools"] != client.tools:
                    raise ValueError("Canonical tool definitions changed after substrate execution")
            # Keep every other supplied capability in the SAME graph while one
            # controlled acquisition is withdrawn. Never restart client/runtime.
            remaining = set(action["id"] for action in selected.values())
            for family, fixture in manifest["rows"].items():
                stage = "live-withdrawal"
                if not fixture.get("withdrawal"):
                    if family in args.require_withdrawal:
                        raise ValueError("Required " + family + " live withdrawal was not provisioned")
                    continue
                withdraw(fixture["withdrawal"], private, processes)
                old = selected[family]["id"]
                remaining.remove(old)
                deadline = time.monotonic() + 30
                while True:
                    current = {action["id"] for action in client.call("context_actions", {"item": item})["actions"]}
                    if old not in current:
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError("Supplied " + family + " stale capability did not withdraw live")
                    time.sleep(0.1)
                if not remaining.issubset(current):
                    raise ValueError("Withdrawing " + family + " removed an unrelated substrate from the shared graph")
                fresh = fresh_bindings()
                if not fixture.get("readback"):
                    raise ValueError("Withdrawal requires a fresh independent absence control")
                absence_read(fixture["readback"], private, fresh)
                stale = call_allow_error(client, "context_run", dict(substitute(fixture.get("invoke", {}), fresh),
                    item=fixture.get("item", item), actionId=old, confirmed=True))
                if not stale.get("isError") and stale.get("state") not in {"unavailable", "rejected", "unsupported", "unknown"}:
                    raise ValueError("A withdrawn capability still admitted execution")
                absence_read(fixture["readback"], private, fresh, stale)
                if client.request("tools/list")["tools"] != client.tools:
                    raise ValueError("Seven tool definitions changed during live withdrawal")
                report["rows"][family]["liveWithdrawalTested"] = True
            report["fixtureProcesses"] = processes.diagnostics
            report["oneGraphSuppliedFamilies"] = sorted(manifest["rows"])
            stage, family = "source-provenance", None
            if source_content_digest(args.repository) != source_content or sha(client.binary.read_bytes()) != client.sha256:
                raise ValueError("Candidate sources changed during the coexistence proof")
            report["status"] = "PASS_FOR_SUPPLIED_BOUNDARY" if len(manifest["rows"]) == 11 else "PARTIAL_BOUNDARY_PASS"
        except Exception as error:
            # Provider output/raw exception detail may contain authority bytes.
            # Public errors identify only our closed stage/error class.
            report["errors"].append({"stage": stage, "family": family, "kind": type(error).__name__})
            report["status"] = "FAIL"
        finally:
            try:
                if client is not None and hasattr(client, "process"):
                    report["clientProcessCount"] = 1
                    close_client(client)
                    report["canonicalToolCallCount"] = sum(1 for entry in client.transcript if entry["request"]["method"] == "tools/call")
            except Exception as error:
                report["errors"].append({"stage": "runtime-cleanup", "kind": type(error).__name__})
                report["status"] = "FAIL"
            finally:
                try:
                    processes.close()
                except Exception as error:
                    report["errors"].append({"stage": "fixture-cleanup", "kind": type(error).__name__})
                    report["status"] = "FAIL"
            (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    os.umask(private_umask)
    print("SUBSTRATE COEXISTENCE:", report["status"], "one client/runtime; eleven independent rows")
    raise SystemExit(report["status"] == "FAIL")


if __name__ == "__main__":
    main()
