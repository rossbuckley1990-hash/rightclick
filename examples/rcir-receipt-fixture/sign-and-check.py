#!/usr/bin/env python3
"""Sign fixture receipts with an ephemeral key; verify through Python and OpenSSL.

The key is generated only in memory and discarded. The public key is a fixture
trust anchor, not an authenticated production RIGHTCLICK signing identity.
"""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import cryptography
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("receipt_verifier", ROOT / "scripts/verify-rcir-receipt.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def prove(output: Path) -> dict:
    key = Ed25519PrivateKey.generate()
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    pinned = output / "fixture-public-key.raw"
    pinned.write_bytes(public)
    pem = output / "fixture-public-key.pem"
    pem.write_bytes(key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
    results = []
    for name in ("success", "mismatch"):
        payload_path = output / f"{name}-payload.bin"
        payload = payload_path.read_bytes()
        signature = key.sign(payload)
        signature_path = output / f"{name}-signature.bin"
        signature_path.write_bytes(signature)
        envelope = {"version": 1, "algorithm": "Ed25519", "publicKey": base64.b64encode(public).decode(),
                    "payload": base64.b64encode(payload).decode(), "signature": base64.b64encode(signature).decode()}
        envelope_path = output / f"{name}-signed-receipt.json"
        envelope_path.write_text(json.dumps(envelope, sort_keys=True, indent=2) + "\n")
        verified = verifier.verify(envelope_path, pinned)
        command = ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(pem), "-rawin",
                   "-in", str(payload_path), "-sigfile", str(signature_path)]
        result = subprocess.run(command, capture_output=True, timeout=10, check=False)
        if result.returncode != 0: raise RuntimeError("OpenSSL rejected the Ed25519 fixture signature")
        results.append({"receipt": name, "payloadSHA256": hashlib.sha256(payload).hexdigest(),
                        "pythonVerification": verified["signature"], "opensslVerification": "VALID"})

    base = json.loads((output / "success-signed-receipt.json").read_text())
    rejected = []
    with tempfile.TemporaryDirectory(prefix="rcir-signature-negatives-") as work:
        temp = Path(work)
        variants = {}
        mutated = dict(base); raw = bytearray(base64.b64decode(mutated["payload"])); raw[-1] ^= 1
        mutated["payload"] = base64.b64encode(raw).decode(); variants["tampered_payload"] = mutated
        mutated = dict(base); raw = bytearray(base64.b64decode(mutated["signature"])); raw[0] ^= 1
        mutated["signature"] = base64.b64encode(raw).decode(); variants["tampered_signature"] = mutated
        mutated = dict(base); mutated["algorithm"] = "none"; variants["algorithm_downgrade"] = mutated
        mutated = dict(base); mutated["version"] = True; variants["boolean_version"] = mutated
        mutated = dict(base); mutated["extra"] = "unknown"; variants["unknown_field"] = mutated
        mutated = dict(base); mutated["signature"] = "AA=="; variants["truncated_signature"] = mutated
        mutated = dict(base); mutated["publicKey"] = base64.b64encode(b"x" * 32).decode(); variants["embedded_key_substitution"] = mutated
        mutated = dict(base); mutated["payload"] += "="; variants["noncanonical_base64"] = mutated
        for label, value in variants.items():
            path = temp / f"{label}.json"; path.write_text(json.dumps(value))
            try: verifier.verify(path, pinned)
            except Exception: rejected.append(label)
            else: raise RuntimeError(f"Accepted negative control: {label}")
        wrong_key = temp / "wrong-key.raw"; wrong_key.write_bytes(b"y" * 32)
        try: verifier.verify(output / "success-signed-receipt.json", wrong_key)
        except Exception: rejected.append("wrong_trusted_key")
        else: raise RuntimeError("Trusted key pin was ignored")
        duplicate = temp / "duplicate.json"
        duplicate.write_text(json.dumps(base)[:-1] + ',"version":1}')
        try: verifier.verify(duplicate, pinned)
        except Exception: rejected.append("duplicate_json_key")
        else: raise RuntimeError("Duplicate JSON key was accepted")
        # Independent OpenSSL negative control, not only the Python verifier.
        altered = temp / "altered.bin"
        data = bytearray((output / "success-payload.bin").read_bytes()); data[-1] ^= 1; altered.write_bytes(data)
        result = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(pem), "-rawin",
                                 "-in", str(altered), "-sigfile", str(output / "success-signature.bin")],
                                capture_output=True, timeout=10, check=False)
        if result.returncode == 0: raise RuntimeError("OpenSSL accepted altered payload")
        rejected.append("openssl_tampered_payload")
    report = {"scope": "Real signatures on Swift-produced local fixture receipts; not production runtime signing",
              "keyProvenance": "EPHEMERAL_FIXTURE_ONLY", "privateKeyPersisted": False,
              "cryptographyVersion": cryptography.__version__,
              "opensslVersion": subprocess.check_output(["openssl", "version"], timeout=10, text=True).strip(),
              "receipts": results, "negativeControlsRejected": rejected,
              "appleCryptoKitBackend": "NOT_RUN_ON_LINUX"}
    (output / "signature-verification-report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report

if __name__ == "__main__":
    if len(sys.argv) != 2: raise SystemExit("Expected fixture output directory")
    print(json.dumps(prove(Path(sys.argv[1])), indent=2, sort_keys=True))
