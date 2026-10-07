import Foundation
import XCTest
@testable import RightClickCore

final class ContractBoundCapabilityEngineTests: XCTestCase {
    private class Reflector: CapabilityReflector {
        let id = "binding.test.reflector"
        var capability = Capability(id: "binding:test", title: "Test action", source: .system,
            safety: .unknown, invocation: .direct, supportLevel: .experimental, requiresConfirmation: true,
            metadata: ["providerIdentity": "provider-v1", "schema": "schema-v1", "authorityOrigin": "origin-v1"])
        var calls = 0
        var observations = 0
        var mutateAt = 0
        var received: CapabilityArguments?
        var state: ExecutionState = .accepted
        var shouldThrow = false
        func capabilities(for item: ContentItem) throws -> [Capability] {
            observations += 1
            if observations == mutateAt { capability.metadata["schema"] = "changed-during-resolution" }
            return [capability]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            try begin(capability: capability, item: item, executionID: executionID, arguments: nil)
        }
        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?) throws -> ExecutionRecord {
            calls += 1; received = arguments
            if shouldThrow { throw CapabilityBindingError.mismatch }
            return ExecutionRecord(executionId: executionID, actionId: capability.id, state: state,
                                   message: "fixture accepted", output: "ok")
        }
    }
    private final class Verifier: Reflector, CapabilityVerificationReflector {
        var observed: VerificationSpec?
        var complete = true
        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
            calls += 1; received = arguments; observed = verification
            return ExecutionRecord(executionId: executionID, actionId: capability.id, state: .succeeded,
                message: "fixture verification", evidence: OutcomeEvidence(type: "fixture", outcomeVerified: complete),
                verification: complete ? OutcomeVerification(status: .verifiedSuccess,
                    predicates: verification.predicates.map {
                        PredicateVerification(predicate: $0, evaluated: true, passed: true, message: "fixture")
                    }) : nil)
        }
    }
    private final class Source: CapabilityReflectorSource {
        let id = "binding.test.source"
        var values: [any CapabilityReflector]
        var reads = 0
        var swapAt = 0
        var replacement: [any CapabilityReflector] = []
        init(_ values: [any CapabilityReflector]) { self.values = values }
        func reflectors() -> [any CapabilityReflector] {
            reads += 1
            if reads == swapAt { values = replacement }
            return values
        }
    }
    private func engine(_ r: Reflector) -> ContractBoundCapabilityEngine {
        ContractBoundCapabilityEngine(reflectors: [r])
    }
    private func plan(_ e: ContractBoundCapabilityEngine, arguments: CapabilityArguments? = nil,
                      verification: VerificationSpec? = nil) throws -> PreparedCapabilityInvocation {
        try e.prepare(id: "binding:test", item: "bound request", arguments: arguments, verification: verification)
    }
    func testPreparationNeverInvokes() throws {
        let r = Reflector(); let e = engine(r); let p = try plan(e)
        XCTAssertEqual(r.calls, 0)
        XCTAssertEqual(p.contractSHA256.count, 64); XCTAssertEqual(p.invocationSHA256.count, 64)
    }
    func testUnchangedExecutionAcceptedButNotVerified() throws {
        let r = Reflector(); let e = engine(r)
        let result = try e.begin(plan(e), confirmed: true)
        XCTAssertEqual(r.calls, 1); XCTAssertEqual(result.state, .accepted)
        XCTAssertFalse(result.evidence.outcomeVerified)
        XCTAssertEqual(e.executionStatus(result.executionId).executionId, result.executionId)
    }
    func testConfirmationStillRequired() throws {
        let r = Reflector(); let e = engine(r)
        XCTAssertEqual(try e.begin(plan(e)).state, .awaitingUser); XCTAssertEqual(r.calls, 0)
    }
    func testProviderSchemaAndAuthorityChangesReject() throws {
        for key in ["providerIdentity", "schema", "authorityOrigin"] {
            let r = Reflector(); let e = engine(r); let p = try plan(e)
            r.capability.metadata[key] = "changed"
            XCTAssertEqual(try e.begin(p, confirmed: true).state, .rejected, key)
            XCTAssertEqual(r.calls, 0, key)
        }
    }
    func testSafetyDowngradeCannotBypassBinding() throws {
        let r = Reflector(); let e = engine(r); let p = try plan(e)
        r.capability.safety = .read; r.capability.requiresConfirmation = false
        XCTAssertEqual(try e.begin(p).state, .rejected); XCTAssertEqual(r.calls, 0)
    }
    func testMutationAtLastObservationRejects() throws {
        let r = Reflector(); let e = engine(r); let p = try plan(e)
        r.mutateAt = 3
        XCTAssertEqual(try e.begin(p, confirmed: true).state, .rejected)
        XCTAssertEqual(r.observations, 3); XCTAssertEqual(r.calls, 0)
    }
    func testReplacementBetweenSelectionAndInvocationRejects() throws {
        let first = Reflector(); let second = Reflector()
        second.capability.metadata["schema"] = "replacement"
        let source = Source([first])
        let e = ContractBoundCapabilityEngine(reflectorSources: [source]); let p = try plan(e)
        source.swapAt = 3; source.replacement = [second]
        XCTAssertEqual(try e.begin(p, confirmed: true).state, .rejected)
        XCTAssertEqual(first.calls + second.calls, 0)
    }
    func testDisappearanceRemainsUnavailable() throws {
        let r = Reflector(); let source = Source([r])
        let e = ContractBoundCapabilityEngine(reflectorSources: [source]); let p = try plan(e)
        source.values = []
        XCTAssertEqual(try e.begin(p, confirmed: true).state, .unavailable); XCTAssertEqual(r.calls, 0)
    }
    func testAmbiguousReflectorIDsCannotPrepare() {
        let e = ContractBoundCapabilityEngine(reflectors: [Reflector(), Reflector()])
        XCTAssertThrowsError(try plan(e))
    }
    func testTitleIsNotAnExecutableIdentity() {
        let r = Reflector(); let e = engine(r)
        XCTAssertThrowsError(try e.prepare(id: "Test action", item: "bound request"))
        XCTAssertEqual(r.calls, 0)
    }
    func testForeignEnginePlanRejected() throws {
        let r = Reflector(); let a = engine(r); let b = engine(r)
        XCTAssertThrowsError(try b.begin(plan(a), confirmed: true)) { error in
            XCTAssertEqual(error as? CapabilityBindingError, .foreignPlan)
        }
        XCTAssertEqual(r.calls, 0)
    }
    func testArgumentsAreCopiedAndForwardedExactly() throws {
        let r = Reflector(); let e = engine(r)
        var arguments = ["title": "original"]
        let p = try plan(e, arguments: arguments); arguments["title"] = "changed"
        _ = try e.begin(p, confirmed: true)
        XCTAssertEqual(r.received, ["title": "original"])
    }
    func testNilAndEmptyArgumentsReachProviderDistinctly() throws {
        let r = Reflector(); let e = engine(r)
        let absent = try plan(e); let empty = try plan(e, arguments: [:])
        XCTAssertNotEqual(absent.invocationSHA256, empty.invocationSHA256)
        _ = try e.begin(absent, confirmed: true); XCTAssertNil(r.received)
        _ = try e.begin(empty, confirmed: true); XCTAssertEqual(r.received, [:])
    }
    func testLocalVerificationStillEvaluatesOutput() throws {
        let r = Reflector(); let e = engine(r)
        let spec = VerificationSpec(predicates: [.init(type: .textEquals, value: "ok")])
        let result = try e.begin(plan(e, verification: spec), confirmed: true)
        XCTAssertEqual(result.state, .succeeded); XCTAssertTrue(result.evidence.outcomeVerified)
    }
    func testFailedPostconditionDoesNotBecomeSuccess() throws {
        let r = Reflector(); let e = engine(r)
        let spec = VerificationSpec(predicates: [.init(type: .textEquals, value: "not ok")])
        XCTAssertEqual(try e.begin(plan(e, verification: spec), confirmed: true).state, .failed)
    }
    func testDelegatedVerificationIsPreserved() throws {
        let r = Verifier(); let e = engine(r)
        let spec = VerificationSpec(predicates: [.init(type: .textEquals, value: "ok")])
        XCTAssertEqual(try e.begin(plan(e, verification: spec), confirmed: true).state, .succeeded)
        XCTAssertEqual(r.observed, spec); XCTAssertEqual(r.calls, 1)
    }
    func testIncompleteDelegatedVerificationDowngrades() throws {
        let r = Verifier(); r.complete = false; let e = engine(r)
        let spec = VerificationSpec(predicates: [.init(type: .textEquals, value: "ok")])
        let result = try e.begin(plan(e, verification: spec), confirmed: true)
        XCTAssertEqual(result.state, .accepted); XCTAssertFalse(result.evidence.outcomeVerified)
    }
    func testURLsRejectedBeforeContextualDiscovery() {
        let source = Source([Reflector()]); let e = ContractBoundCapabilityEngine(reflectorSources: [source])
        XCTAssertThrowsError(try e.prepare(id: "binding:test", item: "https://example.invalid/object"))
        XCTAssertEqual(source.reads, 0)
    }
    func testAsynchronousStateIsNotInventedSuccess() throws {
        let r = Reflector(); r.state = .started; let e = engine(r)
        XCTAssertEqual(try e.begin(plan(e), confirmed: true).state, .started)
    }
    func testProviderErrorDoesNotCauseAutomaticRetry() throws {
        let r = Reflector(); r.shouldThrow = true; let e = engine(r); let p = try plan(e)
        XCTAssertThrowsError(try e.begin(p, confirmed: true)); XCTAssertEqual(r.calls, 1)
    }
    func testPlansAreExplicitlyNotSingleUseLeases() throws {
        let r = Reflector(); let e = engine(r); let p = try plan(e)
        _ = try e.begin(p, confirmed: true); _ = try e.begin(p, confirmed: true)
        XCTAssertEqual(r.calls, 2)
    }
    func testChangedContractCannotBeRescuedByLocalVerification() throws {
        let r = Reflector(); let e = engine(r)
        let spec = VerificationSpec(predicates: [.init(type: .textEquals, value: "ok")])
        let p = try plan(e, verification: spec)
        r.capability.metadata["schema"] = "changed"
        let result = try e.begin(p, confirmed: true)
        XCTAssertEqual(result.state, .rejected); XCTAssertFalse(result.evidence.outcomeVerified)
        XCTAssertEqual(r.calls, 0)
    }
    func testChangedContractCannotReachDelegatedVerifier() throws {
        let r = Verifier(); let e = engine(r)
        let spec = VerificationSpec(predicates: [.init(type: .textEquals, value: "ok")])
        let p = try plan(e, verification: spec)
        r.capability.metadata["schema"] = "changed"
        let result = try e.begin(p, confirmed: true)
        XCTAssertEqual(result.state, .rejected); XCTAssertFalse(result.evidence.outcomeVerified)
        XCTAssertEqual(r.calls, 0); XCTAssertNil(r.observed)
    }
}
