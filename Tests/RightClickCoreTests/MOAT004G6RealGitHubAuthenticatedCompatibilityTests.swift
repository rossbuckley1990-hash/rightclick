@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest

@testable import RightClickCore

#if os(macOS)
final class MOAT004G6RealGitHubAuthenticatedCompatibilityTests:
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
                "\(key) required."
            )
        }

        return value
    }

    private func source()
        throws -> (
            source:
                BonjourOpenAPISource,
            engine:
                CapabilityEngine,
            target:
                Capability
        )
    {
        let specificationURL =
            try environment(
                "MOAT004_G6_SPEC_URL"
            )

        let authScheme =
            try environment(
                "MOAT004_G6_AUTH_SCHEME"
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false
            )

        source.update(
            resolved:
                BonjourOpenAPIServiceDescriptor(
                    instanceName:
                        "MOAT-004 G6 Real Provider",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "discovery.invalid",
                    port:
                        9,
                    txt: [
                        "kind":
                            "openapi",

                        "spec-url":
                            specificationURL,

                        "base-url":
                            "https://api.github.com",

                        "auth-scheme":
                            authScheme,
                    ]
                )
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1,
            "The default RIGHTCLICK OpenAPI acquisition path must load the pinned official contract."
        )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let matches =
            try engine
                .capabilities(
                    for:
                        "Get the authenticated GitHub user"
                )
                .capabilities
                .filter {
                    $0.metadata[
                        "operationId"
                    ]
                    == "users/get-authenticated"
                }

        XCTAssertEqual(
            matches.count,
            1
        )

        let target =
            try XCTUnwrap(
                matches.first
            )

        return (
            source,
            engine,
            target
        )
    }

    func testFrozenOfficialContractDiscoversExactAuthenticatedUserCapability()
        throws
    {
        let value =
            try source()

        let target =
            value.target

        XCTAssertEqual(
            target.title,
            "Get the authenticated user"
        )

        XCTAssertEqual(
            target.metadata[
                "method"
            ],
            "GET"
        )

        XCTAssertEqual(
            target.metadata[
                "path"
            ],
            "/user"
        )

        XCTAssertNil(
            target.metadata[
                "argumentsSchema"
            ]
        )

        XCTAssertEqual(
            target.metadata[
                "resultValidation"
            ],
            "json_syntax_only"
        )

        XCTAssertEqual(
            target.metadata[
                "authorityRequired"
            ],
            "true"
        )

        XCTAssertEqual(
            target.metadata[
                "authorityKind"
            ],
            "http_bearer"
        )

        XCTAssertEqual(
            target.metadata[
                "authorityScheme"
            ],
            try environment(
                "MOAT004_G6_AUTH_SCHEME"
            )
        )

        XCTAssertEqual(
            target.metadata[
                "authorityOrigin"
            ],
            "https://api.github.com"
        )
    }

    func testRealAuthenticatedGitHubUserMatchesIndependentControl()
        throws
    {
        let expectedLogin =
            try environment(
                "MOAT004_G6_EXPECTED_LOGIN"
            )

        let expectedID =
            try XCTUnwrap(
                Int64(
                    try environment(
                        "MOAT004_G6_EXPECTED_ID"
                    )
                )
            )

        let value =
            try source()

        let result =
            try value.engine.run(
                id:
                    value.target.id,
                item:
                    "Get the authenticated GitHub user",
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        let output =
            try XCTUnwrap(
                result.output
            )

        let data =
            Data(
                output.utf8
            )

        let object =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any]
            )

        let actualLogin =
            try XCTUnwrap(
                object[
                    "login"
                ] as? String
            )

        let actualID =
            try XCTUnwrap(
                object[
                    "id"
                ] as? NSNumber
            )
            .int64Value

        XCTAssertEqual(
            actualLogin,
            expectedLogin
        )

        XCTAssertEqual(
            actualID,
            expectedID
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified,
            "RIGHTCLICK itself must not overclaim semantic verification merely because GitHub returned HTTP 2xx."
        )
    }
}

#endif
