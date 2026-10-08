"""RIGHTCLICK Alien Network v2: bounded cross-runner delegation proof.

Experimental portable delegator, NOT the production RIGHTCLICK dispatcher.
Ubuntu issuer -> Windows capability observer -> independent Ubuntu verifier.
No private keys leave their issuing runner; no production credentials touched.
"""
import argparse
import base64
import copy
import hashlib
import json
import os
import pathlib
import platform
import secrets
import shutil
import subprocess
import time

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

SCHEMA = "rightclick.delegation-experiment/v2"
OP = "platform.inspect"
AUDIENCE = "windows-child"
WINDOW_SECONDS = 2700


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def encode(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def decode(value):
    return base64.urlsafe_b64decode(value + ("=" * (-len(value) % 4)))


def key_public(key):
    return encode(key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    ))


def signed(payload, private_key):
    return {"payload": payload, "public_key": key_public(private_key),
            "signature": encode(private_key.sign(canonical(payload)))}


def verify_signature(envelope, expected_public=None):
    if not isinstance(envelope, dict) or set(envelope) != {"payload", "public_key", "signature"}:
        raise ValueError("invalid_signed_envelope")
    public = envelope["public_key"]
    if expected_public is not None and public != expected_public:
        raise ValueError("unexpected_signer")
    try:
        Ed25519PublicKey.from_public_bytes(decode(public)).verify(
            decode(envelope["signature"]), canonical(envelope["payload"])
        )
    except Exception as exc:
        raise ValueError("signature_invalid") from exc
    return envelope["payload"]


def write_json(path, obj):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def create_issuer_bundle(run_id, repo_sha, now=None):
    now = int(time.time()) if now is None else int(now)
    key = Ed25519PrivateKey.generate()
    parent = signed({
        "schema": SCHEMA, "kind": "parent_attestation", "run_id": run_id,
        "repo_commit_sha": repo_sha, "issuer_substrate": "linux",
        "nonce": secrets.token_hex(16), "issued_unix": now,
        "ai_facing_operations": 7, "max_depth": 2, "max_fanout": 1,
    }, key)
    lease = signed({
        "schema": SCHEMA, "kind": "delegation", "run_id": run_id,
        "parent_receipt_sha256": digest(parent),
        "id": secrets.token_hex(16), "audience": AUDIENCE,
        "scope": [OP], "issued_unix": now,
        "expires_unix": now + WINDOW_SECONDS,
        "max_executions": 1, "max_depth": 1, "max_fanout": 1,
    }, key)
    return parent, lease


def validate_issuer(parent, lease, run_id=None, repo_sha=None):
    p = verify_signature(parent)
    l = verify_signature(lease, parent["public_key"])
    if p.get("schema") != SCHEMA or l.get("schema") != SCHEMA:
        raise ValueError("schema_mismatch")
    if p.get("kind") != "parent_attestation" or l.get("kind") != "delegation":
        raise ValueError("kind_mismatch")
    if p.get("run_id") != l.get("run_id"):
        raise ValueError("run_id_mismatch")
    if run_id and p["run_id"] != run_id:
        raise ValueError("unexpected_run")
    if repo_sha and p["repo_commit_sha"] != repo_sha:
        raise ValueError("unexpected_commit")
    if digest(parent) != l.get("parent_receipt_sha256"):
        raise ValueError("parent_digest_mismatch")
    if p.get("ai_facing_operations") != 7 or p.get("max_depth", 99) > 2:
        raise ValueError("interface_or_depth_broadened")
    if l.get("max_fanout") != 1 or l.get("max_depth") != 1 or l.get("max_executions") != 1:
        raise ValueError("delegation_budget_broadened")
    return p, l


