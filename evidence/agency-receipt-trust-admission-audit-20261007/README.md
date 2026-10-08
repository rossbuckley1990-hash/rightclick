# Protected receipt policy at final transport admission

This preserves two real A2A failures found during independent source review of
the shared runtime. Each test exercised a host callback that wrote a valid
protected issuer policy revoking the unchanged signing key. The old ordering
still started one provider request, produced one effect and read it back through
the separate observer. Each native run has one test, three expected assertion
failures and zero unexpected failures. The final result truthfully remained an
unsigned canonical runtime assertion, with the signature-withheld event.

| RED | Substrate exposing it | Generic deficiency | Reusable primitive/repair | Provider layer | GREEN evidence | Other substrates |
| --- | --- | --- | --- | --- | --- | --- |
| Configuration callback after signing authority validation | A2A held task | A configuration refresh could withdraw issuer authority after the last check but before transport admission | Refresh the current host policy before the final protected signer validation | None; existing generic A2A task/observer fixture | Exact configuration control changes from one request/effect/readback to rejection with zero requests/effects | Same common host admission used by the other reflectors |
| Consumption callback after signing authority validation | A2A held task | Argument/authority/context/time callbacks could run after the last signer check | Snapshot admission callback results before the final signer check, then use frozen values under existing lease/budget/graph admission lock | None | Exact consumption callback must actually revoke, then yield rejection and zero requests/effects | Same admission primitive applies across providers; no extra AI operation |

The independent audits use the existing canonical receipt decoder and existing
Ed25519 verifier. They bind task, lease, canonical argument message and canonical
observation bytes to the request/effect/readback journals. A signature is checked
only when actually emitted, against a separate raw public-key pin. Unsigned
assertions have no authenticated receipt claim.

Public policy history contains exact written public bytes, SHA256, sequence and
fixture wall-clock time. Digests and the final protected archived snapshot match.
This history is an unsigned fixture write journal, not an authenticated issuer
log or trusted timestamp. Deletion is evidenced by the native test and missing
archived current snapshot, not a signed deletion event.

`configuration-red/` and `consumption-red/` retain each raw synthetic fixture
once, with lossless native logs. `artifact-manifest.json` records their exact
hashes and the separately retained intermediate ten-case evidence hashes. The
intermediate ten-case audit passes seven effects, five denials, three signatures
and four unsigned assertions; the subsequent consumption RED supersedes its
final-admission acceptance claim. Final eleven-case evidence is recorded only
after a fresh run and independent audit.

The fresh eleven-case run at root source
`0fdb5d28c733215d8b0f352b15af6f372d2c8153` passes the independent audit:
seven effects with readbacks, six rejected executions with zero corresponding
provider requests, three verified signatures and four unsigned assertions.
Both measured callback controls actually revoke and deny without an effect.
Seven altered-artifact controls are rejected: missing case, invalid signature,
wrong public pin, matching journal swap against a different bound message,
wrong policy digest, unexercised callback and unsigned truth relabelled as a
signature. This checks the artifact auditor's rejection behavior; it does not
authenticate unsigned journals. Final native raw artifacts remain in root's
`/private/tmp/rightclick-root-production-trust-final-green-20261007`; root owns
their archival. This directory retains their hashes and independent audit
without making a second raw copy.

A separate read-only follow-up remains RED: the admission time is captured
before protected signer validation. A slow final configuration/protected-input
callback may carry that frozen time past a lease's actual expiry. The eleven
controls do not exercise that delay. Root was given a concrete native control
proposal; no expired-lease dispatch guarantee is inferred from these passes.

The bounded privacy review covered only these fixture artifacts, their raw logs
and decoded receipt/public-policy bytes, checking private PEM, obvious bearer
and common GitHub token patterns. It found no matches. It is not a comprehensive
secrecy proof. Private signing-key bytes are not archived.

Scope remains local retained-policy reconciliation and current protected signer
revalidation in the running host. Restart-persistent/distributed revocation,
external clock attestation, complete broker/credential privacy, native final
platform/profile proofs and the full goal remain RED. This audit is not the
restricted seven-operation AI proof. RIGHTCLICK Stable runtime/provider discovery
was used; procedural-memory retrieval was not demonstrated.
