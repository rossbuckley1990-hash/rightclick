# RCIR-001 — typed semantic foundation

**Status: implemented as an additive source patch; portable foundation validated. Production dispatch integration and the eleven-substrate proof are not complete.**

RCIR is the RIGHTCLICK Intermediate Representation. It extends the existing Capability ABI rather than replacing its types or adding a second JSON normaliser. It adds no model-facing operation and no provider-specific AI integration.

## Source and engineering gate

The initial baseline was RIGHTCLICK commit `05ace2fec149c62c7cfb24f41fafde863b377ff5`. During implementation, main advanced to `1f2219eafb4514b08c6364cb0ec3bb8bf105cf80`, whose parent is that baseline. That merge changes experience/dispatch handling, not the ABI. The ABI blob was rechecked at the newer commit and remains `ff9732c2743898275c87167429858407bf86063f`.

Forty-six tests were frozen before implementation. A deliberately permissive new API scaffold compiled, then failed 74 assertions. The implementation passed the unchanged tests. This is a **scaffold RED**, not a claim that the upstream product was run and failed these tests.

A separate five-test boundary gate then exposed a real defect in the new implementation: a task could predate its lease. The failing test and pre-fix source were retained; the defect was repaired without changing the tests. Ten additional portable integration tests exercise observation inputs, event pages, and signature-envelope trust boundaries. Two additional real CryptoKit tests are conditional on Apple-platform availability.

Commands: `bash scripts/test-rcir.sh` and `bash scripts/prove-rcir-receipt.sh NEW_EVIDENCE_DIRECTORY`.

## The semantic pipeline

```text
untrusted discovery artifact
    -> validated substrate compiler                 [production lowering: next gate]
    -> existing CapabilityContract + RCIRContract   [implemented]
    -> host-authenticated principal + graph binding [implemented model; host supplies identity]
    -> exact authority intersection + policy        [implemented in-process admission]
    -> one-use lease consumption                    [implemented; wire at real dispatch next]
    -> provider transport                           [existing transports; RCIR wiring pending]
    -> typed bounded task events                    [implemented state model]
    -> independently configured observer            [implemented; local external fixture tested]
    -> signed canonical receipt                     [envelope + Apple backend; crypto fixture tested]
```

The production CapabilityEngine, existing reflectors and seven operation schemas are intentionally unchanged in this patch. New source files will be included by the existing Swift package targets, but this does **not** make their checks mandatory on current dispatch paths. A separate, tested integration gate must do that before any runtime claim or release.

## Types and declarations

`CapabilityValue` remains the sole value representation: null, Boolean, exact Int64, finite binary64, UTF-8 string, bytes, arrays and objects. Existing closed schemas validate inputs without silent coercion. Canonical bytes retain the ABI's domain separation and exact type information; they are not advertised as RFC 8785 JSON canonicalisation.

`RCIRContract` binds the ABI declaration to exact resource/effect requirements, task shape and budgets, and a host-selected external verification predicate. Provider identity is initially a locator. Authentication of the principal is a host responsibility, not inferred from a URL, title, metadata claim or model response.

Unknown effects or argument schemas fail closed. Empty effects means explicitly pure, not missing metadata. Do not convert absent/ambiguous provider declarations into an empty scope set. The trusted compiler must justify the model it emits. Advisory `experience.*` values must not be treated as authority; follow the production engine's reserved-namespace rule when integrating lowering.

This foundation is not the final universal type algebra. Resource handles, rich variants/results, recursive references, typed error mapping, durable continuations and supported client/bidirectional streaming require later validated extensions. Unsupported shapes must abstain, never be flattened into strings.

## Authority and policy

`RCIRAdmission` serializes graph and approval changes under a lock. Admission requires the contract's exact scopes to be allowed by both host authority and the current policy, and its authenticated principal to match an allowed principal byte-for-byte. The lease contains only the required scopes, not ambient privileges. Scope matching has no implicit wildcard, prefix, case-folding or Unicode-normalisation widening.

The request binds principal, declaration, graph generation, typed arguments, scopes, policy and validity interval. Consumption rechecks all these conditions and spends the lease once. A 32-way concurrent consumption test has exactly one winner. Changed arguments, policy, authority or provider incarnation reject dispatch.

