@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore

final class NetworkOriginAuthorityTests:
    XCTestCase
{
    private struct Ports {
        let source: Int
        let sink: Int
    }

    private func ports()
        throws -> Ports
    {
        let environment =
            ProcessInfo.processInfo.environment

        guard
            let sourceRaw =
                environment[
                    "NS007_SOURCE_PORT"
                ],
            let source =
                Int(sourceRaw),
            let sinkRaw =
                environment[
                    "NS007_SINK_PORT"
                ],
            let sink =
                Int(sinkRaw)
        else {
            throw XCTSkip(
                "NS007_SOURCE_PORT and NS007_SINK_PORT required."
            )
        }

        return Ports(
            source: source,
            sink: sink
        )
    }

    private func descriptor(
        port: Int,
        specificationPath: String
    ) -> BonjourOpenAPIServiceDescriptor {
        BonjourOpenAPIServiceDescriptor(
            instanceName:
                "Origin Authority Probe",
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

    func testSpecificationRedirectCannotEscapeDiscoveredOrigin()
        throws
    {
        let ports =
            try ports()

        let source =
            BonjourOpenAPISource(
                startBrowsing: false
            )

        source.update(
            resolved:
                descriptor(
                    port:
                        ports.source,
                    specificationPath:
                        "/redirect-openapi.json"
                )
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty,
            "A redirected OpenAPI document must not create a reflector."
        )
    }

    func testInvocationRedirectCannotEscapeDiscoveredOrigin()
        throws
    {
        let ports =
            try ports()

        let source =
            BonjourOpenAPISource(
                startBrowsing: false
            )

        source.update(
            resolved:
                descriptor(
                    port:
                        ports.source,
                    specificationPath:
                        "/openapi.json"
                )
        )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id:
                    capability.id,
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

        XCTAssertNotEqual(
            result.status,
            .verified,
            "Redirected output must not become verified success."
        )

        XCTAssertNotEqual(
            result
                .verification?
                .status,
            .verifiedSuccess,
            "Cross-origin redirected text must not satisfy verification."
        )
    }
}
