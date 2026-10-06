import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPINestedLocalReferenceRedTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var requestCount =
            0

        static var lastRequest:
            URLRequest?

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
            Self.lastRequest = request

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

        StubURLProtocol
            .lastRequest = nil
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

    private func localReferenceSpecification()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Nested Ref Provider",
                "version": "1"
              },
              "paths": {
                "/items": {
                  "post": {
                    "operationId": "createItems",
                    "security": [],
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "required": [
                              "items"
                            ],
                            "properties": {
                              "items": {
                                "type": "array",
                                "minItems": 1,
                                "items": {
                                  "$ref": "#/components/schemas/Item"
                                }
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
              },
              "components": {
                "schemas": {
                  "Item": {
                    "type": "object",
                    "required": [
                      "name"
                    ],
                    "properties": {
                      "name": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 3
                      }
                    },
                    "additionalProperties": false
                  }
                }
              }
            }
            """.utf8
        )
    }

    private func engine(
        specification: Data
    ) throws -> CapabilityEngine {
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

        return CapabilityEngine(
            reflectors: [
                reflector
            ]
        )
    }

    private func capability(
        engine: CapabilityEngine
    ) throws -> Capability {
        try XCTUnwrap(
            engine
                .capabilities(
                    for:
                        #"{"items":[{"name":"ok"}]}"#
                )
                .capabilities
                .first
        )
    }

    func testNestedLocalRequestReferenceAllowsValidInvocation()
        throws
    {
        let engine =
            try engine(
                specification:
                    localReferenceSpecification()
            )

        let capability =
            try capability(
                engine:
                    engine
            )

        StubURLProtocol
            .requestCount = 0

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"items":[{"name":"ok"}]}"#,
                confirmed:
                    true
            )

        print(
            "NESTED_REF_DIAGNOSTIC valid"
            + " status="
            + result.status.rawValue
            + " requests="
            + String(
                StubURLProtocol
                    .requestCount
            )
            + " message="
            + result.message
        )

        XCTAssertEqual(
            result.status,
            .accepted,
            "RED_NESTED_LOCAL_REF_VALID_REQUEST_NOT_EXECUTABLE"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1,
            "RED_NESTED_LOCAL_REF_VALID_REQUEST_NO_TRANSPORT"
        )
    }

    func testNestedLocalReferenceConstraintIsActuallyEnforced()
        throws
    {
        let engine =
            try engine(
                specification:
                    localReferenceSpecification()
            )

        let capability =
            try capability(
                engine:
                    engine
            )

        StubURLProtocol
            .requestCount = 0

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    #"{"items":[{"name":"toolong"}]}"#,
                confirmed:
                    true
            )

        print(
            "NESTED_REF_DIAGNOSTIC constraint"
            + " status="
            + result.status.rawValue
            + " requests="
            + String(
                StubURLProtocol
                    .requestCount
            )
            + " message="
            + result.message
        )

        XCTAssertEqual(
            result.status,
            .failed,
            "RED_NESTED_LOCAL_REF_CONSTRAINT_NOT_ENFORCED"
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0,
            "RED_NESTED_LOCAL_REF_CONSTRAINT_REACHED_TRANSPORT"
        )

        XCTAssertTrue(
            result.message
                .contains(
                    "maxLength"
                ),
            "RED_NESTED_LOCAL_REF_CONSTRAINT_WRONG_FAILURE"
        )
    }

    func testNestedExternalReferenceAbstainsDuringReflection()
        throws
    {
        let specification =
            Data(
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "External Nested Ref",
                    "version": "1"
                  },
                  "paths": {
                    "/items": {
                      "post": {
                        "operationId": "externalNestedRef",
                        "security": [],
                        "requestBody": {
                          "required": true,
                          "content": {
                            "application/json": {
                              "schema": {
                                "type": "object",
                                "required": ["items"],
                                "properties": {
                                  "items": {
                                    "type": "array",
                                    "items": {
                                      "$ref": "https://example.com/item.json"
                                    }
                                  }
                                }
                              }
                            }
                          }
                        },
                        "responses": {
                          "200": {
                            "description": "OK",
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

        let engine =
            try engine(
                specification:
                    specification
            )

        let graph =
            try engine.capabilities(
                for:
                    #"{"items":[]}"#
            )

        print(
            "NESTED_REF_REFLECTION external count="
            + String(
                graph.capabilities.count
            )
        )

        XCTAssertEqual(
            graph.capabilities.count,
            0,
            "RED_NESTED_EXTERNAL_REF_DID_NOT_ABSTAIN"
        )
    }

    func testNestedMissingLocalReferenceAbstainsDuringReflection()
        throws
    {
        let specification =
            Data(
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "Missing Nested Ref",
                    "version": "1"
                  },
                  "paths": {
                    "/items": {
                      "post": {
                        "operationId": "missingNestedRef",
                        "security": [],
                        "requestBody": {
                          "required": true,
                          "content": {
                            "application/json": {
                              "schema": {
                                "type": "object",
                                "properties": {
                                  "item": {
                                    "$ref": "#/components/schemas/Missing"
                                  }
                                }
                              }
                            }
                          }
                        },
                        "responses": {
                          "200": {
                            "description": "OK",
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

        let engine =
            try engine(
                specification:
                    specification
            )

        let graph =
            try engine.capabilities(
                for:
                    #"{"item":{}}"#
            )

        print(
            "NESTED_REF_REFLECTION missing count="
            + String(
                graph.capabilities.count
            )
        )

        XCTAssertEqual(
            graph.capabilities.count,
            0,
            "RED_NESTED_MISSING_REF_DID_NOT_ABSTAIN"
        )
    }

    func testNestedCyclicLocalReferenceAbstainsDuringReflection()
        throws
    {
        let specification =
            Data(
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "Cyclic Nested Ref",
                    "version": "1"
                  },
                  "paths": {
                    "/items": {
                      "post": {
                        "operationId": "cyclicNestedRef",
                        "security": [],
                        "requestBody": {
                          "required": true,
                          "content": {
                            "application/json": {
                              "schema": {
                                "type": "object",
                                "properties": {
                                  "item": {
                                    "$ref": "#/components/schemas/A"
                                  }
                                }
                              }
                            }
                          }
                        },
                        "responses": {
                          "200": {
                            "description": "OK",
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
                  },
                  "components": {
                    "schemas": {
                      "A": {
                        "type": "object",
                        "properties": {
                          "next": {
                            "$ref": "#/components/schemas/B"
                          }
                        }
                      },
                      "B": {
                        "type": "object",
                        "properties": {
                          "next": {
                            "$ref": "#/components/schemas/A"
                          }
                        }
                      }
                    }
                  }
                }
                """.utf8
            )

        let engine =
            try engine(
                specification:
                    specification
            )

        let graph =
            try engine.capabilities(
                for:
                    #"{"item":{}}"#
            )

        print(
            "NESTED_REF_REFLECTION cyclic count="
            + String(
                graph.capabilities.count
            )
        )

        XCTAssertEqual(
            graph.capabilities.count,
            0,
            "RED_NESTED_CYCLIC_REF_DID_NOT_ABSTAIN"
        )
    }
}
