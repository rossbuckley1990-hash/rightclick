# Internal RCIR authority attenuation foundation

This candidate adds host-local delegated authority to the existing RCIR admission
ledger and common execution host. It adds no AI-facing operation. The seven-operation
Core Profile remains compatible. This is an internal integration seam, not a claim
that released MCP clients or native operating-system principals are authenticated
into delegated sessions.

## Meaningful REDs and transfer

| Exposing boundary | RED | Reusable change | Provider-specific layer | Evidence | Transfer |
| --- | --- | --- | --- | --- | --- |
| Shared RCIR admission used by REST and other compiler paths; frozen Foundation pressure test | A copied lease starts with no invoking-agent/audience value for the ledger to check | Exact UTF-8 authenticated context, immutable grant handle, grant-bound lease | Trusted host session authentication; no new provider dispatcher | `red/LegacyAuthorityGapTests.swift`, two failing pre-change invariants; wrong-subject/audience actual HTTP controls GREEN | Every compiler using common admission can reuse the same caller boundary |
| Shared RCIR admission; frozen Foundation pressure test | Two fresh child leases both start despite an intended one-use parent budget | Atomic debit of every ancestor's invocation budget | None | Frozen two-versus-one dispatch count; concurrent fresh child leases and actual HTTP sibling/parent controls GREEN | Shared budgets are independent of transport |
| REST common host, real HTTP control | Synthetic credential material in an authentication callback error reaches the execution response | Sanitized authentication boundary returning generic authority denial | Host callback supplies identity; errors cannot supply model-visible text | `dispatch/context-error-red.json`, frozen host/test source, native leak RED; `dispatch-final/context-error-green.json` GREEN | Any authenticated host attachment gets the same error boundary |

The first two REDs demonstrate missing agency invariants. They do not assert that
the pre-existing trusted-host scope API promised invoking-agent authentication.

## One architecture

`RCIRAuthorityLedger` is a value owned by `RCIRAdmission` and accessed only under
its existing graph/lease lock. It is not a second execution engine. Authority
issuance, attenuation, revocation, lease consumption, all ancestor budget debits
and transport enqueue share that lock. Enqueue must return promptly; network
completion remains outside the lock. An uncertain dispatched mutation is never
retried by this change.

An `RCIRAuthorityRequest` represents:

- exact subject, audience set and discovered target set;
- exact provider, capability, authenticated provider principal, generation and canonical discovery bytes per target;
- exact resource/effect scope pairs;
- unrestricted ABI-valid arguments or a finite set of exact typed canonical arguments;
- permitted task-start shapes;
- expiry, invocation limit and remaining downstream delegation depth.

Children may select a new subject but every other represented authority dimension
must be a subset of their parent's. Credential-reference sets must also shrink.
Every dispatch checks the entire live ancestry. Child revocation leaves siblings
usable; ancestor or credential-reference revocation invalidates descendants.

A grant is an immutable random host-local handle with canonical evidence bytes.
It has no public constructor or deserialize/redeem path. Those bytes are not a
signed or remotely redeemable bearer token. The receipt signs the exact grant
ancestry inside the existing canonical lease request. Credential references
contain only a UUID, issuer identity and audience; no token, private key, credential
path, raw provider bytes or secret resolver enters this ledger.

## Execution integration and compatibility

The trusted host may attach `RCIRHostAuthority` to one execution invocation. Its
grant is immutable and its context callback derives the current authenticated
subject/audience from that host's session. No identity is taken from model
parameters, MCP `clientInfo` or provider metadata. The callback's authentication
error text is sanitized.

The final admitted transport start rechecks grant identity, ancestry, expiry,
current policy, exact arguments, resource scope and provider incarnation.
Grant-backed leases cannot be consumed through the compatibility scope-only API.
Ongoing task/observation checks revalidate grant identity, expiry and revocation
without debiting a second invocation for the already admitted task.

The default scope-only host path remains supported and explicitly trusted-host
only. Production MCP/native identity wiring is still RED. Model-visible Core
requests cannot opt into, replace or manufacture a host authority attachment.

## Bounds and evidence

The ledger retains at most 4096 grants and 8 MiB of grant canonical bytes, 4096
credential references and 1 MiB of reference canonical metadata. Outstanding
leases retain at most 4096 records and 16 MiB of request bytes. Each request keeps
the existing 131072-byte ceiling. Authority lifetime is at most 60000 milliseconds;
ancestry is at most a root plus 16 descendants. Expired records are reaped;
unexpired revoked grants keep their state and counters. These are encoded-payload
bounds, not measurements of allocator overhead. A large or deep grant/request can
fail closed at byte/node limits.

Evidence: `evidence/agency-authority-20261007/`.

- Foundation final: 100 tests, zero skips/failures; 29 authority cases.
- Full native final: 718 tests, 31 pre-existing environment exclusions, zero failures. All 38 new authority cases ran; nine use a real disposable HTTP process.
- Independent Python receipt verification: 16 tests, zero failures, including legacy receipt compatibility and signature-valid widened/unknown authority claims.
- Legal child: one actual POST, separate exact GET readback, independently verified Ed25519 signature, expected child subject/audience and parent subject checked by the Python decoder.
- Final signed grant ancestry and exact file hashes are in the evidence manifest. Fixture signing keys are provisioned test keys, not a production trust root.
- The optimized benchmark records five samples of 1000 local issue/consume pairs against the existing trusted-scope path and parent/child path. It excludes transport and signing.

The independent decoder accepts exactly the six legacy request fields, or those
six plus the explicit `authority` field. It recursively validates supported grant
fields, attenuation, exact target/argument/effect/task binding and time intervals.
Expected authority comparisons are explicit. A signature does not prove live
issuer enforcement, budget state, revocation state or external truth by itself.

CI definitions now include the Foundation cases, actual HTTP authority dispatch,
and independent authority receipt decoding. Their remote execution remains
unproven until the integration branch's CI runs.

## Remaining RED

No public `context_authority` or `context_delegate` primitive is added. Authenticated
transport/OS identity wiring, actual issuer/provider downscoping and credential
resolution, distributed/persisted grants, production signer lifecycle, central
subject/delegation-chain policy inputs, task-control permissions, constraint
languages beyond finite exact arguments, multi-agent hierarchy acceptance and the
complete eleven-substrate delegated proof remain RED. Task-start shapes are not
permission to pause, cancel, resume or retry. Provider discovery fingerprint bytes
are exact canonical material; this change does not relabel them as a cryptographic
hash. Procedural knowledge remains advisory and cannot issue or bypass a grant.
