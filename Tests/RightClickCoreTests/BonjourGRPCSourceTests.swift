import Foundation
import XCTest

@testable import RightClickCore

final class BonjourGRPCSourceTests:
    XCTestCase
{
    private let fixtureBase64 =
        "CgpkZW1vLnByb3RvEgRkZW1vIisKDEhlbGxvUmVxdWVzdBIMCgRuYW1lGAEgASgJEg0KBWNvdW50GAIgASgFIh0KCkhlbGxvUmVwbHkSDwoHbWVzc2FnZRgBIAEoCTJsCgdHcmVldGVyEjAKCFNheUhlbGxvEhIuZGVtby5IZWxsb1JlcXVlc3QaEC5kZW1vLkhlbGxvUmVwbHkSLwoFV2F0Y2gSEi5kZW1vLkhlbGxvUmVxdWVzdBoQLmRlbW8uSGVsbG9SZXBseTABYgZwcm90bzM="

    private func fixture()
        throws -> Data
    {
        try XCTUnwrap(
            Data(
                base64Encoded:
                    fixtureBase64
            )
        )
    }

    func testResolvedAdvertisementCreatesAndRemovesGRPCReflector()
        throws
    {
        var loadedEndpoints:
            [GRPCEndpoint] = []

        let source =
            BonjourGRPCSource(
                startBrowsing:
                    false,
                reflectionLoader: {
                    endpoint in

                    loadedEndpoints
                        .append(
                            endpoint
                        )

                    return [
                        try self.fixture()
                    ]
                },
                unaryInvoker: {
                    _,
                    _,
                    _ in

                    XCTFail(
                        "Discovery must not invoke an RPC."
                    )

                    return Data()
                }
            )

        source.update(
            resolved:
                BonjourGRPCServiceDescriptor(
                    instanceName:
                        "Demo gRPC",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "DEMO.LOCAL.",
                    port:
                        50051,
                    txt: [
                        "kind":
                            "grpc",
                        "scheme":
                            "grpc",
                    ]
                )
        )

        XCTAssertEqual(
            loadedEndpoints,
            [
                try GRPCEndpoint(
                    scheme:
                        "grpc",
                    host:
                        "demo.local",
                    port:
                        50051
                )
            ]
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "Say hello"
                )
                .capabilities
                .contains {
                    $0.metadata[
                        "rpcPath"
                    ] ==
                        "/demo.Greeter/SayHello"
                }
        )

        XCTAssertEqual(
            engine
                .providers()
                .first {
                    $0.source
                        == "grpc"
                }?
                .name,
            "Demo gRPC"
        )

        source.remove(
            instanceName:
                "Demo gRPC",
            domain:
                "local."
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }

    func testUnsupportedAuthorityAdvertisementFailsClosedBeforeReflection()
        throws
    {
        var loaderCalled =
            false

        let source =
            BonjourGRPCSource(
                startBrowsing:
                    false,
                reflectionLoader: {
                    _ in

                    loaderCalled =
                        true

                    return [
                        try self.fixture()
                    ]
                },
                unaryInvoker: {
                    _,
                    _,
                    _ in

                    Data()
                }
            )

        source.update(
            resolved:
                BonjourGRPCServiceDescriptor(
                    instanceName:
                        "Protected gRPC",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "protected.local.",
                    port:
                        443,
                    txt: [
                        "kind":
                            "grpc",
                        "scheme":
                            "grpcs",
                        "auth-scheme":
                            "BearerAuth",
                    ]
                )
        )

        XCTAssertFalse(
            loaderCalled
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }

    func testMalformedSchemeAbstainsWithoutReflection()
        throws
    {
        var loaderCalled =
            false

        let source =
            BonjourGRPCSource(
                startBrowsing:
                    false,
                reflectionLoader: {
                    _ in

                    loaderCalled =
                        true

                    return [
                        try self.fixture()
                    ]
                },
                unaryInvoker: {
                    _,
                    _,
                    _ in

                    Data()
                }
            )

        source.update(
            resolved:
                BonjourGRPCServiceDescriptor(
                    instanceName:
                        "Bad gRPC",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "bad.local.",
                    port:
                        50051,
                    txt: [
                        "kind":
                            "grpc",
                        "scheme":
                            "http",
                    ]
                )
        )

        XCTAssertFalse(
            loaderCalled
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }
}
