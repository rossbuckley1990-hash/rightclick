import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local-only onboarding. Deliberately independent of bridge, Keychain and setup-state code.
/// Configuration is not evidence of an MCP connection or a verified external outcome.
enum RightClickLocalOnboarding {
    typealias SetupError = RightClickOnboardingError
    typealias Plan = RightClickJSONConfigBackend.Plan
    typealias Applied = RightClickJSONConfigBackend.Applied

    struct Options {
        var client: String?
        var yes = false
        var dryRun = false
        var json = false
        var disconnect = false
        var help = false

        init(_ args: [String]) throws {
            var index = 0
            var seen = Set<String>()
            while index < args.count {
                let arg = args[index]
                guard seen.insert(arg).inserted else { throw SetupError("Repeated option: \(arg)") }
                switch arg {
                case "--client":
                    index += 1
                    guard index < args.count,
                          ["cursor", "claude", "codex"].contains(args[index])
                    else {
                        throw SetupError(
                            "RIGHTCLICK currently supports "
                            + "--client cursor, --client claude, "
                            + "or --client codex."
                        )
                    }
                    client = args[index]
                case "--yes": yes = true
                case "--dry-run": dryRun = true
                case "--json": json = true
                case "--disconnect": disconnect = true
                case "--help", "-h": help = true
                default: throw SetupError("Unknown local setup option: \(arg)")
                }
                index += 1
            }
            if yes && client == nil {
                throw SetupError(
                    "Use --client cursor, --client claude, "
                    + "or --client codex with --yes to "
                    + "explicitly select the client."
                )
            }
        }
    }

    static let usage = """
    rightclick setup
    rightclick setup --client cursor [--yes] [--dry-run] [--json]
    rightclick setup --client cursor --disconnect [--yes] [--dry-run] [--json]
    rightclick setup --client claude [--yes] [--dry-run] [--json]
    rightclick setup --client claude --disconnect [--yes] [--dry-run] [--json]
    rightclick setup --client codex [--yes] [--dry-run] [--json]
    rightclick setup --client codex --disconnect [--yes] [--dry-run] [--json]

    Cursor uses its local JSON MCP configuration.
    Claude Code uses its native user-scope MCP registration CLI.
    Codex uses its native global MCP registration CLI.
    Dry-run may inspect current state but never mutates configuration.
    Existing different rightclick registrations are never silently replaced.
    """

    static func bridgeArguments(_ args: [String]) throws -> Bool {
        guard args.contains("--chatgpt-tunnel-id") else { return false }
        var index = 0
        var tunnelID: String?
        var jsonSeen = false
        while index < args.count {
            switch args[index] {
            case "--json":
                guard !jsonSeen else { throw SetupError("Repeated --json option.") }
                jsonSeen = true
            case "--chatgpt-tunnel-id":
                guard tunnelID == nil, index + 1 < args.count else {
                    throw SetupError("Provide exactly one --chatgpt-tunnel-id value.")
                }
                index += 1
                tunnelID = args[index]
            default:
                throw SetupError("Do not mix local setup options with bridge setup.")
            }
            index += 1
        }
        guard let tunnelID, tunnelID.utf8.count == 39,
              tunnelID.range(of: #"^tunnel_[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            throw SetupError("Expected tunnel_ followed by 32 lowercase hexadecimal characters.")
        }
        return true
    }

    static func cursorDetected(home: URL, applications: URL = URL(fileURLWithPath: "/Applications")) -> Bool {
        RightClickCursorClientAdapter().detected(home: home, applications: applications)
    }

    static func desiredEntry(executable: String) throws -> [String: Any] {
        try RightClickCursorClientAdapter().connectionRecipe(executable: executable).jsonMCPEntry
    }

    // Compatibility shim for existing onboarding transactions that already
    // rely on the same fail-closed path inspection semantics.
    static func inspectPath(_ file: URL) throws {
        try RightClickJSONConfigBackend.inspectPath(file)
    }

    static func plan(file: URL, executable: String, disconnect: Bool = false) throws -> Plan {
        let desired = try desiredEntry(executable: executable)
        var legacy = desired
        legacy.removeValue(forKey: "type")
        return try RightClickJSONConfigBackend.plan(
            file: file,
            containerKey: "mcpServers",
            entryKey: "rightclick",
            desiredEntry: desired,
            acceptedExistingEntries: [legacy],
            disconnect: disconnect
        )
    }

    static func apply(_ plan: Plan) throws -> Applied {
        try RightClickJSONConfigBackend.apply(plan)
    }

