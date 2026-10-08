import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

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
    func testQuarantinedIDCannotFallThroughToAnotherProvidersTitle() throws {
        let a = SemanticPreflightSpy()
        let b = SemanticPreflightSpy(semanticFixture(owner: "owner:beta"))
        let alias = SemanticPreflightSpy(semanticFixture(id: "unrelated:alias", title: a.capability.id, owner: "owner:alias"))
        let engine = CapabilityEngine(reflectors: [a, b, alias], experience: nil)
        XCTAssertEqual(try engine.capabilities(for: "synthetic report").capabilities.map(\.id), [alias.capability.id])
        XCTAssertThrowsError(try engine.describe(id: a.capability.id, item: "synthetic report"))
        XCTAssertEqual(try engine.run(id: a.capability.id, item: "synthetic report", confirmed: true).status, .unavailable)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true).state, .unavailable)
        XCTAssertEqual(a.invocations + b.invocations + alias.invocations, 0)
        XCTAssertEqual(try engine.begin(id: alias.capability.id, item: "synthetic report", confirmed: true).state, .accepted)
        XCTAssertEqual(alias.invocations, 1)
    }
    func testExactIDWithPinWinsOverSpoofedTitleAndPinCannotDisambiguateAlias() throws {
        let a = SemanticPreflightSpy()
        let b = SemanticPreflightSpy(semanticFixture(id: "cap:beta", title: a.capability.id, owner: "owner:beta"))
        let engine = CapabilityEngine(reflectors: [b, a], experience: nil)
        let pin = try XCTUnwrap(engine.describe(id: a.capability.id, item: "synthetic report").contractSHA256)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: false, contractSHA256: pin).state, .awaitingUser)
        XCTAssertEqual(a.invocations + b.invocations, 0)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true, contractSHA256: pin).state, .accepted)
        XCTAssertEqual(a.invocations, 1); XCTAssertEqual(b.invocations, 0)
        b.capability.title = a.capability.title
        XCTAssertEqual(try engine.begin(id: a.capability.title, item: "synthetic report", confirmed: true, contractSHA256: pin).state, .unavailable)
        XCTAssertEqual(a.invocations, 1); XCTAssertEqual(b.invocations, 0)
        b.capability.id = a.capability.id
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true, contractSHA256: pin).state, .unavailable)
        XCTAssertEqual(a.invocations, 1); XCTAssertEqual(b.invocations, 0)
    }
    func testDuplicateReflectorOwnerCannotRouteToFirstProvider() throws {
        let a = SemanticPreflightSpy()
        let b = SemanticPreflightSpy(semanticFixture(id: "cap:beta"))
        let engine = CapabilityEngine(reflectors: [a, b], experience: nil)
        XCTAssertTrue(try engine.capabilities(for: "synthetic report").capabilities.isEmpty)
        XCTAssertThrowsError(try engine.describe(id: a.capability.id, item: "synthetic report"))
        // Even a syntactically valid pin cannot resurrect an unavailable owner.
        let pin = String(repeating: "f", count: 64)
        XCTAssertEqual(try engine.run(id: a.capability.id, item: "synthetic report", confirmed: true, contractSHA256: pin).status, .unavailable)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true, contractSHA256: pin).state, .unavailable)
        XCTAssertEqual(a.invocations + b.invocations, 0)
    }
    func testExactUTF8ReflectorOwnersAndIDsRouteIndependently() throws {
        let a = SemanticPreflightSpy(semanticFixture(id: "cap:caf\u{e9}", owner: "owner:caf\u{e9}"))
        let b = SemanticPreflightSpy(semanticFixture(id: "cap:cafe\u{301}", owner: "owner:cafe\u{301}"))
        XCTAssertEqual(a.capability.id, b.capability.id)
        XCTAssertEqual(a.id, b.id)
        let engine = CapabilityEngine(reflectors: [b, a], experience: nil)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true).state, .accepted)
        XCTAssertEqual(try engine.begin(id: b.capability.id, item: "synthetic report", confirmed: true).state, .accepted)
        XCTAssertEqual(a.invocations, 1); XCTAssertEqual(b.invocations, 1)
    }
    func testIdenticalDeclarationRepeatsKeepSingleOwnedDispatch() throws {
        let a = SemanticPreflightSpy(); var repeated = a.capability
        repeated.contractSHA256 = "provider-forged"
        repeated.metadata["experience.status"] = "provider-forged"
        a.rows = [a.capability, repeated]
        let engine = CapabilityEngine(reflectors: [a], experience: nil)
        XCTAssertEqual(try engine.capabilities(for: "synthetic report").capabilities.count, 1)
        XCTAssertEqual(try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: true).state, .accepted)
        XCTAssertEqual(a.invocations, 1)
    }
    func testMissingArgumentsFailBeforeRunConfirmation() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let result = try CapabilityEngine(reflectors: [a]).run(id: a.capability.id, item: "synthetic report", confirmed: false)
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.evidence.type, "input_contract_failure")
        XCTAssertTrue(result.evidence.boundary.contains("[missing_required_arguments]")); XCTAssertEqual(a.invocations, 0)
    }
    func testMissingArgumentsFailBeforeBeginConfirmationAndRemainQueryable() throws {
        let a = SemanticPreflightSpy(semanticFixture(schema: semanticClosedSchema))
        let engine = CapabilityEngine(reflectors: [a])
        let result = try engine.begin(id: a.capability.id, item: "synthetic report", confirmed: false)
        XCTAssertEqual(result.state, .failed); XCTAssertEqual(a.invocations, 0)
        XCTAssertEqual(engine.executionStatus(result.executionId).evidence.type, "input_contract_failure")
        XCTAssertTrue(engine.executionStatus(result.executionId).evidence.boundary.contains("[missing_required_arguments]"))
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
