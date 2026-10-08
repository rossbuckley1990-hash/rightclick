# Nested execution adversarial matrix

Implementation baseline: `d496cf1b240bc97a52dbb5a5a76f378fd183b074`, on isolated
`feature/nested-execution-fabric`. Protected main remains outside this work.

The new `NestedAdversarialTests` contains 22 tests against the production
`EnvironmentCoordinator`, `EnvironmentJournal`, capability lease reservation
state, Ed25519 proof adjudicator and causal dependency validator. Its
`InMemoryEnvironmentProvider` supplies deterministic resource faults and holds
the simulated child signing keys. It is neither a VM nor evidence of a running
Linux child. The enrollment callback verifies the actual provider-held key and
issues a pinned host certificate; direct production Link enrollment validation
is additionally covered by `ChildRuntimeEnrollmentTests`.

Execution status at authoring: **pending the lead-owned focused test run**.
Names in this matrix identify executable tests, not inferred passing results.
The final run log and counts must be recorded after completion. No cloud
credentials, cloud resource, installed product, shared build, main change or
release action was used by the adversarial author.

| # | Required attack | Actual executable coverage | Required result and scope |
| --- | --- | --- | --- |
| 1 | Forged lease | `NestedAdversarialTests.testForgedLeaseCannotInstallOrCauseAnyProviderEffect` | A forged root signature cannot install authority or authenticate a caller; zero provider effects and no installed lease. |
| 2 | Modified signed evidence | `testModifiedSignedEvidenceAndReorderedSequenceDoNotConsumeValidProof`; `EnvironmentEvidenceTests.testEverySignedReportFieldMutationAndForgedSignatureFail` | Modified signed report rejected; it cannot consume the original valid proof or promote execution. The existing test mutates every signed report field. |
| 3 | Expired lease | `testExpiredAndRevokedLeasesRejectAlreadyAuthenticatedAdmission` | Already authenticated admission is rechecked after expiry; zero workload effects. |
| 4 | Revoked lease | `testExpiredAndRevokedLeasesRejectAlreadyAuthenticatedAdmission`; `testTeardownPartitionRevokesAuthorityAndDoesNotFalselyConfirmAbsence`; `CapabilityLeaseTests.testAncestorRevocationRejectsDescendantAndPriorReservationRetries` | Teardown revokes runtime and lease authority before uncertain deletion; old admissions and descendants cannot execute or retry consumed authority. |
| 5 | Replayed execution request | `testExecutionReplayAcrossBrokerRestartHasExactlyOneEffect`; existing `RemoteAdversarialTests.testSimultaneousFreshRequestsWithSameIntentHaveOneEffect` | Same execution and digest returns retained acceptance after reopening the protected journal; a changed challenge or digest rejects; one substrate effect. Existing Link test covers concurrent remote delivery. |
| 6 | Stale evidence | `testStaleProofCannotUsePreviouslyObservableChallenge`; `EnvironmentEvidenceTests.testStaleFutureExpiredAndOutOfWindowSignedEvidenceFail` | Expired proof rejects even while old state remains observable; verification is unknown, with no retained success certificate. |
| 7 | Valid provider response but false semantic postcondition | `testProviderAcceptanceAndSignedChildSuccessCannotHideFalsePostcondition` | Accepted provider response and valid signed child success are contradicted by separate observation; host certificate and execution become failed. |
| 8 | Malicious child claiming success | `testChildLieAndMissingExternalEffectNeverBecomeSemanticSuccess` | A signed child lie with no external effect remains unknown. Publishing a succeeded execution cannot bypass the broker's separate read. |
| 9 | Privilege amplification | `testChildrenCannotIncreaseDelegatedScopeExpiryCostResourcesOrDepth`; `testSignedScopeCostAndResourceCeilingsDenyBeforeDispatch` | Real A-held node key signs wider B capabilities; installation rejects. Signed invocation scope is also rechecked immediately before effect. |
| 10 | Excessive delegation depth | `testChildrenCannotIncreaseDelegatedScopeExpiryCostResourcesOrDepth`; `testExcessChildCountAndMaximumEnvironmentDepthRejectWithoutEffect` | Nonattenuated depth rejects; A/B/C reaches the host maximum, and a further child is denied without an effect. |
| 11 | Excessive child count | `testExcessChildCountAndMaximumEnvironmentDepthRejectWithoutEffect` | A's second direct child cannot reuse the first child's reserved count; no extra environment is created. |
| 12 | Extending lease expiry | `testChildrenCannotIncreaseDelegatedScopeExpiryCostResourcesOrDepth`; `CapabilityLeaseTests.testSignedChildWideningAndWrongParentAreRejected` | Typed A issuer cannot sign B expiry beyond either runtime's TTL. Existing production lease-state test authenticates a separately signed expiry-widening child and rejects attenuation. |
| 13 | Increasing cost/resource ceiling | `testChildrenCannotIncreaseDelegatedScopeExpiryCostResourcesOrDepth`; `testSignedScopeCostAndResourceCeilingsDenyBeforeDispatch` | Signed child cost/CPU/memory increases reject, and admitted create requests cannot exceed reserved spend or invocation ceilings. |
| 14 | Wrong runtime SHA | `testPartiallyEnrolledRuntimeAndWrongSHAHaveNoWorkloadAuthority`; `ChildRuntimeEnrollmentTests.testValidChildSignatureCannotOverrideExpectedRuntime` | Independent observed SHA mismatch prevents activation, with no workload authority. Production Link test covers a valid child signature over a wrong SHA/version/architecture. |
| 15 | Wrong environment identity | `testMalformedOrWrongEnvironmentEnrollmentCannotActivateRuntime`; `testChildCannotTargetAnotherEnvironmentOrBypassConfirmation`; `ChildRuntimeEnrollmentTests.testValidChildSignatureCannotOverrideEnvironmentOrParent` | A mutated correlation rejects enrollment; an admitted A subject cannot operate on another environment. Link additionally rejects correctly signed identity substitutions. |
| 16 | Parent-child identity mismatch | `testMalformedOrWrongEnvironmentEnrollmentCannotActivateRuntime`; `ChildRuntimeEnrollmentTests.testValidChildSignatureCannotOverrideEnvironmentOrParent` | Changed signed parent execution rejects, and production Link rejects valid child signatures over incorrect parent lineage/runtime. |
| 17 | Network partition during execution | `testExecutionPartitionPreservesUnknownAndRecoveryDoesNotRedispatch`; `testCreatePartitionDoesNotBecomeAbsentOrRetryAnUncertainEffect` | Dispatch/observation partition remains unknown; reopening the journal cannot redispatch an uncertain effect or interpret an unknown resource locator as absence. Deterministic partition, not live network outage. |
| 18 | Network partition during teardown | `testTeardownPartitionRevokesAuthorityAndDoesNotFalselyConfirmAbsence` | Authority is revoked immediately, presence remains unknown, and reconciliation after reopening completes exact absence and stops all simulated runtimes. |
| 19 | Provider says deleted but resource remains observable | `testAcceptedDeletionOfStillObservableResourceRemainsUnverified`; `testInterruptedRecursiveTeardownRecoversDeepestFirstAndRetainsLedger` | Accepted deletion plus present observation cannot become destroyed or succeeded; parent deletion waits for descendant absence. |
| 20 | Parent crashes after create before completion persistence | `testLostCreateAcceptanceAndRestartRetainOneCorrelatedResource`; `EnvironmentJournalTests.testReservationsSurviveReopenAndTwoWritersSeeSameHistory` | Simulated lost acceptance after real test-provider creation plus broker reopening retains one immutable correlation/resource and never recreates it. **Gap:** this does not kill an actual parent process at the exact post-create/pre-completion-write instruction; that process fault remains unexecuted. Production broker persists and fsyncs the creation reservation before calling the provider. |
| 21 | Duplicate create/retry/idempotency | `testLostCreateAcceptanceAndRestartRetainOneCorrelatedResource`; `testCreatePartitionDoesNotBecomeAbsentOrRetryAnUncertainEffect` | Same create retries reuse the original environment and resource; changed spec or originating execution conflicts. Uncertain create never causes a second provider call. |
| 22 | Duplicate destroy | `testAcceptedDeletionOfStillObservableResourceRemainsUnverified`; `testInterruptedRecursiveTeardownRecoversDeepestFirstAndRetainsLedger` | Destroy/reconcile of already absent terminal resources produces no additional provider effects. |
| 23 | Reordered evidence | `testModifiedSignedEvidenceAndReorderedSequenceDoNotConsumeValidProof` | Correctly signed out-of-order sequence rejects before consumption; original sequence succeeds once, and replay rejects across reopening. |
| 24 | Evidence reused across environments | `testCrossEnvironmentExecutionEvidenceAndDependencyReplayRejectAcrossRestart`; `EnvironmentEvidenceTests.testValidSignatureWithEveryWrongBindingIsRejectedBeforeObservation` | A proof/dependency cannot select another environment; host retained evidence for that target stays empty. Existing adjudicator test uses valid signatures over each wrong binding. |
| 25 | Evidence reused across executions | `testCrossEnvironmentExecutionEvidenceAndDependencyReplayRejectAcrossRestart`; `EnvironmentEvidenceTests.testValidSignatureWithEveryWrongBindingIsRejectedBeforeObservation` | Changed execution selector rejects, modified proof cannot authenticate for the target, and one-use dependency cannot be reassigned to another consuming execution/request after reopening. |
| 26 | Interrupted recursive teardown | `testInterruptedRecursiveTeardownRecoversDeepestFirstAndRetainsLedger` | An observable deepest child blocks deletion of B/A. Broker reopening resumes C, then B, then A; all absence observations and creation records remain queryable. |
| 27 | Partially enrolled child runtime | `testPartiallyEnrolledRuntimeAndWrongSHAHaveNoWorkloadAuthority` | Provider-created/bootstrap-accepted runtime alone has no broker authority, no grant installation and no executable workload. Single-use enrollment also rejects reuse. |
| 28 | Malicious/malformed Link request | Existing `RemoteAdversarialTests.testEveryAuthoritativeRequestFieldIsCoveredByAuthentication`, `testSignedUnknownConsentFieldAndNestedOversizedPayloadCannotApprove`; `ChildRuntimeEnrollmentTests.testStrictWireRejectsMalformedUnknownDuplicateOrOversizedFields` | Real Link decoder/authentication rejects authoritative field changes, unknown consent, duplicate/oversized and malformed envelopes. New broker test `testMalformedOrWrongEnvironmentEnrollmentCannotActivateRuntime` rejects oversized/malformed enrollment responses. Remote environment routing requires the lead's integration guard/E2E tests as an additional gate. |
| 29 | Child bypasses confirmation | `testChildCannotTargetAnotherEnvironmentOrBypassConfirmation`; existing `RemoteAdversarialTests.testRealOpenAPIRequiresLocalApprovalAndHostDenialNeverInvokesProvider`, `testSignedUnknownConsentFieldAndNestedOversizedPayloadCannotApprove` | Broker refuses create/execute/destroy without host confirmation; a caller's signed consent field cannot create Link local approval. Public generic environment integration must preserve this existing host boundary. |
| 30 | Child bypasses semantic verification | `testProviderAcceptanceAndSignedChildSuccessCannotHideFalsePostcondition`; `testChildLieAndMissingExternalEffectNeverBecomeSemanticSuccess`; existing `RemoteAdversarialTests.testRealOpenAPIAcceptanceWithoutObserverStaysUnverified` | Provider acceptance, signed child report and a succeeded publication cannot substitute for independent target observation. Missing observation remains unknown; contradictory observation becomes failed. |

## Additional review limits

The deterministic suite verifies actual persisted recovery, key binding,
allocation/admission and observable lifecycle effects. It cannot establish real
provider TTL enforcement, VM executable measurement, process-level key custody,
cross-machine Link deployment or Linux x86_64/arm64 execution. Those require the
separate platform and opt-in live gates. A lost-response fault is deliberately
distinguished from a parent process crash. Runtime enrollment is software
identity verification, with no hardware attestation claim.

Additional tests cover persistent clock rollback denial
(`testClockRollbackDeniesAdmissionAndDiscoveryAcrossRestart`) and withdrawal of
discovery when a child budget is consumed or teardown revokes the runtime
(`testDiscoveryWithdrawsConsumedChildBudgetAndRevokedWorkloadAuthority`).

The partition replay test intentionally requires zero redispatch. Once separate
observation has placed an environment in `unknown`, its current production
broker denies a repeated workload admission before reaching the retained
workload result. This is safe denial; it does not demonstrate availability or
successful transparent resume under that state.

Every critical/high finding must go to the lead and source owner; assertions
must not be weakened to hide it. At authoring no passing-run or independent
security-review completion is claimed.
