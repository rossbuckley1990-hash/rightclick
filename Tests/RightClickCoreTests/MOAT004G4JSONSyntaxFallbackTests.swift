import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import RightClickCore

final class MOAT004G4JSONSyntaxFallbackTests:
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
                                "MOAT004G4JSONSyntaxFallbackTests",
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

    private func strongSchema()
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

    private func unsupportedSchema()
        -> [String: Any]
    {
        [
            "oneOf": [
                [
                    "type":
                        "object"
                ],
                [
                    "type":
                        "array"
                ],
            ]
        ]
    }

    private func zeroArgumentGETSpecification(
        responseSchema:
            [String: Any]?
    ) throws -> Data {
        var jsonContent:
            [String: Any] = [:]

        if let responseSchema {
            jsonContent[
                "schema"
            ] =
                responseSchema
        }

        let root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "Read Only JSON Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/status": [
                        "get": [
                            "operationId":
                                "getStatus",

                            "summary":
                                "Get Status",

                            "responses": [
                                "200": [
                                    "description":
                                        "Success",

                                    "content": [
                                        "application/json":
                                            jsonContent
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

    private func mutatingSpecificationWithUnsupportedResponse()
        throws -> Data
    {
        let root:
            [String: Any] = [
                "openapi":
                    "3.0.3",

                "info": [
                    "title":
                        "Mutating Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/records": [
                        "post": [
                            "operationId":
                                "createRecord",

                            "summary":
                                "Create Record",

                            "requestBody": [
                                "required":
                                    true,

                                "content": [
                                    "application/json": [
                                        "schema": [
                                            "type":
                                                "object",

                                            "additionalProperties":
                                                false,

                                            "required": [
                                                "title"
                                            ],

                                            "properties": [
                                                "title": [
                                                    "type":
                                                        "string"
                                                ]
                                            ],
                                        ]
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
                                                unsupportedSchema()
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
    ) throws -> OpenAPIReflector
    {
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

    func testUnsupportedDeclaredJSONSchemaReflectsGETWithSyntaxOnlyMetadata()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try zeroArgumentGETSpecification(
                                responseSchema:
                                    unsupportedSchema()
                            )
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
                    "resultValidation"
                ],
            "json_syntax_only"
        )

        XCTAssertNil(
            capability
                .metadata[
                    "resultSchema"
                ]
        )

        XCTAssertEqual(
            capability
                .metadata[
                    "method"
                ],
            "GET"
        )
    }

    func testStrongClosedResponseSchemaRemainsPreferred()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try zeroArgumentGETSpecification(
                                responseSchema:
                                    strongSchema()
                            )
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

        XCTAssertNotNil(
            capability
                .metadata[
                    "resultSchema"
                ]
        )

        XCTAssertNil(
            capability
                .metadata[
                    "resultValidation"
                ]
        )
    }

    func testSyntaxOnlyGETAcceptsAndCanonicalizesValidJSON()
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
                    .value(
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
                      "z": 1,
                      "a": [
                        true,
                        null,
                        "x"
                      ]
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
                            try zeroArgumentGETSpecification(
                                responseSchema:
                                    unsupportedSchema()
                            ),
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
            {"a":[true,null,"x"],"z":1}
            """
        )
    }

    func testSyntaxOnlyGETRejectsInvalidJSON()
        throws
    {
        StubURLProtocol.handler = {
            request in

            (
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
                    {"broken":
                    """.utf8
                )
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try zeroArgumentGETSpecification(
                                responseSchema:
                                    unsupportedSchema()
                            ),
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
            .failed
        )

        XCTAssertEqual(
            result.evidence.type,
            "provider_contract_failure"
        )
    }

    func testSyntaxOnlyGETStillRequiresApplicationJSONContentType()
        throws
    {
        StubURLProtocol.handler = {
            request in

            (
                HTTPURLResponse(
                    url:
                        request.url!,
                    statusCode:
                        200,
                    httpVersion:
                        "HTTP/1.1",
                    headerFields: [
                        "Content-Type":
                            "text/plain"
                    ]
                )!,
                Data(
                    """
                    {"status":"ok"}
                    """.utf8
                )
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try zeroArgumentGETSpecification(
                                responseSchema:
                                    unsupportedSchema()
                            ),
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
            .failed
        )
    }

    func testGETWithoutDeclaredJSONSchemaStillAbstains()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try zeroArgumentGETSpecification(
                                responseSchema:
                                    nil
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

    // MOAT-004 originally froze JSON syntax fallback as GET-only.
    // MOAT-005 G4 deliberately generalizes the same conservative
    // response observation to supported mutation requests.
    //
    // Historical MOAT-004 evidence remains preserved in Git history.
    func testMutatingOperationWithUnsupportedJSONResponseUsesSyntaxOnlyMetadata()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        specification:
                            try mutatingSpecificationWithUnsupportedResponse()
                    )
                ]
            )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "create record"
                    )
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability.metadata[
                "method"
            ],
            "POST"
        )

        XCTAssertEqual(
            capability.metadata[
                "responseContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            capability.metadata[
                "resultValidation"
            ],
            "json_syntax_only"
        )

        XCTAssertNil(
            capability.metadata[
                "resultSchema"
            ]
        )
    }

    func testFrozenGitHubUserReflectsForFirstTimeButHasNoExternalAuthorityYet()
        throws
    {
        guard
            let specificationPath =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G4_SPEC_PATH"
                    ]
        else {
            throw XCTSkip(
                "MOAT004_G4_SPEC_PATH required."
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
                    data
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

        let target =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for:
                            "Get the authenticated GitHub user"
                    )
                    .capabilities
                    .first {
                        $0.metadata[
                            "operationId"
                        ]
                        == "users/get-authenticated"
                    }
            )

        XCTAssertEqual(
            target.title,
            "Get the authenticated user"
        )

        XCTAssertEqual(
            target
                .metadata[
                    "method"
                ],
            "GET"
        )

        XCTAssertEqual(
            target
                .metadata[
                    "path"
                ],
            "/user"
        )

        XCTAssertNil(
            target
                .metadata[
                    "argumentsSchema"
                ]
        )

        XCTAssertNil(
            target
                .metadata[
                    "resultSchema"
                ]
        )

        XCTAssertEqual(
            target
                .metadata[
                    "resultValidation"
                ],
            "json_syntax_only"
        )

        XCTAssertNil(
            target
                .metadata[
                    "authorityRequired"
                ],
            "G5 owns external authority. G4 must not invent it."
        )
    }
}
