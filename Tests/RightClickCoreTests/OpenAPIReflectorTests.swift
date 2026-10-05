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
