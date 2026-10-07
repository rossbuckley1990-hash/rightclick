# Remote OpenAPI capability gain, execution, and phone outcome — 2026-10-06

## Result

**PASS**, with the claim boundaries below.

This experiment demonstrated that an ongoing ChatGPT conversation using RIGHTCLICK could gain a capability reflected from remote HTTPS software, execute that newly discovered capability after confirmation, verify the provider's deterministic returned-text receipt, and produce an independently visible notification on a physical iPhone carrying the same live proof code.

A separate lifecycle pass then demonstrated that the remote capability was absent after its discovery advertisement was removed and present again after the advertisement was restored. A later second invocation was blocked by the ChatGPT platform before it reached RIGHTCLICK, so this evidence does **not** claim that the second notification was sent.

## Frozen parent

Repository parent before the candidate change:

`0e733f5fb64bbc2f10ef8701e6a2e2dbc2f7335b`

Commit message:

`evidence: record OpenAPI discovery execution and live removal`

The sealed v0.2.0 RC1 binary was not modified. The successful remote run used an isolated RC2 candidate derived from the frozen parent above.

## Candidate runtime attestation

The live RIGHTCLICK process serving the successful remote capability evaluation reported:

- product: `RIGHTCLICK`
- version: `0.2.0`
- executable path: `/tmp/rightclick-v020-remote-fqdn-rc2/.build/release/rightclick`
- executable real path: `/tmp/rightclick-v020-remote-fqdn-rc2/.build/arm64-apple-macosx/release/rightclick`
- executable SHA-256: `60aba8cc28e40fb2e16637e380381fe2a98b844c2c435a136515a3f1382feb17`
- live proof PID: `43135`
- transport: `stdio`

## Interoperability defect found before the pass

The remote provider was originally advertised through Bonjour as an Internet proxy record whose resolved hostname was an absolute DNS name ending in a root dot:

`rightclick-remote-openapi.spiny-justice.workers.dev.`

macOS `NetService` resolved that service correctly, but Foundation `URLSession` failed the HTTPS request with `NSURLErrorDomain Code=-1200` on the trailing-dot form. A diagnostic showed an unexpected TLS peer certificate rather than the Worker hostname. A plain-HTTP diagnostic was also upgraded by Foundation to HTTPS and failed on the same path.

The RC2 candidate fixes this narrowly at the Bonjour boundary:

- trim surrounding whitespace as before;
- remove exactly one terminal DNS root dot before constructing provider URLs;
- reject a host that still ends in `.` after that removal, so malformed multiple terminal dots fail closed.

This does not weaken the existing scheme, effective-port, redirect, acquisition-size, acquisition-deadline, or origin-pinning rules.

## Candidate test result

The candidate was tested before the live remote gate:

- `BonjourOpenAPISourceTests`: **7 executed, 0 failures**
- full suite: **134 executed, 8 skipped, 0 failures**
- release candidate binary SHA-256: `60aba8cc28e40fb2e16637e380381fe2a98b844c2c435a136515a3f1382feb17`

The skips were existing environment-gated acceptance tests, not failures.

## Remote provider

The software executed remotely on Cloudflare Workers and identified itself as:

`RIGHTCLICK REMOTE CLOUD SOFTWARE`

The OpenAPI provider reflected into RIGHTCLICK as:

`RIGHTCLICK Remote Cloud Software`

with capability:

`Publish Proof Through Remote Cloud Software`

The reflected operation ID was:

`broadcastRemoteProof`

The remote origin used by the successful invocation was:

`https://rightclick-remote-openapi.spiny-justice.workers.dev`

The Bonjour advertisement used:

- service type: `_rightclick._tcp.`
- instance: `RIGHTCLICK REMOTE CLOUD`
- port: `443`
- `kind=openapi`
- `scheme=https`
- `spec=/openapi.json`
- `base=/`

The Bonjour proxy advertisement was local discovery metadata. The provider implementation and action execution were remote on Cloudflare; there was no local HTTP provider serving the action.

No provider-specific MCP server, ChatGPT tool definition, or plugin was added for this remote provider.

## Successful execution

The user authorized the newly discovered remote capability.

Exact message:

`This AI learned how to do this after I asked. Proof: 3XD527`

RIGHTCLICK recorded:

- action: `Publish Proof Through Remote Cloud Software`
- execution ID: `D01A9A12-F47F-4E64-85CC-DD385FF6A0F0`
- request: `HTTP POST https://rightclick-remote-openapi.spiny-justice.workers.dev/broadcast`
- provider HTTP status: `200`
- state: `succeeded`
- provider output: `RIGHTCLICK_REMOTE_PUBLISHED`
- verification predicate: exact returned text equals `RIGHTCLICK_REMOTE_PUBLISHED`
- verification status: `VERIFIED_SUCCESS`
- `outcomeVerified`: `true`

That RIGHTCLICK verification establishes the exact provider-returned receipt. By itself it does not prove the downstream phone notification.

## Independent phone outcome

The user then supplied a screenshot from the physical iPhone showing the ntfy notification with the exact message and live proof code:

`This AI learned how to do this after I asked. Proof: 3XD527`

Frozen screenshot:

`PHONE_PROOF.png`

- dimensions: `941 x 2048`
- SHA-256: `4eaaac0ec51846645f8682ad0131385cd2f28b5ba14797f81d1f65b612b2514f`

The matching unpredictable proof code links the externally visible phone outcome to the confirmed execution in this run.

## Capability loss and regain

A second demonstration used the exact message:

`This AI learned how to do this after I asked. Proof: M7K4P2`

After the remote Bonjour advertisement was removed, a live `context_actions` query in the same conversation did **not** contain `Publish Proof Through Remote Cloud Software`.

The remote advertisement was then restored without restarting ChatGPT. A subsequent live `context_actions` query for the same message **did** contain the remote capability again.

This supports the lifecycle observation:

`advertisement absent -> capability absent -> advertisement restored -> capability present`

The later confirmed invocation attempt for `M7K4P2` was blocked by the ChatGPT platform before it reached RIGHTCLICK. No claim is made that a second notification was sent.

## Exact claim supported by this evidence

> In one ongoing ChatGPT conversation, an isolated RIGHTCLICK v0.2.0 candidate discovered a capability from a remote Cloudflare-hosted OpenAPI provider through its existing generic capability interface, executed the reflected operation after confirmation, verified the provider's exact returned receipt, and the physical iPhone displayed the same live proof code. In a separate lifecycle pass, the capability was absent when its discovery advertisement was removed and present again after the advertisement was restored, without restarting ChatGPT.

## Claim boundaries

- This is evidence for the isolated RC2 candidate, not the sealed RC1 binary.
- The provider action ran remotely on Cloudflare, but a local Bonjour proxy advertisement made that remote service discoverable to RIGHTCLICK.
- `VERIFIED_SUCCESS` verifies the provider-returned receipt; the iPhone screenshot is separate evidence of the downstream external effect.
- The later `M7K4P2` invocation was blocked before reaching RIGHTCLICK and is not counted as a successful execution.
- The remote Worker was temporary and may no longer be reachable when this evidence is read.
- This evidence does not claim universal OpenAPI compatibility or arbitrary remote-software compatibility.
- No credentials, API keys, tunnel secrets, Cloudflare claim tokens, ntfy topic identifiers, or unrelated process command lines are preserved here.