def authorize(lease, trusted_issuer_public, requested_operation=OP,
              expected_audience=AUDIENCE, now=None, revoked=None,
              consumed=None, available=True):
    data = verify_signature(lease, trusted_issuer_public)
    now = int(time.time()) if now is None else int(now)
    if data.get("schema") != SCHEMA or data.get("kind") != "delegation":
        raise ValueError("invalid_delegation")
    if data.get("audience") != expected_audience:
        raise ValueError("audience_denied")
    if data.get("scope") != [OP] or requested_operation not in data["scope"]:
        raise ValueError("scope_denied")
    if data.get("max_executions") != 1 or data.get("max_depth") != 1 or data.get("max_fanout") != 1:
        raise ValueError("authority_broadened")
    if now < data.get("issued_unix", -1) or now >= data.get("expires_unix", -1):
        raise ValueError("lease_expired_or_not_yet_valid")
    if data.get("id") in (revoked or set()):
        raise ValueError("revoked")
    if data.get("id") in (consumed or set()):
        raise ValueError("replay_denied")
    if not available:
        raise ValueError("provider_unavailable")
    return data


def negative_trials(lease, public_key, now):
    """Tests are local adversarial controls; provider loss is SIMULATED."""
    l = lease["payload"]
    modified = copy.deepcopy(lease)
    modified["payload"]["scope"] = [OP, "filesystem.delete"]
    tests = [
        ("tampered_lease", modified, OP, AUDIENCE, now, set(), set(), True),
        ("scope_escalation", lease, "filesystem.delete", AUDIENCE, now, set(), set(), True),
        ("wrong_audience", lease, OP, "linux-child", now, set(), set(), True),
        ("expired", lease, OP, AUDIENCE, l["expires_unix"] + 1, set(), set(), True),
        ("revoked_at_admission", lease, OP, AUDIENCE, now, {l["id"]}, set(), True),
        ("replay", lease, OP, AUDIENCE, now, set(), {l["id"]}, True),
        ("missing_provider_simulation", lease, OP, AUDIENCE, now, set(), set(), False),
    ]
    results = []
    for name, envelope, op, audience, at, revoked, consumed, available in tests:
        try:
            authorize(envelope, public_key, op, audience, at, revoked, consumed, available)
            results.append({"name": name, "denied": False, "reason": "UNEXPECTED_ALLOW"})
        except ValueError as exc:
            results.append({"name": name, "denied": True, "reason": str(exc)})
    return results


def discover_windows_capability():
    """Discover a real Windows command at runtime, NOT a fabricated provider."""
    shell = shutil.which("pwsh") or shutil.which("powershell.exe")
    if not shell:
        raise RuntimeError("windows_powershell_provider_missing")
    query = ("@('Get-CimInstance','Get-ComputerInfo') | "
             "ForEach-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue | "
             "Select-Object -ExpandProperty Name } | ConvertTo-Json -Compress")
    first = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-Command", query],
                           capture_output=True, text=True, timeout=35, check=True)
    available = json.loads(first.stdout.strip())
    if isinstance(available, str):
        available = [available]
    if not isinstance(available, list):
        raise ValueError("discovery_contract_invalid")
    if "Get-CimInstance" in available:
        selected = "Get-CimInstance"
        command = ("Get-CimInstance -ClassName Win32_OperatingSystem | "
                   "Select-Object -First 1 Caption,Version,OSArchitecture | ConvertTo-Json -Compress")
    elif "Get-ComputerInfo" in available:
        selected = "Get-ComputerInfo"
        command = ("Get-ComputerInfo | "
                   "Select-Object -Property OsName,OsVersion,OsArchitecture | ConvertTo-Json -Compress")
    else:
        raise RuntimeError("no_safe_applicable_windows_capability")
    return shell, sorted(set(available)), selected, command


