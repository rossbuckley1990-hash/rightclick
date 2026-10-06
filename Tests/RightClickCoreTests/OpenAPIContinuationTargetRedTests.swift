import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIContinuationTargetRedTests:
    XCTestCase
{
    private let proofPath =
        "proof.txt"

    private let proofSHA256 =
        String(
            repeating:
                "a",
            count:
                64
        )

    private let proofSize =
        7

    private let token =
        "synthetic-provider-token-007b2"

    private let sessionID =
        "private-session-007b2"

    private let fileID =
        "private-file-007b2"

    private func specification()
        throws -> Data
    {
        let root:
            [String: Any] = [
                "openapi":
                    "3.1.0",

                "info": [
                    "title":
                        "Target test",
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

                    "parameters": [
                        "SessionId": [
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

                        "FileId": [
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
                                    "$ref":
                                        "#/components/parameters/SessionId",
                                ],
                                [
                                    "$ref":
                                        "#/components/parameters/FileId",
                                ],
                            ],

                            "requestBody": [
                                "required":
                                    true,

                                "content": [
                                    "application/octet-stream": [
                                        "schema": [
                                            "type":
                                                "string",
                                            "format":
                                                "binary",
                                        ],
                                    ],
                                ],
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

        return try JSONSerialization
            .data(
                withJSONObject:
                    root,
                options: [
                    .sortedKeys
                ]
            )
    }

    private func response(
        origin: String = "https://provider.example",
        method: String = "PUT",
        pathOverride: String? = nil,
        duplicate: Bool = false
    ) throws -> Data {
        let path =
            pathOverride
            ?? (
                "/publish-sessions/"
                + sessionID
                + "/files/"
                + fileID
            )

        let recipe:
            [String: Any] = [
                "fileId":
                    fileID,

                "path":
                    proofPath,

                "hash":
                    proofSHA256,

                "size":
                    proofSize,

                "method":
                    method,

                "url":
                    origin
                    + path,

                "headers": [
                    "Authorization":
                        "Bearer "
                        + token,

                    "Content-Type":
                        "text/plain",
                ],
            ]

        let uploads:
            [[String: Any]] =
                duplicate
                ? [
                    recipe,
                    recipe,
                ]
                : [
                    recipe
                ]

        return try JSONSerialization
            .data(
                withJSONObject: [
                    "sessionId":
                        sessionID,

                    "uploadToken":
                        token,

                    "uploads":
                        uploads,
                ],
                options: [
                    .sortedKeys
                ]
            )
    }

    private func authority(
        specificationData: Data,
        responseData: Data
    ) throws
        -> OpenAPIProviderContinuationAuthority
    {
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
                        URL(
                            string:
                                "https://provider.example"
                        )!
                )
        )
    }

    func testSyntheticProviderRecipeBindsPrivateConcreteTarget()
        throws
    {
        let spec =
            try specification()

        let responseData =
            try response()

        let authority =
            try authority(
                specificationData:
                    spec,
                responseData:
                    responseData
            )

        let target =
            try XCTUnwrap(
                OpenAPIProviderContinuationTargetBinder
                    .bind(
                        specificationData:
                            spec,
                        providerResponseData:
                            responseData,
                        authority:
                            authority,
                        providerBaseURL:
                            URL(
                                string:
                                    "https://provider.example"
                            )!,
                        proofPath:
                            proofPath,
                        proofSHA256:
                            proofSHA256,
                        proofSize:
                            proofSize
                    )
            )

        XCTAssertEqual(
            target.operationID,
            "uploadThing"
        )

        XCTAssertEqual(
            target.method,
            "PUT"
        )

        XCTAssertEqual(
            target.providerOrigin,
            "https://provider.example"
        )

        XCTAssertEqual(
            target.pathTemplate,
            "/publish-sessions/{sessionId}/files/{fileId}"
        )

        XCTAssertEqual(
            target.requiredPathParameters,
            [
                "fileId",
                "sessionId",
            ]
        )

        XCTAssertEqual(
            target.providerReturnedContentType,
            "text/plain"
        )

        XCTAssertEqual(
            target.declaredRequestMedia,
            [
                "application/octet-stream"
            ]
        )

        XCTAssertFalse(
            target.mediaContractMatches
        )

        let description =
            String(
                describing:
                    target
            )

        XCTAssertFalse(
            description
                .contains(
                    sessionID
                )
        )

        XCTAssertFalse(
            description
                .contains(
                    fileID
                )
        )

        XCTAssertFalse(
            description
                .contains(
                    "https://provider.example/publish-sessions/"
                )
        )

        print(
            "TARGET_007B2 synthetic "
            + "bound=true "
            + "operation="
            + target.operationID
            + " method="
            + target.method
            + " sameOrigin=true "
            + "mediaConflict="
            + String(
                !target
                    .mediaContractMatches
            )
            + " targetSecretsPrinted=false"
        )
    }

    func testWrongOriginFailsClosed()
        throws
    {
        let spec =
            try specification()

        let responseData =
            try response(
                origin:
                    "https://attacker.example"
            )

        // GREEN-007B1 binds credential provenance and the named
        // OpenAPI security scheme. It deliberately does not inspect
        // continuation URLs.
        let authority =
            try authority(
                specificationData:
                    spec,
                responseData:
                    responseData
            )

        XCTAssertEqual(
            authority.providerOrigin,
            "https://provider.example"
        )

        // GREEN-007B2 owns concrete-target authority. The provider-
        // returned attacker origin must therefore fail here.
        XCTAssertNil(
            OpenAPIProviderContinuationTargetBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        responseData,
                    authority:
                        authority,
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!,
                    proofPath:
                        proofPath,
                    proofSHA256:
                        proofSHA256,
                    proofSize:
                        proofSize
                )
        )
    }

    func testWrongConcretePathFailsClosed()
        throws
    {
        let spec =
            try specification()

        let responseData =
            try response(
                pathOverride:
                    "/unexpected/"
                    + sessionID
                    + "/"
                    + fileID
            )

        let authority =
            try authority(
                specificationData:
                    spec,
                responseData:
                    responseData
            )

        XCTAssertNil(
            OpenAPIProviderContinuationTargetBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        responseData,
                    authority:
                        authority,
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!,
                    proofPath:
                        proofPath,
                    proofSHA256:
                        proofSHA256,
                    proofSize:
                        proofSize
                )
        )
    }

    func testWrongMethodFailsClosed()
        throws
    {
        let spec =
            try specification()

        let responseData =
            try response(
                method:
                    "POST"
            )

        let authority =
            try authority(
                specificationData:
                    spec,
                responseData:
                    responseData
            )

        XCTAssertNil(
            OpenAPIProviderContinuationTargetBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        responseData,
                    authority:
                        authority,
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!,
                    proofPath:
                        proofPath,
                    proofSHA256:
                        proofSHA256,
                    proofSize:
                        proofSize
                )
        )
    }

    func testAmbiguousDuplicateRecipeFailsClosed()
        throws
    {
        let spec =
            try specification()

        let responseData =
            try response(
                duplicate:
                    true
            )

        let authority =
            try authority(
                specificationData:
                    spec,
                responseData:
                    responseData
            )

        XCTAssertNil(
            OpenAPIProviderContinuationTargetBinder
                .bind(
                    specificationData:
                        spec,
                    providerResponseData:
                        responseData,
                    authority:
                        authority,
                    providerBaseURL:
                        URL(
                            string:
                                "https://provider.example"
                        )!,
                    proofPath:
                        proofPath,
                    proofSHA256:
                        proofSHA256,
                    proofSize:
                        proofSize
                )
        )
    }

    func testRealTempMDResponseBindsPrivateTargetWithoutResolvingMediaConflict()
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
                "RIGHTCLICK continuation spec, raw response and base URL are required for the real target gate."
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
            target.operationID,
            "uploadPublishSessionFile"
        )

        XCTAssertEqual(
            target.method,
            "PUT"
        )

        XCTAssertEqual(
            target.providerOrigin,
            "https://api.temp.md"
        )

        XCTAssertEqual(
            target.requiredPathParameters,
            [
                "fileId",
                "sessionId",
            ]
        )

        XCTAssertEqual(
            target.providerReturnedContentType,
            "text/plain"
        )

        XCTAssertEqual(
            target.declaredRequestMedia,
            [
                "application/octet-stream"
            ]
        )

        XCTAssertFalse(
            target.mediaContractMatches
        )

        let raw =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            responseData
                    )
                    as? [String: Any]
            )

        let sessionID =
            try XCTUnwrap(
                raw[
                    "sessionId"
                ] as? String
            )

        let uploads =
            try XCTUnwrap(
                raw[
                    "uploads"
                ] as? [[String: Any]]
            )

        let upload =
            try XCTUnwrap(
                uploads.first
            )

        let fileID =
            try XCTUnwrap(
                upload[
                    "fileId"
                ] as? String
            )

        let concreteURL =
            try XCTUnwrap(
                upload[
                    "url"
                ] as? String
            )

        let description =
            String(
                describing:
                    target
            )

        XCTAssertFalse(
            description
                .contains(
                    sessionID
                )
        )

        XCTAssertFalse(
            description
                .contains(
                    fileID
                )
        )

        XCTAssertFalse(
            description
                .contains(
                    concreteURL
                )
        )

        print(
            "TARGET_007B2 real "
            + "bound=true "
            + "operation="
            + target.operationID
            + " method="
            + target.method
            + " requiredPathParameters="
            + target
                .requiredPathParameters
                .joined(
                    separator:
                        ","
                )
            + " providerContentType="
            + (
                target
                    .providerReturnedContentType
                ?? "none"
            )
            + " declaredMedia="
            + target
                .declaredRequestMedia
                .joined(
                    separator:
                        ","
                )
            + " mediaConflict="
            + String(
                !target
                    .mediaContractMatches
            )
            + " targetSecretsPrinted=false"
        )
    }
}
