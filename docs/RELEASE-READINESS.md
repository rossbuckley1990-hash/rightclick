# RCIR release readiness — 2026-10-07

Candidate scope: mandatory OpenAPI RCIR admission through the existing engine/compiler, atomic single-use transport start, independent bounded host-selected read-back, honest outcomes and provisioned Ed25519 receipts. Exactly seven operations are preserved. [Execution ledger](EXECUTION-LEDGER.md) and [machine state](execution-ledger.json) distinguish each lifecycle state.

| Required state | Candidate evidence/status |
|---|---|
| Implementation and meaningful RED | PASS, actual pre-change public path dispatched without RCIR; transport-boundary race, actual cached-schema drift, and bounded-body regression separately reproduced |
| Full native regressions | PASS, 587 tests, 26 explicit skips, no failures |
| Real CryptoKit foundation | PASS,71 native and69 Linux assertions on exact candidate; portable tests remain separate from runtime products |
| Public OpenAPI effect/read-back/signature controls | PASS on final debug and release bytes; original seven controls plus additional ten-control live freshness proof on each |
| Release-mode artifact build | PASS; SHA256 in candidate identities |
| Exact-head remote CI/review | PASS: independent security/evidence/package review and all six exact-head checks on57b5d87 |
| Foundation merge | PASS: PR42 sourcefc4eb128→c2f3bac, PR47 source57b5d87→0ed7d3a |
| Deterministic source-package/native/public acceptance | PASS, fresh extraction29 native plus7/10 public controls;177 source files unchanged |
| Candidate publication/source/bottle pins | NOT_RUN; immutable 0.2.2 pins retained |
| Fresh install / upgrade / client reconnection | NOT_RUN for candidate |
| Installed current seven-operation interface | PASS for existing 0.2.2, separate from candidate |
| Full eleven-substrate restricted agent acceptance | NOT_RUN |

The observer reads independently of the invocation output but trusts the same service, with no separate third-party attestation. The first slice is same-origin, credential-free GET and exact argument text. Missing observations are unverified. Legacy returned-value postconditions do not establish external effects. Unsigned receipts are possible without a provisioned signer. A valid signed failure remains failed.

Local scope restriction around an existing bearer token is not issuer-enforced credential downscoping. Receipts currently include invocation arguments and are not yet a minimised public disclosure format. Principal-owned cursor/cancellation, real streams, durable recovery, all-route RCIR coverage, and actual Windows/Linux products are unfinished gates. No universal-ready or production-trust claim is made.

An accurately scoped incremental release can proceed only after its candidate review/CI, source packaging, actual publication workflow, downloaded artifact checks, tap/bottle alignment, fresh installation and reconnected-client task acceptance pass. The current kind-alignment check compares source taxonomy and cannot prove the bottle contains RCIR. Never repoint or force-move v0.2.2. Select a new version only when the replacement has passed the applicable gates.

Concurrent invocation-isolation work from PR43 merged into the former feature branch after PR42 closed, rather than into main. It is preserved in PR47, accepted with combined-source controls and all six exact-head checks, and now integrated on main. Older source/binary/CI snapshots remain preserved separately.


Accepted G2 source: `57b5d87cc54c26c2b444fb232bb2ffa8e49b34c3`; actual normal merge: `0ed7d3a61ba63a36474085ec2b6f141be1b9ee3d`. [Runtime PR47](https://github.com/rossbuckley1990-hash/rightclick/pull/47), [production CI](https://github.com/rossbuckley1990-hash/rightclick/actions/runs/37628487584), [native/release CI](https://github.com/rossbuckley1990-hash/rightclick/actions/runs/37628487655), [foundation CI](https://github.com/rossbuckley1990-hash/rightclick/actions/runs/37628487561). Companion tap probePR8 and its evidencePR10 are merged;0.2.2 source/bottle/resource pins are unchanged.

The development source package SHA256 `1a400bdc3421a3e164e398dcacb4d1f7ce4d5ce0c599d3ad61e6ae66acb76f3f` is preserved for acceptance, not uploaded under the existing immutable release. Source-kind alignment is not an RCIR bottle-byte check. The current installed/connected0.2.2 executable SHA256 `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d` still lacks this candidate; matching version strings do not establish equivalent capabilities.


G3 has a real disposable issuer/provider option: the existing Kubernetes TokenRequest/API lab. It is currently rejected by native HTTPS because no cluster CA has been operator-pinned. Generic scoped transport trust, a host-only managed credential backend with identity/audience/validity, separate protected JSON observation, and receipt privacy/trust controls remain unmet. Read-only prerequisite observations are not an issuer acquisition or a G3 GREEN result.
