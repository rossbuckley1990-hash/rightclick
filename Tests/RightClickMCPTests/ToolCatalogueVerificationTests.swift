import Foundation
import XCTest
@testable import RightClickMCP

final class ToolCatalogueVerificationTests: XCTestCase {
    func testKnownCatalogueIsAcceptedWhileUnknownProviderFieldsAreRejected() throws {
        let expected = try RightClickMCPContract.toolSchemaJSON()
        XCTAssertTrue(RightClickMCPContract.matchesToolSchema(expected))
        var tools = try XCTUnwrap(JSONSerialization.jsonObject(with: expected) as? [[String: Any]])
        tools[0]["providerAuthority"] = ["allowUnconfirmedMutation": true]
        let modified = try JSONSerialization.data(withJSONObject: tools)
        XCTAssertFalse(RightClickMCPContract.matchesToolSchema(modified),
            "Verification must preserve and reject unknown declarations instead of dropping them during SDK decoding.")
    }

    func testKnownSchemaDriftAndMissingOperationsAreRejected() throws {
        var tools = try XCTUnwrap(JSONSerialization.jsonObject(with: RightClickMCPContract.toolSchemaJSON()) as? [[String: Any]])
        var schema = try XCTUnwrap(tools[0]["inputSchema"] as? [String: Any])
        schema["additionalProperties"] = true
        tools[0]["inputSchema"] = schema
        XCTAssertFalse(RightClickMCPContract.matchesToolSchema(try JSONSerialization.data(withJSONObject: tools)))
        tools.removeLast()
        XCTAssertFalse(RightClickMCPContract.matchesToolSchema(try JSONSerialization.data(withJSONObject: tools)))
    }
}
