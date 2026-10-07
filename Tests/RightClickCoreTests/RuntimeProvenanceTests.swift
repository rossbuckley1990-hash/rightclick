import Foundation
import XCTest
@testable import RightClickCore

final class RuntimeProvenanceTests: XCTestCase {
    func testLegacyRemoteIdentityDoesNotInheritLocalBuildFacts() throws {
        let bytes = Data(#"{"product":"RIGHTCLICK","version":"0.2.2","executablePath":"/remote/rightclick","executableRealPath":"/remote/bin","executableSHA256":"remote-digest","pid":1,"transport":"stdio"}"#.utf8)
        let identity = try JSONDecoder().decode(RightClickRuntimeIdentity.self, from: bytes)
        XCTAssertEqual(identity.platform, "unknown")
        XCTAssertEqual(identity.channel, "unverified")
        XCTAssertNil(identity.gitCommit)
        XCTAssertNil(identity.sourceRepository)
        XCTAssertNil(identity.buildSHA256)
        XCTAssertNil(identity.capabilityABIVersion)
    }

    func testCurrentIdentityMeasuresBytesAndNamesVersionedContracts() throws {
        let identity = RightClickRuntime.identity(transport: "test")
        XCTAssertEqual(identity.executableMeasurement, "startup-file-bytes")
        XCTAssertEqual(identity.buildSHA256, identity.executableSHA256)
        XCTAssertEqual(identity.capabilityABIVersion, 1)
        XCTAssertEqual(identity.contractSchemaVersion, CapabilityContract.version)
        XCTAssertEqual(identity.mcpSchemaVersion, 1)
        XCTAssertEqual(identity.agentABIProfiles?.first?.operations.count, 7)
        XCTAssertEqual(identity.channel, RightClickBuildProvenance.channel)
    }
}
