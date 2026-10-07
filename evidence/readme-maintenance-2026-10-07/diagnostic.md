# Read-only native diagnostic

## Source evidence and demo paths

- evidence/moat-001-structured-openapi-2026-10-06/README.md
- evidence/moat-002-durable-readback-2026-10-06/README.md
- evidence/moat-003-generic-bearer-authority-2026-10-06/ARCHIVAL_ARTIFACT_POLICY.md
- evidence/moat-003-generic-bearer-authority-2026-10-06/README.md
- evidence/moat-005-real-mutation-2026-10-06/g1/README.md
- evidence/moat-005-real-mutation-2026-10-06/g2/README.md
- evidence/moat-005-real-mutation-2026-10-06/g3/README.md
- evidence/moat-005-real-mutation-2026-10-06/g4/README.md
- evidence/moat-005-real-mutation-2026-10-06/g5/README.md
- evidence/north-star/reliability/mcp-acceptance.txt
- evidence/openapi-discovery-execution-verification-live-removal-2026-10-06/README.md
- evidence/remote-openapi-capability-gain-execution-phone-outcome-2026-10-06/PHONE_PROOF.png
- evidence/remote-openapi-capability-gain-execution-phone-outcome-2026-10-06/README.md
- evidence/rightclick-000/REPORT.md
- evidence/rightclick-005/matrix.md
- evidence/rightclick-008/final-proof.txt
- evidence/self-hosting-2026-10-07/README.md
- evidence/v0.1-scalability-blind/README.md
- evidence/v0.1-scalability-blind/census/REPORT.md
- evidence/v0.1-scalability-blind/census/SUMMARY.md
- evidence/v0.1-scalability-blind/composition-png-jpeg-optim/REPORT.md
- evidence/v0.1-scalability-blind/compress-intent/REPORT.md
- evidence/v0.1-scalability-blind/cross-domain-csv-chart/CLAIM.md
- evidence/v0.1-scalability-blind/cross-domain-csv-chart/REPORT.md
- evidence/v0.1-scalability-blind/dynamic-substitution/CLAIM.md
- evidence/v0.1-scalability-blind/dynamic-substitution/REPORT.md
- evidence/v0.1-scalability-blind/external-blind/REPORT.md
- evidence/v0.1-scalability-blind/four-app-blind/REPORT.md
- evidence/v0.1-scalability-blind/png2jpeg-intent/REPORT.md
- evidence/v0.1-scalability-blind/privacy-intent/REPORT.md
- evidence/v0.1-scalability-blind/safety-aware-planning-transfer/REPORT.md
- docs/BBEDIT-PROOF.md
- docs/BOTTLE-ALIGNMENT.md
- docs/BUILD-PROGRAMME.md
- docs/BUILD_STATE.md
- docs/CAPABILITY-ABI-001.md
- docs/DECISIONS.md
- docs/DEMO.md
- docs/DEMO_SCRIPT.md
- docs/DISPATCH-CONTRACT-BINDING.md
- docs/EXPERIMENTS.md
- docs/FEDERATION.md
- docs/LAUNCH.md
- docs/PRODUCT_STATE.md
- docs/PROOF.md
- docs/RELEASE.md
- docs/RELEASE_NOTES_v0.1.0.md
- docs/RELEASE_NOTES_v0.2.1.md
- docs/RELEASE_NOTES_v0.2.2.md
- docs/RELIABILITY-CANDIDATE.md
- docs/SIGNING.md
- docs/V0.1_COMPLETION_REPORT.md
- docs/V0.1_COMPLETION_REPORT_APPLE_PATH.md
- docs/YOJAM-LIMITATION.md
- scripts/acceptance-chatgpt-mcp.py
- scripts/acceptance-core-boundary.py
- scripts/acceptance-experience.py
- scripts/acceptance-federation.py
- scripts/acceptance-mcp.py
- scripts/acceptance-setup-failures.py
- scripts/acceptance-setup.py

## Failed public CI steps

