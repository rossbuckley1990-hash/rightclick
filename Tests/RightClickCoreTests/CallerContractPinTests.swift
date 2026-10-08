import Foundation
import XCTest
@testable import RightClickCore

final class CallerContractPinTests: XCTestCase {
    private final class Probe: CapabilityReflector {
        let id = "caller-pin"
        var catalog: [Capability]
        var discoveryCalls = 0
        var providerCalls = 0
        init(_ catalog: [Capability]) { self.catalog = catalog }
        func capabilities(for item: ContentItem) throws -> [Capability] {
            discoveryCalls += 1
            return catalog
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            providerCalls += 1
            return ExecutionRecord(executionId: executionID, actionId: capability.id, state: .accepted,
                message: "Controlled provider accepted; independent outcome remains unverified.")
        }
    }

    private func capability() -> Capability {
        Capability(id: "caller-pin:record", title: "Record", source: .system, reflectorID: "provider-spoofed-owner",
            provider: .init(name: "Controlled"), inputs: ["text"], output: ["typed_value"], safety: .unknown,
            invocation: .direct, supportLevel: .experimental, requiresConfirmation: true,
            metadata: ["providerIdentity": "controlled-provider", "endpoint": "https://api.example/records",
                       "argumentSchema": "closed-schema-one", "effect": "write", "executionMode": "unary"])
    }

    func testReviewedContractDriftBeforeInvocationCannotDispatch() throws {
        for field in ["endpoint", "argumentSchema", "effect", "executionMode", "authorityOrigin", "policyEpoch"] {
            for asynchronous in [false, true] {
                let probe = Probe([capability()])
                let engine = CapabilityEngine(reflectors: [probe], experience: nil)
                let reviewed = try engine.describe(id: "Record", item: "context")
                let pin = try XCTUnwrap(reviewed.contractSHA256)
                probe.catalog[0].metadata[field] = "changed"
                if asynchronous {
                    let result = try engine.begin(id: reviewed.id, item: "context", confirmed: true, contractSHA256: pin)
                    XCTAssertEqual(result.state, .unavailable, field)
                    XCTAssertNil(result.rcir)
                } else {
                    let result = try engine.run(id: reviewed.id, item: "context", confirmed: true, contractSHA256: pin)
                    XCTAssertEqual(result.status, .unavailable, field)
                    XCTAssertNil(result.rcir)
                }
                XCTAssertEqual(probe.providerCalls, 0, field)
            }
        }
    }

    func testMalformedCorePinsFailBeforeDiscovery() throws {
        for pin in ["", "short", String(repeating: "A", count: 64), String(repeating: "f", count: 63), String(repeating: "0", count: 64) + "\n"] {
            let probe = Probe([capability()])
            let engine = CapabilityEngine(reflectors: [probe], experience: nil)
            XCTAssertEqual(try engine.begin(id: "Record", item: "context", confirmed: true, contractSHA256: pin).state, .rejected)
            XCTAssertEqual(try engine.run(id: "Record", item: "context", confirmed: true, contractSHA256: pin).status, .rejected)
            XCTAssertEqual(probe.discoveryCalls, 0)
            XCTAssertEqual(probe.providerCalls, 0)
        }
    }

    func testAliasAndFreshPinShareTheExactDeclaration() throws {
        let probe = Probe([capability()])
        let engine = CapabilityEngine(reflectors: [probe], experience: nil)
        let explained = try engine.describe(id: "Record", item: "context")
        let actions = try engine.capabilities(for: "context").capabilities
        let pin = try XCTUnwrap(explained.contractSHA256)
        XCTAssertEqual(actions.first?.contractSHA256, pin)
        XCTAssertEqual(CapabilityView(explained).contractSHA256, pin)
        XCTAssertEqual(try engine.run(id: explained.id, item: "context", confirmed: true, contractSHA256: pin).status, .accepted)
        XCTAssertEqual(try engine.begin(id: explained.title, item: "context", confirmed: true, contractSHA256: pin).state, .accepted)
        XCTAssertEqual(probe.providerCalls, 2)
    }

