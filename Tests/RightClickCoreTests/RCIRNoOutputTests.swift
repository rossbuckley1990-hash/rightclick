import Foundation
import XCTest
@testable import RightClickCore

final class RCIRNoOutputTests: XCTestCase {
    func testExactUnchangedWindowsDeclarationAcquiresAcknowledgementCapability() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WindowsActualAcknowledgementDeclaration.json")
        let reflector = try OpenAPIReflector(specificationData: Data(contentsOf: fixture),
            baseURL: URL(string: "https://parks-ccd-its-josh.trycloudflare.com")!)
        let capability = try XCTUnwrap(reflector.capabilities(for: ContentParser.parse("windows proof")).first { $0.metadata["operationId"] == "hostWriteProof" })
        XCTAssertEqual(capability.output, [])
        XCTAssertEqual(capability.metadata["resultValidation"], "no_declared_output")
        XCTAssertEqual(capability.metadata["acknowledgementStatuses"], "202")
        XCTAssertTrue(capability.requiresConfirmation)
        XCTAssertEqual(capability.metadata["authorityRequired"], "true")
        let arguments = try XCTUnwrap(capability.metadata["argumentsSchema"])
        XCTAssertTrue(arguments.contains("^[A-Za-z0-9_-]{8,128}$"))
    }

    func testUnknownOrUndeclaredOutputCannotBeRecategorizedAsAcknowledgement() throws {
        func actions(_ responses: [String: Any]) throws -> [Capability] {
            let spec: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Unknown output", "version": "1"],
                "paths": ["/read": ["get": ["operationId": "read", "responses": responses]]]]
            let reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec), baseURL: URL(string: "https://api.example")!)
            return try reflector.capabilities(for: ContentParser.parse("read"))
        }
        for responses: [String: Any] in [[:], ["default": ["description": "Unknown"]], ["202": ["$ref": "#/components/responses/Accepted"]],
            ["202": ["description": "Unknown", "content": ["application/json": [:]]]], ["202": ["description": "Unknown", "content": "malformed"]]] {
            XCTAssertTrue(try actions(responses).isEmpty)
        }
        let declared: [String: Any] = ["description": "Typed", "content": ["application/json": ["schema": ["type": "integer"]]]]
        let mixed = try actions(["200": declared, "202": ["description": "Accepted"]])
        XCTAssertFalse(mixed.contains { $0.metadata["resultValidation"] == "no_declared_output" })
    }

    func testInheritedSecurityUsesStrictSchemeResolutionAndOperationOverrides() throws {
        func actions(rootSecurity: Any, operationSecurity: Any? = nil) throws -> [Capability] {
            var operation: [String: Any] = ["operationId": "read", "responses": ["204": ["description": "Acknowledged"]]]
            if let operationSecurity { operation["security"] = operationSecurity }
            let spec: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Inherited bearer", "version": "1"],
                "security": rootSecurity, "components": ["securitySchemes": ["Bearer": ["type": "http", "scheme": "bearer"],
                    "Other": ["type": "http", "scheme": "bearer"]]], "paths": ["/read": ["get": operation]]]
            let reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec),
                baseURL: URL(string: "https://api.example")!, externalBearerSchemeName: "never-bypass-declared-security")
            return try reflector.capabilities(for: ContentParser.parse("read"))
        }
        let inherited = try XCTUnwrap(actions(rootSecurity: [["Bearer": []]]).first)
        XCTAssertEqual(inherited.metadata["authorityRequired"], "true")
        XCTAssertEqual(inherited.metadata["authorityScheme"], "Bearer")
        let explicitPublic = try XCTUnwrap(actions(rootSecurity: [["Bearer": []]], operationSecurity: []).first)
        XCTAssertNil(explicitPublic.metadata["authorityRequired"])
        XCTAssertNil(try XCTUnwrap(actions(rootSecurity: []).first).metadata["authorityRequired"])
        let override = try XCTUnwrap(actions(rootSecurity: NSNull(), operationSecurity: [["Bearer": []]]).first)
        XCTAssertEqual(override.metadata["authorityRequired"], "true")
        for invalid: Any in [NSNull(), "malformed", [["Unknown": []]], [["Bearer": ["wrong-scope"]]],
            [["Bearer": [], "Other": []]], [["Bearer": []], ["Other": []]], [[:]]] {
            XCTAssertTrue(try actions(rootSecurity: invalid).isEmpty)
            XCTAssertTrue(try actions(rootSecurity: [["Bearer": []]], operationSecurity: invalid).isEmpty)
        }
    }
}
