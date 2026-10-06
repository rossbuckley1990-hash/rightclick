import Foundation
import XCTest
@testable import RightClickCLI

final class ChatGPTOnboardingTests:
    XCTestCase
{
    struct TestKeyStore:
        RightClickRuntimeKeyStore
    {
        var present: Bool

        func save(_ value: String) throws {}

        func read() throws -> String {
            guard present else {
                throw RightClickRuntimeKeyStoreError
                    .notFound
            }

            return "test_runtime_key"
        }

        func delete() throws {}

        func contains() -> Bool {
            present
        }
    }

    struct TestRunner:
        RightClickCommandRunning
    {
        var running: Bool

        func run(
            executable: String,
            arguments: [String]
        ) -> RightClickCommandResult {
            RightClickCommandResult(
                status:
                    running ? 0 : 1,

                output:
                    running
                    ? "running"
                    : "not running"
            )
        }
    }

    private func isolated(
        _ body: (
            URL,
            String,
            String,
            String
        ) throws -> Void
    ) throws {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-chatgpt-onboarding-\(UUID().uuidString)"
                )

        try FileManager.default
            .createDirectory(
                at: home,
                withIntermediateDirectories:
                    true
            )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        let executable =
            home.appendingPathComponent(
                "bin/rightclick"
            )

        let tunnelClient =
            home.appendingPathComponent(
                "bin/tunnel-client"
            )

        try FileManager.default
            .createDirectory(
                at:
                    executable
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try "#!/bin/sh\nexit 0\n"
            .write(
                to: executable,
                atomically: true,
                encoding: .utf8
            )

        try "#!/bin/sh\necho 0.0.15\n"
            .write(
                to: tunnelClient,
                atomically: true,
                encoding: .utf8
            )

        try FileManager.default
            .setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath:
                    executable.path
            )

        try FileManager.default
            .setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath:
                    tunnelClient.path
            )

        let tunnelID =
            "tunnel_"
            + String(
                repeating: "a",
                count: 32
            )

        try body(
            home,
            executable.path,
            tunnelClient.path,
            tunnelID
        )
    }

    private func writeAlignedFiles(
        home: URL,
        executable: String,
        tunnelClient: String,
        tunnelID: String
    ) throws {
        let version = "0.0.15"

        let state =
            try RightClickSetupStateStore
                .make(
                    executable:
                        executable,
                    chatGPTTunnelID:
                        tunnelID,
                    tunnelClientPath:
                        tunnelClient,
                    tunnelClientVersion:
                        version
                )

        try RightClickSetupStateStore
            .write(
                state,
                to:
                    RightClickSetupStateStore
                        .defaultFile(
                            home: home
                        )
            )

        let profile =
            RightClickChatGPTBridge
                .profileFile(home: home)

        try FileManager.default
            .createDirectory(
                at:
                    profile
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try RightClickChatGPTBridge
            .profileYAML(
                tunnelID:
                    tunnelID,
                rightclickExecutable:
                    executable,
                home: home
            )
            .write(
                to: profile,
                atomically: true,
                encoding: .utf8
            )

        let plist =
            RightClickChatGPTBridge
                .launchAgentFile(
                    home: home
                )

        try FileManager.default
            .createDirectory(
                at:
                    plist
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        let plistData =
            try RightClickChatGPTBridge
                .launchAgentPlist(
                    rightclickExecutable:
                        executable,
                    home: home
                )

        try plistData.write(
            to: plist,
            options: .atomic
        )
    }

    func testOptionsAcceptPreview() throws {
        let options =
            try RightClickChatGPTOnboarding
                .Options([
                    "chatgpt",
                    "--dry-run",
                    "--json",
                ])

        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.json)
    }

    func testUnknownOptionFails() {
        XCTAssertThrowsError(
            try RightClickChatGPTOnboarding
                .Options([
                    "chatgpt",
                    "--write-live",
                ])
        )
    }

    func testProfileCommandParsesGeneratedProfile()
        throws
    {
        try isolated {
            home,
            executable,
            _,
            tunnelID in

            let profile =
                RightClickChatGPTBridge
                    .profileFile(
                        home: home
                    )

            try FileManager.default
                .createDirectory(
                    at:
                        profile
                            .deletingLastPathComponent(),
                    withIntermediateDirectories:
                        true
                )

            try RightClickChatGPTBridge
                .profileYAML(
                    tunnelID:
                        tunnelID,
                    rightclickExecutable:
                        executable,
                    home: home
                )
                .write(
                    to: profile,
                    atomically: true,
                    encoding: .utf8
                )

            XCTAssertEqual(
                try RightClickChatGPTOnboarding
                    .profileCommand(
                        profile
                    ),
                "\(executable) mcp"
            )
        }
    }

    func testLaunchAgentArgumentsParse()
        throws
    {
        try isolated {
            home,
            executable,
            _,
            _ in

            let plist =
                RightClickChatGPTBridge
                    .launchAgentFile(
                        home: home
                    )

            try FileManager.default
                .createDirectory(
                    at:
                        plist
                            .deletingLastPathComponent(),
                    withIntermediateDirectories:
                        true
                )

            try RightClickChatGPTBridge
                .launchAgentPlist(
                    rightclickExecutable:
                        executable,
                    home: home
                )
                .write(
                    to: plist,
                    options: .atomic
                )

            XCTAssertEqual(
                try RightClickChatGPTOnboarding
                    .launchAgentArguments(
                        plist
                    ),
                [
                    executable,
                    "bridge",
                    "run",
                ]
            )
        }
    }

    func testFullyAlignedPlanReportsAligned()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let result =
                try RightClickChatGPTOnboarding
                    .plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: true
                            ),
                        uid: 501
                    )

            XCTAssertEqual(
                result["status"],
                "ALIGNED"
            )

            XCTAssertEqual(
                result["allAligned"],
                "true"
            )
        }
    }

    func testProfileDriftIsDetected()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let profile =
                RightClickChatGPTBridge
                    .profileFile(
                        home: home
                    )

            var text =
                try String(
                    contentsOf:
                        profile,
                    encoding: .utf8
                )

            text =
                text.replacingOccurrences(
                    of:
                        "\(executable) mcp",
                    with:
                        "/tmp/stale-rightclick mcp"
                )

            try text.write(
                to: profile,
                atomically: true,
                encoding: .utf8
            )

            let result =
                try RightClickChatGPTOnboarding
                    .plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: true
                            ),
                        uid: 501
                    )

            XCTAssertEqual(
                result["status"],
                "DRIFT_DETECTED"
            )

            XCTAssertEqual(
                result["profileAligned"],
                "false"
            )
        }
    }

    func testLaunchAgentDriftIsDetected()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let plist =
                RightClickChatGPTBridge
                    .launchAgentFile(
                        home: home
                    )

            let stale =
                try RightClickChatGPTBridge
                    .launchAgentPlist(
                        rightclickExecutable:
                            "/tmp/stale-rightclick",
                        home: home
                    )

            try stale.write(
                to: plist,
                options: .atomic
            )

            let result =
                try RightClickChatGPTOnboarding
                    .plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: true
                            ),
                        uid: 501
                    )

            XCTAssertEqual(
                result[
                    "launchAgentAligned"
                ],
                "false"
            )

            XCTAssertEqual(
                result["status"],
                "DRIFT_DETECTED"
            )
        }
    }

    func testStoppedBridgeIsNotAligned()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let result =
                try RightClickChatGPTOnboarding
                    .plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: false
                            ),
                        uid: 501
                    )

            XCTAssertEqual(
                result["bridgeRunning"],
                "false"
            )

            XCTAssertEqual(
                result["status"],
                "DRIFT_DETECTED"
            )
        }
    }

    func testMissingKeyIsReported()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let result =
                try RightClickChatGPTOnboarding
                    .plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        keyStore:
                            TestKeyStore(
                                present: false
                            ),
                        runner:
                            TestRunner(
                                running: true
                            ),
                        uid: 501
                    )

            XCTAssertEqual(
                result["status"],
                "KEY_REQUIRED"
            )
        }
    }

    func testMissingStateRequiresPairing()
        throws
    {
        try isolated {
            home,
            executable,
            _,
            _ in

            let result =
                try RightClickChatGPTOnboarding
                    .plan(
                        home: home,
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: true
                            ),
                        uid: 501
                    )

            XCTAssertEqual(
                result["status"],
                "PAIRING_REQUIRED"
            )
        }
    }

    func testNonDryRunDoesNotModifyAnything()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let profile =
                RightClickChatGPTBridge
                    .profileFile(
                        home: home
                    )

            let before =
                try Data(contentsOf: profile)

            let code =
                RightClickChatGPTOnboarding
                    .run(
                        args: [
                            "chatgpt",
                            "--json",
                        ],
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        home:
                            home,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: true
                            )
                    )

            XCTAssertEqual(code, 0)

            XCTAssertEqual(
                try Data(contentsOf: profile),
                before
            )
        }
    }
}


