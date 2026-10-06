import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIBodyConstraintRedTests:
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
                        #"{"sessionId":"red006"}"#.utf8
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
                "title": "Body Constraint Provider",
                "version": "1"
              },
              "paths": {
                "/publish-sessions": {
                  "post": {
                    "operationId": "createPublishSession",
                    "security": [],
                    "parameters": [
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
                              "files"
                            ],
                            "properties": {
                              "files": {
                                "type": "array",
                                "minItems": 1,
                                "maxItems": 100,
                                "items": {
                                  "type": "object",
                                  "required": [
                                    "path",
                                    "size",
                                    "contentType",
                                    "hash"
                                  ],
                                  "properties": {
                                    "path": {
                                      "type": "string",
                                      "minLength": 1,
                                      "maxLength": 512
                                    },
                                    "size": {
                                      "type": "integer",
                                      "minimum": 0,
                                      "maximum": 10485760
                                    },
                                    "contentType": {
                                      "type": "string",
                                      "minLength": 1,
                                      "maxLength": 255
                                    },
                                    "hash": {
                                      "type": "string",
                                      "pattern": "^[a-f0-9]{64}$"
                                    }
                                  },
                                  "additionalProperties": false
                                }
                              },
                              "title": {
                                "type": "string",
                                "maxLength": 120
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
                            #"{"files":[]}"#
                    )
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "anonymous"
        )

        XCTAssertEqual(
            capability.invocation,
            .interactive
        )

        return (
            engine,
            capability
        )
    }

    private func validFile(
        path: String = "x",
        size: Int = 0,
        contentType: String = "x",
        hash: String =
            String(
                repeating:
                    "a",
                count:
                    64
            )
    ) -> [String: Any] {
        [
            "path":
                path,
            "size":
                size,
            "contentType":
                contentType,
            "hash":
                hash,
        ]
    }

    private func arguments(
        body: [String: Any]
    ) throws -> String {
        let envelope:
            [String: Any] = [
                "body":
                    body,
                "headers": [
                    "Idempotency-Key":
                        "red-006-v2"
                ],
            ]

        let data =
            try JSONSerialization
                .data(
                    withJSONObject:
                        envelope,
                    options: [
                        .sortedKeys
                    ]
                )

        return try XCTUnwrap(
            String(
                data:
                    data,
                encoding:
                    .utf8
            )
        )
    }

    private func run(
        body: [String: Any]
    ) throws -> RunResult {
        let (
            engine,
            capability
        ) =
            try engineAndCapability()

        return try engine.run(
            id:
                capability.id,
            item:
                arguments(
                    body:
                        body
                ),
            confirmed:
                true
        )
    }

    private func assertConstraintShouldReject(
        name: String,
        marker: String,
        body: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        StubURLProtocol
            .requestCount = 0

        let result =
            try run(
                body:
                    body
            )

        print(
            "BODY_CONSTRAINT_DIAGNOSTIC "
            + name
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
            + " evidence="
            + result.evidence.type
            + " message="
            + result.message
        )

        XCTAssertEqual(
            result.status,
            .failed,
            marker,
            file:
                file,
            line:
                line
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            marker
            + "_REACHED_TRANSPORT",
            file:
                file,
            line:
                line
        )

        XCTAssertEqual(
            result.evidence.type,
            "input_contract_failure",
            marker
            + "_WRONG_EVIDENCE",
            file:
                file,
            line:
                line
        )
    }

    func testFilesMinItems()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "FILES_MIN_ITEMS",
            marker:
                "RED_BODY_MIN_ITEMS_NOT_VALIDATED",
            body: [
                "files": [],
            ]
        )
    }

    func testFilesMaxItems()
        throws
    {
        let files =
            (0..<101)
            .map {
                index in

                validFile(
                    path:
                        "x\(index)"
                )
            }

        try assertConstraintShouldReject(
            name:
                "FILES_MAX_ITEMS",
            marker:
                "RED_BODY_MAX_ITEMS_NOT_VALIDATED",
            body: [
                "files":
                    files,
            ]
        )
    }

    func testContentTypeMinLength()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "CONTENT_TYPE_MIN_LENGTH",
            marker:
                "RED_BODY_CONTENTTYPE_MIN_LENGTH_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        contentType:
                            ""
                    )
                ]
            ]
        )
    }

    func testContentTypeMaxLength()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "CONTENT_TYPE_MAX_LENGTH",
            marker:
                "RED_BODY_CONTENTTYPE_MAX_LENGTH_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        contentType:
                            String(
                                repeating:
                                    "x",
                                count:
                                    256
                            )
                    )
                ]
            ]
        )
    }

    func testHashPattern()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "HASH_PATTERN",
            marker:
                "RED_BODY_HASH_PATTERN_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        hash:
                            String(
                                repeating:
                                    "Z",
                                count:
                                    64
                            )
                    )
                ]
            ]
        )
    }

    func testPathMinLength()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "PATH_MIN_LENGTH",
            marker:
                "RED_BODY_PATH_MIN_LENGTH_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        path:
                            ""
                    )
                ]
            ]
        )
    }

    func testPathMaxLength()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "PATH_MAX_LENGTH",
            marker:
                "RED_BODY_PATH_MAX_LENGTH_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        path:
                            String(
                                repeating:
                                    "p",
                                count:
                                    513
                            )
                    )
                ]
            ]
        )
    }

    func testSizeMinimum()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "SIZE_MINIMUM",
            marker:
                "RED_BODY_SIZE_MINIMUM_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        size:
                            -1
                    )
                ]
            ]
        )
    }

    func testSizeMaximum()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "SIZE_MAXIMUM",
            marker:
                "RED_BODY_SIZE_MAXIMUM_NOT_VALIDATED",
            body: [
                "files": [
                    validFile(
                        size:
                            10485761
                    )
                ]
            ]
        )
    }

    func testTitleMaxLength()
        throws
    {
        try assertConstraintShouldReject(
            name:
                "TITLE_MAX_LENGTH",
            marker:
                "RED_BODY_TITLE_MAX_LENGTH_NOT_VALIDATED",
            body: [
                "files": [
                    validFile()
                ],
                "title":
                    String(
                        repeating:
                            "t",
                        count:
                            121
                    ),
            ]
        )
    }

    func testValidBoundaryPayloadStillReachesTransport()
        throws
    {
        StubURLProtocol
            .requestCount = 0

        let result =
            try run(
                body: [
                    "files": [
                        validFile(
                            path:
                                "x",
                            size:
                                0,
                            contentType:
                                "x"
                        )
                    ],
                    "title":
                        String(
                            repeating:
                                "t",
                            count:
                                120
                        ),
                ]
            )

        print(
            "BODY_CONSTRAINT_DIAGNOSTIC VALID_BOUNDARY"
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
            + " evidence="
            + result.evidence.type
            + " message="
            + result.message
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

        XCTAssertEqual(
            result.output,
            #"{"sessionId":"red006"}"#
        )

        XCTAssertFalse(
            result.evidence
                .outcomeVerified
        )
    }
}
