import Foundation
import XCTest

@testable import RightClickCore

final class MOAT004G2SplitOriginTests:
    XCTestCase
{
    final class LoaderProbe
    {
        var requestedURLs:
            [URL] = []

        var data: Data

        init(
            data: Data
        ) {
            self.data =
                data
        }

        func load(
            _ url: URL
        ) throws -> Data {
            requestedURLs.append(
                url
            )

            return data
        }
    }

    private func specification(
        servers:
            [[String: Any]]? = nil
    ) throws -> Data {
        var root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "Split Origin Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/transform": [
                        "post": [
                            "operationId":
                                "transformText",

                            "summary":
                                "Transform text",

                            "requestBody": [
                                "required":
                                    true,

                                "content": [
                                    "text/plain": [
                                        "schema": [
                                            "type":
                                                "string"
                                        ]
                                    ]
                                ],
                            ],

                            "responses": [
                                "200": [
                                    "description":
                                        "Success",

                                    "content": [
                                        "text/plain": [
                                            "schema": [
                                                "type":
                                                    "string"
                                            ]
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ]
                ],
            ]

        if let servers {
            root[
                "servers"
            ] =
                servers
        }

        return try JSONSerialization
            .data(
                withJSONObject:
                    root,
                options:
                    [.sortedKeys]
            )
    }

    private func descriptor(
        txt:
            [String: String]
    ) -> BonjourOpenAPIServiceDescriptor {
        BonjourOpenAPIServiceDescriptor(
            instanceName:
                "Split Origin Provider",
            serviceType:
                "_rightclick._tcp.",
            domain:
                "local.",
            host:
                "bonjour-local.invalid",
            port:
                9,
            txt:
                txt
        )
    }

    private func absoluteTXT(
        specificationURL: String,
        baseURL: String
    ) -> [String: String] {
        [
            "kind":
                "openapi",
            "spec-url":
                specificationURL,
            "base-url":
                baseURL,
        ]
    }

    func testAbsoluteHTTPSModeLoadsSpecificationFromIndependentOriginAndReflectsBaseOrigin()
        throws
    {
        let loader =
            LoaderProbe(
                data:
                    try specification(
                        servers: [
                            [
                                "url":
                                    "https://api.example/v1"
                            ]
                        ]
                    )
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt:
                        absoluteTXT(
                            specificationURL:
                                "https://spec.example/contracts/openapi.json",
                            baseURL:
                                "https://api.example/v1"
                        )
                )
        )

        XCTAssertEqual(
            loader
                .requestedURLs
                .map(
                    \.absoluteString
                ),
            [
                "https://spec.example/contracts/openapi.json"
            ]
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
                        for:
                            "hello"
                    )
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability
                .metadata[
                    "baseURL"
                ],
            "https://api.example/v1"
        )
    }

    func testAbsoluteModeRequiresBothSpecificationAndBaseURLs()
        throws
    {
        for txt in [
            [
                "kind":
                    "openapi",
                "spec-url":
                    "https://spec.example/openapi.json",
            ],
            [
                "kind":
                    "openapi",
                "base-url":
                    "https://api.example",
            ],
        ] {
            let loader =
                LoaderProbe(
                    data:
                        try specification()
                )

            let source =
                BonjourOpenAPISource(
                    startBrowsing:
                        false,
                    specificationLoader:
                        loader.load
                )

            source.update(
                resolved:
                    descriptor(
                        txt:
                            txt
                    )
            )

            XCTAssertTrue(
                loader
                    .requestedURLs
                    .isEmpty
            )

            XCTAssertTrue(
                source
                    .reflectors()
                    .isEmpty
            )
        }
    }

    func testAbsoluteModeRequiresHTTPS()
        throws
    {
        let advertisements:
            [[String: String]] = [
                absoluteTXT(
                    specificationURL:
                        "http://spec.example/openapi.json",
                    baseURL:
                        "https://api.example"
                ),
                absoluteTXT(
                    specificationURL:
                        "https://spec.example/openapi.json",
                    baseURL:
                        "http://api.example"
                ),
            ]

        for txt in advertisements {
            let loader =
                LoaderProbe(
                    data:
                        try specification()
                )

            let source =
                BonjourOpenAPISource(
                    startBrowsing:
                        false,
                    specificationLoader:
                        loader.load
                )

            source.update(
                resolved:
                    descriptor(
                        txt:
                            txt
                    )
            )

            XCTAssertTrue(
                loader
                    .requestedURLs
                    .isEmpty
            )

            XCTAssertTrue(
                source
                    .reflectors()
                    .isEmpty
            )
        }
    }

    func testMixedLegacyAndAbsoluteAdvertisementModesAreRejected()
        throws
    {
        let loader =
            LoaderProbe(
                data:
                    try specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt: [
                        "kind":
                            "openapi",

                        "scheme":
                            "https",

                        "spec":
                            "/openapi.json",

                        "base":
                            "/",

                        "spec-url":
                            "https://spec.example/openapi.json",

                        "base-url":
                            "https://api.example",
                    ]
                )
        )

        XCTAssertTrue(
            loader
                .requestedURLs
                .isEmpty
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }

    func testDeclaredLiteralServerMustMatchAdvertisedExecutionBase()
        throws
    {
        let loader =
            LoaderProbe(
                data:
                    try specification(
                        servers: [
                            [
                                "url":
                                    "https://api.example"
                            ]
                        ]
                    )
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt:
                        absoluteTXT(
                            specificationURL:
                                "https://spec.example/openapi.json",
                            baseURL:
                                "https://other.example"
                        )
                )
        )

        XCTAssertEqual(
            loader
                .requestedURLs
                .map(
                    \.absoluteString
                ),
            [
                "https://spec.example/openapi.json"
            ]
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }

    func testServerVariablesRemainUnsupported()
        throws
    {
        let loader =
            LoaderProbe(
                data:
                    try specification(
                        servers: [
                            [
                                "url":
                                    "https://{tenant}.example",

                                "variables": [
                                    "tenant": [
                                        "default":
                                            "api"
                                    ]
                                ],
                            ]
                        ]
                    )
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt:
                        absoluteTXT(
                            specificationURL:
                                "https://spec.example/openapi.json",
                            baseURL:
                                "https://api.example"
                        )
                )
        )

        XCTAssertEqual(
            loader
                .requestedURLs
                .count,
            1
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }

    func testLiteralServerAndExecutionBaseCanonicalizeBeforeComparison()
        throws
    {
        let loader =
            LoaderProbe(
                data:
                    try specification(
                        servers: [
                            [
                                "url":
                                    "https://api.example/"
                            ]
                        ]
                    )
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        source.update(
            resolved:
                descriptor(
                    txt:
                        absoluteTXT(
                            specificationURL:
                                "https://SPEC.example:443/openapi.json",
                            baseURL:
                                "https://API.example:443/"
                        )
                )
        )

        XCTAssertEqual(
            loader
                .requestedURLs
                .first?
                .absoluteString,
            "https://spec.example/openapi.json"
        )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "hello"
                    )
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability
                .metadata[
                    "baseURL"
                ],
            "https://api.example"
        )
    }

    func testLegacyRelativeAdvertisementModeRemainsSupported()
        throws
    {
        let loader =
            LoaderProbe(
                data:
                    try specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                BonjourOpenAPIServiceDescriptor(
                    instanceName:
                        "Legacy Provider",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "127.0.0.1",
                    port:
                        40123,
                    txt: [
                        "kind":
                            "openapi",
                        "scheme":
                            "http",
                        "spec":
                            "/openapi.json",
                        "base":
                            "/api",
                    ]
                )
        )

        XCTAssertEqual(
            loader
                .requestedURLs
                .map(
                    \.absoluteString
                ),
            [
                "http://127.0.0.1:40123/openapi.json"
            ]
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )
    }

    func testExactFrozenGitHubContractAcceptsSplitOriginButTargetRemainsOutsideG2()
        throws
    {
        guard
            let specificationPath =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G2_SPEC_PATH"
                    ],
            let specificationURL =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G2_SPEC_URL"
                    ]
        else {
            throw XCTSkip(
                "MOAT004_G2_SPEC_PATH and MOAT004_G2_SPEC_URL required."
            )
        }

        let data =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            specificationPath
                    )
            )

        let loader =
            LoaderProbe(
                data:
                    data
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt:
                        absoluteTXT(
                            specificationURL:
                                specificationURL,
                            baseURL:
                                "https://api.github.com"
                        )
                )
        )

        XCTAssertEqual(
            loader
                .requestedURLs
                .map(
                    \.absoluteString
                ),
            [
                specificationURL
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

        let result =
            try engine
                .capabilities(
                    for:
                        "Get the authenticated GitHub user"
                )

        let target =
            result
                .capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ]
                    == "users/get-authenticated"
                }

        XCTAssertNil(
            target,
            "G2 must not accidentally implement G3/G4."
        )
    }
}
