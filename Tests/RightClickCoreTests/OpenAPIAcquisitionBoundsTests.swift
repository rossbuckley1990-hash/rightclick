import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIAcquisitionBoundsTests:
    XCTestCase
{
    private static let maximumBytes =
        1_048_576

    private static let acquisitionDeadline:
        TimeInterval = 5

    private func fixturePort()
        throws -> Int
    {
        guard
            let raw =
                ProcessInfo
                    .processInfo
                    .environment[
                        "NS008_FIXTURE_PORT"
                    ],
            let port =
                Int(raw)
        else {
            throw XCTSkip(
                "NS008_FIXTURE_PORT required."
            )
        }

        return port
    }

    private func descriptor(
        port: Int,
        specificationPath: String
    ) -> BonjourOpenAPIServiceDescriptor {
        BonjourOpenAPIServiceDescriptor(
            instanceName:
                "Acquisition Bounds Probe",
            serviceType:
                "_rightclick._tcp.",
            domain:
                "local.",
            host:
                "127.0.0.1",
            port:
                port,
            txt: [
                "kind":
                    "openapi",
                "scheme":
                    "http",
                "spec":
                    specificationPath,
                "base":
                    "/api",
            ]
        )
    }

    private func acquire(
        port: Int,
        path: String
    ) -> (
        source: BonjourOpenAPISource,
        elapsed: TimeInterval
    ) {
        let source =
            BonjourOpenAPISource(
                startBrowsing: false
            )

        let started =
            Date()

        source.update(
            resolved:
                descriptor(
                    port:
                        port,
                    specificationPath:
                        path
                )
        )

        return (
            source,
            Date()
                .timeIntervalSince(
                    started
                )
        )
    }

    func testSmallSpecificationIsAccepted()
        throws
    {
        let result =
            acquire(
                port:
                    try fixturePort(),
                path:
                    "/small-openapi.json"
            )

        XCTAssertEqual(
            result
                .source
                .reflectors()
                .count,
            1
        )
    }

    func testSpecificationExactlyAtByteLimitIsAccepted()
        throws
    {
        let result =
            acquire(
                port:
                    try fixturePort(),
                path:
                    "/limit-openapi.json"
            )

        XCTAssertEqual(
            result
                .source
                .reflectors()
                .count,
            1,
            "A valid specification exactly at the frozen byte limit must remain accepted."
        )
    }

    func testSpecificationOneByteOverLegacyGenericLimitIsAcceptedByOpenAPISource()
        throws
    {
        let result =
            acquire(
                port:
                    try fixturePort(),
                path:
                    "/oversize-openapi.json"
            )

        XCTAssertEqual(
            result
                .source
                .reflectors()
                .count,
            1,
            "The OpenAPI-specific acquisition path must accept a valid specification one byte above the generic 1 MiB document limit."
        )
    }

    func testSpecificationAcquisitionHasFiveSecondDeadline()
        throws
    {
        let result =
            acquire(
                port:
                    try fixturePort(),
                path:
                    "/slow-openapi.json"
            )

        XCTAssertTrue(
            result
                .source
                .reflectors()
                .isEmpty,
            "A specification that does not complete before the acquisition deadline must not create a reflector."
        )

        XCTAssertLessThan(
            result.elapsed,
            Self.acquisitionDeadline
                + 1.5,
            "Acquisition exceeded the bounded 5-second wall-clock deadline."
        )
    }
}
