#!/usr/bin/env python3
"""Verify exact RCIR receipt bytes using Ed25519 and a separately pinned raw key.

Requires cryptography>=46. No trust-on-first-use, embedded-key self-trust, or
claims that a valid signature proves an external action actually happened.
"""
from __future__ import annotations
import argparse
import base64
import json
from pathlib import Path
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PREFIX = b"RIGHTCLICK-RCIR-RECEIPT-1\x00"
MAX_PAYLOAD = 1_048_576


def unique(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj: raise ValueError("duplicate key")
        obj[key] = value
    return obj


def verify(envelope: Path, trusted_key: Path) -> dict:
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
    return {"signature": "VALID", "algorithm": "Ed25519", "trustedKeyMatched": True,
            "payloadBytes": len(payload), "semanticClaim": "NOT_EVALUATED_BY_SIGNATURE_CHECK"}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("envelope", type=Path)
    p.add_argument("--trusted-key", type=Path, required=True)
    a = p.parse_args()
    try:
        print(json.dumps(verify(a.envelope, a.trusted_key), indent=2))
        return 0
    except Exception as e:
        # No untrusted payload or sensitive key data in errors.
        print(json.dumps({"signature": "INVALID", "errorType": type(e).__name__}), file=sys.stderr)
        return 1

if __name__ == "__main__": raise SystemExit(main())
