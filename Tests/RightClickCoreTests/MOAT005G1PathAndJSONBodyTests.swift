import Foundation
import XCTest

@testable import RightClickCore

final class MOAT005G1PathAndJSONBodyTests:
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
                                "MOAT005G1PathAndJSONBodyTests",
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

    private func closedStringObject(
        required: [String],
        properties: [String]
    ) -> [String: Any] {
        [
            "type":
                "object",

            "additionalProperties":
                false,

            "required":
                required,

            "properties":
                Dictionary(
                    uniqueKeysWithValues:
                        properties.map {
                            (
                                $0,
                                [
                                    "type":
                                        "string"
                                ]
                            )
                        }
                ),
        ]
    }

    private func specification(
        pathParameterName:
            String = "id",
        bodyProperties:
            [String] = [
                "title",
                "body",
            ]
    ) throws -> Data {
        let pathParameter:
            [String: Any] = [
                "name":
                    pathParameterName,

                "in":
                    "path",

                "required":
                    true,

                "schema": [
                    "type":
                        "string"
                ],
            ]

        let requestSchema =
            closedStringObject(
                required:
                    bodyProperties,
                properties:
                    bodyProperties
            )

        let responseSchema =
            closedStringObject(
                required: [
                    "status"
                ],
                properties: [
                    "status"
                ]
            )

        let root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "MOAT-005 G1 Synthetic Mutation Provider",

                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/records/{\(pathParameterName)}": [
                        "post": [
                            "operationId":
                                "records/create",

                            "summary":
                                "Create synthetic record",

                            "parameters": [
                                pathParameter
                            ],

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
                        "create synthetic record"
                )
                .capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ] == "records/create"
                }
        )
    }

    func testPathAndJSONBodyReflectOneCombinedClosedArgumentSchema()
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

        XCTAssertEqual(
            capability.metadata[
                "method"
            ],
            "POST"
        )

        XCTAssertEqual(
            capability.metadata[
                "path"
            ],
            "/records/{id}"
        )

        XCTAssertEqual(
            capability.metadata[
                "requestContentType"
            ],
            "application/json"
        )

        let schemaString =
            try XCTUnwrap(
                capability.metadata[
                    "argumentsSchema"
                ]
            )

        let schemaData =
            try XCTUnwrap(
                schemaString.data(
                    using:
                        .utf8
                )
            )

        let schema =
            try XCTUnwrap(
                JSONSerialization
                    .jsonObject(
                        with:
                            schemaData
                    )
                    as? [String: Any]
            )

        XCTAssertEqual(
            schema[
                "type"
            ] as? String,
            "object"
        )

        XCTAssertEqual(
            schema[
                "additionalProperties"
            ] as? Bool,
            false
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
                "id",
                "title",
                "body",
            ])
        )

        let properties =
            try XCTUnwrap(
                schema[
                    "properties"
                ] as? [String: Any]
            )

        XCTAssertEqual(
            Set(
                properties.keys
            ),
            Set([
                "id",
                "title",
                "body",
            ])
        )
    }

    func testPathAndJSONBodyPartitionsArgumentsBeforeTransport()
        throws
    {
        var transportCalls =
            0

        StubURLProtocol.handler = {
            request in

            transportCalls +=
                1

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request
                    .url?
                    .absoluteString,
                "https://api.example/records/alpha"
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

            XCTAssertNil(
                object[
                    "id"
                ]
            )

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
                    """
                    {
                      "status": "created"
                    }
                    """.utf8
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
                    "create synthetic record",
                confirmed:
                    true,
                arguments: [
                    "id":
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

        XCTAssertEqual(
            result.output,
            """
            {"status":"created"}
            """
        )
    }

    func testCombinedContractRejectsUnknownArgumentBeforeTransport()
        throws
    {
        var transportCalled =
            false

        StubURLProtocol.handler = {
            request in

            transportCalled =
                true

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
                    "create synthetic record",
                confirmed:
                    true,
                arguments: [
                    "id":
                        "alpha",
                    "title":
                        "Hello",
                    "body":
                        "World",
                    "unexpected":
                        "must-fail",
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

    func testPathAndBodyNameCollisionAbstains()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                pathParameterName:
                                    "title",
                                bodyProperties: [
                                    "title",
                                    "body",
                                ]
                            )
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "create synthetic record"
                )
                .capabilities
                .isEmpty
        )
    }
}
