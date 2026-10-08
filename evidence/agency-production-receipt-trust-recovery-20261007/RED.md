# Fresh production receipt-policy RED after recovery

This is newly generated evidence at source fe72457100d74cdc2a6df6a4694da8149c6c2ea6 in the independent recovery checkout. Original f0 receipt/effect journals were lost with the project mirror and are not claimed recovered.

Four native Mac held A2A tests executed: active issuer and fresh key rotation controls passed; pre-admission revocation and post-admission revocation failed five expected assertions, zero unexpected errors. Five actual effects had separate observer readbacks; the independent Python decoder validated all five signed task/lease claims and request/effect/observer bindings. In both revoked cases the private signing bytes stayed identical.

| Pressure test | Actual request/effect/readback count | Independent current policy | Runtime |
| --- | --- | --- | --- |
| Active issuer | 1/1/1 | Accepted | Signed observed success |
| Legal rotation | 2/2/2 | Fresh key accepted | Two keys/tasks and signed successes |
| Pre-revoked policy | 1/1/1 | Revoked key rejected | Started/dispatched/signed |
| Policy revoked after admission | 1/1/1 | Revoked key rejected | Observed success still signed |

**Substrate exposing the failure:** genuine held A2A task with a separate artifact observer. **Generic deficiency:** production host has no receipt-policy input consumed at admission or signing. **Reusable primitive:** protected monotonic policy loader and per-key live authorization token are now implemented/tested; host admission/emission still must consume them. **Provider layer:** none. **Required GREEN:** zero request/effect before admission with pre-revoked policy; after possible effect, preserve unsigned observed/unknown truth and generic withheld event; keep active issuer and legal rotation controls passing. **Other substrates made easier:** every unary/deferred/streaming receipt producer can use the same host-owned policy boundary.

The protected sidecar is a declared desired host input, not a falsely claimed configured production seam. The policy library independently enforces its revocation. Root owns the integration repair; this source deliberately preserves the failing tests before repair.

The independent audit replays policy at signed observation time for recorded evidence; it does not prove present live freshness. Actual Swift controls used their current host clock. Old retired-key historical acceptance is outside this audit; old-key math and fresh-key live acceptance are checked.

Only own synthetic fixture messages, challenge/task UUIDs, public pins/policy documents, runtime records and journals are archived. No private key or credential file is included. The scoped marker scan covers private PEM, obvious bearer and GitHub markers only. Native Windows, restart-persistent/distributed revocation, replay consumption, executable issuer attestation, restricted-agent candidate proof and full programme acceptance remain RED.
