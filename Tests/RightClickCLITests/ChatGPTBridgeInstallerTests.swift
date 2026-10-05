import Foundation
import XCTest
@testable import RightClickCLI

final class ChatGPTBridgeInstallerTests:
    XCTestCase
{
    private let tunnelID =
        "tunnel_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    final class FakeKeyStore:
        RightClickRuntimeKeyStore
    {
        var value: String?

        init(_ value: String? = nil) {
            self.value = value
        }

        func save(_ value: String) throws {
            try RightClickBridgeRuntime
                .validateRuntimeAPIKey(
                    value
                )

            self.value = value
        }

        func read() throws -> String {
            guard let value else {
                throw RightClickRuntimeKeyStoreError
                    .notFound
            }

            return value
        }

        func delete() throws {
            value = nil
        }

        func contains() -> Bool {
            value != nil
        }
    }

    final class FakeRunner:
        RightClickCommandRunning
    {
        struct Invocation:
            Equatable
        {
            let executable: String
            let arguments: [String]
        }

        var invocations:
            [Invocation] = []

        var bootstrapStatus: Int32 = 0

        func run(
            executable: String,
            arguments: [String]
        ) -> RightClickCommandResult {
            invocations.append(
                .init(
                    executable:
                        executable,
                    arguments:
                        arguments
                )
            )

            let status: Int32

            if arguments.first
                == "bootstrap"
            {
                status =
                    bootstrapStatus
            } else {
                status = 0
            }

            return .init(
                status: status,
                output:
                    status == 0
                    ? ""
                    : "synthetic failure"
            )
        }
    }

    private func makeTunnelClient(
        root: URL,
        version: String
    ) throws -> URL {
        let file =
            root.appendingPathComponent(
                "tunnel-client"
            )

        let script =
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              echo "\(version)"
              exit 0
            fi
            exit 0
            """

        try Data(script.utf8)
            .write(to: file)

        try FileManager.default
            .setAttributes(
                [
                    .posixPermissions:
                        0o755,
                ],
                ofItemAtPath:
                    file.path
            )

        return file
    }

    func testPrepareWritesProfileLaunchAgentAndBridgeState()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-install-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        try FileManager.default
            .createDirectory(
                at: home,
                withIntermediateDirectories:
                    true
            )

        let tunnelClient =
            try makeTunnelClient(
                root: home,
                version:
                    "0.0.15+test"
            )

        let rightclick =
            home.appendingPathComponent(
                "rightclick"
            )

        try Data("binary".utf8)
            .write(to: rightclick)

        let keyStore =
            FakeKeyStore(
                "runtime-key_123"
            )

        let result =
            RightClickChatGPTBridgeInstaller
                .prepare(
                    tunnelID:
                        tunnelID,
                    rightclickExecutable:
                        rightclick.path,
                    home:
                        home,
                    environment: [
                        RightClickBridgeRuntime
                            .tunnelClientOverride:
                            tunnelClient.path,
                    ],
                    keyStore:
                        keyStore
                )

        XCTAssertTrue(
            result.success,
            result.message
        )

        let profile =
            try XCTUnwrap(
                result.profileFile
            )

        let plist =
            try XCTUnwrap(
                result.launchAgentFile
            )

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath: profile.path
                )
        )

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath: plist.path
                )
        )

        let state =
            try RightClickSetupStateStore
                .read(
                    from:
                        RightClickSetupStateStore
                            .defaultFile(
                                home: home
                            )
                )

        XCTAssertEqual(
            state.chatGPTTunnelID,
            tunnelID
        )

        XCTAssertEqual(
            state.tunnelClientPath,
            tunnelClient.path
        )

        XCTAssertEqual(
            state.tunnelClientVersion,
            "0.0.15+test"
        )
    }

    func testPrepareRequiresStoredRuntimeKey()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-install-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        try FileManager.default
            .createDirectory(
                at: home,
                withIntermediateDirectories:
                    true
            )

        let tunnelClient =
            try makeTunnelClient(
                root: home,
                version: "0.0.15"
            )

        let rightclick =
            home.appendingPathComponent(
                "rightclick"
            )

        try Data("binary".utf8)
            .write(to: rightclick)

        let result =
            RightClickChatGPTBridgeInstaller
                .prepare(
                    tunnelID:
                        tunnelID,
                    rightclickExecutable:
                        rightclick.path,
                    home:
                        home,
                    environment: [
                        RightClickBridgeRuntime
                            .tunnelClientOverride:
                            tunnelClient.path,
                    ],
                    keyStore:
                        FakeKeyStore()
                )

        XCTAssertFalse(result.success)

        XCTAssertTrue(
            result.message.contains(
                "No OpenAI runtime API key"
            )
        )
    }

    func testPrepareRejectsOldTunnelClient()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-install-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        try FileManager.default
            .createDirectory(
                at: home,
                withIntermediateDirectories:
                    true
            )

        let tunnelClient =
            try makeTunnelClient(
                root: home,
                version: "0.0.14"
            )

        let rightclick =
            home.appendingPathComponent(
                "rightclick"
            )

        try Data("binary".utf8)
            .write(to: rightclick)

        let result =
            RightClickChatGPTBridgeInstaller
                .prepare(
                    tunnelID:
                        tunnelID,
                    rightclickExecutable:
                        rightclick.path,
                    home:
                        home,
                    environment: [
                        RightClickBridgeRuntime
                            .tunnelClientOverride:
                            tunnelClient.path,
                    ],
                    keyStore:
                        FakeKeyStore(
                            "runtime-key_123"
                        )
                )

        XCTAssertFalse(result.success)

        XCTAssertTrue(
            result.message.contains(
                "too old"
            )
        )
    }

    func testActivationUsesExpectedLaunchctlSequence()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-launch-\(UUID().uuidString)",
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

        let runner = FakeRunner()

        let result =
            RightClickChatGPTBridgeInstaller
                .activate(
                    home:
                        home,
                    uid:
                        501,
                    runner:
                        runner
                )

        XCTAssertTrue(
            result.success,
            result.message
        )

        XCTAssertEqual(
            runner.invocations
                .map(\.arguments),
            [
                [
                    "bootout",
                    "gui/501",
                    RightClickChatGPTBridge
                        .launchAgentFile(
                            home: home
                        ).path,
                ],
                [
                    "bootstrap",
                    "gui/501",
                    RightClickChatGPTBridge
                        .launchAgentFile(
                            home: home
                        ).path,
                ],
                [
                    "enable",
                    "gui/501/ai.rightclick.chatgpt-bridge",
                ],
                [
                    "kickstart",
                    "-k",
                    "gui/501/ai.rightclick.chatgpt-bridge",
                ],
            ]
        )
    }

    func testActivationFailsClosedWhenBootstrapFails()
        throws
    {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-launch-\(UUID().uuidString)",
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

        let runner = FakeRunner()
        runner.bootstrapStatus = 5

        let result =
            RightClickChatGPTBridgeInstaller
                .activate(
                    home:
                        home,
                    uid:
                        501,
                    runner:
                        runner
                )

        XCTAssertFalse(result.success)

        XCTAssertEqual(
            runner.invocations.count,
            2
        )
    }
}
