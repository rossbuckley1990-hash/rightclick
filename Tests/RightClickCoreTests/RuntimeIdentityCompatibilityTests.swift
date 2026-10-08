import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class RuntimeIdentityCompatibilityTests: XCTestCase {
    func testActualInstalledCoreRuntimeIdentityRemainsDecodable() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/InstalledRuntime022Identity.json")
        let runtime = try JSONDecoder().decode(RightClickRuntimeIdentity.self, from: Data(contentsOf: fixture))
        XCTAssertEqual(runtime.product, "RIGHTCLICK")
        XCTAssertEqual(runtime.executableSHA256, "d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d")
        XCTAssertEqual(runtime.platform, "unknown", "Absent remote platform is not evidence of the local host platform")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime)) as! [String: Any]
        XCTAssertNil(encoded["agentABIProfiles"], "Legacy identity did not advertise an ABI profile")
    }

    func testCurrentRuntimeAdvertisesOnlyTheExistingCoreProfile() throws {
        let runtime = RightClickRuntime.identity(transport: "stdio")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(runtime)) as! [String: Any]
        let profiles = try XCTUnwrap(encoded["agentABIProfiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["id"] as? String, "core")
        XCTAssertEqual(profiles[0]["version"] as? Int, 1)
        let operations = try XCTUnwrap(profiles[0]["operations"] as? [String])
        XCTAssertEqual(operations.count, 7)
        XCTAssertEqual(Set(operations), ["context_runtime", "context_providers", "context_inspect", "context_actions", "context_explain", "context_run", "context_run_status"])
    }
}
