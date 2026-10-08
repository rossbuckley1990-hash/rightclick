# Bilateral execution fabric: independent adversarial review

Review date: 2026-10-08. Reviewer: Agent C, independent of the Protocol/Providers and Link implementers. Base: PR #99, `6a18aaae3ae3a15b9f6c78f189adc695ae11585a`. The root coordinator owns integration and commits. This report covers portable deferred execution, authenticated remote lifecycle polling, durable replay protection, and the bounded encrypted outbound transport. It does not claim a cross-machine deployment or a formal cryptographic audit.

Final reviewed production revision: `2cc25d7`. The independent controls and actual-process acceptance proof are green. No unresolved CRITICAL or HIGH finding has been identified in the reviewed implementation. This is a scoped adversarial review, not a proof that no vulnerability exists; the coordinator's final platform/suite matrix remains the acceptance authority.

## Evidence observed independently

Agent C ran the following on macOS arm64:

| Check | Result | Evidence |
| --- | --- | --- |
| Portable host/store and Link lifecycle adversarial tests | 32 tests, 0 failures: 14 `RCIRLifecycleAdversarialTests`, 18 `RemoteLifecycleAdversarialTests` | `work/agent-c-final-controls2.log` in the coordinator workspace |
| Final observer-fixture regression | 1 test, 0 failures after explicit Python/valid-port readiness fixes; unchanged 3-second budget and lifecycle assertions | `work/agent-c-fixture-controls.log` |
| Final encrypted exchange/cursor regressions | 2 tests, 0 failures, independently rerun after the final Link fix | `work/agent-c-last-fixes.log` |
| Earlier replay, enrollment and existing adversarial controls | 82 tests, 0 failures: 12 portable lifecycle, 17 Link lifecycle, 23 `RemoteAdversarialTests`, 28 `RemoteReplayLedgerTests`, 2 `RemoteRegistryTests` | `work/agent-c-controls-escalated.log` |
| Actual local MCP/HTTP deferred provider | Live, working, then immutable terminal; typed integer 7; one effect; exactly seven tools | `work/agent-c-fabric-proof5/local-proof.json` and `local-mcp-wire.json` |
| Actual caller and target RIGHTCLICK processes through outbound encrypted broker | Remote discovery/routing, nonterminal and working status, typed terminal result, pinned target identity, one effect | `work/agent-c-fabric-proof5/distributed-proof.json`, MCP transcripts and `processes.json` |
| Separate actual-process retry epoch | Exact request replay rejected; fresh same-intent live and terminal retries retained one execution and idempotency identity; one effect | `work/agent-c-fabric-proof5/retry-proof.json` |
| Independent target receipt check | Ed25519 signature valid under the provisioned target pin; changed signature rejected; receipt retained on the execution node | `receiptVerification` in all three proof JSON files |
| Broker malformed/forged clients | Zero and oversized frames, unknown field, forged route completion, duplicate active host registration rejected; legitimate execution remained observable | `work/agent-c-fabric-proof5/broker-negative-proof.json` |

The actual-process proof recorded source head `646ad462caa9722023f22530483cb5edeb2fa14f` together with its dirty fixture/provenance state and binary SHA-256. It covers the final production code, including the cursor and late-return fixes; subsequent changes concern acceptance fixtures and reporting. The harness records source/head status, binary SHA-256, public node pins, process IDs, arguments, and wire replies. It creates disposable protected keys and journals, puts the fixture credential only in the execution process, and verifies that the credential sentinel is absent from caller-facing replies. It independently verifies receipt signatures with OpenSSL against the provisioned pin, rather than trusting the embedded receipt key.

The first un-escalated existing OpenAPI socket fixture run failed because the execution sandbox denied its loopback listener. The same controls passed with the authorized loopback test execution. An early actual-process attempt failed journal provisioning because macOS Foundation and Python canonicalized system temporary-path aliases differently; effects were zero. The harness now uses a protected workspace temporary directory without weakening journal validation. These were environment/setup failures, not successful acceptance proofs. Final CI also exposed Git's differing-owner checkout denial during read-only provenance collection and macOS fixture readiness failures. Provenance now uses only two exact-path, per-command `safe.directory` overrides; it does not write Git configuration or grant wildcard/global trust. A default differing-owner probe remained denied while these exact-path calls succeeded. Linux private keys/journals move to canonical system temporary storage when checkout ancestry belongs to another UID, preserving the production ledger's owner/ancestor checks. The observer fixture publishes its complete port atomically; C uses the installed `/usr/bin/python3`, waits for a valid numeric port within the same 3-second budget, and captures stage/child stderr diagnostics. The focused observer test and all three real-process proofs passed after these fixture-only changes. The final native CI rerun remains the coordinator's authority.

