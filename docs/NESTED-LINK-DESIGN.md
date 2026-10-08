# Nested child runtime enrollment design

Status: investigation and proposed implementation contract; no live nested
environment, enrollment, or cloud result is claimed by this document.

## Source and runtime boundary

Protected main: `df6690d0fbd2030116736a15f2fd5dff46a21a19`.
Selected portable feature base: `d496cf1b240bc97a52dbb5a5a76f378fd183b074`.
The isolated feature is `feature/nested-execution-fabric`. Main is not modified.

This design inspected the actual portable `RightClickProtocol`, `RightClickCore`,
`RightClickProviders`, and `RightClickLink` source at the feature base. It also
inspected main's legacy Federation and the cached universal candidate
`d063fa35f8507adec9ea0c584f7fb96fd9822c3e`. Those are separate implementations
and evidence scopes. No connected-runtime attestation was collected during this
investigation. Source presence does not establish installed or live capability.

The existing public operations remain `context_runtime`, `context_inspect`,
`context_actions`, `context_providers`, `context_explain`, `context_run`, and
`context_run_status`. Enrollment is host composition beneath those operations.
There is no new enrollment MCP operation or provider-specific MCP tool.

## Existing mechanisms to extend

* `RemoteNodeIdentity` wraps an explicitly supplied `RCIRReceiptSigning` signer;
  runtime and device identifiers derive from its Ed25519 public key.
* `SignedRemoteMessage` and `RemoteWire` sign domain-separated canonical bytes,
  bound size/depth, and reject unknown fields, duplicate fields, and alternate
  encodings through strict round-trip validation. Embedded metadata is not a
  trust anchor; the receiving side already supplies a separately pinned key.
* `RemoteLinkClient` pins the target and binds signed results to request digest,
  caller, runtime/device, idempotency key, execution, generation, and event
  sequence. It refuses contradictory terminal observations.
* `RemoteRuntimeRegistry` authenticates runtime/catalog exchange under that
  pinned key. Removal invalidates the enrollment generation. A catalog expires
  and cannot silently reroute an admitted request to another node.
* `RemoteReplayLedger` reserves effects durably before engine invocation. Request
  and nonce reuse fail; a fresh same-intent retry returns retained status rather
  than invoking again. Unresolved reservations survive restart as unknown.
  Protected storage failures and clock rollback deny admission. History does
  not silently reset or evict consequential reservations.
* `RemoteExecutionDispatcher` uses the original `CapabilityEngine` and its final
  admission checks. Caller messages have no confirmation flag. Only a host-owned
  `RemoteApprovalTicket` can approve the exact reviewed request and contract.
* `EncryptedOutboundLinkTransport` and its host session already implement pinned
  Ed25519 authentication, fresh X25519 agreement, HKDF, and separate ChaChaPoly
  directions. Both sides connect outbound. Do not add a public MCP listener or
  invent an alternate cryptographic channel.

The legacy `Federation.swift` path keeps its existing loopback and non-transitive
behavior. Nested runtime work belongs to actual Link, not a replacement
Federation implementation or a second execution engine.

## Required additions

The current `RemoteRuntimeDescriptor` identifies protocol version, key-derived
runtime/device, OS, architecture, and operations. It does not attest product
version, executable SHA, environment identity, or parent lineage. Its assertions
are authenticated node statements, not independent environment measurements.
`RemoteCallerGrant` restricts exact operation/capability IDs but does not implement
signed attenuating lifetime, execution, descendant, depth, or resource budgets.
The CLI has no automatic network Link startup or enrollment command at this base.

Add a small child-enrollment model in Protocol and its verifier/host composition
in Link. Keep provider observations in the provider contract and lineage in the
environment ledger. Reuse the existing Link codec, signer, dispatcher, registry,
transport, and replay ledger. Wire-format additions need an explicit version;
do not make strict v1 decoders silently accept previously unknown fields.

Suggested implementation contract:

