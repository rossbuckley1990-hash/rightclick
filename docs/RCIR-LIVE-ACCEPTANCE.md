# RCIR live acceptance — required before “universal capability runtime” is proven

**Status: preregistered next-stage acceptance; NOT RUN by this patch.**

The engineering session that produced this patch used RIGHTCLICK, the GitHub connector and a Linux build environment. The portable fixture invokes RCIR library APIs directly. Neither is the seven-operation-only agent experiment below.

## G1: generic lowering, before more providers

Lower the existing supported OpenAPI request/result schemas into the existing ABI and host-validated RCIR effect/task declarations. Route actual invocation through RCIR admission while preserving current confirmation and exact execution-origin credential binding. Keep unsupported constraints unavailable. Replay existing OpenAPI RED/GREEN fixtures and all negative controls. Do not infer read-only/pure authority from human-readable descriptions.

Use the same lowering/dispatch boundary for GraphQL and gRPC, without application-name switches. Protocol-specific compilers/transports are expected; provider-specific AI tools are not. Input compatibility must be deliberate: preserve existing string-only callers, expose typed ABI values through an explicitly versioned generic encoding, and never stringify unsupported values silently. No change from seven top-level operations is permitted.

## G2: task host, authority broker, receipts

Connect discovery removal/replacement events to the admission graph and active task owners. Connect bounded transport events and cursor paging to the existing run/status operations. Place one-use consumption at the actual effectful dispatch boundary and signing after independently obtained observations. Supply authenticated identity and least-authority provider credentials through the host broker, not through model-visible arguments. Provision a trusted signing identity; an ephemeral demo key does not satisfy production trust.

Pending primitives include persistent task recovery, idempotency/retry policy, real backpressure, credential revocation, platform bridges and protocol-specific observation implementations. These are not proved by the Foundation tests.

## G3: the seven-operation-only agent experiment

Start a fresh agent client whose allowed tools are exactly:

```
context_inspect
context_actions
context_explain
context_run
context_run_status
context_providers
context_runtime
```

The agent must not also have a shell, browser, direct HTTP, a GitHub connector, provider SDKs or provider-specific tools. Capture the MCP transcript and exact tool-list fingerprint before discovery and after every graph change. Setup/orchestration outside the agent is permitted but must be disclosed separately. Do not count fixture labels as implemented protocols.

Bring real providers into an isolated test environment. Generic endpoint advertisements, protocol descriptors and operator credentials are allowed. Arbitrary unknown software cannot be safely invoked without a supported discoverable contract and valid authority.

| Substrate | Required real discovery evidence | Required independent outcome evidence |
|---|---|---|
| Mac application | Installed OS-reported applicable capability | Actual target/artefact observation, not invocation return |
| Windows machine | Authenticated Windows capability bridge and validated descriptor | Target-side state observation; no fabricated Mac proxy proof |
| Linux service | Supported introspection/descriptor from an actual Linux host | Read-back of the bounded requested effect |
| REST API | Live supported OpenAPI declaration | Separate read-back tied to exact resource/request |
| GraphQL API | Live schema/operation lowering | Independent query/postcondition, not mutation success alone |
| gRPC service | Reflection/descriptors and supported message shapes | Supported unary/stream result plus required external postcondition |
| MCP server | Real MCP provider tool/schema acquisition | Independent target verification; remote tool text is insufficient |
| A2A agent | Real agent/task contract and task lifecycle | Verified artefact/effect after terminal task observation |
| Kafka topic | Real broker/topic contract and least-privilege identity | Observed committed record/offset or bounded subscription evidence |
| Kubernetes cluster | API discovery/schema and namespaced least authority | Resource UID/generation plus required observed condition |
| WASM component | Actual WIT/component contract and bounded host imports | Typed result and separately verified host effects, where applicable |

Every row is **NOT RUN in RCIR-001**. Existing repository support for a subset of these substrates is not RCIR-integrated acceptance evidence.

## G4: mandatory negative controls

Reject unknown types, effects, task shapes and authority; denied policy; expired/spent leases; changed arguments or credentials; and changed declaration/provider identity. Check cancellation request versus acknowledgement, replayed/missing stream events, resource budgets and ambiguous network failures. Confirm no automatic effectful retry after uncertainty.

Remove a provider after selection but before dispatch: the old lease must not execute. Remove it after dispatch: preserve an honest unknown outcome where completion cannot be established. Reintroduce the same public ID: the old binding must still fail. Capture the external service's effect log to prove the negative controls did not merely hide a successful call.

Return a provider success response while withholding or corrupting the target effect: semantic success must not be reported. Tamper with receipt bytes and substitute the signer key: verification against the operator's pinned key must fail. Verify that authority and approval data are not exposed in model-visible credentials or public logs.

## G5: release and installed-product proof

Record source commit, build/toolchain/dependency lock, immutable asset checksums and installed runtime identity. Run full native CI plus exact-ABI tests and real cryptographic-backend tests. Fresh-install the actual candidate rather than running a developer build while advertising a bottle. The Homebrew companion seven-operation probe must pass against that exact installed executable.

Only when all rows and negative controls pass with raw evidence should the release/README state that an agent traversed the complete eleven-substrate environment through seven operations. Until then, label RCIR as a tested semantic foundation with explicitly incomplete production integration.
