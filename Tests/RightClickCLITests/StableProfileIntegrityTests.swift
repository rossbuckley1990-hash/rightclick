import Foundation
import XCTest
@testable import RightClickCLI

final class StableProfileIntegrityTests:
    XCTestCase
{
    private func executable(
        _ url: URL
    ) throws {
        try FileManager.default
            .createDirectory(
                at:
                    url
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try "#!/bin/sh\nexit 0\n"
            .write(
                to:
                    url,
                atomically:
                    true,
                encoding:
                    .utf8
            )

        try FileManager.default
            .setAttributes(
                [
                    .posixPermissions:
                        0o755
                ],
                ofItemAtPath:
                    url.path
            )
    }

    private func writeProfile(
        command: String?,
        to url: URL
    ) throws {
        try FileManager.default
            .createDirectory(
                at:
                    url
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        var text = """
        config_version: 1
        mcp:
          commands:
            - channel: main

        """

        if let command {
            text +=
                "      command: \"\(command)\"\n"
        }

        try text.write(
            to:
                url,
            atomically:
                true,
            encoding:
                .utf8
        )
    }

    private func environment(
        _ body: (
            URL,
            RightClickStableEntrypoint.Layout,
            URL,
            URL
        ) throws -> Void
    ) throws {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-profile-integrity-\(UUID().uuidString)"
                )

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        root
                )
        }

        let layout =
            RightClickStableEntrypoint
                .Layout(
                    stableBin:
                        root
                            .appendingPathComponent(
                                "bin/rightclick"
                            )
                            .path,

                    cellarRoot:
                        root
                            .appendingPathComponent(
                                "Cellar/rightclick"
                            )
                            .path
                )

        let stable =
            URL(
                fileURLWithPath:
                    layout.stableBin
            )

        let cellar =
            root.appendingPathComponent(
                "Cellar/rightclick/1.0.0/bin/rightclick"
            )

        let profile =
            root.appendingPathComponent(
                "rightclick.yaml"
            )

        try executable(
            cellar
        )

        try FileManager.default
            .createDirectory(
                at:
                    stable
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try FileManager.default
            .createSymbolicLink(
                at:
                    stable,
                withDestinationURL:
                    cellar
            )

        try body(
            root,
            layout,
            stable,
            profile
        )
    }

    func testStableProfileCommandIsAccepted()
        throws
    {
        try environment {
            _,
            layout,
            stable,
            profile in

            try writeProfile(
                command:
                    "\(stable.path) mcp",
                to:
                    profile
            )

            let result =
                try RightClickBridgeRuntime
                    .attestStableProfile(
                        profileFile:
                            profile,
                        invokedExecutable:
                            stable.path,
                        layouts:
                            [layout]
                    )

            XCTAssertEqual(
                result.executable,
                stable.path
            )

            XCTAssertEqual(
                result.expectedCommand,
                "\(stable.path) mcp"
            )

            XCTAssertEqual(
                result.profileSHA256,
                try RightClickSetupStateStore
                    .sha256File(
                        profile.path
                    )
            )
        }
    }

    func testDevelopmentRedirectIsRejected()
        throws
    {
        try environment {
            root,
            layout,
            stable,
            profile in

            let development =
                root.appendingPathComponent(
                    "tmp/rightclick"
                )

            try executable(
                development
            )

            try writeProfile(
                command:
                    "\(development.path) mcp",
                to:
                    profile
            )

            XCTAssertThrowsError(
                try RightClickBridgeRuntime
                    .attestStableProfile(
                        profileFile:
                            profile,
                        invokedExecutable:
                            stable.path,
                        layouts:
                            [layout]
                    )
            ) { error in
                guard case
                    RightClickBridgeRuntime
                        .StableProfileIntegrityError
                        .commandMismatch(
                            let expected,
                            let found
                        ) = error
                else {
                    return XCTFail(
                        "unexpected error: \(error)"
                    )
                }

                XCTAssertEqual(
                    expected,
                    "\(stable.path) mcp"
                )

                XCTAssertEqual(
                    found,
                    "\(development.path) mcp"
                )
            }
        }
    }

    func testMissingProfileCommandIsRejected()
        throws
    {
        try environment {
            _,
            layout,
            stable,
            profile in

            try writeProfile(
                command:
                    nil,
                to:
                    profile
            )

            XCTAssertThrowsError(
                try RightClickBridgeRuntime
                    .attestStableProfile(
                        profileFile:
                            profile,
                        invokedExecutable:
                            stable.path,
                        layouts:
                            [layout]
                    )
            )
        }
    }

    func testTrustedCommandInSecondDocumentCannotAttestForeignFirstDocument() throws {
        try environment { root, layout, stable, profile in
            let foreign = root.appendingPathComponent("foreign/rightclick")
            try executable(foreign)
            let text = """
            config_version: 1
            mcp:
              commands:
                - channel: main
                  command: '\(foreign.path) mcp'
            ---
            mcp:
              commands:
                - channel: main
                  command: "\(stable.path) mcp"
            """
            try text.write(to: profile, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try RightClickBridgeRuntime.attestStableProfile(
                profileFile: profile, invokedExecutable: stable.path, layouts: [layout]))
        }
    }

    func testLiteralScalarDecoyCannotAttestForeignMCPCommand() throws {
        try environment { root, layout, stable, profile in
            let foreign = root.appendingPathComponent("foreign/rightclick")
            try executable(foreign)
            let text = """
            config_version: 1
            log:
              file: |
                command: "\(stable.path) mcp"
            mcp:
              commands:
                - channel: main
                  command: "\(foreign.path) mcp"
            """
            try text.write(to: profile, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try RightClickBridgeRuntime.attestStableProfile(
                profileFile: profile, invokedExecutable: stable.path, layouts: [layout]))
        }
    }

    func testAdditionalForeignMCPCommandIsRejected() throws {
        try environment { root, layout, stable, profile in
            let foreign = root.appendingPathComponent("foreign/rightclick")
            try executable(foreign)
            try writeProfile(command: "\(stable.path) mcp", to: profile)
            let additional = """
                - channel: other
                  command: "\(foreign.path) mcp"

            """
            let text = try String(contentsOf: profile, encoding: .utf8) + additional
            try text.write(to: profile, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try RightClickBridgeRuntime.attestStableProfile(
                profileFile: profile, invokedExecutable: stable.path, layouts: [layout]))
        }
    }

    func testGeneratedOwnedProfileWithEscapedPathsIsAccepted() throws {
        try environment { root, layout, stable, profile in
            let home = root.appendingPathComponent("home café \"quoted\" \\path")
            let text = try RightClickChatGPTBridge.profileYAML(
                tunnelID: "tunnel_00000000000000000000000000000000",
                rightclickExecutable: stable.path, home: home)
            try text.write(to: profile, atomically: true, encoding: .utf8)
            let result = try RightClickBridgeRuntime.attestStableProfile(
                profileFile: profile, invokedExecutable: stable.path, layouts: [layout])
            XCTAssertEqual(result.expectedCommand, "\(stable.path) mcp")
            XCTAssertEqual(result.profileSHA256, try RightClickSetupStateStore.sha256File(profile.path))
        }
    }

    func testCanonicalProfileCommentsAndCRLFRemainAccepted() throws {
        try environment { _, layout, stable, profile in
            try writeProfile(command: "\(stable.path) mcp", to: profile)
            let text = "# Owned RIGHTCLICK profile\n" +
                (try String(contentsOf: profile, encoding: .utf8))
                    .replacingOccurrences(of: "channel: main", with: "channel: main # main binding")
                    .replacingOccurrences(of: "\n", with: "\r\n")
            try text.write(to: profile, atomically: true, encoding: .utf8)
            let result = try RightClickBridgeRuntime.attestStableProfile(
                profileFile: profile, invokedExecutable: stable.path, layouts: [layout])
            XCTAssertEqual(result.expectedCommand, "\(stable.path) mcp")
        }
    }
}