## Findings challenged and resolved

| Finding | Severity and exploitability | Resolution and regression |
| --- | --- | --- |
| Deferred completion skipped admission-bound observer/postcondition policy | HIGH correctness/assurance: a deferred operation could lose required semantic adjudication and receipt outcome despite its bound policy. The independently written typed result test initially failed 12 assertions. | Captured policy is installed before provider start. Provider completion is staged while the last nonterminal snapshot remains visible; host adjudication runs outside admission and live-task locks. `testDeferredCompletionCannotSilentlyIgnoreAdmissionBoundTypedPostcondition` now passes matching and mismatching typed results. A real independent observer is covered by `testActualDeferredHTTPCompletionUsesAdmissionBoundIndependentObserver`. |
| Receipt signing failure could orphan a completed live task | MEDIUM: after a possible effect, signing failure could prevent retained terminal evidence and leave misleading live ownership. | Admission-time signer stays captured; signing failure publishes immutable UNKNOWN with retained unsigned receipt/history. `testTerminalSigningFailureCannotLeaveAnOrphanedLiveTask` passes. |
| Manual public live registration could fabricate consumed-authority evidence | MEDIUM API integrity: an in-process caller could submit an arbitrary task to public registration without the host's admission/consumption path. This was not a remote MCP authority bypass. | Registration is internal to Providers; tests use `@testable` access. Public `execute` registers only after successful consumption and before any provider callback. |
| Signed lifecycle inconsistencies and identity substitution | MEDIUM protocol integrity: signatures authenticate bytes but do not make contradictory bytes coherent. Working snapshots with completed events, wrong origin, stale task/generation, changed repeated event values, and terminal/result substitution must be rejected. | Explicit portable lifecycle/page validation, original-run bindings, per-execution observations, and immutable terminal checks. The independent Link adversarial suite is green. |
| Status/run envelope identity reuse | MEDIUM replay integrity: a caller could reuse observed request IDs/nonces across operations during their valid lifetime. | Polling checks the durable executable ledger and a bounded observation cache; executable requests also consult that cache. `testRunAndPollCannotReuseEachOthersEnvelopeIdentities` and nonce/request replay tests pass. Consequential entries are never evicted. |
| Decoded bad encrypted packets could close the whole target host connection | MEDIUM availability: an ordinary caller could interrupt unrelated routes with a forged packet or handshake quota overflow. No second effect or authorization bypass was found. | Hello/exchange failures return route-scoped opaque errors; malformed framing can close the offending connection. B added `testForgedEncryptedPacketsAndHandshakeQuotaDoNotDisconnectHostOrExecute`; it passes both B's frozen 11-test suite and C's independent 2-test final regression run. An exhausted quota returns a bounded error until expiry without closing the shared host connection. |
| Invalid remote cursor could be treated as execution/route failure | MEDIUM availability/correctness: a caller's pagination error must not make a healthy live execution UNKNOWN or invalidate the enrolled route. | The target signs a poll-bound invalid-cursor response; the client verifies the node signature and exact request/caller/runtime/device/idempotency binding before raising the pagination error. `testSignedInvalidRemoteCursorDoesNotChangeLiveRouteOrDispatchAgain` went red with 4 assertions, then passed in B's frozen 11-test suite and C's independent final regression run. The route stays online and the same execution later completes with one effect. |
| Late initial provider return could conflict with a synchronous pending completion | MEDIUM lifecycle integrity: a synchronous callback can stage typed completion before the provider's initial record returns. A later acceptance/success must not duplicate or destroy that completion. | Pending completion takes precedence over late started/input-required/acceptance/success returns. The exception was narrowed during independent review: contradictory negative returns, explicit UNKNOWN, post-dispatch thrown errors, and revalidation/contract loss produce UNKNOWN. `testPendingSynchronousCompletionSurvivesLateAcceptanceButContradictoryNegativeReturnBecomesUnknown` passed in A's final 30-test controls. C inspected the narrowed exception and the UNKNOWN precedence path. |

The gated observer regression independently proves that a blocked observer does not hold a host-wide callback/status lock; detected loss publishes UNKNOWN with the completed typed event retained, and a late successful readback cannot reopen or replace that immutable record. It compares the complete retained record before and after late observer completion.

## Required negative-case coverage

The table identifies concrete assertions, not a claim that every listed suite was run by Agent C in its latest 32-test selection. The coordinator's final validation matrix records the broader suite results.

