import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIReflectorTests: XCTestCase {
    final class StubURLProtocol: URLProtocol {
        static var handler:
            ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
            guard let handler = Self.handler else {
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        NSError(
                            domain: "OpenAPIReflectorTests",
                            code: 1
                        )
                )
                return
            }

            do {
                // Foundation's URL loading system may convert URLRequest.httpBody
                // into httpBodyStream before a custom URLProtocol observes it.
                //
                // Normalise the intercepted representation back to httpBody so
                // the frozen assertions continue to verify the exact transmitted
                // bytes. StubURLProtocol is terminal in these tests and never
                // forwards this consumed stream.
                var observedRequest = request

                if observedRequest.httpBody == nil,
                   let stream = observedRequest.httpBodyStream
                {
                    stream.open()
                    defer { stream.close() }

                    var body = Data()
                    var buffer = [UInt8](
                        repeating: 0,
                        count: 4096
                    )

                    while true {
                        let count = stream.read(
                            &buffer,
                            maxLength: buffer.count
                        )

                        if count < 0 {
                            throw stream.streamError
                                ?? NSError(
                                    domain: "OpenAPIReflectorTests",
                                    code: 2,
                                    userInfo: [
                                        NSLocalizedDescriptionKey:
                                            "Failed to read intercepted HTTP body stream."
                                    ]
                                )
                        }

                        if count == 0 {
                            break
                        }

                        body.append(
                            contentsOf: buffer[0..<count]
                        )
                    }

                    observedRequest.httpBody = body
                }

                let (response, data) =
                    try handler(observedRequest)

                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )

                client?.urlProtocol(
                    self,
                    didLoad: data
                )

                client?.urlProtocolDidFinishLoading(
                    self
                )
            } catch {
                client?.urlProtocol(
                    self,
                    didFailWithError: error
                )
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration =
            URLSessionConfiguration.ephemeral

        configuration.protocolClasses = [
            StubURLProtocol.self
        ]

        return URLSession(
            configuration: configuration
        )
    }

    private func supportedSpec(
        path: String = "/transform",
        operationID: String = "transformText"
    ) -> Data {
        Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Unknown Text Provider",
                "version": "1.0.0"
              },
              "paths": {
                "\(path)": {
                  "post": {
                    "operationId": "\(operationID)",
                    "summary": "Transform text",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "text/plain": {
                          "schema": {
                            "type": "string"
                          }
                        }
                      }
                    },
                    "responses": {
                      "200": {
                        "description": "Success",
                        "content": {
                          "text/plain": {
                            "schema": {
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
            """.utf8
        )
    }

    private func unsupportedJSONSpec() -> Data {
        Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Unknown JSON Provider",
                "version": "1.0.0"
              },
              "paths": {
                "/object": {
                  "post": {
                    "operationId": "submitObject",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object"
                          }
                        }
                      }
                    },
                    "responses": {
                      "200": {
                        "description": "Success",
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
                }
              }
            }
            """.utf8
        )
    }

    private func supportedStructuredJSONSpec()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Unknown Structured Provider",
                "version": "1.0.0"
              },
              "paths": {
                "/records": {
                  "post": {
                    "operationId": "createStructuredRecord",
                    "summary": "Create Structured Record",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "additionalProperties": false,
                            "required": [
                              "title",
                              "priority"
                            ],
                            "properties": {
                              "title": {
                                "type": "string"
                              },
                              "priority": {
                                "type": "string",
                                "enum": [
                                  "low",
                                  "medium",
                                  "high"
                                ]
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
                              "additionalProperties": false,
                              "required": [
                                "id",
                                "title",
                                "priority"
                              ],
                              "properties": {
                                "id": {
                                  "type": "string"
                                },
                                "title": {
                                  "type": "string"
                                },
                                "priority": {
                                  "type": "string",
                                  "enum": [
                                    "low",
                                    "medium",
                                    "high"
                                  ]
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


    private func getPathParameterSpec(
        required: Bool = true,
        parameterType: String = "string",
        includeQueryParameter: Bool = false
    ) -> Data {
        let queryParameter =
            includeQueryParameter
            ? """
              ,
              {
                "name": "expand",
                "in": "query",
                "required": false,
                "schema": {
                  "type": "string"
                }
              }
              """
            : ""

        return Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Unknown Durable Read Provider",
                "version": "1.0.0"
              },
              "paths": {
                "/records/{id}": {
                  "get": {
                    "operationId": "readDurableRecord",
                    "summary": "Read Durable Record",
                    "parameters": [
                      {
                        "name": "id",
                        "in": "path",
                        "required": \(required ? "true" : "false"),
                        "schema": {
                          "type": "\(parameterType)"
                        }
                      }\(queryParameter)
                    ],
                    "responses": {
                      "200": {
                        "description": "Persisted record",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "additionalProperties": false,
                              "required": [
                                "id",
                                "title",
                                "priority"
                              ],
                              "properties": {
                                "id": {
                                  "type": "string"
                                },
                                "title": {
                                  "type": "string"
                                },
                                "priority": {
                                  "type": "string",
                                  "enum": [
                                    "low",
                                    "medium",
                                    "high"
                                  ]
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

    private func missingOperationIDSpec() -> Data {
        Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Unnamed Operation Provider",
                "version": "1.0.0"
              },
              "paths": {
                "/transform": {
                  "post": {
                    "requestBody": {
                      "required": true,
                      "content": {
                        "text/plain": {
                          "schema": {
                            "type": "string"
                          }
                        }
                      }
                    },
                    "responses": {
                      "200": {
                        "description": "Success",
                        "content": {
                          "text/plain": {
                            "schema": {
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
            """.utf8
        )
    }

    func testUnknownOpenAPISpecReflectsTextOperation()
        throws
    {
        let reflector = try OpenAPIReflector(
            specificationData: supportedSpec(),
            baseURL:
                URL(
                    string:
                        "https://provider.example/api"
                )!,
            session: session()
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        let result =
            try engine.capabilities(
                for: "hello"
            )

        XCTAssertEqual(
            result.capabilities.count,
            1
        )

        let capability =
            try XCTUnwrap(
                result.capabilities.first
            )

        XCTAssertEqual(
            capability.reflectorID,
            reflector.id
        )

        XCTAssertEqual(
            capability.metadata["substrate"],
            "openapi"
        )

        XCTAssertEqual(
            capability.metadata["method"],
            "POST"
        )

        XCTAssertEqual(
            capability.metadata["path"],
            "/transform"
        )

        XCTAssertTrue(
            capability.id.contains(
                "transformText"
            )
        )

        let providers =
            engine.providers()

        XCTAssertEqual(
            providers.count,
            1
        )

        XCTAssertEqual(
            providers.first?.name,
            "Unknown Text Provider"
        )

        XCTAssertEqual(
            providers.first?.source,
            "openapi"
        )
    }

    func testUnsupportedSchemaAbstainsRatherThanGuessing()
        throws
    {
        let reflector = try OpenAPIReflector(
            specificationData:
                unsupportedJSONSpec(),
            baseURL:
                URL(
                    string:
                        "https://provider.example"
                )!,
            session: session()
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        XCTAssertTrue(
            try engine
                .capabilities(for: "hello")
                .capabilities
                .isEmpty
        )
    }

    func testSupportedStructuredJSONObjectOperationReflectsGenericArgumentSchema()
        throws
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    supportedStructuredJSONSpec(),
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

        let result =
            try engine.capabilities(
                for:
                    "Create a record titled RightClick learned structured JSON live with priority high"
            )

        XCTAssertEqual(
            result.capabilities.count,
            1
        )

        let capability =
            try XCTUnwrap(
                result.capabilities.first
            )

        XCTAssertEqual(
            capability.title,
            "Create Structured Record"
        )

        XCTAssertEqual(
            capability.metadata[
                "requestContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            capability.metadata[
                "responseContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            capability.metadata[
                "argumentsSchema"
            ],
            """
            {"additionalProperties":false,"properties":{"priority":{"enum":["low","medium","high"],"type":"string"},"title":{"type":"string"}},"required":["title","priority"],"type":"object"}
            """
        )

        XCTAssertEqual(
            capability.metadata[
                "resultSchema"
            ],
            """
            {"additionalProperties":false,"properties":{"id":{"type":"string"},"priority":{"enum":["low","medium","high"],"type":"string"},"title":{"type":"string"}},"required":["id","title","priority"],"type":"object"}
            """
        )
    }

    func testStructuredJSONObjectOperationUsesGenericArgumentsAndReturnsCanonicalJSON()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://provider.example/records"
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
                try XCTUnwrap(
                    JSONSerialization
                        .jsonObject(
                            with: body
                        )
                        as? [String: String]
                )

            XCTAssertEqual(
                object,
                [
                    "title":
                        "RightClick learned structured JSON live",
                    "priority":
                        "high",
                ]
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
                    {
                      "id": "record-001",
                      "title": "RightClick learned structured JSON live",
                      "priority": "high"
                    }
                    """.utf8
                )
            )
        }

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    supportedStructuredJSONSpec(),
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
                            "Create a high-priority record"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Create a high-priority record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "RightClick learned structured JSON live",
                    "priority":
                        "high",
                ]
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            """
            {"id":"record-001","priority":"high","title":"RightClick learned structured JSON live"}
            """
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified
        )
    }

    func testStructuredJSONObjectArgumentsFailClosedBeforeTransport()
        throws
    {
        var transportCalled =
            false

        StubURLProtocol.handler = {
            request in

            transportCalled = true

            throw NSError(
                domain:
                    "ShouldNotReachTransport",
                code:
                    1
            )
        }

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    supportedStructuredJSONSpec(),
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
                            "Create a record"
                    )
                    .capabilities
                    .first
            )

        let missingRequired =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Create a record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Incomplete"
                ]
            )

        XCTAssertEqual(
            missingRequired.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )

        let invalidEnum =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Create a record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Bad priority",
                    "priority":
                        "urgent",
                ]
            )

        XCTAssertEqual(
            invalidEnum.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )

        let unknownField =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Create a record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Unexpected",
                    "priority":
                        "high",
                    "providerSpecificHack":
                        "must fail",
                ]
            )

        XCTAssertEqual(
            unknownField.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )
    }


    func testGETWithRequiredStringPathParameterReflectsGenericArgumentSchema()
        throws
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    getPathParameterSpec(),
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

        let result =
            try engine.capabilities(
                for:
                    "Read durable record record-001"
            )

        XCTAssertEqual(
            result.capabilities.count,
            1
        )

        let capability =
            try XCTUnwrap(
                result.capabilities.first
            )

        XCTAssertEqual(
            capability.title,
            "Read Durable Record"
        )

        XCTAssertEqual(
            capability.metadata["method"],
            "GET"
        )

        XCTAssertEqual(
            capability.metadata["path"],
            "/records/{id}"
        )

        XCTAssertNil(
            capability.metadata[
                "requestContentType"
            ]
        )

        XCTAssertEqual(
            capability.metadata[
                "responseContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            capability.metadata[
                "argumentsSchema"
            ],
            """
            {"additionalProperties":false,"properties":{"id":{"type":"string"}},"required":["id"],"type":"object"}
            """
        )

        XCTAssertEqual(
            capability.metadata[
                "resultSchema"
            ],
            """
            {"additionalProperties":false,"properties":{"id":{"type":"string"},"priority":{"enum":["low","medium","high"],"type":"string"},"title":{"type":"string"}},"required":["id","title","priority"],"type":"object"}
            """
        )
    }

    func testGETPathParameterUsesGenericArgumentsPercentEncodesAndSendsNoBody()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "GET"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://provider.example/records/alpha%2Fbeta%20%3F%23"
            )

            XCTAssertNil(
                request.httpBody
            )

            XCTAssertNil(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                )
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Accept"
                ),
                "application/json"
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode:
                            200,
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
                    {
                      "id": "alpha/beta ?#",
                      "title": "Persisted",
                      "priority": "high"
                    }
                    """.utf8
                )
            )
        }

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    getPathParameterSpec(),
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
                            "Read durable record"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Read durable record",
                confirmed:
                    true,
                arguments: [
                    "id":
                        "alpha/beta ?#"
                ]
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            """
            {"id":"alpha/beta ?#","priority":"high","title":"Persisted"}
            """
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified
        )
    }

    func testGETPathParameterArgumentsFailClosedBeforeTransport()
        throws
    {
        var transportCalled =
            false

        StubURLProtocol.handler = {
            request in

            transportCalled = true

            throw NSError(
                domain:
                    "ShouldNotReachTransport",
                code:
                    1
            )
        }

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    getPathParameterSpec(),
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
                            "Read durable record"
                    )
                    .capabilities
                    .first
            )

        let missingArguments =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Read durable record",
                confirmed:
                    true
            )

        XCTAssertEqual(
            missingArguments.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )

        let missingID =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Read durable record",
                confirmed:
                    true,
                arguments: [:]
            )

        XCTAssertEqual(
            missingID.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )

        let unknownArgument =
            try engine.run(
                id:
                    capability.id,
                item:
                    "Read durable record",
                confirmed:
                    true,
                arguments: [
                    "id":
                        "record-001",
                    "providerSpecificHack":
                        "must fail",
                ]
            )

        XCTAssertEqual(
            unknownArgument.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )
    }

    func testGETUnsupportedParameterShapesAbstainRatherThanGuessing()
        throws
    {
        let unsupported = [
            getPathParameterSpec(
                required: false
            ),
            getPathParameterSpec(
                parameterType: "integer"
            ),
            getPathParameterSpec(
                includeQueryParameter: true
            ),
        ]

        for specification in unsupported {
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

            XCTAssertTrue(
                try engine
                    .capabilities(
                        for:
                            "Read durable record"
                    )
                    .capabilities
                    .isEmpty
            )
        }
    }

    func testMissingOperationIDAbstains()
        throws
    {
        let reflector = try OpenAPIReflector(
            specificationData:
                missingOperationIDSpec(),
            baseURL:
                URL(
                    string:
                        "https://provider.example"
                )!,
            session: session()
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        XCTAssertTrue(
            try engine
                .capabilities(for: "hello")
                .capabilities
                .isEmpty
        )
    }

    func testCapabilityIdentityBindsEndpointAndSpecification()
        throws
    {
        func reflectedID(
            specification: Data,
            baseURL: String
        ) throws -> String {
            let reflector =
                try OpenAPIReflector(
                    specificationData:
                        specification,
                    baseURL:
                        URL(
                            string: baseURL
                        )!,
                    session: session()
                )

            let engine =
                CapabilityEngine(
                    reflectors: [reflector]
                )

            return try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first?
                    .id
            )
        }

        let original =
            try reflectedID(
                specification:
                    supportedSpec(),
                baseURL:
                    "https://provider.example/api"
            )

        let changedContract =
            try reflectedID(
                specification:
                    supportedSpec(
                        path: "/changed"
                    ),
                baseURL:
                    "https://provider.example/api"
            )

        let changedEndpoint =
            try reflectedID(
                specification:
                    supportedSpec(),
                baseURL:
                    "https://other.example/api"
            )

        XCTAssertNotEqual(
            original,
            changedContract
        )

        XCTAssertNotEqual(
            original,
            changedEndpoint
        )
    }

    func testHTTPAcceptanceIsNotSemanticSuccess()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://provider.example/api/transform"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                ),
                "text/plain"
            )

            XCTAssertEqual(
                String(
                    data:
                        request.httpBody
                        ?? Data(),
                    encoding: .utf8
                ),
                "hello"
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "text/plain"
                        ]
                    )
                )

            return (
                response,
                Data("HELLO".utf8)
            )
        }

        let reflector = try OpenAPIReflector(
            specificationData:
                supportedSpec(),
            baseURL:
                URL(
                    string:
                        "https://provider.example/api"
                )!,
            session: session()
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id: capability.id,
                item: "hello",
                confirmed: true
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            "HELLO"
        )

        XCTAssertFalse(
            result.evidence.outcomeVerified
        )
    }

    func testExistingVerifierCanVerifyOpenAPIResult()
        throws
    {
        StubURLProtocol.handler = {
            request in

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "text/plain"
                        ]
                    )
                )

            return (
                response,
                Data("HELLO".utf8)
            )
        }

        let reflector = try OpenAPIReflector(
            specificationData:
                supportedSpec(),
            baseURL:
                URL(
                    string:
                        "https://provider.example/api"
                )!,
            session: session()
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id: capability.id,
                item: "hello",
                confirmed: true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "HELLO"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            result.status,
            .verified
        )

        XCTAssertEqual(
            result.verification?.status,
            .verifiedSuccess
        )

        XCTAssertTrue(
            result.evidence.outcomeVerified
        )
    }

    func testExistingVerifierRejectsWrongOpenAPIResult()
        throws
    {
        StubURLProtocol.handler = {
            request in

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            try XCTUnwrap(
                                request.url
                            ),
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "text/plain"
                        ]
                    )
                )

            return (
                response,
                Data("HELLO".utf8)
            )
        }

        let reflector = try OpenAPIReflector(
            specificationData:
                supportedSpec(),
            baseURL:
                URL(
                    string:
                        "https://provider.example/api"
                )!,
            session: session()
        )

        let engine = CapabilityEngine(
            reflectors: [reflector]
        )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id: capability.id,
                item: "hello",
                confirmed: true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "THIS IS WRONG"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            result.verification?.status,
            .verifiedFailure
        )
    }
}
