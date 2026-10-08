import Foundation
import MCP
import XCTest
@testable import RightClickMCP

final class MCPInitializationCompatibilityTests: XCTestCase {
    // Captured from the actual Codex 0.159.3 MCP handshake, not a made-up schema.
    let captured = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.159.3"}}}"#.utf8)
    func testRealClientObjectExtensionDoesNotPreventSupportedHandshake() throws {
        let normalized = ModernMCPStdioTransport.sdkCompatibleMessage(captured)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let decoded = try JSONDecoder().decode(Initialize.Parameters.self,
            from: JSONSerialization.data(withJSONObject: params))
        XCTAssertEqual(decoded.protocolVersion, "2025-06-18")
        XCTAssertEqual(decoded.clientInfo.name, "codex-mcp-client")
        XCTAssertNotNil(decoded.capabilities.elicitation?.form)
        XCTAssertNotNil(decoded.capabilities.elicitation?.url)
        XCTAssertNil(decoded.capabilities.experimental)
        XCTAssertEqual(object["id"] as? Int, 0)
    }
    func testOtherMessagesAndMalformedCapabilityShapesAreNotRewritten() {
        let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"context_runtime","arguments":{"experimental":{"opaque":{}}}}}"#.utf8)
        let malformed = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#.utf8)
        XCTAssertEqual(ModernMCPStdioTransport.sdkCompatibleMessage(call), call)
        XCTAssertEqual(ModernMCPStdioTransport.sdkCompatibleMessage(malformed), malformed)
    }
}