| Required attack/failure | Tests or actual evidence |
| --- | --- |
| Duplicate delivery and replay | `RemoteDispatchTests.testCompletedRequestReplayAndNonceReuseAreRejected`; `RemoteAdversarialTests.testSimultaneousFreshRequestsWithSameIntentHaveOneEffect`; actual-process retry proof rejects exact replay with effect count 1. |
| Nonce reuse and request-ID reuse | `RemoteLifecycleAdversarialTests.testRepeatedPollRequestAndNonceCannotBeReused` and `testRunAndPollCannotReuseEachOthersEnvelopeIdentities`; `RemoteReplayLedgerTests.testCompletedRequestAndNonceReplayRemainRejectedAfterRestart`. |
| Idempotency collision | `RemoteDispatchTests.testChangedIntentWithSameIdempotencyKeyIsRejected`; `RemoteReplayLedgerTests.testChangedIntentWithSameIdempotencyKeyRemainsRejectedAfterRestart` and `testIndependentInstancesSimultaneousSameIdempotencyHaveExactlyOneWinner`. |
| Wrong runtime, device, caller | `RemoteLifecycleAdversarialTests.testAdmittedStatusRejectsEveryOriginalExecutionBindingSubstitution` and `testAnotherAuthorizedCallerCannotObserveOriginalCallersLiveExecution`; `RemoteDispatchTests.testInvalidAuthenticationTamperingAndWrongTargetDoNotExecute`. |
| Capability-contract substitution | `testAdmittedStatusRejectsEveryOriginalExecutionBindingSubstitution`; `RemoteDispatchTests.testContractChangeInsideEngineAdmissionPreventsInvocation` and `testCanonicallyEquivalentUnicodeContractSubstitutionCannotDispatch`. Wire capability identifiers are constrained to printable ASCII; contract digests bind canonical bytes. |
| Stale generation | `RemoteLifecycleAdversarialTests.testStatusCannotSubstituteGenerationTaskOrShapeAfterInitialObservation`. |
| Forged lifecycle/result | `RemoteAdversarialTests.testRelayCannotForgeAcceptanceWithAnotherSigningKey`, `testRelayCannotChangeAuthenticatedResultOrSubstituteAnotherRequestResult`; independent pinned receipt verification and changed-signature rejection. |
| Sequence replay and gap | `RCIRLifecycleAdversarialTests.testRetainedHistoryRejectsSequenceReplayGapAndZero`; `RemoteLifecycleAdversarialTests.testPageCannotReplaySequenceSkipSequenceOrLieAboutCursor`, `testAuthenticatedRepeatedEventCannotSubstituteTypedValue`. |
| Stale and invalid cursor | Old valid cursors reread exact retained history: `testOldCursorRereadRetainsExactEventsAndTerminalityWithBacklog`. Negative/ahead/extreme cursors fail: `testNegativeAheadAndOverflowCursorsFailClosed`, `testStatusCursorAndByteBoundsRejectIntegerExtremes`; MCP wire `FederationTests.testContextRunStatusRejectsInvalidPaginationOverRealMCP`; B's healthy-route invalid-cursor regression. |
| Event overflow | `testHistoryOverflowIsRejectedBeforeAnyPublication` and `testHostOverflowBecomesUnknownAndPreservesAcceptedHistoryWithoutReopening`. |
| Byte-budget overflow | `testHistoryByteOverflowIsRejectedBeforeAnyPublication`, `testInsufficientPageBytesDoesNotDropOrRenumberFirstEvent`; `RemoteLifecycleAdversarialTests.testOversizedTypedEventCannotExceedRequestedPageBudget`; `RemoteLifecycleTests.testOversizedAndEscapedExportValuesCannotMakeLifecycleUnobservable`. |
| Completion before initial response | `RemoteLifecycleTests.testFastCompletionBeforeInitialResponseHasTerminalResultAndHistory`, `testRemoteFastCompletionRetainedBeforeDelayedCallerInitialRecord`. |
| Synchronous callback during start | `RCIRDeferredExecutionTests.testDeferredTaskExistsBeforeProviderCanCallback`, `testSynchronousCompletionWithTypedPostconditionFinalizesWithoutBlockingAdmissionStart`. |
| Terminal callback before local record storage | `RCIRDeferredExecutionTests.testSynchronousCompletionBeforeInitialExecutionRecordStorageRetainsReceiptAndTypedResult`; `RCIRLifecycleAdversarialTests.testTerminalBeforeInitialRecordCannotBeReopenedOrLoseTypedResult`. |
| Provider disappearance | `RemoteAdversarialTests.testRealOpenAPIProviderDisappearanceAfterDispatchRemainsUnknownWithoutRetry`; `testPendingIndependentObserverDoesNotBlockCallbacksAndLateSuccessCannotReopenUnknown`; host deadline UNKNOWN regression. |
| Link disconnect before terminal and after possible effect | `RemoteLifecycleAdversarialTests.testDisconnectThenReconnectAndFreshSameIntentRetryHasExactlyOneEffect`; `RemoteAdversarialTests.testOfflineAfterDeliveryAndAmbiguousRetryCannotMoveOrRepeatExecution`; `RemoteLifecycleTests.testLiveSameIntentRetryAndLostResponseCannotRedispatch`. |
| Reconnect without duplicate execution | `RemoteLifecycleTests.testRealEncryptedOutboundTransportLifecycleReconnectAndExactlyOneEffect`; actual-process retry proof independently reads effect count 1. |
| Contradictory acceptance/verification | `RemoteLifecycleAdversarialTests.testLiveSnapshotCannotAdvertiseReceiptResultOrVerifiedSuccess`, `testObservationAvailabilityAndSemanticFailureCannotBeContradictory`; `RemoteDispatchTests.testAcceptanceMissingObservationMismatchAndContradictionStayDistinct`. |
| Confirmation bypass | `RemoteDispatchTests.testConfirmationDefaultPreservedAndOnlyExactHostTicketCanApprove`; `RemoteAdversarialTests.testSignedUnknownConsentFieldAndNestedOversizedPayloadCannotApprove`; `testProviderInputRequiredIsLiveAndCannotBecomeConfirmationBypass`. Provider input-required is distinct from policy confirmation. |
| Authority broadening | `RemoteLifecycleAdversarialTests.testStatusGrantIsNotImplicitlyBroadenedFromRunGrant`; `RemoteProtocolTests.testWindowsRequirementsDoNotGrantLocalAuthority`; `RCIRInvocationIsolationTests.testInvocationDoesNotTurnUnknownEffectsIntoAuthority`; exact-origin and revocation production dispatch controls. |
| Signing-key rotation while live | `RCIRDeferredExecutionTests.testDeferredCompletionPublishesFinalEvidenceUsingAdmissionTimeSigner` replaces the signing-key file during live work and asserts the original signer identity on the retained completion. |
| Terminal task reopening | `testSecondTerminalPublicationCannotSubstituteResultOrHistory`, `testTerminalBeforeInitialRecordCannotBeReopenedOrLoseTypedResult`, `testHostDeadlineMakesUnknownReceiptAndCannotAcceptLateCompletion`; gated observer complete-record immutability check. |
| Stale enrolled runtime resurrection | `RemoteRegistryTests.testRemovalCancelsInFlightEnrollmentWithoutResurrectingRoutes`; captured execution owner remains independent from discovery snapshot expiry. |
| Seven-operation regression | `FederationTests.testModelFacingToolSurfaceRemainsSevenGenericOperations`; both local and caller actual MCP `tools/list` assert exact count and exact seven-name set. |

