import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import RightClickCore

final class MOAT005G3GitHubRequestSchemaTests:
    XCTestCase
{
    private final class StubURLProtocol:
        URLProtocol
    {
        static var called =
            false

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
            Self.called =
                true

            client?.urlProtocol(
                self,
                didFailWithError:
                    NSError(
                        domain:
                            "TransportMustNotRun",
                        code:
                            1
                    )
            )
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.called =
            false

        super.tearDown()
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
                "MOAT005G3IssuesCreateRequest.json"
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

    private func argumentsSchema(
        _ capability:
            Capability
    ) throws -> [String: Any]
    {
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

        return try XCTUnwrap(
            JSONSerialization
                .jsonObject(
                    with:
                        data
                )
                as? [String: Any]
        )
    }

    func testFrozenGitHubRequestSchemaReflectsThroughSafeNarrowing()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector()
                ]
            )

        _ =
            try capability(
                engine:
                    engine
            )
    }

    func testNarrowedSchemaRetainsRequiredTitleAndOptionalBody()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector()
                ]
            )

        let schema =
            try argumentsSchema(
                try capability(
                    engine:
                        engine
                )
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
                "owner",
                "repo",
                "title",
            ])
        )

        let properties =
            try XCTUnwrap(
                schema[
                    "properties"
                ] as? [String: Any]
            )

        for key in [
            "owner",
            "repo",
            "title",
            "body",
        ] {
            XCTAssertNotNil(
                properties[
                    key
                ]
            )
        }

        XCTAssertNil(
            properties[
                "labels"
            ]
        )

        XCTAssertNil(
            properties[
                "assignees"
            ]
        )

        XCTAssertNil(
            properties[
                "issue_field_values"
            ]
        )

        XCTAssertNil(
            properties[
                "parent_issue_id"
            ]
        )
    }

    func testTitleOneOfIsSafelyNarrowedToString()
        throws
    {
        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector()
                ]
            )

        let schema =
            try argumentsSchema(
                try capability(
                    engine:
                        engine
                )
            )

        let properties =
            try XCTUnwrap(
                schema[
                    "properties"
                ] as? [String: Any]
            )

        let title =
            try XCTUnwrap(
                properties[
                    "title"
                ] as? [String: Any]
            )

        XCTAssertEqual(
            title[
                "type"
            ] as? String,
            "string"
        )
    }

    func testUnsupportedOptionalProviderFieldIsRejectedBeforeTransport()
        throws
    {
        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration.protocolClasses = [
            StubURLProtocol.self
        ]

        let session =
            URLSession(
                configuration:
                    configuration
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    try reflector(
                        session:
                            session
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

                    // Provider supports this field, but G3 has not
                    // safely modelled arrays. It must remain outside
                    // RIGHTCLICK's narrowed contract.
                    "labels":
                        "must-not-pass",
                ]
            )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertFalse(
            StubURLProtocol.called
        )
    }
}
