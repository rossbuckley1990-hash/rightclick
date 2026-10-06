import CryptoKit
import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIContinuationBodyRedTests:
    XCTestCase
{
    private struct Fixture {
        let target:
            OpenAPIProviderContinuationTarget

        let body:
            Data
    }

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

    private func fixture()
        throws -> Fixture
    {
        let body =
            Data(
                "RIGHTCLICK BODY 007B3"
                    .utf8
            )

        let proofSHA =
            sha256Hex(
                body
            )

        let proofPath =
            "proof.txt"

        let token =
            "synthetic-provider-token-007b3"

        let sessionID =
            "synthetic-session-007b3"

        let fileID =
            "synthetic-file-007b3"

        let specification:
            [String: Any] = [
                "openapi":
                    "3.1.0",

                "info": [
                    "title":
                        "Body binder test",
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

        let specificationData =
            try JSONSerialization
                .data(
                    withJSONObject:
                        specification,
                    options: [
                        .sortedKeys
                    ]
                )

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
                            body.count,

                        "method":
                            "PUT",

                        "url":
                            "https://provider.example"
                            + "/publish-sessions/"
                            + sessionID
                            + "/files/"
                            + fileID,

                        "headers": [
                            "Authorization":
                                "Bearer "
                                + token,

                            "Content-Type":
                                "text/plain",
                        ],
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
                            proofPath,
                        proofSHA256:
                            proofSHA,
                        proofSize:
                            body.count
                    )
            )

        return Fixture(
            target:
                target,
            body:
                body
        )
    }

    func testExactCandidateBytesBind()
        throws
    {
        let fixture =
            try fixture()

        let body =
            try XCTUnwrap(
                OpenAPIProviderContinuationBodyBinder
                    .bind(
                        target:
                            fixture.target,
                        candidateData:
                            fixture.body
                    )
            )

        XCTAssertEqual(
            body.proofSHA256,
            fixture
                .target
                .proofSHA256
        )

        XCTAssertEqual(
            body.proofSize,
            fixture.body.count
        )

        XCTAssertEqual(
            body.targetFingerprintSHA256,
            fixture
                .target
                .concreteTargetFingerprintSHA256
        )

        print(
            "BODY_007B3 synthetic "
            + "bound=true "
            + "size="
            + String(
                body.proofSize
            )
            + " shaMatch=true "
            + "bytesPrinted=false"
        )
    }

    func testSameLengthWrongByteFailsClosed()
        throws
    {
        let fixture =
            try fixture()

        var wrong =
            fixture.body

        wrong[
            wrong.startIndex
        ] ^= 0x01

        XCTAssertEqual(
            wrong.count,
            fixture.body.count
        )

        XCTAssertNil(
            OpenAPIProviderContinuationBodyBinder
                .bind(
                    target:
                        fixture.target,
                    candidateData:
                        wrong
                )
        )
    }

    func testWrongLengthFailsClosed()
        throws
    {
        let fixture =
            try fixture()

        let wrong =
            fixture.body
            + Data(
                [0x00]
            )

        XCTAssertNil(
            OpenAPIProviderContinuationBodyBinder
                .bind(
                    target:
                        fixture.target,
                    candidateData:
                        wrong
                )
        )
    }

    func testEmptyCandidateFailsClosed()
        throws
    {
        let fixture =
            try fixture()

        XCTAssertNil(
            OpenAPIProviderContinuationBodyBinder
                .bind(
                    target:
                        fixture.target,
                    candidateData:
                        Data()
                )
        )
    }

    func testDescriptionDoesNotLeakBoundBytes()
        throws
    {
        let fixture =
            try fixture()

        let body =
            try XCTUnwrap(
                OpenAPIProviderContinuationBodyBinder
                    .bind(
                        target:
                            fixture.target,
                        candidateData:
                            fixture.body
                    )
            )

        let literal =
            String(
                data:
                    fixture.body,
                encoding:
                    .utf8
            )!

        XCTAssertFalse(
            String(
                describing:
                    body
            )
                .contains(
                    literal
                )
        )

        XCTAssertFalse(
            String(
                reflecting:
                    body
            )
                .contains(
                    literal
                )
        )
    }

    func testRealFrozenProofBindsWithoutChoosingMediaOrTransport()
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

            let proofPath =
                environment[
                    "RIGHTCLICK_CONTINUATION_PROOF_FILE"
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
                "RIGHTCLICK continuation spec, response, proof file and base URL are required for the real body gate."
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

        let proofData =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            proofPath
                    )
            )

        XCTAssertEqual(
            proofData.count,
            179
        )

        XCTAssertEqual(
            sha256Hex(
                proofData
            ),
            "86fd4aa89330ff0953ac9c1f63b9b5602bd986606b91ee1dc76446968795d926"
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

        XCTAssertFalse(
            target.mediaContractMatches
        )

        let body =
            try XCTUnwrap(
                OpenAPIProviderContinuationBodyBinder
                    .bind(
                        target:
                            target,
                        candidateData:
                            proofData
                    )
            )

        XCTAssertEqual(
            body.proofSize,
            179
        )

        XCTAssertEqual(
            body.proofSHA256,
            "86fd4aa89330ff0953ac9c1f63b9b5602bd986606b91ee1dc76446968795d926"
        )

        print(
            "BODY_007B3 real "
            + "bound=true "
            + "size="
            + String(
                body.proofSize
            )
            + " shaMatch=true "
            + "mediaConflict="
            + String(
                !target
                    .mediaContractMatches
            )
            + " transport=false "
            + "bytesPrinted=false"
        )
    }
}