## Boundary review and residual limitations

Protocol owns typed lifecycle/task/event models; Providers owns admission, active work and host observation; Core coordinates owner-bound status; Link owns signed node-to-node requests, safe lifecycle projection, enrollment and durable replay. MCP remains an authenticated loopback ingress. The encrypted broker never receives provider credentials, and the transport is separate from the seven model-facing operations. New portable code does not require AppKit, Keychain, Apple Network or Apple Silicon; POSIX journal code retains its Darwin/Glibc adapter branches.

The encrypted transport authenticates the pinned target's signed ephemeral X25519 certificate with a fresh caller challenge and expiry, derives distinct request/response keys with HKDF, and authenticates certificate-bound ChaChaPoly frames. Inner requests/results retain their Ed25519 identity and authorization bindings. Session consumption precedes decryption/dispatch, framing and resource quotas are bounded, and transport errors trigger no consequential retry. This is a small opt-in outbound broker implementation, not a public relay service.

The broker can deny availability, observe routing identities and timing, drop or delay messages, or exhaust bounded handshake capacity until expiry. These powers do not authorize an operation or change authenticated evidence. Public relay operation, rate limiting, and a broader transport interoperability audit remain future work. The proof uses two genuine isolated RIGHTCLICK processes on one host; it is not evidence of two physical machines, a Linux deployment, or Windows runtime support. The coordinator must report Linux and macOS matrix results separately.

Polling is implemented; push subscriptions are not required and no eighth MCP operation is added. The observation replay window is now durable, bounded and expiry-scoped; durable executable reservations are never automatically evicted, and unresolved restart reservations remain UNKNOWN. Capacity exhaustion denies further work rather than resetting history. There is no automatic uncertain-effect cross-node failover.

