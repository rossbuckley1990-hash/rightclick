# Nested execution fabric: design before implementation

Status: proposed architecture, written before nested production changes. The lead advanced only the isolated feature branch to the reviewed portable prerequisite `d496cf1b240bc97a52dbb5a5a76f378fd183b074`, a direct descendant of protected main; The user confirmed this portable base and excluded the old main test baseline from regression; its baseline completed before implementation: 774 executed, 745 passed, 0 failed, 29 skipped. This document is not an implementation or live-cloud acceptance claim.

## Protected starting point and existing architecture

The isolated feature branch is `feature/nested-execution-fabric`, initially based on protected main `df6690d0fbd2030116736a15f2fd5dff46a21a19`. Main, release tags and Homebrew distribution are outside this change. The lead owns baseline results and exact MCP schema snapshots; this design does not invent test counts.

The exact public operation vocabulary at the protected base is:

- `context_runtime`
- `context_inspect`
- `context_actions`
- `context_explain`
- `context_run`
- `context_run_status`
- `context_providers`

`Sources/RightClickMCP/Server.swift` publishes these seven. Capability arguments are an optional `[String: String]` object. New nested capabilities must use that existing argument channel and ordinary capability IDs; there must be no new cloud/VM/container MCP tools or provider-specific input fields at the public boundary.

Main has one macOS `RightClickCore`, not separate Protocol/Core/Providers/Link targets. `CapabilityEngine` owns contextual discovery, confirmation, reflector routing, execution IDs and verification adjudication. `ContextualCapabilityReflectorSource` already varies discovery by `ContentItem`. `RCIRExecutionReflector` already enters host-owned RCIR admission immediately before transport dispatch. `CapabilityValue` supplies bounded, typed canonical bytes; it is the canonicalisation mechanism to extend. `RCIRSignedReceipt` uses injected Ed25519 signers and separately pinned verification keys. Existing `ExecutionStore` and `RCIRAdmission` are in memory. Main's federation is a conservative loopback bearer MCP peer, disallows transitive federation, and must remain intact.

Portability is a distinct prerequisite, not a property to infer from Foundation-only tests. The clean existing portable/fabric candidate at `d496cf1b240bc97a52dbb5a5a76f378fd183b074` was inspected read-only. It separates `RightClickProtocol`, `RightClickCore`, `RightClickProviders`, native macOS hosts and `RightClickLink`; it already has signed requests/results, `RemoteNodeIdentity`, `RemoteExecutionDispatcher`, host local approval, `RemoteRuntimeRegistry`, protected durable `RemoteReplayLedger`, bounded lifecycle/events and Linux swift-crypto. The historical universal PR49 object `e09f0179f738189fb30b87c652a5433fba648054` was also inspected; its direct A2A/Kafka/Kubernetes/WASM/D-Bus compiler inventory does not establish those paths on main. Integration now reuses that portable prerequisite on this feature branch rather than reconstructing or weakening Link. Baseline and final full-platform results must still be recorded independently; merely adopting source does not prove a Linux child ran.

## Smallest extension and ownership

The feature adds a resource model and a host-owned execution service beneath the existing generic interface. It does not add a competing agent runtime or dispatcher.

| Layer | Responsibility | Proposed ownership |
| --- | --- | --- |
| Protocol/model | Canonical environment identifiers, specs, observations, lineage, lease and proof bodies, dependency selectors | Architecture/core plus security owner |
| Core | Environment ledger, admission/reservation, state transition checks, dependency adjudication, deepest-first teardown, reconciliation | Environment/lifecycle owner; evidence owner for adjudication |
| Providers | One configured provider adapter and deterministic test adapter; node-local credentials; exact provider observation | Environment provider owner |
| Link | Enrolment, ephemeral child key, authenticated requests, lease enforcement at child admission, protected replay state | Link/security owner |
| Existing discovery/engine | Contextual environment source/reflector registration, parser support, confirmation and status projection | Lead integration owner |
| Tests/review | Original regression, adversarial controls, process integration and independent architectural review | Independent assigned reviewers |

On the adopted portable prerequisite, wire types belong in `RightClickProtocol`, management in `RightClickCore`, cloud adapters in `RightClickProviders`, and enrolment/transport binding in `RightClickLink`. The provider contract belongs in Protocol so Core can accept an injected provider without depending on provider-specific implementation.

## Initial API agreement

