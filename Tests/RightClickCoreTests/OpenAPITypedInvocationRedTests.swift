import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPITypedInvocationRedTests:
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

        static var requestCount = 0

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
                                "TypedInvocationRED",
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
                                stream
                                    .streamError
                                ?? NSError(
                                    domain:
                                        "TypedInvocationRED",
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

        StubURLProtocol.handler =
            nil

        StubURLProtocol.requestCount =
            0
    }

    override func tearDown() {
        StubURLProtocol.handler =
            nil

        StubURLProtocol.requestCount =
            0

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

    private func jsonSpec()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Typed JSON Provider",
                "version": "1.0.0"
              },
              "security": [],
              "paths": {
                "/publish": {
                  "post": {
                    "operationId": "publishDocument",
                    "summary": "Publish document",
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
                        "description": "Published",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "required": [
                                "url"
                              ],
                              "properties": {
                                "url": {
                                  "type": "string",
                                  "format": "uri"
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

    private func multipartSpec()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Typed Multipart Provider",
                "version": "1.0.0"
              },
              "security": [],
              "paths": {
                "/artifacts": {
                  "post": {
                    "operationId": "createArtifact",
                    "summary": "Publish artifact",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "multipart/form-data": {
                          "schema": {
                            "type": "object",
                            "required": [
                              "file"
                            ],
                            "properties": {
                              "file": {
                                "type": "string",
                                "format": "binary"
                              },
                              "title": {
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
                              "type": "object",
                              "required": [
                                "url"
                              ],
                              "properties": {
                                "url": {
                                  "type": "string",
                                  "format": "uri"
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

    private func engine(
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
                            "{}"
                    )
                    .capabilities
                    .first
            )

        return (
            engine,
            capability
        )
    }

    func testTypedJSONStillRequiresConfirmationBeforeTransport()
        throws
    {
        let (
            engine,
            capability
        ) =
            try engine(
                specification:
                    jsonSpec()
            )

        let arguments =
            """
            {"content":"hello"}
            """

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    arguments,
                confirmed:
                    false
            )

        XCTAssertEqual(
            result.status,
            .confirmationRequired,
            "RED_TYPED_CONFIRMATION_NOT_IMPLEMENTED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            "RED_TYPED_CONFIRMATION_ALLOWED_TRANSPORT"
        )
    }

    func testTypedJSONInvocationSerializesExactJSONAndReturnsJSON()
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
                "https://provider.example/publish"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                ),
                "application/json"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Accept"
                ),
                "application/json"
            )

            let body =
                try XCTUnwrap(
                    request.httpBody
                )

            let object =
                try JSONSerialization
                    .jsonObject(
                        with:
                            body
                    )
                    as? [String: Any]

            XCTAssertEqual(
                object?[
                    "content"
                ] as? String,
                "hello"
            )

            XCTAssertEqual(
                object?.count,
                1
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
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
                    """
                    {"url":"https://example.invalid/document"}
                    """.utf8
                )
            )
        }

        let (
            engine,
            capability
        ) =
            try engine(
                specification:
                    jsonSpec()
            )

        let arguments =
            """
            {"content":"hello"}
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
            "RED_JSON_TYPED_INVOCATION_NOT_IMPLEMENTED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1,
            "RED_JSON_TYPED_HTTP_NOT_SENT"
        )

        XCTAssertEqual(
            result.output,
            """
            {"url":"https://example.invalid/document"}
            """,
            "RED_JSON_RESPONSE_NOT_RETURNED"
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified,
            "Provider acceptance must remain distinct from semantic verification."
        )
    }

    func testMalformedTypedJSONFailsBeforeTransport()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTFail(
                "Malformed typed arguments reached HTTP transport."
            )

            let response =
                HTTPURLResponse(
                    url:
                        request.url!,
                    statusCode:
                        500,
                    httpVersion:
                        "HTTP/1.1",
                    headerFields:
                        nil
                )!

            return (
                response,
                Data()
            )
        }

        let (
            engine,
            capability
        ) =
            try engine(
                specification:
                    jsonSpec()
            )

        let malformed =
            """
            {"content":42}
            """

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    malformed,
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .failed,
            "RED_TYPED_SCHEMA_VALIDATION_NOT_IMPLEMENTED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            "RED_INVALID_TYPED_ARGUMENTS_REACHED_TRANSPORT"
        )

        XCTAssertEqual(
            result.evidence.type,
            "input_contract_failure"
        )
    }

    func testMultipartInvocationSerializesFileAndFieldsAndReturnsJSON()
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
                "https://provider.example/artifacts"
            )

            let contentType =
                try XCTUnwrap(
                    request.value(
                        forHTTPHeaderField:
                            "Content-Type"
                    )
                )

            XCTAssertTrue(
                contentType
                    .hasPrefix(
                        "multipart/form-data; boundary="
                    )
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Accept"
                ),
                "application/json"
            )

            let body =
                String(
                    data:
                        try XCTUnwrap(
                            request.httpBody
                        ),
                    encoding:
                        .utf8
                )

            let bodyText =
                try XCTUnwrap(
                    body
                )

            XCTAssertTrue(
                bodyText.contains(
                    #"name="file"; filename="note.txt""#
                )
            )

            XCTAssertTrue(
                bodyText.contains(
                    "Content-Type: text/plain"
                )
            )

            XCTAssertTrue(
                bodyText.contains(
                    "hello from RIGHTCLICK"
                )
            )

            XCTAssertTrue(
                bodyText.contains(
                    #"name="title""#
                )
            )

            XCTAssertTrue(
                bodyText.contains(
                    "North Star"
                )
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
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
                    """
                    {"url":"https://example.invalid/artifact"}
                    """.utf8
                )
            )
        }

        let (
            engine,
            capability
        ) =
            try engine(
                specification:
                    multipartSpec()
            )

        let arguments =
            """
            {
              "file": {
                "filename": "note.txt",
                "contentType": "text/plain",
                "text": "hello from RIGHTCLICK"
              },
              "title": "North Star"
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
            "RED_MULTIPART_TYPED_INVOCATION_NOT_IMPLEMENTED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1,
            "RED_MULTIPART_HTTP_NOT_SENT"
        )

        XCTAssertEqual(
            result.output,
            """
            {"url":"https://example.invalid/artifact"}
            """,
            "RED_MULTIPART_JSON_RESPONSE_NOT_RETURNED"
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified
        )
    }
}
