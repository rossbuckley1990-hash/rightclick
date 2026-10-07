# Universal Agency Runtime — evidence gates

This is the amended programme, continuing the existing RCIR architecture.
Current amended objective SHA-256: `4af7b3444226307c48e7a181cd2c896a6403fff203a585eaeecf0682b9bf2f15`.
The earlier objective `d0b14e04ffd301975377d6c3a8e5d4274acff84a95d660d4596badb58638c054`
is retained as historical scope. The amendment adds mandatory product simplicity:
one `rightclick` runtime, automatic useful discovery where safe, and a short
install/connect/first-execution journey. See `PRODUCT-SIMPLICITY-GATES.md`.
No provider-specific AI operation is authorised. Core keeps its seven operations;
authority/events/control need independent universal evidence before a versioned
Agency Profile is exposed. Delegation must be enforceable internally first.

## Repository truth

The 2026-10-07 14:37–14:43 UTC snapshot is retained as projected public metadata
in `evidence/agency-repository-truth-20261007/`. A subsequent fetch at about
15:03 UTC advanced main from `1c3d8c91be5b419e3e4af882972dba025fad2794` to
`7622c133d6db92424f0b959880fa09d7655daad2` (README-only changes); it is merged
into the candidate. A snapshot is not a claim that later remote state is frozen.
The next fetch advanced main to `28de3d8396fc7f144e6734eb6923cdc7219d5c5d`,
merging #46's proof infrastructure. That main is merged into the same candidate;
its Python host/relay fixtures do not establish native substrate acceptance.

The released tag is v0.2.2, commit `7a935fea719601492fe05beba1a4223c283eb350`.
GitHub reported `immutable: false`. Its source archive SHA-256 is
`a3953eb8f1be2f9123d694b90202244c94ee21971171972f8ce1d3bacf807ca5`.
Installed Homebrew bytes are v0.2.2 with executable SHA-256
`d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`;
the observed process advertises seven operations and 42 providers. The current
registered connector independently reports the same executable hash. Plugin
skill versions do not change that runtime identity.

Tap main was `dc3485807481b2c5c30aa963e19c644cdb05ec5b`, still v0.2.2,
arm64_tahoe bottle rebuild 1 with SHA-256
`147828d2ad81b0238c4d733ad757c5c584b7fe359a58db34552052641ea762fd`.
No new release or tap version is claimed by this programme yet.

## Architectural dependency and overlap map

| Existing work | State at snapshot | Reconciliation and dependency |
|---|---|---|
| #42 production OpenAPI RCIR | Merged, merge `c2f3bac98ade0d5f87aeb079d4c2274c55ece561` | Reuse its admission, typed tasks, independent observation and provisioned signing boundary; no second RCIR |
| #47 live execution contracts | Merged into audited main | Preserve before-dispatch/current-observer checks through every adapter |
| #45 discovery lifecycle | Merged in `1c3d8c9` | Reuse monotonic freshness, serialized acquisition and explicit invalidation |
| #44 signed claim verifier | Draft `640a71f`, checks passed | Already integrated into candidate; independent verifier binds outcome/task/lease, not just signature |
| #37 portable runtime | `a41c277`, conflicts; native jobs failed | Preserve useful packaging/integrity/relocated-install controls; do not retain duplicate portable engine |
| #51 portable runtime | Draft `c201420`, conflicts; native Linux product builds, acceptance still fails; Windows compile fails | Converge existing shared core/host boundaries in isolated branch; native protected file backend and dependency repair required |
| #49 async runtime | `29f5527`, conflicts; A2A CI failed | Candidate reconciles task lifecycle/capacity/observation work; repair and rerun against final source before publication |
| #46 isolated proof lab | Merged in `28de3d8`, source `9e223a5` | Reuse issuer-scoped Kafka/Kubernetes and separate observers; Python Windows/Linux hosts support boundaries, not native acceptance; do not restart the withdrawn public relay |
| #50 RCIR acceptance docs | `0fb4b64`, checks passed | Preserve source/package proof with its exact tested SHA; it is not proof of the combined candidate |
| #39 preflight | `14af1ea`, checks failed | Reuse existing boundary conversion only after review; cannot stand in for genuine RCIR types |
| #38 procedural knowledge | `334377b`, checks failed | Advisory experience only; never skip discovery, policy, authority or verification |
| #35 reviewed contract pins | `21ec3d3`, conflicts/checks failed | Reconcile trust/freshness with common binding rather than parallel policy |
| #14 typed OpenAPI experiment | `48794f6`, conflicts/checks failed | Historical experiment, not accepted universal type system |
| #30 archived gRPC work | `65802c2`, checks passed | Preserve descriptor/reflection foundation; real structured messages/stream lifecycle remain required |
| #40/#1 documentation | `9886180` / `2cad342` | Preserve valid adoption material and keep implemented/released boundaries accurate |
| Tap #11 / #9 / #6 | `91fa90f` / `374d157` / `198b404`, checks passed | Converge portable distribution with independently pinned acceptance after immutable publication |
| Operator-owned origin trust | Uncommitted active work in separate `rightclick-g3-tls` checkout | Reconcile its exact-origin protected CA, acquisition/dispatch/observer generation checks and real private TLS controls; current Security/Darwin backend is Mac-specific; do not duplicate or modify the other checkout |

