"""Independent Python checks of real Swift-signed production fixture receipts."""
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receipt_verifier", ROOT / "scripts/verify-rcir-receipt.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
FIXTURE = ROOT / "evidence/rcir-invocation-isolation-20261007/public-mcp"
KEY = FIXTURE / "trusted-public-key.raw"


class ReceiptVerifierTests(unittest.TestCase):
    def test_signed_success_and_failure_remain_distinct(self):
        for label, expected in (("success", "succeeded"), ("failure", "failed")):
            with self.subTest(label=label):
                result = verifier.verify(FIXTURE / (label + "-receipt.json"), KEY)
                self.assertEqual(result["signature"], "VALID")
                self.assertEqual(result["signedClaims"]["semanticOutcome"], expected)
                self.assertEqual(result["signedClaims"]["scopeCount"], 1)
                self.assertEqual(result["signedClaims"]["effects"], ["execute"])

    def test_expected_success_does_not_accept_a_valid_signed_failure(self):
        with self.assertRaises(ValueError):
            verifier.verify(FIXTURE / "failure-receipt.json", KEY, expected_outcome="succeeded")

    def test_expected_failure_accepts_an_authentic_failure(self):
        result = verifier.verify(FIXTURE / "failure-receipt.json", KEY, expected_outcome="failed")
        self.assertEqual(result["signedClaims"]["semanticOutcome"], "failed")

    def test_task_claim_matches_independent_provider_effect_log(self):
        effect = json.loads((FIXTURE / "effects.jsonl").read_text().splitlines()[0])
        result = verifier.verify(FIXTURE / "success-receipt.json", KEY, expected_task_id=effect["correlationID"])
        self.assertEqual(result["signedClaims"]["taskID"], effect["correlationID"])

    def test_a_different_task_is_rejected_even_with_a_valid_signature(self):
        with self.assertRaises(ValueError):
            verifier.verify(FIXTURE / "success-receipt.json", KEY,
                            expected_task_id="00000000-0000-0000-0000-000000000000")

    def test_wrong_trusted_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "wrong.raw"; key.write_bytes(b"x" * 32)
            with self.assertRaises(ValueError): verifier.verify(FIXTURE / "success-receipt.json", key)

    def test_payload_tampering_is_rejected(self):
        envelope = json.loads((FIXTURE / "success-receipt.json").read_text())
        payload = bytearray(base64.b64decode(envelope["payload"])); payload[-1] ^= 1
        envelope["payload"] = base64.b64encode(payload).decode()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tampered.json"; path.write_text(json.dumps(envelope))
            with self.assertRaises(Exception): verifier.verify(path, KEY)

    def test_a_valid_signature_does_not_make_malformed_receipt_bytes_valid(self):
        # New transient test key, never persisted. Signature-valid payload with
        # the proper domain but invalid/noncanonical ABI framing must be rejected.
        key = Ed25519PrivateKey.generate()
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        for body in (b"", b"RIGHTCLICK-VALUE-1\0n", b"RIGHTCLICK-VALUE-1\0o01:n", b"RIGHTCLICK-VALUE-1\0o999999999:"):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as directory:
                payload = verifier.PREFIX + body
                root = Path(directory); pinned = root / "key.raw"; pinned.write_bytes(public)
                envelope = root / "receipt.json"
                envelope.write_text(json.dumps({"version": 1, "algorithm": "Ed25519",
                    "payload": base64.b64encode(payload).decode(), "signature": base64.b64encode(key.sign(payload)).decode(),
                    "publicKey": base64.b64encode(public).decode()}))
                with self.assertRaises(ValueError): verifier.verify(envelope, pinned)

    def test_claim_summary_does_not_disclose_arguments_or_observations(self):
        result = verifier.verify(FIXTURE / "success-receipt.json", KEY)
        summary = json.dumps(result)
        self.assertNotIn("useful verified output", summary)
        self.assertNotIn("arguments", result["signedClaims"])
        self.assertNotIn("observation", result["signedClaims"])


if __name__ == "__main__": unittest.main()
