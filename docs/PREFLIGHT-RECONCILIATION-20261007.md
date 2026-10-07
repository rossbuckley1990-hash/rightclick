# PR39 preflight reconciliation into the current runtime

The engineering source is current PR49 `6ea1d3096eb7bba55417d46e7820796bef24daff`
plus reviewed PR53 source `c7de941bebdba4037eed0bd4c8eae5821ec384e9`, locally
cherry-picked as `b819d4e`. Remote main was fetched at
`d953f1a34675a65cf47abd67c4d678069b6536b5`. The three unique PR39 helpers are
reused rather than introducing a second execution, policy or authority engine.

The mirrored workspace unexpectedly disappeared at approximately 18:06 UTC.
Original PR39/35 handoff diffs and original CI job logs survived in `/private/tmp`
and are losslessly archived. The initial pre-loss control run reported 111 tests
and sixteen assertion failures. Its full raw log did not survive; recorded
command fragments are labelled as fragments. The new RED below is a fresh run
on recovered source outside the volatile mirror, with exact source and binary
hashes. It again reports 111 tests and sixteen assertion failures.

## Pressure cases

| Substrate exposing RED | Generic deficiency | Reusable primitive | Thin provider layer | Evidence needed for GREEN | Benefit elsewhere |
| --- | --- | --- | --- | --- | --- |
| Two owned real OpenAPI endpoints advertise the same title | Engine chooses a first title match and can dispatch an unintended provider | Byte-exact unambiguous capability identity selection; an exact ID takes precedence over title aliases | Existing OpenAPI descriptor compiler and real HTTP transport | Same Core7 driver rejects ambiguous title without either mutation, keeps pin ambiguity rejection, and exact-ID invocation writes only the intended endpoint | All acquired and native capability graphs share the selection boundary |
| Two reflector references claim the same ID with different owned contracts | First-ID deduplication removes evidence of conflict | Quarantine the complete conflicting ID; preserve identical repeats and unrelated IDs; reject ambiguous reflector ownership at dispatch | Controlled reflector declarations for the collision; no new runtime provider | Engine graph and execution tests retain zero invocations, including pin and reordering controls, plus identical-declaration positive control | Federation and independent discovery sources cannot silently win identity collisions |
| Controlled reflector declarations expose a third title claiming a quarantined ID | Removing conflicting rows loses the reason that the ID was withheld, allowing title fallback | Retain quarantined byte identities in the same per-invocation discovery snapshot through explanation and selection | Existing reflector catalog boundary; no new provider | Frozen intermediate RED dispatched twice; final run and begin abstain while unrelated exact-ID positive control still dispatches once | Every source shares the same transient quarantine context without mutable caches |
| Controlled reflectors have canonically equivalent but byte-distinct owner IDs | String-keyed owner counts collapse distinct native identifiers and hide both providers | Byte-keyed duplicate-owner counting and final byte-exact owner lookup | Existing reflector ID declaration | Frozen intermediate RED hid both providers; final exact UTF-8 IDs route independently, while truly duplicate owner IDs remain absent | Preserves exact descriptor/provider identity across native and federated discovery |
| Actual closed OpenAPI argument envelope | Confirmation is requested before the runtime explains missing required names | Bounded, side-effect-free top-level argument-envelope preflight before confirmation | Existing compiler-advertised `argumentsSchema`; authoritative nested/type/encoding validation remains in each compiler | Same real HTTP/Core7 request fails before confirmation, with zero mutation; valid arguments still require confirmation and pass common policy only when allowed | GraphQL and gRPC already advertise the same generic envelope; unadvertised schemas still delegate rather than inventing required arguments |
| OpenAPI GET/POST and descriptor-driven GraphQL/gRPC explanations | Legacy safety category alone does not distinguish declared state access from authority or verified effects | Presentation-only effect assessment in the existing flat explanation response | Compiler metadata supplies operation kind; names never prove effects | Core7 explanation carries advisory read/write claims with `verified=false` and `grantsAuthority=false`; flat old decoder, canonical contract pin and confirmation controls remain valid | Compiler-derived advice can inform planning without enlarging the public tool catalog or weakening admission |

## Compatibility and source reconciliation

