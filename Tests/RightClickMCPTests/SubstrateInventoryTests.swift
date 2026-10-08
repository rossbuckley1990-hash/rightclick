import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore
@testable import RightClickMCP
#if os(macOS)
import RightClickMacOS
#endif

/// This exercises the factories actually consumed by runtime composition. A
/// declaration file alone cannot satisfy the registered-substrate contract.
final class SubstrateInventoryTests: XCTestCase {
    private struct Contract: Decodable {
        struct Family: Decodable {
            let family: String
            let compilerKinds: [String]?
            let actualReflectorIDs: [String]?
        }
        let schemaVersion: Int
        let requiredFamilies: [Family]
        let portableResolverKinds: [String]
        let linuxNativeAdditionalResolverKinds: [String]
        let sevenCanonicalOperations: [String]
    }
    func testRequiredSubstratesRemainRegisteredInActualRuntimeComposition() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: root.appendingPathComponent("docs/substrate-contract.json")))
        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(contract.requiredFamilies.count, 11)
        XCTAssertEqual(Set(contract.requiredFamilies.map(\.family)), Set(["macos", "openapi", "graphql", "grpc", "ard", "mcp", "a2a", "kafka", "kubernetes", "wasm", "dbus"]))
        let portable = CapabilityArtifactResolverDefaults.all()
        let portableKinds = portable.map(\.kind).sorted()
#if os(macOS) || os(Linux)
        XCTAssertEqual(portableKinds, contract.portableResolverKinds.sorted())
#endif
        XCTAssertEqual(portableKinds.count, Set(portableKinds).count)
        let native = CapabilityArtifactResolverRuntimeDefaults.all(environment: [:])
        let registry = CapabilityArtifactResolverRegistry(resolvers: native)
#if os(Linux)
        XCTAssertEqual(registry.supportedKinds, (contract.portableResolverKinds + contract.linuxNativeAdditionalResolverKinds).sorted())
#elseif os(macOS)
        XCTAssertEqual(registry.supportedKinds, contract.portableResolverKinds.sorted())
#endif
        XCTAssertEqual(DBusCapabilityArtifactResolver(transport: nil).kind, "dbus", "The generic D-Bus compiler remains portable")
        let registrations = CapabilityReflectorSourceDefaults.registrations(registry: registry) + RightClickMCPRuntime.sourceRegistrations()
        let keys = registrations.map { $0.family + "/" + $0.role }
        XCTAssertEqual(keys.count, Set(keys).count)
        let artifactJSON = "[{\"id\":\"inventory-invalid-provider\",\"kind\":\"openapi\",\"inlineData\":\"e30=\",\"baseURL\":\"http://127.0.0.1:1\"}]"
        let environment = [ConfiguredCapabilityArtifactSource.environmentKey: artifactJSON,
            "RIGHTCLICK_A2A_PROVIDERS": "/unconfigured-inventory-reference",
            ARDRegistrySource.environmentKey: "[{\"id\":\"inventory-registry\",\"searchURL\":\"https://example.invalid/search\"}]",
            FederationPeerConfiguration.environmentKey: "[{\"id\":\"inventory-peer\",\"name\":\"Inventory peer\",\"endpoint\":\"http://127.0.0.1:1/mcp\",\"tokenEnvironment\":\"INVENTORY_TOKEN\"}]",
            "INVENTORY_TOKEN": "synthetic-fixture-value"]
        var sourceIDs: [String: String] = [:]
        for registration in registrations {
            let source = try XCTUnwrap(registration.make(environment: environment, startBrowsing: false), registration.family + "/" + registration.role)
            sourceIDs[registration.family + "/" + registration.role] = source.id
        }
        XCTAssertEqual(sourceIDs["a2a/configured_source"], "configured.a2a")
        XCTAssertEqual(sourceIDs["ard/configured_source"], "ard.registry")
        XCTAssertEqual(sourceIDs["generic_artifacts/configured_source"], "configured.capability-artifacts")
        XCTAssertEqual(sourceIDs["mcp/federation_peer_source"], "federation.mcp")
        XCTAssertEqual(sourceIDs["openapi/configured_source"], "configured.openapi")
#if os(macOS)
        let macIDs = RightClickMacOS.CapabilityReflectorDefaults.all().map(\.id).sorted()
        XCTAssertEqual(macIDs, contract.requiredFamilies.first { $0.family == "macos" }?.actualReflectorIDs?.sorted())
        XCTAssertNotNil(sourceIDs["openapi/bonjour_source"])
        XCTAssertNotNil(sourceIDs["graphql/bonjour_source"])
        XCTAssertNotNil(sourceIDs["grpc/bonjour_source"])
#elseif os(Linux)
        XCTAssertEqual(sourceIDs["dbus/native_session_source"], "linux.dbus-session")
#endif
        let names = RightClickMCPContract.toolNames()
        XCTAssertEqual(names.count, 7); XCTAssertEqual(names.sorted(), contract.sevenCanonicalOperations.sorted())
        if let path = ProcessInfo.processInfo.environment["RIGHTCLICK_SUBSTRATE_EVIDENCE"] {
            let evidence: [String: Any] = ["schemaVersion": 1, "families": contract.requiredFamilies.map(\.family),
                "portableCompilerKinds": portableKinds, "runtimeCompilerKinds": registry.supportedKinds,
                "sourceFactories": sourceIDs, "canonicalOperations": names, "platform": RuntimeEnvironment.current.operatingSystem.rawValue,
                "architecture": RuntimeEnvironment.current.architecture, "executed": false, "verified": false,
                "scope": "callable composition registration; genuine substrate acceptance is separate"]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
