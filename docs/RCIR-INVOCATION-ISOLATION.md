# RCIR invocation isolation — 7 October 2026

Follow-on to production OpenAPI PR #42, base `fc4eb128a814e799ca545d250dd487729a42185d`, in an isolated checkout. The installed product remains published 0.2.2. This candidate is different development bytes despite reporting that version.

The candidate previously included concrete request bodies/resources/expected observations in the graph declaration. A second valid call with different arguments replaced that declaration and invalidated the first outstanding lease. The frozen real-HTTP RED reproduces this: first call rejected with `leaseUsed`, only the second effect in the separate provider log.

The trusted compiler now supplies both its stable discovered Capability ABI and the complete invocation binding to the same RCIR admission owner. Graph freshness depends on the discovered ABI, principal, effect kinds and task shape/budgets. Exact resources, request bytes, arguments, policy and verification expectations remain bound to individual immutable leases. Authorities are never combined. Endpoint/schema/effect/task/principal drift and provider withdrawal/reappearance still invalidate leases.

`publishInvocation` is host/compiler lowering, unavailable to model tools. It checks exact capability/provider/acquisition-owner identifiers and argument/result schemas. The trusted compiler must supply the full discovered declaration. Legacy `publish` retains full-contract freshness. All seven public operation names and schemas remain unchanged.

Evidence: `evidence/rcir-invocation-isolation-20261007/`.

| Gate | Actual new-run result |
|---|---|
| Frozen production RED | One test, four failed assertions, exit 1; external log contains only the second effect |
| Dispatch GREEN | 20 real-HTTP controls, exit 0; same frozen test observes both distinct requests |
| Full native | 578 tests, 26 explicit skips, zero failures, exit 0 |
| Exact-source foundation | 71 tests on macOS, including two real CryptoKit tests, exit 0 |
| Unchanged public OpenAPI proof | Seven PASS controls, real DNS-SD acquisition, separate read-back, OpenSSL-verified signed success and signed failure |
| Required alignment comparison | Exit 0, 14 published source kinds; taxonomy only, not candidate bottle proof |

The eight new portable compiler-boundary controls were authored after the meaningful production RED. They are additional regressions, not independently preregistered acceptance. The first cloned compiler cache failed because its original absolute path was embedded in generated modules. This setup failure is retained separately, not counted as RED. Frozen production test bytes and SHA-256 remain in `preregistration/`.

Public proof executable SHA-256: `b51807ea0a81e822aea55dd915d725925d5198d01f5651119314f657edaecd4c`. Task IDs link actual invocation/effect logs. Disposable signer private keys remain outside the repository.

Accepted remains unverified without external observation. Separate same-service read-back is not third-party attestation; local leases are not issuer-downscoped credentials. Signed failure remains failure. Raw receipts contain invocation data and need a production minimisation gate. Exact-head remote CI/review are pending. No merge, release, fresh candidate installation or client reconnection is claimed. The restricted AI agent, real credential broker, principal-owned network tasks/recovery and eleven-substrate proof remain unfinished. The active goal prioritises verified and cryptographically receipted execution over adding protocols.
