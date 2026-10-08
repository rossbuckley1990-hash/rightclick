"""Independent Python checks of real Swift-signed production fixture receipts."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receipt_verifier", ROOT / "scripts/verify-rcir-receipt.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
FIXTURE = Path(os.environ.get("RIGHTCLICK_PUBLIC_RECEIPT_EVIDENCE", ROOT / "evidence/rcir-invocation-isolation-20261007/public-mcp"))
KEY = FIXTURE / "trusted-public-key.raw"
ACK_FIXTURE = Path(os.environ.get("RIGHTCLICK_ACK_RECEIPT_EVIDENCE", ROOT / "evidence/universal-async/20261007/acknowledgement-only/receipts"))
SIGNED_FIXTURE = Path(os.environ.get("RIGHTCLICK_SIGNED_RECEIPT_EVIDENCE", ROOT / "evidence/rcir-signed-claims-20261007"))
NATIVE_FIXTURE = Path(os.environ.get("RIGHTCLICK_NATIVE_RECEIPT_EVIDENCE", SIGNED_FIXTURE / "green-transport"))


def canonical_for_test(value):
    def encode(item):
        if item is None: return b"n"
        if isinstance(item, bool): return b"b1" if item else b"b0"
        if isinstance(item, int):
            data = str(item).encode(); return b"i" + str(len(data)).encode() + b":" + data
        if isinstance(item, (str, bytes)):
            data = item.encode() if isinstance(item, str) else item
            return (b"s" if isinstance(item, str) else b"x") + str(len(data)).encode() + b":" + data
        if isinstance(item, list): return b"a" + str(len(item)).encode() + b":" + b"".join(encode(v) for v in item)
        if isinstance(item, dict):
            return b"o" + str(len(item)).encode() + b":" + b"".join(encode(k) + encode(item[k]) for k in sorted(item, key=lambda k: k.encode()))
        raise ValueError("Unsupported pressure-test value")
    return b"RIGHTCLICK-VALUE-1\0" + encode(value)


class ReceiptVerifierTests(unittest.TestCase):
    def test_actual_ack_only_receipts_preserve_all_three_semantic_outcomes(self):
        for label, outcome in (("success", "succeeded"), ("failure", "failed"), ("unverified", "unverified")):
            with self.subTest(label=label):
                result = verifier.verify(ACK_FIXTURE / (label + "-receipt.json"), ACK_FIXTURE / (label + "-trusted-key.raw"), expected_outcome=outcome)
                self.assertEqual(result["signature"], "VALID")
                self.assertEqual(result["signedClaims"]["semanticOutcome"], outcome)
                if outcome != "succeeded":
                    with self.assertRaises(ValueError):
                        verifier.verify(ACK_FIXTURE / (label + "-receipt.json"), ACK_FIXTURE / (label + "-trusted-key.raw"), expected_outcome="succeeded")

    def test_signature_valid_no_output_event_requires_no_value_and_unit_contract(self):
        original = json.loads((ACK_FIXTURE / "unverified-receipt.json").read_text())
        for alter_contract in (False, True):
            receipt = verifier._domain(base64.b64decode(original["payload"]), "RECEIPT")
            if alter_contract:
                request = verifier._domain(receipt["request"], "REQUEST")
                binding = verifier._domain(request["binding"], "BINDING")
                contract = verifier._domain(binding["contract"], "CONTRACT")
                prefix = b"RIGHTCLICK-CONTRACT-1\0"
                abi = verifier._value(contract["abi"][len(prefix):])
                abi["result"] = canonical_for_test("null")
                contract["abi"] = prefix + canonical_for_test(abi)
                binding["contract"] = b"RIGHTCLICK-RCIR-CONTRACT-1\0" + canonical_for_test(contract)
                request["binding"] = b"RIGHTCLICK-RCIR-BINDING-1\0" + canonical_for_test(binding)
                receipt["request"] = b"RIGHTCLICK-RCIR-REQUEST-1\0" + canonical_for_test(request)
            else:
                event = verifier._value(receipt["events"][-1]); event["value"] = "invented returned output"
                receipt["events"][-1] = canonical_for_test(event)
            payload = verifier.PREFIX + canonical_for_test(receipt)
            key = Ed25519PrivateKey.generate()
            public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            with self.subTest(alter_contract=alter_contract), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); pinned = root / "key.raw"; pinned.write_bytes(public)
                envelope = root / "receipt.json"
                envelope.write_text(json.dumps({"version": 1, "algorithm": "Ed25519", "payload": base64.b64encode(payload).decode(),
                    "signature": base64.b64encode(key.sign(payload)).decode(), "publicKey": base64.b64encode(public).decode()}))
                with self.assertRaises(verifier.ReceiptStructureError): verifier.verify(envelope, pinned)

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

    def test_real_signed_unknown_and_unverified_remain_non_success(self):
        cases = [(SIGNED_FIXTURE / "unverified-receipt.json", KEY, "unverified"),
                 (NATIVE_FIXTURE / "lost-response-receipt.json",
                  NATIVE_FIXTURE / "lost-response-public-key.raw", "unknown")]
        for receipt, key, outcome in cases:
            with self.subTest(outcome=outcome):
                result = verifier.verify(receipt, key, expected_outcome=outcome)
                self.assertEqual(result["signature"], "VALID")
                self.assertEqual(result["signedClaims"]["semanticOutcome"], outcome)
                with self.assertRaises(ValueError): verifier.verify(receipt, key, expected_outcome="succeeded")

    def test_lost_response_receipt_matches_the_one_real_provider_effect(self):
        evidence = NATIVE_FIXTURE
        logs = list(evidence.glob("*testLostResponseRetainsSignedUnknownAndDoesNotRetry*.json"))
        self.assertEqual(len(logs), 1, "One exact native lost-response control must supply the effect log")
        effects = json.loads(logs[0].read_text())["effects"]
        self.assertEqual(len(effects), 1)
        result = verifier.verify(evidence / "lost-response-receipt.json", evidence / "lost-response-public-key.raw",
                                 expected_task_id=effects[0]["taskID"], expected_outcome="unknown")
        self.assertEqual(result["signedClaims"]["scopeCount"], 1)


if __name__ == "__main__": unittest.main()
