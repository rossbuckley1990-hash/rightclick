@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest

@testable import RightClickCore

final class MOAT005G5FullFrozenGitHubContractTests:
    XCTestCase
{
    private let specificationURL =
        "https://raw.githubusercontent.com/github/rest-api-description/836ce198db13a6fb194547e53eea99c6ddae495b/descriptions/api.github.com/api.github.com.2026-03-10.json"

    private let expectedSpecificationSHA256 =
        "1429e93b5cbfa7547aa197e9553a6dacbd8d4aaf28012446ed730b152bcdf284"

    private let authorityScheme =
        "MOAT005G5Bearer"

    private func discoveredTarget()
        throws -> Capability
    {
        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false
            )

        source.update(
            resolved:
                BonjourOpenAPIServiceDescriptor(
                    instanceName:
                        "MOAT-005 G5 Full Frozen GitHub Contract",

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
                            authorityScheme,
                    ]
                )
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1,
            "G5_ACQUISITION_FAILURE: production OpenAPI acquisition did not load the exact pinned contract."
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
                        "Create a GitHub issue"
                )
                .capabilities
                .filter {
                    $0.metadata[
                        "operationId"
                    ] == "issues/create"
                }

        XCTAssertEqual(
            matches.count,
            1,
            "G5_TARGET_ABSENT: the full official contract did not dynamically expose exactly one issues/create capability."
        )

        return try XCTUnwrap(
            matches.first,
            "G5_TARGET_ABSENT"
        )
    }

    private func argumentsSchema(
        _ capability:
            Capability
    ) throws -> [String: Any]
    {
        let raw =
            try XCTUnwrap(
                capability.metadata[
                    "argumentsSchema"
                ]
            )

        let data =
            try XCTUnwrap(
                raw.data(
                    using:
                        .utf8
                )
            )

        return try XCTUnwrap(
            JSONSerialization
                .jsonObject(
                    with:
                        data
                )
                as? [String: Any]
        )
    }

    func testFullFrozenOfficialContractDiscoversIssuesCreate()
        throws
    {
        let target =
            try discoveredTarget()

        XCTAssertEqual(
            target.title,
            "Create an issue"
        )

        XCTAssertEqual(
            target.metadata[
                "method"
            ],
            "POST"
        )

        XCTAssertEqual(
            target.metadata[
                "path"
            ],
            "/repos/{owner}/{repo}/issues"
        )

        XCTAssertEqual(
            target.metadata[
                "requestContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            target.metadata[
                "responseContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            target.metadata[
                "specificationSHA256"
            ],
            expectedSpecificationSHA256
        )
    }

    func testFullContractExposesExactClosedArguments()
        throws
    {
        let target =
            try discoveredTarget()

        let schema =
            try argumentsSchema(
                target
            )

        XCTAssertEqual(
            schema[
                "type"
            ] as? String,
            "object"
        )

        XCTAssertEqual(
            schema[
                "additionalProperties"
            ] as? Bool,
            false
        )

        let required =
            Set(
                try XCTUnwrap(
                    schema[
                        "required"
                    ] as? [String]
                )
            )

        XCTAssertEqual(
            required,
            Set([
                "owner",
                "repo",
                "title",
            ])
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
                "owner",
                "repo",
                "title",
                "body",
            ])
        )

        for name in [
            "owner",
            "repo",
            "title",
            "body",
        ] {
            let property =
                try XCTUnwrap(
                    properties[
                        name
                    ] as? [String: Any]
                )

            XCTAssertEqual(
                property[
                    "type"
                ] as? String,
                "string"
            )
        }

        for unsupported in [
            "labels",
            "assignees",
            "issue_field_values",
            "milestone",
            "parent_issue_id",
            "type",
        ] {
            XCTAssertNil(
                properties[
                    unsupported
                ]
            )
        }
    }

    func testFullContractUsesOriginBoundExternalAuthority()
        throws
    {
        let target =
            try discoveredTarget()

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
            authorityScheme
        )

        XCTAssertEqual(
            target.metadata[
                "authorityOrigin"
            ],
            "https://api.github.com"
        )
    }

    func testFullContractUsesUnverifiedJSONSyntaxResponseFallback()
        throws
    {
        let target =
            try discoveredTarget()

        XCTAssertEqual(
            target.metadata[
                "resultValidation"
            ],
            "json_syntax_only"
        )

        XCTAssertNil(
            target.metadata[
                "resultSchema"
            ]
        )
    }
}
