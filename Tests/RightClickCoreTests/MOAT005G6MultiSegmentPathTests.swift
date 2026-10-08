import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import RightClickCore

final class MOAT005G6MultiSegmentPathTests:
    XCTestCase
{
    private final class StubURLProtocol:
        URLProtocol
    {
        static var handler:
            ((URLRequest) throws
                -> (HTTPURLResponse, Data))?

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

            guard
                let handler =
                    Self.handler
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        NSError(
                            domain:
                                "MOAT005G6MultiSegmentPathTests",
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
                    defer { stream.close() }

                    var data =
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
                            throw (
                                stream.streamError
                                ?? NSError(
                                    domain:
                                        "MOAT005G6MultiSegmentPathTests",
                                    code:
                                        2
                                )
                            )
                        }

                        if count == 0 {
                            break
                        }

                        data.append(
                            contentsOf:
                                buffer.prefix(
                                    count
                                )
                        )
                    }

                    observed.httpBody =
                        data
                }

                let (
                    response,
                    data
                ) =
                    try handler(
                        observed
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

        StubURLProtocol.requestCount =
            0

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

    private func specification(
        multiSegmentValue:
            Any? = true
    ) throws -> Data {
        var pathParameter:
            [String: Any] = [
                "name":
                    "path",
                "description":
                    "path parameter",
                "in":
                    "path",
                "required":
                    true,
                "schema": [
                    "type":
                        "string"
                ],
            ]

        if let multiSegmentValue {
            pathParameter[
                "x-multi-segment"
            ] =
                multiSegmentValue
        }

        let parameters:
            [[String: Any]] = [
                [
                    "name":
                        "owner",
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
                        "repo",
                    "in":
                        "path",
                    "required":
                        true,
                    "schema": [
                        "type":
                            "string"
                    ],
                ],
                pathParameter,
            ]

        let requestSchema:
            [String: Any] = [
                "type":
                    "object",

                "additionalProperties":
                    false,

                "required": [
                    "message",
                    "content",
                ],

                "properties": [
                    "message": [
                        "type":
                            "string"
                    ],
                    "content": [
                        "type":
                            "string"
                    ],
                    "sha": [
                        "type":
                            "string"
                    ],
                    "branch": [
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
                        "G6 Generic File Provider",
                    "version":
                        "1.0.0",
                ],

                "paths": [
                    "/repos/{owner}/{repo}/contents/{path}": [
                        "put": [
                            "operationId":
                                "files/create-or-update",

                            "summary":
                                "Create or update contents",

                            "parameters":
                                parameters,

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
                                "200": [
                                    "description":
                                        "updated",

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

    private func engine(
        specification:
            Data,
        session:
            URLSession = .shared
    ) throws -> CapabilityEngine {
        CapabilityEngine(
            reflectors: [
                try OpenAPIReflector(
                    specificationData:
                        specification,
                    baseURL:
                        URL(
                            string:
                                "https://api.example"
                        )!,
                    session:
                        session
                )
            ]
        )
    }

    private func capability(
        _ engine:
            CapabilityEngine
    ) throws -> Capability {
        try XCTUnwrap(
            try engine
                .capabilities(
                    for:
                        "update provider contents"
                )
                .capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ] ==
                        "files/create-or-update"
                }
        )
    }

    private func argumentsSchema(
        _ capability:
            Capability
    ) throws -> [String: Any] {
        let raw =
            try XCTUnwrap(
                capability
                    .metadata[
                        "argumentsSchema"
                    ]
            )

        return try XCTUnwrap(
            JSONSerialization
                .jsonObject(
                    with:
                        Data(
                            raw.utf8
                        )
                )
                as? [String: Any]
        )
    }

    func testDeclaredMultiSegmentPathReflectsAsOrdinaryClosedStringArgument()
        throws
    {
        let value =
            try engine(
                specification:
                    try specification()
            )

        let target =
            try capability(
                value
            )

        let schema =
            try argumentsSchema(
                target
            )

        XCTAssertEqual(
            schema[
                "additionalProperties"
            ] as? Bool,
            false
        )

        XCTAssertEqual(
            Set(
                try XCTUnwrap(
                    schema[
                        "required"
                    ] as? [String]
                )
            ),
            Set([
                "owner",
                "repo",
                "path",
                "message",
                "content",
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
                "owner",
                "repo",
                "path",
                "message",
                "content",
                "sha",
                "branch",
            ])
        )

        let pathProperty =
            try XCTUnwrap(
                properties[
                    "path"
                ] as? [String: Any]
            )

        XCTAssertEqual(
            pathProperty[
                "type"
            ] as? String,
            "string"
        )

        XCTAssertNil(
            pathProperty[
                "x-multi-segment"
            ]
        )
    }

    func testDeclaredMultiSegmentPathPreservesHierarchyButOrdinaryArgumentsDoNot()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "PUT"
            )

            XCTAssertEqual(
                request.url?
                    .absoluteString,
                "https://api.example/repos/acme%2Fdivision/rightclick/contents/docs/LAUNCH.md"
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
                    "message":
                        "docs: refresh launch",
                    "content":
                        "BASE64-CONTENT",
                ]
            )

            XCTAssertNil(
                object[
                    "owner"
                ]
            )

            XCTAssertNil(
                object[
                    "repo"
                ]
            )

            XCTAssertNil(
                object[
                    "path"
                ]
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
                    #"{"status":"updated"}"#.utf8
                )
            )
        }

        let value =
            try engine(
                specification:
                    try specification(),
                session:
                    session()
            )

        let target =
            try capability(
                value
            )

        let result =
            try value.run(
                id:
                    target.id,
                item:
                    "update provider contents",
                confirmed:
                    true,
                arguments: [
                    "owner":
                        "acme/division",
                    "repo":
                        "rightclick",
                    "path":
                        "docs/LAUNCH.md",
                    "message":
                        "docs: refresh launch",
                    "content":
                        "BASE64-CONTENT",
                ]
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
    }

    func testUndeclaredMultiSegmentPathKeepsSlashEncodedAsData()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.url?
                    .absoluteString,
                "https://api.example/repos/acme/rightclick/contents/docs%2FLAUNCH.md"
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
                    #"{"status":"updated"}"#.utf8
                )
            )
        }

        let value =
            try engine(
                specification:
                    try specification(
                        multiSegmentValue:
                            nil
                    ),
                session:
                    session()
            )

        let target =
            try capability(
                value
            )

        let result =
            try value.run(
                id:
                    target.id,
                item:
                    "update provider contents",
                confirmed:
                    true,
                arguments: [
                    "owner":
                        "acme",
                    "repo":
                        "rightclick",
                    "path":
                        "docs/LAUNCH.md",
                    "message":
                        "docs: refresh launch",
                    "content":
                        "BASE64-CONTENT",
                ]
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
    }

    func testMultiSegmentPathTraversalAndEmptySegmentsFailBeforeTransport()
        throws
    {
        let value =
            try engine(
                specification:
                    try specification(),
                session:
                    session()
            )

        let target =
            try capability(
                value
            )

        StubURLProtocol.handler = {
            request in

            XCTFail(
                "Transport must not run for unsafe multi-segment path: \(request)"
            )

            throw NSError(
                domain:
                    "TransportMustNotRun",
                code:
                    1
            )
        }

        let unsafe = [
            "../LAUNCH.md",
            "/docs/LAUNCH.md",
            "docs/LAUNCH.md/",
            "docs//LAUNCH.md",
            "docs/../LAUNCH.md",
            "docs/./LAUNCH.md",
        ]

        for path
            in unsafe
        {
            let before =
                StubURLProtocol
                    .requestCount

            let result =
                try value.run(
                    id:
                        target.id,
                    item:
                        "update provider contents",
                    confirmed:
                        true,
                    arguments: [
                        "owner":
                            "acme",
                        "repo":
                            "rightclick",
                        "path":
                            path,
                        "message":
                            "docs: refresh launch",
                        "content":
                            "BASE64-CONTENT",
                    ]
                )

            XCTAssertEqual(
                result.status,
                .failed,
                "unsafe path unexpectedly accepted: \(path)"
            )

            XCTAssertEqual(
                StubURLProtocol
                    .requestCount,
                before,
                "transport ran for unsafe path: \(path)"
            )
        }
    }

    func testMalformedMultiSegmentExtensionAbstains()
        throws
    {
        let value =
            try engine(
                specification:
                    try specification(
                        multiSegmentValue:
                            "true"
                    )
            )

        XCTAssertTrue(
            try value
                .capabilities(
                    for:
                        "update provider contents"
                )
                .capabilities
                .filter {
                    $0.metadata[
                        "operationId"
                    ] ==
                        "files/create-or-update"
                }
                .isEmpty
        )
    }

    func testFullFrozenGitHubContractDiscoversCreateOrUpdateContents()
        throws
    {
        let source =
            BonjourOpenAPISource(
                startBrowsing:
                    false
            )

        source.update(
            resolved:
                BonjourOpenAPIServiceDescriptor(
                    instanceName:
                        "MOAT-005 G6 Full Frozen GitHub Contract",

                    serviceType:
                        "_rightclick._tcp.",

                    domain:
                        "local.",

                    host:
                        "discovery.invalid",

                    port:
                        9,

                    txt: [
                        "kind":
                            "openapi",

                        "spec-url":
                            "https://raw.githubusercontent.com/github/rest-api-description/836ce198db13a6fb194547e53eea99c6ddae495b/descriptions/api.github.com/api.github.com.2026-03-10.json",

                        "base-url":
                            "https://api.github.com",

                        "auth-scheme":
                            "MOAT005G6Bearer",
                    ]
                )
        )

        XCTAssertEqual(
            source
                .reflectors()
                .count,
            1
        )

        let value =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let matches =
            try value
                .capabilities(
                    for:
                        "Update docs/LAUNCH.md"
                )
                .capabilities
                .filter {
                    $0.metadata[
                        "operationId"
                    ] ==
                        "repos/create-or-update-file-contents"
                }

        XCTAssertEqual(
            matches.count,
            1,
            "The untouched frozen GitHub contract must expose exactly one contents write capability."
        )

        let target =
            try XCTUnwrap(
                matches.first
            )

        XCTAssertEqual(
            target.title,
            "Create or update file contents"
        )

        XCTAssertEqual(
            target.metadata[
                "method"
            ],
            "PUT"
        )

        XCTAssertEqual(
            target.metadata[
                "path"
            ],
            "/repos/{owner}/{repo}/contents/{path}"
        )

        XCTAssertEqual(
            target.metadata[
                "specificationSHA256"
            ],
            "1429e93b5cbfa7547aa197e9553a6dacbd8d4aaf28012446ed730b152bcdf284"
        )

        XCTAssertEqual(
            target.metadata[
                "authorityRequired"
            ],
            "true"
        )

        XCTAssertEqual(
            target.metadata[
                "authorityOrigin"
            ],
            "https://api.github.com"
        )

        XCTAssertEqual(
            target.metadata[
                "resultValidation"
            ],
            "json_syntax_only"
        )

        XCTAssertNil(
            target.metadata[
                "resultSchema"
            ]
        )

        let schema =
            try argumentsSchema(
                target
            )

        XCTAssertEqual(
            schema[
                "additionalProperties"
            ] as? Bool,
            false
        )

        XCTAssertEqual(
            Set(
                try XCTUnwrap(
                    schema[
                        "required"
                    ] as? [String]
                )
            ),
            Set([
                "owner",
                "repo",
                "path",
                "message",
                "content",
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
                "owner",
                "repo",
                "path",
                "message",
                "content",
                "sha",
                "branch",
            ])
        )

        XCTAssertNil(
            properties[
                "committer"
            ]
        )

        XCTAssertNil(
            properties[
                "author"
            ]
        )
    }
}
