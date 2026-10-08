@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class CapabilityArtifactResolverTests:
    XCTestCase
{
    private final class StubReflector:
        CapabilityReflector
    {
        let id: String

        init(
            id: String
        ) {
            self.id = id
        }

        func capabilities(
            for item: ContentItem
        ) throws -> [Capability] {
            [
                Capability(
                    id:
                        "stub:" + id,
                    title:
                        "Stub " + id,
                    source:
                        .system,
                    safety:
                        .read,
                    invocation:
                        .direct,
                    supportLevel:
                        .experimental,
                    requiresConfirmation:
                        false,
                    metadata: [
                        "substrate":
                            id
                    ]
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
                    "stub accepted"
            )
        }
    }

    private final class StubResolver:
        CapabilityArtifactResolver
    {
        let kind: String
        let reflectorID: String

        init(
            kind: String,
            reflectorID: String
        ) {
            self.kind = kind
            self.reflectorID =
                reflectorID
        }

        func resolve(
            _ descriptor:
                CapabilityArtifactDescriptor
        ) throws -> any CapabilityReflector {
            StubReflector(
                id:
                    reflectorID
            )
        }
    }

    func testDefaultRegistryAdvertisesGenericSubstrates() {
        let kinds =
            Set(
                CapabilityArtifactResolverRegistry()
                    .supportedKinds
            )

        XCTAssertTrue(
            kinds.contains(
                "openapi"
            )
        )

        XCTAssertTrue(
            kinds.contains(
                "graphql"
            )
        )

#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
        XCTAssertTrue(
            kinds.contains(
                "grpc"
            )
        )
#endif
    }

    func testRegistryRoutesByNormalizedKind() throws {
        let registry =
            CapabilityArtifactResolverRegistry(
                resolvers: [
                    StubResolver(
                        kind:
                            "openapi",
                        reflectorID:
                            "fixture.openapi"
                    ),
                    StubResolver(
                        kind:
                            "graphql",
                        reflectorID:
                            "fixture.graphql"
                    ),
                ]
            )

        let reflector =
            try registry.resolve(
                CapabilityArtifactDescriptor(
                    id:
                        "fixture",
                    kind:
                        " GraphQL "
                )
            )

        XCTAssertEqual(
            reflector.id,
            "fixture.graphql"
        )
    }

    func testRegistryAcceptsOpaqueARDURNIdentity() throws {
        let registry =
            CapabilityArtifactResolverRegistry(
                resolvers: [
                    StubResolver(
                        kind:
                            "openapi",
                        reflectorID:
                            "fixture.urn"
                    )
                ]
            )

        let reflector =
            try registry.resolve(
                CapabilityArtifactDescriptor(
                    id:
                        "urn:air:registry.example:api:durable-records",
                    kind:
                        "openapi"
                )
            )

        XCTAssertEqual(
            reflector.id,
            "fixture.urn"
        )
    }


    func testDuplicateResolverKindFailsClosed() {
        let registry =
            CapabilityArtifactResolverRegistry(
                resolvers: [
                    StubResolver(
                        kind:
                            "graphql",
                        reflectorID:
                            "fixture.a"
                    ),
                    StubResolver(
                        kind:
                            "GRAPHQL",
                        reflectorID:
                            "fixture.b"
                    ),
                ]
            )

        XCTAssertFalse(
            registry.supportedKinds
                .contains(
                    "graphql"
                )
        )

        XCTAssertThrowsError(
            try registry.resolve(
                CapabilityArtifactDescriptor(
                    id:
                        "fixture",
                    kind:
                        "graphql"
                )
            )
        )
    }

    func testConfiguredSourceComposesDifferentSubstratesIntoOneEngine() throws {
        let registry =
            CapabilityArtifactResolverRegistry(
                resolvers: [
                    StubResolver(
                        kind:
                            "openapi",
                        reflectorID:
                            "fixture.openapi"
                    ),
                    StubResolver(
                        kind:
                            "graphql",
                        reflectorID:
                            "fixture.graphql"
                    ),
                ]
            )

        let source =
            ConfiguredCapabilityArtifactSource(
                descriptors: [
                    CapabilityArtifactDescriptor(
                        id:
                            "a",
                        kind:
                            "openapi"
                    ),
                    CapabilityArtifactDescriptor(
                        id:
                            "b",
                        kind:
                            "graphql"
                    ),
                ],
                registry:
                    registry
            )

        let engine =
            CapabilityEngine(
                reflectors: [],
                reflectorSources: [
                    source
                ]
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        "universal capability test"
                )
                .capabilities

        XCTAssertEqual(
            Set(
                capabilities.map {
                    $0.metadata[
                        "substrate"
                    ] ?? ""
                }
            ),
            Set([
                "fixture.openapi",
                "fixture.graphql",
            ])
        )
    }

    func testConfiguredSourceCachesResolvedSnapshotWithinRefreshWindow() {
        final class CountingResolver:
            CapabilityArtifactResolver
        {
            let kind =
                "openapi"

            var calls =
                0

            func resolve(
                _ descriptor:
                    CapabilityArtifactDescriptor
            ) throws -> any CapabilityReflector {
                calls += 1

                return StubReflector(
                    id:
                        "fixture.cached"
                )
            }
        }

        let resolver =
            CountingResolver()

        let source =
            ConfiguredCapabilityArtifactSource(
                descriptors: [
                    CapabilityArtifactDescriptor(
                        id:
                            "cached",
                        kind:
                            "openapi"
                    )
                ],
                registry:
                    CapabilityArtifactResolverRegistry(
                        resolvers: [
                            resolver
                        ]
                    ),
                refreshInterval:
                    60
            )

        XCTAssertEqual(
            source.reflectors()
                .count,
            1
        )

        XCTAssertEqual(
            source.reflectors()
                .count,
            1
        )

        XCTAssertEqual(
            resolver.calls,
            1
        )
    }

    func testDuplicateConfiguredDescriptorIDsFailClosed() {
        let source =
            ConfiguredCapabilityArtifactSource(
                descriptors: [
                    CapabilityArtifactDescriptor(
                        id:
                            "duplicate",
                        kind:
                            "openapi"
                    ),
                    CapabilityArtifactDescriptor(
                        id:
                            "duplicate",
                        kind:
                            "graphql"
                    ),
                ],
                registry:
                    CapabilityArtifactResolverRegistry(
                        resolvers: [
                            StubResolver(
                                kind:
                                    "openapi",
                                reflectorID:
                                    "fixture.a"
                            ),
                            StubResolver(
                                kind:
                                    "graphql",
                                reflectorID:
                                    "fixture.b"
                            ),
                        ]
                    ),
                refreshInterval:
                    0
            )

        XCTAssertTrue(
            source.reflectors()
                .isEmpty
        )
    }

    func testConfiguredSourceDropsAmbiguousDuplicateReflectorIdentity() {
        let registry =
            CapabilityArtifactResolverRegistry(
                resolvers: [
                    StubResolver(
                        kind:
                            "openapi",
                        reflectorID:
                            "fixture.same"
                    ),
                    StubResolver(
                        kind:
                            "graphql",
                        reflectorID:
                            "fixture.same"
                    ),
                ]
            )

        let source =
            ConfiguredCapabilityArtifactSource(
                descriptors: [
                    CapabilityArtifactDescriptor(
                        id:
                            "a",
                        kind:
                            "openapi"
                    ),
                    CapabilityArtifactDescriptor(
                        id:
                            "b",
                        kind:
                            "graphql"
                    ),
                ],
                registry:
                    registry
            )

        XCTAssertTrue(
            source.reflectors()
                .isEmpty
        )
    }

    func testPlainHTTPIsLoopbackOnly() {
        XCTAssertNotNil(
            CapabilityArtifactURLPolicy
                .httpURL(
                    "http://localhost:8080/openapi.json"
                )
        )

        XCTAssertNil(
            CapabilityArtifactURLPolicy
                .httpURL(
                    "http://example.com/openapi.json"
                )
        )

        XCTAssertNotNil(
            CapabilityArtifactURLPolicy
                .httpURL(
                    "https://example.com/openapi.json"
                )
        )
    }

#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
    func testPlainGRPCIsLoopbackOnly() {
        XCTAssertNotNil(
            CapabilityArtifactURLPolicy
                .grpcEndpoint(
                    "grpc://127.0.0.1:50051"
                )
        )

        XCTAssertNil(
            CapabilityArtifactURLPolicy
                .grpcEndpoint(
                    "grpc://example.com:50051"
                )
        )

        XCTAssertNotNil(
            CapabilityArtifactURLPolicy
                .grpcEndpoint(
                    "grpcs://example.com:443"
                )
        )
    }
#endif
}