The coordinated initial names are `EnvironmentState`, `EnvironmentResources`, `EnvironmentSpec`, `EnvironmentLineage`, `EnvironmentHandle`, `EnvironmentPresence`, `EnvironmentObservation`, `EnvironmentCreateIntent`, `EnvironmentProviderAcceptance`, `EnvironmentProviderSupport` and `EnvironmentProvider`, in `Sources/RightClickProtocol/Environment.swift`. Preserve the existing `RuntimeEnvironment` name for platform routing; it is not a VM resource handle.

- `EnvironmentSpec`: approved `profileID`, `lifetimeMilliseconds`, `resources`; a profile pins runtime manifest and permitted network destinations.
- `EnvironmentResources`: integer `cpuCount`, `memoryMiB`, `maximumCostUnits`, explicit `costUnit`; validated against finite host hard bounds.
- `EnvironmentLineage`: `rootEnvironmentID`, optional `parentEnvironmentID`, `parentExecutionID`, `parentRuntimeID`, and bounded `depth`; parent fields come from authenticated context.
- `EnvironmentCreateIntent`: `environmentID`, `correlationID`/idempotency key, `creationExecutionID`, spec, lineage, absolute expiry. Exact canonical intent is persisted before dispatch.
- `EnvironmentHandle`: `environmentID`, `providerID`, `providerResourceID`, `correlationID`, lineage, spec, expiry. All locator/identifier strings are strictly bounded and non-secret.
- `EnvironmentObservation`: exact environment/correlation/provider resource identity, `presence` (`present`, `absent`, `unknown`), observed state/time, bounded independent runtime facts and explicit observation trust boundary. No secret transport body.
- `EnvironmentProviderAcceptance`: accepted/rejected/unknown provider boundary and optional non-secret locator/message; this is never semantic success.

The runtime manifest/observation are Protocol types (`EnvironmentRuntimeManifest` and `EnvironmentRuntimeObservation`) so Providers need no dependency on Link. Core owns `EnvironmentCoordinator` and a protected durable `EnvironmentLedger`; discovery uses an ordinary `EnvironmentCapabilitySource`/reflector. Link owns `ChildRuntimeClaim`/enrolment verification and subject key custody. The security/evidence owner freezes `CapabilityLease`, `SignedCapabilityLease`, `ExecutionProof`, `SignedExecutionProof` and `ExecutionDependency` fields using these IDs. Core never imports Link; inject a narrowly scoped child-enrolment verifier interface or closure into the coordinator rather than introducing a dependency cycle.

## Environment resource and provider boundary

`rcenv://<canonical-id>` is a provider-independent contextual object. The identifier uses canonical `UUID.uuidString` spelling (uppercase, matching existing execution IDs) chosen by the host; reject userinfo, ports, path, query, fragment, encoded aliases and noncanonical IDs. `rcenv://fabric` is the explicitly configured root factory resource. The parser must recognise these before its ordinary text/path fallback. It must not resolve an environment URI as an arbitrary network URL or filesystem path. Plain text, file and http(s) parsing stays unchanged.

An environment handle contains only a host environment ID, a configured provider key, a non-secret provider resource locator, creation execution ID, immutable lineage, spec digest, expiry and last observed generation. The provider key selects installed host configuration; callers cannot nominate an endpoint, image registry, bearer token, shell command or credential path. A URI is a locator, never authority.

The minimal `EnvironmentSpec` is a named operator-approved Linux runtime profile plus bounded lifetime, memory/CPU ceilings and a parent relationship derived from authenticated context. The profile pins architecture, runtime version, executable SHA-256 and immutable deployment artifact. The child cannot override those pins or choose an arbitrary workload/image. Cost uses integer units and an explicit unit/currency identifier, avoiding floating point widening. Unknown/unmeasurable provider spend is denied for unattended recursive creation unless an operator profile supplies a conservative hard bound.

The production provider contract should have only these host-only operations:

```swift
protocol EnvironmentProvider {
    var id: String { get }
    var support: EnvironmentProviderSupport { get }
    func create(_ intent: EnvironmentCreateIntent) throws -> EnvironmentProviderAcceptance
    func observe(correlationID: String) throws -> EnvironmentObservation
    func list() throws -> [EnvironmentObservation]
    func bootstrap(_ handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest) throws -> EnvironmentProviderAcceptance
    func executeChallenge(_ handle: EnvironmentHandle, executionID: String, challenge: String) throws -> EnvironmentProviderAcceptance
    func observeChallenge(_ handle: EnvironmentHandle, executionID: String) throws -> String?
    func stop(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance
    func destroy(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance
}
```

