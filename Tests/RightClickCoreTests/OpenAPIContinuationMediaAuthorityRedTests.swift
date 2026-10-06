import CryptoKit
import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIContinuationMediaAuthorityRedTests:
    XCTestCase
{
    private func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256
            .hash(
                data:
                    data
            )
            .map {
                String(
                    format:
                        "%02x",
                    $0
                )
            }
            .joined()
    }

    private func target(
        declaredMedia:
            [String],
        runtimeContentType:
            String?
    ) throws
        -> OpenAPIProviderContinuationTarget
    {
        let proof =
            Data(
                "MEDIA-007B4B"
                    .utf8
            )

        let proofSHA =
            sha256Hex(
                proof
            )

        let proofPath =
            "proof.txt"

        let sessionID =
            "media-session-007b4b"

        let fileID =
            "media-file-007b4b"

        let token =
            "media-provider-token-007b4b"

        var content:
            [String: Any] = [:]

        for media
            in declaredMedia
        {
            content[
                media
            ] = [
                "schema": [
                    "type":
                        "string",
                    "format":
                        "binary",
                ],
            ]
        }

        let specification:
            [String: Any] = [
                "openapi":
                    "3.1.0",

                "info": [
                    "title":
                        "Media authority test",
                    "version":
                        "1",
                ],

                "components": [
                    "securitySchemes": [
                        "sessionBearer": [
                            "type":
                                "http",
                            "scheme":
                                "bearer",
                        ],
                    ],
                ],

                "paths": [
                    "/publish-sessions/{sessionId}/files/{fileId}": [
                        "put": [
                            "operationId":
                                "uploadThing",

                            "security": [
                                [
                                    "sessionBearer":
                                        [],
                                ],
                            ],

                            "parameters": [
                                [
                                    "name":
                                        "sessionId",
                                    "in":
                                        "path",
                                    "required":
                                        true,
                                    "schema": [
                                        "type":
                                            "string",
                                    ],
                                ],
                                [
                                    "name":
                                        "fileId",
                                    "in":
                                        "path",
                                    "required":
                                        true,
                                    "schema": [
                                        "type":
                                            "string",
                                    ],
                                ],
                            ],

                            "requestBody": [
                                "required":
                                    true,

                                "content":
                                    content,
                            ],

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

        let specificationData =
            try JSONSerialization
                .data(
                    withJSONObject:
                        specification,
                    options: [
                        .sortedKeys
                    ]
                )

        var headers:
            [String: String] = [
                "Authorization":
                    "Bearer "
                    + token,
            ]

        if
            let runtimeContentType
        {
            headers[
                "Content-Type"
            ] =
                runtimeContentType
        }

        let response:
            [String: Any] = [
                "sessionId":
                    sessionID,

                "uploadToken":
                    token,

                "uploads": [
                    [
                        "fileId":
                            fileID,

                        "path":
                            proofPath,

                        "hash":
                            proofSHA,

                        "size":
                            proof.count,

                        "method":
                            "PUT",

                        "url":
                            "https://provider.example"
                            + "/publish-sessions/"
                            + sessionID
                            + "/files/"
                            + fileID,

                        "headers":
                            headers,
                    ],
                ],
            ]

        let responseData =
            try JSONSerialization
                .data(
                    withJSONObject:
                        response,
                    options: [
                        .sortedKeys
                    ]
                )

        let baseURL =
            URL(
                string:
                    "https://provider.example"
            )!

        let authority =
            try XCTUnwrap(
                OpenAPIProviderContinuationAuthorityBinder
                    .bind(
                        specificationData:
                            specificationData,
                        providerResponseData:
                            responseData,
                        targetOperationID:
                            "uploadThing",
                        providerBaseURL:
                            baseURL
                    )
            )

        return try XCTUnwrap(
            OpenAPIProviderContinuationTargetBinder
                .bind(
                    specificationData:
                        specificationData,
                    providerResponseData:
                        responseData,
                    authority:
                        authority,
                    providerBaseURL:
                        baseURL,
                    proofPath:
                        proofPath,
                    proofSHA256:
                        proofSHA,
                    proofSize:
                        proof.count
                )
        )
    }

    func testExactStaticRuntimeMatchResolves()
        throws
    {
        let target =
            try target(
                declaredMedia: [
                    "application/octet-stream",
                ],
                runtimeContentType:
                    "application/octet-stream"
            )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .resolved(
                authority
            ) =
                resolution
        else {
            XCTFail(
                "Expected exact media agreement to resolve."
            )
            return
        }

        XCTAssertEqual(
            authority.selectedContentType,
            "application/octet-stream"
        )

        XCTAssertEqual(
            authority.normalizedContentType,
            "application/octet-stream"
        )

        XCTAssertEqual(
            authority.matchingDeclaredMediaType,
            "application/octet-stream"
        )

        XCTAssertEqual(
            authority.source,
            "static_and_runtime_agree"
        )

        print(
            "MEDIA_007B4B exact "
            + "resolution=RESOLVED "
            + "selected="
            + authority
                .selectedContentType
            + " transport=false"
        )
    }

    func testParameterizedRuntimeExactBaseMediaResolves()
        throws
    {
        let target =
            try target(
                declaredMedia: [
                    "application/octet-stream",
                ],
                runtimeContentType:
                    "application/octet-stream; version=1"
            )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .resolved(
                authority
            ) =
                resolution
        else {
            XCTFail(
                "Expected parameterized runtime media to match its base declaration."
            )
            return
        }

        XCTAssertEqual(
            authority.selectedContentType,
            "application/octet-stream; version=1"
        )

        XCTAssertEqual(
            authority.normalizedContentType,
            "application/octet-stream"
        )
    }

    func testDeclaredSubtypeWildcardResolves()
        throws
    {
        let target =
            try target(
                declaredMedia: [
                    "text/*",
                ],
                runtimeContentType:
                    "text/plain"
            )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .resolved(
                authority
            ) =
                resolution
        else {
            XCTFail(
                "Expected declared subtype wildcard to resolve."
            )
            return
        }

        XCTAssertEqual(
            authority.selectedContentType,
            "text/plain"
        )

        XCTAssertEqual(
            authority.matchingDeclaredMediaType,
            "text/*"
        )
    }

    func testStaticDynamicConflictAbstains()
        throws
    {
        let target =
            try target(
                declaredMedia: [
                    "application/octet-stream",
                ],
                runtimeContentType:
                    "text/plain"
            )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .abstain(
                abstention
            ) =
                resolution
        else {
            XCTFail(
                "Conflict must abstain."
            )
            return
        }

        XCTAssertEqual(
            abstention.reason.rawValue,
            "static_dynamic_conflict"
        )

        XCTAssertEqual(
            abstention.runtimeContentType,
            "text/plain"
        )

        XCTAssertEqual(
            abstention.declaredRequestMedia,
            [
                "application/octet-stream",
            ]
        )
    }

    func testMissingRuntimeContentTypeAbstains()
        throws
    {
        let target =
            try target(
                declaredMedia: [
                    "application/octet-stream",
                ],
                runtimeContentType:
                    nil
            )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .abstain(
                abstention
            ) =
                resolution
        else {
            XCTFail(
                "Missing runtime Content-Type must abstain."
            )
            return
        }

        XCTAssertEqual(
            abstention.reason.rawValue,
            "missing_runtime_content_type"
        )
    }

    func testInvalidRuntimeContentTypeAbstains()
        throws
    {
        let target =
            try target(
                declaredMedia: [
                    "application/octet-stream",
                ],
                runtimeContentType:
                    "not-a-media-type"
            )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .abstain(
                abstention
            ) =
                resolution
        else {
            XCTFail(
                "Invalid runtime Content-Type must abstain."
            )
            return
        }

        XCTAssertEqual(
            abstention.reason.rawValue,
            "invalid_runtime_content_type"
        )
    }

    func testRealTempMDConflictAbstainsWithoutSelectingMediaOrTransport()
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
                "RIGHTCLICK continuation spec, response and base URL are required for the real media gate."
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

        let responseData =
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
                            responseData,
                        targetOperationID:
                            "uploadPublishSessionFile",
                        providerBaseURL:
                            baseURL
                    )
            )

        let target =
            try XCTUnwrap(
                OpenAPIProviderContinuationTargetBinder
                    .bind(
                        specificationData:
                            specificationData,
                        providerResponseData:
                            responseData,
                        authority:
                            authority,
                        providerBaseURL:
                            baseURL,
                        proofPath:
                            "rightclick-northstar-proof.txt",
                        proofSHA256:
                            "86fd4aa89330ff0953ac9c1f63b9b5602bd986606b91ee1dc76446968795d926",
                        proofSize:
                            179
                    )
            )

        XCTAssertEqual(
            target.providerReturnedContentType,
            "text/plain"
        )

        XCTAssertEqual(
            target.declaredRequestMedia,
            [
                "application/octet-stream",
            ]
        )

        let resolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .abstain(
                abstention
            ) =
                resolution
        else {
            XCTFail(
                "Real temp.md media conflict must abstain."
            )
            return
        }

        XCTAssertEqual(
            abstention.reason.rawValue,
            "static_dynamic_conflict"
        )

        XCTAssertEqual(
            abstention.runtimeContentType,
            "text/plain"
        )

        XCTAssertEqual(
            abstention.declaredRequestMedia,
            [
                "application/octet-stream",
            ]
        )

        print(
            "MEDIA_007B4B real "
            + "resolution=ABSTAIN "
            + "reason="
            + abstention
                .reason
                .rawValue
            + " runtime=text/plain "
            + "declared=application/octet-stream "
            + "selected=false "
            + "transport=false"
        )
    }
}
