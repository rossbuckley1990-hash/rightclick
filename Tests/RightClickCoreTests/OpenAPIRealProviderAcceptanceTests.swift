import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIRealProviderAcceptanceTests:
    XCTestCase
{
    private func specification() -> Data {
        Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Ephemeral Local Text Provider",
                "version": "1.0.0"
              },
              "security": [],
              "paths": {
                "/transform": {
                  "post": {
                    "operationId": "uppercaseText",
                    "summary": "Uppercase supplied text",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "text/plain": {
                          "schema": {
                            "type": "string"
                          }
                        }
                      }
                    },
                    "responses": {
                      "200": {
                        "description": "Uppercase result",
                        "content": {
                          "text/plain": {
                            "schema": {
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
            """.utf8
        )
    }

    func testRealLocalhostProviderThroughUniversalRuntime()
        throws
    {
        guard
            let rawBase =
                ProcessInfo.processInfo
                    .environment[
                        "NS004_OPENAPI_BASE_URL"
                    ]
        else {
            throw XCTSkip(
                "NS004_OPENAPI_BASE_URL is required for the real-provider gate."
            )
        }

        let baseURL =
            try XCTUnwrap(
                URL(string: rawBase)
            )

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    specification(),
                baseURL:
                    baseURL
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let discovered =
            try engine.capabilities(
                for: "hello"
            )

        XCTAssertEqual(
            discovered.capabilities.count,
            1
        )

        let capability =
            try XCTUnwrap(
                discovered
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability.reflectorID,
            reflector.id
        )

        XCTAssertEqual(
            capability.metadata[
                "substrate"
            ],
            "openapi"
        )

        let providers =
            engine.providers()

        XCTAssertEqual(
            providers.count,
            1
        )

        XCTAssertEqual(
            providers.first?.source,
            "openapi"
        )

        let accepted =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            accepted.status,
            .accepted
        )

        XCTAssertEqual(
            accepted.output,
            "HELLO"
        )

        XCTAssertFalse(
            accepted
                .evidence
                .outcomeVerified
        )

        let verified =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "HELLO"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            verified.status,
            .verified
        )

        XCTAssertEqual(
            verified
                .verification?
                .status,
            .verifiedSuccess
        )

        XCTAssertEqual(
            verified.output,
            "HELLO"
        )

        XCTAssertTrue(
            verified
                .evidence
                .outcomeVerified
        )

        let deliberatelyWrong =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "THIS IS DELIBERATELY WRONG"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            deliberatelyWrong.status,
            .failed
        )

        XCTAssertEqual(
            deliberatelyWrong
                .verification?
                .status,
            .verifiedFailure
        )

        let withoutReflector =
            CapabilityEngine(
                reflectors: []
            )

        XCTAssertTrue(
            try withoutReflector
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .isEmpty
        )

        let unavailable =
            try withoutReflector.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            unavailable.status,
            .unavailable
        )
    }
}
