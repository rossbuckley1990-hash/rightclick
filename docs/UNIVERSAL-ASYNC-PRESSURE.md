# Universal runtime async pressure tests

This work keeps the seven canonical operations unchanged. It improves the host's
execution semantics first, then uses a narrow A2A compiler to acquire a genuine
Agent Card and normalize standard JSON-RPC task snapshots.

| RED | Substrate exposing it | Generic runtime deficiency | Reusable primitive | Thin provider layer | GREEN evidence | Other substrates helped |
| --- | --- | --- | --- | --- | --- | --- |
| ASYNC-001 | A2A agent accepting a delegated task before its effect exists | The production host records a still-pending execution as failed, emits terminal evidence and cannot refresh it | Host-owned deferred sessions, normalized task snapshots, deadline/authority/policy/graph revalidation, bounded event retention, terminal signatures | A2A 0.2.6 Agent Card plus `message/send` and `tasks/get` text subset | Frozen native test fails with `phase=failed` while externally held task remains submitted; unchanged test passes after the host change. Separate processes then exercise actual task completion and observation. Public MCP transcript uses seven operations. | Kafka delivery and Kubernetes reconciliation can use the same accepted/completed/observed boundary and status path |
| ASYNC-002 | A2A remote task retention under competing admissions | Session count is checked before dispatch and inserted later, so in-flight admissions can exceed the retained-task bound; expired sessions prevent fresh admission | Atomic session reservations and reaping that preserves terminal receipts in the execution store | None | Deterministic competing-invocation pressure test and expiry/capacity test; source and raw test logs retained | Every long-running provider shares this resource bound |
| OBSERVE-003 | Completed A2A task whose effect appears after policy revocation | Completed-but-unverified tasks skip current policy/authority/graph checks before later observer reads | Every independent observer attempt revalidates current authority, policy and graph; known completion remains signed unverified after revocation | None beyond the real agent and separate effect observer | Frozen pre-fix real-process regression has four failing assertions and an extra observer GET after denial; repaired test has no observer request and no succeeded claim | Kafka delayed delivery and Kubernetes eventual-state observers cannot retain revoked read authority |
| ADMIT-004 | GraphQL/protobuf compiler returning before transport start; shared interface callback control | The common host manufactures a consumed lease and can verify returned bytes even though no admission start gate ran | Witnessed start gate controls consumption evidence; unstarted compiler errors preserve their cause; unwitnessed progress is unknown and cannot verify | No protocol-specific host branch | Frozen shared-host test has 14 failing assertions on the prior host. Repaired test never reads a result/observer, never claims consumption or success, and retains the specific compiler failure. Real HTTP/A2A regression suite also passes. | Every unary transport can report honest preflight rejection without inventing dispatch |
| KUBE-005 | Genuine Kubernetes API and namespace-scoped service accounts | Default descriptor composition cannot acquire authenticated resource declarations or carry a host-selected typed independent observer; exact whole-object comparison cannot retain unknown assigned fields while binding desired fields | Shared per-operation observer factory, exact argument-bound observation projection, full typed observation bytes in receipts, protected lifetime-managed executable/credential snapshots and bounded stdin process launch | Acquire real `/api/v1` ConfigMap metadata and actual principal; fixed namespace `create` and separate GET-only identity `get` through trusted `kubectl`, retaining real TLS CA | Frozen public seven-operation RED has genuine resource discovery, principals and API Forbidden evidence but no runtime capability. Committed GREEN dynamically discovers, explains, creates and independently verifies a nonce-bound resource, pins/verifies the signature, retains real UID/resourceVersion, demonstrates confirmation/policy zero effects and live authority-reference withdrawal/restoration with seven unchanged tools. | Kafka uses the same factory/projection to bind caller key/payload while retaining independently observed partition/offset; other assigned-ID resource APIs gain the same contract |

The structured observation contract validates the complete independently acquired
schema, compares only declared desired fields exactly, and includes the complete
observed value in the signed receipt. Provider results are explicitly untrusted
locators. They never choose expected values, executables, credentials, namespace,
observer identity or policy. A factory selected by the trusted descriptor compiler
reaches the ordinary host through `CapabilityInterfaceReflector`; no special host
initialization or additional model-facing operation is required. Conflicting
observers or caller postconditions fail before dispatch instead of being ignored.