    func testConflictingTitleCannotChooseAnotherContractWithTheSamePin() throws {
        let probe = Probe([capability()])
        let engine = CapabilityEngine(reflectors: [probe], experience: nil)
        let reviewed = try engine.describe(id: "Record", item: "context")
        let pin = try XCTUnwrap(reviewed.contractSHA256)
        var other = capability()
        other.id = "caller-pin:another-record"
        probe.catalog.append(other)
        XCTAssertEqual(try engine.begin(id: "Record", item: "context", confirmed: true,
            contractSHA256: pin).state, .unavailable)
        XCTAssertEqual(probe.providerCalls, 0)
        XCTAssertEqual(try engine.begin(id: reviewed.id, item: "context", confirmed: true,
            contractSHA256: pin).state, .accepted)
    }

    func testAdvisoryExperienceAndComputedPinAreExcludedButPolicyBytesBind() throws {
        var original = capability()
        original.reflectorID = "caller-pin"
        let expected = try original.discoveryContractSHA256()
        let experience = CapabilityExperience(ledger: try CapabilityExperienceLedger(), namespace: "caller-pin")
        let existingExperienceKey = try XCTUnwrap(experience.contractKey(for: original))
        original.contractSHA256 = "provider-forged"
        original.metadata["experience.status"] = "provider-forged"
        original.metadata["experience.predicatesVerified"] = "99999"
        XCTAssertEqual(try original.discoveryContractSHA256(), expected)
        XCTAssertEqual(experience.contractKey(for: original), existingExperienceKey)
        original.metadata["policyEpoch"] = "changed"
        XCTAssertNotEqual(try original.discoveryContractSHA256(), expected)
    }

    func testProviderFingerprintCannotSpoofEngineAndAdvisoryDriftDoesNotInvalidateRun() throws {
        var original = capability()
        original.contractSHA256 = String(repeating: "0", count: 64)
        let probe = Probe([original])
        let engine = CapabilityEngine(reflectors: [probe], experience: nil)
        let reviewed = try engine.describe(id: original.id, item: "context")
        let pin = try XCTUnwrap(reviewed.contractSHA256)
        XCTAssertNotEqual(reviewed.contractSHA256, original.contractSHA256)
        XCTAssertEqual(reviewed.reflectorID, probe.id)
        probe.catalog[0].metadata["experience.status"] = "advice changed"
        probe.catalog[0].contractSHA256 = "another-forgery"
        XCTAssertEqual(try engine.begin(id: reviewed.id, item: "context", confirmed: true,
            contractSHA256: pin).state, .accepted)
        XCTAssertEqual(probe.providerCalls, 1)
    }

    func testExactUTF8PolicyBytesBindAndMetadataOrderingDoesNot() throws {
        var original = capability()
        original.reflectorID = "caller-pin"
        original.metadata["endpoint"] = "/caf\u{00e9}"
        let pin = try original.discoveryContractSHA256()
        original.metadata = Dictionary(uniqueKeysWithValues: original.metadata.sorted { $0.key > $1.key })
        XCTAssertEqual(try original.discoveryContractSHA256(), pin)
        original.metadata["endpoint"] = "/cafe\u{0301}"
        XCTAssertNotEqual(try original.discoveryContractSHA256(), pin)
    }

    func testMatchingPinDoesNotGrantConfirmationAndLegacyCallsRemainUnpinned() throws {
        let probe = Probe([capability()])
        let engine = CapabilityEngine(reflectors: [probe], experience: nil)
        let reviewed = try engine.describe(id: "Record", item: "context")
        let pin = try XCTUnwrap(reviewed.contractSHA256)
        XCTAssertEqual(try engine.begin(id: reviewed.id, item: "context", confirmed: false,
            contractSHA256: pin).state, .awaitingUser)
        XCTAssertEqual(probe.providerCalls, 0)
        probe.catalog[0].metadata["endpoint"] = "https://api.example/replacement"
        XCTAssertEqual(try engine.begin(id: reviewed.id, item: "context", confirmed: true).state, .accepted)
        XCTAssertEqual(probe.providerCalls, 1)
    }
}
