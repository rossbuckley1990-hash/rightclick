import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIIntegerBridgeRedTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var requestCount =
            0

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
                    Data(
                        #"{"ok":true}"#.utf8
                    )
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

        StubURLProtocol
            .requestCount = 0
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
                "title": "Integer Bridge Provider",
                "version": "1"
              },
              "paths": {
                "/number": {
                  "post": {
                    "operationId": "acceptInteger",
                    "security": [],
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "required": [
                              "size"
                            ],
                            "properties": {
                              "size": {
                                "type": "integer"
                              }
                            },
                            "additionalProperties": false
                          }
                        }
                      }
                    },
                    "responses": {
                      "201": {
                        "description": "Accepted",
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

    private func run(
        size: Int
    ) throws -> RunResult {
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
                            #"{"size":2}"#
                    )
                    .capabilities
                    .first
            )

        return try engine.run(
            id:
                capability.id,
            item:
                #"{"size":\#(size)}"#,
            confirmed:
                true
        )
    }

    private func describe(
        label: String,
        result: RunResult
    ) {
        print(
            "INTEGER_BRIDGE_DIAGNOSTIC "
            + label
            + " status="
            + String(
                describing:
                    result.status
            )
            + " requests="
            + String(
                StubURLProtocol
                    .requestCount
            )
            + " message="
            + result.message
        )
    }

    func testIntegerZeroMustRemainInteger()
        throws
    {
        StubURLProtocol
            .requestCount = 0

        let result =
            try run(
                size:
                    0
            )

        describe(
            label:
                "ZERO",
            result:
                result
        )

        XCTAssertEqual(
            result.status,
            .accepted,
            "RED_INTEGER_ZERO_BOOL_BRIDGE"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1,
            "RED_INTEGER_ZERO_BOOL_BRIDGE_REACHED_NO_TRANSPORT"
        )
    }

    func testIntegerOneMustRemainInteger()
        throws
    {
        StubURLProtocol
            .requestCount = 0

        let result =
            try run(
                size:
                    1
            )

        describe(
            label:
                "ONE",
            result:
                result
        )

        XCTAssertEqual(
            result.status,
            .accepted,
            "RED_INTEGER_ONE_BOOL_BRIDGE"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1,
            "RED_INTEGER_ONE_BOOL_BRIDGE_REACHED_NO_TRANSPORT"
        )
    }

    func testIntegerTwoRemainsAcceptedControl()
        throws
    {
        StubURLProtocol
            .requestCount = 0

        let result =
            try run(
                size:
                    2
            )

        describe(
            label:
                "TWO",
            result:
                result
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1
        )
    }

    func testNegativeIntegerRemainsAcceptedControl()
        throws
    {
        StubURLProtocol
            .requestCount = 0

        let result =
            try run(
                size:
                    -1
            )

        describe(
            label:
                "NEGATIVE_ONE",
            result:
                result
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1
        )
    }
}
