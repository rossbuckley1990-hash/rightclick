import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPITypedReflectionRedTests:
    XCTestCase
{
    private func jsonBodySpec()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Unknown Structured JSON Provider",
                "version": "1.0.0"
              },
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
                "title": "Unknown Multipart Provider",
                "version": "1.0.0"
              },
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

    private func parameterisedJSONSpec()
        -> Data
    {
        Data(
            """
            {
              "openapi": "3.1.0",
              "info": {
                "title": "Parameterized Provider",
                "version": "1.0.0"
              },
              "paths": {
                "/documents/{documentId}": {
                  "post": {
                    "operationId": "updateDocument",
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
                            }
                          }
                        }
                      }
                    },
                    "responses": {
                      "200": {
                        "description": "Updated",
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

    func testJSONBodyAndJSONResponseShouldReflectTypedCapability()
        throws
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    jsonBodySpec(),
                baseURL:
                    URL(
                        string:
                            "https://provider.example"
                    )!
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
                    "synthetic document"
            )

        XCTAssertEqual(
            result.capabilities.count,
            1,
            "RED_JSON_TYPED_CAPABILITY_NOT_REFLECTED"
        )
    }

    func testMultipartBodyAndJSONResponseShouldReflectTypedCapability()
        throws
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    multipartSpec(),
                baseURL:
                    URL(
                        string:
                            "https://provider.example"
                    )!
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
                    "synthetic artifact"
            )

        XCTAssertEqual(
            result.capabilities.count,
            1,
            "RED_MULTIPART_TYPED_CAPABILITY_NOT_REFLECTED"
        )
    }

    func testParameterizedTypedOperationStillAbstains()
        throws
    {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    parameterisedJSONSpec(),
                baseURL:
                    URL(
                        string:
                            "https://provider.example"
                    )!
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
                        "synthetic document"
                )
                .capabilities
                .isEmpty,
            "RED_PATH_PARAMETER_SCOPE_WAS_ACCIDENTALLY_EXPANDED"
        )
    }
}
