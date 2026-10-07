#!/usr/bin/env python3
"""Verify exact RCIR receipt bytes using Ed25519 and a separately pinned raw key.

Requires cryptography>=46. No trust-on-first-use, embedded-key self-trust, or
claims that a valid signature proves an external action actually happened.
"""
from __future__ import annotations
import argparse
import base64
import json
import math
import hashlib
from pathlib import Path
import re
import struct
import sys
import uuid

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PREFIX = b"RIGHTCLICK-RCIR-RECEIPT-1\x00"
MAX_PAYLOAD = 1_048_576


class ReceiptClaimMismatch(ValueError):
    """The signature is valid, but it authenticates a different requested claim."""


class ReceiptStructureError(ValueError):
    """Signature-valid bytes do not conform to the supported receipt structure."""


def _value(data: bytes):
    """Independent, bounded decoder for the existing exact typed ABI framing.

    This is not JSON re-canonicalisation and does not interpret executable data.
    Nested bytes remain opaque until an explicit RCIR domain is selected.
    """
    prefix = b"RIGHTCLICK-VALUE-1\0"
    if not isinstance(data, bytes) or len(data) > MAX_PAYLOAD or not data.startswith(prefix):
        raise ValueError("invalid canonical value")
    position = len(prefix); nodes = 0

    def take(size):
        nonlocal position
        if size < 0 or size > len(data) - position: raise ValueError("truncated canonical value")
        result = data[position:position + size]; position += size
        return result

    def count():
        nonlocal position
        end = data.find(b":", position, position + 9)
        if end < 0: raise ValueError("invalid canonical length")
        raw = data[position:end]
        if not re.fullmatch(rb"0|[1-9][0-9]*", raw): raise ValueError("noncanonical length")
        position = end + 1
        size = int(raw)
        if size > MAX_PAYLOAD: raise ValueError("canonical length limit")
        return size

    def read(depth):
        nonlocal nodes
        if depth > 32 or nodes >= 4096: raise ValueError("canonical structure limit")
        nodes += 1; tag = take(1)
        if tag == b"n": return None
        if tag == b"b":
            bit = take(1)
            if bit not in (b"0", b"1"): raise ValueError("invalid boolean")
            return bit == b"1"
        if tag in (b"i", b"s", b"x"):
            raw = take(count())
            if tag == b"x": return raw
            if tag == b"s": return raw.decode("utf-8", errors="strict")
            if len(raw) > 20 or not re.fullmatch(rb"0|-?[1-9][0-9]*", raw): raise ValueError("invalid canonical integer")
            result = int(raw)
            if not -(1 << 63) <= result < (1 << 63): raise ValueError("integer range")
            return result
        if tag == b"d":
            result = struct.unpack(">d", take(8))[0]
            if not math.isfinite(result): raise ValueError("nonfinite number")
            return result
        if tag in (b"a", b"o"):
            size = count()
            if size > 4096: raise ValueError("canonical collection limit")
            if tag == b"a": return [read(depth + 1) for _ in range(size)]
            result = {}; previous = None
            for _ in range(size):
                key = read(depth + 1)
                if not isinstance(key, str): raise ValueError("non-string object key")
                encoded = key.encode("utf-8")
                if previous is not None and encoded <= previous: raise ValueError("noncanonical object order")
                previous = encoded; result[key] = read(depth + 1)
            return result
        raise ValueError("unknown canonical tag")

    result = read(0)
    if position != len(data): raise ValueError("trailing canonical bytes")
    return result


def _domain(data: bytes, name: str):
    prefix = ("RIGHTCLICK-RCIR-" + name + "-1\0").encode("ascii")
    if not isinstance(data, bytes) or not data.startswith(prefix): raise ValueError("invalid RCIR domain")
    result = _value(data[len(prefix):])
    if not isinstance(result, dict): raise ValueError("RCIR domain requires an object")
    return result


def _identifier(value):
    if not isinstance(value, str) or str(uuid.UUID(value)).upper() != value:
        raise ValueError("invalid receipt identifier")
    return value