**These leases are opaque, in-process handles, not signed bearer credentials or downscoped OAuth tokens.** This patch neither authenticates remote principals nor obtains provider credentials. A token/credential broker and actual transport-bound enforcement are separate integration requirements. Host code must consume immediately before dispatch and never automatically retry an effectful request after an ambiguous transport result. The model does not promise distributed exactly-once execution or atomicity across the network.

The trust boundary assumes host-controlled publication, policy, time, signer and observers. Passing untrusted provider assertions into these host interfaces is not safe admission.

## Task and stream semantics

Unary, deferred and server-stream shapes have bounded state semantics. Client-stream and duplex shapes can be represented but are denied at admission. A provider's accepted/completed event never sets semantic success. Cancellation requested is not cancellation acknowledged. Timeouts and in-flight provider loss become unknown, not invented success or failure.

Events must be strictly sequential, have non-regressing trusted host time, satisfy their schemas, and fit count/byte budgets. A rejected event does not partially mutate the log. The default event budget is 256 events and 256 KiB; hard ceilings are 1,024 events and 256 KiB. Tasks have an upper duration bound of one day. Lease TTL is capped at 60 seconds for admission, not the duration of an already admitted task.

`eventPage(after:limit:)` produces bounded event pages for a future `context_run_status` binding. This is not actual network backpressure, persistent task storage or restart recovery. The eventual transport controller must stop pulling, cancel where supported, or preserve an unknown outcome on overflow/uncertainty. It must never create an unbounded queue behind these checks.

Host time is monotonic milliseconds, not a claim of globally synchronized timestamps. A task cannot start before its lease was issued. A provider disappearance notification must also be delivered to active tasks by the host; updating the admission graph alone does not magically notify unrelated task owners.

## Dynamic graph changes

Publishing the same declaration/principal retains the current generation. Replacing it creates a new generation and invalidates outstanding leases for that capability. Withdrawing a provider removes its capabilities and unspent leases. A reappearance is a new incarnation: old bindings cannot authorize the new provider.

This is the graph's semantic invalidation mechanism. Existing Bonjour/artifact refresh sources are not yet connected to it. Unit and fixture removal tests are not proof of live discovery across eleven protocols.

## External verification and receipts

A trusted observer receives the exact task ID, lease ID, binding and invocation arguments, not the provider's returned result. It independently observes the target, validates its observation type and compares exact canonical values against the host-bound postcondition. Missing, throwing or ill-typed observers cannot promote success; a well-typed mismatch records semantic failure.

The external fixture launches a separate local producer process, records provider completion as unverified, and reads the resulting file independently. A good result succeeds; a deliberately incorrect result fails despite identical provider acceptance. This fixture is not an LLM agent or production protocol adapter.

Canonical receipts include invocation/policy binding, IDs, task/event history, outcome and observation. The receipt can honestly record an unverified or failed result. A signature must not be interpreted as a success flag.

`RCIRSignedReceipt` supports Ed25519 through host-owned backend interfaces. Its CryptoKit implementation requires explicitly provisioned key material. Verification requires a separately pinned public key; an embedded key is not trusted automatically. Python and OpenSSL independently verify real signatures on the Swift-generated fixture receipts, including a signed mismatch. Eleven negative controls cover tampering, key substitution, malformed encoding and algorithm downgrade. The fixture private key exists only in memory and is not shipped.

A valid signature authenticates bytes under the trusted key, not the truthfulness of a compromised host. Constructing a task does not prove a lease was consumed. Production signing must be located after the host's real dispatch/observation boundary, backed by appropriate key provisioning, retention/redaction, rotation and audit controls. Raw receipts include invocation/observation data and may be sensitive; do not publish production receipts without a data policy. The included receipts contain fixture data only.

## Non-regression and release boundary

Do not remove confirmation or authority revalidation, change existing release tags, relax schema tests, add model-facing tools, or expose secrets to make a demo pass. Do not mark remote/provider acceptance as verified semantic success. Do not present Linux Foundation-only test results as a portable macOS application, Windows agent bridge, or full runtime test.

The merge/release gates remain: compile and run the full macOS suite; run the two real CryptoKit tests; integrate RCIR at actual generic dispatch and status boundaries; run the live acceptance protocol; build a new immutable artifact; fresh-install it; verify runtime identity, exact seven-operation surface and bottle alignment. Keep the v0.2.2 Homebrew pin until a genuinely tested replacement exists.
