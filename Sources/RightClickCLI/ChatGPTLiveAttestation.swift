import Darwin
import Foundation

extension RightClickChatGPTOnboarding {
    struct LiveAttestation {
        let success: Bool
        let values: [String: String]
    }

    static func integerLines(
        _ text: String
    ) -> [Int] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap {
                Int(
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            }
    }

    static func launchdPID(
        _ text: String
    ) -> Int? {
        guard
            let regex =
                try? NSRegularExpression(
                    pattern:
                        #"(?m)^\s*pid = ([0-9]+)\s*$"#
                )
        else {
            return nil
        }

        let range =
            NSRange(
                text.startIndex..<text.endIndex,
                in: text
            )

        guard
            let match =
                regex.firstMatch(
                    in: text,
                    range: range
                ),
            let valueRange =
                Range(
                    match.range(at: 1),
                    in: text
                )
        else {
            return nil
        }

        return Int(text[valueRange])
    }

    static func childPIDs(
        parent: Int,
        runner:
            any RightClickCommandRunning
    ) -> [Int] {
        let result =
            runner.run(
                executable:
                    "/usr/bin/pgrep",
                arguments: [
                    "-P",
                    String(parent),
                ]
            )

        guard result.status == 0 else {
            return []
        }

        return integerLines(
            result.output
        )
    }

    static func processCommand(
        pid: Int,
        runner:
            any RightClickCommandRunning
    ) -> String? {
        let result =
            runner.run(
                executable:
                    "/bin/ps",
                arguments: [
                    "-ww",
                    "-p",
                    String(pid),
                    "-o",
                    "command=",
                ]
            )

        guard result.status == 0 else {
            return nil
        }

        let value =
            result.output
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        return value.isEmpty
            ? nil
            : value
    }

    static func isRightClickMCP(
        _ command: String
    ) -> Bool {
        let parts =
            command.split(
                whereSeparator:
                    \.isWhitespace
            )

        guard parts.count >= 2 else {
            return false
        }

        let executable =
            URL(
                fileURLWithPath:
                    String(parts[0])
            )
            .lastPathComponent

        return executable == "rightclick"
            && parts[1] == "mcp"
    }

    static func processAttestation(
        home: URL,
        executable: String,
        tunnelClient: String,
        uid: uid_t,
        runner:
            any RightClickCommandRunning
    ) -> LiveAttestation {
        let service =
            "gui/\(uid)/\(RightClickChatGPTBridge.launchAgentLabel)"

        let launchctl =
            runner.run(
                executable:
                    "/bin/launchctl",
                arguments: [
                    "print",
                    service,
                ]
            )

        guard
            launchctl.status == 0,
            let bridgePID =
                launchdPID(
                    launchctl.output
                )
        else {
            return .init(
                success: false,
                values: [
                    "attestationError":
                        "Bridge PID unavailable."
                ]
            )
        }

        let tunnelChildren =
            childPIDs(
                parent:
                    bridgePID,
                runner:
                    runner
            )

        guard tunnelChildren.count == 1 else {
            return .init(
                success: false,
                values: [
                    "bridgePID":
                        String(bridgePID),

                    "attestationError":
                        "Expected exactly one tunnel-client child."
                ]
            )
        }

        let tunnelPID =
            tunnelChildren[0]

        guard
            let bridgeCommand =
                processCommand(
                    pid:
                        bridgePID,
                    runner:
                        runner
                ),
            let tunnelCommand =
                processCommand(
                    pid:
                        tunnelPID,
                    runner:
                        runner
                )
        else {
            return .init(
                success: false,
                values: [
                    "attestationError":
                        "Bridge or tunnel command could not be inspected."
                ]
            )
        }

        let profile =
            RightClickChatGPTBridge
                .profileFile(
                    home: home
                )

        let expectedBridge =
            "\(executable) bridge run"

        let expectedTunnel =
            "\(tunnelClient) run --profile-file \(profile.path)"

        let expectedMCP =
            "\(executable) mcp"

        let childIDs =
            childPIDs(
                parent:
                    tunnelPID,
                runner:
                    runner
            )

        var childCommands:
            [(Int, String)] = []

        for pid in childIDs {
            guard
                let command =
                    processCommand(
                        pid:
                            pid,
                        runner:
                            runner
                    )
            else {
                return .init(
                    success: false,
                    values: [
                        "attestationError":
                            "A tunnel child could not be inspected."
                    ]
                )
            }

            childCommands.append(
                (
                    pid,
                    command
                )
            )
        }

        let expected =
            childCommands.filter {
                $0.1 == expectedMCP
            }

        let conflictingRightClick =
            childCommands.filter {
                $0.1 != expectedMCP
                    && isRightClickMCP(
                        $0.1
                    )
            }

        guard
            expected.count == 1,
            conflictingRightClick.isEmpty
        else {
            return .init(
                success: false,
                values: [
                    "bridgePID":
                        String(bridgePID),

                    "tunnelPID":
                        String(tunnelPID),

                    "expectedMCPCount":
                        String(
                            expected.count
                        ),

                    "conflictingRightClickMCPCount":
                        String(
                            conflictingRightClick.count
                        ),

                    "attestationError":
                        "Expected exactly one desired RIGHTCLICK MCP child and no conflicting RIGHTCLICK MCP child."
                ]
            )
        }

        let mcpPID =
            expected[0].0

        let bridgeAligned =
            bridgeCommand
            == expectedBridge

        let tunnelAligned =
            tunnelCommand
            == expectedTunnel

        guard
            bridgeAligned,
            tunnelAligned
        else {
            return .init(
                success: false,
                values: [
                    "bridgeCommandAligned":
                        bridgeAligned
                        ? "true"
                        : "false",

                    "tunnelCommandAligned":
                        tunnelAligned
                        ? "true"
                        : "false",

                    "attestationError":
                        "Bridge or tunnel command does not match the desired runtime."
                ]
            )
        }

        return .init(
            success: true,
            values: [
                "bridgePID":
                    String(bridgePID),

                "tunnelPID":
                    String(tunnelPID),

                "mcpPID":
                    String(mcpPID),

                "auxiliaryChildCount":
                    String(
                        childCommands.count - 1
                    ),

                "bridgeCommandAligned":
                    "true",

                "tunnelCommandAligned":
                    "true",

                "mcpCommandAligned":
                    "true",
            ]
        )
    }

