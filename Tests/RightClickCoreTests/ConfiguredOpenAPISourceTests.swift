import Foundation
import XCTest

@testable import RightClickCore

final class ConfiguredOpenAPISourceTests:
    XCTestCase
{
    private func temporaryDirectory()
        throws -> URL
    {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-configured-openapi-"
                    + UUID().uuidString,
                    isDirectory:
                        true
                )

        try FileManager.default
            .createDirectory(
                at:
                    directory,
                withIntermediateDirectories:
                    true
            )

        return directory
    }

    private func specification(
        title: String,
        operationID: String
    ) throws -> Data {
        let root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        title,
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/ping": [
                        "get": [
                            "operationId":
                                operationID,

                            "summary":
                                title + " Ping",

                            "responses": [
                                "200": [
                                    "description":
                                        "ok",

                                    "content": [
                                        "application/json": [
                                            "schema": [
                                                "type":
                                                    "object",

                                                "additionalProperties":
                                                    false,

                                                "required": [
                                                    "status"
                                                ],

                                                "properties": [
                                                    "status": [
                                                        "type":
                                                            "string"
                                                    ]
                                                ],
                                            ]
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ]
                ],
            ]

        return try JSONSerialization
            .data(
                withJSONObject:
                    root,
                options:
                    [.sortedKeys]
            )
    }

    private func capabilityIDs(
        _ engine:
            CapabilityEngine
    ) throws -> Set<String> {
        Set(
            try engine
                .capabilities(
                    for:
                        "ping remote provider"
                )
                .capabilities
                .compactMap {
                    $0.metadata[
                        "operationId"
                    ]
                }
        )
    }

    func testLongLivedEngineObservesConfiguredAddReplaceAndRemove()
        throws
    {
        let directory =
            try temporaryDirectory()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        directory
                )
        }

        let file =
            directory
                .appendingPathComponent(
                    "providers.json"
                )

        let v1URL =
            "https://spec.example/v1.json"

        let v2URL =
            "https://spec.example/v2.json"

        let specifications:
            [String: Data] = [
                v1URL:
                    try specification(
                        title:
                            "Configured V1",
                        operationID:
                            "configured/ping-v1"
                    ),

                v2URL:
                    try specification(
                        title:
                            "Configured V2",
                        operationID:
                            "configured/ping-v2"
                    ),
            ]

        let source =
            ConfiguredOpenAPISource(
                configurationFile:
                    file,
                specificationLoader: {
                    url in

                    guard
                        let data =
                            specifications[
                                url.absoluteString
                            ]
                    else {
                        throw NSError(
                            domain:
                                "ConfiguredOpenAPISourceTests",
                            code:
                                1
                        )
                    }

                    return data
                }
            )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        XCTAssertTrue(
            try capabilityIDs(
                engine
            )
            .isEmpty
        )

        try ConfiguredOpenAPIProviderStore
            .write(
                [
                    ConfiguredOpenAPIProviderDescriptor(
                        id:
                            "remote",
                        specificationURL:
                            v1URL,
                        baseURL:
                            "https://api.example",
                        authorityScheme:
                            "ConfiguredBearer"
                    )
                ],
                to:
                    file
            )

        XCTAssertEqual(
            try capabilityIDs(
                engine
            ),
            Set([
                "configured/ping-v1"
            ])
        )

        let v1 =
            try XCTUnwrap(
                try engine
                    .capabilities(
                        for:
                            "ping remote provider"
                    )
                    .capabilities
                    .first {
                        $0.metadata[
                            "operationId"
                        ] ==
                            "configured/ping-v1"
                    }
            )

        XCTAssertEqual(
            v1.metadata[
                "authorityRequired"
            ],
            "true"
        )

        XCTAssertEqual(
            v1.metadata[
                "authorityScheme"
            ],
            "ConfiguredBearer"
        )

        XCTAssertEqual(
            v1.metadata[
                "authorityOrigin"
            ],
            "https://api.example"
        )

        try ConfiguredOpenAPIProviderStore
            .write(
                [
                    ConfiguredOpenAPIProviderDescriptor(
                        id:
                            "remote",
                        specificationURL:
                            v2URL,
                        baseURL:
                            "https://api.example",
                        authorityScheme:
                            "ConfiguredBearer"
                    )
                ],
                to:
                    file
            )

        XCTAssertEqual(
            try capabilityIDs(
                engine
            ),
            Set([
                "configured/ping-v2"
            ])
        )

        try ConfiguredOpenAPIProviderStore
            .write(
                [],
                to:
                    file
            )

        XCTAssertTrue(
            try capabilityIDs(
                engine
            )
            .isEmpty
        )
    }

    func testUnchangedConfigurationDoesNotRefetchSpecification()
        throws
    {
        let directory =
            try temporaryDirectory()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        directory
                )
        }

        let file =
            directory
                .appendingPathComponent(
                    "providers.json"
                )

        try ConfiguredOpenAPIProviderStore
            .write(
                [
                    ConfiguredOpenAPIProviderDescriptor(
                        id:
                            "remote",
                        specificationURL:
                            "https://spec.example/openapi.json",
                        baseURL:
                            "https://api.example"
                    )
                ],
                to:
                    file
            )

        var loads =
            0

        let data =
            try specification(
                title:
                    "Cache",
                operationID:
                    "cache/ping"
            )

        let source =
            ConfiguredOpenAPISource(
                configurationFile:
                    file,
                specificationLoader: {
                    _ in

                    loads += 1

                    return data
                }
            )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        XCTAssertEqual(
            loads,
            1
        )

        // Atomic rewrite with identical canonical bytes must still
        // retain the cached reflector rather than reacquire remotely.
        let providers =
            try ConfiguredOpenAPIProviderStore
                .read(
                    from:
                        file
                )

        try ConfiguredOpenAPIProviderStore
            .write(
                providers,
                to:
                    file
            )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        XCTAssertEqual(
            loads,
            1
        )
    }

    func testMalformedConfigurationRemovesPreviouslyVisibleReflector()
        throws
    {
        let directory =
            try temporaryDirectory()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        directory
                )
        }

        let file =
            directory
                .appendingPathComponent(
                    "providers.json"
                )

        try ConfiguredOpenAPIProviderStore
            .write(
                [
                    ConfiguredOpenAPIProviderDescriptor(
                        id:
                            "remote",
                        specificationURL:
                            "https://spec.example/openapi.json",
                        baseURL:
                            "https://api.example"
                    )
                ],
                to:
                    file
            )

        let source =
            ConfiguredOpenAPISource(
                configurationFile:
                    file,
                specificationLoader: {
                    _ in

                    try self.specification(
                        title:
                            "Malformed",
                        operationID:
                            "malformed/ping"
                    )
                }
            )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        try Data(
            "{".utf8
        )
        .write(
            to:
                file,
            options:
                .atomic
        )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )
    }

    func testCredentialLikeUnknownFieldFailsClosed()
        throws
    {
        let directory =
            try temporaryDirectory()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        directory
                )
        }

        let file =
            directory
                .appendingPathComponent(
                    "providers.json"
                )

        let root:
            [String: Any] = [
                "schemaVersion":
                    1,

                "providers": [
                    [
                        "id":
                            "remote",

                        "kind":
                            "openapi",

                        "specificationURL":
                            "https://spec.example/openapi.json",

                        "baseURL":
                            "https://api.example",

                        "token":
                            "must-never-be-accepted",
                    ]
                ],
            ]

        let data =
            try JSONSerialization
                .data(
                    withJSONObject:
                        root,
                    options:
                        [.sortedKeys]
                )

        try data.write(
            to:
                file,
            options:
                .atomic
        )

        XCTAssertThrowsError(
            try ConfiguredOpenAPIProviderStore
                .read(
                    from:
                        file
                )
        )

        var fetched =
            false

        let source =
            ConfiguredOpenAPISource(
                configurationFile:
                    file,
                specificationLoader: {
                    _ in

                    fetched =
                        true

                    return Data()
                }
            )

        XCTAssertTrue(
            source
                .reflectors()
                .isEmpty
        )

        XCTAssertFalse(
            fetched
        )
    }

    func testRegistryRejectsNonHTTPSAndCredentialBearingURLs()
        throws
    {
        let directory =
            try temporaryDirectory()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        directory
                )
        }

        let file =
            directory
                .appendingPathComponent(
                    "providers.json"
                )

        XCTAssertThrowsError(
            try ConfiguredOpenAPIProviderStore
                .write(
                    [
                        ConfiguredOpenAPIProviderDescriptor(
                            id:
                                "remote",
                            specificationURL:
                                "http://spec.example/openapi.json",
                            baseURL:
                                "https://api.example"
                        )
                    ],
                    to:
                        file
                )
        )

        XCTAssertThrowsError(
            try ConfiguredOpenAPIProviderStore
                .write(
                    [
                        ConfiguredOpenAPIProviderDescriptor(
                            id:
                                "remote",
                            specificationURL:
                                "https://user:secret@spec.example/openapi.json",
                            baseURL:
                                "https://api.example"
                        )
                    ],
                    to:
                        file
                )
        )

        XCTAssertThrowsError(
            try ConfiguredOpenAPIProviderStore
                .write(
                    [
                        ConfiguredOpenAPIProviderDescriptor(
                            id:
                                "remote",
                            specificationURL:
                                "https://spec.example/openapi.json?token=secret",
                            baseURL:
                                "https://api.example"
                        )
                    ],
                    to:
                        file
                )
        )
    }

    func testRegistryWriteIsDeterministicAndPrivate()
        throws
    {
        let directory =
            try temporaryDirectory()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        directory
                )
        }

        let file =
            directory
                .appendingPathComponent(
                    "providers.json"
                )

        let providers = [
            ConfiguredOpenAPIProviderDescriptor(
                id:
                    "zeta",
                specificationURL:
                    "https://spec.example/zeta.json",
                baseURL:
                    "https://api-zeta.example"
            ),

            ConfiguredOpenAPIProviderDescriptor(
                id:
                    "alpha",
                specificationURL:
                    "https://spec.example/alpha.json",
                baseURL:
                    "https://api-alpha.example",
                authorityScheme:
                    "AlphaBearer"
            ),
        ]

        try ConfiguredOpenAPIProviderStore
            .write(
                providers,
                to:
                    file
            )

        let first =
            try Data(
                contentsOf:
                    file
            )

        try ConfiguredOpenAPIProviderStore
            .write(
                providers.reversed(),
                to:
                    file
            )

        let second =
            try Data(
                contentsOf:
                    file
            )

        XCTAssertEqual(
            first,
            second
        )

        let attributes =
            try FileManager.default
                .attributesOfItem(
                    atPath:
                        file.path
                )

        let permissions =
            try XCTUnwrap(
                attributes[
                    .posixPermissions
                ] as? NSNumber
            )

        XCTAssertEqual(
            permissions.intValue
                & 0o777,
            0o600
        )

        let decoded =
            try ConfiguredOpenAPIProviderStore
                .read(
                    from:
                        file
                )

        XCTAssertEqual(
            decoded.map(\.id),
            [
                "alpha",
                "zeta",
            ]
        )
    }

    func testDuplicateProviderIDsFailClosed()
        throws
    {
        let root:
            [String: Any] = [
                "schemaVersion":
                    1,

                "providers": [
                    [
                        "id":
                            "same",
                        "kind":
                            "openapi",
                        "specificationURL":
                            "https://spec.example/a.json",
                        "baseURL":
                            "https://api.example",
                    ],
                    [
                        "id":
                            "same",
                        "kind":
                            "openapi",
                        "specificationURL":
                            "https://spec.example/b.json",
                        "baseURL":
                            "https://api.example",
                    ],
                ],
            ]

        let data =
            try JSONSerialization
                .data(
                    withJSONObject:
                        root,
                    options:
                        [.sortedKeys]
                )

        XCTAssertThrowsError(
            try ConfiguredOpenAPIProviderStore
                .decode(
                    data
                )
        )
    }
}
