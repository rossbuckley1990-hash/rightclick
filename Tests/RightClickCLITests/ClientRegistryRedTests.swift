import Foundation
import XCTest
@testable import RightClickCLI

final class ClientRegistryRedTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(
            fileURLWithPath: #filePath
        )
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    }

    private func source(
        _ relativePath: String
    ) throws -> String {
        try String(
            contentsOf:
                repositoryRoot
                .appendingPathComponent(
                    relativePath
                ),
            encoding: .utf8
        )
    }

    func testRegistrySourceOwnsExistingAdaptersInStableOrder() throws {
        let path =
            repositoryRoot
            .appendingPathComponent(
                "Sources/RightClickCLI/ClientRegistry.swift"
            )

        guard FileManager.default
            .fileExists(
                atPath: path.path
            )
        else {
            XCTFail(
                "ADOPT-002 requires a dedicated "
                + "RightClickClientRegistry source."
            )
            return
        }

        let text =
            try String(
                contentsOf: path,
                encoding: .utf8
            )

        XCTAssertTrue(
            text.contains(
                "RightClickClientRegistry"
            )
        )

        let cursor =
            try XCTUnwrap(
                text.range(
                    of:
                        "RightClickCursorClientAdapter()"
                )
            )

        let claude =
            try XCTUnwrap(
                text.range(
                    of:
                        "RightClickClaudeClientAdapter()"
                )
            )

        let codex =
            try XCTUnwrap(
                text.range(
                    of:
                        "RightClickCodexClientAdapter()"
                )
            )

        XCTAssertLessThan(
            cursor.lowerBound,
            claude.lowerBound
        )

        XCTAssertLessThan(
            claude.lowerBound,
            codex.lowerBound
        )

        XCTAssertTrue(
            text.contains(
                "supportedIDs"
            )
        )

        XCTAssertTrue(
            text.contains(
                "detected"
            )
        )

        XCTAssertTrue(
            text.contains(
                "adapter"
            )
        )
    }

    func testLocalOnboardingDelegatesClientCatalogAndRoutingToRegistry() throws {
        let text =
            try source(
                "Sources/RightClickCLI/LocalOnboarding.swift"
            )

        XCTAssertTrue(
            text.contains(
                "RightClickClientRegistry"
            ),
            "Local onboarding must consume the registry."
        )

        let forbidden = [
            #"["cursor", "claude", "codex"]"#,
            #"case "cursor":"#,
            #"case "claude":"#,
            #"case "codex":"#,
            "let cursor = RightClickCursorClientAdapter()",
            "let claude = RightClickClaudeClientAdapter()",
            "let codex = RightClickCodexClientAdapter()",
        ]

        for fragment in forbidden {
            XCTAssertFalse(
                text.contains(fragment),
                """
                LocalOnboarding still owns named-client routing:
                \(fragment)
                """
            )
        }

        XCTAssertFalse(
            text.contains(
                "RIGHTCLICK currently supports "
                + "--client cursor, --client claude"
            ),
            "Supported-client validation must come from the registry."
        )
    }

    func testAdaptersOwnClientSpecificPresentationInsteadOfLocalRouter() throws {
        let engine =
            try source(
                "Sources/RightClickCLI/OnboardingEngine.swift"
            )

        XCTAssertTrue(
            engine.contains(
                "setupNotice"
            ),
            """
            Client-specific setup messaging should belong
            to the adapter protocol.
            """
        )

        XCTAssertTrue(
            engine.contains(
                "nextMessage"
            ),
            """
            Client-specific next-step messaging should belong
            to adapters rather than LocalOnboarding switches.
            """
        )

        let local =
            try source(
                "Sources/RightClickCLI/LocalOnboarding.swift"
            )

        XCTAssertFalse(
            local.contains(
                #"case "claude":"#
            )
        )

        XCTAssertFalse(
            local.contains(
                #"case "codex":"#
            )
        )
    }

    func testAllCurrentlySupportedExplicitClientIDsRemainAccepted() throws {
        for id in [
            "cursor",
            "claude",
            "codex",
        ] {
            let options =
                try RightClickLocalOnboarding
                    .Options([
                        "--client",
                        id,
                        "--dry-run",
                    ])

            XCTAssertEqual(
                options.client,
                id
            )
        }

        XCTAssertTrue(
            RightClickLocalOnboarding
                .usage
                .contains(
                    "rightclick setup --client cursor"
                )
        )

        XCTAssertTrue(
            RightClickLocalOnboarding
                .usage
                .contains(
                    "rightclick setup --client claude"
                )
        )

        XCTAssertTrue(
            RightClickLocalOnboarding
                .usage
                .contains(
                    "rightclick setup --client codex"
                )
        )
    }

    func testUnknownClientStillFailsClosed() {
        XCTAssertThrowsError(
            try RightClickLocalOnboarding
                .Options([
                    "--client",
                    "definitely-not-a-client",
                ])
        )
    }
}
