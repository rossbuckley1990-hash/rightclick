# Production OpenAPI RCIR boundary

This candidate extends the existing Capability ABI and OpenAPI compiler. It introduces no top-level tools and keeps legacy string arguments. `CapabilityEngine.run` (CLI) and `begin` (MCP/federation) pass OpenAPI reflectors an engine-owned admission host. The ARD OpenAPI wrapper forwards the same host and acquisition owner. Configured, Bonjour and artifact-resolved OpenAPI use the existing compiler. Other substrate integration remains G5 work.

The existing compiler validates request/path schemas and exact credential origin before lowering. RCIR binds the compiled method, exact URL/body digest, complete typed arguments, declaration, current owner generation and policy. GET requires read authority; other supported methods conservatively require execute authority. A title never establishes purity. Required bearer authority is re-read and compared immediately before consumption. Public operations acquire one invocation-bound public-access lease after existing confirmation; this is local authorisation, not issuer-enforced credential downscoping.

Admission serializes lease consumption with `URLSessionTask.resume()` under one lock. It releases the lock before waiting. This prevents an in-process graph withdrawal from interleaving consumption and transport start. It does not make HTTP exactly once. Neither timeout nor ambiguous transport failure retries a write. URL-acquired specifications are read again with bounded, cache-bypassing acquisition before transport and after dispatch. Changed or unavailable bytes invalidate admission; acquisition caches refresh the compiler and expose a new contract without reconnecting. Replacement does not grant authority. Inline/operator-owned snapshots have no remote locator and retain the engine graph boundary. Removal or live schema drift after dispatch yields unknown. A separately confirmed repeat gets a new lease; experience remains advisory.

Run/status add optional `rcir` evidence containing task/lease identity, generation, phase, semantic outcome and canonical receipt bytes. A signed envelope is present only when a signer has actually been provisioned. Provider acceptance defaults to unverified. The seven operation schemas remain compatible; typed wire negotiation, cursor ownership and network streaming are later gates.

## Invocation and graph identity

The compiler supplies its stable discovered Capability ABI separately from the exact invocation binding. `RCIRAdmission.publishInvocation` retains the provider generation across different request bodies/resources/postconditions while keeping each value in its own lease. Changes to the discovered declaration, authenticated principal, effect kinds or task model invalidate leases. Withdrawal and reappearance create a new incarnation. See [invocation isolation and real-effect RED/GREEN](RCIR-INVOCATION-ISOLATION.md).

## Operator configuration

Set `RIGHTCLICK_RCIR_CONFIG` to a local operator-owned JSON file. The file and any raw 32-byte Ed25519 private key must be owned by the runtime user, regular files, with no group/other permissions. Symlinks and unknown configuration keys are rejected. A malformed configured file denies dispatch. No implicit signing key is generated.

```json
{
  "version": 1,
  "revision": "reviewed-local-policy-1",
  "deniedCapabilities": [],
  "signingKeyFile": "/operator/private/receipt-key.raw",
  "observers": {
    "<exact discovered capability ID>": {
      "urlTemplate": "https://service.example/records/{id}",
      "expectedArgument": "value"
    }
  }
}
```

`signingKeyFile` and `observers` are optional. Keep private keys out of source, model arguments and evidence. Provision and independently pin the corresponding public key through the operator's trusted channel. A managed signing deployment can additionally set the optional `receiptTrustPolicyFile` to its protected public issuer/key policy. The shared host checks that policy before transport admission and before and after signing; see [managed receipt policy](RCIR-RECEIPT-POLICY.md). Independent verifier trust, issuer identity, durable revocation across restarts and credential issuance remain separate requirements.

The first observer slice is a bounded same-origin, credential-free GET in an isolated ephemeral session with cookies and credential storage disabled, with argument path segments restricted to ASCII URI-unreserved characters (`A–Z`, `a–z`, digits, `-._~`), excluding empty values, `.` and `..`. Separators, percent encodings, queries, fragments and Unicode IDs are unsupported by this initial observer and reject admission before effects. It compares exact UTF-8 response text to the selected argument. The provider and agent cannot supply this observer through a tool call. It never substitutes into a query or different origin; redirects are rejected. A protected endpoint needing separate observer credentials remains unverified in this slice. Read-back is independent of invocation output, but the same service is still a trust source; it is not independent third-party attestation. Missing observation remains unverified. A mismatch fails even if POST returned 200.

Legacy caller postconditions retain their existing returned-value semantics through the host verifier. They prove the requested returned bytes and do not establish external side effects. When a host observer is configured, caller postconditions cannot weaken or replace it; both must pass. Unsigned receipt bytes are evidence, not a signature. A signature authenticates runtime-observed bytes and never turns failed/unknown/unverified into success. Canonical receipts currently include invocation arguments; minimise them before sharing. Production public-receipt minimisation remains G3 work.

## Reproduce the candidate

```sh
swift test --force-resolved-versions
bash scripts/test-rcir.sh
python3 scripts/acceptance-rcir-openapi.py .build/debug/rightclick /tmp/rcir-public-proof
python3 scripts/acceptance-rcir-openapi-freshness.py .build/debug/rightclick /tmp/rcir-freshness-proof
```

The public proof provisions a disposable real Bonjour/OpenAPI server and signer. It discovers through the actual runtime, invokes public MCP operations and verifies signatures with OpenSSL against a separately captured public key. Infrastructure setup is disclosed engineering workbench activity. This is not the restricted eleven-substrate proof agent. No Docker, paid services or personal credentials are needed.

`RCIRProductionDispatchTests` exercise the actual HTTP transport against a separate Python provider and inspect its effect log. They inject clock/graph/policy/argument faults through internal test seams, unavailable in the public tools or configuration. They cover lease expiry/not-yet-valid/replay/racing consumers, changed arguments, schema/endpoint drift, removal/reappearance, missing exact-origin authority, invalid signer, invalid observer and post-dispatch uncertainty. Set `RCIR_DISPATCH_EVIDENCE` to preserve each provider log.

The dedicated production CI workflow preserves raw transcripts, effect logs and receipts. Foundation Linux/macOS tests and full native regressions remain separate. The installed 0.2.2 product has not acquired this candidate merely because its version matches. No release or eleven-substrate readiness claim follows from these gates.

The initial RCIR slice retains foundation size bounds: 64 KiB contract/graph declarations, 128 KiB canonical request envelopes (including binding and arguments), a default 256 KiB accumulated task-event budget and 1 MiB ABI encoding. A compiled body digest avoids duplicating arguments into the declaration; it does not loosen these limits. The real 80,000-byte argument control proves a supported bounded body still dispatches. Values above applicable limits are explicitly rejected or produce honest post-dispatch unknown outcomes where only the response exceeds a bound. No unlimited legacy-payload claim is made.

Bonjour acquisition UUIDs are minted by the local owner and inserted into the existing metadata/ABI. They distinguish removal/reintroduction even when endpoint, public ID and schema bytes are identical. Provider documents cannot choose them. Queued/in-flight reads and obsolete service callbacks cannot restore a withdrawn incarnation. Discovery refresh of the same acquired schema retains its incarnation; a new acquisition revokes the prior invocation binding.
