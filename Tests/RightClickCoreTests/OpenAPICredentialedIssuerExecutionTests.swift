import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPICredentialedIssuerExecutionTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var handler:
            ((URLRequest) throws
                -> (
                    HTTPURLResponse,
                    Data
                ))?

        static var requestCount =
            0

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
            Self.requestCount += 1

            guard
                let handler =
                    Self.handler
            else {
                client?
                    .urlProtocol(
                        self,
                        didFailWithError:
                            NSError(
                                domain:
                                    "CredentialedIssuer",
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
                    observed.httpBody
                        == nil,
                    let stream =
                        observed
                            .httpBodyStream
                {
                    stream.open()

                    defer {
                        stream.close()
                    }

                    var data =
                        Data()

                    var buffer =
                        [
                            UInt8
                        ](
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
                                stream
                                    .streamError
                                ?? NSError(
                                    domain:
                                        "CredentialedIssuer",
                                    code:
                                        2
                                )
                        }

                        if count == 0 {
                            break
                        }

                        data.append(
                            contentsOf:
                                buffer[
                                    0..<count
                                ]
                        )
                    }

                    observed.httpBody =
                        data
                }

                let (
                    response,
                    data
                ) =
                    try handler(
                        observed
                    )

                client?
                    .urlProtocol(
                        self,
                        didReceive:
                            response,
                        cacheStoragePolicy:
                            .notAllowed
                    )

                client?
                    .urlProtocol(
                        self,
                        didLoad:
                            data
                    )

                client?
                    .urlProtocolDidFinishLoading(
                        self
                    )
            } catch {
                client?
                    .urlProtocol(
                        self,
                        didFailWithError:
                            error
                    )
            }
        }

        override func stopLoading() {}
    }

    final class Probe {
        var resolutions =
            0

        var materializations =
            0
    }

    override func setUp() {
        super.setUp()

        StubURLProtocol.handler =
            nil

        StubURLProtocol.requestCount =
            0
    }

    private func session()
        -> URLSession
    {
        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration
            .protocolClasses =
            [
                StubURLProtocol.self
            ]

        return URLSession(
            configuration:
                configuration
        )
    }

    private func specification()
        -> Data
    {
        Data(
            #"""
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Generic Credentialed Provider",
                "version": "1.0.0"
              },
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
                "/records": {
                  "post": {
                    "operationId": "createRecord",
                    "summary": "Create record",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "required": [
                              "name"
                            ],
                            "properties": {
                              "name": {
                                "type": "string"
                              }
                            },
                            "additionalProperties": false
                          }
                        }
                      }
                    },
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
                }
              }
            }
            """#.utf8
        )
    }

    private func validResolver(
        probe:
            Probe,
        secret:
            String =
                "GENERIC-SECRET-NOT-REAL"
    )
        -> OpenAPIOperationExecutionAuthorityResolver
    {
        {
            request in

            probe.resolutions += 1

            XCTAssertEqual(
                request
                    .providerOrigin,
                "https://provider.example"
            )

            XCTAssertEqual(
                request
                    .operationID,
                "createRecord"
            )

            XCTAssertEqual(
                request
                    .method,
                "POST"
            )

            XCTAssertEqual(
                request
                    .url
                    .absoluteString,
                "https://provider.example/base/v1/records"
            )

            let alternative =
                try XCTUnwrap(
                    request
                        .securityAlternatives
                        .first(
                            where: {
                                $0
                                    .schemes
                                    .count
                                    == 1
                                && $0
                                    .schemes[
                                        0
                                    ]
                                    .name
                                    == "bearerAuth"
                                && $0
                                    .schemes[
                                        0
                                    ]
                                    .kind
                                    == "http:bearer"
                            }
                        )
                )

            let authority =
                OpenAPIOperationExecutionAuthority(
                    providerOrigin:
                        request
                            .providerOrigin,
                    operationID:
                        request
                            .operationID,
                    securityAlternative:
                        alternative,
                    authorityFingerprintSHA256:
                        "generic-authority-fingerprint",
                    materializer: {
                        descriptor in

                        probe.materializations += 1

                        XCTAssertEqual(
                            descriptor
                                .method,
                            "POST"
                        )

                        XCTAssertEqual(
                            descriptor
                                .url
                                .absoluteString,
                            "https://provider.example/base/v1/records"
                        )

                        return [
                            "Authorization":
                                "Bearer "
                                + secret
                        ]
                    }
                )

            XCTAssertFalse(
                authority
                    .description
                    .contains(
                        secret
                    )
            )

            return authority
        }
    }

    private func engine(
        resolver:
            OpenAPIOperationExecutionAuthorityResolver?
    ) throws
        -> (
            CapabilityEngine,
            Capability
        )
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    specification(),
                baseURL:
                    URL(
                        string:
                            "https://provider.example/base/v1"
                    )!,
                session:
                    session(),
                executionAuthorityResolver:
                    resolver
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let capability =
            try XCTUnwrap(
                try engine
                    .capabilities(
                        for:
                            #"{"name":"alpha"}"#
                    )
                    .capabilities
                    .first(
                        where: {
                            $0
                                .metadata[
                                    "operationId"
                                ]
                                == "createRecord"
                        }
                    )
            )

        return (
            engine,
            capability
        )
    }

    func testCredentialedTypedIssuerExecutesOnlyAfterConfirmation()
        throws
    {
        let probe =
            Probe()

        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request
                    .httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request
                    .url?
                    .absoluteString,
                "https://provider.example/base/v1/records"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Authorization"
                ),
                "Bearer GENERIC-SECRET-NOT-REAL"
            )

            let body =
                try XCTUnwrap(
                    request
                        .httpBody
                )

            let json =
                try XCTUnwrap(
                    try JSONSerialization
                        .jsonObject(
                            with:
                                body
                        )
                    as? [String: Any]
                )

            XCTAssertEqual(
                json[
                    "name"
                ] as? String,
                "alpha"
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            request.url!,
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
                    #"{"id":"rec_123"}"#.utf8
                )
            )
        }

        let (
            engine,
            capability
        ) =
            try engine(
                resolver:
                    validResolver(
                        probe:
                            probe
                    )
            )

        XCTAssertEqual(
            capability
                .invocation,
            .direct
        )

        XCTAssertTrue(
            capability
                .requiresConfirmation
        )

        XCTAssertNil(
            capability
                .metadata[
                    "invocationLimitation"
                ]
        )

        XCTAssertFalse(
            capability
                .metadata
                .values
                .joined()
                .contains(
                    "GENERIC-SECRET-NOT-REAL"
                )
        )

        let unconfirmed =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"name":"alpha"}"#,
                confirmed:
                    false
            )

        XCTAssertEqual(
            unconfirmed
                .status,
            .confirmationRequired
        )

        XCTAssertEqual(
            probe
                .resolutions,
            0
        )

        XCTAssertEqual(
            probe
                .materializations,
            0
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        print(
            "GREEN011I_CONFIRMATION_BEFORE_AUTHORITY PASS"
        )

        let accepted =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"name":"alpha"}"#,
                confirmed:
                    true
            )

        XCTAssertEqual(
            accepted
                .status,
            .accepted
        )

        XCTAssertEqual(
            probe
                .resolutions,
            1
        )

        XCTAssertEqual(
            probe
                .materializations,
            1
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1
        )

        XCTAssertFalse(
            accepted
                .evidence
                .outcomeVerified
        )

        XCTAssertFalse(
            (
                accepted.message
                    + (accepted.output ?? "")
                    + accepted
                        .evidence
                        .boundary
            )
            .contains(
                "GENERIC-SECRET-NOT-REAL"
            )
        )

        print(
            "GREEN011I_GENERIC_CREDENTIALED_TYPED_ISSUER PASS"
        )

        print(
            "GREEN011I_BASE_PATH_PRESERVED PASS"
        )

        print(
            "GREEN011I_PROVIDER_ACCEPTED_SEMANTIC_UNVERIFIED PASS"
        )
    }

    func testMissingAuthorityResolverRemainsFailClosed()
        throws
    {
        let (
            engine,
            capability
        ) =
            try engine(
                resolver:
                    nil
            )

        XCTAssertEqual(
            capability
                .invocation,
            .unsupported
        )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"name":"alpha"}"#,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result
                .status,
            .unsupported
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        print(
            "GREEN011I_MISSING_AUTHORITY_FAILS_CLOSED PASS"
        )
    }

    func testMismatchedAuthorityFailsBeforeTransport()
        throws
    {
        let probe =
            Probe()

        let resolver:
            OpenAPIOperationExecutionAuthorityResolver =
        {
            request in

            probe.resolutions += 1

            let alternative =
                try XCTUnwrap(
                    request
                        .securityAlternatives
                        .first
                )

            return
                OpenAPIOperationExecutionAuthority(
                    providerOrigin:
                        "https://wrong.example",
                    operationID:
                        request
                            .operationID,
                    securityAlternative:
                        alternative,
                    authorityFingerprintSHA256:
                        "wrong-origin",
                    materializer: {
                        _ in

                        probe.materializations += 1

                        return [
                            "Authorization":
                                "Bearer SHOULD-NOT-MATERIALIZE"
                        ]
                    }
                )
        }

        let (
            engine,
            capability
        ) =
            try engine(
                resolver:
                    resolver
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"name":"alpha"}"#,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result
                .status,
            .failed
        )

        XCTAssertEqual(
            probe
                .resolutions,
            1
        )

        XCTAssertEqual(
            probe
                .materializations,
            0
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        print(
            "GREEN011I_MISMATCHED_AUTHORITY_FAILS_CLOSED PASS"
        )
    }

    func testCallerCannotInjectAuthorizationThroughTypedArguments()
        throws
    {
        let probe =
            Probe()

        let (
            engine,
            capability
        ) =
            try engine(
                resolver:
                    validResolver(
                        probe:
                            probe
                    )
            )

        let input =
            #"""
            {
              "body": {
                "name": "alpha"
              },
              "headers": {
                "Authorization": "Bearer CALLER"
              }
            }
            """#

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    input,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result
                .status,
            .failed
        )

        XCTAssertEqual(
            probe
                .resolutions,
            0
        )

        XCTAssertEqual(
            probe
                .materializations,
            0
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        print(
            "GREEN011I_CALLER_AUTHORIZATION_REJECTED PASS"
        )
    }
}
