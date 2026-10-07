# Caller-held declaration fingerprints

`context_actions` and contextual `context_explain` return an optional
`contractSHA256`. A caller may send that exact lowercase SHA-256 to `context_run`
with its selected action ID or title. A changed or unavailable declaration then
fails before provider dispatch. A malformed pin fails before discovery or any
provider request. An invalid supplied field never silently becomes an unpinned
call. No additional top-level operation is introduced.

The existing typed `CapabilityContract` canonical representation supplies the
hash. The engine assigns reflector ownership and replaces provider-supplied pins.
The declaration includes its routing, schema, safety and other metadata bytes;
the reserved advisory `experience.*` fields and the computed pin are excluded.
Metadata ordering is canonical, while distinct UTF-8 bytes remain distinct.
The fingerprint also stays outside experience ledger keys, retaining existing
history identities. Existing execution-boundary revalidation still checks the
selected declaration immediately before transport starts.

The optional argument preserves source compatibility with existing direct
`CapabilityEngine.run` and `begin` callers. Missing pins retain legacy fresh
ID/title resolution. **An unpinned call does not prove execution of a previously
reviewed declaration.** Pinned title aliases reject conflicting matches rather
than choosing a different contract. Callers must rediscover and review a changed
declaration; they must not automatically retry without the pin.

This is a content precondition, not approval, authenticated authority, a lease,
an invocation binding, or a signature. It does not make unknown schemas usable:
the discovery fingerprint retains their unknown state. Public string argument
compatibility and the compiler-selected typed adapters remain as before. It
does not independently prove typed public execution for every substrate.

Byte-identical withdrawal and reappearance can have the same content hash.
Acquisition incarnation and RCIR generation/authority invalidation remain a
separate required gate. Optional pins also do not establish that every legacy
execution is pinned, or that the eleven-world restricted experiment is GREEN.

## Convergence and evidence

The historical `feat/reviewed-contract-pins` branch implemented pins inside an
action ID using a separate contract enum and JSON canonicalizer. The historical
`feature/capability-abi-002a-bound-execution` branch supplied a core-only wrapper
engine. This change retains their conservative selection principles in the
existing typed ABI and current execution engine; it adds neither competing type
nor dispatcher and does not introduce their approval abstractions.

`scripts/acceptance-contract-pin.py` is the frozen public MCP regression. Its
separate encoder verifies the exact declaration hash; a controlled provider
records actual HTTP requests and effects. On the preserved `2dd7bd2` runtime,
eight malformed pins and stale same-ID/schema and title selections all reached
the provider. The frozen script, baseline provenance, transcript, provider logs,
and subsequent results are under `evidence/contract-pin-20261007/`.

This is a controlled-provider engineering regression through the production
transport. It is not a real eleven-substrate restricted-agent acceptance claim.
