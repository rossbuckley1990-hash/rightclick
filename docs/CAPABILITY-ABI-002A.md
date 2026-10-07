# ABI-002A: contract-bound core execution

Base: 42e62afcbdbfbc0f5acd05fb97c09b878b9a9d02 (ABI-001 / PR #29).
Status: preregistered, opt-in core API; not enabled in the released MCP runtime.

## Acceptance boundary

Add an immutable invocation binding over the exact ABI declaration, context,
arguments and verification request. Absent, null and empty values are distinct.
Use existing bounded canonical bytes, not Unicode-normalising equality.

Add an opt-in ContractBoundCapabilityEngine using the existing CapabilityEngine
and reflectors. Preparation is discovery only and selects an exact capability
ID, never a title. Execution must rediscover availability and revalidate the
selected declaration at the reflector boundary before any provider invocation.
Same-ID provider/schema/authority/safety changes, ambiguous IDs, disappearance,
and plans prepared by another engine must fail closed. Retain existing schema
validation, confirmation requirements and verification semantics. No new MCP
tools, no changed legacy argument transport, no expanded provider permission.

Initially accept plain-text contexts only. A path or URL is not a frozen file
or remote resource; those inputs must be rejected before contextual discovery.
Preserve the exact legacy arguments and declared verification request. An
accepted provider response remains unverified unless the existing verifier
establishes the requested postcondition. Verification delegation must continue
to work only for reflectors that implement its existing protocol.

Tests must include successful unchanged execution, same-ID replacement,
mutation between engine discovery and reflector invocation, disappearance,
confirmation refusal, exact-ID selection, immutable arguments, delegated and
local verification, and separate-engine plan rejection. Portable binding tests
must cover absent/null/empty, exact UTF-8, type distinctions and resource limits.

## Explicit non-claims

This is content binding, not a signed capability lease, user-approval issuer,
persistent replay prevention, full policy engine or remote attestation. Plans
may be deliberately executed more than once. The provider and compiled adapter
remain trusted to honour their contract; a lying implementation or external
state changing after the last check cannot be detected by a metadata digest.
Discovery may still perform configured network reads. Tenant/egress policies
must precede general deployment. Do not log binding bytes: they contain inputs.

ABI-002B must expose the bound path through a versioned MCP contract and migrate
substrate argument compilers with explicit conformance coverage. LEASE-001 then
adds independently issued approval, revocation and durable atomic replay
protection. Do not treat confirmed=true or a hash as cryptographic authority.
