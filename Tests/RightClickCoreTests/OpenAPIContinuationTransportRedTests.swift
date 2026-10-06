import CryptoKit
import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIContinuationTransportRedTests:
    XCTestCase
{
    private struct Fixture {
        let authority:
            OpenAPIProviderContinuationAuthority

        let target:
            OpenAPIProviderContinuationTarget

        let body:
            OpenAPIProviderContinuationBody

        let bodyData:
            Data

        let expectedURL:
            URL

        let expectedAuthorization:
            String

        let expectedContentType:
            String
    }

    private final class RecordingClient:
        OpenAPIProviderContinuationHTTPClient
    {
        var requests:
            [URLRequest] = []

        var redirectPolicies:
            [OpenAPIProviderContinuationRedirectPolicy]
            = []

        let response:
            OpenAPIProviderContinuationHTTPResponse

        init(
            statusCode: Int,
            data:
                Data = Data(
                    "provider-response"
                        .utf8
                )
        ) {
            self.response =
                OpenAPIProviderContinuationHTTPResponse(
                    statusCode:
                        statusCode,
                    data:
                        data
                )
        }

        func send(
            _ request: URLRequest,
            redirectPolicy:
                OpenAPIProviderContinuationRedirectPolicy
        ) throws
            -> OpenAPIProviderContinuationHTTPResponse
        {
            requests.append(
                request
            )

            redirectPolicies.append(
                redirectPolicy
            )

            return response
        }
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

    private func fixture(
        suffix:
            String,
        bodyData:
            Data? = nil,
        runtimeContentType:
            String = "application/octet-stream"
    ) throws
        -> Fixture
    {
        let bodyData =
            bodyData
            ?? Data(
                (
                    "RIGHTCLICK TRANSPORT "
                    + suffix
                )
                .utf8
            )

        let proofSHA =
            sha256Hex(
                bodyData
            )

        let proofPath =
            "proof-"
            + suffix
            + ".bin"

        let token =
            "token-"
            + suffix

        let sessionID =
            "session-"
            + suffix

        let fileID =
            "file-"
            + suffix

        let origin =
            "https://transport.example"

        let concreteURL =
            try XCTUnwrap(
                URL(
                    string:
                        origin
                        + "/publish-sessions/"
                        + sessionID
                        + "/files/"
                        + fileID
                )
            )

        let authorization =
            "Bearer "
            + token

        let specification:
            [String: Any] = [
                "openapi":
                    "3.1.0",

                "info": [
                    "title":
                        "Continuation transport",
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
                                        "accepted",
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
                            bodyData.count,

                        "method":
                            "PUT",

                        "url":
                            concreteURL
                                .absoluteString,

                        "headers": [
                            "Authorization":
                                authorization,

                            "Content-Type":
                                runtimeContentType,
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
                    origin
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
                            bodyData.count
                    )
            )

        let body =
            try XCTUnwrap(
                OpenAPIProviderContinuationBodyBinder
                    .bind(
                        target:
                            target,
                        candidateData:
                            bodyData
                    )
            )

        return Fixture(
            authority:
                authority,
            target:
                target,
            body:
                body,
            bodyData:
                bodyData,
            expectedURL:
                concreteURL,
            expectedAuthorization:
                authorization,
            expectedContentType:
                runtimeContentType
        )
    }

    func testUnconfirmedMutationProducesZeroRequests()
        throws
    {
        let fixture =
            try fixture(
                suffix:
                    "unconfirmed"
            )

        let client =
            RecordingClient(
                statusCode:
                    204
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        fixture.authority,
                    target:
                        fixture.target,
                    body:
                        fixture.body,
                    confirmed:
                        false,
                    client:
                        client
                )

        guard
            case .confirmationRequired =
                outcome
        else {
            XCTFail(
                "Expected confirmationRequired."
            )
            return
        }

        XCTAssertEqual(
            client.requests.count,
            0
        )

        XCTAssertEqual(
            client.redirectPolicies.count,
            0
        )
    }

    func testMatchingMediaSendsExactBoundWireOnceAndReturnsAcceptedUnverified()
        throws
    {
        let fixture =
            try fixture(
                suffix:
                    "wire"
            )

        let client =
            RecordingClient(
                statusCode:
                    204,
                data:
                    Data(
                        "accepted"
                            .utf8
                    )
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        fixture.authority,
                    target:
                        fixture.target,
                    body:
                        fixture.body,
                    confirmed:
                        true,
                    client:
                        client
                )

        guard
            case let .providerAccepted(
                statusCode,
                responseData,
                semanticOutcomeVerified
            ) =
                outcome
        else {
            XCTFail(
                "Expected providerAccepted."
            )
            return
        }

        XCTAssertEqual(
            statusCode,
            204
        )

        XCTAssertEqual(
            responseData,
            Data(
                "accepted"
                    .utf8
            )
        )

        XCTAssertFalse(
            semanticOutcomeVerified
        )

        XCTAssertEqual(
            client.requests.count,
            1
        )

        XCTAssertEqual(
            client.redirectPolicies,
            [
                .reject
            ]
        )

        let request =
            try XCTUnwrap(
                client.requests.first
            )

        XCTAssertEqual(
            request.url,
            fixture.expectedURL
        )

        XCTAssertEqual(
            request.httpMethod,
            "PUT"
        )

        XCTAssertEqual(
            request.httpBody,
            fixture.bodyData
        )

        XCTAssertEqual(
            request.value(
                forHTTPHeaderField:
                    "Authorization"
            ),
            fixture.expectedAuthorization
        )

        XCTAssertEqual(
            request.value(
                forHTTPHeaderField:
                    "Content-Type"
            ),
            fixture.expectedContentType
        )

        let headerNames =
            Set(
                (
                    request
                        .allHTTPHeaderFields
                    ?? [:]
                )
                .keys
                .map {
                    $0.lowercased()
                }
            )

        XCTAssertEqual(
            headerNames,
            Set(
                [
                    "authorization",
                    "content-type",
                ]
            )
        )

        let authorizationHash =
            sha256Hex(
                Data(
                    fixture
                        .expectedAuthorization
                        .utf8
                )
            )

        print(
            "TRANSPORT_007B5 wire "
            + "requests=1 "
            + "method=PUT "
            + "contentType=application/octet-stream "
            + "bodySHA256="
            + sha256Hex(
                fixture.bodyData
            )
            + " authorizationSHA256="
            + authorizationHash
            + " redirectPolicy=reject "
            + "providerAccepted=true "
            + "semanticVerified=false"
        )
    }

    func testAuthorityTargetMismatchFailsBeforeRequest()
        throws
    {
        let first =
            try fixture(
                suffix:
                    "authority-a"
            )

        let second =
            try fixture(
                suffix:
                    "authority-b"
            )

        let client =
            RecordingClient(
                statusCode:
                    204
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        first.authority,
                    target:
                        second.target,
                    body:
                        second.body,
                    confirmed:
                        true,
                    client:
                        client
                )

        guard
            case let .bindingRejected(
                reason
            ) =
                outcome
        else {
            XCTFail(
                "Expected binding rejection."
            )
            return
        }

        XCTAssertEqual(
            reason.rawValue,
            "authority_target_response_mismatch"
        )

        XCTAssertEqual(
            client.requests.count,
            0
        )
    }

    func testBodyTargetMismatchFailsBeforeRequest()
        throws
    {
        let first =
            try fixture(
                suffix:
                    "body-a"
            )

        let second =
            try fixture(
                suffix:
                    "body-b"
            )

        let client =
            RecordingClient(
                statusCode:
                    204
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        first.authority,
                    target:
                        first.target,
                    body:
                        second.body,
                    confirmed:
                        true,
                    client:
                        client
                )

        guard
            case let .bindingRejected(
                reason
            ) =
                outcome
        else {
            XCTFail(
                "Expected body binding rejection."
            )
            return
        }

        XCTAssertEqual(
            reason.rawValue,
            "body_target_mismatch"
        )

        XCTAssertEqual(
            client.requests.count,
            0
        )
    }

    func testRedirectResponseIsRejectedWithRejectPolicy()
        throws
    {
        let fixture =
            try fixture(
                suffix:
                    "redirect"
            )

        let client =
            RecordingClient(
                statusCode:
                    302
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        fixture.authority,
                    target:
                        fixture.target,
                    body:
                        fixture.body,
                    confirmed:
                        true,
                    client:
                        client
                )

        guard
            case let .redirectRejected(
                statusCode
            ) =
                outcome
        else {
            XCTFail(
                "Expected redirectRejected."
            )
            return
        }

        XCTAssertEqual(
            statusCode,
            302
        )

        XCTAssertEqual(
            client.requests.count,
            1
        )

        XCTAssertEqual(
            client.redirectPolicies,
            [
                .reject
            ]
        )
    }

    func testNon2xxIsProviderRejected()
        throws
    {
        let fixture =
            try fixture(
                suffix:
                    "rejected"
            )

        let client =
            RecordingClient(
                statusCode:
                    500,
                data:
                    Data(
                        "provider-error"
                            .utf8
                    )
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        fixture.authority,
                    target:
                        fixture.target,
                    body:
                        fixture.body,
                    confirmed:
                        true,
                    client:
                        client
                )

        guard
            case let .providerRejected(
                statusCode,
                responseData
            ) =
                outcome
        else {
            XCTFail(
                "Expected providerRejected."
            )
            return
        }

        XCTAssertEqual(
            statusCode,
            500
        )

        XCTAssertEqual(
            responseData,
            Data(
                "provider-error"
                    .utf8
            )
        )

        XCTAssertEqual(
            client.requests.count,
            1
        )
    }

    func testRealTempMDMediaAbstentionProducesZeroRequests()
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

            let proofFilePath =
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
                "RIGHTCLICK continuation spec, response, proof and base URL are required for the real transport abstention gate."
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
                            proofFilePath
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

        let client =
            RecordingClient(
                statusCode:
                    204
            )

        let outcome =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        authority,
                    target:
                        target,
                    body:
                        body,
                    confirmed:
                        true,
                    client:
                        client
                )

        guard
            case let .mediaAbstained(
                reason
            ) =
                outcome
        else {
            XCTFail(
                "Real temp.md must remain media-abstained."
            )
            return
        }

        XCTAssertEqual(
            reason.rawValue,
            "static_dynamic_conflict"
        )

        XCTAssertEqual(
            client.requests.count,
            0
        )

        XCTAssertEqual(
            client.redirectPolicies.count,
            0
        )

        print(
            "TRANSPORT_007B5 real_temp_md "
            + "resolution=ABSTAIN "
            + "reason=static_dynamic_conflict "
            + "requests=0 "
            + "safeToUpload=false"
        )
    }
}
