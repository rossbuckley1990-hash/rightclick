# Accepted, observed, and cryptographically receipted

This follow-on preserves all seven operations. It strengthens independent verification of the actual production receipts rather than adding a protocol or another dispatcher. Candidate scope is stacked on PR #43/#42. The tap companion PR #9 adds independent executable pinning while preserving PR #8's schema fingerprints.

The existing host distinguishes provider acceptance from a separately observed postcondition, and signs only after dispatch and outcome bookkeeping. The independent Python verifier previously verified signatures without interpreting the signed claims. Frozen tests exposed a concrete gap: correctly signed receipt-prefixed bytes with malformed ABI framing passed. A consumer also had no way to check that a valid signature authenticated the task/outcome it expected.

The verifier now decodes the existing domain-separated typed ABI with explicit byte/depth/node/count limits and canonical framing checks. It validates terminal receipt structure and returns a bounded claim summary: task/lease identity, provider generation, phase, semantic outcome and exact-scope count/effect kinds. It prints no arguments, resource locations, returned values or observations. This summary does not minimise the underlying raw receipt; production disclosure remains a separate gate.

Optional `--expected-outcome`, `--expected-task-id` and `--expected-lease-id` compare against the signed bytes after independently pinned signature verification. A valid signature with a mismatched requested claim remains signature-valid and is rejected. Signature-valid malformed bytes are reported as malformed. Unknown/untrusted signatures remain unestablished. Failure, unknown and unverified can never satisfy an expected succeeded claim.

## Actual evidence

`evidence/rcir-signed-claims-20261007/` retains the frozen nine-test verifier RED, with three malformed signed-payload failures and seven errors for missing claim handling. Those frozen controls pass after implementation. Two additional regressions use actual signed unknown/unverified results. There are eleven independent verifier tests in total.

The unchanged live seven-operation OpenAPI transcript supplies succeeded, failed and unverified receipts, each correlated to exactly one separately captured provider effect. For unknown, a real Python HTTP provider writes its append-only effect log, then deliberately closes the connection before any acceptance response. The actual engine retains unknown, sends only one mutation, and signs an unknown receipt. A separately captured public key verifies that receipt through Python; CryptoKit checks it in the native test. This unknown control uses the real engine/transport, not the public MCP agent; the distinction is explicit.

The transport control was first run against the ordinary reply fixture: accepted/unverified, two failed assertions when expecting unknown. That is a fault-setup control, not a pre-change runtime defect. Only after injecting the disclosed dropped-reply fault does the same test pass. Twenty-one actual HTTP dispatch controls and the full 579-test native suite pass; 26 environment-gated skips remain skips.

`scripts/acceptance-rcir-signed-evidence.py` consumes both actual runs, checks the recorded seven-tool surface/calls, verifies all four signed outcome claims against separately captured effect IDs, and rejects success promotion, tampered bytes and wrong trust pins. CI runs this after fresh native and public acceptance; the frozen original public proof remains unchanged. It uses the version-pinned cryptography 50.0.1 backend and retains receipts, effects and transcripts as artifacts.

## Reproduce

```sh
RCIR_DISPATCH_EVIDENCE=/tmp/rcir-native swift test --force-resolved-versions --filter RCIRProductionDispatchTests
python3 scripts/acceptance-rcir-openapi.py .build/debug/rightclick /tmp/rcir-public
python3 -m unittest discover -s Tests -p 'test_rcir_receipt_verifier.py' -v
python3 scripts/acceptance-rcir-signed-evidence.py --public /tmp/rcir-public --native /tmp/rcir-native --output /tmp/rcir-claims
```

The Python commands require the existing cryptography dependency. The native and public runs provision disposable, separately pinned signer keys. They do not establish production signing identity, key rotation/revocation, issuer-downscoped provider credentials or a restricted LLM-agent proof. Leases prove local exact-resource containment; independent same-service read-back trusts that service. A signature authenticates the runtime's assertion, not the honesty of a compromised runtime/provider or current resource state. These are historical receipts; replay/expiry/freshness are not invented from signature validity.

The goal remains active. Next dependency-ready work is production authority/observer/signer trust and receipt minimisation, followed by the host-restricted agent and live removal/stream controls. No universal-ready release, fresh installation or all-eleven-substrate result is claimed.