def execute_windows():
    if platform.system() != "Windows":
        raise RuntimeError("host_substrate_not_windows")
    shell, discovered, selected, cmd = discover_windows_capability()
    invocation = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-Command", cmd],
                                capture_output=True, text=True, timeout=60)
    if invocation.returncode:
        raise RuntimeError("windows_discovered_invocation_failed")
    data = json.loads(invocation.stdout.strip())
    if not isinstance(data, dict) or not data or not any(
        isinstance(v, str) and v.strip() for v in data.values()
    ):
        raise RuntimeError("semantic_observation_invalid")
    independent = {"python_platform": platform.system(), "os_name": os.name,
                   "platform_release": platform.release(), "machine": platform.machine()}
    observed = independent["python_platform"] == "Windows" and independent["os_name"] == "nt"
    return {
        "schema": SCHEMA, "observed": observed, "provider_selected": selected,
        "providers_discovered": discovered, "provider_stdout": data,
        "provider_exit_code": invocation.returncode, "independent_os_observer": independent,
        "runner_name": os.environ.get("RUNNER_NAME"),
        "runner_os": os.environ.get("RUNNER_OS"),
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "github_sha": os.environ.get("GITHUB_SHA"),
    }


def issue(output):
    parent, lease = create_issuer_bundle(os.environ.get("GITHUB_RUN_ID", "local"),
                                         os.environ.get("GITHUB_SHA", "local"))
    validate_issuer(parent, lease)
    write_json(output / "parent-signed.json", parent)
    write_json(output / "lease-signed.json", lease)
    write_json(output / "issuer-summary.json", {
        "schema": SCHEMA, "key_lifecycle": "ephemeral_private_key_never_exported",
        "source": "Ubuntu GitHub Actions job", "parent_sha256": digest(parent),
        "lease_sha256": digest(lease), "max_depth": 2, "max_fanout": 1,
    })
    print("ISSUED parent=" + digest(parent) + " lease=" + digest(lease))


def child(issuer_dir, output):
    parent = read_json(issuer_dir / "parent-signed.json")
    lease = read_json(issuer_dir / "lease-signed.json")
    validate_issuer(parent, lease, os.environ.get("GITHUB_RUN_ID"),
                    os.environ.get("GITHUB_SHA"))
    now = int(time.time())
    tests = negative_trials(lease, parent["public_key"], now)
    if not all(t["denied"] for t in tests):
        raise RuntimeError("negative_security_test_failed")
    # Admission check MUST precede the first provider effect.
    delegated = authorize(lease, parent["public_key"], now=now)
    result = execute_windows()
    if not result["observed"]:
        raise RuntimeError("child_semantic_verification_failed")
    result["delegation_id"] = delegated["id"]
    # Consumed here; a second admission with the same nonce denies.
    consumed = {delegated["id"]}
    try:
        authorize(lease, parent["public_key"], now=now, consumed=consumed)
        raise RuntimeError("replay_not_denied")
    except ValueError as exc:
        if str(exc) != "replay_denied":
            raise
    result_hash = digest(result)
    child_key = Ed25519PrivateKey.generate()
    receipt = signed({
        "schema": SCHEMA, "kind": "child_receipt", "run_id":delegated["run_id"],
        "parent_receipt_sha256": digest(parent), "lease_sha256": digest(lease),
        "result_sha256": result_hash, "delegation_id":delegated["id"],
        "executed_scope": OP, "semantic_success": True,
        "observed_substrate": "windows", "depth": 1, "fanout": 1,
    }, child_key)
    write_json(output / "result.json", result)
    write_json(output / "negative-controls.json", tests)
    write_json(output / "child-signed.json", receipt)
    print("EXECUTED provider=" + result["provider_selected"] + " result=" + result_hash)


