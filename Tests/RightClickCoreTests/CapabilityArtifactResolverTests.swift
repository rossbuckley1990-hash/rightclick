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