Kubernetes operator composition requires `RIGHTCLICK_KUBERNETES_CLIENT`, separate
`RIGHTCLICK_KUBERNETES_WRITER_CONFIG` and `RIGHTCLICK_KUBERNETES_OBSERVER_CONFIG`
protected file references, and `RIGHTCLICK_KUBERNETES_NAMESPACE`. The ordinary
`RIGHTCLICK_CAPABILITY_ARTIFACTS` descriptor supplies only an ID, `kind=kubernetes`
and credential-free HTTPS endpoint. The narrow transport accepts embedded-CA JSON
kubeconfigs with expiring bearer tokens, authenticates those captured tokens at the
actual API, and refuses credential plugins, external certificate paths, TLS bypass,
a broader observer mutation/list/watch grant or a writer default-namespace create
grant. The proof uses actual namespace RBAC and separate TokenRequest identities.
Local policy is separately tested and does not replace issuer scope.

The real ConfigMap mutation is immediately stored and uses the unary lifecycle.
Async controller reconciliation, Job completion, watches, broad Kubernetes API
coverage, YAML kubeconfigs, generic REST TLS transport and credential renewal
within a retained invocation remain RED. The runtime does not pretend a ConfigMap
is an asynchronous Job. The checked-in CI workflow runs shared observation,
admission and negative credential controls plus actual A2A processes. Genuine
Kubernetes local evidence is separate; a successful real-cluster CI run has not
been demonstrated by this slice.

With the provisioned disposable namespace and scoped references available:

```sh
swift build
python3 scripts/acceptance-kubernetes.py .build/debug/rightclick /tmp/rightclick-kubernetes-evidence --lab /tmp/rightclick-proof-lab-20261007
```

Immutable evidence under `evidence/universal-async/20261007` records actual binary
hashes and source identities, frozen RED logs, genuine API denial messages,
seven-operation transcripts, independently acquired resources, receipts and the
separately derived public verification key. It excludes private key and bearer
credential bytes. An initial automatic approval-review capacity error prevented
one attempted proof from starting; the same scoped proof was subsequently
approved and completed. This is recorded as a setup boundary rather than a RED
runtime observation.

The host supports a protected operator-configured independent observer origin pin.
An unpinned cross-origin observer still fails before any delegated request. The
actual A2A proof uses a separate process and network origin to read nonce-bound
effect bytes; provider response artifacts never choose the verifier. This observer
separates acquisition from effect observation but is not remote attestation.

Run the proof on macOS with an Ed25519-capable OpenSSL on PATH:

```sh
swift test --filter 'RCIRDeferredProductionTests|RCIRDeferredCapacityTests|A2ARealLifecycleTests|RCIRProductionDispatchTests|CapabilityInterfaceTests|RCIRStructuredObservationTests|KubernetesCapabilityArtifactTests'
swift build
python3 scripts/acceptance-a2a.py .build/debug/rightclick /tmp/rightclick-a2a-evidence
```

The public proof covers discovery, explanation, confirmation and local policy
denial, admitted delegation, pending status, independently observed completion,
signed mismatch and unverified outcomes, no original-request replay during
status, and live A2A capability withdrawal with unchanged tool definitions.
Separate adversarial native controls cover task failure, provider disappearance,
policy revocation and deadline expiry. Signatures are checked against a public
key derived independently from operator-provisioned disposable key material.
Private keys stay outside evidence and are deleted with the disposable lab.

The source supports only the explicitly declared A2A 0.2.6 text/JSON-RPC task
subset. Authenticated Agent Cards, immediate Message responses, streams,
multi-turn continuation and cancellation dispatch remain unsupported. A2A does
not define direct invocation of an individual skill, so skill descriptions are
discovery metadata rather than invented callable methods. The public A2A lab
demonstrates exact local invocation leases and policy, not issuer-enforced
credential downscoping.

The retained-task bound is 256. Repeated identical accepted/working snapshots do
not consume event budget. Status never reruns the original mutation. Completed
tasks with missing independent observations retain signed unverified evidence;
later bounded status reads may observe the effect before the deadline. Expired
pending tasks become signed unknown outcomes, and reaping preserves those final
records in `ExecutionStore`. This store and the retained tasks remain in-process;
crash recovery/durable remote-task resumption is not demonstrated.

The installed stable runtime was also exercised through its actual seven
operations for runtime identity, repository/text contextual discovery, native
explanation, exact native execution and retained status. No verified development
procedure was exposed in that observed graph. Existing capability experience is
advisory; these proofs do not claim procedural workflow execution.

The engineering acceptance client is not the fresh restricted AI eleven-substrate
run. Windows/Kafka/WASM graph mutation, release packaging, clean installation and
any substrate not independently evidenced remain separate RED acceptance work.