def _authority_claims(encoded, binding, request):
    """Strict optional authority-v1 decode; no unknown fields or implicit scopes.

    This checks the signed attenuation/binding claims, not live host-ledger state
    or issuer enforcement. Only the runtime can attest atomic usage/revocation.
    """
    def fields(value, expected):
        if not isinstance(value, dict) or set(value) != set(expected): raise ValueError("unsupported authority fields")
    def identity(value):
        if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 4096 or "*" in value:
            raise ValueError("invalid authority identity")
        return value.encode("utf-8")
    def collection(values, limit, parse, nonempty=True):
        if not isinstance(values, list) or len(values) > limit or (nonempty and not values): raise ValueError("invalid authority set")
        result = [parse(value) for value in values]
        if len(set(result)) != len(result): raise ValueError("duplicate authority set value")
        return set(result)
    def scope(value):
        fields(value, {"resource", "effect"})
        if value["effect"] not in ("read", "write", "delete", "execute", "publish", "subscribe", "securityChange"):
            raise ValueError("unknown authority effect")
        return (identity(value["resource"]), value["effect"])
    def target(value):
        fields(value, {"provider", "capability", "providerPrincipal", "generation", "discovery"})
        if type(value["generation"]) is not int or value["generation"] < 1 or not isinstance(value["discovery"], bytes):
            raise ValueError("invalid authority target")
        return (identity(value["provider"]), identity(value["capability"]), identity(value["providerPrincipal"]), value["generation"], value["discovery"])
    def reference(value):
        fields(value, {"id", "issuer", "audience"})
        return (_identifier(value["id"]), identity(value["issuer"]), identity(value["audience"]))
    contract = _domain(binding["contract"], "CONTRACT")
    fields(contract, {"abi", "effects", "task", "verification"})
    prefix = b"RIGHTCLICK-CONTRACT-1\0"
    if not isinstance(contract["abi"], bytes) or not contract["abi"].startswith(prefix): raise ValueError("invalid capability ABI")
    abi = _value(contract["abi"][len(prefix):])
    fields(abi, {"version", "provider", "reflector", "capability", "arguments", "result", "declaration"})
    if type(abi["version"]) is not int or abi["version"] != 1: raise ValueError("unsupported capability ABI version")
    actual_target = (identity(abi["provider"]), identity(abi["capability"]), identity(binding["principal"]), binding["generation"], binding.get("discovery"))
    actual_scopes = collection(request["scopes"],512,scope,False)
    if collection(contract["effects"],512,scope,False) != actual_scopes: raise ValueError("lease effects do not match contract")
    policy = _domain(request["policy"], "POLICY")
    fields(policy, {"revision", "principals", "scopes"}); identity(policy["revision"])
    if identity(binding["principal"]) not in collection(policy["principals"],512,identity) or not actual_scopes <= collection(policy["scopes"],512,scope,False):
        raise ValueError("authority lease is outside bound policy")
    fields(contract["task"], {"shape", "element", "cancellable", "maxEvents", "maxBytes"})
    nodes = []; seen = set(); current = encoded
    while current is not None:
        if len(nodes) >= 17: raise ValueError("authority ancestry limit")
        grant = _domain(current, "AUTHORITY")
        fields(grant, {"id", "issuer", "request", "issuedAt", "parent", "credentialReferences"})
        identifier = _identifier(grant["id"])
        if identifier in seen: raise ValueError("authority cycle")
        seen.add(identifier); issuer = identity(grant["issuer"])
        r = grant["request"]
        fields(r, {"subject", "audiences", "targets", "scopes", "arguments", "taskShapes", "expiresAt", "invocationLimit", "delegationDepth"})
        identity(r["subject"])
        audiences = collection(r["audiences"],64,identity)
        targets = collection(r["targets"],64,target)
        scopes = collection(r["scopes"],512,scope,False)
        def shape(value):
            if value not in ("unary","deferred","serverStream","clientStream","duplex"): raise ValueError("invalid task shape")
            return value
        shapes = collection(r["taskShapes"],5,shape)
        arguments = None
        if r["arguments"] is not None:
            def argument(value):
                _value(value); return value
            arguments = collection(r["arguments"],256,argument)
        refs = collection(grant["credentialReferences"],64,reference,False)
        if any(ref[2] not in audiences for ref in refs): raise ValueError("credential reference audience mismatch")
        for name in ("issuedAt",):
            if type(grant[name]) is not int or grant[name] < 0: raise ValueError("invalid authority issuance")
        for name in ("expiresAt", "invocationLimit", "delegationDepth"):
            if type(r[name]) is not int: raise ValueError("invalid authority limit")
        if not 0 < r["expiresAt"] - grant["issuedAt"] <= 60_000 or not 1 <= r["invocationLimit"] <= 4096 or not 0 <= r["delegationDepth"] <= 16:
            raise ValueError("invalid authority bounds")
        if not grant["issuedAt"] <= request["issuedAt"] < request["expiresAt"] <= r["expiresAt"]:
            raise ValueError("lease outside ancestor authority interval")
        node = {"id":identifier,"issuer":issuer,"request":r,"audiences":audiences,"targets":targets,"scopes":scopes,"arguments":arguments,"shapes":shapes,"references":refs,"issuedAt":grant["issuedAt"]}
        if nodes:
            child = nodes[-1]; cr = child["request"]
            if child["issuer"] != issuer or child["issuedAt"] < grant["issuedAt"] or not child["audiences"] <= audiences or not child["targets"] <= targets or not child["scopes"] <= scopes or not child["shapes"] <= shapes or not child["references"] <= refs:
                raise ValueError("authority ancestry widens set constraints")
            if cr["expiresAt"] > r["expiresAt"] or cr["invocationLimit"] > r["invocationLimit"] or cr["delegationDepth"] >= r["delegationDepth"]:
                raise ValueError("authority ancestry widens scalar constraints")
            if arguments is not None and (child["arguments"] is None or not child["arguments"] <= arguments):
                raise ValueError("authority ancestry widens arguments")
        nodes.append(node); current = grant["parent"]
    leaf = nodes[0]
    if actual_target not in leaf["targets"] or not actual_scopes <= leaf["scopes"] or contract["task"]["shape"] not in leaf["shapes"]:
        raise ValueError("authority does not cover bound capability effects")
    if leaf["arguments"] is not None and request["arguments"] not in leaf["arguments"]:
        raise ValueError("authority does not cover bound arguments")
    return {"grantID":leaf["id"], "issuer":leaf["issuer"].decode("utf-8"), "subject":leaf["request"]["subject"],
        "audiences":sorted(a.decode("utf-8") for a in leaf["audiences"]),
        "ancestorGrantIDs":[n["id"] for n in nodes[1:]], "ancestorSubjects":[n["request"]["subject"] for n in nodes[1:]],
        "invocationLimit":leaf["request"]["invocationLimit"], "delegationDepth":leaf["request"]["delegationDepth"],
        "argumentSHA256":hashlib.sha256(request["arguments"]).hexdigest(),
        "ancestrySHA256":hashlib.sha256(encoded).hexdigest()}