    static func healthAttestation(
        home: URL,
        runner:
            any RightClickCommandRunning
    ) -> LiveAttestation {
        let file =
            RightClickChatGPTBridge
                .healthURLFile(
                    home: home
                )

        guard
            let raw =
                try? String(
                    contentsOf:
                        file,
                    encoding:
                        .utf8
                )
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                ),
            let base =
                URL(string: raw),
            base.scheme == "http",
            [
                "127.0.0.1",
                "localhost",
                "::1",
            ].contains(
                base.host ?? ""
            )
        else {
            return .init(
                success: false,
                values: [
                    "healthError":
                        "Valid loopback health URL unavailable."
                ]
            )
        }

        let readyURL =
            base
                .appendingPathComponent(
                    "readyz"
                )
                .absoluteString

        let ready =
            runner.run(
                executable:
                    "/usr/bin/curl",
                arguments: [
                    "--silent",
                    "--show-error",
                    "--fail",
                    "--max-time",
                    "2",
                    readyURL,
                ]
            )

        guard
            ready.status == 0,
            ready.output
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == "ready"
        else {
            return .init(
                success: false,
                values: [
                    "tunnelReady":
                        "false"
                ]
            )
        }

        let mcpURL =
            base
                .appendingPathComponent(
                    "health/mcp"
                )
                .absoluteString

        let mcp =
            runner.run(
                executable:
                    "/usr/bin/curl",
                arguments: [
                    "--silent",
                    "--show-error",
                    "--fail",
                    "--max-time",
                    "2",
                    mcpURL,
                ]
            )

        guard
            mcp.status == 0,
            let data =
                mcp.output
                    .data(
                        using:
                            .utf8
                    ),
            let root =
                try? JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any],
            let details =
                root["details"]
                    as? [String: Any]
        else {
            return .init(
                success: false,
                values: [
                    "healthError":
                        "MCP health snapshot unavailable."
                ]
            )
        }

        let channel =
            details["channel"]
                as? String

        let transport =
            details["transport"]
                as? String

        let childState =
            details["child_state"]
                as? String

        let healthState =
            root["state"]
                as? String
                ?? "unknown"

        let healthStatus =
            root["status"]
                as? String
                ?? "unknown"

        let success =
            channel == "main"
            && transport == "stdio"
            && childState == "running"

        return .init(
            success: success,
            values: [
                "tunnelReady":
                    "true",

                "mcpHealthStatus":
                    healthStatus,

                "mcpHealthState":
                    healthState,

                "mcpChildState":
                    childState
                    ?? "unknown",

                "mcpDiscoveryRequiredForSetup":
                    "false",
            ]
        )
    }

    static func waitForLiveAttestation(
        home: URL =
            FileManager.default
                .homeDirectoryForCurrentUser,

        executable: String,

        tunnelClient: String,

        uid: uid_t = getuid(),

        runner:
            any RightClickCommandRunning =
            SystemRightClickCommandRunner(),

        attempts: Int = 20,

        interval:
            TimeInterval = 0.25
    ) -> LiveAttestation {
        var lastValues:
            [String: String] = [:]

        for attempt in 1...max(
            attempts,
            1
        ) {
            let process =
                processAttestation(
                    home: home,
                    executable:
                        executable,
                    tunnelClient:
                        tunnelClient,
                    uid: uid,
                    runner:
                        runner
                )

            let health =
                healthAttestation(
                    home: home,
                    runner:
                        runner
                )

            var values =
                process.values

            for (
                key,
                value
            ) in health.values {
                values[key] =
                    value
            }

            values[
                "attestationAttempt"
            ] =
                String(attempt)

            if process.success
                && health.success
            {
                values[
                    "liveRuntimeAttested"
                ] = "true"

                return .init(
                    success: true,
                    values:
                        values
                )
            }

            lastValues =
                values

            if attempt < attempts {
                Thread.sleep(
                    forTimeInterval:
                        interval
                )
            }
        }

        lastValues[
            "liveRuntimeAttested"
        ] = "false"

        return .init(
            success: false,
            values:
                lastValues
        )
    }
}
