import Foundation
import XCTest
@testable import RightClickCLI

final class ChatGPTLiveAttestationTests:
    XCTestCase
{
    struct Runner:
        RightClickCommandRunning
    {
        let bridgeCommand: String
        let tunnelCommand: String
        let childCommands: [Int: String]

        var ready = true
        var mcpChildState = "running"

        func run(
            executable: String,
            arguments: [String]
        ) -> RightClickCommandResult {
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
                    let rows =
                        childCommands
                            .keys
                            .sorted()
                            .map(String.init)
                            .joined(
                                separator: "\n"
                            )

                    return .init(
                        status:
                            rows.isEmpty
                            ? 1
                            : 0,
                        output:
                            rows.isEmpty
                            ? ""
                            : rows + "\n"
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
                    index + 1
                        < arguments.count,
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

                let command: String?

                switch pid {
                case 100:
                    command =
                        bridgeCommand

                case 200:
                    command =
                        tunnelCommand

                default:
                    command =
                        childCommands[
                            pid
                        ]
                }

                guard let command else {
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

            if executable == "/usr/bin/curl" {
                let target =
                    arguments.last
                    ?? ""

                if target.hasSuffix(
                    "/readyz"
                ) {
                    return .init(
                        status:
                            ready
                            ? 0
                            : 1,
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

            return .init(
                status: 1,
                output: ""
            )
        }
    }

    private func healthHome(
        _ body: (URL) throws -> Void
    ) throws {
        let home =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-health-\(UUID().uuidString)"
                )

        defer {
            try? FileManager.default
                .removeItem(
                    at: home
                )
        }

        let file =
            RightClickChatGPTBridge
                .healthURLFile(
                    home: home
                )

        try FileManager.default
            .createDirectory(
                at:
                    file
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try "http://127.0.0.1:9999\n"
            .write(
                to: file,
                atomically: true,
                encoding: .utf8
            )

        try body(home)
    }

    func testExpectedMCPWithAuxiliaryCodexChildPasses()
        throws
    {
        let home =
            URL(
                fileURLWithPath:
                    "/Users/test"
            )

        let executable =
            "/opt/rightclick"

        let tunnel =
            "/opt/tunnel-client"

        let profile =
            RightClickChatGPTBridge
                .profileFile(
                    home: home
                )

        let result =
            RightClickChatGPTOnboarding
                .processAttestation(
                    home: home,
                    executable:
                        executable,
                    tunnelClient:
                        tunnel,
                    uid: 501,
                    runner:
                        Runner(
                            bridgeCommand:
                                "\(executable) bridge run",

                            tunnelCommand:
                                "\(tunnel) run --profile-file \(profile.path)",

                            childCommands: [
                                300:
                                    "\(executable) mcp",

                                400:
                                    "node /opt/homebrew/bin/codex app-server",
                            ]
                        )
                )

        XCTAssertTrue(
            result.success
        )

        XCTAssertEqual(
            result.values[
                "mcpCommandAligned"
            ],
            "true"
        )

        XCTAssertEqual(
            result.values[
                "auxiliaryChildCount"
            ],
            "1"
        )

        XCTAssertEqual(
            result.values[
                "mcpPID"
            ],
            "300"
        )
    }

    func testConflictingRightClickMCPChildFailsClosed()
        throws
    {
        let home =
            URL(
                fileURLWithPath:
                    "/Users/test"
            )

        let executable =
            "/opt/rightclick"

        let tunnel =
            "/opt/tunnel-client"

        let profile =
            RightClickChatGPTBridge
                .profileFile(
                    home: home
                )

        let result =
            RightClickChatGPTOnboarding
                .processAttestation(
                    home: home,
                    executable:
                        executable,
                    tunnelClient:
                        tunnel,
                    uid: 501,
                    runner:
                        Runner(
                            bridgeCommand:
                                "\(executable) bridge run",

                            tunnelCommand:
                                "\(tunnel) run --profile-file \(profile.path)",

                            childCommands: [
                                300:
                                    "\(executable) mcp",

                                301:
                                    "/tmp/rightclick mcp",

                                400:
                                    "node /opt/homebrew/bin/codex app-server",
                            ]
                        )
                )

        XCTAssertFalse(
            result.success
        )

        XCTAssertEqual(
            result.values[
                "conflictingRightClickMCPCount"
            ],
            "1"
        )
    }

    func testMissingExpectedRightClickMCPFailsClosed()
        throws
    {
        let home =
            URL(
                fileURLWithPath:
                    "/Users/test"
            )

        let executable =
            "/opt/rightclick"

        let tunnel =
            "/opt/tunnel-client"

        let profile =
            RightClickChatGPTBridge
                .profileFile(
                    home: home
                )

        let result =
            RightClickChatGPTOnboarding
                .processAttestation(
                    home: home,
                    executable:
                        executable,
                    tunnelClient:
                        tunnel,
                    uid: 501,
                    runner:
                        Runner(
                            bridgeCommand:
                                "\(executable) bridge run",

                            tunnelCommand:
                                "\(tunnel) run --profile-file \(profile.path)",

                            childCommands: [
                                400:
                                    "node /opt/homebrew/bin/codex app-server",
                            ]
                        )
                )

        XCTAssertFalse(
            result.success
        )

        XCTAssertEqual(
            result.values[
                "expectedMCPCount"
            ],
            "0"
        )
    }

    func testNotObservedMCPHealthWithRunningChildPasses()
        throws
    {
        try healthHome {
            home in

            let result =
                RightClickChatGPTOnboarding
                    .healthAttestation(
                        home: home,
                        runner:
                            Runner(
                                bridgeCommand:
                                    "",
                                tunnelCommand:
                                    "",
                                childCommands:
                                    [:],
                                ready:
                                    true,
                                mcpChildState:
                                    "running"
                            )
                    )

            XCTAssertTrue(
                result.success
            )

            XCTAssertEqual(
                result.values[
                    "tunnelReady"
                ],
                "true"
            )

            XCTAssertEqual(
                result.values[
                    "mcpHealthState"
                ],
                "not_observed"
            )

            XCTAssertEqual(
                result.values[
                    "mcpChildState"
                ],
                "running"
            )
        }
    }

    func testNonRunningMCPHealthFails()
        throws
    {
        try healthHome {
            home in

            let result =
                RightClickChatGPTOnboarding
                    .healthAttestation(
                        home: home,
                        runner:
                            Runner(
                                bridgeCommand:
                                    "",
                                tunnelCommand:
                                    "",
                                childCommands:
                                    [:],
                                ready:
                                    true,
                                mcpChildState:
                                    "stopped"
                            )
                    )

            XCTAssertFalse(
                result.success
            )
        }
    }

    func testNotReadyTunnelFailsHealthAttestation()
        throws
    {
        try healthHome {
            home in

            let result =
                RightClickChatGPTOnboarding
                    .healthAttestation(
                        home: home,
                        runner:
                            Runner(
                                bridgeCommand:
                                    "",
                                tunnelCommand:
                                    "",
                                childCommands:
                                    [:],
                                ready:
                                    false,
                                mcpChildState:
                                    "running"
                            )
                    )

            XCTAssertFalse(
                result.success
            )

            XCTAssertEqual(
                result.values[
                    "tunnelReady"
                ],
                "false"
            )
        }
    }
}
