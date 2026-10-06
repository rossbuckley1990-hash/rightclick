import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIHeaderParameterRedTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var requestCount = 0

        static var handler:
            ((URLRequest) throws
                -> (
                    HTTPURLResponse,
                    Data
                ))?

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

            guard
                let handler =
                    Self.handler
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        NSError(
                            domain:
                                "OpenAPIHeaderRED",
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
                                        "OpenAPIHeaderRED",
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

    override func setUp() {
        super.setUp()

        StubURLProtocol
            .requestCount = 0

        StubURLProtocol
            .handler = nil
    }

    override func tearDown() {
        StubURLProtocol
            .requestCount = 0

        StubURLProtocol
            .handler = nil

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

    private func specification()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Declared Header Provider",
                "version": "1"
              },
              "paths": {
                "/publish-sessions": {
                  "post": {
                    "operationId": "createPublishSession",
                    "security": [],
                    "parameters": [
                      {
                        "name": "X-Client",
                        "in": "header",
                        "required": false,
                        "schema": {
                          "type": "string",
                          "maxLength": 80
                        }
                      },
                      {
                        "name": "Idempotency-Key",
                        "in": "header",
                        "required": true,
                        "schema": {
                          "type": "string",
                          "maxLength": 128
                        }
                      }
                    ],
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "required": [
                              "content"
                            ],
                            "properties": {
                              "content": {
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
                        "description": "Created",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "properties": {
                                "ok": {
                                  "type": "boolean"
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
            """.utf8
        )
    }

    private func engineAndCapability()
        throws
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

    func testDeclaredHeaderParametersAreRetainedInCapabilityMetadata()
        throws
    {
        let (
            _,
            capability
        ) =
            try engineAndCapability()

        let raw =
            try XCTUnwrap(
                capability.metadata[
                    "parametersJSON"
                ],
                "RED_HEADER_PARAMETERS_NOT_REFLECTED"
            )

        let data =
            try XCTUnwrap(
                raw.data(
                    using:
                        .utf8
                )
            )

        let rows =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [
                        [
                            String:
                            Any
                        ]
                    ]
            )

        XCTAssertEqual(
            rows.count,
            2
        )

        let idempotency =
            try XCTUnwrap(
                rows.first {
                    $0[
                        "name"
                    ] as? String
                        == "Idempotency-Key"
                }
            )

        XCTAssertEqual(
            idempotency[
                "in"
            ] as? String,
            "header"
        )

        XCTAssertEqual(
            idempotency[
                "required"
            ] as? Bool,
            true
        )

        let schema =
            try XCTUnwrap(
                idempotency[
                    "schema"
                ] as? [
                    String:
                    Any
                ]
            )

        XCTAssertEqual(
            schema[
                "type"
            ] as? String,
            "string"
        )

        XCTAssertEqual(
            schema[
                "maxLength"
            ] as? Int,
            128
        )
    }

    func testMissingRequiredDeclaredHeaderFailsBeforeTransport()
        throws
    {
        StubURLProtocol.handler = {
            request in

            let response =
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
                )!

            return (
                response,
                Data(
                    #"{"ok":true}"#.utf8
                )
            )
        }

        let (
            engine,
            capability
        ) =
            try engineAndCapability()

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
            .failed,
            "RED_REQUIRED_HEADER_NOT_ENFORCED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            "RED_MISSING_REQUIRED_HEADER_REACHED_TRANSPORT"
        )

        XCTAssertEqual(
            result.evidence.type,
            "input_contract_failure"
        )

        XCTAssertTrue(
            result.message.contains(
                "Idempotency-Key"
            ),
            "RED_MISSING_HEADER_FAILURE_NOT_IDENTIFIED"
        )
    }

    func testDeclaredHeaderEnvelopeSerializesHeaderAndExactBody()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.url?
                    .absoluteString,
                "https://provider.example/publish-sessions"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Idempotency-Key"
                ),
                "northstar-001"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "X-Client"
                ),
                "RIGHTCLICK"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                ),
                "application/json"
            )

            let body =
                try XCTUnwrap(
                    request.httpBody
                )

            let object =
                try XCTUnwrap(
                    try JSONSerialization
                        .jsonObject(
                            with:
                                body
                        )
                        as? [
                            String:
                            Any
                        ]
                )

            XCTAssertEqual(
                object[
                    "content"
                ] as? String,
                "hello"
            )

            XCTAssertEqual(
                object.count,
                1,
                "Argument envelope leaked into provider request body."
            )

            let response =
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
                )!

            return (
                response,
                Data(
                    #"{"ok":true}"#.utf8
                )
            )
        }

        let (
            engine,
            capability
        ) =
            try engineAndCapability()

        let arguments =
            """
            {
              "body": {
                "content": "hello"
              },
              "headers": {
                "Idempotency-Key": "northstar-001",
                "X-Client": "RIGHTCLICK"
              }
            }
            """

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    arguments,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .accepted,
            "RED_DECLARED_HEADER_NOT_SERIALIZED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1,
            "RED_DECLARED_HEADER_REQUEST_NOT_SENT"
        )

        XCTAssertEqual(
            result.output,
            #"{"ok":true}"#
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified
        )
    }

    func testUndeclaredHeaderIsRejectedBeforeTransport()
        throws
    {
        let (
            engine,
            capability
        ) =
            try engineAndCapability()

        let arguments =
            """
            {
              "body": {
                "content": "hello"
              },
              "headers": {
                "Idempotency-Key": "northstar-001",
                "Authorization": "Bearer definitely-not-allowed"
              }
            }
            """

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    arguments,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        XCTAssertTrue(
            result.message
                .lowercased()
                .contains(
                    "undeclared"
                ),
            "RED_UNDECLARED_HEADER_NOT_REJECTED_AT_PARAMETER_BOUNDARY"
        )
    }

    func testDeclaredHeaderConstraintIsValidatedBeforeTransport()
        throws
    {
        let (
            engine,
            capability
        ) =
            try engineAndCapability()

        let tooLong =
            String(
                repeating:
                    "x",
                count:
                    129
            )

        let arguments =
            """
            {
              "body": {
                "content": "hello"
              },
              "headers": {
                "Idempotency-Key": "\(tooLong)"
              }
            }
            """

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    arguments,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        XCTAssertTrue(
            result.message.contains(
                "maxLength"
            ),
            "RED_HEADER_MAX_LENGTH_NOT_VALIDATED"
        )
    }
}
