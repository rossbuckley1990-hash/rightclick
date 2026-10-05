import Foundation
import XCTest
@testable import RightClickCLI

final class SetupTests: XCTestCase {
    private func isolated(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-setup-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("nested/mcp.json"))
    }

    func testAbsentConfigurationIsCreated() throws {
        try isolated { file in
            let result = RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: file)
            XCTAssertTrue(result.success)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
            let entry = try XCTUnwrap(servers["rightclick"] as? [String: Any])
            XCTAssertEqual(entry["command"] as? String, "/example/rightclick")
            XCTAssertEqual(entry["args"] as? [String], ["mcp"])
        }
    }

    func testInvalidServerContainersRemainByteIdentical() throws {
        for value in ["[]", "[1,2]", "\"keep\"", "null", "42", "true"] {
            try isolated { file in
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = Data("{\"mcpServers\":\(value),\"untouched\":\"π\"}".utf8)
                try original.write(to: file)
                XCTAssertFalse(RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: file).success, value)
                XCTAssertEqual(try Data(contentsOf: file), original, value)
            }
        }
    }

    func testInvalidRootAndMalformedJSONRemainByteIdentical() throws {
        for value in ["[]", "\"keep\"", "null", "42", "{", "{\"x\":"] {
            try isolated { file in
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = Data(value.utf8)
                try original.write(to: file)
                XCTAssertFalse(RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: file).success, value)
                XCTAssertEqual(try Data(contentsOf: file), original, value)
            }
        }
    }

    func testUnrelatedValuesAndOnlyOwnedEntryArePreserved() throws {
        try isolated { file in
            let original = Data(#"{"rootExtra":{"nested":["π",true,null]},"mcpServers":{"other":{"command":"unchanged","args":["a\\b","\"quoted\""]},"unrecognised":42,"rightclick":{"command":"replace me","oldField":true}}}"#.utf8)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: file)
            XCTAssertTrue(RightClickSetup.writeCursorConfig(executable: "/example/with spaces/rightclick", at: file).success)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary)
            XCTAssertEqual(after["rootExtra"] as? NSDictionary, before["rootExtra"] as? NSDictionary)
            let servers = try XCTUnwrap(after["mcpServers"] as? NSDictionary)
            let prior = try XCTUnwrap(before["mcpServers"] as? NSDictionary)
            XCTAssertEqual(servers["other"] as? NSDictionary, prior["other"] as? NSDictionary)
            XCTAssertEqual(servers["unrecognised"] as? NSNumber, prior["unrecognised"] as? NSNumber)
            let entry = try XCTUnwrap(servers["rightclick"] as? NSDictionary)
            XCTAssertEqual(entry, ["command": "/example/with spaces/rightclick", "args": ["mcp"]] as NSDictionary)
            let first = try Data(contentsOf: file)
            XCTAssertTrue(RightClickSetup.writeCursorConfig(executable: "/example/with spaces/rightclick", at: file).success)
            XCTAssertEqual(try Data(contentsOf: file), first)
        }
    }

    func testWriteFailureIsReported() {
        let result = RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: URL(fileURLWithPath: "/dev/null/no-directory/mcp.json"))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("not written"))
    }

    func testEveryFailedStagePreventsSuccessfulExit() {
        for discovery in ["FAIL", "UNKNOWN", "", "not a status"] {
            XCTAssertFalse(RightClickSetup.succeeded(discovery: discovery, cursorWritten: true, selfTestPassed: true))
        }
        XCTAssertFalse(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: false, selfTestPassed: true))
        XCTAssertFalse(
            RightClickSetup.succeeded(
                discovery: "PASS",
                cursorWritten: true,
                openAIWritten: true,
                stateWritten: false,
                selfTestPassed: true
            )
        )
        XCTAssertFalse(
            RightClickSetup.succeeded(
                discovery: "PASS",
                cursorWritten: true,
                openAIWritten: true,
                stateWritten: true,
                chatGPTBridgePrepared: false,
                selfTestPassed: true
            )
        )
        XCTAssertFalse(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: true, openAIWritten: false, selfTestPassed: true))
        XCTAssertFalse(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: true, selfTestPassed: false))
        XCTAssertTrue(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: true, openAIWritten: true, selfTestPassed: true))
    }

    func testOpenAIPluginUsesCurrentPersonalMarketplaceLayout() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rightclick-openai-plugin-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: home)
        }

        let result = RightClickOpenAIPlugin.install(
            executable: "/example/with spaces/rightclick",
            home: home
        )

        XCTAssertTrue(result.success, result.message)

        let pluginRoot = home.appendingPathComponent("plugins/rightclick")

        let manifestFile = pluginRoot
            .appendingPathComponent(".codex-plugin/plugin.json")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestFile.path)
        )

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestFile)
            ) as? [String: Any]
        )

        XCTAssertEqual(
            manifest["mcpServers"] as? String,
            "./.mcp.json"
        )

        let mcpFile = pluginRoot.appendingPathComponent(".mcp.json")

        let mcp = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: mcpFile)
            ) as? [String: Any]
        )

        let servers = try XCTUnwrap(
            mcp["mcpServers"] as? [String: Any]
        )

        let rightclick = try XCTUnwrap(
            servers["rightclick"] as? [String: Any]
        )

        XCTAssertEqual(rightclick["type"] as? String, "stdio")
        XCTAssertEqual(rightclick["command"] as? String, "zsh")
        XCTAssertEqual(
            rightclick["args"] as? [String],
            ["./bin/rightclick-mcp"]
        )
        XCTAssertEqual(rightclick["cwd"] as? String, ".")

        let launcher = try String(
            contentsOf: pluginRoot
                .appendingPathComponent("bin/rightclick-mcp"),
            encoding: .utf8
        )

        XCTAssertTrue(
            launcher.contains(
                "exec '/example/with spaces/rightclick' mcp"
            )
        )

        let marketplaceFile = home
            .appendingPathComponent(".agents/plugins/marketplace.json")

        let marketplace = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: marketplaceFile)
            ) as? [String: Any]
        )

        let plugins = try XCTUnwrap(
            marketplace["plugins"] as? [[String: Any]]
        )

        let entry = try XCTUnwrap(
            plugins.first {
                $0["name"] as? String == "rightclick"
            }
        )

        let source = try XCTUnwrap(
            entry["source"] as? [String: Any]
        )

        XCTAssertEqual(source["source"] as? String, "local")
        XCTAssertEqual(
            source["path"] as? String,
            "./plugins/rightclick"
        )
    }

    func testOpenAIPluginPreservesMarketplaceAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rightclick-openai-idempotent-\(UUID().uuidString)")

        let marketplaceFile = home
            .appendingPathComponent(".agents/plugins/marketplace.json")

        try FileManager.default.createDirectory(
            at: marketplaceFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let original: [String: Any] = [
            "name": "personal",
            "interface": [
                "displayName": "My Personal Plugins",
            ],
            "extra": [
                "keep": true,
            ],
            "plugins": [
                [
                    "name": "other-plugin",
                    "source": [
                        "source": "local",
                        "path": "./plugins/other-plugin",
                    ],
                    "policy": [
                        "installation": "AVAILABLE",
                        "authentication": "ON_INSTALL",
                    ],
                    "category": "Productivity",
                ],
            ],
        ]

        var originalData = try JSONSerialization.data(
            withJSONObject: original,
            options: [.prettyPrinted, .sortedKeys]
        )
        originalData.append(0x0A)
        try originalData.write(to: marketplaceFile)

        defer {
            try? FileManager.default.removeItem(at: home)
        }

        let first = RightClickOpenAIPlugin.install(
            executable: "/example/rightclick",
            home: home
        )

        XCTAssertTrue(first.success, first.message)

        let afterFirst = try Data(contentsOf: marketplaceFile)

        let second = RightClickOpenAIPlugin.install(
            executable: "/example/rightclick",
            home: home
        )

        XCTAssertTrue(second.success, second.message)

        let afterSecond = try Data(contentsOf: marketplaceFile)

        XCTAssertEqual(afterFirst, afterSecond)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: afterSecond
            ) as? [String: Any]
        )

        let extra = try XCTUnwrap(
            root["extra"] as? [String: Any]
        )

        XCTAssertEqual(extra["keep"] as? Bool, true)

        let plugins = try XCTUnwrap(
            root["plugins"] as? [[String: Any]]
        )

        XCTAssertEqual(
            plugins.filter {
                $0["name"] as? String == "rightclick"
            }.count,
            1
        )

        XCTAssertEqual(
            plugins.filter {
                $0["name"] as? String == "other-plugin"
            }.count,
            1
        )
    }

}

