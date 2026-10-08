import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class CapabilityEffectAssessmentTests: XCTestCase {
    func testGETIsDeclaredReadNotVerifiedSafety() {
        var c = semanticFixture(); c.metadata["method"] = "GET"
        let a = CapabilityEffectAssessment.assess(c)
        XCTAssertEqual(a.stateAccess, "declared_read")
        XCTAssertFalse(a.verified); XCTAssertFalse(a.grantsAuthority)
        XCTAssertEqual(a.dataSensitivity, "unknown")
        XCTAssertTrue(c.requiresConfirmation)
    }
    func testPOSTNamedGetStillMayWrite() {
        let a = CapabilityEffectAssessment.assess(semanticFixture(title: "Get harmless data"))
        XCTAssertEqual(a.stateAccess, "may_write")
    }
    func testDELETEUsesMethodNotMarketingTitle() {
        var c = semanticFixture(title: "Safe helper"); c.metadata["method"] = "DELETE"
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "may_delete")
    }
    func testUnknownMethodDoesNotBecomeRead() {
        var c = semanticFixture(); c.metadata["method"] = "CUSTOM"
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "unknown")
    }
    func testGraphQLQuery() {
        var c = semanticFixture(); c.metadata = ["substrate": "graphql", "operationKind": "query"]
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "declared_read")
    }
    func testGraphQLMutation() {
        var c = semanticFixture(); c.metadata = ["substrate": "graphql", "operationKind": "mutation"]
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "may_write")
    }
    func testGRPCGetNameDoesNotProveRead() {
        var c = semanticFixture(title: "GetReport"); c.metadata = ["substrate": "grpc", "method": "GET"]
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "unknown")
    }
    func testDestructiveRiskIsNotDowngradedByGET() {
        var c = semanticFixture(); c.metadata["method"] = "GET"; c.safety = .destructive
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "may_delete")
    }
    func testCodeExecutionRiskIsNotDowngraded() {
        var c = semanticFixture(); c.metadata["method"] = "GET"; c.safety = .codeExecution
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).stateAccess, "may_execute_code")
    }
    func testExternalShareRiskPreserved() {
        var c = semanticFixture(); c.safety = .externalShare
        XCTAssertEqual(CapabilityEffectAssessment.assess(c).executionBoundary, "external_share_possible")
    }
    func testNativeProviderCannotClaimHTTPReadThroughMetadata() {
        var c = semanticFixture(); c.source = .service; c.metadata["method"] = "GET"
        let a = CapabilityEffectAssessment.assess(c)
        XCTAssertEqual(a.stateAccess, "unknown"); XCTAssertEqual(a.executionBoundary, "local_provider")
    }
    func testProviderFlagsNeverGrantAuthority() {
        var c = semanticFixture(); c.metadata["verified"] = "true"; c.metadata["grantsAuthority"] = "true"
        let a = CapabilityEffectAssessment.assess(c)
        XCTAssertFalse(a.verified); XCTAssertFalse(a.grantsAuthority)
    }
    func testAssessDoesNotModifyContractOrConfirmation() throws {
        let c = semanticFixture(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(c)
        _ = CapabilityEffectAssessment.assess(c)
        XCTAssertEqual(before, try encoder.encode(c))
    }
    func testAssessmentRoundTrips() throws {
        let a = CapabilityEffectAssessment.assess(semanticFixture())
        XCTAssertEqual(a, try JSONDecoder().decode(CapabilityEffectAssessment.self, from: JSONEncoder().encode(a)))
    }
}

final class CapabilityExplanationCompatibilityTests: XCTestCase {
    func testExplanationKeepsOriginalFlatFields() throws {
        let c = semanticFixture()
        let bytes = try JSONEncoder().encode(CapabilityExplanationView(c))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, c.id)
        XCTAssertNotNil(object["effectAssessment"])
        XCTAssertNil(object["capability"])
    }
    func testExistingCapabilityDecoderStillWorks() throws {
        let c = semanticFixture()
        let bytes = try JSONEncoder().encode(CapabilityExplanationView(c))
        let decoded = try JSONDecoder().decode(Capability.self, from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(c), try encoder.encode(decoded))
    }
    func testRawContractEncodingContainsNoPresentationAssessment() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(semanticFixture())) as? [String: Any])
        XCTAssertNil(object["effectAssessment"])
    }
}