Provider acceptance is a separate type from observation. `create` returning normally does not mark the environment ready. `destroy` returning normally does not mark it destroyed. `observe` has three explicit presence outcomes: present, absent and unknown; exceptions, authentication failures, timeouts and malformed responses are unknown, never absent. A provider must independently inspect the exact correlation/identity and report bounded non-secret facts. Provider names and locator strings can appear in operator diagnostics, but their proprietary request schemas do not become public MCP tools.

Cloud credentials stay at the parent execution node. A child creation request returns through authenticated Link to the parent's environment broker, which admits it under the child's lease. The child receives no parent cloud credentials. The broker derives parent environment/runtime fields from the authenticated session and immutable enrolled lineage, not from untrusted caller fields. This gives A enough authority to create B without handing A an unrestricted cloud token.

## Lifecycle and durable correlation

The environment state machine is separate from the existing execution state enum:

```text
creating -> bootstrapping -> ready -> running -> ready
     |            |           |         |
     +------------+-----------+---------+-> failed / unknown
ready / running / failed / unknown -> stopping -> destroying -> destroyed
```

`destroyed` is terminal only after exact absence observations for that resource and all descendants. `unknown` preserves an uncertain external effect and remains reconcilable. `failed` does not erase a potentially existing resource. Runtime enrolment is separately pending/enrolled/revoked; a created VM is not an enrolled child.

Before any effect, the protected durable ledger atomically reserves the immutable create intent: correlation ID, idempotency key, owner, spec digest, parent environment/execution/runtime, bounds, deadline and proposed environment ID. Flush this intent before provider dispatch. A retry with the same key and same canonical intent returns the original handle/status; a different intent conflicts. Provider creation must use native idempotency where available and deterministic tags/name containing the host correlation ID otherwise. After ambiguous create, reconcile that correlation before any retry. More than one matching resource is an unsafe duplicate requiring cleanup, never a successful handle.

Use the existing protected Link journal's ownership, no-follow, bounded reads, interprocess lock, atomic rename and fsync conventions for the environment/evidence journal. Do not extend the in-memory `ExecutionStore` and call it crash recovery. The ledger retains provider acceptance and observations as distinct events and materialises status for `context_run_status`. Capacity exhaustion rejects new effects while retaining records needed for revocation and cleanup. Do not compact replay tombstones while their credentials remain usable.

Every managed environment has a provider-enforced TTL or equally strong provider-visible shutdown deadline and a parent reconciler. A local timer alone cannot protect against parent crash. If the selected provider cannot enforce termination/TTL, label this limitation and require an external operator janitor; do not claim strong orphan prevention. Reconciliation lists only resources bearing a pinned host ownership marker, checks the full lineage/correlation before touching them, and never deletes arbitrary provider resources based on a user string.

## Dynamic capabilities through the seven operations

A configured `EnvironmentCapabilitySource` enters `ContextualCapabilityReflectorSource`. Its ordinary reflector capabilities are provider-independent actions such as create, observe, bootstrap, run approved workload, create child and destroy. The applicable action set is the intersection of provider support, current independently observed state, host policy, caller identity, valid lease, remaining budgets and enrolled runtime state. Discovery denies missing/unknown authorisation and reveals no secrets. This intersection must be checked again at dispatch; discovery is not admission.

Use stable IDs such as `environment:create`, `environment:observe`, `environment:bootstrap`, `environment:execute`, `environment:create-child`, `environment:destroy`, with ownership assigned by the engine. Action metadata explains profile/bounds and verification prerequisites in generic terms. Arguments are closed allowlists of strings, parsed strictly into canonical numbers/IDs. Unknown arguments, parent-ID spoofing and malformed URI aliases reject. Initial workload support is a single named challenge workload, not arbitrary shell execution.

The existing engine remains responsible for confirmation. Create/bootstrap/workload/destroy are external, code-execution, financial or destructive capabilities and retain confirmation unless a host-provisioned narrow local approval explicitly covers that exact intent. A remote `confirmed: true` cannot grant consent. Child admission uses existing host local approval and revalidates it with the grant/lease immediately before the provider effect. No wrapper may bypass these checks by calling the provider directly.

`context_run_status` projects the durable execution and environment ledger under the existing operation. Existing `ExecutionState` values and their meanings are preserved. New environment lifecycle facts appear as evidence/output, not as a redefinition of `accepted` or `succeeded`.

## Ephemeral child enrolment

A child generates an ephemeral Ed25519 private key on the execution node. Private key custody never crosses into a caller, relay, evidence or log. A single-use parent enrolment challenge binds expected environment ID, parent runtime/execution/environment, profile digest, expected executable SHA/version/platform/architecture, expiration and nonce. It is provisioned through the operator-approved bootstrap mechanism; the child proves possession of its key with a signed response. Parent pins the enrolled public key only after checking the challenge and exact environment binding.

