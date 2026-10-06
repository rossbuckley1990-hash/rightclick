import XCTest
import Foundation

@testable import RightClickCore

final class OpenAPIContinuationExecutionGenericRepairTests:
    XCTestCase
{
    private final class RecordingClient:
        OpenAPIContinuationExecutionHTTPClient
    {
        var requests: [URLRequest] = []

        var redirectPolicies:
            [OpenAPIContinuationExecutionRedirectPolicy] = []

        let statusCode: Int
        let data: Data

        init(
            statusCode: Int,
            data: Data
        ) {
            self.statusCode = statusCode
            self.data = data
        }

        func send(
            _ request: URLRequest,
            redirectPolicy:
                OpenAPIContinuationExecutionRedirectPolicy
        ) throws -> OpenAPIContinuationExecutionHTTPResponse {
            requests.append(
                request
            )

            redirectPolicies.append(
                redirectPolicy
            )

            return OpenAPIContinuationExecutionHTTPResponse(
                statusCode:
                    statusCode,
                data:
                    data
            )
        }
    }

    private final class AuthorityProbe {
        var materializations = 0
    }

    private func specification()
        -> Data
    {
        Data(
            #"""
            {
              "openapi": "3.1.0",
              "security": [
                {
                  "bearerAuth": []
                }
              ],
              "components": {
                "securitySchemes": {
                  "bearerAuth": {
                    "type": "http",
                    "scheme": "bearer"
                  }
                }
              },
              "paths": {
                "/jobs": {
                  "post": {
                    "operationId": "createJob",
                    "responses": {
                      "201": {
                        "description": "created",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "required": [
                                "id"
                              ],
                              "properties": {
                                "id": {
                                  "type": "string"
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                },
                "/jobs/{id}": {
                  "get": {
                    "operationId": "getJob",
                    "parameters": [
                      {
                        "name": "id",
                        "in": "path",
                        "required": true,
                        "schema": {
                          "type": "string"
                        }
                      }
                    ],
                    "responses": {
                      "200": {
                        "description": "job",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "properties": {
                                "status": {
                                  "type": "string"
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  },
                  "delete": {
                    "operationId": "deleteJob",
                    "parameters": [
                      {
                        "name": "id",
                        "in": "path",
                        "required": true,
                        "schema": {
                          "type": "string"
                        }
                      }
                    ],
                    "responses": {
                      "200": {
                        "description": "deleted"
                      }
                    }
                  }
                }
              }
            }
            """#.utf8
        )
    }

    private func derive(
        targetOperationID: String
    ) throws -> OpenAPIContinuationTemplate {
        switch OpenAPIContinuationTemplate.derive(
            specificationData:
                specification(),
            providerBaseURL:
                URL(
                    string:
                        "https://api.example.test/base/v3"
                )!,
            issuerOperationID:
                "createJob",
            targetOperationID:
                targetOperationID
        ) {
        case .derived(let template):
            return template

        case .abstain(let reason):
            XCTFail(
                "GENERIC_REPAIR_DERIVATION_ABSTAIN "
                    + reason
            )

            throw NSError(
                domain:
                    "GREEN011G",
                code:
                    1
            )
        }
    }

    private func bind(
        _ template:
            OpenAPIContinuationTemplate
    ) throws -> OpenAPIContinuationInstance {
        let response =
            Data(
                #"{"id":"job_123"}"#.utf8
            )

        switch template.bindInstance(
            sourceInvocationArguments: [:],
            issuerStatusCode: 201,
            issuerResponseMediaType:
                "application/json",
            issuerResponseData:
                response
        ) {
        case .bound(let instance):
            return instance

        case .abstain(let reason):
            XCTFail(
                "GENERIC_REPAIR_BIND_ABSTAIN "
                    + reason
            )

            throw NSError(
                domain:
                    "GREEN011G",
                code:
                    2
            )
        }
    }

    private func authority(
        instance:
            OpenAPIContinuationInstance,
        probe:
            AuthorityProbe
    ) throws -> OpenAPIContinuationExecutionAuthority {
        let selected =
            try XCTUnwrap(
                instance
                    .selectedExecutionSecurityAlternative
            )

        return OpenAPIContinuationExecutionAuthority(
            providerOrigin:
                instance.providerOrigin,
            targetOperationID:
                instance.targetOperationID,
            securityAlternative:
                selected,
            authorityFingerprint:
                "generic-green011g-authority",
            materializer: {
                _,
                _ in

                probe.materializations += 1

                return [
                    "Authorization":
                        "Bearer GENERIC-GREEN011G-NOT-REAL"
                ]
            }
        )
    }

    func testBasePathAndAuthenticatedReadOnlyGET()
        throws
    {
        let template =
            try derive(
                targetOperationID:
                    "getJob"
            )

        let instance =
            try bind(
                template
            )

        XCTAssertEqual(
            instance.providerOrigin,
            "https://api.example.test"
        )

        XCTAssertEqual(
            instance.targetPathTemplate,
            "/base/v3/jobs/{id}",
            "GENERIC_BASE_PATH_LOST_PRE_REPAIR"
        )

        if instance.targetPathTemplate
            == "/base/v3/jobs/{id}"
        {
            print(
                "GREEN011G_GENERIC_BASE_PATH_PRESERVED PASS"
            )
        }

        let probe =
            AuthorityProbe()

        let client =
            RecordingClient(
                statusCode:
                    200,
                data:
                    Data(
                        #"{"status":"ready"}"#.utf8
                    )
            )

        let outcome =
            try OpenAPIContinuationExecutor.execute(
                instance:
                    instance,
                callerArguments:
                    [:],
                requestBody:
                    nil,
                authority:
                    try authority(
                        instance:
                            instance,
                        probe:
                            probe
                    ),
                confirmed:
                    false,
                client:
                    client
            )

        switch outcome {
        case .providerAccepted(
            let statusCode,
            _,
            let semanticVerified,
            _,
            _
        ):
            XCTAssertEqual(
                statusCode,
                200
            )

            XCTAssertFalse(
                semanticVerified
            )

            XCTAssertEqual(
                probe.materializations,
                1
            )

            XCTAssertEqual(
                client.requests.count,
                1
            )

            XCTAssertEqual(
                client.redirectPolicies,
                [.reject]
            )

            let request =
                try XCTUnwrap(
                    client.requests.first
                )

            XCTAssertEqual(
                request.httpMethod,
                "GET"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example.test/base/v3/jobs/job_123"
            )

            print(
                "GREEN011G_GENERIC_READONLY_AUTH_WITHOUT_CONFIRMATION PASS"
            )

        case .confirmationRequired:
            XCTFail(
                "GENERIC_READONLY_AUTH_REQUIRES_CONFIRMATION_PRE_REPAIR"
            )

        default:
            XCTFail(
                "Unexpected read-only outcome: "
                    + String(
                        describing:
                            outcome
                    )
            )
        }
    }

    func testUnconfirmedMutationStillFailsClosed()
        throws
    {
        let template =
            try derive(
                targetOperationID:
                    "deleteJob"
            )

        let instance =
            try bind(
                template
            )

        let probe =
            AuthorityProbe()

        let client =
            RecordingClient(
                statusCode:
                    200,
                data:
                    Data()
            )

        let outcome =
            try OpenAPIContinuationExecutor.execute(
                instance:
                    instance,
                callerArguments:
                    [:],
                requestBody:
                    nil,
                authority:
                    try authority(
                        instance:
                            instance,
                        probe:
                            probe
                    ),
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
                "GENERIC_UNCONFIRMED_MUTATION_DID_NOT_FAIL_CLOSED"
            )

            return
        }

        XCTAssertEqual(
            probe.materializations,
            0
        )

        XCTAssertEqual(
            client.requests.count,
            0
        )

        print(
            "GREEN011G_GENERIC_UNCONFIRMED_MUTATION_FAILS_CLOSED PASS"
        )
    }
}
