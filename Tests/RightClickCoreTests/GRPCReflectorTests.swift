import Foundation
import XCTest

@testable import RightClickCore

final class GRPCReflectorTests:
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

    private func endpoint()
        throws -> GRPCEndpoint
    {
        try GRPCEndpoint(
            scheme:
                "grpc",
            host:
                "localhost",
            port:
                50051
        )
    }

    func testDescriptorReflectsUnaryAndStreamingMethodsWithoutGeneratedStubs()
        throws
    {
        let reflector =
            try GRPCReflector(
                descriptorData: [
                    fixture()
                ],
                endpoint:
                    endpoint(),
                providerName:
                    "Demo gRPC",
                invoker: {
                    _,
                    _,
                    _ in

                    XCTFail(
                        "Discovery must not invoke provider transport."
                    )

                    return Data()
                }
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
                        "Use the demo gRPC service"
                )
                .capabilities
                .filter {
                    $0.metadata[
                        "substrate"
                    ] == "grpc"
                }

        XCTAssertEqual(
            capabilities.count,
            2
        )

        let unary =
            try XCTUnwrap(
                capabilities.first {
                    $0.metadata[
                        "method"
                    ] == "SayHello"
                }
            )

        XCTAssertEqual(
            unary.title,
            "gRPC demo.Greeter/SayHello"
        )

        XCTAssertEqual(
            unary.metadata[
                "service"
            ],
            "demo.Greeter"
        )

        XCTAssertEqual(
            unary.metadata[
                "rpcPath"
            ],
            "/demo.Greeter/SayHello"
        )

        XCTAssertEqual(
            unary.metadata[
                "callType"
            ],
            "unary"
        )

        XCTAssertEqual(
            unary.metadata[
                "requestType"
            ],
            "demo.HelloRequest"
        )

        XCTAssertEqual(
            unary.metadata[
                "responseType"
            ],
            "demo.HelloReply"
        )

        XCTAssertEqual(
            unary.metadata[
                "resultValidation"
            ],
            "protobuf_descriptor"
        )

        XCTAssertEqual(
            unary.invocation,
            .interactive
        )

        let rawSchema =
            try XCTUnwrap(
                unary.metadata[
                    "argumentsSchema"
                ]
            )

        let schema =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            Data(
                                rawSchema.utf8
                            )
                    )
                    as? [String: Any]
            )

        XCTAssertEqual(
            schema[
                "additionalProperties"
            ] as? Bool,
            false
        )

        let properties =
            try XCTUnwrap(
                schema[
                    "properties"
                ] as? [String: Any]
            )

        XCTAssertEqual(
            Set(
                properties.keys
            ),
            Set([
                "name",
                "count",
            ])
        )

        let streaming =
            try XCTUnwrap(
                capabilities.first {
                    $0.metadata[
                        "method"
                    ] == "Watch"
                }
            )

        XCTAssertEqual(
            streaming.metadata[
                "callType"
            ],
            "server_streaming"
        )

        XCTAssertEqual(
            streaming.invocation,
            .unsupported
        )

        XCTAssertNotNil(
            streaming.metadata[
                "invocationLimitation"
            ]
        )
    }

    func testUnaryExecutionEncodesAndDecodesDynamicProtobuf()
        throws
    {
        var invocationCount =
            0

        let reflector =
            try GRPCReflector(
                descriptorData: [
                    fixture()
                ],
                endpoint:
                    endpoint(),
                providerName:
                    "Demo gRPC",
                invoker: {
                    endpoint,
                    path,
                    request in

                    invocationCount += 1

                    XCTAssertEqual(
                        endpoint.identity,
                        "grpc://localhost:50051"
                    )

                    XCTAssertEqual(
                        path,
                        "/demo.Greeter/SayHello"
                    )

                    var expected =
                        GRPCWireWriter()

                    expected
                        .writeStringField(
                            1,
                            value:
                                "Ada"
                        )

                    expected
                        .writeVarintField(
                            2,
                            value:
                                2
                        )

                    XCTAssertEqual(
                        request,
                        expected.data
                    )

                    var response =
                        GRPCWireWriter()

                    response
                        .writeStringField(
                            1,
                            value:
                                "Hello Ada"
                        )

                    return response.data
                }
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let target =
            try XCTUnwrap(
                try engine
                    .capabilities(
                        for:
                            "Say hello"
                    )
                    .capabilities
                    .first {
                        $0.metadata[
                            "method"
                        ] == "SayHello"
                    }
            )

        let result =
            try engine.run(
                id:
                    target.id,
                item:
                    "Say hello",
                confirmed:
                    true,
                arguments: [
                    "name":
                        "Ada",
                    "count":
                        "2",
                ]
            )

        XCTAssertEqual(
            invocationCount,
            1
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            #"{"message":"Hello Ada"}"#
        )

        XCTAssertEqual(
            result.evidence.type,
            "provider_acceptance"
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified
        )
    }

    func testUnknownArgumentFailsBeforeTransport()
        throws
    {
        var invoked =
            false

        let reflector =
            try GRPCReflector(
                descriptorData: [
                    fixture()
                ],
                endpoint:
                    endpoint(),
                invoker: {
                    _,
                    _,
                    _ in

                    invoked =
                        true

                    return Data()
                }
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let target =
            try XCTUnwrap(
                try engine
                    .capabilities(
                        for:
                            "Say hello"
                    )
                    .capabilities
                    .first {
                        $0.metadata[
                            "method"
                        ] == "SayHello"
                    }
            )

        let result =
            try engine.run(
                id:
                    target.id,
                item:
                    "Say hello",
                confirmed:
                    true,
                arguments: [
                    "unknown":
                        "value",
                ]
            )

        XCTAssertFalse(
            invoked
        )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            result.evidence.type,
            "input_contract_failure"
        )
    }

    func testStreamingMethodFailsClosedBeforeTransport()
        throws
    {
        var invoked =
            false

        let reflector =
            try GRPCReflector(
                descriptorData: [
                    fixture()
                ],
                endpoint:
                    endpoint(),
                invoker: {
                    _,
                    _,
                    _ in

                    invoked =
                        true

                    return Data()
                }
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let target =
            try XCTUnwrap(
                try engine
                    .capabilities(
                        for:
                            "Watch"
                    )
                    .capabilities
                    .first {
                        $0.metadata[
                            "method"
                        ] == "Watch"
                    }
            )

        let result =
            try engine.run(
                id:
                    target.id,
                item:
                    "Watch",
                confirmed:
                    true
            )

        XCTAssertFalse(
            invoked
        )

        XCTAssertEqual(
            result.status,
            .unsupported
        )
    }
}
