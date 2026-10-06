import Foundation
import XCTest

@testable import RightClickCore

final class MOAT005G4MutationJSONResponseFallbackTests:
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
                                "MOAT005G4MutationJSONResponseFallbackTests",
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

    private func fixture()
        throws -> Data
    {
        let testFile =
            URL(
                fileURLWithPath:
                    #filePath
            )

        let fixtureURL =
            testFile
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures"
            )
            .appendingPathComponent(
                "MOAT005G4IssuesCreateRealResponse.json"
            )

        return try Data(
            contentsOf:
                fixtureURL
        )
    }

    private func reflector(
        session:
            URLSession = .shared
    ) throws -> OpenAPIReflector
    {
        try OpenAPIReflector(
            specificationData:
                try fixture(),
            baseURL:
                URL(
                    string:
                        "https://api.example"
                )!,
            session:
                session
        )
    }

    private func capability(
        engine:
            CapabilityEngine
    ) throws -> Capability
    {
        try XCTUnwrap(
            engine
                .capabilities(
                    for:
                        "create issue"
                )
                .capabilities
                .first {
                    $0.metadata[
                        "operationId"
                    ] == "issues/create"
                }
        )
    }

    func testRealMutationResponseReflectsWithJSONSyntaxFallback()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector()
                ]
            )

        let action =
            try capability(
                engine:
                    engine
            )

        XCTAssertEqual(
            action.metadata[
                "method"
            ],
            "POST"
        )

        XCTAssertEqual(
            action.metadata[
                "responseContentType"
            ],
            "application/json"
        )

        XCTAssertEqual(
            action.metadata[
                "resultValidation"
            ],
            "json_syntax_only"
        )

        XCTAssertNil(
            action.metadata[
                "resultSchema"
            ]
        )
    }

    func testValidRealStyle201JSONIsAcceptedButUnverified()
        throws
    {
        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request.httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example/repos/example/repo/issues"
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
                      "id": 123,
                      "number": 1,
                      "state": "open",
                      "title": "Hello"
                    }
                    """.utf8
                )
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        session:
                            session()
                    )
                ]
            )

        let action =
            try capability(
                engine:
                    engine
            )

        let result =
            try engine.run(
                id:
                    action.id,
                item:
                    "create issue",
                confirmed:
                    true,
                arguments: [
                    "owner":
                        "example",
                    "repo":
                        "repo",
                    "title":
                        "Hello",
                    "body":
                        "World",
                ]
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertEqual(
            result.evidence
                .outcomeVerified,
            false
        )

        let output =
            try XCTUnwrap(
                result.output
            )

        let data =
            try XCTUnwrap(
                output.data(
                    using:
                        .utf8
                )
            )

        let object =
            try XCTUnwrap(
                JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any]
            )

        XCTAssertEqual(
            object[
                "title"
            ] as? String,
            "Hello"
        )

        XCTAssertEqual(
            object[
                "state"
            ] as? String,
            "open"
        )
    }

    func testMalformed201JSONFailsProviderContract()
        throws
    {
        StubURLProtocol.handler = {
            request in

            (
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
                    #"{"id":123"#.utf8
                )
            )
        }

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        session:
                            session()
                    )
                ]
            )

        let action =
            try capability(
                engine:
                    engine
            )

        let result =
            try engine.run(
                id:
                    action.id,
                item:
                    "create issue",
                confirmed:
                    true,
                arguments: [
                    "owner":
                        "example",
                    "repo":
                        "repo",
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

        XCTAssertEqual(
            result.evidence
                .type,
            "provider_contract_failure"
        )

        XCTAssertEqual(
            result.evidence
                .outcomeVerified,
            false
        )
    }
}
