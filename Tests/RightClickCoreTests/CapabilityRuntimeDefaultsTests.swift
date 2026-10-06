import XCTest
@testable import RightClickCore

final class CapabilityRuntimeDefaultsTests:
    XCTestCase
{
    final class ProbeReflector:
        CapabilityReflector
    {
        let id =
            "runtime.probe.reflector"

        func capabilities(
            for item: ContentItem
        ) throws -> [Capability] {
            guard item.text != nil else {
                return []
            }

            return [
                Capability(
                    id:
                        "runtime:probe",
                    title:
                        "Runtime default probe",
                    source:
                        .system,
                    reflectorID:
                        id,
                    provider:
                        CapabilityProvider(
                            name:
                                "Runtime probe"
                        ),
                    inputs: [
                        "public.plain-text"
                    ],
                    output: [
                        "public.plain-text"
                    ],
                    safety:
                        .unknown,
                    invocation:
                        .direct,
                    supportLevel:
                        .experimental,
                    requiresConfirmation:
                        true
                )
            ]
        }

        func begin(
            capability: Capability,
            item: ContentItem,
            executionID: String
        ) throws -> ExecutionRecord {
            ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .accepted,
                message:
                    "Runtime probe accepted.",
                output:
                    item.text
            )
        }
    }

    final class ProbeSource:
        CapabilityReflectorSource
    {
        let id =
            "runtime.probe.source"

        var current:
            [any CapabilityReflector] = []

        func reflectors()
            -> [any CapabilityReflector]
        {
            current
        }
    }

    func testDefaultSourceRegistryContainsBonjourOpenAPISource()
        throws
    {
        let sources =
            CapabilityReflectorSourceDefaults
                .all(
                    startBrowsing:
                        false
                )

        let sourceIDs =
            Set(
                sources.map {
                    $0.id
                }
            )

        XCTAssertEqual(
            sources.count,
            3
        )

        XCTAssertEqual(
            sourceIDs,
            Set([
                "bonjour.graphql",
                "bonjour.openapi",
                "configured.openapi",
            ])
        )

        XCTAssertTrue(
            sources.contains {
                $0 is BonjourOpenAPISource
            }
        )

        XCTAssertTrue(
            sources.contains {
                $0 is BonjourGraphQLSource
            }
        )
    }

    func testRuntimeDefaultsConsumeLiveSuppliedSource()
        throws
    {
        let source =
            ProbeSource()

        let engine =
            CapabilityRuntimeDefaults
                .makeEngine(
                    reflectorSources: [
                        source
                    ]
                )

        XCTAssertFalse(
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .contains {
                    $0.id
                        == "runtime:probe"
                }
        )

        source.current = [
            ProbeReflector()
        ]

        XCTAssertTrue(
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .contains {
                    $0.id
                        == "runtime:probe"
                }
        )

        source.current = []

        XCTAssertFalse(
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .contains {
                    $0.id
                        == "runtime:probe"
                }
        )
    }
}
