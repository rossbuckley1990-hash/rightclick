import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityInvocationBindingTests: XCTestCase {
    private func contract(_ id: String = "cap", provider: String = "provider",
                          reflector: String = "reflector", schema: CapabilitySchema? = .string,
                          declaration: CapabilityValue = .string("declaration")) -> CapabilityContract {
        CapabilityContract(capabilityID: id, reflectorID: reflector, providerID: provider,
                           arguments: schema, result: nil, declaration: declaration)
    }
    private func binding(_ value: CapabilityValue? = nil, context: CapabilityValue = .string("task"),
                         verification: CapabilityValue? = nil) throws -> CapabilityInvocationBinding {
        try CapabilityInvocationBinding(contract: contract(), context: context,
                                        arguments: value, verification: verification)
    }
    func testIdenticalRequestsMatch() throws {
        let b = try binding(.string("input"))
        try b.validate(contract: contract(), context: .string("task"), arguments: .string("input"))
    }
    func testChangedCapabilityRejected() throws {
        let b = try binding()
        XCTAssertThrowsError(try b.validate(contract: contract("other"), context: .string("task")))
    }
    func testChangedProviderRejected() throws {
        let b = try binding()
        XCTAssertThrowsError(try b.validate(contract: contract(provider: "other"), context: .string("task")))
    }
    func testChangedReflectorRejected() throws {
        let b = try binding()
        XCTAssertThrowsError(try b.validate(contract: contract(reflector: "other"), context: .string("task")))
    }
    func testChangedSchemaRejected() throws {
        let b = try binding()
        XCTAssertThrowsError(try b.validate(contract: contract(schema: .integer), context: .string("task")))
    }
    func testChangedAuthorityDeclarationRejected() throws {
        let b = try binding()
        XCTAssertThrowsError(try b.validate(contract: contract(declaration: .string("other origin")), context: .string("task")))
    }
    func testContextUsesExactUTF8() throws {
        XCTAssertNotEqual(try binding(context: .string("\u{e9}")),
                          try binding(context: .string("e\u{301}")))
    }
    func testScalarTypesRemainDistinct() throws {
        let values: [CapabilityValue] = [.boolean(true), .integer(1), .number(1), .string("1")]
        XCTAssertEqual(try Set(values.map { try binding($0).canonicalData() }).count, 4)
    }
    func testAbsentNullAndEmptyArgumentsRemainDistinct() throws {
        let values: [CapabilityValue?] = [nil, .null, .object([:]), .array([])]
        XCTAssertEqual(try Set(values.map { try binding($0).canonicalData() }).count, 4)
    }
    func testVerificationCannotBeReplaced() throws {
        let b = try binding(verification: .string("read back exact title"))
        XCTAssertThrowsError(try b.validate(contract: contract(), context: .string("task"), verification: .string("HTTP 200")))
    }
    func testVerificationCannotBeRemoved() throws {
        let b = try binding(verification: .string("check"))
        XCTAssertThrowsError(try b.validate(contract: contract(), context: .string("task")))
    }
    func testAbsentAndEmptyVerificationDiffer() throws {
        XCTAssertNotEqual(try binding(), try binding(verification: .object([:])))
    }
    func testObjectInsertionOrderDoesNotMatter() throws {
        XCTAssertEqual(try binding(.object(["a": .integer(1), "b": .integer(2)])),
                       try binding(.object(["b": .integer(2), "a": .integer(1)])))
    }
    func testBindingIsAnImmutableSnapshot() throws {
        var values: [String: CapabilityValue] = ["title": .string("draft")]
        let b = try binding(.object(values))
        values["title"] = .string("send")
        XCTAssertNotEqual(b, try binding(.object(values)))
        try b.validate(contract: contract(), context: .string("task"), arguments: .object(["title": .string("draft")]))
    }
    func testAggregateByteLimitRejects() throws {
        let text = String(repeating: "x", count: 600_000)
        XCTAssertThrowsError(try binding(.string(text), context: .string(text)))
    }
    func testNonfiniteAndDeepInputsReject() throws {
        XCTAssertThrowsError(try binding(.number(.infinity)))
        var deep = CapabilityValue.null
        for _ in 0..<40 { deep = .array([deep]) }
        XCTAssertThrowsError(try binding(deep))
    }
    func testBindingHasSeparateCanonicalDomain() throws {
        let data = try binding().canonicalData()
        XCTAssertTrue(data.starts(with: Data("RIGHTCLICK-INVOCATION-1\0".utf8)))
        XCTAssertNotEqual(data, try contract().canonicalData())
    }
    func testInvalidIdentityCannotBeBound() {
        XCTAssertThrowsError(try CapabilityInvocationBinding(contract: contract(""), context: .null))
    }
}
