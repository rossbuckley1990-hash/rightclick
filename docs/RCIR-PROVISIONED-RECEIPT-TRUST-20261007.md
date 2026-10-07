# Protected receipt policy and signing authorization

This source was reconstructed from this security agent's recorded source writes after the shared project mirror disappeared. The independent recovery checkout starts from fetched PR49 head 6ea1d3096eb7bba55417d46e7820796bef24daff. Original unpushed commit objects and original receipt/journal evidence were not recovered; this is a new provenance commit. Source files and fresh gates have explicit hashes.

## Shared production API

- RCIRProvisionedReceiptTrust(path:currentReference:clock:) retains one host-owned policy instance.
- authorization(for:) protected-refreshes policy and returns a live RCIRReceiptSigningAuthorization.
- revalidate(_:) protected-refreshes again, checks the same policy instance and key revision, and checks current live authorization.
- The token exposes issuerID/keyID/publicKey/keyRevision; its private policy identity/memberwise initializer cannot be minted by callers.
- RCIRReceiptTrustPolicy.reconcile(issuerID:records:maximumLiveAge:) validates the entire candidate before updating retained state.
- RCIRReceiptTrustJSON.validateUniqueKeys(_:) is shared raw syntax/duplicate validation before the existing closed host decoder. The caller retains its own schema and byte limit.

Root owns execution-host/configuration/provisioned-signer integration. These sources introduce no signing implementation, public agent operation or receipt wire change. Retain a loader per host: recreating it on each invocation would erase in-process tombstones.

## Enforced boundaries

Protected immutable policy snapshots read at most 131072 bytes and recheck current reference/source before accepting the document. Source access/configuration failures map to static authorityDenied; parser/policy failures are static typed errors.

The document has exactly version/issuerID/maximumLiveAge/keys; each key has exactly keyID/publicKey/notBefore/notAfter/retiredAt/revoked. Version is integer 1, intervals/freshness are bounded integer values, revocation is a Boolean, and public locators are canonical base64 for 32 raw bytes. Raw duplicate decoded fields, including escaped aliases, are refused before dictionaries can discard them. The general validator supports ordinary JSON numeric kinds; the policy reader separately requires integer-only fields.

Reconciliation permits new separately provisioned keys, earlier retirement and irreversible revocation. It refuses omitted records/tombstones, key/ID reassignment, changed original intervals, issuer/freshness changes and unrevocation. Invalid batches commit nothing. Same-key tokens survive unrelated additions; retirement/revocation changes invalidate the affected token. Authorization uses half-open intervals and retained monotonic time.

A withdrawn source can be restored legally without losing retained history. Restoring pre-revocation bytes fails. No restart-persistent/distributed revocation storage or independently trusted signing timestamp is established.

## RED to GREEN scope

**Substrate:** real held A2A exposed policy revocation while private signing bytes stayed identical. **Generic deficiency:** production admission/emission had no host issuer-policy seam. **Reusable primitive:** protected monotonic trust loader, live authorization token and shared raw duplicate validator. **Provider layer:** none. **Other substrates:** every unary/deferred/streaming receipt producer can consume the same host boundary.

The loader/parser/reconciliation scope is tested. Production GREEN still requires real host wiring: pre-revoked zero dispatch/effect, post-admission withheld signature with preserved actual observer truth, legal fresh key rotation, file withdrawal/restoration and callback races. The recovered RCIRProductionReceiptTrustTests remain intentionally RED until that wiring is added; they must not be described as a passing gate.

Fresh exact-source Foundation Mac: 116 tests, 0 failures/skips. Fresh exact-source Foundation Linux Swift 6.2: 114 tests, 0 failures/skips; the two Apple crypto controls are absent from this Foundation Linux configuration. This gate covers parser/policy/ABI structure, not full providers, protected native loader or Linux cryptography. Native Mac targeted loader/signing revalidation is being rerun in the independent checkout; its final result is recorded separately.

Installed RIGHTCLICK self-use attested Stable 0.2.2 and discovered 42 providers via context_runtime then context_providers. It did not demonstrate candidate installation, procedural-memory retrieval or a restricted seven-operation agent execution.

One executable and the existing agent ABI remain. All policy complexity is host implementation. Production issuer-policy configuration is operator-owned protected input, not provider metadata.