def _signed_claims(payload: bytes) -> dict:
    receipt = _domain(payload, "RECEIPT")
    required = {"taskID", "leaseID", "request", "startedAt", "deadline", "finishedAt", "lastObservationTime",
                "phase", "semanticOutcome", "events", "lastSequence", "cancellationRequestedAt", "observation", "observedAt"}
    if set(receipt) != required: raise ValueError("unsupported receipt fields")
    task, lease = _identifier(receipt["taskID"]), _identifier(receipt["leaseID"])
    phase, outcome = receipt["phase"], receipt["semanticOutcome"]
    if phase not in ("completed", "failed", "cancelled", "unknown") or outcome not in ("succeeded", "failed", "unknown", "unverified"):
        raise ValueError("unsupported terminal claim")
    for name in ("startedAt", "deadline", "finishedAt", "lastObservationTime", "lastSequence"):
        if type(receipt[name]) is not int or receipt[name] < 0: raise ValueError("invalid receipt counter")
    if not receipt["startedAt"] < receipt["deadline"] or not receipt["startedAt"] <= receipt["finishedAt"] <= receipt["lastObservationTime"]:
        raise ValueError("invalid receipt time order")
    for name in ("observedAt", "cancellationRequestedAt"):
        if receipt[name] is not None and (type(receipt[name]) is not int or not receipt["startedAt"] <= receipt[name] <= receipt["lastObservationTime"]):
            raise ValueError("invalid optional receipt time")
    if receipt["observation"] is not None: _value(receipt["observation"])
    if (receipt["observation"] is None) != (receipt["observedAt"] is None): raise ValueError("incomplete observation")
    if outcome in ("succeeded", "failed") and (phase != "completed" or receipt["observation"] is None):
        raise ValueError("semantic outcome lacks a completed observation")
    if outcome == "unknown" and phase != "unknown": raise ValueError("inconsistent unknown claim")
    events = receipt["events"]
    if not isinstance(events, list) or len(events) > 1024 or receipt["lastSequence"] != len(events):
        raise ValueError("invalid event history")
    if sum(len(event) for event in events if isinstance(event, bytes)) > 262_144:
        raise ValueError("event byte budget exceeded")
    previous_time = receipt["startedAt"]
    completion_without_output = False
    for index, event in enumerate(events, 1):
        value = _value(event)
        if not isinstance(value, dict) or set(value) != {"sequence", "time", "kind", "value"}:
            raise ValueError("invalid event fields")
        if type(value["sequence"]) is not int or value["sequence"] != index or type(value["time"]) is not int:
            raise ValueError("invalid event sequence")
        if not previous_time <= value["time"] <= receipt["lastObservationTime"]:
            raise ValueError("invalid event time")
        previous_time = value["time"]
        if value["kind"] not in ("accepted", "working", "inputRequired", "chunk", "completed", "completedWithoutOutput", "failed", "cancelled"):
            raise ValueError("unknown event kind")
        if value["kind"] == "completedWithoutOutput":
            if value["value"] is not None or index != len(events) or phase != "completed":
                raise ValueError("invalid no-output completion")
            completion_without_output = True
    request = _domain(receipt["request"], "REQUEST")
    legacy_fields = {"binding", "arguments", "scopes", "policy", "issuedAt", "expiresAt"}
    if set(request) not in (legacy_fields, legacy_fields | {"authority"}):
        raise ValueError("unsupported request binding")
    if any(type(request[name]) is not int for name in ("issuedAt", "expiresAt")):
        raise ValueError("invalid lease time")
    if not 0 <= request["issuedAt"] <= receipt["startedAt"] < request["expiresAt"] or not 1 <= request["expiresAt"] - request["issuedAt"] <= 60_000:
        raise ValueError("invalid lease interval")
    _value(request["arguments"]); _domain(request["policy"], "POLICY")
    binding = _domain(request["binding"], "BINDING")
    if set(binding) not in ({"contract", "principal", "generation"}, {"contract", "principal", "generation", "discovery"}):
        raise ValueError("unsupported graph binding")
    generation = binding["generation"]
    if type(generation) is not int or generation < 1: raise ValueError("invalid provider generation")
    if not isinstance(binding["principal"], str) or not binding["principal"]:
        raise ValueError("invalid bound principal")
    if completion_without_output:
        contract = _domain(binding["contract"], "CONTRACT")
        abi = contract.get("abi")
        abi_prefix = b"RIGHTCLICK-CONTRACT-1\0"
        if not isinstance(abi, bytes) or not abi.startswith(abi_prefix):
            raise ValueError("invalid no-output ABI binding")
        declaration = _value(abi[len(abi_prefix):])
        if not isinstance(declaration, dict) or not isinstance(declaration.get("result"), bytes) or _value(declaration["result"]) != "unit:no-declared-output":
            raise ValueError("no-output completion requires a unit result contract")
    scopes = request["scopes"]
    if not isinstance(scopes, list) or len(scopes) > 512: raise ValueError("invalid scope binding")
    effects = set()
    for scope in scopes:
        if not isinstance(scope, dict) or set(scope) != {"effect", "resource"} or not isinstance(scope["resource"], str):
            raise ValueError("invalid exact resource scope")
        if scope["effect"] not in ("read", "write", "delete", "execute", "publish", "subscribe", "securityChange"):
            raise ValueError("unknown effect scope")
        effects.add(scope["effect"])
    result = {"taskID": task, "leaseID": lease, "providerGeneration": generation, "phase": phase,
              "semanticOutcome": outcome, "scopeCount": len(scopes), "effects": sorted(effects)}
    if "authority" in request: result["authority"] = _authority_claims(request["authority"], binding, request)
    return result


