import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPILocalReferenceRedTests:
    XCTestCase
{
    private func engine(
        specification: String
    ) throws -> CapabilityEngine {
        let reflector =
            try OpenAPIReflector(
                specificationData:
                    Data(
                        specification.utf8
                    ),
                baseURL:
                    URL(
                        string:
                            "https://provider.example"
                    )!
            )

        return CapabilityEngine(
            reflectors: [
                reflector
            ]
        )
    }

    func testLocalResponseSchemaReferenceShouldReflect()
        throws
    {
        let engine =
            try engine(
                specification:
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "Local Response Ref Provider",
                    "version": "1"
                  },
                  "paths": {
                    "/publish": {
                      "post": {
                        "operationId": "publish",
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
                                  "$ref": "#/components/schemas/CreateResult"
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
                      "CreateResult": {
                        "type": "object",
                        "required": ["url"],
                        "properties": {
                          "url": {
                            "type": "string"
                          }
                        }
                      }
                    }
                  }
                }
                """
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        #"{"content":"hello"}"#
                )
                .capabilities

        XCTAssertEqual(
            capabilities.count,
            1,
            "RED_LOCAL_RESPONSE_REF_NOT_RESOLVED"
        )
    }

    func testLocalRequestSchemaReferenceShouldReflect()
        throws
    {
        let engine =
            try engine(
                specification:
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "Local Request Ref Provider",
                    "version": "1"
                  },
                  "paths": {
                    "/publish": {
                      "post": {
                        "operationId": "publish",
                        "requestBody": {
                          "required": true,
                          "content": {
                            "application/json": {
                              "schema": {
                                "$ref": "#/components/schemas/CreateInput"
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
                      "CreateInput": {
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
                }
                """
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        #"{"content":"hello"}"#
                )
                .capabilities

        XCTAssertEqual(
            capabilities.count,
            1,
            "RED_LOCAL_REQUEST_REF_NOT_RESOLVED"
        )
    }

    func testExternalSchemaReferenceStillAbstains()
        throws
    {
        let engine =
            try engine(
                specification:
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "External Ref Provider",
                    "version": "1"
                  },
                  "paths": {
                    "/publish": {
                      "post": {
                        "operationId": "publish",
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
                            "description": "OK",
                            "content": {
                              "application/json": {
                                "schema": {
                                  "$ref": "https://other.example/schema.json"
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
                """
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "{}"
                )
                .capabilities
                .isEmpty,
            "EXTERNAL_REF_MUST_NOT_GAIN_NETWORK_AUTHORITY"
        )
    }

    func testMissingLocalReferenceStillAbstains()
        throws
    {
        let engine =
            try engine(
                specification:
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "Missing Ref Provider",
                    "version": "1"
                  },
                  "paths": {
                    "/publish": {
                      "post": {
                        "operationId": "publish",
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
                            "description": "OK",
                            "content": {
                              "application/json": {
                                "schema": {
                                  "$ref": "#/components/schemas/DoesNotExist"
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
                """
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "{}"
                )
                .capabilities
                .isEmpty
        )
    }

    func testCyclicLocalReferenceStillAbstains()
        throws
    {
        let engine =
            try engine(
                specification:
                """
                {
                  "openapi": "3.1.0",
                  "info": {
                    "title": "Cyclic Ref Provider",
                    "version": "1"
                  },
                  "paths": {
                    "/publish": {
                      "post": {
                        "operationId": "publish",
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
                            "description": "OK",
                            "content": {
                              "application/json": {
                                "schema": {
                                  "$ref": "#/components/schemas/A"
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
                        "$ref": "#/components/schemas/B"
                      },
                      "B": {
                        "$ref": "#/components/schemas/A"
                      }
                    }
                  }
                }
                """
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "{}"
                )
                .capabilities
                .isEmpty,
            "CYCLIC_REF_MUST_FAIL_CLOSED"
        )
    }
}