### Run 37594306485
```text
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.3547430Z 294 |             )
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.3680300Z 295 |             return .init(content: [.text(text)], isError: false)
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.3780530Z     |                                     `- warning: 'text(_:metadata:)' is deprecated: Use .text(text:annotations:_meta:) instead. [#DeprecatedDeclaration]
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.3881050Z 296 |         } catch {
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4086990Z 297 |             return .init(content: [.text(String(describing: error))], isError: true)
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4088020Z
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4191150Z /Users/runner/work/rightclick/rightclick/Sources/RightClickMCP/Server.swift:297:37: warning: 'text(_:metadata:)' is deprecated: Use .text(text:annotations:_meta:) instead. [#DeprecatedDeclaration]
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4324480Z 295 |             return .init(content: [.text(text)], isError: false)
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4428750Z 296 |         } catch {
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4531500Z 297 |             return .init(content: [.text(String(describing: error))], isError: true)
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4634280Z     |                                     `- warning: 'text(_:metadata:)' is deprecated: Use .text(text:annotations:_meta:) instead. [#DeprecatedDeclaration]
test	Run swift test --force-resolved-versions	2026-10-07T08:37:15.4737380Z 298 |         }
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.6474000Z Test Case '-[RightClickCoreTests.AcquisitionTests testImageServiceDoesNotApplyToPlainText]' passed (0.002 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.6477300Z Test Case '-[RightClickCoreTests.AcquisitionTests testMalformedPathIsAnError]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.6478200Z Test Case '-[RightClickCoreTests.AcquisitionTests testMalformedPathIsAnError]' passed (0.001 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.6479310Z Test Case '-[RightClickCoreTests.AcquisitionTests testProofURLPayloadRoundTrip]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.6479950Z Test Case '-[RightClickCoreTests.AcquisitionTests testProofURLPayloadRoundTrip]' passed (0.008 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.7727240Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testDisabledExperienceDoesNotAddHints]' passed (0.001 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.7728010Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testEmptyFailedOrUnevaluatedPredicatesNeverTeachVerifiedSuccess]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.7728890Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testEmptyFailedOrUnevaluatedPredicatesNeverTeachVerifiedSuccess]' passed (0.001 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.7729700Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testGatedAndMismatchedResultsAreNotRecorded]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:37:37.7730420Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testGatedAndMismatchedResultsAreNotRecorded]' passed (0.002 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6505320Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testRemovalSchemaDriftAndRevokedAuthorityRemainEnforced]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6537760Z /Users/runner/work/rightclick/rightclick/Tests/RightClickCoreTests/CapabilityExperienceTests.swift:168: error: -[RightClickCoreTests.CapabilityExperienceTests testRemovalSchemaDriftAndRevokedAuthorityRemainEnforced] : XCTAssertEqual failed: ("unavailable") is not equal to ("rejected")
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6540500Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testRemovalSchemaDriftAndRevokedAuthorityRemainEnforced]' failed (1.194 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6541750Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testRuntimeBeginLearnsVerifiedPredicatesButNextRunIsNotVerifiedByHistory]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6564540Z /Users/runner/work/rightclick/rightclick/Tests/RightClickCoreTests/CapabilityExperienceTests.swift:150: error: -[RightClickCoreTests.CapabilityExperienceTests testRuntimeBeginLearnsVerifiedPredicatesButNextRunIsNotVerifiedByHistory] : XCTAssertEqual failed: ("unavailable") is not equal to ("accepted")
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6566120Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testRuntimeBeginLearnsVerifiedPredicatesButNextRunIsNotVerifiedByHistory]' failed (0.008 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6567300Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testRuntimeRunLearnsAcceptanceWithoutSkippingConfirmation]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6568400Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testRuntimeRunLearnsAcceptanceWithoutSkippingConfirmation]' passed (0.002 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6572210Z Test Case '-[RightClickCoreTests.CapabilityExperienceTests testVerifiedBooleanAloneNeverTeachesVerifiedSuccess]' passed (0.000 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6572970Z Test Suite 'CapabilityExperienceTests' failed at 2026-10-07 08:37:38.950.
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6573520Z 	 Executed 13 tests, with 2 failures (0 unexpected) in 1.218 (1.221) seconds
test	Run swift test --force-resolved-versions	2026-10-07T08:38:12.6574070Z Test Suite 'CapabilityReflectorSourceTests' started at 2026-10-07 08:37:38.950.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:06.7261610Z Test Case '-[RightClickCoreTests.DispatchContractBindingTests testEquivalentRecreatedReflectorRemainsUsable]' passed (0.001 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:06.7262940Z Test Case '-[RightClickCoreTests.DispatchContractBindingTests testFailedRevalidationIsNotDispatched]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:06.7263850Z Test Case '-[RightClickCoreTests.DispatchContractBindingTests testFailedRevalidationIsNotDispatched]' passed (0.002 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:06.7264830Z Test Case '-[RightClickCoreTests.DispatchContractBindingTests testIdenticalDuplicateDoesNotBreakExistingProviders]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:06.7265930Z Test Case '-[RightClickCoreTests.DispatchContractBindingTests testIdenticalDuplicateDoesNotBreakExistingProviders]' passed (0.001 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:14.5724370Z Test Suite 'OutcomeVerifierTests' started at 2026-10-07 08:39:11.135.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:14.5725010Z Test Case '-[RightClickCoreTests.OutcomeVerifierTests testAnyFalseRequiredPredicateMakesWholeOutcomeFail]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:14.5725810Z Test Case '-[RightClickCoreTests.OutcomeVerifierTests testAnyFalseRequiredPredicateMakesWholeOutcomeFail]' passed (0.004 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:14.5726760Z Test Case '-[RightClickCoreTests.OutcomeVerifierTests testExactReturnedTextCanVerifySuccess]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:14.5727570Z Test Case '-[RightClickCoreTests.OutcomeVerifierTests testExactReturnedTextCanVerifySuccess]' passed (0.000 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6779920Z Test Case '-[RightClickCLITests.SetupTests testAbsentConfigurationIsCreated]' passed (0.001 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6780540Z Test Case '-[RightClickCLITests.SetupTests testEveryFailedStagePreventsSuccessfulExit]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6781270Z Test Case '-[RightClickCLITests.SetupTests testEveryFailedStagePreventsSuccessfulExit]' passed (0.000 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6782000Z Test Case '-[RightClickCLITests.SetupTests testExplicitChatGPTTunnelIDIsSelected]' started.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6789810Z Test Case '-[RightClickCLITests.SetupTests testExplicitChatGPTTunnelIDIsSelected]' passed (0.000 seconds).
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6942950Z 	 Executed 6 tests, with 0 failures (0 unexpected) in 29.985 (29.986) seconds
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6943470Z Test Suite 'rightclick-mcpPackageTests.xctest' failed at 2026-10-07 08:39:44.665.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6944120Z 	 Executed 485 tests, with 26 tests skipped and 2 failures (0 unexpected) in 131.421 (131.527) seconds
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6944590Z Test Suite 'All tests' failed at 2026-10-07 08:39:44.666.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.6945810Z 	 Executed 485 tests, with 26 tests skipped and 2 failures (0 unexpected) in 131.421 (131.529) seconds
:"\/var\/folders\/36\/tjdph2t965j8snz9_vkdnw0r0000gn\/T\/rightclick-chatgpt-onboarding-3237F48A-8AD0-4671-8439-7FB7EFDB31D3\/Library\/Application Support\/RIGHTCLICK\/setup-state.json","stateAligned":"true","stateExecutable":"\/var\/folders\/36\/tjdph2t965j8snz9_vkdnw0r0000gn\/T\/rightclick-chatgpt-onboarding-3237F48A-8AD0-4671-8439-7FB7EFDB31D3\/bin\/rightclick","stateExecutableSHA256":"306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb","status":"CONSENT_REQUIRED","tunnelClient":"\/var\/folders\/36\/tjdph2t965j8snz9_vkdnw0r0000gn\/T\/rightclick-chatgpt-onboarding-3237F48A-8AD0-4671-8439-7FB7EFDB31D3\/bin\/tunnel-client","tunnelClientVersion":"0.0.15","tunnelIDPresent":"true"}
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.8672900Z ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
test	Run swift test --force-resolved-versions	2026-10-07T08:39:44.8871450Z ##[error]Process completed with exit code 1.
```

### Run 37594375944
```text
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:41.7288570Z [#DeprecatedDeclaration]: <https://docs.swift.org/compiler/documentation/diagnostics/deprecated-declaration>
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2723510Z error: emit-module command failed with exit code 1 (use -v to see invocation)
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2724960Z [1298/1316] Emitting module RightClickCore
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2726450Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABI.swift:277:15: error: invalid redeclaration of 'CapabilityContract'
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2727340Z 275 | /// Immutable declaration snapshot. No field grants authority or verifies an
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2727950Z 276 | /// outcome. Provider identity here is a locator, not an authenticated principal.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2728440Z 277 | public struct CapabilityContract: Sendable {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2728850Z     |               `- error: invalid redeclaration of 'CapabilityContract'
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2729630Z 278 |     public static let version = 1
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2729900Z 279 |     public let capabilityID: String
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2730140Z
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2730660Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABIAdapter.swift:4:18: error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2731390Z  2 | import Foundation
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2731590Z  3 |
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2731780Z  4 | public extension CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2732630Z    |                  `- error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2733130Z  5 |     /// Content fingerprint only: not a signature, approval token or attestation.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2733570Z  6 |     func sha256() throws -> String {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2738350Z  4 | /// A content-addressed contract pin, not a grant, signature or approval.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2738900Z  5 | /// Passed through the existing actionId field; old runtimes fail unavailable.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2739390Z  6 | public enum CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2739740Z    |             `- note: found this candidate
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2740520Z
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2741050Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABIAdapter.swift:17:65: error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2741870Z 15 |     /// Nil schemas mean unknown and cannot authorise an invocation.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2742880Z 16 |     func abiContract(arguments: CapabilitySchema? = nil,
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2743300Z 17 |                      result: CapabilitySchema? = nil) throws -> CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2743900Z    |                                                                 `- error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2744640Z 18 |         guard reflectorID != "unowned" else { throw CapabilityABIError.invalidIdentity }
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2745060Z 19 |         let contract = CapabilityContract(
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2749380Z  4 | /// A content-addressed contract pin, not a grant, signature or approval.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2750060Z  5 | /// Passed through the existing actionId field; old runtimes fail unavailable.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2750420Z  6 | public enum CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2750690Z    |             `- note: found this candidate
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2754510Z [1299/1316] Compiling RightClickCore ARDRegistrySource.swift
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2757200Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABI.swift:277:15: error: invalid redeclaration of 'CapabilityContract'
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2760420Z 275 | /// Immutable declaration snapshot. No field grants authority or verifies an
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2761880Z 276 | /// outcome. Provider identity here is a locator, not an authenticated principal.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2762940Z 277 | public struct CapabilityContract: Sendable {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2763880Z     |               `- error: invalid redeclaration of 'CapabilityContract'
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2764660Z 278 |     public static let version = 1
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2782760Z 279 |     public let capabilityID: String
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2782980Z
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2783490Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABIAdapter.swift:4:18: error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2784110Z  2 | import Foundation
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2784260Z  3 |
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2784460Z  4 | public extension CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2784830Z    |                  `- error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2785650Z  5 |     /// Content fingerprint only: not a signature, approval token or attestation.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2785990Z  6 |     func sha256() throws -> String {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2790610Z  4 | /// A content-addressed contract pin, not a grant, signature or approval.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2791040Z  5 | /// Passed through the existing actionId field; old runtimes fail unavailable.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2791370Z  6 | public enum CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2791600Z    |             `- note: found this candidate
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2792200Z
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2792680Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABIAdapter.swift:17:65: error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2793340Z 15 |     /// Nil schemas mean unknown and cannot authorise an invocation.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2793670Z 16 |     func abiContract(arguments: CapabilitySchema? = nil,
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2794100Z 17 |                      result: CapabilitySchema? = nil) throws -> CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2794600Z    |                                                                 `- error: 'CapabilityContract' is ambiguous for type lookup in this context
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2795100Z 18 |         guard reflectorID != "unowned" else { throw CapabilityABIError.invalidIdentity }
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2795930Z 19 |         let contract = CapabilityContract(
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2800840Z  4 | /// A content-addressed contract pin, not a grant, signature or approval.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2801260Z  5 | /// Passed through the existing actionId field; old runtimes fail unavailable.
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2801730Z  6 | public enum CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2801950Z    |             `- note: found this candidate
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2802460Z
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2803130Z /Users/runner/work/rightclick/rightclick/Sources/RightClickCore/CapabilityABIAdapter.swift:19:13: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2804300Z 17 |                      result: CapabilitySchema? = nil) throws -> CapabilityContract {
macOS ARD runtime gates	G13 portable parser contract	2026-10-07T08:35:44.2804870Z 18 |         guard reflectorID != "unowned" else { throw CapabilityABIError.invalidIdentity }
```

## Installed-package read-only checks
```text
0.2.2
rightclick 0.2.2
```
