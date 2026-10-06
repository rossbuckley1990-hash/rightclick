import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIAuthorityRedTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var requestCount = 0
        static var acceptedResponse = false

        override class func canInit(
            with request: URLRequest
        ) -> Bool {
            true
        }

        override class func canonicalRequest(
            for request: URLRequest
        ) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.requestCount += 1

            let status =
                Self.acceptedResponse
                ? 201
                : 500

            let data =
                Self.acceptedResponse
                ? Data(
                    #"{"ok":true}"#.utf8
                )
                : Data(
                    #"{"error":"transport must not occur"}"#.utf8
                )

            let response =
                HTTPURLResponse(
                    url:
                        request.url!,
                    statusCode:
                        status,
                    httpVersion:
                        "HTTP/1.1",
                    headerFields: [
                        "Content-Type":
                            "application/json"
                    ]
                )!

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
        }

        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()

        StubURLProtocol.requestCount =
            0

        StubURLProtocol.acceptedResponse =
            false
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

    private func operationBody(
        operationSecurity: String?
    ) -> String
    {
        let security =
            operationSecurity
                .map {
                    """
                    "security": \($0),
                    """
                }
                ?? ""

        return """
        {
          "operationId": "publish",
          \(security)
          "requestBody": {
            "required": true,
            "content": {
              "application/json": {
                "schema": {
                  "type": "object",
                  "required": ["content"],
                  "properties": {
                    "content": {
                      "type": "string"
                    }
                  }
                }
              }
            }
          },
          "responses": {
            "201": {
              "description": "Created",
              "content": {
                "application/json": {
                  "schema": {
                    "type": "object"
                  }
                }
              }
            }
          }
        }
        """
    }

    private func specification(
        rootSecurity: String? = nil,
        operationSecurity: String? = nil,
        includeBearerScheme: Bool = false
    ) -> Data
    {
        let security =
            rootSecurity
                .map {
                    """
                    "security": \($0),
                    """
                }
                ?? ""

        let components =
            includeBearerScheme
                ? """
                  "components": {
                    "securitySchemes": {
                      "BearerAuth": {
                        "type": "http",
                        "scheme": "bearer"
                      }
                    }
                  },
                  """
                : ""

        return Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Authority Provider",
                "version": "1"
              },
              \(security)
              \(components)
              "paths": {
                "/publish": {
                  "post":
                    \(operationBody(
                        operationSecurity:
                            operationSecurity
                    ))
                }
              }
            }
            """.utf8
        )
    }

    private func engineAndCapability(
        specification: Data
    ) throws
        -> (
            CapabilityEngine,
            Capability
        )
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    specification,
                baseURL:
                    URL(
                        string:
                            "https://provider.example"
                    )!,
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
                            #"{"content":"hello"}"#
                    )
                    .capabilities
                    .first
            )

        return (
            engine,
            capability
        )
    }

    func testMissingSecurityIsUnresolvedAndConfirmationCannotAuthorizeTransport()
        throws
    {
        let (
            engine,
            capability
        ) =
            try engineAndCapability(
                specification:
                    specification()
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "unresolved",
            "RED_AUTHORITY_MISSING_SECURITY_NOT_UNRESOLVED"
        )

        XCTAssertEqual(
            capability.invocation,
            .unsupported,
            "RED_UNRESOLVED_AUTHORITY_STILL_INVOCABLE"
        )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"content":"hello"}"#,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .unsupported,
            "RED_USER_CONFIRMATION_BYPASSED_AUTHORITY"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            "RED_UNRESOLVED_AUTHORITY_REACHED_TRANSPORT"
        )
    }

    func testBearerRequirementIsCredentialRequiredAndCannotExecuteWithoutCredentials()
        throws
    {
        let (
            engine,
            capability
        ) =
            try engineAndCapability(
                specification:
                    specification(
                        rootSecurity:
                            #"[{"BearerAuth":[]}]"#,
                        includeBearerScheme:
                            true
                    )
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "credential_required",
            "RED_SECURED_OPERATION_NOT_CLASSIFIED_CREDENTIAL_REQUIRED"
        )

        XCTAssertEqual(
            capability.invocation,
            .unsupported,
            "RED_CREDENTIAL_REQUIRED_CAPABILITY_STILL_INVOCABLE"
        )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"content":"hello"}"#,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .unsupported
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            "RED_CREDENTIAL_REQUIRED_OPERATION_REACHED_TRANSPORT"
        )
    }

    func testExplicitEmptyOperationSecurityAllowsAnonymousCapabilityButStillRequiresConfirmation()
        throws
    {
        StubURLProtocol.acceptedResponse =
            true

        let (
            engine,
            capability
        ) =
            try engineAndCapability(
                specification:
                    specification(
                        operationSecurity:
                            "[]"
                    )
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "anonymous",
            "RED_EXPLICIT_ANONYMOUS_NOT_RECOGNIZED"
        )

        XCTAssertEqual(
            capability.invocation,
            .interactive
        )

        XCTAssertTrue(
            capability
                .requiresConfirmation
        )

        let unconfirmed =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"content":"hello"}"#,
                confirmed:
                    false
            )

        XCTAssertEqual(
            unconfirmed.status,
            .confirmationRequired
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        let confirmed =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"content":"hello"}"#,
                confirmed:
                    true
            )

        XCTAssertEqual(
            confirmed.status,
            .accepted,
            "RED_EXPLICIT_ANONYMOUS_OPERATION_NOT_EXECUTABLE"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1
        )

        XCTAssertFalse(
            confirmed.evidence
                .outcomeVerified
        )
    }

    func testAnonymousAlternativeEmptyObjectAllowsExecution()
        throws
    {
        let (
            _,
            capability
        ) =
            try engineAndCapability(
                specification:
                    specification(
                        operationSecurity:
                            #"[{},{"BearerAuth":[]}]"#,
                        includeBearerScheme:
                            true
                    )
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "anonymous",
            "RED_EMPTY_SECURITY_ALTERNATIVE_NOT_RECOGNIZED"
        )
    }

    func testOperationAnonymousOverrideBeatsSecuredRoot()
        throws
    {
        let (
            _,
            capability
        ) =
            try engineAndCapability(
                specification:
                    specification(
                        rootSecurity:
                            #"[{"BearerAuth":[]}]"#,
                        operationSecurity:
                            "[]",
                        includeBearerScheme:
                            true
                    )
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "anonymous",
            "RED_OPERATION_SECURITY_OVERRIDE_NOT_HONOURED"
        )
    }
}
