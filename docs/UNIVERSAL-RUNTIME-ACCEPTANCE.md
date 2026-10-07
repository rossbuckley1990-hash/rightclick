# Universal runtime acceptance — work in progress

The acceptance contract is the full eleven-substrate north star: a fresh agent
receives exactly `context_runtime`, `context_providers`, `context_inspect`,
`context_actions`, `context_explain`, `context_run`, and `context_run_status`.
Provider-specific top-level tools added must remain zero. Infrastructure readiness,
transport acceptance, fixture tests and individual PRs do not complete this gate.

## Established baseline

The initial audited main was `1f2219eafb4514b08c6364cb0ec3bb8bf105cf80`.
Its native run executed 487 tests, with 26 explicit skips and zero failures.
GitHub run `37603479313` passed on the same main commit. The installed Homebrew
0.2.2 stdio process exposed exactly seven operations; executable SHA-256 was
`d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`.
The published-source substrate inventory aligned, which does not prove behavioral
equivalence or acceptance of this candidate. Raw evidence is in
`evidence/universal-runtime-20261007/`.

Main advanced during this work: OpenAPI RCIR admission and signed outcome work
merged in #42. Subsequent integration must be tested on its actual final source;
the earlier baseline cannot stand in for those checks.

## Architecture/gap matrix

| Boundary | Actual initial main | Remaining universal-runtime gap |
|---|---|---|
| Agent ABI | Seven operations through stdio/authenticated HTTP | Fresh restricted AI acceptance across all eleven substrates |
| Acquisition | Sources → resolver registry → reflectors; OpenAPI, GraphQL, gRPC, native macOS, RIGHTCLICK federation | Arbitrary MCP tools, A2A cards/tasks, Kafka, Kubernetes and WASM interface acquisition |
| Typed contract | Bounded values/schemas/canonical contracts in ABI-001 | Production executors/public arguments still largely string maps; do not infer authority from schemas |
| Lifecycle | Native sharing callbacks; status reads retained records | Common remote task/stream polling, cancellation, recovery and uncertainty semantics |
| Authority | Origin-bound bearer references, OAuth/OIDC; confirmation | Real issuer-enforced scoped grants across authenticated substrates, expiry/revocation and out-of-scope denial |
| Policy | Engine-owned safety/confirmation and contract revalidation | Evidence-backed policy at all required acquisition/admission/execution boundaries |
| Verification | Generic text/file/image/metadata predicates; explicit accepted versus verified | Independent event consumption/control-plane read-back/remote-task observations bound to the exact invocation |
| Receipts | Initial main did not contain production RCIR receipt host; #42 adds an integration foundation | Proper trust/key lifecycle and integrity-backed receipts for every proof route |
| Portability | Runtime imports AppKit/Darwin; separate portable PR #37 exists | Real Windows/Linux execution plus live Windows withdrawal in the same agent graph |
| Provider graph | Dynamic source composition; configured OpenAPI cached until its file changed | Bounded reacquisition, safe invalidation and no stale publication during concurrent discovery |

All eleven final substrate rows remain **RED / not demonstrated** until the full
restricted-agent run supplies the required discovery, normalization, explanation,
authority, policy, execution, applicable async/stream lifecycle, independent
verification and receipt evidence. Historical proofs and these incremental tests
are supporting evidence, not replacement acceptance runs.

## DISCOVERY-LIFECYCLE-001: RED → GREEN

- **Exposing substrate:** configured REST/OpenAPI discovery. A real disposable
  loopback HTTP specification provider is stopped, then restarted with a changed
  operation, while local configuration bytes stay unchanged.
- **Generic deficiency:** configuration equality was treated as permanent
  acquisition evidence. A withdrawn provider stayed visible indefinitely and its
  changed operation was missed. The artifact cache also used wall-clock age and
  allowed concurrent older loads to overwrite a newer observation.
- **Reusable primitive:** `CapabilitySnapshotFreshness` bounds acquisition
  evidence using monotonic time. `CapabilityReflectorSource.invalidateSnapshot`
  provides a common invalidation boundary. Engine refresh propagates through
  sources. Artifact acquisition/publication is serialized. Both configured
  sources use the shared freshness contract, default five seconds, hard maximum
  five minutes; invalid/nonfinite timing does not create immortal snapshots.
- **Provider-specific layer:** zero new providers or protocol-specific engine
  branches. The existing OpenAPI compiler/transport remains in use.
- **GREEN evidence:** the frozen two-test lifecycle proof produced seven failing
  assertions on original main and zero after the change. Separate real HTTP
  request logs retain v1 and v2 acquisition. Seven additional boundary tests
  exercise expiry, clock regression/nonfinite values, lifetime limits, generic
  engine refresh, concurrent observers and invalidation during an acquisition.
  Full native regression: 496 tests, 26 explicit skips, zero failures. Existing
  concrete-binary stdio/authenticated HTTP acceptance retains exactly seven
  operations, native text conversion, policy and retained status.
- **Transfer:** the provider-neutral artifact source already serves GraphQL and
  gRPC, and future resolver kinds inherit the same bounded cache and invalidation
  contract. The boundary tests use a neutral fixture kind to demonstrate that the
  source has no protocol routing branches. This does not claim Kafka, Windows or
  WASM support has been implemented.

The real configured-source test injects its acquisition loader to a disposable
loopback HTTP origin, because production configured-provider URLs require HTTPS.
That injection is explicit; the test neither weakens production TLS policy nor
executes the logical HTTPS target. It is a Core lifecycle proof, not the final
fresh-agent experiment. A reachable descriptor alone also does not prove that a
separate execution target remains available. Liveness, authority and independent
semantic verification continue to be distinct boundaries.

## Lab and release gates

Use isolated, labeled proof resources. Cluster and namespace must be
`rightclick-proof`; the proof identity must have a namespace Role, not unrestricted
cluster-admin. Real Kafka-compatible wire protocol is required. Tokens/kubeconfigs
stay in private temporary storage; evidence records references/authority/expiry.
Preserve each failure and teardown method. Never prune unrelated Docker resources.

Exact integrated source tests, architectural controls, CI/review, publication,
fresh installation and the full restricted-agent scorecard remain separate gates.
No universal-ready release claim is made by this increment.