```swift
struct ChildRuntimeClaim: Codable {
    // schema version, enrollment ID, and parent-generated challenge
    // environment ID and immutable provider resource/incarnation identity
    // parent environment ID, parent execution ID, parent runtime/key identity
    // RIGHTCLICK version, executable SHA-256, platform, architecture
    // child public key, key-derived runtime/device IDs
    // bootstrap intent ID, issued time, expiry
}

struct ExpectedChildRuntime {
    // trusted build manifest and exact persisted bootstrap/lineage expectation
}

struct IndependentlyObservedChildRuntime {
    // provider/control-plane observation, resource incarnation, observed key,
    // executable/immutable image measurement, OS/architecture, observation time,
    // and an explicit trust/evidence boundary
}

struct EnrolledChildRuntime {
    // immutable verified binding plus registry enrollment generation
}

func verifyChildEnrollment(
    signedClaim: Data,
    expected: ExpectedChildRuntime,
    observation: IndependentlyObservedChildRuntime,
    now: Int64
) throws -> EnrolledChildRuntime
```

These are design names, not a requirement to duplicate stronger existing
environment models. Observation and expected manifest must come from the
host-controlled provider/ledger path. The AI and child cannot supply their own
trusted observation, manifest, observer endpoint, or pin.

## Identity custody and first enrollment

1. Before any bootstrap effect, the parent records an enrollment/bootstrap intent,
   environment/provider incarnation, lineage, immutable expected build manifest,
   random 32-byte challenge, and bounded expiry. Its existing execution identity
   correlates create, bootstrap, and enrollment. An uncertain retry reconciles
   that intent rather than provisioning another identity or environment.
2. The child generates one Ed25519 signing key on its execution node using
   CryptoKit on macOS or the already pinned Swift Crypto dependency on Linux.
   Wrap it in `RemoteNodeIdentity`. Do not copy the parent's private key or cloud
   credentials. The parent supplies only its public identity and bounded
   bootstrap configuration to the child.
3. The provider's authenticated management/observation channel independently
   obtains the child public identity and the exact resource/process/image
   measurements at the expected bootstrap target. This supplies the first pin.
   A key in a child response or relay catalog cannot pin itself.
4. The child signs a domain-separated canonical claim containing every binding
   above and the parent challenge. The parent verifies the signature against the
   separately observed key, not against the claim's embedded key alone.
5. The parent checks exact equality with its persisted bootstrap and expected
   manifest: environment, provider incarnation, version, SHA, OS/architecture,
   parent environment/execution/runtime, and expiry. Observation must be fresh,
   correlate with this bootstrap intent, and precede activation. An unreadable
   executable hash, missing measurement, mismatch, future claim, stale
   observation, or partially enrolled child denies activation.
6. Reserve/consume the enrollment challenge and persist the binding before
   activating the child registry or issuing a lease. An exact retry of the same
   enrollment intent/digest may recover the same binding; a changed intent under
   the same identifier is an idempotency conflict. Exact signed envelope replay
   remains rejected. Missing/corrupt replay history does not create a new epoch.
7. Construct the existing `RemoteLinkClient` with this pin and enroll through
   `RemoteRuntimeRegistry`. Link's authenticated runtime descriptor must agree
   with the independently bound key/platform/architecture. Enrollment generation
   belongs to the environment incarnation; explicit removal cannot revive an old
   owner. Key replacement requires a new verified bootstrap incarnation.

Ephemeral means bounded to the environment incarnation, not regenerated on every
request. Node-local custody must persist for an authorized runtime restart or
restart must explicitly invalidate enrollment and require fresh bootstrap. The
implementation must not silently generate a replacement key after custody loss.
Terminate the signer-owning process and remove custody during teardown. Swift
value copies and software crypto do not guarantee memory zeroization; do not
claim hardware-backed custody or anti-rollback.

## Replay, approval, and recursion

Continue all workload traffic through `RemoteExecutionDispatcher`. Signed lease
admission adds a host-owned gate; it must not turn a child's `confirmed=true`,
lease, or signed claim into user consent. A capability requiring confirmation
still needs the existing exact host approval ticket, or a narrowly specified
host approval service that checks the approved parent intent and exact child
request. Absence leaves `awaiting_user`. Recheck lease expiry/revocation, lineage,
environment state, and current contract at the final engine admission boundary.

