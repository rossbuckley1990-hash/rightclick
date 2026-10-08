"""Independent receipt/effect correlation for retained credential-return proof."""
import importlib.util
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("receipt_verifier", ROOT / "scripts/verify-rcir-receipt.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)
EVIDENCE = Path(os.environ.get("RCIR_CREDENTIAL_ECHO_EVIDENCE", ROOT / "evidence/authority-credential-return-20261007/green"))


class CredentialEchoReceiptTests(unittest.TestCase):
    def test_all_unknown_receipts_correlate_to_actual_credential_accepted_effects(self):
        summary = json.loads(next(EVIDENCE.glob("*testCredentialEchoCannotReachModelRecordEventsOrSignedReceipt*.json")).read_text())
        self.assertEqual(len(summary["effects"]), 8)
        for effect in summary["effects"]:
            with self.subTest(mode=effect["mode"]):
                result = VERIFIER.verify(EVIDENCE / ("clean-" + effect["mode"] + "-receipt.json"),
                    EVIDENCE / "trusted-public-key.raw", expected_outcome="unknown")
                self.assertEqual(result["signedClaims"]["taskID"], effect["taskID"])
                self.assertTrue(effect["credentialAccepted"])
                diagnosis = next(row for row in summary["diagnostics"] if row["mode"] == effect["mode"])
                self.assertTrue(diagnosis["recordClean"])
                self.assertTrue(diagnosis["receiptClean"])
                self.assertTrue(diagnosis["outputWithheld"])
                self.assertEqual(diagnosis["actualRequests"], 1)


if __name__ == "__main__":
    unittest.main()
