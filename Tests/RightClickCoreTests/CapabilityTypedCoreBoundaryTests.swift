import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityTypedCoreBoundaryTests: XCTestCase {
    func testDeclaredBooleanCanReachCommonHostWithExactTaggedCoreValue() throws {
        var calls = 0
        let reflector = try CapabilityInterfaceReflector(id: "typed:boundary", provider: "typed-provider",
            target: URL(string: "dbus://com.example.Typed/com/example/Typed")!, substrate: "dbus",
            descriptorDigest: "actual-boolean-signature-b",
            operations: [.init(name: "SetEnabled", title: "SetEnabled",
                arguments: .object(properties: ["enabled": .boolean], required: ["enabled"]),
                result: .boolean, declaration: .string("b->b"))],
            argumentEncoding: .taggedNonStrings, available: { true }, invoke: { _, input, admit in
                try admit { calls += 1 }
                guard case let .object(values) = input, let enabled = values["enabled"] else { throw RCIRError.invalidContract }
                return enabled
            })
        let item = try ContentParser.parse("typed boundary")
        let capability = try reflector.capabilities(for: item)[0]
        do {
            let result = try reflector.begin(capability: capability, item: item, executionID: "typed-core",
                arguments: ["enabled": "[\"boolean\",true]"])
            XCTAssertEqual(result.state, .accepted)
            XCTAssertEqual(result.output, "true")
            XCTAssertEqual(result.rcir?.leaseConsumed, true)
        } catch { XCTFail("A declared boolean cannot reach the shared host through the Core profile: \(error)") }
        XCTAssertEqual(calls, 1)
    }
    func testAdapterPreservesLiteralStringsAndExactIntegerBits() throws {
        let schema = CapabilitySchema.object(properties: ["text": .string, "count": .integer, "flag": .boolean], required: ["text", "count", "flag"])
        let decoded = try CapabilityCoreArgumentEncoding.taggedNonStrings.decode([
            "text": "[\"boolean\",false]", "count": "[\"integer\",\"9223372036854775807\"]", "flag": "[\"boolean\",false]"], schema: schema)
        XCTAssertEqual(try decoded.canonicalData(), try CapabilityValue.object([
            "text": .string("[\"boolean\",false]"), "count": .integer(Int64.max), "flag": .boolean(false)]).canonicalData())
    }
    func testAdapterRejectsCoercionUnknownFieldsWrongTagsAndInvalidNumbers() throws {
        let schema = CapabilitySchema.object(properties: ["flag": .boolean], required: ["flag"])
        for raw in ["true", "[\"string\",\"true\"]", "[\"boolean\",1]", "[\"boolean\",true,false]"] {
            XCTAssertThrowsError(try CapabilityCoreArgumentEncoding.taggedNonStrings.decode(["flag": raw], schema: schema))
        }
        XCTAssertThrowsError(try CapabilityCoreArgumentEncoding.taggedNonStrings.decode(["flag": "[\"boolean\",true]", "extra": "x"], schema: schema))
        XCTAssertThrowsError(try CapabilityCoreArgumentEncoding.literalStrings.decode(["flag": "[\"boolean\",true]"], schema: schema))
    }
    func testArrayRetainsTypedElementsAndRejectsDepthLimit() throws {
        let schema = CapabilitySchema.object(properties: ["tags": .array(.string)], required: ["tags"])
        let value = try CapabilityCoreArgumentEncoding.taggedNonStrings.decode(["tags": "[\"array\",[[\"string\",\"literal\"],[\"string\",\"$(not-a-command)\"]]]"], schema: schema)
        try schema.validate(value)
        XCTAssertThrowsError(try CapabilityCoreArgumentEncoding.taggedNonStrings.decode(["tags": "[\"array\",[[\"boolean\",true]]]"], schema: schema))
        var deep = CapabilityValue.string("leaf")
        for _ in 0..<34 { deep = .array([deep]) }
        XCTAssertThrowsError(try deep.wireData())
    }
}
