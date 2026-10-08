"""Independent policy controls over actual Swift/Ed25519 receipt evidence."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("trust_receipt",ROOT / "scripts/verify-rcir-receipt.py")
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
EVIDENCE = ROOT / "evidence/agency-receipt-trust-20261007/green"

class ReceiptTrustTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="public-trust-controls-")
        self.wire = Path(self.directory.name) / "receipt.json"
        records = json.loads((EVIDENCE / "runtime-records.json").read_text())
        self.wire.write_text(json.dumps(records[-1]["rcir"]["signedReceipt"]))
        self.case = json.loads((EVIDENCE / "requested-policy-matrix.json").read_text())[0]
        self.policy = copy.deepcopy(self.case["trustPolicy"])
    def tearDown(self): self.directory.cleanup()
    def verify(self,policy=None,**changes):
        options = {"mode":"live","expected_issuer":self.case["expectedIssuer"],
            "expected_task_id":self.case["expectedTaskID"],"expected_lease_id":self.case["expectedLeaseID"],
            "expected_outcome":"succeeded","verification_time":self.case["verificationTime"]}
        options.update(changes)
        return v.verify_with_policy(self.wire,self.policy if policy is None else policy,**options)
    def test_same_receipt_pin_compatibility_and_explicit_policy(self):
        pinned = v.verify(self.wire,EVIDENCE / "key-1-public.raw")
        policy = self.verify()
        self.assertEqual(pinned["signedClaims"],policy["signedClaims"])
        self.assertEqual(policy["trustPolicy"]["keyID"],"key-1")
        self.assertEqual(policy["trustPolicy"]["signingTimestamp"],"NOT_INDEPENDENTLY_ESTABLISHED")
    def test_actual_crypto_expiry_during_verification(self):
        expiry = self.policy["keys"][1]["notAfter"]
        with patch.object(v.time,"time",side_effect=[self.case["verificationTime"] / 1000,expiry / 1000 + 1]):
            with self.assertRaises(ValueError): self.verify(verification_time=None)
    def test_revoked_key_denies_backdated_live_and_historical(self):
        self.policy["keys"][1]["revoked"] = True
        for mode in ("live","historical"):
            with self.subTest(mode=mode),self.assertRaises(ValueError): self.verify(mode=mode)
    def test_freshness_does_not_silently_become_historical_acceptance(self):
        self.policy["maximumLiveAge"] = 1
        with self.assertRaises(ValueError): self.verify(verification_time=self.case["verificationTime"] + 1000)
        self.assertEqual(self.verify(mode="historical",verification_time=self.case["verificationTime"] + 1000)["signature"],"VALID")
    def test_exact_issuer_and_mandatory_uuid_bindings(self):
        self.policy["issuerID"] = "issuér"
        with self.assertRaises(ValueError): self.verify(expected_issuer="issue\u0301r")
        for name,value in (("expected_task_id",None),("expected_lease_id",None),("mode",None)):
            with self.subTest(name=name),self.assertRaises((ValueError,TypeError,AttributeError)): self.verify(**{name:value})
    def test_typed_policy_fields_duplicates_and_unknowns_reject(self):
        modifications = [lambda p:p.update(version=True),lambda p:p.update(unknown=True),
            lambda p:p["keys"][1].update(revoked=1),lambda p:p["keys"][1].update(notAfter=True),
            lambda p:p["keys"][1].update(keyID="key-0"),lambda p:p["keys"][1].update(publicKey=p["keys"][0]["publicKey"]),
            lambda p:p["keys"][1].update(retiredAt=-1),lambda p:p["keys"][1].update(unknown=True)]
        for index,alter in enumerate(modifications):
            candidate = copy.deepcopy(self.policy); alter(candidate)
            with self.subTest(index=index),self.assertRaises(ValueError): self.verify(candidate)
    def test_record_and_document_budgets(self):
        candidate = copy.deepcopy(self.policy); candidate["keys"] *= 33
        with self.assertRaises(ValueError): self.verify(candidate)
        path = Path(self.directory.name) / "oversized.json"; path.write_bytes(b" " * 131_073)
        with self.assertRaises(ValueError): self.verify(path)
    def test_bounded_policy_file_rejects_duplicate_json_fields(self):
        path = Path(self.directory.name) / "duplicate.json"
        path.write_text('{"version":1,"version":1}')
        with self.assertRaises(ValueError): self.verify(path)

if __name__ == "__main__": unittest.main()
