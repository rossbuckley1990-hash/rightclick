#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityABIAdapterTests: XCTestCase {
    private func capability(_ substrate: String) -> Capability {
        Capability(id: "cap:\(substrate)", title: "Example", source: .system,
                   reflectorID: "reflector:\(substrate)", provider: .init(name: "Example"),
                   safety: .unknown, invocation: .direct, supportLevel: .experimental,
                   requiresConfirmation: true, metadata: ["substrate": substrate, "providerIdentity": "provider"])
    }

    func testGenericAdapterPreservesDeclarationsAndDoesNotMutateCapability() throws {
        for substrate in ["openapi", "graphql", "grpc", "macos.service", "federation"] {
            let original = capability(substrate)
            let before = original
            let contract = try original.abiContract()
            XCTAssertEqual(original, before)
            XCTAssertEqual(contract.capabilityID, original.id)
            XCTAssertEqual(contract.reflectorID, original.reflectorID)
            XCTAssertEqual(contract.providerID, "provider")
            XCTAssertThrowsError(try contract.validateArguments(.object([:])))
        }
    }

    func testUnownedCapabilitiesCannotAcquireAnABIIdentity() {
        var value = capability("openapi")
        value.reflectorID = "unowned"
        XCTAssertThrowsError(try value.abiContract())
    }

    func testChangesInAuthorityOrPolicyMetadataChangeFingerprint() throws {
        var value = capability("openapi")
        let first = try value.abiContract().sha256()
        value.metadata["authorityOrigin"] = "https://example.invalid"
        let second = try value.abiContract().sha256()
        XCTAssertNotEqual(first, second)
        value.requiresConfirmation = false
        XCTAssertNotEqual(second, try value.abiContract().sha256())
    }

    func testSHA256MatchesCanonicalBytesAndHasNoSignatureSemantics() throws {
        let contract = try capability("openapi").abiContract(arguments: .object(properties: ["title": .string], required: ["title"]))
        try contract.validateArguments(.object(["title": .string("example")]))
        let expected = SHA256.hash(data: try contract.canonicalData()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try contract.sha256(), expected)
        XCTAssertEqual(expected.count, 64)
    }
}
