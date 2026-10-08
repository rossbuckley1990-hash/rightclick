# Nested execution acceptance

The implementation baseline is portable commit
`d496cf1b240bc97a52dbb5a5a76f378fd183b074`. The isolated branch is
`feature/nested-execution-fabric`. The protected main SHA is separately recorded
in `evidence/nested-execution-fabric/baseline.json`; no acceptance work requires
changing main, releases, bottles, credentials, or installed runtimes.

`NestedExecutionAcceptanceTests.testNestedGenericMCPAuthenticatedLinkProofRealityAndDurableTeardown`
is the default deterministic integration scenario. It composes the actual
`RightClickMCP` handler, `CapabilityEngine`, environment contextual source,
durable coordinator, Link dispatcher, signed Link client, replay ledger,
runtime enrollment verifier, lease verifier and execution-proof adjudicator.
The provider is `InMemoryEnvironmentProvider`.

This is a simulated environment and runtime identity model in one test process.
The test does not start a Linux VM, Linux executable, container or cloud resource.
The runtime manifest's platform, version, architecture and executable digest are
fixture expectations checked against the simulated provider's separate
observation. They are not a measured live executable. The simulated relay uses
actual signed Link requests/results without opening a network listener.

The public MCP contract must retain these exact seven operations and its
candidate-baseline canonical schema SHA-256:

- `context_actions`
- `context_explain`
- `context_inspect`
- `context_providers`
- `context_run`
- `context_run_status`
- `context_runtime`

Both the names and complete schema digest are asserted before and after the
scenario. Generic environment actions are dynamically discovered capabilities
under this existing interface, including `environment:create`,
`environment:bootstrap`, `environment:create-child`, `environment:execute` and
`environment:destroy`. They are not additional public MCP operations.

The verified portable-baseline schema digest is
`57758dc2cd5be92e1dc4dfbcd20b2bcffede88b4520a6197f17850d688105cbd`.
The untouched candidate binary, its executable digest, exact `tools/list`
response and baseline commit are recorded in
`evidence/nested-execution-fabric/portable-baseline-tool-schema.json`.

## Scenario and decisive observations

| Stage | Actual boundary exercised | Evidence required by the test |
| --- | --- | --- |
| Parent startup and factory discovery | `context_actions` on `rcenv://fabric` | One generic create capability, classified as an environment and requiring confirmation |
| A creation | `context_run` through ordinary RCIR admission | Missing confirmation produces awaiting-user and no provider effect; confirmed creation produces an independently observed present resource |
| A bootstrap | Parent generic capability plus host-installed callback | Provider acceptance alone cannot expose workload capabilities; actual Link enrollment verifier checks signed claim, challenge, exact handle/lineage, pinned manifest and independently observed ephemeral public key |
| Root grant to A | Signed Ed25519 capability lease and durable coordinator | Exact enrolled subject; one child, depth one, finite TTL/executions/resources/cost and empty network allowlist |
| A discovery and B creation | A's fixed caller identity/source, authenticated signed Link dispatcher | Factory access remains absent; child creation is discovered and cannot dispatch without the exact host approval ticket; B is retained with A's creating lease and runtime/execution lineage |
| B bootstrap and delegation | Root lifecycle broker; A's node-local typed lease signer; coordinator allocation | Parent verifies B enrollment independently; B's issuer is A's enrolled key; B's signed lease attenuates scope, TTL, execution/resource/cost quotas and has zero child/delegation authority |
| B capability discovery | B's own `context_actions`, then A's Link registry | Only observe/execute/destroy are exposed; B cannot discover A's private contextual capabilities |
| Workload and upward report | A's generic MCP call to its discovered B Link route | A authenticates B using B's exact enrolled key; B requires its own local approval; B signs the challenge proof with its node-local key; A reports success after the authenticated signed B result returns |
| Parent adjudication | Coordinator's independent observation and ordinary RCIR host observer | The exact fresh random challenge is read from B's provider observation channel; signed host certificate and final RCIR outcome both succeed; child reports do not define the expected value |
| Replay rejection | Durable proof-consumption state and Link replay ledger | Re-adjudicating the same signed proof fails with invalid-sequence; replaying the signed create request fails with replay and never creates a third resource |
| False postcondition | Same signed route, provider acceptance and child success claim | A deliberately different independently observed value produces a failed RCIR outcome; a separately supplied valid child success proof cannot obtain any host certificate after that failure |
| Recursive teardown | Parent `context_run` destroy capability | Provider operation order is B then A; exact correlations independently observe both absent; both retained records are revoked and have no active runtime |
| Revocation and key destruction | Coordinator admission plus node-local signing proxies | Both exact lease subjects stop authorizing workloads; both opaque Link identities stop signing after destruction; simulated provider active-runtime count is zero |
| Durable receipt access | New coordinator and new engine opened against the same protected journal | Recovery owner reads the journal before the shared in-memory execution cache; successes, failure and destruction remain queryable through `context_run_status`; signed proof and certificate bytes remain intact |