extension SetupTests {
    func testExplicitChatGPTTunnelIDIsSelected() {
        let tunnelID =
            "tunnel_0123456789abcdef0123456789abcdef"

        XCTAssertEqual(
            RightClickSetup
                .requestedChatGPTTunnelID(
                    args: [
                        "--chatgpt-tunnel-id",
                        tunnelID,
                    ],
                    existingState: nil
                ),
            tunnelID
        )
    }

    func testStoredChatGPTTunnelIDIsReused() {
        let stored =
            "tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        let state =
            RightClickSetupState(
                setupSchemaVersion: 1,
                rightclickVersion: "test",
                executablePath:
                    "/example/rightclick",
                executableSHA256:
                    "binary",
                mcpSchemaVersion: 1,
                mcpToolSchemaSHA256:
                    "contract",
                chatGPTTunnelID:
                    stored,
                tunnelClientPath:
                    "/example/tunnel-client",
                tunnelClientVersion:
                    "0.0.15",
                bridgeConfigurationVersion:
                    1
            )

        XCTAssertEqual(
            RightClickSetup
                .requestedChatGPTTunnelID(
                    args: [],
                    existingState:
                        state
                ),
            stored
        )
    }

    func testExplicitTunnelIDOverridesStoredIdentity() {
        let stored =
            "tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        let explicit =
            "tunnel_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

        let state =
            RightClickSetupState(
                setupSchemaVersion: 1,
                rightclickVersion: "test",
                executablePath:
                    "/example/rightclick",
                executableSHA256:
                    "binary",
                mcpSchemaVersion: 1,
                mcpToolSchemaSHA256:
                    "contract",
                chatGPTTunnelID:
                    stored,
                tunnelClientPath:
                    "/example/tunnel-client",
                tunnelClientVersion:
                    "0.0.15",
                bridgeConfigurationVersion:
                    1
            )

        XCTAssertEqual(
            RightClickSetup
                .requestedChatGPTTunnelID(
                    args: [
                        "--chatgpt-tunnel-id",
                        explicit,
                    ],
                    existingState:
                        state
                ),
            explicit
        )
    }

    func testLongVersionFlagIsAccepted() {
        XCTAssertEqual(CLI().run(["--version"]), 0)
    }


    func testExplicitServeTokenOverridesStoredToken() {
        XCTAssertEqual(
            RightClickServe.selectedToken(
                args: ["--token", "explicit-token"],
                fallback: { "stored-token" }
            ),
            "explicit-token"
        )

        XCTAssertEqual(
            RightClickServe.selectedToken(
                args: [],
                fallback: { "stored-token" }
            ),
            "stored-token"
        )
    }

}
