import Foundation
import XCTest
@testable import RightClickCLI

final class ChatGPTOnboardingTransactionTests:
    XCTestCase
{
    struct KeyStore:
        RightClickRuntimeKeyStore
    {
        func save(_ value: String) throws {}

        func read() throws -> String {
            "test_runtime_key"
        }

        func delete() throws {}

        func contains() -> Bool {
            true
        }
    }

    final class Runner:
        RightClickCommandRunning
    {
        private var statuses:
            [Int32]

        private var index = 0

        let liveCommands:
            [Int: String]

        let ready: Bool
        let mcpChildState: String

        init(
            _ statuses: [Int32] = [],
            liveCommands:
                [Int: String] = [:],
            ready: Bool = true,
            mcpChildState:
                String = "running"
        ) {
            self.statuses =
                statuses

            self.liveCommands =
                liveCommands

            self.ready =
                ready

            self.mcpChildState =
                mcpChildState
        }

        func run(
            executable: String,
            arguments: [String]
        ) -> RightClickCommandResult {

            // launchd status / attestation identity
            if executable == "/bin/launchctl",
               arguments.first == "print"
            {
                return .init(
                    status: 0,
                    output:
                        """
                        gui/501/ai.rightclick.chatgpt-bridge = {
                            pid = 100
                        }
                        """
                )
            }

            // Real observed topology:
            // bridge 100 -> tunnel 200
            // tunnel 200 -> MCP 300 + Codex 400
            if executable == "/usr/bin/pgrep" {
                guard
                    arguments.count == 2,
                    arguments[0] == "-P"
                else {
                    return .init(
                        status: 1,
                        output: ""
                    )
                }

                if arguments[1] == "100" {
                    return .init(
                        status: 0,
                        output: "200\n"
                    )
                }

                if arguments[1] == "200" {
                    return .init(
                        status: 0,
                        output: "300\n400\n"
                    )
                }

                return .init(
                    status: 1,
                    output: ""
                )
            }

            if executable == "/bin/ps" {
                guard
                    let index =
                        arguments.firstIndex(
                            of: "-p"
                        ),
                    index + 1 <
                        arguments.count,
                    let pid =
                        Int(
                            arguments[
                                index + 1
                            ]
                        )
                else {
                    return .init(
                        status: 1,
                        output: ""
                    )
                }

                if pid == 400 {
                    return .init(
                        status: 0,
                        output:
                            "node /opt/homebrew/bin/codex app-server\n"
                    )
                }

                guard
                    let command =
                        liveCommands[pid]
                else {
                    return .init(
                        status: 1,
                        output: ""
                    )
                }

                return .init(
                    status: 0,
                    output:
                        command + "\n"
                )
            }

            // Native tunnel health model.
            if executable == "/usr/bin/curl" {
                let target =
                    arguments.last
                    ?? ""

                if target.hasSuffix(
                    "/readyz"
                ) {
                    return .init(
                        status:
                            ready ? 0 : 1,
                        output:
                            ready
                            ? "ready\n"
                            : ""
                    )
                }

                if target.hasSuffix(
                    "/health/mcp"
                ) {
                    return .init(
                        status: 0,
                        output:
                            """
                            {"schema_version":1,"status":"unknown","state":"not_observed","details":{"channel":"main","transport":"stdio","child_state":"\(mcpChildState)"}}
                            """
                    )
                }
            }

            // launchctl bootout/bootstrap/enable/kickstart.
            let status: Int32

            if index < statuses.count {
                status =
                    statuses[index]
            } else {
                status = 0
            }

            index += 1

            return .init(
                status: status,
                output:
                    status == 0
                    ? "ok"
                    : "failure"
            )
        }
    }

    private func makeExecutable(
        _ file: URL,
        body: String =
            "#!/bin/sh\nexit 0\n"
    ) throws {
        try FileManager.default
            .createDirectory(
                at:
                    file
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try body.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        try FileManager.default
            .setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath:
                    file.path
            )
    }

    private func makeEnvironment(
        _ body: (
            URL,
            String,
            String,
            String,
            String
        ) throws -> Void
    ) throws {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-onboard-003-\(UUID().uuidString)"
                )

        defer {
            try? FileManager.default
                .removeItem(at: home)
        }

        let old =
            home.appendingPathComponent(
                "old/rightclick"
            )

        let new =
            home.appendingPathComponent(
                "new/rightclick"
            )

        let tunnel =
            home.appendingPathComponent(
                "bin/tunnel-client"
            )

        try makeExecutable(old)
        try makeExecutable(new)

        try makeExecutable(
            tunnel,
            body:
                "#!/bin/sh\necho 0.0.15\n"
        )

        let tunnelID =
            "tunnel_"
            + String(
                repeating: "b",
                count: 32
            )

        let state =
            try RightClickSetupStateStore
                .make(
                    executable:
                        old.path,
                    chatGPTTunnelID:
                        tunnelID,
                    tunnelClientPath:
                        tunnel.path,
                    tunnelClientVersion:
                        "0.0.15"
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

        _ =
            try RightClickChatGPTBridge
                .writeProfile(
                    tunnelID:
                        tunnelID,
                    rightclickExecutable:
                        old.path,
                    home:
                        home
                )

        _ =
            try RightClickChatGPTBridge
                .writeLaunchAgent(
                    rightclickExecutable:
                        old.path,
                    home:
                        home
                )

        try "http://127.0.0.1:9999\n"
            .write(
                to:
                    RightClickChatGPTBridge
                        .healthURLFile(
                            home: home
                        ),
                atomically: true,
                encoding: .utf8
            )

        try body(
            home,
            old.path,
            new.path,
            tunnel.path,
            tunnelID
        )
    }

    func testSuccessfulMigrationUpdatesAllOwnedFiles()
        throws
    {
        try makeEnvironment {
            home,
            _,
            new,
            tunnel,
            _ in

            let result =
                try RightClickChatGPTOnboarding
                    .applyMigration(
                        home: home,
                        executable:
                            new,
                        persistentExecutable:
                            new,
                        keyStore:
                            KeyStore(),
                        runner:
                            Runner(
                                liveCommands: [
                                    100:
                                        "\(new) bridge run",

                                    200:
                                        "\(tunnel) run --profile-file \(RightClickChatGPTBridge.profileFile(home: home).path)",

                                    300:
                                        "\(new) mcp",
                                ]
                            ),
                        uid:
                            501
                    )

            XCTAssertEqual(
                result["status"],
                "APPLIED"
            )

            XCTAssertEqual(
                try RightClickChatGPTOnboarding
                    .profileCommand(
                        RightClickChatGPTBridge
                            .profileFile(
                                home: home
                            )
                    ),
                "\(new) mcp"
            )

            XCTAssertEqual(
                try RightClickChatGPTOnboarding
                    .launchAgentArguments(
                        RightClickChatGPTBridge
                            .launchAgentFile(
                                home: home
                            )
                    ),
                [
                    new,
                    "bridge",
                    "run",
                ]
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
                state.executablePath,
                new
            )
        }
    }

    func testActivationFailureRestoresExactOwnedFiles()
        throws
    {
        try makeEnvironment {
            home,
            _,
            new,
            _,
            _ in

            let profile =
                RightClickChatGPTBridge
                    .profileFile(
                        home: home
                    )

            let plist =
                RightClickChatGPTBridge
                    .launchAgentFile(
                        home: home
                    )

            let state =
                RightClickSetupStateStore
                    .defaultFile(
                        home: home
                    )

            let beforeProfile =
                try Data(
                    contentsOf:
                        profile
                )

            let beforePlist =
                try Data(
                    contentsOf:
                        plist
                )

            let beforeState =
                try Data(
                    contentsOf:
                        state
                )

            // before-plan status succeeds;
            // first activation bootstrap fails;
            // rollback activation then succeeds.
            let runner =
                Runner([
                    // new activation: bootout succeeds,
                    // bootstrap fails
                    0,
                    1,

                    // rollback activation succeeds
                    0,
                    0,
                    0,
                    0,
                ])

            let result =
                try RightClickChatGPTOnboarding
                    .applyMigration(
                        home: home,
                        executable:
                            new,
                        persistentExecutable:
                            new,
                        keyStore:
                            KeyStore(),
                        runner:
                            runner,
                        uid:
                            501
                    )

            XCTAssertEqual(
                result["status"],
                "FAILED_ROLLED_BACK"
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        profile
                ),
                beforeProfile
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        plist
                ),
                beforePlist
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        state
                ),
                beforeState
            )
        }
    }
}


