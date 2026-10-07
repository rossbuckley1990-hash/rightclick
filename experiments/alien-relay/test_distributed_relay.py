"""RED/GREEN tests of cross-OS delegation, denial, and receipt verification."""
import copy
import json
import unittest
from unittest.mock import patch

import distributed_relay as relay


NOW = 1_800_000_000
RUN = "sample-run-123"
REPO = "owner/repo"
COMMIT = "a" * 40
ROWS = {
    "results": [
        {"identifier": "urn:air:huggingface:space:example-ai", "type": "application/ai-skill", "source": "HF"},
        {"identifier": "urn:air:other:example", "type": "application/json", "source": "other"},
    ],
    "referrals": [],
}
RAW = json.dumps(ROWS).encode("utf-8")


class Response:
    status = 200

    def __init__(self, raw=RAW, url=relay.ORIGIN + "/search"):
        self.raw, self.url = raw, url

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def geturl(self):
        return self.url

    def read(self, limit):
        return self.raw[:limit]


class Opener:
    def __init__(self, response=None):
        self.response = response or Response()
        self.calls = 0

    def open(self, request, timeout):
        self.calls += 1
        if request.get_method() != "POST":
            raise AssertionError("unsafe method")
        return self.response


class DelegationTests(unittest.TestCase):
    def setUp(self):
        self.delegation = relay.issue_delegation(NOW, RUN, REPO, COMMIT)

    def validate(self, **kwargs):
        values = dict(now=NOW, run_id=RUN, repository=REPO, runner_os="Windows")
        values.update(kwargs)
        return relay.validate_delegation(self.delegation, **values)

    def test_signature_and_exact_7_operation_budget(self):
        p = self.validate()
        self.assertEqual(p["ai_facing_operation_count"], 7)
        self.assertEqual(p["limits"]["max_network_calls"], 1)
        self.assertEqual(p["limits"]["max_depth"], 1)

    def test_tampered_delegation_signature_denied(self):
        bad = copy.deepcopy(self.delegation)
        bad["payload"]["grant"]["query"] = "arbitrary command execution"
        with self.assertRaises(relay.Denied):
            relay.validate_delegation(bad, now=NOW, run_id=RUN, repository=REPO, runner_os="Windows")

    def test_wrong_audience_platform_and_run_denied(self):
        for kwargs in ({"runner_os": "Linux"}, {"run_id": "other"}, {"repository": "attacker/repo"}):
            with self.subTest(kwargs=kwargs), self.assertRaises(relay.Denied):
                self.validate(**kwargs)

    def test_expiry_and_revocation_fail_closed(self):
        with self.assertRaises(relay.Denied):
            self.validate(now=NOW + 1201)
        with self.assertRaises(relay.Denied):
            self.validate(revoked_nonces={self.delegation["payload"]["nonce"]})

    def test_single_use_nonce_rejects_replay(self):
        used = set()
        self.validate(consumed_nonces=used)
        with self.assertRaises(relay.Denied):
            self.validate(consumed_nonces=used)

    def test_out_of_scope_action_denied_before_network(self):
        for orig,path,method in ((relay.ORIGIN, "/predict", "POST"),
                                 ("https://example.org", "/search", "POST"),
                                 (relay.ORIGIN, "/search", "DELETE")):
            with self.subTest(method=method,path=path), self.assertRaises(relay.Denied):
                relay.enforce_action(relay.GRANT, orig, path, method)

    def test_signed_but_broader_policy_denied(self):
        modified = copy.deepcopy(self.delegation["payload"])
        modified["limits"]["max_network_calls"] = 2
        resigned = relay.sign(modified)
        with self.assertRaises(relay.Denied):
            relay.validate_delegation(resigned, now=NOW, run_id=RUN,
                                      repository=REPO, runner_os="Windows")

    def test_empty_or_invalid_remote_discovery_denied(self):
        for sample in (b'{"results":[]}', b'{"status":"done"}', b'not json'):
            with self.subTest(sample=sample), self.assertRaises(relay.Denied):
                relay.parse_result(sample, "image generation")

    def test_provider_redirect_fail_closed(self):
        with self.assertRaises(relay.Denied):
            relay.discover(relay.GRANT, relay.LIMITS,
                           opener=Opener(Response(url="https://redirected.invalid/")))

    def test_response_byte_budget_denied(self):
        limits = dict(relay.LIMITS)
        limits["max_response_bytes"] = 5
        with self.assertRaises(relay.Denied):
            relay.discover(relay.GRANT, limits, opener=Opener())

    def test_child_signs_result_and_verifier_independently_parses_bytes(self):
        opener = Opener()
        with patch.object(relay.platform, "system", return_value="Windows"):
            receipt, raw = relay.make_child_receipt(
                self.delegation, NOW, RUN, REPO, "Windows", opener=opener)
        self.assertEqual(opener.calls, 1)
        self.assertTrue(receipt["payload"]["semantic_success"])
        self.assertEqual(set(receipt["payload"]["negative_gates"].values()), {True})
        verdict = relay.verify_chain(self.delegation, receipt, raw, run_id=RUN, repository=REPO)
        self.assertTrue(verdict["semantic_success"])
        self.assertEqual(verdict["independent_selection"]["selected_type"], "application/ai-skill")

    def test_receipt_tampering_and_response_substitution_denied(self):
        with patch.object(relay.platform, "system", return_value="Windows"):
            receipt, raw = relay.make_child_receipt(
                self.delegation, NOW, RUN, REPO, "Windows", opener=Opener())
        bad = copy.deepcopy(receipt)
        bad["payload"]["selection"]["selected_identifier"] = "forged"
        with self.assertRaises(relay.Denied):
            relay.verify_chain(self.delegation, bad, raw, run_id=RUN, repository=REPO)
        with self.assertRaises(relay.Denied):
            relay.verify_chain(self.delegation, receipt, b'{"results":[]}',
                               run_id=RUN, repository=REPO)

    def test_unavailable_provider_keeps_signed_failure_receipt(self):
        class FailingOpener:
            def open(self, request, timeout):
                raise OSError("provider absent")
        with patch.object(relay.platform, "system", return_value="Windows"):
            receipt, raw = relay.make_child_receipt(
                self.delegation, NOW, RUN, REPO, "Windows", opener=FailingOpener())
        self.assertFalse(receipt["payload"]["semantic_success"])
        self.assertIsNone(raw)
        with self.assertRaises(relay.Denied):
            relay.verify_chain(self.delegation, receipt, raw, run_id=RUN, repository=REPO)


if __name__ == "__main__":
    unittest.main()
