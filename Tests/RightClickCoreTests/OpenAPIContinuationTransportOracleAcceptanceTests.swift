import CryptoKit
import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIContinuationTransportOracleAcceptanceTests:
    XCTestCase
{
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
            statusCode: Int
        ) {
            self.response =
                OpenAPIProviderContinuationHTTPResponse(
                    statusCode:
                        statusCode,
                    data:
                        Data(
                            "oracle-accepted"
                                .utf8
                        )
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

    func testExactFrozenRED007B5Oracle()
        throws
    {
        let environment =
            ProcessInfo
                .processInfo
                .environment

        guard
            let specPath =
                environment[
                    "RIGHTCLICK_ORACLE_SPEC"
                ],

            let responsePath =
                environment[
                    "RIGHTCLICK_ORACLE_RESPONSE"
                ],

            let bodyPath =
                environment[
                    "RIGHTCLICK_ORACLE_BODY"
                ],

            let oraclePath =
                environment[
                    "RIGHTCLICK_ORACLE_JSON"
                ]
        else {
            throw XCTSkip(
                "Exact RED-007B5 oracle fixture paths are required."
            )
        }

        let specificationData =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            specPath
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

        let bodyData =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            bodyPath
                    )
            )

        let oracleData =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            oraclePath
                    )
            )

        let oracle =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            oracleData
                    )
                    as? [String: Any]
            )

        let providerResponse =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            responseData
                    )
                    as? [String: Any]
            )

        let operationID =
            try XCTUnwrap(
                oracle[
                    "operationId"
                ] as? String
            )

        let origin =
            try XCTUnwrap(
                oracle[
                    "origin"
                ] as? String
            )

        let expectedPath =
            try XCTUnwrap(
                oracle[
                    "path"
                ] as? String
            )

        let expectedMethod =
            try XCTUnwrap(
                oracle[
                    "method"
                ] as? String
            )

        let expectedContentType =
            try XCTUnwrap(
                oracle[
                    "contentType"
                ] as? String
            )

        let expectedBodySHA =
            try XCTUnwrap(
                oracle[
                    "bodySHA256"
                ] as? String
            )

        let expectedBodySize =
            try XCTUnwrap(
                oracle[
                    "bodySize"
                ] as? Int
            )

        let expectedAuthorizationSHA =
            try XCTUnwrap(
                oracle[
                    "authorizationSHA256"
                ] as? String
            )

        let expectedHeaderNames =
            try XCTUnwrap(
                oracle[
                    "expectedHeaderNames"
                ] as? [String]
            )

        let baseURL =
            try XCTUnwrap(
                URL(
                    string:
                        origin
                )
            )

        let expectedURL =
            try XCTUnwrap(
                URL(
                    string:
                        origin
                        + expectedPath
                )
            )

        XCTAssertEqual(
            bodyData.count,
            expectedBodySize
        )

        XCTAssertEqual(
            sha256Hex(
                bodyData
            ),
            expectedBodySHA
        )

        let uploads =
            try XCTUnwrap(
                providerResponse[
                    "uploads"
                ] as? [[String: Any]]
            )

        XCTAssertEqual(
            uploads.count,
            1
        )

        let recipe =
            try XCTUnwrap(
                uploads.first
            )

        let proofPath =
            try XCTUnwrap(
                recipe[
                    "path"
                ] as? String
            )

        let proofSHA =
            try XCTUnwrap(
                recipe[
                    "hash"
                ] as? String
            )

        let proofSize =
            try XCTUnwrap(
                recipe[
                    "size"
                ] as? Int
            )

        XCTAssertEqual(
            proofSHA,
            expectedBodySHA
        )

        XCTAssertEqual(
            proofSize,
            expectedBodySize
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
                            operationID,
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
                            proofSize
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

        let mediaResolution =
            OpenAPIProviderContinuationMediaAuthorityBinder
                .resolve(
                    target:
                        target
                )

        guard
            case let .resolved(
                mediaAuthority
            ) =
                mediaResolution
        else {
            XCTFail(
                "Exact RED oracle must have matching media."
            )
            return
        }

        XCTAssertEqual(
            mediaAuthority
                .selectedContentType,
            expectedContentType
        )

        // First replay the preregistered unconfirmed branch.
        let unconfirmedClient =
            RecordingClient(
                statusCode:
                    204
            )

        let unconfirmed =
            try OpenAPIProviderContinuationTransport
                .execute(
                    authority:
                        authority,
                    target:
                        target,
                    body:
                        body,
                    confirmed:
                        false,
                    client:
                        unconfirmedClient
                )

        guard
            case .confirmationRequired =
                unconfirmed
        else {
            XCTFail(
                "Unconfirmed exact oracle must stop before transport."
            )
            return
        }

        XCTAssertEqual(
            unconfirmedClient
                .requests
                .count,
            try XCTUnwrap(
                oracle[
                    "requestCountWhenUnconfirmed"
                ] as? Int
            )
        )

        // Now replay the exact confirmed branch.
        let confirmedClient =
            RecordingClient(
                statusCode:
                    204
            )

        let confirmed =
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
                        confirmedClient
                )

        guard
            case let .providerAccepted(
                statusCode,
                _,
                semanticOutcomeVerified
            ) =
                confirmed
        else {
            XCTFail(
                "Exact frozen oracle did not reach providerAccepted."
            )
            return
        }

        XCTAssertEqual(
            statusCode,
            204
        )

        XCTAssertFalse(
            semanticOutcomeVerified
        )

        XCTAssertEqual(
            confirmedClient
                .requests
                .count,
            try XCTUnwrap(
                oracle[
                    "requestCountWhenConfirmed"
                ] as? Int
            )
        )

        XCTAssertEqual(
            confirmedClient
                .redirectPolicies
                .count,
            1
        )

        XCTAssertEqual(
            confirmedClient
                .redirectPolicies
                .first?
                .rawValue,
            try XCTUnwrap(
                oracle[
                    "redirectPolicy"
                ] as? String
            )
        )

        let request =
            try XCTUnwrap(
                confirmedClient
                    .requests
                    .first
            )

        XCTAssertEqual(
            request.url,
            expectedURL
        )

        XCTAssertEqual(
            request.httpMethod,
            expectedMethod
        )

        let actualBody =
            try XCTUnwrap(
                request.httpBody
            )

        XCTAssertEqual(
            actualBody.count,
            expectedBodySize
        )

        XCTAssertEqual(
            sha256Hex(
                actualBody
            ),
            expectedBodySHA
        )

        XCTAssertEqual(
            request.value(
                forHTTPHeaderField:
                    "Content-Type"
            ),
            expectedContentType
        )

        let authorization =
            try XCTUnwrap(
                request.value(
                    forHTTPHeaderField:
                        "Authorization"
                )
            )

        XCTAssertEqual(
            sha256Hex(
                Data(
                    authorization
                        .utf8
                )
            ),
            expectedAuthorizationSHA
        )

        let actualHeaderNames =
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

        let oracleHeaderNames =
            Set(
                expectedHeaderNames
                    .map {
                        $0.lowercased()
                    }
            )

        XCTAssertEqual(
            actualHeaderNames,
            oracleHeaderNames
        )

        print(
            "ORACLE_007B5A "
            + "exact=true "
            + "requestsConfirmed="
            + String(
                confirmedClient
                    .requests
                    .count
            )
            + " requestsUnconfirmed="
            + String(
                unconfirmedClient
                    .requests
                    .count
            )
            + " method="
            + expectedMethod
            + " contentType="
            + expectedContentType
            + " bodySHA256="
            + expectedBodySHA
            + " authorizationSHA256="
            + expectedAuthorizationSHA
            + " redirectPolicy=reject "
            + "semanticVerified=false"
        )
    }
}
