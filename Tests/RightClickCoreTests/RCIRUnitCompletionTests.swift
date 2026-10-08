import Foundation
import XCTest
@testable import RightClickCore

final class RCIRUnitCompletionTests: XCTestCase {
    private func task(result: CapabilitySchema?, verification: RCIRVerificationContract? = nil) throws -> RCIRTask {
        let scope = RCIRScope("urn:isolated:effect", .execute)
        let abi = CapabilityContract(capabilityID: "effect", reflectorID: "compiler", providerID: "provider",
            arguments: .string, result: result, declaration: .string("acquired contract"))
        let admission = RCIRAdmission()
        let binding = try admission.publish(.init(abi: abi, scopes: [scope], verification: verification), authenticatedPrincipal: "owner")
        let lease = try admission.issue(binding, arguments: .string("challenge"), authority: [scope],
            policy: .init(revision: "local", principals: ["owner"], scopes: [scope]), now: 100)
        return try RCIRTask(lease: lease, startedAt: 101, deadline: 1000)
    }

    func testNoOutputHasCanonicalIdentityDistinctFromJSONNull() throws {
        XCTAssertNotEqual(try CapabilitySchema.unit.canonicalData(), try CapabilitySchema.null.canonicalData())
        for value in [CapabilityValue.null, .string("accepted"), .bytes(Data()), .object([:])] {
            XCTAssertThrowsError(try CapabilitySchema.unit.validate(value))
        }
    }

    func testNoOutputCompletionCarriesNoProviderValueAndRemainsUnverified() throws {
        var value = try task(result: .unit)
        try value.record(.completedWithoutOutput, sequence: 1, now: 102)
        XCTAssertEqual(value.phase, .completed); XCTAssertEqual(value.outcome, .unverified)
        XCTAssertNil(value.observationRequest.providerResult)
        XCTAssertThrowsError(try value.record(.completedWithoutOutput, sequence: 2, now: 103))
    }

    func testNoOutputCompletionCannotBypassDeclaredOrUnknownOutput() throws {
        for schema in [CapabilitySchema.string, .null, nil] {
            var value = try task(result: schema)
            XCTAssertThrowsError(try value.record(.completedWithoutOutput, sequence: 1, now: 102))
            XCTAssertEqual(value.phase, .started); XCTAssertEqual(value.sequence, 0)
        }
        var value = try task(result: .unit)
        XCTAssertThrowsError(try value.record(.completed(.null), sequence: 1, now: 102))
        XCTAssertEqual(value.phase, .started); XCTAssertEqual(value.sequence, 0)
    }

    func testOnlyIndependentObserverCanPromoteNoOutputOutcome() throws {
        let contract = RCIRVerificationContract(observerID: "independent", schema: .string, expected: .string("actual effect"))
        var value = try task(result: .unit, verification: contract)
        try value.record(.completedWithoutOutput, sequence: 1, now: 102)
        XCTAssertThrowsError(try value.verify(observerID: "provider", now: 103) { _, _ in .string("actual effect") })
        XCTAssertEqual(value.outcome, .unverified)
        try value.verify(observerID: "independent", now: 104) { _, _ in .string("actual effect") }
        XCTAssertEqual(value.outcome, .succeeded)
    }

}
