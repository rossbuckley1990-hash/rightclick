# RCIR release readiness — 2026-10-07

Candidate scope: mandatory OpenAPI RCIR admission through the existing engine/compiler, atomic single-use transport start, independent bounded host-selected read-back, honest outcomes and provisioned Ed25519 receipts. Exactly seven operations are preserved. [Execution ledger](EXECUTION-LEDGER.md) and [machine state](execution-ledger.json) distinguish each lifecycle state.

| Required state | Candidate evidence/status |
|---|---|
| Implementation and meaningful RED | PASS, actual pre-change public path dispatched without RCIR; transport-boundary race separately reproduced |
| Full native regressions | PASS, 569 tests, 26 explicit skips, no failures |
| Real CryptoKit foundation | PASS, 63 assertions; Linux remote reproduction pending |
| Public OpenAPI effect/read-back/signature controls | PASS on final debug and release bytes; seven controls each |
| Release-mode artifact build | PASS; SHA256 in candidate identities |
| Exact-head remote CI/review | Pending; baseline main success does not establish candidate success |
| Merge | NOT_RUN |
| Candidate publication/source/bottle pins | NOT_RUN; immutable 0.2.2 pins retained |
| Fresh install / upgrade / client reconnection | NOT_RUN for candidate |
| Installed current seven-operation interface | PASS for existing 0.2.2, separate from candidate |
| Full eleven-substrate restricted agent acceptance | NOT_RUN |

The observer reads independently of the invocation output but trusts the same service, with no separate third-party attestation. The first slice is same-origin, credential-free GET and exact argument text. Missing observations are unverified. Legacy returned-value postconditions do not establish external effects. Unsigned receipts are possible without a provisioned signer. A valid signed failure remains failed.

Local scope restriction around an existing bearer token is not issuer-enforced credential downscoping. Receipts currently include invocation arguments and are not yet a minimised public disclosure format. Principal-owned cursor/cancellation, real streams, durable recovery, all-route RCIR coverage, and actual Windows/Linux products are unfinished gates. No universal-ready or production-trust claim is made.

An accurately scoped incremental release can proceed only after its candidate review/CI, source packaging, actual publication workflow, downloaded artifact checks, tap/bottle alignment, fresh installation and reconnected-client task acceptance pass. The current kind-alignment check compares source taxonomy and cannot prove the bottle contains RCIR. Never repoint or force-move v0.2.2. Select a new version only when the replacement has passed the applicable gates.
