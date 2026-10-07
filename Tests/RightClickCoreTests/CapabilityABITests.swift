import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityABITests: XCTestCase {
    private func bytes(_ value: CapabilityValue) throws -> Data {
        try value.canonicalData()
    }

    private func decode(_ text: String) throws -> CapabilityValue {
        try CapabilityValue.decodeWire(Data(text.utf8))
    }

    func testAllValueKindsRoundTripWithoutCoercion() throws {
        let values: [CapabilityValue] = [
            .null, .boolean(true), .integer(Int64.min), .integer(Int64.max),
            .number(1.25), .number(-0.0), .string("a\u{0000}é"),
            .bytes(Data([0, 255, 17])), .array([.null, .boolean(false)]),
            .object(["n": .integer(42), "s": .string("42")])
        ]
        for value in values {
            let restored = try CapabilityValue.decodeWire(value.wireData())
            XCTAssertEqual(try bytes(value), try bytes(restored))
        }
    }

    func testTypesAndSignedZeroHaveDifferentCanonicalBytes() throws {
        let values: [CapabilityValue] = [.null, .boolean(false), .integer(0),
            .number(0), .number(-0.0), .string("0"), .bytes(Data([48]))]
        XCTAssertEqual(try Set(values.map(bytes)).count, values.count)
    }

    func testObjectInsertionOrderDoesNotMatter() throws {
        var first: [String: CapabilityValue] = [:]
        first["z"] = .integer(1); first["a"] = .boolean(true)
        var second: [String: CapabilityValue] = [:]
        second["a"] = .boolean(true); second["z"] = .integer(1)
        XCTAssertEqual(try bytes(.object(first)), try bytes(.object(second)))
    }

    func testArrayOrderAndOriginalUTF8Matter() throws {
        XCTAssertNotEqual(try bytes(.array([.integer(1), .integer(2)])),
                          try bytes(.array([.integer(2), .integer(1)])))
        XCTAssertNotEqual(try bytes(.string("é")), try bytes(.string("e\u{0301}")))
    }

    func testCanonicalGoldenVectors() throws {
        let header = Data("RIGHTCLICK-VALUE-1\0".utf8)
        XCTAssertEqual(try bytes(.null), header + Data("n".utf8))
        XCTAssertEqual(try bytes(.integer(-42)), header + Data("i3:-42".utf8))
        XCTAssertEqual(try bytes(.object(["a": .boolean(true)])),
                       header + Data("o1:s1:ab1".utf8))
        XCTAssertEqual(try bytes(.number(1)), header + Data([100, 63, 240, 0, 0, 0, 0, 0, 0]))
    }

    func testLengthFramingPreventsConcatenationAmbiguity() throws {
        XCTAssertNotEqual(try bytes(.array([.string("ab"), .string("c")])),
                          try bytes(.array([.string("a"), .string("bc")])))
    }

    func testNonfiniteNumbersRejectedEverywhere() throws {
        for number in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try bytes(.number(number)))
            XCTAssertThrowsError(try CapabilityValue.number(number).wireData())
            XCTAssertThrowsError(try CapabilitySchema.number.validate(.number(number)))
        }
    }

    func testLargeIntegerWireDoesNotUseFloatingPoint() throws {
        let value = CapabilityValue.integer(9_007_199_254_740_993)
        let wire = try value.wireData()
        XCTAssertTrue(String(decoding: wire, as: UTF8.self).contains("9007199254740993"))
        XCTAssertEqual(try bytes(value), try bytes(CapabilityValue.decodeWire(wire)))
    }

    func testStrictWireRejectsUnknownTrailingOrMalformedValues() {
        let bad = ["[\"future\"]", "[\"null\",0]", "[\"boolean\",1]",
            "[\"integer\",\"01\"]", "[\"integer\",\"-0\"]",
            "[\"integer\",\"9223372036854775808\"]",
            "[\"number\",\"7ff0000000000000\"]", "[\"number\",\"3FF0000000000000\"]",
            "[\"number\",\"1\"]", "[\"bytes\",\"!!!!\"]", "[\"bytes\",\"Zg\"]",
            "[\"array\",[],0]", "[\"object\",[[\"a\",[\"null\"],0]]]", "{}"]
        for wire in bad { XCTAssertThrowsError(try decode(wire), wire) }
    }

    func testDuplicateObjectKeysRejectedRatherThanOverwritten() {
        XCTAssertThrowsError(try decode("[\"object\",[[\"a\",[\"null\"]],[\"a\",[\"boolean\",true]]]]"))
        // Swift keys compare canonically equivalent Unicode as equal; reject both.
        XCTAssertThrowsError(try decode("[\"object\",[[\"é\",[\"null\"]],[\"e\\u0301\",[\"null\"]]]]"))
    }

    func testDepthLimitIsExact() throws {
        let value = CapabilityValue.array([.array([.null])])
        XCTAssertNoThrow(try value.canonicalData(limits: .init(maxDepth: 2)))
        XCTAssertThrowsError(try value.canonicalData(limits: .init(maxDepth: 1)))
        var deep = CapabilityValue.null
        for _ in 0..<40 { deep = .array([deep]) }
        XCTAssertThrowsError(try deep.wireData())
        let deepWire = String(repeating: "[\"array\",[", count: 40) + "[\"null\"]" + String(repeating: "]]", count: 40)
        XCTAssertThrowsError(try decode(deepWire))
    }

    func testNodeLimitCountsKeysAndValues() throws {
        let value = CapabilityValue.object(["a": .null])
        XCTAssertNoThrow(try value.canonicalData(limits: .init(maxNodes: 3)))
        XCTAssertThrowsError(try value.canonicalData(limits: .init(maxNodes: 2)))
    }

    func testCanonicalByteLimitIncludesHeaderAndFraming() throws {
        let value = CapabilityValue.string("hello")
        let count = try bytes(value).count
        XCTAssertEqual(try value.canonicalData(limits: .init(maxBytes: count)).count, count)
        XCTAssertThrowsError(try value.canonicalData(limits: .init(maxBytes: count - 1)))
    }

    func testWireByteLimitIsCheckedBeforeParsing() throws {
        XCTAssertThrowsError(try CapabilityValue.decodeWire(Data(repeating: 32, count: 33), limits: .init(maxBytes: 32)))
        XCTAssertThrowsError(try CapabilityValue.string(String(repeating: "\u{0000}", count: 100)).wireData(limits: .init(maxBytes: 200)))
    }

    func testInvalidLimitsFailClosed() {
        XCTAssertThrowsError(try CapabilityValue.null.canonicalData(limits: .init(maxDepth: -1)))
        XCTAssertThrowsError(try CapabilityValue.null.canonicalData(limits: .init(maxNodes: 0)))
        XCTAssertThrowsError(try CapabilityValue.null.canonicalData(limits: .init(maxBytes: 0)))
    }

    func testClosedObjectSchemaValidatesNestedValues() throws {
        let schema = CapabilitySchema.object(properties: ["title": .string,
            "rows": .array(.object(properties: ["active": .boolean], required: ["active"]))], required: ["title", "rows"])
        try schema.validate(.object(["title": .string("x"),
            "rows": .array([.object(["active": .boolean(true)])])]))
        XCTAssertThrowsError(try schema.validate(.object(["title": .string("x"),
            "rows": .array([.object(["active": .string("true")])])])))
    }

    func testClosedSchemaRejectsUnknownMissingAndWrongTypes() {
        let schema = CapabilitySchema.object(properties: ["n": .integer], required: ["n"])
        for value in [CapabilityValue.object([:]), .object(["n": .integer(1), "x": .null]),
                      .object(["n": .number(1)]), .object(["n": .string("1")]), .null] {
            XCTAssertThrowsError(try schema.validate(value))
        }
    }

    func testNullableAndOptionalAreDifferent() throws {
        let schema = CapabilitySchema.object(properties: ["n": .nullable(.integer)], required: ["n"])
        try schema.validate(.object(["n": .null]))
        XCTAssertThrowsError(try schema.validate(.object([:])))
        try CapabilitySchema.object(properties: ["n": .integer], required: []).validate(.object([:]))
        XCTAssertThrowsError(try CapabilitySchema.integer.validate(.null))
    }

    func testEnumsAndInvalidSchemaDeclarationsFailClosed() throws {
        try CapabilitySchema.stringEnum(["low", "high"]).validate(.string("high"))
        XCTAssertThrowsError(try CapabilitySchema.stringEnum(["high"]).validate(.string("other")))
        for schema in [CapabilitySchema.stringEnum([]), .stringEnum(["a", "a"]),
                       .object(properties: [:], required: ["missing"]),
                       .object(properties: ["a": .string], required: ["a", "a"])] {
            XCTAssertThrowsError(try schema.canonicalData())
        }
    }

    func testSchemaSetOrderIsCanonical() throws {
        XCTAssertEqual(try CapabilitySchema.stringEnum(["b", "a"]).canonicalData(),
                       try CapabilitySchema.stringEnum(["a", "b"]).canonicalData())
        let p: [String: CapabilitySchema] = ["a": .string, "b": .integer]
        XCTAssertEqual(try CapabilitySchema.object(properties: p, required: ["a", "b"]).canonicalData(),
                       try CapabilitySchema.object(properties: p, required: ["b", "a"]).canonicalData())
    }

    func testLegacyStringsRoundTripAndNilIsPreserved() throws {
        let source = ["integer": "001", "boolean": "false", "null": "null", "unicode": "é"]
        XCTAssertEqual(try CapabilityValue.fromLegacyArguments(source)?.legacyArguments(), source)
        XCTAssertNil(CapabilityValue.fromLegacyArguments(nil))
        XCTAssertEqual(try CapabilityValue.fromLegacyArguments([:])?.legacyArguments(), [:])
    }

    func testLegacyAdapterNeverStringifiesRicherValues() {
        for value in [CapabilityValue.null, .boolean(true), .integer(1), .number(1),
                      .bytes(Data()), .array([]), .object([:])] {
            XCTAssertThrowsError(try CapabilityValue.object(["x": value]).legacyArguments())
        }
        XCTAssertThrowsError(try CapabilityValue.array([]).legacyArguments())
    }

    private func contract(provider: String = "provider", owner: String = "reflector",
                          schema: CapabilitySchema? = .string, declaration: CapabilityValue = .object([:])) -> CapabilityContract {
        CapabilityContract(capabilityID: "capability", reflectorID: owner, providerID: provider,
                           arguments: schema, result: nil, declaration: declaration)
    }

    func testContractBindsIdentitySchemaAndDeclaration() throws {
        let baseline = try contract().canonicalData()
        for value in [contract(provider: "other"), contract(owner: "other"),
                      contract(schema: .integer), contract(declaration: .object(["origin": .string("other")]))] {
            XCTAssertNotEqual(baseline, try value.canonicalData())
        }
    }

    func testUnknownArgumentSchemaIsNotUnrestricted() {
        XCTAssertThrowsError(try contract(schema: nil).validateArguments(.object([:])))
        XCTAssertThrowsError(try contract().validateArguments(.integer(3)))
    }

    func testInvalidContractIdentityRejected() {
        let c = CapabilityContract(capabilityID: "", reflectorID: "r", providerID: "p",
                                   arguments: nil, result: nil, declaration: .null)
        XCTAssertThrowsError(try c.canonicalData())
    }

    func testContractAndValueCanonicalDomainsAreDifferent() throws {
        XCTAssertTrue(String(decoding: try contract().canonicalData().prefix(21), as: UTF8.self).hasPrefix("RIGHTCLICK-CONTRACT-1"))
        XCTAssertNotEqual(try contract().canonicalData(), try bytes(.object([:])))
    }
}