OAuth/OIDC, origin-bound credentials, ARD, reflection, federation and experience
already have runtime paths. They remain foundations to inspect and pressure-test,
not a reason to introduce provider-name policy or model-visible credentials.
The current parallel branches own distinct slices: types/compiler boundaries,
host portability and internal authority. Their changes converge into the same
Capability ABI, RCIRAdmission and execution host.

The installed-runtime transcript is retained in lossless gzip. The fresh-client
catalogue progression and actual AI discovery evidence are retained separately in
`evidence/core-profile-isolation-20261007/`; the original probe script is preserved
in `scripts/restricted-core-probe.py`. It should be copied to a neutral private
acceptance directory before use so its ephemeral client's working directory does
not inherit the repository's engineering instructions. Exact current lab secret
matching checked 92 evidence files against nine bearer/password materials,
including gzip and decoded JSON payload fields, with zero matches. This bounded
check is not a proof against every possible encoding or unknown secret.

## Full gate status

Every gate below remains RED at programme scope until its full acceptance is
demonstrated. Narrow GREENs are recorded without promoting the enclosing gate.

| Gate | Supporting evidence | Remaining RED |
|---|---|---|
| G0 Repository truth | Exact main/release/installed/tap/PR/CI snapshot and dependency map | Reconcile overlaps; refresh state before final review/merge |
| G1 RCIR | Existing closed typed ABI; bounded string constraints; common task contracts | Maps/unions/resources/handles/identities/refs/typed errors/events; descriptor-native GraphQL/gRPC types; coherent versioned effects |
| G2 Admission | OpenAPI and generic unary/acquired process/task routes; replay/argument/policy/current-contract controls | Demonstrate every relevant production route on final shared core |
| G3 Authority | Exact resource/effect/argument leases, private credential refs; real Kafka ACL/Kubernetes RBAC; internal represented child-subset, shared ancestor budgets, revocation and bound subject/audience controls | Authenticated production caller wiring, issuer credential brokering/downscoping, durable/distributed grant lifecycle; issuer/local distinction |
| G4 Policy | Confirmation/policy denial with actual zero side effect; current-policy checks during tasks | One full effect/authority/delegation-aware decision model and consistent final routes |
| G5 Tasks | Real A2A async tests, admission/capacity/deadline/uncertainty; explicit ACK remains unverified | Required universal states, native streams/checkpoints and durable recovery semantics |
| G6 Events | Bounded internal task history | Generic graph/authority/approval/resource events; legal cursors/checkpoints and replay controls |
| G7 Control | Explicit cancellation boundary in task model | Actual legal cancel/pause/resume/retry/checkpoint semantics driven by effects |
| G8 Verification | Real exact JSON/file/Kafka/Kubernetes/WASM observations; host invocation causality; mismatch/missing controls | Full matrix; verification timeout/unavailability and causal stream observations |
| G9 Receipts | Provisioned Ed25519; pinned independent decoder/signature/claim checks | Runtime/ABI/authority/delegation bindings, privacy-minimized public receipt, production key IDs/rotation/expiry/revocation/trust lifecycle |
| G10 Portability | Genuine Linux product build, seven-operation stdio/authenticated-HTTP boundary, real bounded sockets and protected files; Mac combined regression | Final-source native Linux discovery/effect/receipt and genuine Windows build/run/protected-file security |
| G11 Compilers | Main Mac/REST/GraphQL/gRPC/federation; candidate MCP/A2A/Kafka/Kubernetes/WASM acquisition | Native Windows/Linux direct reflectors; complete consume/watch/stream and type coverage |
| G12 Graph | Actual Kafka removal/restoration prior candidate; credential withdrawal/reacquisition; serialized discovery tests | Final source provider generations, old authority invalidation, near-dispatch disappearance/restoration races |
| G13 Core proof | Outgoing catalogue 20→14→8→7; actual fresh AI Kafka single publish/status plus independent broker readback and pinned receipt verification | Same fresh AI must perform effects/receipts/graph mutation across full matrix; exact final installed bytes |
| G14 Agency proof | No extra operations exposed yet | Meaningful authority/events/control REDs and universal necessity; versioned compatible profile plus restricted AI proof |
| G15 Delegation | Internal child⊆parent constraints, atomic ancestor budgets/revocation and real bounded HTTP child execution with independently decoded signed ancestry | Production principal identity, issuer/distributed constraints, durable task controls, genuine child-agent compromise/revocation proof before any public delegation operation |
| G16 Multi-agent | Engineering agents use RIGHTCLICK discovery themselves | Real principal/attenuated children, compromise/revocation and provenance proof |
| G17 Eleven substrates | Individual genuine effect/readback pressure tests | Full restricted-agent matrix; native platforms, gRPC streams, Kafka consume and Kubernetes watches |
| G18 Release | Existing v0.2.2 source/assets inspected | Appropriate immutable tested publication of accepted final source/artifacts |
| G19 Distribution | Existing source/bottle pins and active tap PRs inspected | Formula/native distribution aligned to accepted immutable bytes |
| G20 Fresh install | Actual existing installed identity probed | Clean install of final release reproduces ABI, safe effect, verification and receipt proofs |