def verify_remote(issuer_dir, child_dir, output):
    parent = read_json(issuer_dir / "parent-signed.json")
    lease = read_json(issuer_dir / "lease-signed.json")
    p, l = validate_issuer(parent, lease, os.environ.get("GITHUB_RUN_ID"),
                           os.environ.get("GITHUB_SHA"))
    child_receipt = read_json(child_dir / "child-signed.json")
    child_claim = verify_signature(child_receipt)
    result = read_json(child_dir / "result.json")
    negatives = read_json(child_dir / "negative-controls.json")
    assert_all = [
        child_claim.get("schema") == SCHEMA,
        child_claim.get("kind") == "child_receipt",
        child_claim.get("run_id") == p["run_id"],
        child_claim.get("parent_receipt_sha256") == digest(parent),
        child_claim.get("lease_sha256") == digest(lease),
        child_claim.get("delegation_id") == l["id"],
        child_claim.get("executed_scope") in l["scope"],
        child_claim.get("result_sha256") == digest(result),
        child_claim.get("semantic_success") is True,
        child_claim.get("observed_substrate") == "windows",
        child_claim.get("depth") <= l["max_depth"],
        child_claim.get("fanout") <= l["max_fanout"],
        result.get("observed") is True,
        result.get("independent_os_observer", {}).get("python_platform") == "Windows",
        result.get("independent_os_observer", {}).get("os_name") == "nt",
        result.get("github_run_id") == p["run_id"],
        result.get("github_sha") == p["repo_commit_sha"],
        result.get("delegation_id") == l["id"],
        result.get("provider_selected") in result.get("providers_discovered", []),
        result.get("provider_exit_code") == 0,
        isinstance(negatives, list) and len(negatives) == 7,
        all(v.get("denied") is True for v in negatives),
    ]
    verified = all(assert_all)
    report = {
        "schema": SCHEMA, "verified_success": verified,
        "checks": dict(enumerate(assert_all)),
        "parent_sha256": digest(parent), "lease_sha256": digest(lease),
        "child_receipt_sha256": digest(child_receipt),
        "result_sha256": digest(result),
        "issuer_key": parent["public_key"],
        "child_key": child_receipt["public_key"],
        "negative_controls": negatives,
        "limitations": [
            "Ephemeral issuer key rooted in the GitHub Actions parent artifact, not externally pinned identity",
            "Revocation and provider-loss tests are admission-time simulations, not live remote revocation",
            "Windows child uses a portable experimental delegator, not the native RIGHTCLICK Core7 runtime",
            "Provider contract is dynamically inspected from a bounded safe PowerShell candidate family",
        ],
    }
    write_json(output / "verified-receipt-chain.json", report)
    if not verified:
        raise RuntimeError("independent_parent_verification_failed")
    print("VERIFIED cross-substrate receipt chain " + digest(report))


def selftest(output):
    parent, lease = create_issuer_bundle("unit-run", "unit-sha")
    validate_issuer(parent, lease, "unit-run", "unit-sha")
    now = lease["payload"]["issued_unix"]
    authorize(lease, parent["public_key"], now=now)
    tests = negative_trials(lease, parent["public_key"], now)
    if len(tests) != 7 or not all(t["denied"] for t in tests):
        raise RuntimeError("selftest_denial_mismatch")
    tamper = copy.deepcopy(parent)
    tamper["payload"]["nonce"] = "forged"
    try:
        verify_signature(tamper)
    except ValueError:
        pass
    else:
        raise RuntimeError("tampered_parent_passed")
    write_json(output / "unit-security-results.json", {
        "schema": SCHEMA, "passed": True, "denials": tests,
        "tests": ["parent_signature","tamper","scope","audience","expiry",
                  "revocation","replay","simulated_provider_removal"],
    })
    print("SELFTEST GREEN: seven negative controls and issuer signature")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["issue", "child", "verify", "selftest"])
    parser.add_argument("--issuer-dir", type=pathlib.Path, default=pathlib.Path("v2-issuer"))
    parser.add_argument("--child-dir", type=pathlib.Path, default=pathlib.Path("v2-child"))
    parser.add_argument("--output-dir", type=pathlib.Path, default=pathlib.Path("v2-result"))
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.mode == "issue":
        issue(args.output_dir)
    elif args.mode == "child":
        child(args.issuer_dir, args.output_dir)
    elif args.mode == "verify":
        verify_remote(args.issuer_dir, args.child_dir, args.output_dir)
    else:
        selftest(args.output_dir)


if __name__ == "__main__":
    main()
