import Foundation
import XCTest
@testable import RightClickCore

/// Actual Windows relay declaration exposed this generic schema omission.
/// These pressure tests apply equally to OpenAPI and nested descriptor schemas.
final class CapabilityStringConstraintTests: XCTestCase {
    private let challenge: [String: Any] = ["type": "string", "pattern": "^[A-Za-z0-9_-]{8,128}$"]

    func testActualChallengeDeclarationAcceptsExactBoundsAndCharacterSet() throws {
        let schema = try CapabilityJSON.schema(challenge)
        for value in ["Ab0_-xyz", String(repeating: "A", count: 128)] {
            XCTAssertNoThrow(try schema.validate(.string(value)))
        }
        for value in ["short", String(repeating: "A", count: 129), "abcdefgh/", "abcdefgh\n", "abcdefgé", "abcdefgh."] {
            XCTAssertThrowsError(try schema.validate(.string(value)), value.debugDescription)
        }
    }

    func testNestedImportKeepsRequiredClosedObjectAndStringConstraint() throws {
        let schema = try CapabilityJSON.schema(["type": "object", "properties": ["challenge": challenge],
            "required": ["challenge"], "additionalProperties": false])
        try schema.validate(.object(["challenge": .string("nonce_42")]))
        XCTAssertThrowsError(try schema.validate(.object(["challenge": .string("x")])) )
        XCTAssertThrowsError(try schema.validate(.object(["challenge": .string("nonce_42"), "extra": .null])))
        XCTAssertThrowsError(try schema.validate(.object([:])))
    }

    func testLengthUsesUnicodeScalarsRatherThanGraphemesOrBytes() throws {
        let schema = try CapabilityJSON.schema(["type": "string", "minLength": 2, "maxLength": 2])
        try schema.validate(.string("e\u{0301}")) // Two scalars, one grapheme, three UTF-8 bytes.
        try schema.validate(.string("é🙂"))
        XCTAssertThrowsError(try schema.validate(.string("é")))
        XCTAssertThrowsError(try schema.validate(.string("é🙂x")))
    }

    func testPatternLengthAndEnumAreIntersectedWithoutWidening() throws {
        let schema = try CapabilityJSON.schema(["type": "string", "pattern": "^[a-z]{2,8}$",
            "minLength": 3, "maxLength": 4, "enum": ["abc", "abcd", "ab", "abcde", "ABC"]])
        try schema.validate(.string("abc")); try schema.validate(.string("abcd"))
        for value in ["ab", "abcde", "ABC", "xyz"] { XCTAssertThrowsError(try schema.validate(.string(value))) }
    }

    func testEquivalentCharacterClassesAndEnumOrderHaveCanonicalIdentity() throws {
        var alternate = challenge; alternate["pattern"] = "^[-_0-9a-zA-Z]{8,128}$"
        XCTAssertEqual(try CapabilityJSON.schema(challenge).canonicalData(), try CapabilityJSON.schema(alternate).canonicalData())
        let first = try CapabilityJSON.schema(["type": "string", "minLength": 1, "enum": ["b", "a"]])
        let second = try CapabilityJSON.schema(["type": "string", "minLength": 1, "enum": ["a", "b"]])
        XCTAssertEqual(try first.canonicalData(), try second.canonicalData())
    }

    func testChangingBoundOrCharacterSetChangesContractIdentity() throws {
        func contract(_ schema: [String: Any]) throws -> Data {
            try CapabilityContract(capabilityID: "proof", reflectorID: "compiler", providerID: "provider",
                arguments: CapabilityJSON.schema(schema), result: .string, declaration: .null).canonicalData()
        }
        let original = try contract(challenge)
        for pattern in ["^[A-Za-z0-9_-]{8,127}$", "^[A-Za-z0-9_-]{9,128}$", "^[A-Za-z0-9]{8,128}$"] {
            XCTAssertNotEqual(original, try contract(["type": "string", "pattern": pattern]))
        }
    }