Preflight checks only top-level names and closed/open envelope shape, bounded to
262,144 schema bytes. It does not validate JSON Schema constraints, argument
values or types, nested objects, credentials, policy, authority, or transport.
Absence of an advertised JSON envelope delegates to the existing validator.
The existing `input_contract_failure` evidence category is retained; a fixed
preflight diagnostic code remains visible in the observation boundary. There
is no argument-value echo and no permission or verification claim.

Conflict comparison excludes only PR53's reserved computed contract fingerprint
and engine-owned `experience.*` advice. Every other declaration byte still
binds. Selection compares UTF-8 bytes, including IDs, titles and owner routing.
A pin cannot turn an ambiguous alias or conflicting identity into permission.
Quarantine context is local to the current discovery snapshot; it is neither a
remembered allowlist nor a second source query. Removing a conflicting ID from
the visible graph cannot resurrect it through another provider's title.
Matching pins still require confirmation, current common policy and final RCIR
admission. The flat effect explanation adds no field to raw capability contract
encoding or discovery rows, and preserves independent PR53 hash calculation.

Original PR39 CI failures are preserved verbatim. Its two Experience failures
are already GREEN on the unchanged recovered baseline through current
discovery-advice normalization; this reconciliation does not claim that work.
Its gRPC `input_contract_failure` assertion is retained unchanged. The old
Policy assertion intentionally expected the first conflicting ID to survive;
the user's explicit unambiguous selection requirement supersedes that behavior.
The replacement requires complete quarantine and adds the exact-identical
duplicate positive control. The original source and failing assertion remain
archived, rather than exempting a substrate to restore first-match dispatch.

PR35's content-addressed reviewed intent is supplied by PR53's engine-produced
canonical `contractSHA256` and optional caller-held invocation pin. Its unmerged
`reviewedActionId` wire alias is explicitly superseded, not implemented as a
second pinning protocol or a colliding `CapabilityContract` type. Legacy calls
remain deliberately unpinned. Compatibility with the unmerged PR35 alias is not
claimed. Its original source and type-collision CI logs remain preserved.

## Evidence boundaries

Mounted RIGHTCLICK self-use attested Stable 0.2.2 at
`/opt/homebrew/Cellar/rightclick/0.2.2/bin/rightclick`, SHA-256
`d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`, PID 67552,
42 providers and exactly seven operations. The procedural-memory catalog query
returned 263 applicable actions and no memory/experience capability. No executable
procedural-memory use is claimed.

The Core7 pressure driver uses owned disposable real HTTP providers, central
policy, confirmation, actual persisted bytes, retained status and signed runtime
ACK evidence. Its operator filesystem readback is separate evidence; it is not
silently promoted to runtime semantic verification. An ACK-only write remains
accepted/unverified even when that independent operator sees the expected bytes.
This driver is deterministic engineering, not a fresh autonomous AI. No shared
broker, cluster, credential or signer configuration was modified.

The unchanged fresh Core7 driver moved from five failures in sixteen checks to
sixteen passing checks. Baseline binary SHA-256 was
`9d4b1fa21b6f3a4e6eef43b72a0b0aa2d507aa0cd0236bba781fcad4bcd9f46d`;
the tested candidate is
`6c5b1e3dbdeef200e5bc24181f94c492963e7ccfeb1b3cd691f86287458d7995`.
The RED actually persisted an unintended write to provider B. GREEN retained
zero ambiguous effects, a real exact-ID write to A, independent matching bytes,
queryable unchanged runtime ACK receipt, advisory effects and unchanged Core7.
The explicit ACK receipt remains unverified. The final native Mac control run
passed 137 tests without skips, including unchanged Experience, gRPC and PR53
pin assertions, OpenAPI/GraphQL controls and the new collision tests.

The required bottle check exits 1: this recovered checkout's inventory contains
Kafka/MCP/WASM resolver kinds missing from published 0.2.2 source
`a3953eb8f1be2f9123d694b90202244c94ee21971171972f8ce1d3bacf807ca5`.
This lane has not changed releases, tags or the stable Homebrew formula. The
root delivery/release lane must close that distribution gate separately.

Native Linux/Windows execution, remote CI, final receipt trust lifecycle,
fresh install, distribution and the full eleven-substrate goal remain separate
RED gates until demonstrated. The Core Profile remains exactly seven operations.
