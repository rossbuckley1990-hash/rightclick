# Universal runtime async pressure tests

This work keeps the seven canonical operations unchanged. It improves the host's
execution semantics first, then uses a narrow A2A compiler to acquire a genuine
Agent Card and normalize standard JSON-RPC task snapshots.

| RED | Substrate exposing it | Generic runtime deficiency | Reusable primitive | Thin provider layer | GREEN evidence | Other substrates helped |
| --- | --- | --- | --- | --- | --- | --- |
| ASYNC-001 | A2A agent accepting a delegated task before its effect exists | The production host records a still-pending execution as failed, emits terminal evidence and cannot refresh it | Host-owned deferred sessions, normalized task snapshots, deadline/authority/policy/graph revalidation, bounded event retention, terminal signatures | A2A 0.2.6 Agent Card plus `message/send` and `tasks/get` text subset | Frozen native test fails with `phase=failed` while externally held task remains submitted; unchanged test passes after the host change. Separate processes then exercise actual task completion and observation. Public MCP transcript uses seven operations. | Kafka delivery and Kubernetes reconciliation can use the same accepted/completed/observed boundary and status path |
| ASYNC-002 | A2A remote task retention under competing admissions | Session count is checked before dispatch and inserted later, so in-flight admissions can exceed the retained-task bound; expired sessions prevent fresh admission | Atomic session reservations and reaping that preserves terminal receipts in the execution store | None | Deterministic competing-invocation pressure test and expiry/capacity test; source and raw test logs retained | Every long-running provider shares this resource bound |
| OBSERVE-003 | Completed A2A task whose effect appears after policy revocation | Completed-but-unverified tasks skip current policy/authority/graph checks before later observer reads | Every independent observer attempt revalidates current authority, policy and graph; known completion remains signed unverified after revocation | None beyond the real agent and separate effect observer | Frozen pre-fix real-process regression has four failing assertions and an extra observer GET after denial; repaired test has no observer request and no succeeded claim | Kafka delayed delivery and Kubernetes eventual-state observers cannot retain revoked read authority |

The host supports a protected operator-configured independent observer origin pin.
An unpinned cross-origin observer still fails before any delegated request. The
actual A2A proof uses a separate process and network origin to read nonce-bound
effect bytes; provider response artifacts never choose the verifier. This observer
separates acquisition from effect observation but is not remote attestation.

Run the proof on macOS with an Ed25519-capable OpenSSL on PATH:

```sh
swift test --filter 'RCIRDeferredProductionTests|RCIRDeferredCapacityTests|A2ARealLifecycleTests|RCIRProductionDispatchTests'
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
