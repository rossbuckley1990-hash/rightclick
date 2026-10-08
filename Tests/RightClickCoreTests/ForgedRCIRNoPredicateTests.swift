import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore

/// A public provider record cannot manufacture host admission with RCIR fields.
final class ForgedRCIRNoPredicateTests: XCTestCase {
    private final class Provider: CapabilityReflector {
        let id = "untrusted.receipt-field"
        var initialState: ExecutionState = .succeeded
        var callbackDuringRun = false
        var completionWaitSeconds: TimeInterval { callbackDuringRun ? 1 : 0 }
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [.init(id: "fixture:ordinary-rcir", title: "Fixture effect", source: .system,
                reflectorID: id, safety: .read, invocation: .direct,
                supportLevel: .experimental, requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            if initialState == .started {
                if callbackDuringRun {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { [self] in
                        ExecutionStore.shared.put(forged(executionID, capability.id))
                    }
                }
                return .init(executionId: executionID, actionId: capability.id, state: .started, message: "Pending provider")
            }
            return forged(executionID, capability.id)
        }
        func forged(_ executionID: String, _ actionID: String) -> ExecutionRecord {
            .init(executionId: executionID, actionId: actionID, state: .succeeded,
                message: "Provider forged host admission evidence",
                evidence: .init(type: "rcir_http_readback", boundary: "Provider asserted observation",
                    outcomeVerified: true, observationBoundary: .externalState),
                rcir: .init(version: 1, taskID: UUID().uuidString, leaseID: UUID().uuidString,
                    generation: 1, leaseConsumed: true, phase: "completed", outcome: "succeeded",
                    receipt: nil, signedReceipt: nil, observationBoundary: "Provider assertion"))
        }
    }
    func testOrdinaryProviderCannotForgeHostVerifiedBeginWithoutCallerPredicate() throws {
        let provider = Provider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        let record = try engine.begin(id: "fixture:ordinary-rcir", item: "effect", confirmed: false)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertFalse(record.locallyAdmittedRCIR)
    }
    func testOrdinaryProviderCannotForgeHostVerifiedRunWithoutCallerPredicate() throws {
        let provider = Provider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        let result = try engine.run(id: "fixture:ordinary-rcir", item: "effect", confirmed: false)
        XCTAssertEqual(result.status, .accepted)
        XCTAssertFalse(result.evidence.outcomeVerified)
    }
    func testOrdinaryAsyncCallbackCannotForgeHostVerifiedStatusWithoutCallerPredicate() throws {
        let provider = Provider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        provider.initialState = .started
        let initial = try engine.begin(id: "fixture:ordinary-rcir", item: "effect", confirmed: false)
        XCTAssertEqual(initial.state, .started)
        ExecutionStore.shared.put(provider.forged(initial.executionId, initial.actionId))
        let status = engine.executionStatus(initial.executionId)
        XCTAssertEqual(status.state, .accepted)
        XCTAssertFalse(status.evidence.outcomeVerified)
        XCTAssertFalse(status.locallyAdmittedRCIR)
    }
    func testOrdinaryAsyncCompletionWaitCannotForgeHostVerifiedRunWithoutCallerPredicate() throws {
        guard Thread.isMainThread else { throw XCTSkip("Completion-wait main run-loop fixture requires main thread") }
        let provider = Provider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        provider.initialState = .started
        provider.callbackDuringRun = true
        let result = try engine.run(id: "fixture:ordinary-rcir", item: "effect", confirmed: false)
        XCTAssertEqual(result.status, .accepted)
        XCTAssertFalse(result.evidence.outcomeVerified)
    }
    func testCopyingProvenanceCannotSubstituteInvocationOrExactActionIdentity() throws {
        let provider = Provider()
        var original = provider.forged(UUID().uuidString, "action:\u{00e9}")
        original.locallyAdmittedRCIR = true; original.authenticatedNodeVerification = true
        XCTAssertTrue(original.locallyAdmittedRCIR); XCTAssertTrue(original.authenticatedNodeVerification)
        var substituted = original; substituted.executionId = UUID().uuidString
        XCTAssertFalse(substituted.locallyAdmittedRCIR); XCTAssertFalse(substituted.authenticatedNodeVerification)
        substituted = original; substituted.actionId = "action:e\u{0301}"
        XCTAssertEqual(substituted.actionId, original.actionId)
        XCTAssertFalse(substituted.locallyAdmittedRCIR); XCTAssertFalse(substituted.authenticatedNodeVerification)
    }
    func testLocalAdmissionProvenanceCannotBeImportedThroughCodable() throws {
        let provider = Provider()
        var admitted = provider.forged(UUID().uuidString, "fixture:ordinary-rcir")
        admitted.locallyAdmittedRCIR = true
        admitted.authenticatedNodeVerification = true
        let bytes = try JSONEncoder().encode(admitted)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("locallyAdmittedRCIR"))
        let imported = try JSONDecoder().decode(ExecutionRecord.self, from: bytes)
        XCTAssertFalse(imported.locallyAdmittedRCIR)
        XCTAssertFalse(imported.authenticatedNodeVerification)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["locallyAdmittedRCIR"] = true; object["authenticatedNodeVerification"] = true
        let importedForgery = try JSONDecoder().decode(ExecutionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(importedForgery.locallyAdmittedRCIR)
        XCTAssertFalse(importedForgery.authenticatedNodeVerification)
    }
}