Provider completion and a valid signature remain independent from semantic success. The unobserved fixture in the actual-process proof explicitly reports UNVERIFIED. A returned typed value postcondition is marked as a returned-value observation boundary; it is not external-state proof. An external observer must be bound during admission, and credentials/cookies from invocation are not borrowed for that observation.

Local provider disappearance is detected on host withdrawal/synchronization, explicit execution-owner loss, or the task deadline. Every status call does not rediscover the dynamic capability catalog. Catalog TTL expiry alone is not proof that an admitted live execution ceased; remote status remains bound to the original execution owner. A future dedicated owner-liveness signal should preserve this separation.

Terminal RCIR history is bounded, retained in immutable process-owned storage, and remote safe terminal summaries/events also remain in the durable Link journal. Full raw local RCIR receipts are not promised to survive a host process restart; the durable remote reservation safely reports UNKNOWN when live ownership is lost. Raw receipts/observation payloads are kept on the execution node. Only values explicitly allowed by the host export policy are exposed remotely, with bounded redaction for unsafe/oversized values.

## Follow-up stacked review on 2026-10-08

The follow-up review began with PR #99 at `6a18aaae` and PR #101 at `9fbb3e0`.
Its new controls found and corrected additional issues; the preceding native CI
counts describe the earlier head and must not be attributed to these fixes.

| Finding | Severity and evidence | Correction |
|---|---|---|
| Unary before-reference verification captured the baseline after dispatch | HIGH false assurance: changed file bytes could compare with themselves and yield a signed success. Four negative/positive cases produced 20 failed assertions before the fix. | Capture the admitted pre-effect snapshot before provider start, reuse it in both unary postcondition branches and deferred ownership, and retain explicit external/returned observation boundaries. Regression tests independently validate the signed receipt against the provisioned pin and semantic outcome. |
| Local bounded status mixed lifecycle and event snapshots | MEDIUM correctness: old ordering produced 374 torn replies in 6,869 reads; a newer page could accompany an older lifecycle. | Atomic host/store snapshot capture; corrected stress run produced zero torn replies in 232,468 reads. Retained terminal evidence takes precedence without a visibility gap. |
| Re-enrollment after a disconnect invalidated existing routed owners | MEDIUM availability: routed MCP recovery failed while direct client reconnect tests passed. | Authenticated same-client re-enrollment preserves peer generation; explicit removal still invalidates old owners. Both recovery and removal controls pass with one provider effect. |
| Harmless discovery consumed permanent execution capacity | MEDIUM availability: three observations exhausted a configured two-request consequential journal before any effect. | Durable v2 observation window for runtime/actions/status; permanent run identities and intents remain unchanged. Restart, full-window, expiry, rollback, cross-operation replay and validated v1 migration controls pass. Historical permanent v1 observations are never reclassified or removed. |
| Generic ordinary verification omitted its observation boundary | MEDIUM evidence clarity: returned-value and file predicates both emitted a missing boundary. | Classify actually evaluated predicates and expose returnedValue or externalState on success/failure. Provider acceptance alone remains unverified. |
| Background preparation initialized AppKit's event queue incorrectly | MEDIUM native availability: an existing async portable fixture followed by a native Service crashed with SIGTRAP. | Main-queue preparation entirely inside RightClickMacOSHost. A fresh isolated process and the original combined test ordering pass; embedding hosts must keep the native main queue running. |

No remaining CRITICAL/HIGH finding was identified in the scoped independent
review of these corrections. Strict shared-wall-clock freshness can reject
authentic sessions under skew; the checks remain intact, and clock offset is an
explicit deployment preflight requirement. Relay squatting and resource
exhaustion remain availability risks rather than identity or authority bypasses.

The generic local RCIR receipt signs a host-observed predicate outcome. It does
not contain enough material to reconstruct the exact VerificationSpec and
pre-effect snapshot from that opaque receipt alone. The host captures those
inputs; a signed Link request additionally binds its supported caller
postcondition. Consumers must not present a standalone generic receipt as a
reconstructable proof of an arbitrary policy. A policy-digest receipt extension
is separate future contract work.

The owner confirmed that no genuinely independent Linux target exists yet.
Live Rosss-MacBook-Air -> independent Ubuntu 24.04 x86_64 acceptance is paused at
that environmental prerequisite. Additional local processes, VMs, containers,
simulated transports or a tunnel back to this Mac do not complete the criterion.

No release, main merge, Homebrew update, credential migration, public MCP listener, or Actenon edit forms part of this review.
