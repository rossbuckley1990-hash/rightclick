import XCTest
@testable import RightClickCore

final class CapabilityArgumentPreflightTests: XCTestCase {
    private func check(_ schema: String? = semanticClosedSchema, _ arguments: [String: String]? = nil) -> CapabilityPreflightIssue? {
        CapabilityArgumentPreflight.issue(for: semanticFixture(schema: schema), arguments: arguments)
    }
    func testMissingRequiredArgumentsDetectedBeforeApproval() {
        XCTAssertEqual(check()?.code, "missing_required_arguments")
    }
    func testPartialArgumentsFail() {
        XCTAssertEqual(check(semanticClosedSchema, ["owner": "demo"])?.code, "missing_required_arguments")
    }
    func testUnexpectedArgumentsFail() {
        XCTAssertEqual(check(semanticClosedSchema, ["owner": "demo", "report": "r", "extra": "x"])?.code, "unexpected_arguments")
    }
    func testCompleteEnvelopePasses() {
        XCTAssertNil(check(semanticClosedSchema, ["owner": "demo", "report": "r"]))
    }
    func testAbsentSchemaDelegatesToReflector() {
        XCTAssertNil(check(nil, ["custom": "custom-input"]))
    }
    func testAbsentSchemaDoesNotInventRequiredArguments() { XCTAssertNil(check(nil)) }
    func testMalformedJSONRejected() { XCTAssertEqual(check("{")?.code, "invalid_argument_schema") }
    func testNonObjectSchemaRejected() { XCTAssertEqual(check(#"{"type":"array"}"#)?.code, "invalid_argument_schema") }
    func testInvalidPropertiesRejected() { XCTAssertEqual(check(#"{"type":"object","properties":[]}"#)?.code, "invalid_argument_schema") }
    func testInvalidRequiredRejected() { XCTAssertEqual(check(#"{"type":"object","required":[1]}"#)?.code, "invalid_argument_schema") }
    func testRequiredDuplicateRejected() { XCTAssertEqual(check(#"{"type":"object","required":["x","x"]}"#)?.code, "invalid_argument_schema") }
    func testClosedRequiredNameOutsidePropertiesRejected() {
        XCTAssertEqual(check(#"{"type":"object","required":["x"],"additionalProperties":false}"#)?.code, "invalid_argument_schema")
    }
    func testOpenRequiredNameOutsidePropertiesIsLegal() {
        XCTAssertNil(check(#"{"type":"object","required":["x"]}"#, ["x": "value"]))
    }
    func testAdditionalPropertiesTrueAcceptsExtra() {
        XCTAssertNil(check(#"{"type":"object","additionalProperties":true}"#, ["x": "value"]))
    }
    func testAdditionalPropertiesSchemaDelegated() {
        XCTAssertNil(check(#"{"type":"object","additionalProperties":{"type":"string"}}"#, ["x": "value"]))
    }
    func testNumericZeroIsNotBooleanFalse() {
        XCTAssertEqual(check(#"{"type":"object","additionalProperties":0}"#)?.code, "invalid_argument_schema")
    }
    func testOversizedSchemaRejected() {
        XCTAssertEqual(check(String(repeating: " ", count: CapabilityArgumentPreflight.maximumSchemaBytes + 1))?.code, "invalid_argument_schema")
    }
    func testRequiredNamesComparedAsBytes() {
        let schema = "{\"type\":\"object\",\"properties\":{\"caf\u{e9}\":{\"type\":\"string\"}},\"required\":[\"caf\u{e9}\"],\"additionalProperties\":false}"
        XCTAssertEqual(check(schema, ["cafe\u{301}": "value"])?.code, "missing_required_arguments")
    }
    func testEmptyEnvelopeDoesNotAssertTransportWillAcceptNil() {
        XCTAssertNil(check(#"{"type":"object","additionalProperties":false}"#))
    }
    func testNestedValueValidationRemainsWithSubstrate() {
        let schema = #"{"type":"object","properties":{"input":{"type":"string"}},"required":["input"],"additionalProperties":false}"#
        XCTAssertNil(check(schema, ["input": "not a JSON object"]))
    }
    func testArgumentValuesAreNeverEchoedInError() {
        let issue = check(semanticClosedSchema, ["owner": "SECRET_SENTINEL_001"])
        XCTAssertFalse(issue?.message.contains("SECRET_SENTINEL_001") ?? true)
    }
}
