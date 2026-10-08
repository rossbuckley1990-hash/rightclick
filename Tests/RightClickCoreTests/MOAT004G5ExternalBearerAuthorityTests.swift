@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
#if os(macOS)
import Security
#endif
import XCTest

@testable import RightClickCore

final class MOAT004G5ExternalBearerAuthorityTests:
    XCTestCase
{
    private static let keychainService =
        "ai.rightclick.openapi-authority"

    private static let externalScheme =
        "MOAT004ExternalBearer"

    private static let fixtureToken =
        "g5-fixture-token"

    private var keychainAccounts:
        [String] = []

    final class LoaderProbe
    {
        var requestedURLs:
            [URL] = []

        let data: Data

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

    override func tearDown() {
        for account in keychainAccounts {
            deleteBearerToken(
                account:
                    account
            )
        }

        keychainAccounts = []

        super.tearDown()
    }

    private func fixturePort()
        throws -> Int
    {
        guard
            let raw =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G5_FIXTURE_PORT"
                    ],
            let port =
                Int(raw)
        else {
            throw XCTSkip(
                "MOAT004_G5_FIXTURE_PORT required."
            )
        }

        return port
    }

    private func authorityOrigin(
        port: Int
    ) -> String {
        "http://127.0.0.1:"
        + String(port)
    }

    private func authorityAccount(
        origin: String,
        schemeName: String
    ) -> String {
        "http-bearer|"
        + origin
        + "|"
        + schemeName
    }

    private func deleteBearerToken(
        account: String
    ) {
        #if os(macOS)
        let query:
            [String: Any] = [
                kSecClass as String:
                    kSecClassGenericPassword,

                kSecAttrService as String:
                    Self.keychainService,

                kSecAttrAccount as String:
                    account,
            ]

        SecItemDelete(
            query as CFDictionary
        )
        #endif
    }

    private func deleteBearerToken(
        origin: String,
        schemeName: String
    ) {
        deleteBearerToken(
            account:
                authorityAccount(
                    origin:
                        origin,
                    schemeName:
                        schemeName
                )
        )
    }

    #if os(macOS)
    private func saveBearerToken(
        _ token: String,
        origin: String,
        schemeName: String
    ) throws {
        let account =
            authorityAccount(
                origin:
                    origin,
                schemeName:
                    schemeName
            )

        deleteBearerToken(
            account:
                account
        )

        let query:
            [String: Any] = [
                kSecClass as String:
                    kSecClassGenericPassword,

                kSecAttrService as String:
                    Self.keychainService,

                kSecAttrAccount as String:
                    account,

                kSecValueData as String:
                    Data(
                        token.utf8
                    ),
            ]

        let status =
            SecItemAdd(
                query as CFDictionary,
                nil
            )

        guard
            status == errSecSuccess
        else {
            throw NSError(
                domain:
                    "MOAT004G5ExternalBearerAuthorityTests.Keychain",
                code:
                    Int(status)
            )
        }

        keychainAccounts.append(
            account
        )
    }

    #endif

    private func responseSchema()
        -> [String: Any]
    {
        [
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
    }

    private func specification(
        includeOperationSecurity:
            Bool = false,
        operationSecurity:
            [[String: [String]]] = [],
        rootSecurity:
            [[String: [String]]]? = nil,
        securitySchemes:
            [String: [String: Any]] = [:]
    ) throws -> Data {
        var operation:
            [String: Any] = [
                "operationId":
                    "getStatus",

                "summary":
                    "Get Status",

                "responses": [
                    "200": [
                        "description":
                            "Success",

                        "content": [
                            "application/json": [
                                "schema":
                                    responseSchema()
                            ]
                        ],
                    ]
                ],
            ]

        if includeOperationSecurity {
            operation[
                "security"
            ] =
                operationSecurity
        }

        var root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "External Authority Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/status": [
                        "get":
                            operation
                    ]
                ],
            ]

        if let rootSecurity {
            root[
                "security"
            ] =
                rootSecurity
        }

        if !securitySchemes.isEmpty {
            root[
                "components"
            ] = [
                "securitySchemes":
                    securitySchemes
            ]
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
        port: Int,
        authScheme:
            String? = MOAT004G5ExternalBearerAuthorityTests.externalScheme
    ) -> BonjourOpenAPIServiceDescriptor
    {
        var txt:
            [String: String] = [
                "kind":
                    "openapi",

                "scheme":
                    "http",

                "spec":
                    "/openapi.json",

                "base":
                    "/",
            ]

        if let authScheme {
            txt[
                "auth-scheme"
            ] =
                authScheme
        }

        return BonjourOpenAPIServiceDescriptor(
            instanceName:
                "External Authority Provider",
            serviceType:
                "_rightclick._tcp.",
            domain:
                "local.",
            host:
                "127.0.0.1",
            port:
                port,
            txt:
                txt
        )
    }

    private func capability(
        specification:
            Data,
        port: Int,
        authScheme:
            String? = MOAT004G5ExternalBearerAuthorityTests.externalScheme
    ) throws -> (
        source:
            BonjourOpenAPISource,
        engine:
            CapabilityEngine,
        capability:
            Capability,
        loader:
            LoaderProbe
    ) {
        let loader =
            LoaderProbe(
                data:
                    specification
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
                    port:
                        port,
                    authScheme:
                        authScheme
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
                        for:
                            "get status"
                    )
                    .capabilities
                    .first
            )

        return (
            source,
            engine,
            capability,
            loader
        )
    }

    func testExternalBearerMetadataBindsToExecutionOriginWithoutSecret()
        throws
    {
        let port =
            try fixturePort()

        let value =
            try capability(
                specification:
                    try specification(),
                port:
                    port
            )

        XCTAssertEqual(
            value.capability
                .metadata[
                    "authorityRequired"
                ],
            "true"
        )

        XCTAssertEqual(
            value.capability
                .metadata[
                    "authorityKind"
                ],
            "http_bearer"
        )

        XCTAssertEqual(
            value.capability
                .metadata[
                    "authorityScheme"
                ],
            Self.externalScheme
        )

        XCTAssertEqual(
            value.capability
                .metadata[
                    "authorityOrigin"
                ],
            authorityOrigin(
                port:
                    port
            )
        )

        let metadataText =
            value.capability
                .metadata
                .values
                .joined(
                    separator:
                        "\n"
                )

        XCTAssertFalse(
            metadataText.contains(
                Self.fixtureToken
            )
        )
    }

    func testMissingExternalBearerFailsBeforeProviderTransport()
        throws
    {
        let port =
            try fixturePort()

        let origin =
            authorityOrigin(
                port:
                    port
            )

        deleteBearerToken(
            origin:
                origin,
            schemeName:
                Self.externalScheme
        )

        let value =
            try capability(
                specification:
                    try specification(),
                port:
                    port
            )

        let result =
            try value.engine.run(
                id:
                    value.capability.id,
                item:
                    "get status",
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .unavailable
        )

        XCTAssertEqual(
            result.evidence.type,
            "authority_unavailable"
        )
    }

    #if os(macOS)
    func testExternalBearerUsesExistingOriginBoundKeychainStore()
        throws
    {
        let port =
            try fixturePort()

        let origin =
            authorityOrigin(
                port:
                    port
            )

        try saveBearerToken(
            Self.fixtureToken,
            origin:
                origin,
            schemeName:
                Self.externalScheme
        )

        let value =
            try capability(
                specification:
                    try specification(),
                port:
                    port
            )

        let result =
            try value.engine.run(
                id:
                    value.capability.id,
                item:
                    "get status",
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            """
            {"status":"ok"}
            """
        )

        let metadataText =
            value.capability
                .metadata
                .values
                .joined(
                    separator:
                        "\n"
                )

        XCTAssertFalse(
            metadataText.contains(
                Self.fixtureToken
            )
        )
    }

    #endif

    #if os(macOS)
    func testCredentialForDifferentOriginIsNotUsed()
        throws
    {
        let port =
            try fixturePort()

        let correctOrigin =
            authorityOrigin(
                port:
                    port
            )

        let differentPort =
            port == 65_535
            ? port - 1
            : port + 1

        deleteBearerToken(
            origin:
                correctOrigin,
            schemeName:
                Self.externalScheme
        )

        try saveBearerToken(
            Self.fixtureToken,
            origin:
                authorityOrigin(
                    port:
                        differentPort
                ),
            schemeName:
                Self.externalScheme
        )

        let value =
            try capability(
                specification:
                    try specification(),
                port:
                    port
            )

        let result =
            try value.engine.run(
                id:
                    value.capability.id,
                item:
                    "get status",
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .unavailable
        )

        XCTAssertEqual(
            result.evidence.type,
            "authority_unavailable"
        )
    }

    #endif

    func testExplicitEmptyOperationSecurityRemainsPublic()
        throws
    {
        let port =
            try fixturePort()

        let value =
            try capability(
                specification:
                    try specification(
                        includeOperationSecurity:
                            true,
                        operationSecurity:
                            []
                    ),
                port:
                    port
            )

        XCTAssertNil(
            value.capability
                .metadata[
                    "authorityRequired"
                ]
        )
    }

    func testExplicitEmptyRootSecurityRemainsPublic()
        throws
    {
        let port =
            try fixturePort()

        let value =
            try capability(
                specification:
                    try specification(
                        rootSecurity:
                            []
                    ),
                port:
                    port
            )

        XCTAssertNil(
            value.capability
                .metadata[
                    "authorityRequired"
                ]
        )
    }

    func testUnsupportedDeclaredSecurityStillAbstains()
        throws
    {
        let port =
            try fixturePort()

        let loader =
            LoaderProbe(
                data:
                    try specification(
                        includeOperationSecurity:
                            true,
                        operationSecurity: [
                            [
                                "ApiKeyAuth":
                                    []
                            ]
                        ],
                        securitySchemes: [
                            "ApiKeyAuth": [
                                "type":
                                    "apiKey",
                                "in":
                                    "header",
                                "name":
                                    "X-API-Key",
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
                    port:
                        port
                )
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
                        "get status"
                )
                .capabilities
                .isEmpty
        )
    }

    func testContractDeclaredBearerTakesPrecedenceOverExternalFallback()
        throws
    {
        let port =
            try fixturePort()

        let value =
            try capability(
                specification:
                    try specification(
                        includeOperationSecurity:
                            true,
                        operationSecurity: [
                            [
                                "ContractBearer":
                                    []
                            ]
                        ],
                        securitySchemes: [
                            "ContractBearer": [
                                "type":
                                    "http",
                                "scheme":
                                    "bearer",
                            ]
                        ]
                    ),
                port:
                    port
            )

        XCTAssertEqual(
            value.capability
                .metadata[
                    "authorityScheme"
                ],
            "ContractBearer"
        )

        XCTAssertNotEqual(
            value.capability
                .metadata[
                    "authorityScheme"
                ],
            Self.externalScheme
        )
    }

    func testChangingExternalAuthoritySchemeChangesCapabilityIdentity()
        throws
    {
        let port =
            try fixturePort()

        let specification =
            try specification()

        let loader =
            LoaderProbe(
                data:
                    specification
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
                    port:
                        port,
                    authScheme:
                        "SchemeA"
                )
        )

        let firstID =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "get status"
                    )
                    .capabilities
                    .first?
                    .id
            )

        source.update(
            resolved:
                descriptor(
                    port:
                        port,
                    authScheme:
                        "SchemeB"
                )
        )

        let secondID =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "get status"
                    )
                    .capabilities
                    .first?
                    .id
            )

        XCTAssertNotEqual(
            firstID,
            secondID
        )
    }

    func testInvalidExternalAuthoritySchemeMetadataIsRejectedBeforeFetch()
        throws
    {
        let port =
            try fixturePort()

        for scheme in [
            "",
            "   ",
            "bad|scheme",
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
                        port:
                            port,
                        authScheme:
                            scheme
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

    func testFrozenGitHubUserCarriesGenericExternalBearerAuthority()
        throws
    {
        guard
            let specificationPath =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G5_SPEC_PATH"
                    ]
        else {
            throw XCTSkip(
                "MOAT004_G5_SPEC_PATH required."
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
                BonjourOpenAPIServiceDescriptor(
                    instanceName:
                        "Frozen Real Contract",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "ignored.invalid",
                    port:
                        9,
                    txt: [
                        "kind":
                            "openapi",

                        "spec-url":
                            "https://spec.example/github-openapi.json",

                        "base-url":
                            "https://api.github.com",

                        "auth-scheme":
                            Self.externalScheme,
                    ]
                )
        )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let target =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "Get the authenticated GitHub user"
                    )
                    .capabilities
                    .first {
                        $0.metadata[
                            "operationId"
                        ]
                        == "users/get-authenticated"
                    }
            )

        XCTAssertEqual(
            target.title,
            "Get the authenticated user"
        )

        XCTAssertEqual(
            target
                .metadata[
                    "authorityRequired"
                ],
            "true"
        )

        XCTAssertEqual(
            target
                .metadata[
                    "authorityKind"
                ],
            "http_bearer"
        )

        XCTAssertEqual(
            target
                .metadata[
                    "authorityScheme"
                ],
            Self.externalScheme
        )

        XCTAssertEqual(
            target
                .metadata[
                    "authorityOrigin"
                ],
            "https://api.github.com"
        )

        XCTAssertEqual(
            target
                .metadata[
                    "resultValidation"
                ],
            "json_syntax_only"
        )

        let metadataText =
            target
                .metadata
                .values
                .joined(
                    separator:
                        "\n"
                )

        XCTAssertFalse(
            metadataText.contains(
                Self.fixtureToken
            )
        )
    }
}