extension ChatGPTOnboardingTests {
    func testDriftWithoutYesRequiresConsent()
        throws
    {
        try isolated {
            home,
            executable,
            tunnelClient,
            tunnelID in

            try writeAlignedFiles(
                home: home,
                executable:
                    executable,
                tunnelClient:
                    tunnelClient,
                tunnelID:
                    tunnelID
            )

            let profile =
                RightClickChatGPTBridge
                    .profileFile(
                        home: home
                    )

            var profileText =
                try String(
                    contentsOf:
                        profile,
                    encoding: .utf8
                )

            profileText =
                profileText
                    .replacingOccurrences(
                        of:
                            "\(executable) mcp",
                        with:
                            "/tmp/stale-rightclick mcp"
                    )

            try profileText.write(
                to: profile,
                atomically: true,
                encoding: .utf8
            )

            let before =
                try Data(
                    contentsOf:
                        profile
                )

            let code =
                RightClickChatGPTOnboarding
                    .run(
                        args: [
                            "chatgpt",
                            "--json",
                        ],
                        executable:
                            executable,
                        persistentExecutable:
                            executable,
                        home:
                            home,
                        keyStore:
                            TestKeyStore(
                                present: true
                            ),
                        runner:
                            TestRunner(
                                running: true
                            )
                    )

            XCTAssertEqual(
                code,
                3
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        profile
                ),
                before
            )
        }
    }
}
