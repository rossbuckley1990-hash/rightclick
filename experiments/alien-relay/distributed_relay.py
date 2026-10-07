"""Experimental cross-OS constrained delegation and signed receipt protocol.

This is a portable protocol *harness*, not a native Windows RIGHTCLICK binary.
The explicit seed is an external capability registry; individual AI capabilities
are discovered at runtime. No privilege escalation, self-replication or secrets.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import platform
import secrets
import sys
import time
import urllib.error
import urllib.request
from typing import Any

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

SCHEMA = "rightclick.distributed-delegation/v2"
RECEIPT_SCHEMA = "rightclick.distributed-receipt/v2"
ORIGIN = "https://huggingface-hf-discover.hf.space"
GRANT = {
    "origin": ORIGIN, "path": "/search", "method": "POST",
    "query": "image generation", "page_size": 5, "federation": "none",
}
LIMITS = {
    "max_depth": 1, "max_generations": 1, "max_fanout": 1,
    "max_network_calls": 1, "max_response_bytes": 500000, "timeout_seconds": 25,
}
SAMPLE_AI_OPERATIONS = (
    "context_runtime", "context_inspect", "context_actions",
    "context_explain", "context_run", "context_run_status", "context_providers",
)


class Denied(RuntimeError):
    """Policy rejection before effect or unverifiable postcondition."""


def canonical(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def digest(obj: Any) -> str:
    return hashlib.sha256(canonical(obj)).hexdigest()


def file_digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sign(payload: dict[str, Any], key: Ed25519PrivateKey | None = None) -> dict[str, Any]:
    key = key or Ed25519PrivateKey.generate()
    pub = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    return {
        "payload": payload,
        "public_key_b64": base64.b64encode(pub).decode("ascii"),
        "signature_b64": base64.b64encode(key.sign(canonical(payload))).decode("ascii"),
    }


def require_trust_anchor(signed: dict[str, Any], trusted_public_key: str | None) -> None:
    """Require the public key conveyed by GitHub job outputs, not by this artifact."""
    if not trusted_public_key or signed.get("public_key_b64") != trusted_public_key:
        raise Denied("untrusted_cross_job_public_key")


def verify_signature(signed: Any) -> dict[str, Any]:
    if not isinstance(signed, dict) or set(signed) != {"payload", "public_key_b64", "signature_b64"}:
        raise Denied("invalid_signature_envelope")
    try:
        pk = base64.b64decode(signed["public_key_b64"], validate=True)
        sig = base64.b64decode(signed["signature_b64"], validate=True)
        if len(pk) != 32 or len(sig) != 64:
            raise ValueError("invalid key or signature length")
        Ed25519PublicKey.from_public_bytes(pk).verify(sig, canonical(signed["payload"]))
    except Exception as exc:
        raise Denied("signature_verification_failed") from exc
    if not isinstance(signed["payload"], dict):
        raise Denied("invalid_signed_payload")
    return signed["payload"]


def issue_delegation(now: int, run_id: str, repository: str, commit: str) -> dict[str, Any]:
    if not (run_id and repository and len(commit) >= 12):
        raise Denied("missing_workflow_identity")
    payload = {
        "schema": SCHEMA, "issuer": "rightclick-protocol-parent-ubuntu",
        "audience": "rightclick-protocol-child-windows",
        "issued_epoch": now, "expires_epoch": now + 1200,
        "nonce": secrets.token_hex(16),
        "run_id": run_id, "repository": repository, "commit": commit,
        "grant": dict(GRANT), "limits": dict(LIMITS),
        "ai_facing_operation_count": len(SAMPLE_AI_OPERATIONS),
    }
    return sign(payload)


def validate_delegation(
    signed: dict[str, Any], *, now: int, run_id: str, repository: str,
    runner_os: str, revoked_nonces: set[str] | None = None,
    consumed_nonces: set[str] | None = None,
) -> dict[str, Any]:
    p = verify_signature(signed)
    if p.get("schema") != SCHEMA or p.get("issuer") != "rightclick-protocol-parent-ubuntu":
        raise Denied("wrong_delegation_schema_or_issuer")
    if p.get("audience") != "rightclick-protocol-child-windows" or runner_os != "Windows":
        raise Denied("wrong_audience_or_substrate")
    if p.get("run_id") != run_id or p.get("repository") != repository:
        raise Denied("wrong_workflow_identity")
    if not isinstance(p.get("nonce"), str) or len(p["nonce"]) != 32:
        raise Denied("invalid_nonce")
    if p["nonce"] in (revoked_nonces or set()):
        raise Denied("delegation_revoked")
    if p["nonce"] in (consumed_nonces or set()):
        raise Denied("delegation_replayed")
    if not isinstance(p.get("issued_epoch"), int) or not isinstance(p.get("expires_epoch"), int):
        raise Denied("invalid_clock")
    if now < p["issued_epoch"] - 30 or now > p["expires_epoch"] or p["expires_epoch"] - p["issued_epoch"] > 1200:
        raise Denied("delegation_expired_or_invalid")
    if p.get("grant") != GRANT or p.get("limits") != LIMITS:
        raise Denied("scope_or_budget_modified")
    if p.get("ai_facing_operation_count") != 7:
        raise Denied("interface_budget_modified")
    if consumed_nonces is not None:
        consumed_nonces.add(p["nonce"])
    return p


def enforce_action(grant: dict[str, Any], origin: str, path: str, method: str) -> None:
    if (origin, path, method) != (grant["origin"], grant["path"], grant["method"]):
        raise Denied("out_of_scope_action")


def parse_result(raw: bytes, expected_query: str) -> dict[str, Any]:
    try:
        response = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise Denied("provider_not_json") from exc
    if not isinstance(response, dict) or not isinstance(response.get("results"), list):
        raise Denied("provider_contract_missing_results")
    candidates = [
        row for row in response["results"]
        if isinstance(row, dict) and isinstance(row.get("identifier"), str)
        and bool(row["identifier"].strip()) and isinstance(row.get("type"), str)
    ]
    if not candidates:
        raise Denied("provider_returned_no_discoverable_capabilities")
    selected = next((r for r in candidates if r["type"] == "application/ai-skill"), candidates[0])
    return {
        "selected_identifier": selected["identifier"],
        "selected_type": selected["type"],
        "candidate_count": len(candidates),
        "query": expected_query,
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Denied("http_redirect_denied")


def discover(grant: dict[str, Any], limits: dict[str, Any], opener=None) -> tuple[bytes, dict[str, Any]]:
    """Generic, constrained JSON-over-HTTPS, not a provider-specific top-level AI tool."""
    enforce_action(grant, grant["origin"], grant["path"], grant["method"])
    payload = canonical({"query": grant["query"], "page_size": grant["page_size"], "federation": grant["federation"]})
    req = urllib.request.Request(
        grant["origin"] + grant["path"], data=payload, method=grant["method"],
        headers={"Accept": "application/json", "Content-Type": "application/json"},
    )
    opener = opener or urllib.request.build_opener(NoRedirect)
    with opener.open(req, timeout=limits["timeout_seconds"]) as response:
        if response.status != 200 or response.geturl() != grant["origin"] + grant["path"]:
            raise Denied("non_exact_remote_response")
        raw = response.read(limits["max_response_bytes"] + 1)
    if len(raw) > limits["max_response_bytes"]:
        raise Denied("response_byte_budget_exceeded")
    return raw, parse_result(raw, grant["query"])


def negative_gates(signed: dict[str, Any], p: dict[str, Any]) -> dict[str, bool]:
    """Execute concrete denial tests on child; none generates network traffic."""
    gates: dict[str, bool] = {}
    def denied(name: str, operation) -> None:
        try:
            operation()
        except Denied:
            gates[name] = True
        else:
            gates[name] = False

    denied("out_of_scope", lambda: enforce_action(p["grant"], ORIGIN, "/predict", "POST"))
    denied("revocation", lambda: validate_delegation(
        signed, now=p["issued_epoch"], run_id=p["run_id"], repository=p["repository"],
        runner_os="Windows", revoked_nonces={p["nonce"]}))
    denied("expiry", lambda: validate_delegation(
        signed, now=p["expires_epoch"] + 1, run_id=p["run_id"], repository=p["repository"],
        runner_os="Windows"))
    denied("replay", lambda: validate_delegation(
        signed, now=p["issued_epoch"], run_id=p["run_id"], repository=p["repository"],
        runner_os="Windows", consumed_nonces={p["nonce"]}))
    denied("missing_provider", lambda: parse_result(b'{"results":[]}', p["grant"]["query"]))
    return gates


def make_child_receipt(
    signed: dict[str, Any], now: int, run_id: str, repository: str,
    runner_os: str, *, opener=None,
) -> tuple[dict[str, Any], bytes | None]:
    """Always produce a signed success/failure receipt, preserving negative evidence."""
    raw = None
    proof: dict[str, Any] = {
        "schema": RECEIPT_SCHEMA, "parent_envelope_sha256": digest(signed),
        "observed_epoch": now,
        "runtime": {
            "platform_system": platform.system(), "runner_os": runner_os,
            "job": os.environ.get("GITHUB_JOB", "test"),
            "runner_name": os.environ.get("RUNNER_NAME", "unattested"),
            "run_id": run_id, "repository": repository,
        },
        "network_calls": 0, "max_depth_observed": 1,
        "negative_gates": {}, "semantic_success": False,
    }
    try:
        consumed: set[str] = set()
        p = validate_delegation(
            signed, now=now, run_id=run_id, repository=repository,
            runner_os=runner_os, consumed_nonces=consumed,
        )
        proof["negative_gates"] = negative_gates(signed, p)
        if not all(proof["negative_gates"].values()):
            raise Denied("negative_control_gate_failed")
        proof["grant"] = p["grant"]
        proof["network_calls"] = 1
        raw, selection = discover(p["grant"], p["limits"], opener=opener)
        proof["response_sha256"] = hashlib.sha256(raw).hexdigest()
        proof["selection"] = selection
        proof["semantic_success"] = True
    except Exception as exc:
        proof["failure_type"] = type(exc).__name__
        proof["failure_reason"] = str(exc)[:300]
    return sign(proof), raw


def verify_chain(
    delegation: dict[str, Any], child_receipt: dict[str, Any],
    raw: bytes | None, *, run_id: str, repository: str,
) -> dict[str, Any]:
    """Separate verification job: signatures, attenuation, byte read-back and semantics."""
    p = verify_signature(delegation)
    c = verify_signature(child_receipt)
    observed_time = c.get("observed_epoch")
    if not isinstance(observed_time, int):
        raise Denied("child_time_missing")
    validate_delegation(
        delegation, now=observed_time, run_id=run_id,
        repository=repository, runner_os="Windows",
    )
    if c.get("schema") != RECEIPT_SCHEMA or c.get("parent_envelope_sha256") != digest(delegation):
        raise Denied("broken_receipt_chain")
    runtime = c.get("runtime", {})
    if (runtime.get("runner_os") != "Windows" or runtime.get("platform_system") != "Windows"
        or runtime.get("run_id") != run_id or runtime.get("repository") != repository):
        raise Denied("child_runtime_mismatch")
    if c.get("grant") != p["grant"] or c.get("network_calls") != 1 or c.get("max_depth_observed") != 1:
        raise Denied("authority_or_execution_budget_broadened")
    if not c.get("semantic_success") or not all(c.get("negative_gates", {}).get(k) is True
        for k in ("out_of_scope", "revocation", "expiry", "replay", "missing_provider")):
        raise Denied("child_result_or_negative_controls_failed")
    if not raw or hashlib.sha256(raw).hexdigest() != c.get("response_sha256"):
        raise Denied("raw_provider_response_missing_or_changed")
    independent = parse_result(raw, p["grant"]["query"])
    if independent != c.get("selection"):
        raise Denied("independent_result_does_not_match")
    return {
        "schema": "rightclick.distributed-proof-verdict/v2",
        "semantic_success": True, "parent_signature_valid": True,
        "child_signature_valid": True,
        "parent_delegation_sha256": digest(delegation),
        "child_receipt_sha256": digest(child_receipt),
        "provider_response_sha256": hashlib.sha256(raw).hexdigest(),
        "independent_selection": independent,
        "negative_gates": c["negative_gates"],
        "cross_os_transition": "Ubuntu runner -> Windows runner -> Ubuntu verifier",
        "claim_limit": "Protocol harness only; not native Windows RIGHTCLICK runtime or cryptographic host attestation.",
    }


def cli(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("role", choices=("parent", "child", "verify"))
    ap.add_argument("--input", type=pathlib.Path, default=pathlib.Path("delegation"))
    ap.add_argument("--child-dir", type=pathlib.Path, default=pathlib.Path("child"))
    ap.add_argument("--out", type=pathlib.Path, required=True)
    args = ap.parse_args(argv)
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("GITHUB_SHA", "")
    if not (run_id and repository and sha):
        raise Denied("github_workflow_identity_required")
    now = int(time.time())
    if args.role == "parent":
        if platform.system() != "Linux" or os.environ.get("RUNNER_OS") != "Linux":
            raise Denied("parent_must_run_on_linux")
        envelope = issue_delegation(now, run_id, repository, sha)
        save(args.out / "delegation.json", envelope)
        save(args.out / "parent-evidence.json", {
            "attested_by": "GitHub Actions runner environment (not independently signed)",
            "runner_os": os.environ["RUNNER_OS"], "run_id": run_id,
            "repository": repository, "commit": sha,
            "delegation_sha256": digest(envelope),
        })
        print("PARENT_DELEGATION_SIGNED", digest(envelope))
        return 0
    if args.role == "child":
        delegation = load(args.input / "delegation.json")
        if platform.system() != "Windows" or os.environ.get("RUNNER_OS") != "Windows":
            raise Denied("child_must_run_on_windows")
        require_trust_anchor(delegation, os.environ.get("RIGHTCLICK_TRUSTED_PARENT_PUBLIC_KEY"))
        if delegation["payload"].get("commit") != sha:
            raise Denied("child_commit_mismatch")
        receipt, raw = make_child_receipt(delegation, now, run_id, repository, "Windows")
        save(args.out / "child-receipt.json", receipt)
        if raw is not None:
            (args.out / "provider-response.json").write_bytes(raw)
        print("CHILD_RECEIPT_SIGNED", digest(receipt))
        if not receipt["payload"]["semantic_success"]:
            print("CHILD_FAILED_CLOSED", receipt["payload"].get("failure_reason"))
            return 3
        return 0
    try:
        delegation = load(args.input / "delegation.json")
        receipt = load(args.child_dir / "child-receipt.json")
        require_trust_anchor(delegation, os.environ.get("RIGHTCLICK_TRUSTED_PARENT_PUBLIC_KEY"))
        require_trust_anchor(receipt, os.environ.get("RIGHTCLICK_TRUSTED_CHILD_PUBLIC_KEY"))
        if delegation["payload"].get("commit") != sha:
            raise Denied("verifier_commit_mismatch")
        response_path = args.child_dir / "provider-response.json"
        raw = response_path.read_bytes() if response_path.exists() else None
        result = verify_chain(delegation, receipt, raw, run_id=run_id, repository=repository)
        save(args.out / "verdict.json", result)
        print("DISTRIBUTED_PROTOCOL_VERIFIED", digest(result))
        return 0
    except Exception as exc:
        save(args.out / "verdict.json", {
            "schema": "rightclick.distributed-proof-verdict/v2",
            "semantic_success": False,
            "failure_type": type(exc).__name__,
            "failure_reason": str(exc)[:300],
        })
        print("DISTRIBUTED_PROTOCOL_UNVERIFIED", type(exc).__name__, str(exc))
        return 3


if __name__ == "__main__":
    sys.exit(cli())