The enrolment result records independently observed provider resource identity, independently retrieved/observed executable digest where the adapter supports it, challenge proof, actual runtime version/platform/architecture and ephemeral public identity. A child's claimed SHA/version are assertions until the parent has a separate observation path. No hardware attestation is implied: a compromised VM can lie about its process; signed bytes identify the holder of the enrolled key, not untampered hardware. Wrong SHA, environment, parent, architecture or key fails closed; partially enrolled resources remain cleanup targets without workload authority.

Authenticated child requests use the existing Link request/result signing, bounded decoding, exact target identity, local approval and durable replay reservation. Extend those bindings with environment and lease identity rather than creating an unsigned alternate protocol. Existing loopback federation remains nontransitive; nested Link lineage is explicit and bounded, not automatic re-export of federation IDs.

## Signed capability leases and attenuation

The existing one-use `RCIRLease` remains local invocation admission. A distributed `CapabilityLease` is a signed, revocable authorisation document that constrains which local RCIR leases the child may receive; it does not replace local admission or contain provider credentials.

The canonical signed body binds version/domain, lease ID, issuer key identity, subject enrolled runtime/key identity, environment ID, parent lease digest, issuing execution ID, exact allowed capability IDs and profile IDs, issue/expiry times, nonce, executions, direct-child count, total descendants, remaining delegation depth, resource ceilings, total cost ceiling/unit and an explicit network allowlist. Required limits cannot be omitted or mean unlimited. Sign with existing Ed25519 interfaces over `CapabilityValue` canonical bytes under a lease-specific domain. Verification uses the previously pinned issuer key, not an embedded key as authority.

Admission rejects invalid signatures, wrong issuer/subject/environment/session, expiry or clock rollback, revoked lease or ancestor, unknown capability, depleted reservation, stale lineage and unauthorised network/resource profile. Reserve execution/child/cost budgets atomically before an effect. A child lease must be a byte-exact subset/intersection of its parent's capability/profile/network sets; expiry is no later; scalar ceilings cannot increase; its depth is strictly less. Allocation decrements a shared ancestor budget, so siblings cannot each receive the entire parent count/spend allowance. Revocation invalidates descendants before teardown and rejects future dispatch while preserving evidence/status reads.

Conservative initial host defaults: nesting depth 1 below the first child, one direct child, two total managed descendants, 15 minute environment TTL (hard ceiling one hour), 5 minute lease lifetime, 8 executions per lease, one CPU and 512 MiB memory per environment; an explicit configured cost ceiling is required for live unattended creation. Hard ceilings are host constants and cannot be raised by a child/profile argument. These values are proposed defaults to be reviewed with the chosen provider's minimum shape.

A stolen bearer lease alone does not work: requests require proof of the subject private key. A stolen subject key permits only the remaining constrained authority until revocation/expiry; this is documented rather than claimed impossible.

## Proof, independent verification and causal dependencies

A portable evidence body binds version/domain, execution ID, environment, parent execution/environment/runtime, enrolled runtime identity and executable SHA, authorising lease digest, capability/contract digest, canonical request hash, response hash, challenge nonce, provider acceptance, observations and their trust boundaries, required predicates, outcome, observed/expiry times, sequence and signer identity. Sign exact canonical bytes with a proof-specific Ed25519 domain. The signature authenticates who reported bytes; it does not establish semantic success.

A child may sign accepted/unverified/failed proof. The parent verifies signature, pinned signer, exact execution/environment/lease/request/challenge bindings, order, time window and fresh nonce. Then a separate parent observer reads the externally visible challenge through a fixed operator-configured observation path bound to the exact environment and execution. It must not consume the child's claimed observation as reality. Exact challenge mismatch is `failed`; missing/partitioned observation is `unknown` or accepted/unverified according to existing semantics. HTTP 2xx, process exit 0 and child success cannot establish `succeeded`.

Initial independent observation can be provider-mediated resource output/file observation through a fixed adapter, but the documented trust boundary remains the provider. A genuine cloud acceptance should use a separately queried resource/process endpoint with invocation-bound challenge; a deterministic test provider must maintain independent actual state separately from configurable reported results so false-success tests exercise the production adjudicator.

