# Agency runtime security review — 7 October 2026

Review base: root candidate `950b6a4`. Frozen adversarial source/evidence commit:
`d88df95`. Authority foundation separately reviewed at `85401f0`; portable
protected-file backend reviewed at `018c96c`. These are candidate boundaries,
not a release, installed eleven-substrate proof or native Windows acceptance.

| Finding | Original location | Demonstrated failure | Repair |
| --- | --- | --- | --- |
| P1 — protected observer credential retained in signed metadata | `RCIRHTTPObservation.swift:47` | Actual read-only HTTP observer echoed its bearer into a declared metadata string. Requested challenge/digest matched, outcome was `succeeded`, and decoded receipt retained the credential. Public RED evidence retains only a leak Boolean. | Bounded `CapabilitySensitiveMaterial` rejects known protected material before observation retention, verification or signing. It abstains with generic error; it does not verify substituted bytes. |
| P1 — mutation claim lacked configurable invocation binding | `RCIRHTTPObservation.swift:80` | Actual no-op HTTP ACK plus an old independently read matching artifact produced signed `succeeded`, despite an old invocation marker and zero applied mutation. The trusted configuration callback could not represent the requested causal binding. | Optional protected JSON `invocationBindingPath` lowers into the existing `RCIRVerificationContract`; exact host task UUID is the expectation. Old marker fails; absent marker abstains. |
| P2 — state predicate boundary overstated its evidence | `RCIRExecutionHost.swift:384` | State-only read-back legitimately matched existing state, but its wording did not distinguish that from current mutation causality. | State-only predicates remain supported and explicitly state this evidence limit in the model-visible message and signed observation boundary. |

The causal RED uses the native engine's trusted configuration callback, decoding
the requested JSON shape without inventing a constructor that would fail to
compile against the original source. The former protected-file loader would
reject the new causal key; it did not already support that configuration. The
GREEN seven-operation run separately proves that the production protected-file
loader accepts and enforces the new key.

## RED → GREEN pressure tests

| Substrate exposing RED | Generic runtime deficiency | Reusable primitive | Thin provider layer | GREEN evidence | Reuse |
| --- | --- | --- | --- | --- | --- |
| REST/OpenAPI ACK-only writer with independent HTTP JSON observer | State equality could not bind a mutation claim to the current invocation | Existing RCIR invocation binding, exposed through protected observer configuration; honest state-only predicate boundary | Writer stores the host `X-RightClick-Invocation`; independent observer exposes that marker | Old/no-op marker produces signed `failed`; missing marker signed `unverified`; fresh stored marker equals task ID and produces signed `succeeded` | Same verification primitive already applies to Kafka/Kubernetes and can bind Windows/Linux/REST/A2A observers without a new AI operation |
| Credential-backed independent HTTP observation | Untrusted but schema-valid metadata could reflect broker-held secret material into a receipt | Bounded immutable known-sensitive-material guard; reject before retention | Observer gives its protected snapshot material to the common guard | Raw, Base64, URL-safe Base64, encoded Authorization, hex and escaped JSON cases all signed `unverified`, with no credential in emitted receipt | Other credential-backed response/observation boundaries can reuse the guard; broad broker-wide application is still required |

The initial five actual HTTP controls had seven assertion failures. The same
five became GREEN. Expanded malformed-path and six encoding controls plus
observation/ACK/authority regressions passed **47 tests, zero skips/failures**.
Large logs are losslessly compressed with original/archive hashes.

`scripts/acceptance-http-json.py --acknowledgement-only --causal` then exercised
the real stdio runtime with exactly seven canonical operations. It discovered
and explained the ACK-only capability, proved confirmation/policy caused zero
requests, rejected old matching state, matched fresh task identity, abstained
on real credential reflection, and observed live capability removal while the
seven tool definitions remained unchanged. This is an engineering client,
not a fresh AI agent. Candidate executable SHA:
`5eaf84ad7d69b4dc2a37eb61d87564a52076c1ffe017ef8fc60bc208d3ba1e5d`.

Receipts were verified against separately provisioned pinned keys by OpenSSL
and the independent Python verifier. A separate Python canonical-byte audit
corroborated the signed path, marker/state bindings and outcomes. A valid
signature authenticates a runtime assertion; the fixture's actual independent
file observations supply the resource evidence.

Evidence: `evidence/agency-security-20261007/`, including both original failures
and subsequent runs. No private signing key or observer bearer is archived.

## Other reviewed boundaries and remaining RED

Authority foundation `85401f0` uses exact UTF-8 identities and scopes, finite
argument constraints, current provider generation/discovery binding, attenuated
target/audience/resource/effect/task-shape/expiry/count/depth sets, shared
ancestor counters, and revocation checks under the existing admission lock.
The final synchronous enqueue shares that lock. Existing trusted-host scope
APIs cannot redeem grant-bound leases. Aggregate grant/reference/lease byte
bounds were tightened during this review. No escalation was identified in
those represented dimensions from source inspection and supplied tests.

Those findings do not authenticate an MCP caller or create an issuer broker.
The host must supply a genuinely authenticated context. Task-control rights,
remote/distributed grants, issuer downscoping, public delegation and real
independent attenuated agents remain RED until demonstrated.

The portable C backend checks the actual file handle, owner SID and conservative
DACL, denies write/delete sharing, rejects reparse/directory/path substitution,
and bounds reads. Private ACL/attribute changes now use validated handles and
do not take ownership. Its subject is the native process token, not an
impersonating multiuser broker. Native Windows tests are still required; source
review is not a native GREEN.

Protected-material coverage is limited to the tested exact/common encodings at
this HTTP observer boundary. Arbitrary secret splitting/obfuscation, every
other credential-backed transport, complete trace/error/persistent-memory
coverage, and privacy-minimized receipts remain RED. Full observations are
still retained after the guard, and observer IDs still include host reference
paths. Production signing identity, rotation/trust/revocation also remain RED.

Self-use: installed RIGHTCLICK `0.2.2`, SHA `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`,
provided exactly seven tools and 42 providers; runtime/providers/inspect/actions
were used. No advisory experience annotations were returned, so procedural
memory use is not claimed. Private self-use transcripts remain outside this
public evidence package.
