@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class CapabilityReflectorSourceTests:
    XCTestCase
{
    final class ProbeReflector:
        CapabilityReflector
    {
        let id: String
        let capabilityID: String

        private(set) var beginCalls = 0

        init(
            id: String,
            capabilityID: String
        ) {
            self.id = id
            self.capabilityID = capabilityID
        }

        func capabilities(
            for item: ContentItem
        ) throws -> [Capability] {
            guard item.text != nil else {
                return []
            }

            return [
                Capability(
                    id: capabilityID,
                    title:
                        "Dynamically acquired capability",
                    source: .system,
                    reflectorID: id,
                    provider:
                        CapabilityProvider(
                            name:
                                "Dynamic provider"
                        ),
                    inputs: [
                        "public.plain-text"
                    ],
                    output: [
                        "public.plain-text"
                    ],
                    safety: .unknown,
                    invocation: .direct,
                    supportLevel: .experimental,
                    requiresConfirmation: true
                )
            ]
        }

        func providers()
            -> [ProviderSummary]
        {
            [
                ProviderSummary(
                    name:
                        "Dynamic provider",
                    bundleIdentifier:
                        nil,
                    source:
                        "probe",
                    capabilityTitles: [
                        "Dynamically acquired capability"
                    ]
                )
            ]
        }

        func begin(
            capability: Capability,
            item: ContentItem,
            executionID: String
        ) throws -> ExecutionRecord {
            beginCalls += 1

            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .accepted,
                message:
                    "Dynamic reflector accepted.",
                output:
                    item.text?.uppercased(),
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_acceptance",
                        boundary:
                            "Synthetic dynamic reflector provider boundary.",
                        outcomeVerified:
                            false
                    )
            )
        }
    }

    final class MutableSource:
        CapabilityReflectorSource
    {
        let id = "probe.source"

        var current:
            [any CapabilityReflector] = []

        func reflectors()
            -> [any CapabilityReflector]
        {
            current
        }
    }

    func testSameEngineGainsAndLosesDynamicReflector()
        throws
    {
        let source =
            MutableSource()

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .isEmpty
        )

        let reflector =
            ProbeReflector(
                id:
                    "probe.dynamic",
                capabilityID:
                    "probe:dynamic"
            )

        source.current = [
            reflector
        ]

        let appeared =
            try engine.capabilities(
                for: "hello"
            )

        XCTAssertEqual(
            appeared
                .capabilities
                .map(\.id),
            [
                "probe:dynamic"
            ]
        )

        source.current = []

        XCTAssertTrue(
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .isEmpty
        )

        let stale =
            try engine.run(
                id:
                    "probe:dynamic",
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            stale.status,
            .unavailable
        )

        XCTAssertEqual(
            reflector.beginCalls,
            0
        )
    }

    func testDynamicSourceStillUsesReflectorOwnershipForExecution()
        throws
    {
        let source =
            MutableSource()

        let first =
            ProbeReflector(
                id:
                    "probe.first",
                capabilityID:
                    "probe:first"
            )

        let second =
            ProbeReflector(
                id:
                    "probe.second",
                capabilityID:
                    "probe:second"
            )

        source.current = [
            first,
            second
        ]

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let result =
            try engine.run(
                id:
                    "probe:second",
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            first.beginCalls,
            0
        )

        XCTAssertEqual(
            second.beginCalls,
            1
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertFalse(
            result
                .evidence
                .outcomeVerified
        )
    }

    func testDynamicSourceUsesExistingGenericVerifier()
        throws
    {
        let source =
            MutableSource()

        let reflector =
            ProbeReflector(
                id:
                    "probe.verified",
                capabilityID:
                    "probe:verified"
            )

        source.current = [
            reflector
        ]

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let result =
            try engine.run(
                id:
                    "probe:verified",
                item:
                    "hello",
                confirmed:
                    true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "HELLO"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            result.status,
            .verified
        )

        XCTAssertEqual(
            result
                .verification?
                .status,
            .verifiedSuccess
        )

        XCTAssertTrue(
            result
                .evidence
                .outcomeVerified
        )
    }
}