A dependency is a host-resolved selector for an earlier ledger evidence record: execution ID, environment ID, expected request/proof digest, required predicate/outcome, maximum age and optional one-use consumption. Dependency references can use the existing string argument channel on the relevant capability; no new MCP schema is required. Before admitting B, verify A's persisted signed envelope, pinned signer, exact causal lineage, fresh successful independent observation and required predicate. Bind the dependency digests into B's request/lease/proof. Missing, forged, stale, semantically wrong or cross-environment/execution evidence rejects dispatch. Cycles are rejected. One-use dependency reservations survive restart; retries of the same admitted intent reuse the reservation rather than consume it twice. Signed evidence can remain queryable after teardown without remaining valid as a fresh authorisation dependency.

## Recursive teardown and reconciliation

Freeze new descendant admission and revoke the root/subtree leases first. Take a bounded, validated lineage snapshot from the durable ledger and reconcile provider correlation markers for uncertain/pending creations. Reject cycles, contradictory parents and ambiguous identities. Destroy deepest-first: B before A. Each child gets a persisted idempotent destroy intent, accepted response, and independent exact absence observation. Only then may its ancestor be declared destroyed. Unknown absence stops success and records resumable teardown; it must not skip to an apparently clean parent.

Duplicate destroy returns retained progress and re-observes uncertainty without creating resources. Interrupted teardown resumes the same intents after restart. Runtime sessions are invalidated independently of VM deletion. At completion, all descendants are independently absent, no enrolled child session or valid descendant lease remains, and immutable execution/evidence records remain queryable. A parent disappearing alone is not proof its descendants disappeared.

## Threats and explicit limitations

| Threat | Required defence/control |
| --- | --- |
| Malicious child, forged/modified evidence | Pinned Ed25519 identity, complete canonical binding, parent observer; child signed success alone never succeeds |
| Replayed/reordered/stale evidence or request | Durable replay/intent reservation, fresh 32-byte nonce, strict sequence/time, execution/environment binding |
| Privilege amplification or stolen lease | Subject proof of possession, exact subsets, cumulative ancestor budgets, expiry/revocation cascade |
| Dishonest create/delete callback | Separate present/absent/unknown observation; accepted is never success |
| Provider/child partition or crash | Persist intent before effect, conservative unknown, correlation reconciliation, provider TTL, resumable deepest-first teardown |
| Recursive resource/cost explosion | Hard depth/descendant/lifetime/execution/shape/cumulative-cost limits and atomic reservations |
| Credential exfiltration | Parent-local broker; no cloud credentials in child/bootstrap/evidence; fixed profiles and network allowlist |
| Malicious workload/injection/SSRF | Named workload/profile, closed argument parser, no interpolated shell, fixed configured endpoint, redirect rejection, constrained egress |
| Parent state loss after create | Durable pre-effect correlation plus provider ownership labels/TTL; corrupt/missing ledger fails closed and reconciles safely |
| Compromised provider or VM | Truth boundary explicitly limited; no claim of hardware attestation or cryptographic proof of provider truth |

Real provider choice follows configuration inspection. Credential absence must not block deterministic architecture/security tests or be reported as live success. The adapter may be production code without a performed live test. Full macOS/Linux x86_64/Linux arm64 process execution, bootstrap binary delivery, provider TTL and externally observable workload are acceptance gates with separately recorded evidence. Do not infer a full cloud runtime from an in-memory fake or exact-source Foundation test.

## Implementation and acceptance sequence

1. Preserve main/base/test/MCP evidence and separately baseline the adopted portable prerequisite.
2. Add canonical models and failing boundary tests, then provider contract/test provider.
3. Add protected intent/evidence storage, budget/lease attenuation and adversarial tests.
4. Add child enrolment and existing Link admission/replay bindings.
5. Add generic contextual reflector and parser support without MCP operation/schema expansion.
6. Add parent independent observation, proof validation and causal dependency admission.
7. Add deepest-first cleanup/reconciliation and process restart failure controls.
8. Run deterministic A -> B challenge end-to-end, replay and false-success rejection, teardown and retained ledger.
9. Add one configured real-cloud adapter with opt-in bounded test; report unexecuted gates honestly.
10. Freeze, run full regression/platform gates, obtain independent architecture/security/regression review, fix critical/high findings and rerun.

Required negative controls include forged/expired/revoked lease, every signed-field mutation, subject/environment/parent/SHA mismatch, replay/reordering/cross-execution evidence, sibling budget overspend, confirmation bypass, false success, create/teardown partition, accepted deletion with present resource, crash before persistence boundary, duplicate intents, interrupted teardown, partial enrolment and malformed Link payload. Tests must call production admission/adjudication paths and independently model observed reality rather than assert that a mock called itself successfully.
