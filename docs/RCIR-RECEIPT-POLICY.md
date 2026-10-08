# Managed receipt policy in the shared runtime

An unchanged private signing key does not establish current permission to sign. A2A held-task controls exposed a generic missing issuer-policy check: a revoked key could still admit a real mutation and sign its completion. The reusable primitive is one protected, retained receipt-policy loader with issuer/key lifecycle authorization tokens. The provider layer remains the existing A2A task transport; the same admission and receipt-emission path serves unary and deferred substrates. No additional agent operation, receipt format, cryptographic implementation or runtime process is added.

## Operator reference

The existing protected host configuration accepts an optional `receiptTrustPolicyFile` alongside `signingKeyFile`. Both references remain host-owned; neither the provider nor the agent can provide them through `context_run`. A configured policy requires a configured signing key. A missing, malformed, unsafe or withdrawn policy denies new admission. The raw host JSON reader rejects duplicate fields, escaped duplicate aliases and unknown fields before ordinary decoding.

The public policy document contains exactly `version` (1), `issuerID`, `maximumLiveAge` and `keys`. Each key record contains exactly `keyID`, the canonical base64 public key, `notBefore`, `notAfter`, `retiredAt` and `revoked`. Time values are integer milliseconds; `retiredAt` is null or an integer, and `revoked` is a JSON boolean. Documents are bounded to 128 KiB and 64 key records. Protect this public document because it authorizes signing; it never contains a private key. Use the native protected-reference backend on each host.

The retained policy cannot remove an observed key, reassign its identity, widen its validity or undo retirement/revocation. A later task can use a legally added fresh key; unrelated additions preserve existing valid authorization tokens. Malformed updates are transactional and cannot partially change trust. Restoring an older public document does not erase an observed revocation in the running host. Removing or changing an armed policy reference does not restore legacy signing. Correcting a malformed document at the same armed reference can recover when the update preserves the retained lifecycle constraints.

Admission refreshes configuration and consumption callbacks before the final protected signing-authority check. It then samples the trusted, non-mutating host clock freshly for consumption, because protected validation can take time and outlive a lease. Signing repeats current reference, private-source identity and issuer-token checks on both sides of the actual Ed25519 operation. These are local revalidation boundaries; they do not claim atomicity with an external file writer or distributed revocation.

If authorization disappears after an actual effect, the host retains the independently observed outcome and unsigned canonical receipt, with the explicit signature-withheld event. It does not discard the effect, retry the mutation or invent a valid signature. Unsigned canonical bytes remain a runtime assertion with authenticity unestablished.

## Evidence and limits

The original four real A2A controls preserve the missing-policy RED and legal active-key/rotation positives. Separate final-admission callback controls preserve real unintended requests/effects before the callback-ordering fixes. GREEN must include zero requests/effects for each pre-dispatch denial, actual provider and separate observer journals for permitted effects, signature verification against independently captured public pins, and explicit unsigned handling after withdrawal. Public policy-write histories are unsigned fixture evidence; their byte hashes establish archive identity, not issuer authenticity.

This is a candidate implementation. The full native macOS/Linux/Windows suite, immutable release, clean installation, restricted-agent eleven-substrate proof, authenticated issuer/runtime identity, durable restart/distributed revocation and consumed replay protection remain independent gates. Version-1 receipt bytes and existing bare-public-key verification remain compatible. Managed live/historical receipt acceptance requires separately provisioned verifier policy; receiving a key inside a receipt does not provision trust.

## Product impact

1. Installation stays one `rightclick` executable; no additional package or process is needed.
2. Managed signing adds an operator security reference behind the existing configuration boundary; normal discovery does not require it.
3. Parsing, lifecycle reconciliation and signing authorization remain inside the runtime.
4. Providers and agents use the same existing capability and seven-operation interface.
5. Issuer trust requires an approved provisioning channel; discovering a public key cannot authorize it automatically.
6. A default user can still discover and execute supported capabilities within the existing setup flow; managed receipt trust has its own provisioning and verification evidence.
