@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore

final class ARDAcquisitionGateTests: XCTestCase {
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
                                    "ARDAcquisitionGateTests",
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
                                        "ARDAcquisitionGateTests",
                                    code:
                                        2
                                )
                        }

                        if count == 0 {
                            break
                        }

                        body.append(
                            contentsOf:
                                buffer[0..<count]
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

    final class DurableState {
        private let lock =
            NSLock()

        private var title:
            String?

        func create(
            title: String
        ) {
            lock.lock()
            self.title = title
            lock.unlock()
        }

        func read()
            -> String?
        {
            lock.lock()
            defer {
                lock.unlock()
            }
            return title
        }
    }

    override func tearDown() {
        StubURLProtocol.handler =
            nil

        super.tearDown()
    }

    private func providerSession()
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
              "openapi": "3.0.3",
              "info": {
                "title": "ARD Durable Records",
                "version": "1.0.0"
              },
              "servers": [
                {
                  "url": "https://api.example"
                }
              ],
              "paths": {
                "/records": {
                  "post": {
                    "operationId": "records/create",
                    "summary": "Create ARD Record",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "application/json": {
                          "schema": {
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["title"],
                            "properties": {
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
                              "additionalProperties": false,
                              "required": ["id", "title"],
                              "properties": {
                                "id": {
                                  "type": "string"
                                },
                                "title": {
                                  "type": "string"
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                },
                "/records/{id}": {
                  "get": {
                    "operationId": "records/get",
                    "summary": "Read ARD Record",
                    "parameters": [
                      {
                        "name": "id",
                        "in": "path",
                        "required": true,
                        "schema": {
                          "type": "string"
                        }
                      }
                    ],
                    "responses": {
                      "200": {
                        "description": "Record",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "additionalProperties": false,
                              "required": ["id", "title"],
                              "properties": {
                                "id": {
                                  "type": "string"
                                },
                                "title": {
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
              }
            }
            """.utf8
        )
    }

    private func searchResponse()
        -> Data
    {
        Data(
            """
            {
              "results": [
                {
                  "identifier": "urn:air:registry.example:api:durable-records",
                  "displayName": "ARD Durable Records",
                  "type": "application/openapi+json",
                  "url": "https://spec.example/openapi.json",
                  "score": 100,
                  "source": "fixture-registry"
                }
              ],
              "referrals": []
            }
            """.utf8
        )
    }

    private func source(
        expectedQuery: String? = nil
    ) -> ARDRegistrySource {
        ARDRegistrySource(
            registries: [
                ARDRegistryDescriptor(
                    id:
                        "fixture",
                    searchURL:
                        "https://registry.example/search"
                )
            ],
            searchLoader: {
                url,
                body in

                XCTAssertEqual(
                    url.absoluteString,
                    "https://registry.example/search"
                )

                if let expectedQuery {
                    let object =
                        try XCTUnwrap(
                            try JSONSerialization
                                .jsonObject(
                                    with:
                                        body
                                )
                                as? [String: Any]
                        )

                    let query =
                        try XCTUnwrap(
                            object["query"]
                                as? [String: Any]
                        )

                    XCTAssertEqual(
                        query["text"] as? String,
                        expectedQuery
                    )
                }

                return self
                    .searchResponse()
            },
            specificationLoader: {
                url in

                XCTAssertEqual(
                    url.absoluteString,
                    "https://spec.example/openapi.json"
                )

                return self
                    .specification()
            },
            providerSession:
                providerSession()
        )
    }

    private func capability(
        operationID: String,
        in engine:
            CapabilityEngine,
        item: String
    ) throws -> Capability {
        try XCTUnwrap(
            try engine
                .capabilities(
                    for:
                        item
                )
                .capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ] ==
                        operationID
                }
        )
    }

    func testG13ARDSearchResponseBecomesOpenAPIAcquisitionCandidate() throws {
        let engine =
            CapabilityEngine(
                reflectors: [],
                reflectorSources: [
                    source(
                        expectedQuery:
                            "create durable ARD record"
                    )
                ]
            )

        let discovered =
            try engine
                .capabilities(
                    for:
                        "create durable ARD record"
                )
                .capabilities

        XCTAssertEqual(
            Set(
                discovered.compactMap {
                    $0.metadata[
                        "operationId"
                    ]
                }
            ),
            Set([
                "records/create",
                "records/get",
            ])
        )

        XCTAssertTrue(
            discovered.allSatisfy {
                $0.metadata[
                    "acquiredVia"
                ] ==
                    "ard"
            }
        )

        XCTAssertTrue(
            discovered.allSatisfy {
                $0.metadata[
                    "ardRegistryID"
                ] ==
                    "fixture"
            }
        )

        XCTAssertTrue(
            discovered.allSatisfy {
                $0.metadata[
                    "ardIdentifier"
                ] ==
                    "urn:air:registry.example:api:durable-records"
            }
        )
    }

    func testG14CapabilityIsAbsentBeforeARDAndAppearsAfterDiscovery() throws {
        let before =
            CapabilityEngine(
                reflectors: []
            )

        XCTAssertTrue(
            try before
                .capabilities(
                    for:
                        "create durable ARD record"
                )
                .capabilities
                .isEmpty
        )

        let after =
            CapabilityEngine(
                reflectors: [],
                reflectorSources: [
                    source()
                ]
            )

        let create =
            try capability(
                operationID:
                    "records/create",
                in:
                    after,
                item:
                    "create durable ARD record"
            )

        XCTAssertTrue(
            create.id
                .hasPrefix(
                    "ard:fixture:"
                )
        )

        XCTAssertEqual(
            create.metadata[
                "substrate"
            ],
            "openapi"
        )

        XCTAssertEqual(
            create.metadata[
                "acquiredVia"
            ],
            "ard"
        )
    }

    func testG15ExecutesARDAcquiredCapabilityThroughCapabilityEngine() throws {
        let state =
            DurableState()

        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example/records"
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
                        as? [String: Any]
                )

            let title =
                try XCTUnwrap(
                    object["title"]
                        as? String
                )

            state.create(
                title:
                    title
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            request.url!,
                        statusCode:
                            201,
                        httpVersion:
                            nil,
                        headerFields: [
                            "Content-Type":
                                "application/json"
                        ]
                    )
                )

            let data =
                try JSONSerialization
                    .data(
                        withJSONObject: [
                            "id":
                                "r1",
                            "title":
                                title,
                        ],
                        options:
                            [.sortedKeys]
                    )

            return (
                response,
                data
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [],
                reflectorSources: [
                    source()
                ]
            )

        let create =
            try capability(
                operationID:
                    "records/create",
                in:
                    engine,
                item:
                    "create durable ARD record"
            )

        let result =
            try engine.run(
                id:
                    create.id,
                item:
                    "create durable ARD record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Hello ARD",
                ]
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertFalse(
            result
                .evidence
                .outcomeVerified
        )

        XCTAssertEqual(
            state.read(),
            "Hello ARD"
        )

        XCTAssertEqual(
            result.output,
            "{\"id\":\"r1\",\"title\":\"Hello ARD\"}"
        )
    }

    func testG16IndependentReadBackVerifiesDurableState() throws {
        let state =
            DurableState()

        StubURLProtocol.handler = {
            request in

            if request.httpMethod == "POST" {
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
                            as? [String: Any]
                    )

                let title =
                    try XCTUnwrap(
                        object["title"]
                            as? String
                    )

                state.create(
                    title:
                        title
                )

                let response =
                    try XCTUnwrap(
                        HTTPURLResponse(
                            url:
                                request.url!,
                            statusCode:
                                201,
                            httpVersion:
                                nil,
                            headerFields: [
                                "Content-Type":
                                    "application/json"
                            ]
                        )
                    )

                let data =
                    try JSONSerialization
                        .data(
                            withJSONObject: [
                                "id":
                                    "r1",
                                "title":
                                    title,
                            ],
                            options:
                                [.sortedKeys]
                        )

                return (
                    response,
                    data
                )
            }

            XCTAssertEqual(
                request.httpMethod,
                "GET"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example/records/r1"
            )

            let title =
                try XCTUnwrap(
                    state.read()
                )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            request.url!,
                        statusCode:
                            200,
                        httpVersion:
                            nil,
                        headerFields: [
                            "Content-Type":
                                "application/json"
                        ]
                    )
                )

            let data =
                try JSONSerialization
                    .data(
                        withJSONObject: [
                            "id":
                                "r1",
                            "title":
                                title,
                        ],
                        options:
                            [.sortedKeys]
                    )

            return (
                response,
                data
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [],
                reflectorSources: [
                    source()
                ]
            )

        let create =
            try capability(
                operationID:
                    "records/create",
                in:
                    engine,
                item:
                    "create durable ARD record"
            )

        let accepted =
            try engine.run(
                id:
                    create.id,
                item:
                    "create durable ARD record",
                confirmed:
                    true,
                arguments: [
                    "title":
                        "Verified ARD",
                ]
            )

        XCTAssertEqual(
            accepted.status,
            .accepted
        )

        XCTAssertFalse(
            accepted
                .evidence
                .outcomeVerified
        )

        let read =
            try capability(
                operationID:
                    "records/get",
                in:
                    engine,
                item:
                    "read durable ARD record"
            )

        let expected =
            "{\"id\":\"r1\",\"title\":\"Verified ARD\"}"

        let verified =
            try engine.run(
                id:
                    read.id,
                item:
                    "read durable ARD record",
                confirmed:
                    true,
                arguments: [
                    "id":
                        "r1",
                ],
                expectedOutput:
                    expected
            )

        XCTAssertEqual(
            verified.status,
            .verified
        )

        XCTAssertEqual(
            verified.output,
            expected
        )

        XCTAssertTrue(
            verified
                .evidence
                .outcomeVerified
        )
    }
}