extension ChatGPTOnboardingTransactionTests {
    func testAttestationFailureRestoresExactOwnedFiles()
        throws
    {
        try makeEnvironment {
            home,
            _,
            new,
            tunnel,
            _ in

            let profile =
                RightClickChatGPTBridge
                    .profileFile(
                        home: home
                    )

            let plist =
                RightClickChatGPTBridge
                    .launchAgentFile(
                        home: home
                    )

            let state =
                RightClickSetupStateStore
                    .defaultFile(
                        home: home
                    )

            let beforeProfile =
                try Data(
                    contentsOf:
                        profile
                )

            let beforePlist =
                try Data(
                    contentsOf:
                        plist
                )

            let beforeState =
                try Data(
                    contentsOf:
                        state
                )

            let runner =
                Runner(
                    liveCommands: [
                        100:
                            "\(new) bridge run",

                        200:
                            "\(tunnel) run --profile-file \(profile.path)",

                        // Deliberately stale/wrong live MCP child.
                        300:
                            "/tmp/wrong-rightclick mcp",
                    ]
                )

            let result =
                try RightClickChatGPTOnboarding
                    .applyMigration(
                        home: home,
                        executable:
                            new,
                        persistentExecutable:
                            new,
                        keyStore:
                            KeyStore(),
                        runner:
                            runner,
                        uid:
                            501
                    )

            XCTAssertEqual(
                result["status"],
                "FAILED_ROLLED_BACK"
            )

            XCTAssertEqual(
                result[
                    "liveRuntimeAttested"
                ],
                "false"
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        profile
                ),
                beforeProfile
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        plist
                ),
                beforePlist
            )

            XCTAssertEqual(
                try Data(
                    contentsOf:
                        state
                ),
                beforeState
            )
        }
    }
}
