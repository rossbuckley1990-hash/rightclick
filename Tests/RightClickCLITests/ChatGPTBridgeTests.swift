import Foundation
import XCTest
@testable import RightClickCLI

final class ChatGPTBridgeTests: XCTestCase {
    private let tunnelID =
        "tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func testProfileMatchesOpenAIStdioTunnelShape()
        throws
    {
        let home = URL(
            fileURLWithPath: "/Users/example"
        )

        let profile =
            try RightClickChatGPTBridge.profileYAML(
                tunnelID: tunnelID,
                rightclickExecutable:
                    "/opt/homebrew/bin/rightclick",
                home: home
            )

        XCTAssertTrue(
            profile.contains(
                #"tunnel_id: "tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa""#
            )
        )

        XCTAssertTrue(
            profile.contains(
                #"api_key: "env:CONTROL_PLANE_API_KEY""#
            )
        )

        XCTAssertTrue(
            profile.contains(
                #"command: "/opt/homebrew/bin/rightclick mcp""#
            )
        )

        XCTAssertTrue(
            profile.contains(
                #"listen_addr: "127.0.0.1:0""#
            )
        )

        XCTAssertTrue(
            profile.contains(
                "/Users/example/Library/Application Support/RIGHTCLICK/tunnel-health.url"
            )
        )

        XCTAssertFalse(
            profile.contains("sk-")
        )
    }

    func testLaunchAgentUsesStableRightClickEntryPoint()
        throws
    {
        let home = URL(
            fileURLWithPath: "/Users/example"
        )

        let data =
            try RightClickChatGPTBridge
                .launchAgentPlist(
                    rightclickExecutable:
                        "/opt/homebrew/bin/rightclick",
                    home: home
                )

        let object =
            try XCTUnwrap(
                try PropertyListSerialization
                    .propertyList(
                        from: data,
                        options: [],
                        format: nil
                    )
                    as? [String: Any]
            )

        XCTAssertEqual(
            object["Label"] as? String,
            "ai.rightclick.chatgpt-bridge"
        )

        XCTAssertEqual(
            object["ProgramArguments"]
                as? [String],
            [
                "/opt/homebrew/bin/rightclick",
                "bridge",
                "run",
            ]
        )

        XCTAssertEqual(
            object["RunAtLoad"] as? Bool,
            true
        )

        XCTAssertEqual(
            object["KeepAlive"] as? Bool,
            true
        )
    }

    func testTunnelClientMinimumVersionGate() {
        XCTAssertFalse(
            RightClickChatGPTBridge
                .tunnelClientVersionIsSupported(
                    "0.0.14+old"
                )
        )

        XCTAssertTrue(
            RightClickChatGPTBridge
                .tunnelClientVersionIsSupported(
                    "0.0.15+a390c168"
                )
        )

        XCTAssertTrue(
            RightClickChatGPTBridge
                .tunnelClientVersionIsSupported(
                    "v0.1.0"
                )
        )
    }

    func testBridgeFilesAreDeterministicAndPrivate()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-bridge-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        let profile =
            try RightClickChatGPTBridge
                .writeProfile(
                    tunnelID: tunnelID,
                    rightclickExecutable:
                        "/opt/homebrew/bin/rightclick",
                    home: home
                )

        let first =
            try Data(contentsOf: profile)

        _ = try RightClickChatGPTBridge
            .writeProfile(
                tunnelID: tunnelID,
                rightclickExecutable:
                    "/opt/homebrew/bin/rightclick",
                home: home
            )

        let second =
            try Data(contentsOf: profile)

        XCTAssertEqual(first, second)

        let attrs =
            try FileManager.default.attributesOfItem(
                atPath: profile.path
            )

        let permissions =
            try XCTUnwrap(
                attrs[.posixPermissions]
                    as? NSNumber
            )

        XCTAssertEqual(
            permissions.intValue,
            0o600
        )

        let launchAgent =
            try RightClickChatGPTBridge
                .writeLaunchAgent(
                    rightclickExecutable:
                        "/opt/homebrew/bin/rightclick",
                    home: home
                )

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath: launchAgent.path
                )
        )
    }

    func testInvalidTunnelIDsAreRejected() {
        for value in [
            "",
            "tunnel_short",
            "TUNNEL_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "tunnel_Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "tunnel_gggggggggggggggggggggggggggggggg",
            "other_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ] {
            XCTAssertThrowsError(
                try RightClickChatGPTBridge
                    .validateTunnelID(value),
                value
            )
        }
    }
}

extension ChatGPTBridgeTests {
    func testBridgeWritingCreatesRuntimeDirectories()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-runtime-dirs-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        _ = try RightClickChatGPTBridge
            .writeLaunchAgent(
                rightclickExecutable:
                    "/opt/homebrew/bin/rightclick",
                home:
                    home
            )

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath:
                        RightClickChatGPTBridge
                            .runtimeLogDirectory(
                                home: home
                            )
                            .path
                )
        )

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath:
                        RightClickChatGPTBridge
                            .healthURLFile(
                                home: home
                            )
                            .deletingLastPathComponent()
                            .path
                )
        )
    }
}
