# Portable / v0.2.3 reconciliation design gate

Inputs: PR #99 `6a18aaae3ae3a15b9f6c78f189adc695ae11585a` and PR #49
`053b6202df504ff1a33682a39f2e72a959f65983`. Integration starts from #99.
The later #49 remote head is not an input to this reconciliation.

The coordinator reviewed independent architecture, complete source/substrate
inventory, security reconciliation and exact-head regression reports before
changing production architecture. Source presence and green fixture provisioning
are not execution evidence. The candidate is not authorized for merge or release.

## Module decisions

* Protocol retains the portable ABI, capability/result/runtime contracts and gains
  constrained strings/unit results, caller contract commitments, shared interface
  operations/JSON lowering, authority/admission, task events, receipt claims/trust
  and observer/lifecycle contracts.
* Providers retains the **one existing RCIRExecutionHost**, constructed and owned
  by Core. It gains A2A, Kafka, Kubernetes, WASM, MCP artifact compilation,
  bounded process/snapshot primitives, generic D-Bus compilation, deferred host
  sessions, HTTP/structured observations, provisioned signers/trust and the
  invocation journal. Moving its concrete host to Core now would introduce a
  Providers/Core cycle; a second executor is prohibited.
* Core retains #99's serialized engine, runtime compatibility, routing, frozen
  contract, remote admission callback and file-input containment. It gains
  exact selection/conflict quarantine, semantic preflight, bounded reservations,
  richer lifecycle/status and configured A2A discovery.
* MacOS/MacOSHost remain native leaves. No AppKit, Keychain or Security framework
  implementation returns to portable modules. Native Services/sharing behavior
  is retained from #99 rather than replaced with the older monolithic versions.
* RightClickLinux owns native session D-Bus discovery and busctl execution.
  Its generic introspection/schema compiler remains in Providers.
* RightClickHostFiles is a small guarded C storage/process leaf, retaining #49's
  Windows foundations without claiming an untested Windows runtime.
* MCP retains #99's bounded loopback listener and exactly seven operations.
  Federation and Link share engine-owned routing provenance and conservative
  single-hop export. A possibly delivered federation request fails unknown.
* Link remains optional and authenticates delivery, enrollment and result
  assertions. It calls the same Core engine and RCIR admission host. Provider
  authority, credentials, confirmation and observation remain execution-local.

## Security reconciliation

Link's durable, non-evicting delivery reservations and RCIR's bounded invocation
journal have different responsibilities in one execution chain. Neither may
restart a mutation after ambiguous delivery or recovery. Deferred status uses
fresh authenticated ownership checks and `engine.executionStatus`, never begin.
Initial delivery/approval expiry is distinct from ongoing observation authority.
Receipt issuer trust is independently provisioned; a node transport signature
does not confer receipt trust. Private receipts and credentials remain local.

Resolve the review's six HIGH findings with retained regressions: preserve engine
hooks; strengthen protected references; protect journal ancestry/reset history;
prevent cross-transport exports; preserve ambiguous federation uncertainty; and
isolate ambient HTTP credentials on public A2A/MCP descriptor sessions.
Observers set typed external-state boundaries at the actual host observation
edge. Provider acceptance, returned-value checks and external verification remain
distinct. Existing process-local receipt revocation does not claim durable
anti-rollback across restart.

## Compatibility and proof gates

Retain #99's official MCP SDK (both inputs use upstream 0.12.1), Crypto 5 and
configuration paths. Migrate local handshake/stdio compatibility; retain Windows
patch provenance as an explicit unproven gate. Keep the stable version/formula.

Exact input baselines: #99 Mac 687 tests (658 pass,29 skip), Linux x86_64/arm64
419 each (416 pass,3 skip); #49 independently rebuilt Mac 996 (958 pass,38 skip),
Linux x86_64 776 (748 pass,28 skip). #49 Linux arm64 was not proven. Its Windows
CI has three failures; original Mac CI has one intermittent fixture failure;
stable-bottle alignment is red. These are not newly passing combined results.

The complete source inventory and test-identity unions are reconciliation aids.
The long-term substrate gate must inspect actual registered acquisition/compiler
kinds and callable fixtures, not filenames. All old tests are retained or mapped
explicitly, with new combined native Mac, native Linux x86_64/arm64 and real
substrate acceptance results reported separately. Kafka/Kubernetes lab readiness
alone is insufficient. Fresh independent capability, adversarial and product
reviews follow a compiling implementation. No HIGH/CRITICAL issue may remain
when recommending merge.

## Explicit stronger-contract reconciliations

* Candidate journal status formerly returned nil after the named writer lock was
  replaced. The combined durable identity anchor now rejects that storage, including
  reads, as corrupt. The existing replacement test explicitly expects a throw;
  new commit-anchor-loss and recreated-directory tests prevent an empty-history
  fallback. Initialized candidate journals without a sibling anchor need an
  operator-reviewed migration preserving history; automatic reset is forbidden.
* PR99 `PolicyTests.testDedupeKeepsFirstIdentifier` maps to candidate
  `testDedupeQuarantinesConflictingIdentity`. Exact duplicates still collapse;
  conflicting declarations with one ID are quarantined. First-wins must not
  resurrect a substituted contract.
* Candidate Linux supportDirectory used XDG_STATE_HOME; PR99's configuration
  directory contract remains XDG_CONFIG_HOME, with state used for logs. The copied
  relative-path test retains its denial assertion and expects the preserved config
  directory. Windows retains absolute LOCALAPPDATA/AppData/Local behavior.
* The descriptor portion of Bonjour OpenAPI acquisition lives in Providers;
  native NetService discovery remains in MacOS and shares the same revocable
  acquisition token implementation. Linux's legacy source name is a descriptor
  acquisition alias, never a claim of native Bonjour browsing.
* PR49's portable `setup` registration preview and `refresh` command are retained
  additively in PortableMain. Its non-Mac `authority` command retains an explicit
  unavailable storage boundary. It does not manage environment credentials or
  introduce plaintext persistence; Mac authority commands retain their existing
  Keychain implementation.

## Independent adversarial corrections

Delegated predicate evidence must match the caller's exact predicate bytes,
fields, count and order for both success and failure. Contradictory or substituted
evidence remains accepted but unverified. Received RCIR structs/receipts cannot
prove that this process admitted an invocation. A package-only, non-serialized
host provenance flag records the existing host's admission path; it cannot be set
by JSON, a relay, or a public ExecutionRecord initializer. Incoming receipts remain
available for separately provisioned trust evaluation. Bare RCIR claims from a
federation peer no longer establish verified completion without consistent
predicate evidence. Link never treats its outer signature as receipt issuer trust.

MCP artifact contracts are reacquired and compared at the final admission
boundary. Selected local credential bytes are pinned for the session; withdrawal
or rotation invalidates the old capability. MCP does not provide an atomic
compare-contract-and-call primitive, so provider changes after the final check
remain a protocol limitation; no stronger atomic remote-server guarantee is
claimed. Final lease time is sampled inside the admission lock after authority
and graph callbacks, preventing expiry during callbacks from permitting dispatch.

Execution-node replay and task identity are durable where explicitly journaled.
The current routed caller's local-to-node task map is volatile. Caller process
restart cannot fabricate recovery or redispatch an ambiguous mutation; durable
caller-side task recovery is deferred. Direct authenticated status with a retained
execution ID and the same identity is supported and tested separately.
