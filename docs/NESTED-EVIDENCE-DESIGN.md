# Nested execution evidence design

Written before implementation against portable baseline `d496cf1b240bc97a52dbb5a5a76f378fd183b074` on isolated `feature/nested-execution-fabric`. Main, releases and packaging are outside this work.

## Authenticated reports and independent truth

`ExecutionProofBinding` is an immutable exact execution/environment/parent/runtime binding. It includes the enrolled runtime, executable SHA-256, signer and key identity, authorising lease digest, capability and contract digest, and canonical request and response digests. Canonical UUID identifiers retain the repository's uppercase `UUID.uuidString` convention. Digest identifiers use lowercase SHA-256 hex. String identities are compared as UTF-8 bytes.

`ExecutionProof` adds a 32-byte challenge nonce, issue/observation/expiry timestamps, strict sequence, required predicate, provider acceptance, reported outcome, reported value and an explicit report trust boundary. `SignedExecutionProof` uses the existing Ed25519 signing/verifying interfaces. Distinct domain framing and bounded `CapabilityValue` canonical bytes bind every field. Embedded keys locate a signer; a separately pinned key is the trust anchor. Bounded wire decoding validates the body before use.

`ExecutionProofExpectation` originates at the parent. It pins every binding field, nonce, exact sequence, time bounds, predicate and expected challenge value. `ExecutionProofAdjudicator` authenticates and checks the exact expectation before calling the parent-configured observer. The observer receives the host expectation, never the child's reported observation, and queries an independent external-state path. Byte-exact canonical challenge equality means succeeded; mismatch means failed; observer exception or unavailable state means unknown. HTTP acceptance, process exit and signed child success do not enter this decision. The observer's identity and truth boundary are explicit; no hardware or provider-truth attestation is implied.

## Durable causal authorization

The adjudicator alone constructs `HostExecutionVerification`. Its persisted representation retains the full exact binding, proof digest, nonce/sequence, predicate, expected and observed value digests, observation time/deadline, independent observer identity/boundary and adjudicated outcome. The host can seal it as `SignedExecutionVerificationCertificate` using a distinct certificate domain and separately pinned host key.

`ExecutionDependency` selects execution/environment/request/proof digests and predicate with a maximum age and optional one-use consumption. `ExecutionDependencyValidator` accepts the child report only together with a valid pinned host-issued successful independent verification certificate. It rejects a child-signed success alone, modified or forged certificates, stale/cross-environment/cross-execution/request-mismatched records, wrong predicates, unknown/failed observations and causal self-dependencies. Certificate fields must match the authenticated child proof. A dependent execution binds the validated proof and certificate digests into its own immutable intent.

One-use consumption is delegated to `EnvironmentDependencyReservationStore`, whose contract requires durable atomic reservation before effect dispatch and idempotent reuse only for the same consuming execution and request digest. There is deliberately no in-memory production implementation here. Core owns the protected journal implementation and must refuse admission when durable reservation is unavailable. A restart does not restore consumed authority. Certificate persistence does not itself reserve a dependency.

## Required controls

Unit controls call the production adjudicator and dependency validator with actual Ed25519 signatures. They cover every binding mutation, body/signature tampering, unpinned keys, stale/future/expired timestamps, replayed nonce or sequence, wrong order, cross-environment/execution, malicious child success with false independent state, unavailable observation, valid independent success, and rejection of signed success as sole causal evidence. Dependency controls include wrong host key, forged/modified certificates, age/predicate/request mismatch, one-use refusal and idempotent reservation. Core's integration gate must additionally demonstrate persisted reservation across restart; unit fixtures make no crash-durability claim.
