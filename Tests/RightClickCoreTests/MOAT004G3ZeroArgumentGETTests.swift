import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import RightClickCore

final class MOAT004G3ZeroArgumentGETTests:
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
            with request:
                URLRequest
        ) -> Bool {
            true
        }

        override class func canonicalRequest(
            for request:
                URLRequest
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
                                "MOAT004G3ZeroArgumentGETTests",
                            code:
                                1
                        )
                )

                return
            }

            do {
                let (
                    response,
                    data
                ) =
                    try handler(
                        request
                    )

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

    private func closedResponseSchema()
        -> [String: Any]
    {
        [
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
    }

    private func specification(
        path: String = "/status",
        operationID: String = "getStatus",
        operationParameters:
            [[String: Any]]? = nil,
        includeEmptyOperationParameters:
            Bool = false,
        pathParameters:
            [[String: Any]]? = nil,
        requestBody:
            [String: Any]? = nil
    ) throws -> Data {
        var operation:
            [String: Any] = [
                "operationId":
                    operationID,

                "summary":
                    "Get Status",

                "responses": [
                    "200": [
                        "description":
                            "Success",

                        "content": [
                            "application/json": [
                                "schema":
                                    closedResponseSchema()
                            ]
                        ],
                    ]
                ],
            ]

        if includeEmptyOperationParameters {
            operation[
                "parameters"
            ] =
                operationParameters ?? []
        } else if let operationParameters {
            operation[
                "parameters"
            ] =
                operationParameters
        }

        if let requestBody {
            operation[
                "requestBody"
            ] =
                requestBody
        }

        var pathObject:
            [String: Any] = [
                "get":
                    operation
            ]

        if let pathParameters {
            pathObject[
                "parameters"
            ] =
                pathParameters
        }

        let root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "Zero Argument GET Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    path:
                        pathObject
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

    func testAbsentOperationParametersReflectsZeroArgumentGETWithoutArgumentsSchema()
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
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "get status"
                    )
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability
                .metadata[
                    "method"
                ],
            "GET"
        )

        XCTAssertEqual(
            capability
                .metadata[
                    "path"
                ],
            "/status"
        )

        XCTAssertNil(
            capability
                .metadata[
                    "argumentsSchema"
                ]
        )

        XCTAssertNil(
            capability
                .metadata[
                    "requestContentType"
                ]
        )
    }

    func testExplicitEmptyOperationParametersAlsoReflectZeroArgumentGET()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                includeEmptyOperationParameters:
                                    true
                            )
                    )
                ]
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        "get status"
                )
                .capabilities

        XCTAssertEqual(
            capabilities.count,
            1
        )

        XCTAssertNil(
            capabilities
                .first?
                .metadata[
                    "argumentsSchema"
                ]
        )
    }

    func testZeroArgumentGETExecutesWithoutBodyOrContentType()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "GET"
            )

            XCTAssertEqual(
                request
                    .url?
                    .absoluteString,
                "https://api.example/status"
            )

            XCTAssertNil(
                request.httpBody
            )

            XCTAssertNil(
                request.value(
                    forHTTPHeaderField:
                        "Content-Type"
                )
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Accept"
                ),
                "application/json"
            )

            return (
                HTTPURLResponse(
                    url:
                        request.url!,
                    statusCode:
                        200,
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
                      "status": "ok"
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
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "get status"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "get status",
                confirmed:
                    true
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.output,
            """
            {"status":"ok"}
            """
        )
    }

    func testZeroArgumentGETRejectsUnexpectedArgumentsBeforeTransport()
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
                    "ShouldNotReachTransport",
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
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "get status"
                    )
                    .capabilities
                    .first
            )

        let result =
            try engine.run(
                id:
                    capability.id,
                item:
                    "get status",
                confirmed:
                    true,
                arguments:
                    [:]
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertFalse(
            transportCalled
        )
    }

    func testQueryParameterGETDoesNotBecomeZeroArgumentGET()
        throws
    {
        let queryParameter:
            [String: Any] = [
                "name":
                    "page",

                "in":
                    "query",

                "required":
                    false,

                "schema": [
                    "type":
                        "string"
                ],
            ]

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                operationParameters: [
                                    queryParameter
                                ]
                            )
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "get status"
                )
                .capabilities
                .isEmpty
        )
    }

    func testGETWithRequestBodyDoesNotBecomeZeroArgumentGET()
        throws
    {
        let requestBody:
            [String: Any] = [
                "required":
                    true,

                "content": [
                    "application/json": [
                        "schema": [
                            "type":
                                "object"
                        ]
                    ]
                ],
            ]

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                requestBody:
                                    requestBody
                            )
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "get status"
                )
                .capabilities
                .isEmpty
        )
    }

    func testPathLevelParametersDoNotBecomeZeroArgumentGET()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                pathParameters:
                                    []
                            )
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "get status"
                )
                .capabilities
                .isEmpty
        )
    }

    func testExistingRequiredStringPathGETRemainsSupported()
        throws
    {
        let pathParameter:
            [String: Any] = [
                "name":
                    "id",

                "in":
                    "path",

                "required":
                    true,

                "schema": [
                    "type":
                        "string"
                ],
            ]

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try specification(
                                path:
                                    "/records/{id}",
                                operationID:
                                    "getRecord",
                                operationParameters: [
                                    pathParameter
                                ]
                            )
                    )
                ]
            )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "get record"
                    )
                    .capabilities
                    .first
            )

        XCTAssertNotNil(
            capability
                .metadata[
                    "argumentsSchema"
                ]
        )
    }

    func testFrozenGitHubAuthenticatedUserStillDoesNotReflectUntilG4()
        throws
    {
        guard
            let specificationPath =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G3_SPEC_PATH"
                    ]
        else {
            throw XCTSkip(
                "MOAT004_G3_SPEC_PATH required."
            )
        }

        let data =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            specificationPath
                    )
            )

        let loaderData =
            data

        final class Loader
        {
            let data: Data

            init(
                data: Data
            ) {
                self.data =
                    data
            }

            func load(
                _ url: URL
            ) throws -> Data {
                data
            }
        }

        let loader =
            Loader(
                data:
                    loaderData
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                BonjourOpenAPIServiceDescriptor(
                    instanceName:
                        "Frozen Real Contract",
                    serviceType:
                        "_rightclick._tcp.",
                    domain:
                        "local.",
                    host:
                        "ignored.invalid",
                    port:
                        9,
                    txt: [
                        "kind":
                            "openapi",

                        "spec-url":
                            "https://spec.example/github-openapi.json",

                        "base-url":
                            "https://api.github.com",
                    ]
                )
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let capabilities =
            try engine
                .capabilities(
                    for:
                        "Get the authenticated GitHub user"
                )
                .capabilities

        let target =
            capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ]
                    == "users/get-authenticated"
                }

        XCTAssertNil(
            target,
            "G3 must not accidentally implement G4 response compatibility."
        )
    }
}
