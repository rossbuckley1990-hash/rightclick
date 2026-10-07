# SEMANTIC-PREFLIGHT-001: selection and argument-envelope admission

Implementation candidate against `7a935fea719601492fe05beba1a4223c283eb350`.
Not released, not installed, not a full policy engine or a capability lease.

## Problem

The current contextual `describe`, `run`, and `begin` paths choose the first
capability whose ID or title matches. `dedupeCapabilities` keeps the first
occurrence of an ID. A changing, multi-provider graph can therefore route an
ambiguous name to an unintended provider. An exact ID can even be shadowed by
another capability whose title equals that ID. Separately, confirmation is
requested before missing required argument names are detected.

## Changes

1. Prefer byte-exact capability IDs over title aliases. A unique title remains
   supported; an ambiguous title requires an exact ID. Contextual explain and
   both execution entrypoints use the same resolver.
2. Collapse identical declarations but quarantine every conflicting declaration
   of an ID. A different reflector owner, authority metadata, endpoint, schema,
   output contract, invocation mode, or confirmation requirement is a conflict.
   Other IDs remain available. Snapshot serialization is lazy: unique IDs do
   not pay the duplicate-comparison cost.
3. Check the advertised top-level argument envelope before asking for consent.
   Detect malformed or oversized envelopes, missing required names and
   unexpected fields in closed objects. No argument values are included in
   rejection messages. `begin` stores the failed record for `context_run_status`.
4. Add a presentation-only effect assessment to `context_explain`. Discovery
   lists, raw `Capability` records, contract fingerprints, the seven MCP tool
   definitions and their argument schemas remain unchanged. The flat explain
   response retains the original fields and adds `effectAssessment`.

## Trust and compatibility

HTTP GET/HEAD/OPTIONS and GraphQL query are **declared reads**, not proof of safe
behavior, public data, idempotence, or permission. A gRPC method called `GetFoo`
does not prove a read. The assessment always sets `verified=false` and
`grantsAuthority=false`; it never changes `CapabilitySafety`, confirmation or
credential lookup. Elevated existing destructive/code-execution signals are
not downgraded by a benign-looking method declaration.

MCP explicitly treats annotations as untrusted unless obtained from a trusted
server. HTTP safe-method semantics describe the client's requested semantics,
not an authorization grant or a sandbox. See:
- https://modelcontextprotocol.io/specification/2025-11-25/server/tools
- https://www.rfc-editor.org/rfc/rfc9110.html#name-safe-methods

Argument preflight is intentionally **not full JSON Schema validation**. It
checks the outer envelope only. It does not validate nested values, enums,
field value types, numeric ranges, query/path encoding, duplicate keys within
arbitrary JSON strings, business rules, credentials or network policy. Existing
substrate validators remain authoritative and still run before their own
transport. Reflectors without an advertised argumentsSchema retain their
existing validation path. Passing preflight never establishes authorization.

The pure helper adds no provider requests, although existing discovery itself
can perform network I/O. This is not a no-network dry run.

Changing invalid requests from awaiting-user to failed is intentional. Unknown
or duplicate names now fail closed instead of depending on catalog ordering.
Title-based calls that were ambiguous must use an ID. No ranking rule silently
chooses between potentially different operations.

Raw contract serialization remains unchanged. A flat explain response can
still be decoded as the original Swift Capability; unusually strict external
clients that reject unknown output keys should be tested before deployment.

The contextual MCP path is covered. The older CLI-only contextless describe
fallback is not expanded in this change.

## Existing work preserved

- PR #31's live dispatch-contract drift guard stays in place.
- ABI #29 and bound-execution #33 remain separate; this adds no competing ABI.
- Experience-ledger #32 is not merged or modified by this candidate.
- No changes to versions, Homebrew, credentials, global confirmations, existing
  tests, release artifacts, CI permissions, or protocol-acquisition coverage.

This does not introduce signed approval, replay protection, durable jobs,
automatic retries, a universal authority policy, trusted remote federation,
or independent attestation of provider behavior.

## Validation

Run the dependency-free helper slice:

```bash
python3 scripts/acceptance-semantic-preflight.py
```

Run the actual source engine admission paths with explicit platform/transport
**test doubles**, not real macOS providers:

```bash
python3 scripts/acceptance-semantic-preflight.py --engine-root .
```

The second mode removes only AppKit/Darwin imports from the engine, retains
its actual decision logic, and supplies deliberately limited test doubles.
Outcome verification stubs throw rather than fabricate successful evidence.
The tests make no provider network calls. Neither mode qualifies the native
runtime. Native acceptance remains mandatory:

```bash
swift test --force-resolved-versions
scripts/build-cli.sh
python3 scripts/acceptance-mcp.py "$PWD/.build/release/rightclick" /tmp/rightclick-preflight-mcp
python3 scripts/acceptance-federation.py "$PWD/.build/release/rightclick" /tmp/rightclick-preflight-federation
python3 scripts/acceptance-core-boundary.py "$PWD/.build/release/rightclick" /tmp/rightclick-preflight-core /tmp/rightclick-preflight-mcp/results.json
```

Tests were developed alongside implementation, not independently preregistered.
An original-source negative control is recorded in the supplied evidence bundle.

## Next gate

Integrate with the existing typed-ABI effort after review rather than inventing
another contract layer. For scoped approvals, require an independent trusted
issuer and bind exact reviewed contract, arguments/resource, principal,
expiry and replay semantics. Do not derive authority from this assessment or
from the model setting a boolean. Separately qualify the live Stranger's
Software Challenge; component tests do not establish that end-to-end result.
