# Capability ABI-001: typed contract foundation

Status: implementation gate, not a released runtime or a security certification.
Base: b6439f116af2bb19c7a02b816be0d4391ac087ee.

## Preregistered boundary

The next P0 increment adds a provider-independent typed value algebra, closed
structural schemas, deterministic versioned contract bytes, and a read-only
adapter from existing Capability declarations. It must not replace the current
string-only CapabilityArguments type, change the seven MCP tool schemas, expand
provider authority, execute a provider, or alter existing confirmation policy.

## Acceptance contract (freeze before implementation)

- Preserve null, Boolean, signed 64-bit integer, finite binary64, string, bytes,
  array and object without implicit conversion. Reject NaN and infinities.
- Deterministic canonical bytes: distinguish integer/number/string/Boolean,
  signed zero and original UTF-8; object insertion order is irrelevant.
- Strict tagged wire round trips preserve large integers and exact binary64.
  Reject unknown tags, trailing elements, malformed numbers/base64, duplicate
  object keys, and oversized or over-deep inputs.
- Bound depth, node count, canonical bytes and wire bytes. Limits must reject,
  never truncate data. Byte limits include envelope/framing overhead.
- Closed schemas reject unknown fields, missing required fields, wrong types,
  invalid enum declarations, nullable violations and nested mismatches.
- Legacy argument conversion is exact strings only. Non-string values must
  fail before any existing reflector could receive them. Nil is not an empty
  argument object and an unknown schema is not an unrestricted schema.
- Contract changes to provider, reflector, input schema or declared metadata
  change canonical bytes. Contract fingerprinting is content identity, not
  provider authentication, user approval or proof of an observed outcome.
- The adapter covers the existing generic Capability representation rather
  than adding provider-specific OpenAPI, GraphQL, gRPC or macOS execution code.

## Deferred P0 gates

ABI-002 must wire typed contracts into discovery/explanation and migrate each
executor through explicit conformance tests. It must bind execution to the
exact discovered contract instead of merely publishing a schema.

LEASE-001 must use a separately trusted approval issuer, established crypto,
expiry, caller/resource/argument/contract binding, atomic single-use admission,
persistent replay protection, and revocation. A model-supplied confirmed=true
must never mint its own authority. A contract hash is not a lease.

POLICY-001 must apply local/organisation rules before discovery egress as well
as invocation, and provider metadata must never lower required permissions.

VERIFY-001 must bind predicates and observations to the same invocation,
resource and time window, distinguish acknowledgement from state observation,
and avoid claiming causality or verification based solely on provider output.

## P1/P2 sequencing

Complete those P0 enforcement gates before remote trusted federation, typed
workflows, broader ARD acquisition or more protocols. Cross-platform ABI tests
are not proof that the AppKit-dependent runtime runs on Linux or Windows.
