import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore

final class GraphQLReflectorTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var handler:
            (
                (URLRequest)
                    throws
                    -> (
                        HTTPURLResponse,
                        Data
                    )
            )?

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
                                    "GraphQLReflectorTests",
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
                                        "GraphQLReflectorTests",
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

    override func tearDown() {
        StubURLProtocol.handler =
            nil

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

    private func schemaData()
        -> Data
    {
        Data(
            """
            {
              "data": {
                "__schema": {
                  "queryType": {
                    "name": "Query"
                  },
                  "mutationType": {
                    "name": "Mutation"
                  },
                  "types": [
                    {
                      "kind": "OBJECT",
                      "name": "Query",
                      "fields": [
                        {
                          "name": "viewer",
                          "description": "View a user",
                          "args": [
                            {
                              "name": "id",
                              "defaultValue": null,
                              "type": {
                                "kind": "NON_NULL",
                                "name": null,
                                "ofType": {
                                  "kind": "SCALAR",
                                  "name": "ID"
                                }
                              }
                            }
                          ],
                          "type": {
                            "kind": "OBJECT",
                            "name": "User"
                          }
                        },
                        {
                          "name": "search",
                          "description": "Search users",
                          "args": [
                            {
                              "name": "term",
                              "defaultValue": null,
                              "type": {
                                "kind": "SCALAR",
                                "name": "String"
                              }
                            },
                            {
                              "name": "limit",
                              "defaultValue": "10",
                              "type": {
                                "kind": "SCALAR",
                                "name": "Int"
                              }
                            }
                          ],
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "LIST",
                              "name": null,
                              "ofType": {
                                "kind": "NON_NULL",
                                "name": null,
                                "ofType": {
                                  "kind": "OBJECT",
                                  "name": "User"
                                }
                              }
                            }
                          }
                        }
                      ]
                    },
                    {
                      "kind": "OBJECT",
                      "name": "Mutation",
                      "fields": [
                        {
                          "name": "createRecord",
                          "description": "Create a record",
                          "args": [
                            {
                              "name": "input",
                              "defaultValue": null,
                              "type": {
                                "kind": "NON_NULL",
                                "name": null,
                                "ofType": {
                                  "kind": "INPUT_OBJECT",
                                  "name": "CreateRecordInput"
                                }
                              }
                            }
                          ],
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "OBJECT",
                              "name": "Record"
                            }
                          }
                        }
                      ]
                    },
                    {
                      "kind": "OBJECT",
                      "name": "User",
                      "fields": [
                        {
                          "name": "id",
                          "args": [],
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "SCALAR",
                              "name": "ID"
                            }
                          }
                        },
                        {
                          "name": "name",
                          "args": [],
                          "type": {
                            "kind": "SCALAR",
                            "name": "String"
                          }
                        }
                      ]
                    },
                    {
                      "kind": "OBJECT",
                      "name": "Record",
                      "fields": [
                        {
                          "name": "id",
                          "args": [],
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "SCALAR",
                              "name": "ID"
                            }
                          }
                        },
                        {
                          "name": "title",
                          "args": [],
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "SCALAR",
                              "name": "String"
                            }
                          }
                        },
                        {
                          "name": "priority",
                          "args": [],
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "ENUM",
                              "name": "Priority"
                            }
                          }
                        }
                      ]
                    },
                    {
                      "kind": "INPUT_OBJECT",
                      "name": "CreateRecordInput",
                      "inputFields": [
                        {
                          "name": "title",
                          "defaultValue": null,
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "SCALAR",
                              "name": "String"
                            }
                          }
                        },
                        {
                          "name": "priority",
                          "defaultValue": null,
                          "type": {
                            "kind": "NON_NULL",
                            "name": null,
                            "ofType": {
                              "kind": "ENUM",
                              "name": "Priority"
                            }
                          }
                        }
                      ]
                    },
                    {
                      "kind": "ENUM",
                      "name": "Priority",
                      "enumValues": [
                        {
                          "name": "LOW"
                        },
                        {
                          "name": "HIGH"
                        }
                      ]
                    },
                    {
                      "kind": "SCALAR",
                      "name": "ID"
                    },
                    {
                      "kind": "SCALAR",
                      "name": "String"
                    },
                    {
                      "kind": "SCALAR",
                      "name": "Int"
                    },
                    {
                      "kind": "SCALAR",
                      "name": "Boolean"
                    },
                    {
                      "kind": "SCALAR",
                      "name": "Float"
                    }
                  ]
                }
              }
            }
            """.utf8
        )
    }

    private func reflector()
        throws
        -> GraphQLReflector
    {
        try GraphQLReflector(
            schemaData:
                schemaData(),
            endpointURL:
                URL(
                    string:
                        "https://graphql.example.test/graphql"
                )!,
            providerName:
                "Fixture GraphQL",
            session:
                session()
        )
    }

    private func response(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String,
        contentType: String =
            "application/graphql-response+json"
    ) -> (
        HTTPURLResponse,
        Data
    ) {
        (
            HTTPURLResponse(
                url:
                    request.url!,
                statusCode:
                    statusCode,
                httpVersion:
                    "HTTP/1.1",
                headerFields: [
                    "Content-Type":
                        contentType
                ]
            )!,
            Data(
                body.utf8
            )
        )
    }

    private func jsonBody(
        _ request:
            URLRequest
    ) throws
        -> [String: Any]
    {
        guard
            let body =
                request.httpBody,
            let object =
                try JSONSerialization
                    .jsonObject(
                        with:
                            body
                    )
                as? [String: Any]
        else {
            throw NSError(
                domain:
                    "GraphQLReflectorTests",
                code:
                    3
            )
        }

        return object
    }

    func testReflectsQueriesAndMutationsBehindGenericCapabilities()
        throws
    {
        let reflector =
            try reflector()

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        "hello"
                )
                .capabilities

        XCTAssertEqual(
            capabilities.count,
            3
        )

        let viewer =
            try XCTUnwrap(
                capabilities
                    .first {
                        $0.title
                            == "GraphQL query: viewer"
                    }
            )

        let mutation =
            try XCTUnwrap(
                capabilities
                    .first {
                        $0.title
                            == "GraphQL mutation: createRecord"
                    }
            )

        XCTAssertTrue(
            viewer.id
                .hasPrefix(
                    "graphql:"
                )
        )

        XCTAssertEqual(
            viewer.metadata[
                "substrate"
            ],
            "graphql"
        )

        XCTAssertEqual(
            viewer.metadata[
                "operationKind"
            ],
            "query"
        )

        XCTAssertEqual(
            mutation.metadata[
                "operationKind"
            ],
            "mutation"
        )

        XCTAssertTrue(
            mutation
                .requiresConfirmation
        )

        let argumentSchema =
            try XCTUnwrap(
                mutation
                    .metadata[
                        "argumentsSchema"
                    ]
            )

        XCTAssertTrue(
            argumentSchema
                .contains(
                    "CreateRecordInput!"
                )
        )

        XCTAssertTrue(
            argumentSchema
                .contains(
                    "JSON-encoded"
                )
        )
    }

    func testExecutesQueryWithVariablesAndSynthesizedSelection()
        throws
    {
        var observedCalls =
            0

        StubURLProtocol.handler = {
            request in

            observedCalls += 1

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                ),
                "application/json"
            )

            let object =
                try self
                    .jsonBody(
                        request
                    )

            let query =
                try XCTUnwrap(
                    object[
                        "query"
                    ] as? String
                )

            XCTAssertTrue(
                query
                    .contains(
                        "query RightClick_"
                    )
            )

            XCTAssertTrue(
                query
                    .contains(
                        "rightclickResult: viewer(id: $id)"
                    )
            )

            XCTAssertTrue(
                query
                    .contains(
                        "__typename"
                    )
            )

            XCTAssertTrue(
                query
                    .contains(
                        " id"
                    )
            )

            XCTAssertTrue(
                query
                    .contains(
                        " name"
                    )
            )

            let variables =
                try XCTUnwrap(
                    object[
                        "variables"
                    ] as? [String: Any]
                )

            XCTAssertEqual(
                variables[
                    "id"
                ] as? String,
                "u-123"
            )

            return
                self.response(
                    for:
                        request,
                    body:
                        """
                        {
                          "data": {
                            "rightclickResult": {
                              "__typename": "User",
                              "id": "u-123",
                              "name": "Ada"
                            }
                          }
                        }
                        """
                )
        }

        let reflector =
            try reflector()

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
                            "hello"
                    )
                    .capabilities
                    .first {
                        $0.title
                            == "GraphQL query: viewer"
                    }
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true,
                arguments: [
                    "id":
                        "u-123"
                ]
            )

        XCTAssertEqual(
            observedCalls,
            1
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.evidence.type,
            "provider_acceptance"
        )

        XCTAssertTrue(
            result.output?
                .contains(
                    "\"name\":\"Ada\""
                )
                == true
        )
    }

    func testExecutesMutationWithJSONEncodedInputObject()
        throws
    {
        StubURLProtocol.handler = {
            request in

            let object =
                try self
                    .jsonBody(
                        request
                    )

            let query =
                try XCTUnwrap(
                    object[
                        "query"
                    ] as? String
                )

            XCTAssertTrue(
                query
                    .contains(
                        "mutation RightClick_"
                    )
            )

            XCTAssertTrue(
                query
                    .contains(
                        "createRecord(input: $input)"
                    )
            )

            let variables =
                try XCTUnwrap(
                    object[
                        "variables"
                    ] as? [String: Any]
                )

            let input =
                try XCTUnwrap(
                    variables[
                        "input"
                    ] as? [String: Any]
                )

            XCTAssertEqual(
                input[
                    "title"
                ] as? String,
                "RIGHTCLICK"
            )

            XCTAssertEqual(
                input[
                    "priority"
                ] as? String,
                "HIGH"
            )

            return
                self.response(
                    for:
                        request,
                    body:
                        """
                        {
                          "data": {
                            "rightclickResult": {
                              "__typename": "Record",
                              "id": "r-1",
                              "title": "RIGHTCLICK",
                              "priority": "HIGH"
                            }
                          }
                        }
                        """
                )
        }

        let reflector =
            try reflector()

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
                            "hello"
                    )
                    .capabilities
                    .first {
                        $0.title
                            == "GraphQL mutation: createRecord"
                    }
            )

        let input =
            """
            {"title":"RIGHTCLICK","priority":"HIGH"}
            """

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true,
                arguments: [
                    "input":
                        input
                ]
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )
    }

    func testMutationRequiresConfirmationBeforeTransport()
        throws
    {
        var transportCalls =
            0

        StubURLProtocol.handler = {
            request in

            transportCalls += 1

            return
                self.response(
                    for:
                        request,
                    body:
                        """
                        {"data":{"rightclickResult":null}}
                        """
                )
        }

        let reflector =
            try reflector()

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
                            "hello"
                    )
                    .capabilities
                    .first {
                        $0.title
                            == "GraphQL mutation: createRecord"
                    }
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    false,
                arguments: [
                    "input":
                        "{\"title\":\"RIGHTCLICK\",\"priority\":\"HIGH\"}"
                ]
            )

        XCTAssertEqual(
            result.status,
            .confirmationRequired
        )

        XCTAssertEqual(
            transportCalls,
            0
        )
    }

    func testInvalidNestedEnumFailsBeforeTransport()
        throws
    {
        var transportCalls =
            0

        StubURLProtocol.handler = {
            request in

            transportCalls += 1

            return
                self.response(
                    for:
                        request,
                    body:
                        """
                        {"data":{"rightclickResult":null}}
                        """
                )
        }

        let reflector =
            try reflector()

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
                            "hello"
                    )
                    .capabilities
                    .first {
                        $0.title
                            == "GraphQL mutation: createRecord"
                    }
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true,
                arguments: [
                    "input":
                        "{\"title\":\"RIGHTCLICK\",\"priority\":\"INVALID\"}"
                ]
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            result.evidence.type,
            "input_contract_failure"
        )

        XCTAssertEqual(
            transportCalls,
            0
        )
    }

    func testGraphQLErrorsFailEvenWhenPartialDataExists()
        throws
    {
        StubURLProtocol.handler = {
            request in

            self.response(
                for:
                    request,
                body:
                    """
                    {
                      "data": {
                        "rightclickResult": {
                          "__typename": "User",
                          "id": "u-123",
                          "name": null
                        }
                      },
                      "errors": [
                        {
                          "message": "name resolver failed"
                        }
                      ]
                    }
                    """
            )
        }

        let reflector =
            try reflector()

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
                            "hello"
                    )
                    .capabilities
                    .first {
                        $0.title
                            == "GraphQL query: viewer"
                    }
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true,
                arguments: [
                    "id":
                        "u-123"
                ]
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            result.evidence.type,
            "graphql_errors"
        )
    }
}
