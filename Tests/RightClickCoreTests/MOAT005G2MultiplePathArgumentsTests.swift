import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import RightClickCore

final class MOAT005G2MultiplePathArgumentsTests:
    XCTestCase
{
    private final class StubURLProtocol:
        URLProtocol
    {
        static var handler:
            ((URLRequest) throws
                -> (HTTPURLResponse, Data))?

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
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        NSError(
                            domain:
                                "MOAT005G2MultiplePathArgumentsTests",
                            code:
                                1
                        )
                )

                return
            }

            do {
                let (response, data) =
                    try handler(request)

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

    private static func observedRequestBody(
        _ request: URLRequest
    ) throws -> Data {
        if let body =
            request.httpBody
        {
            return body
        }

        guard
            let stream =
                request.httpBodyStream
        else {
            throw NSError(
                domain:
                    "MOAT005G2MultiplePathArgumentsTests",
                code:
                    2
            )
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
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
                throw (
                    stream.streamError
                    ?? NSError(
                        domain:
                            "MOAT005G2MultiplePathArgumentsTests",
                        code:
                            3
                    )
                )
            }

            if count == 0 {
                break
            }

            data.append(
                contentsOf:
                    buffer.prefix(count)
            )
        }

        return data
    }

    private func specification(
        parameters:
            [[String: Any]]? = nil,
        path:
            String =
                "/groups/{group}/records/{record}"
    ) throws -> Data {
        let defaultParameters:
            [[String: Any]] = [
                [
                    "name":
                        "group",
                    "in":
                        "path",
                    "required":
                        true,
                    "schema": [
                        "type":
                            "string"
                    ],
                ],
                [
                    "name":
                        "record",
                    "in":
                        "path",
                    "required":
                        true,
                    "schema": [
                        "type":
                            "string"
                    ],
                ],
            ]

        let requestSchema:
            [String: Any] = [
                "type":
                    "object",
                "additionalProperties":
                    false,
                "required": [
                    "title",
                    "body",
                ],
                "properties": [
                    "title": [
                        "type":
                            "string"
                    ],
                    "body": [
                        "type":
                            "string"
                    ],
                ],
            ]

        let responseSchema:
            [String: Any] = [
                "type":
                    "object",
                "additionalProperties":
                    false,
                "required": [
                    "status"
                ],
                "properties": [
                    "status": [
                        "type":
                            "string"
                    ]
                ],
            ]

        let root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "MOAT-005 G2 Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    path: [
                        "post": [
                            "operationId":
                                "records/create-multi-path",

                            "summary":
                                "Create record with multiple path arguments",

                            "parameters":
                                parameters
                                ?? defaultParameters,

                            "requestBody": [
                                "required":
                                    true,

                                "content": [
                                    "application/json": [
                                        "schema":
                                            requestSchema
                                    ]
                                ],
                            ],

                            "responses": [
                                "201": [
                                    "description":
                                        "Created",

                                    "content": [
                                        "application/json": [
                                            "schema":
                                                responseSchema
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ]
                ],
            ]

        return try JSONSerialization
            .data(
                withJSONObject:
                    root,
                options:
                    [.sortedKeys]
            )
    }

    private func reflector(
        specification:
            Data,
        session:
            URLSession? = nil
    ) throws -> OpenAPIReflector {
        try OpenAPIReflector(
            specificationData:
                specification,
            baseURL:
                URL(
                    string:
                        "https://api.example"
                )!,
            session:
                session ?? .shared
        )
    }

    private func capability(
        engine:
            CapabilityEngine
    ) throws -> Capability {
        try XCTUnwrap(
            engine
                .capabilities(
                    for:
                        "create record"
                )
                .capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ]
                    == "records/create-multi-path"
                }
        )
    }

    func testMultiplePathArgumentsReflectInCombinedSchema()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification()
                    )
                ]
            )

        let capability =
            try capability(
                engine:
                    engine
            )

        let raw =
            try XCTUnwrap(
                capability.metadata[
                    "argumentsSchema"
                ]
            )

        let data =
            try XCTUnwrap(
                raw.data(
                    using:
                        .utf8
                )
            )

        let schema =
            try XCTUnwrap(
                JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any]
            )

        let required =
            Set(
                try XCTUnwrap(
                    schema[
                        "required"
                    ] as? [String]
                )
            )

        XCTAssertEqual(
            required,
            Set([
                "group",
                "record",
                "title",
                "body",
            ])
        )
    }

    func testMultiplePathArgumentsSubstituteAndPartition()
        throws
    {
        var transportCalls = 0

        StubURLProtocol.handler = {
            request in

            transportCalls += 1

            XCTAssertEqual(
                request
                    .url?
                    .absoluteString,
                "https://api.example/groups/engineering/records/alpha"
            )

            let body =
                try Self.observedRequestBody(
                    request
                )

            let object =
                try XCTUnwrap(
                    JSONSerialization
                        .jsonObject(
                            with:
                                body
                        )
                        as? [String: String]
                )

            XCTAssertEqual(
                object,
                [
                    "title":
                        "Hello",
                    "body":
                        "World",
                ]
            )

            XCTAssertNil(object["group"])
            XCTAssertNil(object["record"])

            return (
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
                )!,
                Data(
                    #"{"status":"created"}"#.utf8
                )
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(),
                        session:
                            session()
                    )
                ]
            )

        let capability =
            try capability(
                engine:
                    engine
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "create record",
                confirmed:
                    true,
                arguments: [
                    "group":
                        "engineering",
                    "record":
                        "alpha",
                    "title":
                        "Hello",
                    "body":
                        "World",
                ]
            )

        XCTAssertEqual(
            transportCalls,
            1
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )
    }

    func testMissingOneRequiredPathArgumentFailsBeforeTransport()
        throws
    {
        var transportCalled = false

        StubURLProtocol.handler = {
            request in

            transportCalled = true

            throw NSError(
                domain:
                    "TransportMustNotRun",
                code:
                    1
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(),
                        session:
                            session()
                    )
                ]
            )

        let capability =
            try capability(
                engine:
                    engine
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "create record",
                confirmed:
                    true,
                arguments: [
                    "group":
                        "engineering",
                    "title":
                        "Hello",
                    "body":
                        "World",
                ]
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )
    }

    func testDuplicatePathParameterNamesAbstain()
        throws
    {
        let duplicate:
            [[String: Any]] = [
                [
                    "name":
                        "group",
                    "in":
                        "path",
                    "required":
                        true,
                    "schema": [
                        "type":
                            "string"
                    ],
                ],
                [
                    "name":
                        "group",
                    "in":
                        "path",
                    "required":
                        true,
                    "schema": [
                        "type":
                            "string"
                    ],
                ],
            ]

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                parameters:
                                    duplicate
                            )
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "create record"
                )
                .capabilities
                .isEmpty
        )
    }
}