    func testUnsupportedRegexGrammarAndUnboundedRepetitionAbstain() {
        for pattern in ["safe", "^safe$", "^[a-z]+$", "^[a-z]{1,}$", "^[a-z]*$", "^(a+)+$", "^(a|b){1,8}$",
            "^(?=a)[a-z]{1,8}$", "^[^a]{1,8}$", "^[\\w]{1,8}$", "^[z-a]{1,8}$", "^[a-z]{8,2}$",
            "^[a-z]{1,1048577}$", "^[a-z]{1,8}$suffix", "^[a-z]{1,8}{1,8}$", "^[é]{1,8}$"] {
            XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "pattern": pattern]), pattern)
        }
    }

    func testMalformedLengthsAndEmptyIntersectionAbstain() {
        for value: Any in [true, -1, 0.5, "8", NSNull(), 1_048_577, Double.infinity] {
            XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "minLength": value]))
            XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "maxLength": value]))
        }
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "minLength": 9, "maxLength": 8]))
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "pattern": "^[a-z]{1,8}$", "minLength": 9]))
        XCTAssertThrowsError(try CapabilityJSON.schema(["type": "string", "pattern": "^[a-z]{8,16}$", "maxLength": 7]))
    }

    func testZeroAndExactQuantifierRemainExact() throws {
        let empty = try CapabilityJSON.schema(["type": "string", "pattern": "^[a-z]{0}$"])
        try empty.validate(.string("")); XCTAssertThrowsError(try empty.validate(.string("a")))
        let exact = try CapabilityJSON.schema(["type": "string", "pattern": "^[a-z]{3}$"])
        try exact.validate(.string("abc")); XCTAssertThrowsError(try exact.validate(.string("ab")))
        XCTAssertThrowsError(try exact.validate(.string("abcd")))
    }

    private func specification(pattern: String = "^[A-Za-z0-9_-]{8,128}$") throws -> Data {
        let body: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["challenge"],
            "properties": ["challenge": ["type": "string", "pattern": pattern]]]
        let content: [String: Any] = ["application/json": ["schema": body]]
        return try JSONSerialization.data(withJSONObject: ["openapi": "3.0.3", "info": ["title": "Bounded challenge", "version": "1"],
            "paths": ["/proof": ["post": ["operationId": "proof", "requestBody": ["required": true, "content": content],
                "responses": ["200": ["description": "Accepted", "content": content]]]]]])
    }

    func testOpenAPIPreservesActualProviderPatternInDiscoveredContract() throws {
        let reflector = try OpenAPIReflector(specificationData: specification(), baseURL: URL(string: "https://api.example")!)
        let action = try XCTUnwrap(reflector.capabilities(for: ContentParser.parse("proof")).first { $0.metadata["operationId"] == "proof" })
        let raw = try XCTUnwrap(action.metadata["argumentsSchema"])
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["challenge"] as? [String: Any])?["pattern"] as? String, challenge["pattern"] as? String)
    }

    func testOpenAPIRejectsInvalidValueBeforeTransport() throws {
        var transportCalls = 0
        OpenAPIReflectorTests.StubURLProtocol.handler = { _ in
            transportCalls += 1; throw RightClickError("Invalid arguments must not reach transport")
        }
        defer { OpenAPIReflectorTests.StubURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAPIReflectorTests.StubURLProtocol.self]
        let reflector = try OpenAPIReflector(specificationData: specification(), baseURL: URL(string: "https://api.example")!,
            session: URLSession(configuration: configuration))
        let engine = CapabilityEngine(reflectors: [reflector])
        let action = try XCTUnwrap(engine.capabilities(for: "proof").capabilities.first { $0.metadata["operationId"] == "proof" })
        for challenge in ["x", "abcdefgh/", String(repeating: "a", count: 129)] {
            let record = try engine.begin(id: action.id, item: "proof", confirmed: true, arguments: ["challenge": challenge])
            XCTAssertEqual(record.state, .failed)
            XCTAssertEqual(record.evidence.type, "input_contract_failure")
        }
        XCTAssertEqual(transportCalls, 0)
    }

    func testOpenAPIOmitsUnsupportedPatternRatherThanErasingIt() throws {
        let reflector = try OpenAPIReflector(specificationData: specification(pattern: "^(a+)+$"), baseURL: URL(string: "https://api.example")!)
        XCTAssertFalse(try reflector.capabilities(for: ContentParser.parse("proof")).contains { $0.metadata["operationId"] == "proof" })
    }
}