def unique(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj: raise ValueError("duplicate key")
        obj[key] = value
    return obj


def verify(envelope: Path, trusted_key: Path, *, expected_outcome=None, expected_task_id=None, expected_lease_id=None, expected_authority=None) -> dict:
    # A bounded read, rather than an unbounded read after a racy stat check.
    with envelope.open("rb") as file:
        raw = file.read(1_500_001)
    if len(raw) > 1_500_000: raise ValueError("envelope too large")
    data = json.loads(raw, object_pairs_hook=unique)
    if not isinstance(data, dict) or set(data) != {"version", "algorithm", "payload", "signature", "publicKey"}:
        raise ValueError("unsupported envelope")
    if type(data["version"]) is not int or data["version"] != 1 or data["algorithm"] != "Ed25519":
        raise ValueError("unsupported version or algorithm")
    def decode(name):
        if not isinstance(data[name], str): raise ValueError("invalid binary field")
        decoded = base64.b64decode(data[name], validate=True)
        if base64.b64encode(decoded).decode("ascii") != data[name]: raise ValueError("noncanonical base64")
        return decoded
    payload, signature, embedded = decode("payload"), decode("signature"), decode("publicKey")
    with trusted_key.open("rb") as file: pinned = file.read(33)
    if len(pinned) != 32 or embedded != pinned: raise ValueError("untrusted public key")
    if len(signature) != 64 or not len(PREFIX) < len(payload) <= MAX_PAYLOAD or not payload.startswith(PREFIX):
        raise ValueError("malformed signed receipt")
    Ed25519PublicKey.from_public_bytes(pinned).verify(signature, payload)
    try:
        claims = _signed_claims(payload)
    except (ValueError, TypeError) as error:
        raise ReceiptStructureError("signed bytes do not conform to the supported receipt structure") from error
    for expected, name in ((expected_outcome, "semanticOutcome"), (expected_task_id, "taskID"), (expected_lease_id, "leaseID")):
        if expected is not None and expected != claims[name]:
            raise ReceiptClaimMismatch("valid signature authenticates a different requested claim")
    if expected_authority is not None:
        actual = claims.get("authority")
        if not isinstance(expected_authority, dict) or not isinstance(actual, dict) or any(name not in actual or actual[name] != value for name, value in expected_authority.items()):
            raise ReceiptClaimMismatch("valid signature authenticates different requested authority")
    return {"signature": "VALID", "algorithm": "Ed25519", "trustedKeyMatched": True,
            "payloadBytes": len(payload), "signedClaims": claims,
            "semanticClaim": "SIGNED_RUNTIME_ASSERTION", "externalTruth": "NOT_ESTABLISHED_BY_SIGNATURE_ALONE"}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("envelope", type=Path)
    p.add_argument("--trusted-key", type=Path, required=True)
    p.add_argument("--expected-outcome", choices=("succeeded", "failed", "unknown", "unverified"))
    p.add_argument("--expected-task-id")
    p.add_argument("--expected-lease-id")
    p.add_argument("--expected-authority", type=Path, help="Bounded JSON of explicit expected authority claims")
    a = p.parse_args()
    try:
        expected_authority = None
        if a.expected_authority is not None:
            with a.expected_authority.open("rb") as source: encoded = source.read(65_537)
            if len(encoded) > 65_536: raise ValueError("expected authority size limit")
            expected_authority = json.loads(encoded, object_pairs_hook=unique)
        print(json.dumps(verify(a.envelope, a.trusted_key, expected_outcome=a.expected_outcome,
                                expected_task_id=a.expected_task_id, expected_lease_id=a.expected_lease_id,
                                expected_authority=expected_authority), indent=2))
        return 0
    except ReceiptClaimMismatch:
        print(json.dumps({"signature": "VALID", "requestedClaim": "MISMATCH"}), file=sys.stderr)
        return 1
    except ReceiptStructureError:
        print(json.dumps({"signature": "VALID", "receipt": "MALFORMED"}), file=sys.stderr)
        return 1
    except Exception as e:
        # No untrusted payload or sensitive key data in errors.
        print(json.dumps({"receiptVerification": "REJECTED", "signature": "NOT_ESTABLISHED", "errorType": type(e).__name__}), file=sys.stderr)
        return 1

if __name__ == "__main__": raise SystemExit(main())