The reopened coordinator is logical recovery within one process, rather than a
new OS process. Directly reading its recovered status owner proves that an old
`ExecutionStore` cache cannot satisfy the durability assertion. The test removes
the B route and disconnects its simulated relay after teardown.

## Review regressions

The same integration suite also checks the following through the actual generic
MCP handler and production coordinator/source:

- A created resource may be present while the caller's complete postcondition is
  false. Its final failed RCIR record and receipt remain failed after observation,
  reconciliation and logical recovery.
- An exact built-in challenge observation cannot override a false caller
  postcondition. The post-success signing callback is not called, no proof or
  verification certificate is issued, a valid malicious child proof is refused,
  and later challenge readback cannot promote the immutable failure.
- Host-installed dependency selectors block dispatch when the producer is
  missing, failed or stale. The unrestricted source remains ready, establishing
  that a resource-state change cannot explain the zero-effect denial.
- A verified one-use prerequisite permits one actual dependent workload and
  prevents another consumer, including after reopening the durable journal.
- A revoked child's exact immutable ownership pins retain receipt access after
  teardown. Recovered `context_run_status` enforces event cursors, event counts
  and byte bounds, and returns retained runtime enrollment, signed child proof
  and host verification certificate in `ExecutionRecord.environmentEvidence`.
- A child with foreign ownership pins receives an unknown receipt with no
  result, event page or signed evidence even when the authentic receipt remains
  in the process-wide execution cache. A Link endpoint whose identity differs
  from the source's installed child identity is rejected at construction.

Dependency selectors are configured by the host and are included in admitted
request binding; caller arguments cannot supply their own trust keys, proof
envelopes or prerequisite policy. Signed dependency authority is issued only
after the entire original RCIR invocation succeeds, including caller predicates.

## Key custody and trust chain

The provider generates a different ephemeral Ed25519 key for each simulated
runtime. The enrollment claim, A-to-B lease, B execution proof, Link runtime ID,
Link result signature and subject lease pins use those exact keys. No child raw
private key is returned to the harness. A fake-only node-composition callback
provides an opaque `RCIRReceiptSigning` proxy whose signatures are checked
against the still-active provider resource; stop, destroy and TTL expiry disable
it. This models local custody and revocation without claiming process isolation.

The root fixture key is explicitly a deterministic test-only key. Local approval
is an injected test host implementation: A receives an exact reviewed request
ticket, while B's host admits only the test's specifically reviewed challenge and
returns a ticket bound to that exact request/declaration. The signed caller grant
does not supply confirmation.

## Running and limits

Run the focused test using the lead's isolated Swift build directory:

```sh
swift test --scratch-path <isolated-build-directory> --filter NestedExecutionAcceptanceTests
```

The lead records actual pass/fail evidence separately; this document does not
invent a successful run. The broader adversarial suites test forged/mutated/
expired/revoked leases and proofs, identity substitution, cumulative quotas,
partitions, interrupted teardown and provider deletion without absence.

Live cloud execution is a separate opt-in provider gate. A passing simulated
acceptance test does not establish cloud credentials, Linux portability tests,
live bootstrap, independently measured runtime identity, true process isolation
or a genuine disposable Linux-compute demonstration. Those claims require their
own execution evidence and remain unproven when not run.
