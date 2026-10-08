import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore

final class DelegatedVerificationLabelTests: XCTestCase {
    private final class Provider: CapabilityVerificationReflector {
        let id = "fixture:invalid-verification-label"
        var failure = false
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [.init(id: id, title: "Fixture effect", source: .system, reflectorID: id,
                safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            .init(executionId: executionID, actionId: id, state: .accepted, message: "Provider accepted")
        }
        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
            .init(executionId: executionID, actionId: id, state: failure ? .failed : .succeeded,
                message: "Provider verified a different predicate",
                evidence: .init(type: "provider_claim", boundary: "Different claim", outcomeVerified: true),
                verification: .init(status: failure ? .verifiedFailure : .verifiedSuccess,
                    predicates: [.init(predicate: .init(type: .textEquals, value: "different"),
                        evaluated: true, passed: !failure, actual: "different", message: "Different predicate")]))
        }
    }
    func testPendingDelegatedStatusPreservesItsOriginalLifecycle() throws {
        let provider = Provider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        let record = try engine.begin(id: provider.id, item: "effect", confirmed: false)
        for state: ExecutionState in [.started, .awaitingUser, .cancelled] {
            ExecutionStore.shared.put(.init(executionId: record.executionId, actionId: provider.id,
                state: state, message: "Pending or cancelled provider"))
            XCTAssertEqual(engine.executionStatus(record.executionId).state, state)
        }
    }
    func testInvalidSuccessLabelCannotRemainInAcceptedCoreRecord() throws { try check(failure: false) }
    func testInvalidFailureLabelCannotRemainInAcceptedCoreRecord() throws { try check(failure: true) }
    func testReconstructedEngineCannotRetainUnownedVerifiedFailure() {
        let executionID = UUID().uuidString
        ExecutionStore.shared.put(.init(executionId: executionID, actionId: "fixture:unowned-failure",
            state: .failed, message: "Unowned provider claims verified failure",
            evidence: .init(type: "provider_claim", boundary: "No original invocation context", outcomeVerified: true),
            verification: .init(status: .verifiedFailure,
                predicates: [.init(predicate: .init(type: .textEquals, value: "substituted"),
                    evaluated: true, passed: false, actual: "different", message: "Unowned expectation")])))
        let reconstructed = CapabilityEngine(reflectors: [], experience: nil)
        let record = reconstructed.executionStatus(executionID)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertNil(record.verification)
        XCTAssertFalse(record.evidence.outcomeVerified)
    }
    private func check(failure: Bool) throws {
        let provider = Provider(), engine = CapabilityEngine(reflectors: [provider], experience: nil)
        provider.failure = failure
        let record = try engine.begin(id: provider.id, item: "effect", confirmed: false,
            verification: .init(predicates: [.init(type: .textEquals, value: "desired")]))
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertNotEqual(record.verification?.status, .verifiedSuccess)
        XCTAssertNotEqual(record.verification?.status, .verifiedFailure)
    }
}
