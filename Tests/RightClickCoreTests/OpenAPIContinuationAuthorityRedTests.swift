import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIContinuationAuthorityRedTests:
    XCTestCase
{
    private func specification(
        security: [Any],
        schemes: [String: Any]
    ) throws -> Data {
        let root:
            [String: Any] = [
                "openapi":
                    "3.1.0",

                "info": [
                    "title":
                        "Authority test",
                    "version":
                        "1.0.0",
                ],

                "components": [
                    "securitySchemes":
                        schemes,
                ],

                "paths": [
                    "/upload": [
                        "put": [
                            "operationId":
                                "uploadThing",

                            "security":
                                security,

                            "responses": [
                                "204": [
                                    "description":
                                        "ok",
                                ],
                            ],
                        ],
                    ],
                ],
            ]

        return try JSONSerialization
            .data(
                withJSONObject:
                    root,
                options: [
                    .sortedKeys
                ]
            )
    }

    private func bearerScheme()
        -> [String: Any]
    {
        [
            "type":
                "http",
            "scheme":
                "bearer",
        ]
    }

    func testSyntheticProviderResponseBindsSingleDeclaredBearerScheme()
        throws
    {
        let token =
            "synthetic-provider-secret-007b1"

        let spec =
            try specification(
                security: [
                    [
                        "sessionBearer":
                            [],
                    ],
                ],
                schemes: [
                    "sessionBearer":
                        bearerScheme(),
                ]
            )

        let response =
            try JSONSerialization
                .data(
                    withJSONObject: [
                        "uploadToken":
                            token,

                        "uploads": [
                            [
                                "headers": [
                                    "Authorization":
                                        "Bearer "
                                        + token,
                                ],
                            ],
                        ],
                    ],
                    options: [
                        .sortedKeys
                    ]
                )

        let authority =
            try XCTUnwrap(
                OpenAPIProviderContinuationAuthorityBinder
                    .bind(
                        specificationData:
                            spec,
                        providerResponseData:
                            response,
                        targetOperationID:
                            "uploadThing",
                        providerBaseURL:
                            URL(
                                string:
                                    "https://provider.example"
                            )!
                    )
            )

        XCTAssertEqual(
            authority.schemeName,
            "sessionBearer"
        )

        XCTAssertEqual(
            authority.targetOperationID,
            "uploadThing"
        )

        XCTAssertEqual(
            authority.providerOrigin,
            "https://provider.example"
        )

        XCTAssertEqual(
            authority.sourceResponseSHA256.count,
            64
        )

        XCTAssertEqual(
            authority.credentialFingerprintSHA256.count,
            64
        )

        XCTAssertFalse(
            String(
                describing:
                    authority
            )
                .contains(
                    token
                )
        )

        XCTAssertFalse(
            String(
                reflecting:
                    authority
            )
                .contains(
                    token
                )
        )

        print(
            "AUTHORITY_007B1 synthetic "
            + "bound=true "
            + "scheme="
            + authority.schemeName
            + " secretPrinted=false"
        )
    }

    func testMismatchedProviderBearerRecipeDoesNotBind()
        throws
    {
        let spec =
            try specification(
                security: [
                    [
                        "sessionBearer":
                            [],
                    ],
                ],
                schemes: [
                    "sessionBearer":
                        bearerScheme(),
                ]
            )

        let response =
            try JSONSerialization
                .data(
                    withJSONObject: [
                        "uploadToken":
                            "token-A",

                        "uploads": [
                            [
                                "headers": [
                                    "Authorization":
                                        "Bearer token-B",
                                ],
                            ],
                        ],
                    ]
                )

        XCTAssertNil(
            OpenAPIProviderContinuationAuthorityBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        response,
                    targetOperationID:
                        "uploadThing",
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!
                )
        )
    }

    func testAnonymousAlternativeCannotCreateCredentialBinding()
        throws
    {
        let spec =
            try specification(
                security: [
                    [:],
                    [
                        "sessionBearer":
                            [],
                    ],
                ],
                schemes: [
                    "sessionBearer":
                        bearerScheme(),
                ]
            )

        let token =
            "provider-token"

        let response =
            try JSONSerialization
                .data(
                    withJSONObject: [
                        "uploadToken":
                            token,

                        "headers": [
                            "Authorization":
                                "Bearer "
                                + token,
                        ],
                    ]
                )

        XCTAssertNil(
            OpenAPIProviderContinuationAuthorityBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        response,
                    targetOperationID:
                        "uploadThing",
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!
                )
        )
    }

    func testAmbiguousBearerSchemesAbstain()
        throws
    {
        let spec =
            try specification(
                security: [
                    [
                        "bearerA":
                            [],
                    ],
                    [
                        "bearerB":
                            [],
                    ],
                ],
                schemes: [
                    "bearerA":
                        bearerScheme(),
                    "bearerB":
                        bearerScheme(),
                ]
            )

        let token =
            "provider-token"

        let response =
            try JSONSerialization
                .data(
                    withJSONObject: [
                        "uploadToken":
                            token,

                        "headers": [
                            "Authorization":
                                "Bearer "
                                + token,
                        ],
                    ]
                )

        XCTAssertNil(
            OpenAPIProviderContinuationAuthorityBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        response,
                    targetOperationID:
                        "uploadThing",
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!
                )
        )
    }

    func testRealTempMDResponseBindsPublishSessionTokenWithoutDisclosure()
        throws
    {
        let environment =
            ProcessInfo
                .processInfo
                .environment

        guard
            let specificationPath =
                environment[
                    "RIGHTCLICK_CONTINUATION_SPEC"
                ],

            let responsePath =
                environment[
                    "RIGHTCLICK_CONTINUATION_RAW_RESPONSE"
                ],

            let baseURLString =
                environment[
                    "RIGHTCLICK_CONTINUATION_BASE_URL"
                ],

            let baseURL =
                URL(
                    string:
                        baseURLString
                )
        else {
            throw XCTSkip(
                "RIGHTCLICK continuation spec, raw response and base URL are required for the real authority gate."
            )
        }

        let specificationData =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            specificationPath
                    )
            )

        let providerResponseData =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            responsePath
                    )
            )

        let authority =
            try XCTUnwrap(
                OpenAPIProviderContinuationAuthorityBinder
                    .bind(
                        specificationData:
                            specificationData,
                        providerResponseData:
                            providerResponseData,
                        targetOperationID:
                            "uploadPublishSessionFile",
                        providerBaseURL:
                            baseURL
                    )
            )

        XCTAssertEqual(
            authority.schemeName,
            "publishSessionToken"
        )

        XCTAssertEqual(
            authority.targetOperationID,
            "uploadPublishSessionFile"
        )

        XCTAssertEqual(
            authority.providerOrigin,
            "https://api.temp.md"
        )

        XCTAssertEqual(
            authority.sourceResponseSHA256,
            "6601209aac38928cd25ee7f8366d4d000dd89138c959eb3015f663575345d379"
        )

        let response =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            providerResponseData
                    )
                    as? [String: Any]
            )

        let token =
            try XCTUnwrap(
                response[
                    "uploadToken"
                ] as? String
            )

        XCTAssertFalse(
            String(
                describing:
                    authority
            )
                .contains(
                    token
                )
        )

        XCTAssertFalse(
            String(
                reflecting:
                    authority
            )
                .contains(
                    token
                )
        )

        print(
            "AUTHORITY_007B1 real "
            + "bound=true "
            + "scheme="
            + authority.schemeName
            + " operation="
            + authority.targetOperationID
            + " sourceResponseSHA256="
            + authority.sourceResponseSHA256
            + " credentialFingerprintLength="
            + String(
                authority
                    .credentialFingerprintSHA256
                    .count
            )
            + " secretPrinted=false"
        )
    }
}
