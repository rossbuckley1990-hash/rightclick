import Foundation
import XCTest
@testable import RightClickCore

private final class SemanticPreflightSpy: CapabilityReflector {
    let id: String
    var capability: Capability
    var rows: [Capability]?
    var invocations = 0
    var catalogReads = 0
    var driftOnSecondRead = false
    init(_ capability: Capability = semanticFixture()) {
        self.capability = capability
        self.id = capability.reflectorID
    }
    func capabilities(for item: ContentItem) throws -> [Capability] {
        catalogReads += 1
        if driftOnSecondRead && catalogReads >= 2 { capability.metadata["method"] = "DELETE" }
        return rows ?? [capability]
    }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        invocations += 1
        return ExecutionRecord(executionId: executionID, actionId: capability.id, state: .accepted, message: "Synthetic provider accepted; no semantic proof.")
    }
}

final class ExecutionPreflightIntegrationTests: XCTestCase {
    func testAmbiguousTitleNeverDispatchesThroughRun() throws {
        let a = SemanticPreflightSpy(); let b = SemanticPreflightSpy(semanticFixture(id: "cap:beta", owner: "owner:beta"))
        let result = try CapabilityEngine(reflectors: [a, b]).run(id: "Publish report", item: "synthetic report", confirmed: true)
        XCTAssertEqual(result.status, .unavailable); XCTAssertEqual(a.invocations + b.invocations, 0)
    }
    func testAmbiguousTitleNeverDispatchesThroughBegin() throws {
        let a = SemanticPreflightSpy(); let b = SemanticPreflightSpy(semanticFixture(id: "cap:beta", owner: "owner:beta"))
        let result = try CapabilityEngine(reflectors: [a, b]).begin(id: "Publish report", item: "synthetic report", confirmed: true)
        XCTAssertEqual(result.state, .unavailable); XCTAssertEqual(a.invocations + b.invocations, 0)
    }
    func testDescribeRejectsAmbiguousTitle() throws {
        let a = SemanticPreflightSpy(); let b = SemanticPreflightSpy(semanticFixture(id: "cap:beta", owner: "owner:beta"))
        XCTAssertThrowsError(try CapabilityEngine(reflectors: [a, b]).describe(id: "Publish report", item: "synthetic report"))
    }
    func testExactIDCannotBeShadowedByTitle() throws {
        let a = SemanticPreflightSpy(); let b = SemanticPreflightSpy(semanticFixture(id: "cap:impostor", title: "capability:alpha", owner: "owner:impostor"))
        let result = try CapabilityEngine(reflectors: [b, a]).run(id: a.capability.id, item: "synthetic report", confirmed: true)
        XCTAssertEqual(result.status, .accepted); XCTAssertEqual(a.invocations, 1); XCTAssertEqual(b.invocations, 0)
    }
    func testConflictingIdentityRemovedFromGraph() throws {
        let a = SemanticPreflightSpy(); let b = SemanticPreflightSpy(semanticFixture(owner: "owner:beta"))
        let engine = CapabilityEngine(reflectors: [a, b])
        XCTAssertTrue(try engine.capabilities(for: "synthetic report").capabilities.isEmpty)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true).state, .unavailable)
        XCTAssertEqual(a.invocations + b.invocations, 0)
    }
    func testMissingArgumentsFailBeforeRunConfirmation() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let result = try CapabilityEngine(reflectors: [a]).run(id: a.capability.id, item: "synthetic report", confirmed: false)
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.evidence.type, "missing_required_arguments"); XCTAssertEqual(a.invocations, 0)
    }
    func testMissingArgumentsFailBeforeBeginConfirmationAndRemainQueryable() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let engine = CapabilityEngine(reflectors: [a])
        let result = try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: false)
        XCTAssertEqual(result.state, .failed); XCTAssertEqual(a.invocations, 0)
        XCTAssertEqual(engine.executionStatus(result.executionId).evidence.type, "missing_required_arguments")
    }
    func testUnexpectedArgumentsNeverReachConfirmedProvider() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let result = try CapabilityEngine(reflectors: [a]).begin(id: a.capability.id, item: "synthetic report", confirmed: true, arguments: ["owner": "test", "report": "r", "extra": "x"])
        XCTAssertEqual(result.state, .failed); XCTAssertEqual(a.invocations, 0)
    }
    func testValidEnvelopeStillNeedsConfirmation() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let engine = CapabilityEngine(reflectors: [a])
        let args = ["owner": "test", "report": "r"]
        XCTAssertEqual(try engine.run(id: a.capability.id, item: "synthetic report", confirmed: false, arguments: args).status, .confirmationRequired)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: false, arguments: args).state, .awaitingUser)
        XCTAssertEqual(a.invocations, 0)
    }
    func testValidConfirmedEnvelopeRemainsAcceptedNotVerified() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let result = try CapabilityEngine(reflectors: [a]).begin(id: a.capability.id, item: "synthetic report", confirmed: true, arguments: ["owner": "test", "report": "r"])
        XCTAssertEqual(result.state, .accepted); XCTAssertFalse(result.evidence.outcomeVerified); XCTAssertEqual(a.invocations, 1)
    }
    func testUnadvertisedCustomEnvelopeRetainsReflectorValidation() throws {
        let a = SemanticPreflightSpy()
        let result = try CapabilityEngine(reflectors: [a]).run(id: a.capability.id, item: "synthetic report", confirmed: true, arguments: ["custom": "x"])
        XCTAssertEqual(result.status, .accepted); XCTAssertEqual(a.invocations, 1)
    }
    func testUnsupportedRemainsUnsupportedWithoutInvocation() throws {
        var c = semanticFixture(schema: semanticClosedSchema); c.invocation = .unsupported
        let a = SemanticPreflightSpy(c)
        let result = try CapabilityEngine(reflectors: [a]).begin(id: c.id, item: "synthetic report", confirmed: true)
        XCTAssertEqual(result.state, .unsupported); XCTAssertEqual(a.invocations, 0)
    }
    func testExistingDispatchDriftGuardIsPreserved() throws {
        let a = SemanticPreflightSpy(); a.driftOnSecondRead = true
        let result = try CapabilityEngine(reflectors: [a]).begin(id: a.capability.id, item: "synthetic report", confirmed: true)
        XCTAssertEqual(result.state, .unavailable); XCTAssertEqual(a.invocations, 0)
    }
    func testRemovedCapabilityStaysUnavailableInSameEngine() throws {
        let a = SemanticPreflightSpy(); let engine = CapabilityEngine(reflectors: [a])
        XCTAssertEqual(try engine.capabilities(for: "synthetic report").capabilities.count, 1)
        a.rows = []
        XCTAssertEqual(try engine.run(id: a.capability.id, item: "synthetic report", confirmed: true).status, .unavailable)
        XCTAssertEqual(a.invocations, 0)
    }
}
