import Foundation
import XCTest

@testable import RightClickCore

final class GRPCRealProviderAcceptanceTests:
    XCTestCase
{
    private func environment(
        _ key: String
    ) throws -> String {
        guard
            let value =
                ProcessInfo
                    .processInfo
                    .environment[
                        key
                    ],
            !value.isEmpty
        else {
            throw XCTSkip(
                "\(key) required for real gRPC reflection acceptance."
            )
        }

        return value
    }

    func testRealServerReflectionDiscoversProviderCapabilities()
        throws
    {
        let host =
            try environment(
                "RIGHTCLICK_GRPC_REAL_HOST"
            )

        let port =
            try XCTUnwrap(
                Int(
                    try environment(
                        "RIGHTCLICK_GRPC_REAL_PORT"
                    )
                )
            )

        let scheme =
            ProcessInfo
                .processInfo
                .environment[
                    "RIGHTCLICK_GRPC_REAL_SCHEME"
                ]
            ?? "grpc"

        let endpoint =
            try GRPCEndpoint(
                scheme:
                    scheme,
                host:
                    host,
                port:
                    port
            )

        let descriptors =
            try GRPCReflectionTransport
                .discover(
                    endpoint:
                        endpoint
                )

        XCTAssertFalse(
            descriptors.isEmpty
        )

        let reflector =
            try GRPCReflector(
                descriptorData:
                    descriptors,
                endpoint:
                    endpoint,
                providerName:
                    "Real gRPC provider"
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        "Inspect real gRPC provider"
                )
                .capabilities
                .filter {
                    $0.metadata[
                        "substrate"
                    ] == "grpc"
                }

        XCTAssertFalse(
            capabilities.isEmpty
        )

        if let expected =
            ProcessInfo
                .processInfo
                .environment[
                    "RIGHTCLICK_GRPC_REAL_EXPECTED_RPC"
                ],
           !expected.isEmpty
        {
            XCTAssertTrue(
                capabilities.contains {
                    $0.metadata[
                        "rpcPath"
                    ] == expected
                },
                "Expected reflected RPC was absent: \(expected)"
            )
        }
    }
}
