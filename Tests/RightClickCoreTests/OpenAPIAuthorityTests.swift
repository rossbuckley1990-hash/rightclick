@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif
import XCTest
#if os(Linux)
import Glibc
#endif
@testable import RightClickCore

final class OpenAPIAuthorityTests:
    XCTestCase
{
    private static let keychainService =
        "ai.rightclick.openapi-authority"

    private var keychainAccounts:
        [String] = []

    #if os(Linux)
    private var previousAuthorityBindings: String?
    private var testAuthorityBindings: [String: [String: String]] = [:]

    override func setUp() {
        super.setUp()
        previousAuthorityBindings = ProcessInfo.processInfo.environment[RuntimeEnvironmentAuthority.environmentKey]
        XCTAssertEqual(setenv(RuntimeEnvironmentAuthority.environmentKey, "[]", 1), 0)
    }

    private func updateTestAuthorityBindings() throws {
        let rows = testAuthorityBindings.values.sorted {
            ($0["origin"] ?? "", $0["schemeName"] ?? "") < ($1["origin"] ?? "", $1["schemeName"] ?? "")
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(setenv(RuntimeEnvironmentAuthority.environmentKey, json, 1), 0)
    }
    #endif

    final class StubURLProtocol:
        URLProtocol
    {
        static var handler:
            (
                (URLRequest)
                    throws
                    -> (
                        HTTPURLResponse,
                        Data
                    )
            )?

        override class func canInit(
            with request:
                URLRequest
        ) -> Bool {
            true
        }

        override class func canonicalRequest(
            for request:
                URLRequest
        ) -> URLRequest {
            request
        }

        override func startLoading() {
            guard
                let handler =
                    Self.handler
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        NSError(
                            domain:
                                "OpenAPIAuthorityTests",
                            code:
                                1
                        )
                )

                return
            }

            do {
                var observed =
                    request

                if
                    observed.httpBody == nil,
                    let stream =
                        observed.httpBodyStream
                {
                    stream.open()
                    defer {
                        stream.close()
                    }

                    var body =
                        Data()

                    var buffer =
                        [UInt8](
                            repeating:
                                0,
                            count:
                                4096
                        )

                    while true {
                        let count =
                            stream.read(
                                &buffer,
                                maxLength:
                                    buffer.count
                            )

                        if count < 0 {
                            throw
                                stream.streamError
                                ?? NSError(
                                    domain:
                                        "OpenAPIAuthorityTests",
                                    code:
                                        2
                                )
                        }

                        if count == 0 {
                            break
                        }

                        body.append(
                            contentsOf:
                                buffer[
                                    0..<count
                                ]
                        )
                    }

                    observed.httpBody =
                        body
                }

                let (
                    response,
                    data
                ) =
                    try handler(
                        observed
                    )

                client?.urlProtocol(
                    self,
                    didReceive:
                        response,
                    cacheStoragePolicy:
                        .notAllowed
                )

                client?.urlProtocol(
                    self,
                    didLoad:
                        data
                )

                client?
                    .urlProtocolDidFinishLoading(
                        self
                    )

            } catch {
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        error
                )
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.handler =
            nil

        for account
            in keychainAccounts
        {
            deleteBearerToken(
                account:
                    account
            )
        }

        keychainAccounts =
            []

        #if os(Linux)
        if let previousAuthorityBindings {
            XCTAssertEqual(setenv(RuntimeEnvironmentAuthority.environmentKey, previousAuthorityBindings, 1), 0)
        } else {
            XCTAssertEqual(unsetenv(RuntimeEnvironmentAuthority.environmentKey), 0)
        }
        #endif

        super.tearDown()
    }

    private func session()
        -> URLSession
    {
        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration.protocolClasses = [
            StubURLProtocol.self
        ]

        return URLSession(
            configuration:
                configuration
        )
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
        #elseif os(Linux)
        if let binding = testAuthorityBindings.removeValue(forKey: account),
           let name = binding["tokenEnvironment"] {
            XCTAssertEqual(unsetenv(name), 0)
        }
        XCTAssertNoThrow(try updateTestAuthorityBindings())
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

    private func saveBearerToken(
        _ token: String,
        origin: String,
        schemeName: String
    ) throws {
        #if os(macOS)
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
            status
                == errSecSuccess
        else {
            throw NSError(
                domain:
                    "OpenAPIAuthorityTests.Keychain",
                code:
                    Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not add test bearer credential to Keychain."
                ]
            )
        }

        keychainAccounts.append(
            account
        )
        #elseif os(Linux)
        // Same exact origin/scheme contract, backed by an explicitly named
        // environment credential on this host instead of macOS Keychain.
        let account = authorityAccount(origin: origin, schemeName: schemeName)
        deleteBearerToken(account: account)
        let name = "RIGHTCLICK_TEST_BEARER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        testAuthorityBindings[account] = ["origin": origin, "schemeName": schemeName, "tokenEnvironment": name]
        XCTAssertEqual(setenv(name, token, 1), 0)
        try updateTestAuthorityBindings()
        keychainAccounts.append(account)
        #endif
    }

    private func specification(
        securitySchemes:
            [String: [String: Any]],
        operationSecurity:
            [[String: [String]]]?
                = [
                    [
                        "BearerAuth":
                            []
                    ]
                ],
        rootSecurity:
            [[String: [String]]]?
                = nil
    ) throws -> Data {
        var operation:
            [String: Any] = [
                "operationId":
                    "createSecureRecord",

                "summary":
                    "Create Secure Record",

                "requestBody": [
                    "required":
                        true,

                    "content": [
                        "application/json": [
                            "schema": [
                                "type":
                                    "object",

                                "additionalProperties":
                                    false,

                                "required": [
                                    "title",
                                    "priority",
                                ],

                                "properties": [
                                    "title": [
                                        "type":
                                            "string"
                                    ],

                                    "priority": [
                                        "type":
                                            "string",

                                        "enum": [
                                            "low",
                                            "medium",
                                            "high",
                                        ],
                                    ],
                                ],
                            ]
                        ]
                    ],
                ],

                "responses": [
                    "201": [
                        "description":
                            "Created",

                        "content": [
                            "application/json": [
                                "schema": [
                                    "type":
                                        "object",

                                    "additionalProperties":
                                        false,

                                    "required": [
                                        "id",
                                        "title",
                                        "priority",
                                    ],

                                    "properties": [
                                        "id": [
                                            "type":
                                                "string"
                                        ],

                                        "title": [
                                            "type":
                                                "string"
                                        ],

                                        "priority": [
                                            "type":
                                                "string",

                                            "enum": [
                                                "low",
                                                "medium",
                                                "high",
                                            ],
                                        ],
                                    ],
                                ]
                            ]
                        ],
                    ],

                    "401": [
                        "description":
                            "Authority required"
                    ],
                ],
            ]

        if let operationSecurity {
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
                        "Unknown Secure Provider",
                    "version":
                        "1.0.0",
                ],

                "components": [
                    "securitySchemes":
                        securitySchemes
                ],

                "paths": [
                    "/records": [
                        "post":
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

        return try JSONSerialization
            .data(
                withJSONObject:
                    root,
                options: [
                    .sortedKeys
                ]
            )
    }

    private func bearerSpec(
        operationSecurity:
            [[String: [String]]]?
                = [
                    [
                        "BearerAuth":
                            []
                    ]
                ],
        rootSecurity:
            [[String: [String]]]?
                = nil
    ) throws -> Data {
        try specification(
            securitySchemes: [
                "BearerAuth": [
                    "type":
                        "http",
                    "scheme":
                        "bearer",
                ]
            ],
            operationSecurity:
                operationSecurity,
            rootSecurity:
                rootSecurity
        )
    }

    private func capability(
        specification:
            Data,
        baseURL:
            String =
                "https://provider.example"
    ) throws -> (
        reflector:
            OpenAPIReflector,
        engine:
            CapabilityEngine,
        capability:
            Capability
    ) {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    specification,
                baseURL:
                    try XCTUnwrap(
                        URL(
                            string:
                                baseURL
                        )
                    ),
                session:
                    session()
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "Create a secure record"
                    )
                    .capabilities
                    .first
            )

        return (
            reflector,
            engine,
            capability
        )
    }

    func testBearerSecurityRequirementReflectsGenericAuthorityMetadataWithoutSecret()
        throws
    {
        let value =
            try capability(
                specification:
                    bearerSpec(),
                baseURL:
                    "HTTPS://PROVIDER.EXAMPLE:443/api/"
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
            "BearerAuth"
        )

        XCTAssertEqual(
            value.capability
                .metadata[
                    "authorityOrigin"
                ],
            "https://provider.example"
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
                "moat003-unit-secret"
            )
        )
    }

    func testMissingBearerAuthorityFailsBeforeTransport()
        throws
    {
        let origin =
            "https://provider.example"

        deleteBearerToken(
            origin:
                origin,
            schemeName:
                "BearerAuth"
        )

        var transportCalled =
            false

        StubURLProtocol.handler = {
            request in

            transportCalled =
                true

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode:
                            401,
                        httpVersion:
                            "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "application/json"
                        ]
                    )
                )

            return (
                response,
                Data(
                    """
                    {"error":"authority required"}
                    """.utf8
                )
            )
        }

        let value =
            try capability(
                specification:
                    bearerSpec()
            )

        let result =
            try value.engine.run(
                id:
                    value.capability.id,
                item:
                    "Create a secure record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Missing authority",
                    "priority":
                        "high",
                ]
            )

        XCTAssertEqual(
            result.status,
            .unavailable
        )

        XCTAssertEqual(
            result.evidence.type,
            "authority_unavailable"
        )

        XCTAssertFalse(
            transportCalled
        )
    }

    func testBearerAuthorityIsInjectedFromOriginBoundKeychainWithoutSecretDisclosure()
        throws
    {
        let origin =
            "https://provider.example"

        let token =
            "moat003-unit-secret-not-for-ai"

        try saveBearerToken(
            token,
            origin:
                origin,
            schemeName:
                "BearerAuth"
        )

        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.url?
                    .absoluteString,
                "https://provider.example/api/records"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Authorization"
                ),
                "Bearer "
                + token
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                ),
                "application/json"
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode:
                            201,
                        httpVersion:
                            "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "application/json"
                        ]
                    )
                )

            return (
                response,
                Data(
                    """
                    {
                      "id": "secure-001",
                      "title": "Authorized",
                      "priority": "high"
                    }
                    """.utf8
                )
            )
        }

        let value =
            try capability(
                specification:
                    bearerSpec(),
                baseURL:
                    "https://provider.example/api"
            )

        let reflectedMetadata =
            value.capability
                .metadata
                .values
                .joined(
                    separator:
                        "\n"
                )

        XCTAssertFalse(
            reflectedMetadata
                .contains(
                    token
                )
        )

        let result =
            try value.engine.begin(
                id:
                    value.capability.id,
                item:
                    "Create a secure record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Authorized",
                    "priority":
                        "high",
                ]
            )

        XCTAssertEqual(
            result.state,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            """
            {"id":"secure-001","priority":"high","title":"Authorized"}
            """
        )

        let observableText =
            (
                [
                    result.message,
                    result.output ?? "",
                ]
                + result.events
            )
            .joined(
                separator:
                    "\n"
            )

        XCTAssertFalse(
            observableText
                .contains(
                    token
                )
        )

        XCTAssertFalse(
            result.evidence
                .boundary
                .contains(
                    token
                )
        )
    }

    func testBearerAuthorityDoesNotCrossOrigin()
        throws
    {
        let providerOrigin =
            "https://provider.example"

        deleteBearerToken(
            origin:
                providerOrigin,
            schemeName:
                "BearerAuth"
        )

        try saveBearerToken(
            "wrong-origin-secret",
            origin:
                "https://other.example",
            schemeName:
                "BearerAuth"
        )

        var transportCalled =
            false

        StubURLProtocol.handler = {
            _ in

            transportCalled =
                true

            throw NSError(
                domain:
                    "ShouldNotReachTransport",
                code:
                    1
            )
        }

        let value =
            try capability(
                specification:
                    bearerSpec(),
                baseURL:
                    providerOrigin
            )

        let result =
            try value.engine.run(
                id:
                    value.capability.id,
                item:
                    "Create a secure record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Wrong origin",
                    "priority":
                        "high",
                ]
            )

        XCTAssertEqual(
            result.status,
            .unavailable
        )

        XCTAssertEqual(
            result.evidence.type,
            "authority_unavailable"
        )

        XCTAssertFalse(
            transportCalled
        )
    }

    func testUnsupportedSecurityRequirementsAbstainRatherThanGuessing()
        throws
    {
        let cases:
            [
                (
                    schemes:
                        [String: [String: Any]],
                    security:
                        [[String: [String]]]
                )
            ] = [
                (
                    schemes: [
                        "ApiKeyAuth": [
                            "type":
                                "apiKey",
                            "in":
                                "header",
                            "name":
                                "X-API-Key",
                        ]
                    ],
                    security: [
                        [
                            "ApiKeyAuth":
                                []
                        ]
                    ]
                ),

                (
                    schemes: [
                        "BasicAuth": [
                            "type":
                                "http",
                            "scheme":
                                "basic",
                        ]
                    ],
                    security: [
                        [
                            "BasicAuth":
                                []
                        ]
                    ]
                ),

                (
                    schemes: [
                        "OAuth": [
                            "type":
                                "oauth2",

                            "flows": [
                                "clientCredentials": [
                                    "tokenUrl":
                                        "https://auth.example/token",

                                    "scopes":
                                        [String: String]()
                                ]
                            ],
                        ]
                    ],
                    security: [
                        [
                            "OAuth":
                                []
                        ]
                    ]
                ),

                (
                    schemes: [
                        "BearerAuth": [
                            "type":
                                "http",
                            "scheme":
                                "bearer",
                        ]
                    ],
                    security: [
                        [
                            "BearerAuth": [
                                "scope-that-must-not-be-guessed"
                            ]
                        ]
                    ]
                ),

                (
                    schemes: [
                        "BearerAuth": [
                            "type":
                                "http",
                            "scheme":
                                "bearer",
                        ]
                    ],
                    security: [
                        [
                            "BearerAuth":
                                []
                        ],
                        [:],
                    ]
                ),

                (
                    schemes: [
                        "BearerAuth": [
                            "type":
                                "http",
                            "scheme":
                                "bearer",
                        ],

                        "SecondBearer": [
                            "type":
                                "http",
                            "scheme":
                                "bearer",
                        ],
                    ],
                    security: [
                        [
                            "BearerAuth":
                                [],
                            "SecondBearer":
                                [],
                        ]
                    ]
                ),
            ]

        for testCase in cases {
            let spec =
                try specification(
                    securitySchemes:
                        testCase.schemes,
                    operationSecurity:
                        testCase.security
                )

            let reflector =
                try OpenAPIReflector(
                    specificationData:
                        spec,
                    baseURL:
                        try XCTUnwrap(
                            URL(
                                string:
                                    "https://provider.example"
                            )
                        ),
                    session:
                        session()
                )

            let engine =
                CapabilityEngine(
                    reflectors: [
                        reflector
                    ]
                )

            XCTAssertTrue(
                try engine
                    .capabilities(
                        for:
                            "Create a secure record"
                    )
                    .capabilities
                    .isEmpty
            )
        }
    }

    func testRootLevelSecurityIsNotSilentlyIgnored()
        throws
    {
        let spec =
            try bearerSpec(
                operationSecurity:
                    nil,
                rootSecurity: [
                    [
                        "BearerAuth":
                            []
                    ]
                ]
            )

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    spec,
                baseURL:
                    try XCTUnwrap(
                        URL(
                            string:
                                "https://provider.example"
                        )
                    ),
                session:
                    session()
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "Create a secure record"
                )
                .capabilities
                .isEmpty
        )
    }

    func testExplicitEmptyOperationSecurityOverridesRootSecurityAsPublic()
        throws
    {
        let spec =
            try bearerSpec(
                operationSecurity:
                    [],
                rootSecurity: [
                    [
                        "BearerAuth":
                            []
                    ]
                ]
            )

        StubURLProtocol.handler = {
            request in

            XCTAssertNil(
                request.value(
                    forHTTPHeaderField:
                        "Authorization"
                )
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode:
                            201,
                        httpVersion:
                            "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "application/json"
                        ]
                    )
                )

            return (
                response,
                Data(
                    """
                    {
                      "id": "public-override",
                      "title": "Public override",
                      "priority": "high"
                    }
                    """.utf8
                )
            )
        }

        let value =
            try capability(
                specification:
                    spec
            )

        XCTAssertNil(
            value.capability
                .metadata[
                    "authorityRequired"
                ]
        )

        let result =
            try value.engine.run(
                id:
                    value.capability.id,
                item:
                    "Create a secure record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Public override",
                    "priority":
                        "high",
                ]
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )
    }
}