## Current real-provider causality increment

Candidate source `242e97d` / executable SHA-256
`3c6fd8d48c381646d7da41f0864d853735d9489cbec7b21e2dbfa3c1191d2bd2`
was checked through the seven-operation engineering client against real Kafka
and Kubernetes. Independent scoped readers verified host task identity in the
Kafka header / ConfigMap annotation, exact desired fields, and signed observation.
Confirmation and policy denial produced no effect. Kubernetes issuer-forbidden
nodes/default-namespace/create-observer controls also passed; withdrawing a
private copied writer credential removed the capability, and restoration
reacquired it without altering the seven tool definitions.

Evidence is in `evidence/universal-execution-20261007/{kafka,kubernetes}-causality-current/`.
This is write/readback boundary evidence. Kafka subscription, Kubernetes watch,
native cross-platform runtime and the fresh AI matrix remain RED. Kafka broker
withdrawal was not requested during this particular run; its earlier real
withdrawal proof is explicitly tied to earlier bytes.

## Private lab boundary

Windows relay terminal evidence records success at 14:54:05.917 UTC:
withdrawn, private state removed and proof users removed. No continuing relay is
claimed. A separate private Linux writer/GET-only observer pair is ready with
different Unix users and read-only observer filesystem enforcement.

Automatic approval review rejected creation of public Linux tunnels because
it would expose the local services externally. No tunnel was created or alternate
route used to bypass that rejection. Private native/integration work continues;
public exposure is not required to substitute for missing native runtime proof.
