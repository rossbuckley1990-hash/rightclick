import Foundation
import XCTest

@testable import RightClickCore

final class GRPCReflectionTransportTests:
    XCTestCase
{
    func testReflectionRequestsUseStandardWireFieldNumbers()
        throws
    {
        XCTAssertEqual(
            GRPCReflectionWire
                .listServicesRequest(),
            Data([
                0x3a,
                0x00,
            ])
        )

        var expected =
            GRPCWireWriter()

        expected
            .writeStringField(
                4,
                value:
                    "demo.Greeter"
            )

        XCTAssertEqual(
            GRPCReflectionWire
                .fileContainingSymbolRequest(
                    "demo.Greeter"
                ),
            expected.data
        )
    }

    func testListServicesResponseParsesStandardReflectionEnvelope()
        throws
    {
        var firstService =
            GRPCWireWriter()

        firstService
            .writeStringField(
                1,
                value:
                    "demo.Greeter"
            )

        var secondService =
            GRPCWireWriter()

        secondService
            .writeStringField(
                1,
                value:
                    "grpc.health.v1.Health"
            )

        var list =
            GRPCWireWriter()

        list
            .writeLengthDelimitedField(
                1,
                data:
                    firstService.data
            )

        list
            .writeLengthDelimitedField(
                1,
                data:
                    secondService.data
            )

        var response =
            GRPCWireWriter()

        response
            .writeLengthDelimitedField(
                6,
                data:
                    list.data
            )

        XCTAssertEqual(
            try GRPCReflectionWire
                .listServices(
                    from:
                        response.data
                ),
            [
                "demo.Greeter",
                "grpc.health.v1.Health",
            ]
        )
    }

    func testFileDescriptorResponseReturnsRawDescriptorBytes()
        throws
    {
        let first =
            Data([
                0x01,
                0x02,
                0x03,
            ])

        let second =
            Data([
                0x04,
                0x05,
            ])

        var descriptors =
            GRPCWireWriter()

        descriptors
            .writeLengthDelimitedField(
                1,
                data:
                    first
            )

        descriptors
            .writeLengthDelimitedField(
                1,
                data:
                    second
            )

        var response =
            GRPCWireWriter()

        response
            .writeLengthDelimitedField(
                4,
                data:
                    descriptors.data
            )

        XCTAssertEqual(
            try GRPCReflectionWire
                .fileDescriptors(
                    from:
                        response.data
                ),
            [
                first,
                second,
            ]
        )
    }
}
