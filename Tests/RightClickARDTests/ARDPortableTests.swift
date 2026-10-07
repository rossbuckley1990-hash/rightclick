import Foundation
import XCTest
@testable import RightClickARD

final class ARDPortableTests: XCTestCase {
    func testG13DecodesHfDiscoverSearchResponseShape() throws {
        let payload = Data(
            """
            {
              "results": [
                {
                  "identifier": "urn:air:huggingface.co:skill:research",
                  "displayName": "Research Skill",
                  "type": "application/ai-skill",
                  "url": "https://huggingface.co/skills/research/SKILL.md",
                  "description": "Research a topic.",
                  "tags": ["research"],
                  "capabilities": ["research"],
                  "metadata": {"sourceType": "skill"},
                  "score": 96,
                  "source": "huggingface:skills"
                },
                {
                  "identifier": "urn:air:huggingface.co:mcp:echo",
                  "displayName": "Echo MCP",
                  "type": "application/mcp-server-card+json",
                  "data": {
                    "name": "echo",
                    "remotes": [
                      {
                        "transport": "streamable-http",
                        "url": "https://echo.example/mcp"
                      }
                    ]
                  },
                  "score": 88,
                  "source": "huggingface:spaces"
                }
              ],
              "referrals": [
                {
                  "identifier": "urn:air:huggingface.co:registry:spaces",
                  "displayName": "Spaces Registry",
                  "type": "application/ai-registry+json",
                  "url": "https://huggingface-hf-discover.hf.space/registries/huggingface/spaces"
                }
              ],
              "pageToken": null
            }
            """.utf8
        )

        let decoded =
            try ARDAcquisition
                .decodeSearchResponse(
                    payload
                )

        XCTAssertEqual(
            decoded.results.count,
            2
        )

        XCTAssertEqual(
            decoded.referralCount,
            1
        )

        XCTAssertEqual(
            decoded.results[0].type,
            "application/ai-skill"
        )

        XCTAssertNotNil(
            decoded.results[0].url
        )

        XCTAssertNotNil(
            decoded.results[1].inlineData
        )

        XCTAssertTrue(
            ARDAcquisition
                .openAPICandidates(
                    in:
                        decoded
                )
                .isEmpty
        )
    }

    func testG13ExtractsSupportedOpenAPICandidate() throws {
        let payload = Data(
            """
            {
              "results": [
                {
                  "identifier": "urn:air:example.com:api:records",
                  "displayName": "Records API",
                  "type": "application/openapi+json",
                  "data": {
                    "openapi": "3.0.3",
                    "info": {
                      "title": "Records API",
                      "version": "1.0.0"
                    },
                    "servers": [
                      {
                        "url": "https://api.example.com"
                      }
                    ],
                    "paths": {}
                  },
                  "score": 100,
                  "source": "fixture"
                }
              ],
              "referrals": []
            }
            """.utf8
        )

        let response =
            try ARDAcquisition
                .decodeSearchResponse(
                    payload
                )

        let candidates =
            ARDAcquisition
                .openAPICandidates(
                    in:
                        response
                )

        XCTAssertEqual(
            candidates.count,
            1
        )

        let candidate =
            try XCTUnwrap(
                candidates.first
            )

        XCTAssertEqual(
            candidate.identifier,
            "urn:air:example.com:api:records"
        )

        let specification =
            try XCTUnwrap(
                candidate.inlineSpecification
            )

        XCTAssertEqual(
            ARDAcquisition
                .literalOpenAPIBaseURL(
                    from:
                        specification
                ),
            "https://api.example.com"
        )
    }

    func testAmbiguousOpenAPIServerBindingAbstains() throws {
        let specification = Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Ambiguous",
                "version": "1.0.0"
              },
              "servers": [
                {"url": "https://one.example"},
                {"url": "https://two.example"}
              ],
              "paths": {}
            }
            """.utf8
        )

        XCTAssertNil(
            ARDAcquisition
                .literalOpenAPIBaseURL(
                    from:
                        specification
                )
        )
    }

    func testSearchResponseRequiresExactlyOneValueOrReference() throws {
        let payload = Data(
            """
            {
              "results": [
                {
                  "identifier": "urn:air:example.com:api:invalid",
                  "displayName": "Invalid",
                  "type": "application/openapi+json",
                  "url": "https://example.com/openapi.json",
                  "data": {"openapi": "3.0.3"},
                  "score": 90,
                  "source": "fixture"
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try ARDAcquisition
                .decodeSearchResponse(
                    payload
                )
        )
    }

    func testSearchRequestMatchesARDEnvelope() throws {
        let data =
            try ARDAcquisition
                .searchRequest(
                    query:
                        "create a durable record",
                    pageSize:
                        7,
                    federation:
                        "auto"
                )

        let object =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any]
            )

        XCTAssertEqual(
            object["pageSize"] as? Int,
            7
        )

        XCTAssertEqual(
            object["federation"] as? String,
            "auto"
        )

        let query =
            try XCTUnwrap(
                object["query"]
                    as? [String: Any]
            )

        XCTAssertEqual(
            query["text"] as? String,
            "create a durable record"
        )
    }
}