Use the existing durable Link request/nonce/idempotency reservations for runs.
Enrollment adds its own typed domain and bounded reservation in that same trusted
storage boundary; do not disguise enrollment as an unverified successful run.
Atomic reservation must precede activation. Resource and lease counters require
durable atomic admission too, so concurrent children cannot double-spend a
remaining execution/descendant budget. Counters and irreversible unknown
reservations cannot be discarded to make room for more work.

Recursion should expose a locally owned contextual environment capability at
each child. Existing Link excludes `remote:` actions from export and execution;
preserve that constraint. Each subordinate environment has explicit lineage and
an attenuated lease. Do not implement arbitrary transitive routing to bypass it.

A child creating an environment still requires provider authority. The current
Link does not broker cloud credentials. Either provision an actual provider-issued
restricted credential locally to that node, or implement a parent-mediated
environment provider beneath the generic provider boundary: child requests a
bounded generic environment action over Link and the parent keeps its cloud
credential. A full parent cloud bearer cannot be injected into children. A broker
implementation must bind the child signature/lease/lineage and budgets before
dispatch; merely hiding a broad token from MCP is insufficient attenuation.

## Evidence and independent verification

Child signatures authenticate identity and immutable report bytes. They do not
establish a semantic result. Link's existing signed summaries explicitly state
an execution-node observation boundary. A malicious child can still sign a lie.
The nested parent must not promote that assertion to final success.

The requested workload challenge, environment/incarnation, execution, lease,
request/response hashes, parent relationship, timestamp, and nonce must be bound
to its signed proof. Parent-selected observation evaluates the exact challenge
through an independent mechanism and only then promotes semantic outcome.
Missing observation stays accepted/unverified or unknown; a observed mismatch
fails even if both children report success. Expired, reused, forged, reordered,
or cross-environment/execution evidence cannot satisfy a causal dependency.

Destruction first revokes leases and disables new admission, then shuts down
descendants deepest-first. Stop Link sessions and remove registry enrollment,
but retain protected replay history and non-secret evidence. Provider delete
acceptance is not absence. Independent resource absence and no active child
session/lease are separate predicates; a partition leaves unknown/reconciling
status, not successful teardown.

## Limits and threat boundary

Independent provider management observation is a stronger source than child
self-report, but it trusts that provider/control plane. It is not hardware remote
attestation. A root-compromised VM may falsify process observations or use an
extracted private key. Prefer immutable verified images, read-only executable
storage, unprivileged runtime/workload separation, bounded egress and short leases.
Document the actual provider measurement method. If a provider cannot measure the
requested executable/platform, enrollment remains unverified; do not fill absent
observations with expected values.

There is a measurement-to-use race without a provider/hardware-enforced immutable
execution boundary. Rechecking current environment incarnation and narrow leases
reduces exposure but does not prove post-measurement integrity. Parent independent
semantic verification remains necessary even for correctly enrolled children.
Clock checks stay strict; skew can deny authentic requests. Admin rollback of all
trusted node storage is outside software anti-replay guarantees. The relay can
deny availability. Environments need independent TTL/reconciliation protection
because a crashed parent cannot promise cleanup from its own timer.

No live cloud configuration, signer custody, deployed enrollment supervisor, or
cross-machine nested proof was demonstrated during this design investigation.
Those require separate implementation and exact test/runtime evidence.

## Enrollment acceptance controls

Require exact production-path tests for wrong executable SHA/version/platform/
architecture; environment/provider incarnation mismatch; wrong parent execution
or parent key; self-pinned rogue child; claim/key/signature mutation; challenge
reuse; enrollment identifier conflict; future/expired/stale claim or observation;
partially enrolled runtime; missing/corrupt durable history; concurrent activation;
restart custody loss; removed generation reuse; malformed signed Link input; child
confirmation bypass; revoked/expired lease at final admission; and malicious child
success without the parent's independently observed challenge. Preserve every
existing Link replay, idempotency, approval, lifecycle, and credential-isolation
control. Tests using independent fake-provider observations must label that scope;
they do not establish a real cloud measurement or environment.
