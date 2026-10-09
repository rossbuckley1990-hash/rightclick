@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class UniversalReflectorContractTests: XCTestCase {
    final class ProbeReflector: CapabilityReflector {
        let id: String
        let actionID: String
        let returnedText: String

        private(set) var beginCalls = 0

        init(
            id: String,
            actionID: String,
            returnedText: String
        ) {
            self.id = id
            self.actionID = actionID
            self.returnedText = returnedText
        }

        func capabilities(
            for item: ContentItem
        ) throws -> [Capability] {
            guard item.text != nil else {
                return []
            }

            return [
                Capability(
                    id: actionID,
                    title: "Probe capability",
                    source: .system,
                    reflectorID: id,
                    provider: CapabilityProvider(
                        name: "Probe provider",
                        bundleIdentifier: nil
                    ),
                    inputs: ["public.plain-text"],
                    output: ["public.plain-text"],
                    safety: .unknown,
                    invocation: .direct,
                    supportLevel: .experimental,
                    requiresConfirmation: true
                )
            ]
        }

        func providers() -> [ProviderSummary] {
            []
        }

        func begin(
            capability: Capability,
            item: ContentItem,
            executionID: String
        ) throws -> ExecutionRecord {
            beginCalls += 1

            return ExecutionRecord(
                executionId: executionID,
                actionId: capability.id,
                title: capability.title,
                state: .accepted,
                message: "Synthetic provider accepted invocation.",
                output: returnedText,
                evidence: OutcomeEvidence(
                    type: "provider_acceptance",
                    boundary: "Synthetic reflector provider boundary.",
                    outcomeVerified: false
                )
            )
        }
    }

    func testEngineRoutesByReflectorOwnershipNotCapabilitySource() throws {
        let first = ProbeReflector(
            id: "probe.first",
            actionID: "probe:first",
            returnedText: "FIRST"
        )

        let second = ProbeReflector(
            id: "probe.second",
            actionID: "probe:second",
            returnedText: "SECOND"
        )

        let engine = CapabilityEngine(
            reflectors: [first, second]
        )

        let discovered = try engine.capabilities(
            for: "hello"
        ).capabilities

        XCTAssertEqual(
            Set(discovered.map(\.reflectorID)),
            Set(["probe.first", "probe.second"])
        )

        let result = try engine.run(
            id: "probe:second",
            item: "hello",
            confirmed: true
        )

        XCTAssertEqual(first.beginCalls, 0)
        XCTAssertEqual(second.beginCalls, 1)

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertFalse(
            result.evidence.outcomeVerified
        )
    }

    func testGenericVerificationRemainsAboveReflectorBoundary() throws {
        let reflector = ProbeReflector(
            id: "probe.verification",
            actionID: "probe:uppercase",
            returnedText: "HELLO"
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        let result = try engine.run(
            id: "probe:uppercase",
            item: "hello",
            confirmed: true,
            verification: VerificationSpec(
                predicates: [
                    VerificationPredicate(
                        type: .textEquals,
                        value: "HELLO"
                    )
                ]
            )
        )

        XCTAssertEqual(
            reflector.beginCalls,
            1
        )

        XCTAssertEqual(
            result.status,
            .verified
        )

        XCTAssertEqual(
            result.verification?.status,
            .verifiedSuccess
        )

        XCTAssertTrue(
            result.evidence.outcomeVerified
        )
    }

    func testRemovingReflectorRemovesCapability() throws {
        let reflector = ProbeReflector(
            id: "probe.removable",
            actionID: "probe:temporary",
            returnedText: "OK"
        )

        let withReflector = CapabilityEngine(
            reflectors: [reflector]
        )

        XCTAssertTrue(
            try withReflector
                .capabilities(for: "hello")
                .capabilities
                .contains(where: {
                    $0.id == "probe:temporary"
                })
        )

        let withoutReflector = CapabilityEngine(
            reflectors: []
        )

        let result = try withoutReflector.run(
            id: "probe:temporary",
            item: "hello",
            confirmed: true
        )

        XCTAssertEqual(
            result.status,
            .unavailable
        )
    }
}