    static func run(
        args: [String], executable: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        interactive: Bool = isatty(STDIN_FILENO) != 0,
        readAnswer: () -> String? = { readLine() },
        output: (String) -> Void = { print($0) },
        probe: () throws -> String
    ) -> Int {
        let json = args.contains("--json")
        func emit(_ payload: [String: String]) {
            if json, let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { output(text) }
            else { output(payload.keys.sorted().map { "\($0): \(payload[$0]!)" }.joined(separator: "\n")) }
        }

        do {
            let options = try Options(args)
            if options.help {
                emit(["help": usage])
                return 0
            }

            let cursor = RightClickCursorClientAdapter()
            let claude = RightClickClaudeClientAdapter()
            let codex = RightClickCodexClientAdapter()

            let adapter: any RightClickClientAdapter

            switch options.client {
            case "cursor":
                adapter = cursor

            case "claude":
                adapter = claude

            case "codex":
                adapter = codex

            case nil:
                if cursor.detected(
                    home: home,
                    applications: URL(
                        fileURLWithPath: "/Applications"
                    )
                ) {
                    adapter = cursor
                } else if claude.detected(
                    home: home,
                    applications: URL(
                        fileURLWithPath: "/Applications"
                    )
                ) {
                    adapter = claude
                } else if codex.detected(
                    home: home,
                    applications: URL(
                        fileURLWithPath: "/Applications"
                    )
                ) {
                    adapter = codex
                } else {
                    throw SetupError(
                        "No supported local client was detected. "
                        + "Use --client cursor, --client claude, "
                        + "or --client codex to explicitly select one."
                    )
                }

            default:
                throw SetupError(
                    "Unsupported local client."
                )
            }

            guard options.disconnect
                    || FileManager.default
                        .isExecutableFile(
                            atPath: executable
                        )
            else {
                throw SetupError(
                    "The RIGHTCLICK executable is missing "
                    + "or not executable: \(executable)"
                )
            }

            let onboarding =
                try RightClickOnboardingEngine.plan(
                    adapter: adapter,
                    home: home,
                    executable: executable,
                    disconnect: options.disconnect
                )

            let file =
                onboarding.configurationFile

            let recipe =
                onboarding.recipe

            let notice: String

            switch onboarding.clientID {
            case "claude":
                notice =
                    "Claude Code will use its native "
                    + "user-scope MCP registration. "
                    + "RIGHTCLICK does not write Claude "
                    + "JSON directly."

            case "codex":
                notice =
                    "Codex will use its native global "
                    + "MCP registration. RIGHTCLICK does "
                    + "not write Codex config.toml directly."

            default:
                notice =
                    "Cursor can launch this executable and "
                    + "request its discovered capabilities. "
                    + "Existing action confirmations still "
                    + "apply. Close Cursor while changing "
                    + "its configuration."
            }

            var payload: [String: String] = [
                "client": onboarding.clientID,
                "configuration": file.path,
                "command": recipe.command,
                "arguments": recipe.arguments.joined(separator: " "),
                "transport": recipe.transport.rawValue,
                "operation": onboarding.mutation.operation,
                "configurationChanged": "false",
                "registrationBackend": onboarding.mutation.backendID,
                "registrationScope": onboarding.mutation.scope ?? "client-config",
                "mcpConnection": "NOT_VERIFIED",
                "outcomeVerification": "NOT_RUN",
                "localProbe": "NOT_RUN",
                "bridge": "NOT_TOUCHED",
                "keychain": "NOT_TOUCHED",
                "notice": notice,
            ]

            if options.dryRun {
                payload["status"] = "DRY_RUN"
                emit(payload)
                return 0
            }

            if onboarding.mutation.changed && !options.yes {
                if !interactive || options.json {
                    payload["status"] = "CONSENT_REQUIRED"
                    payload["next"] =
                        "Review this plan, then run setup --client "
                        + onboarding.clientID
                        + " --yes"
                        + (options.disconnect ? " --disconnect" : "")
                    emit(payload)
                    return 3
                }
                output("""
                RIGHTCLICK local setup

                Client: \(onboarding.clientDisplayName)
                Configuration: \(file.path)
                Executable: \(recipe.command)
                Arguments: \(recipe.arguments.joined(separator: " "))
                Change: \(onboarding.mutation.operation)

                \(payload["notice"]!)
                No tunnel, bridge, Keychain or other client will be configured.

                """)
                output("Apply this change? [y/N]")
                let answer = readAnswer()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard answer == "y" || answer == "yes" else {
                    payload["status"] = "CANCELLED"
                    emit(payload)
                    return 3
                }
            }

            if !options.disconnect { payload["localProbe"] = try probe() }
            let result = try RightClickOnboardingEngine.apply(onboarding)
            payload["status"] =
                result.operation

            payload["configurationChanged"] =
                onboarding.mutation.changed
                ? "true"
                : "false"

            if let backup = result.backup {
                payload["backup"] = backup.path
            }

            if result.connectionState == .connected {
                payload["mcpConnection"] = "CONNECTED"
            }

            if options.disconnect {
                switch onboarding.clientID {
                case "claude":
                    payload["next"] =
                        "Claude Code no longer has the "
                        + "RIGHTCLICK user-scope MCP registration."

                case "codex":
                    payload["next"] =
                        "Codex no longer has the RIGHTCLICK "
                        + "global MCP registration."

                default:
                    payload["next"] =
                        "Reload Cursor to stop using this entry. "
                        + "No process was stopped by setup."
                }
            } else {
                switch onboarding.clientID {
                case "claude":
                    payload["next"] =
                        "Claude Code reports RIGHTCLICK connected. "
                        + "Start a new Claude Code session and ask "
                        + "it to use RIGHTCLICK."

                case "codex":
                    payload["next"] =
                        "Codex has the RIGHTCLICK MCP registration. "
                        + "Start a new Codex session and ask it to "
                        + "use RIGHTCLICK. Connection is not attested "
                        + "by this setup command."

                default:
                    payload["next"] =
                        "Open Cursor, enable RIGHTCLICK in its MCP "
                        + "settings if required, and start a new chat. "
                        + "Ask: Use RIGHTCLICK to inspect the exact "
                        + "text RightClick, then list applicable "
                        + "capabilities. Do not invoke any capability yet."
                }
            }
            emit(payload)
            return 0
        } catch {
            emit(["status": "FAILED", "error": String(describing: error),
                  "mcpConnection": "NOT_VERIFIED", "outcomeVerification": "NOT_RUN"])
            return 1
        }
    }
}
