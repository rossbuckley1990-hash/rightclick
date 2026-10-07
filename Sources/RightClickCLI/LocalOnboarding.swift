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
        var all = false
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
                    guard
                        index < args.count,
                        RightClickClientRegistry
                            .adapter(
                                id: args[index]
                            ) != nil
                    else {
                        let supported =
                            RightClickClientRegistry
                                .supportedIDs
                                .map {
                                    "--client " + $0
                                }
                                .joined(
                                    separator: ", "
                                )

                        throw SetupError(
                            "RIGHTCLICK currently supports: "
                            + supported
                            + "."
                        )
                    }

                    client = args[index]
                case "--all":
                    all = true
                case "--yes":
                    yes = true
                case "--dry-run":
                    dryRun = true
                case "--json": json = true
                case "--disconnect": disconnect = true
                case "--help", "-h": help = true
                default: throw SetupError("Unknown local setup option: \(arg)")
                }
                index += 1
            }
            if all && client != nil {
                throw SetupError(
                    "--all and --client are mutually exclusive."
                )
            }

            if yes
                && client == nil
                && !all
            {
                throw SetupError(
                    "Use --client <id> or --all with --yes. "
                    + "Supported IDs: "
                    + RightClickClientRegistry
                        .supportedIDs
                        .joined(separator: ", ")
                    + "."
                )
            }
        }
    }

    static var usage: String {
        var lines: [String] = [
            "rightclick setup",
            "rightclick setup --all [--yes] [--dry-run] [--json]",
            "rightclick setup --all --disconnect [--yes] [--dry-run] [--json]",
        ]

        for id in
            RightClickClientRegistry
                .supportedIDs
        {
            lines.append(
                "rightclick setup --client "
                + id
                + " [--yes] [--dry-run] [--json]"
            )

            lines.append(
                "rightclick setup --client "
                + id
                + " --disconnect [--yes] "
                + "[--dry-run] [--json]"
            )
        }

        lines.append("")

        for adapter in
            RightClickClientRegistry
                .adapters
        {
            lines.append(
                adapter.displayName
                + ": "
                + adapter.setupNotice
            )
        }

        lines.append(
            "Dry-run may inspect current state "
            + "but never mutates configuration."
        )

        lines.append(
            "Existing different rightclick "
            + "registrations are never silently replaced."
        )

        return lines.joined(
            separator: "\n"
        )
    }

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

    static func cursorDetected(
        home: URL,
        applications: URL =
            URL(
                fileURLWithPath: "/Applications"
            )
    ) -> Bool {
        RightClickClientRegistry
            .adapters
            .first?
            .detected(
                home: home,
                applications: applications
            )
        ?? false
    }

    static func desiredEntry(
        executable: String
    ) throws -> [String: Any] {
        try RightClickConnectionRecipe
            .stdio(
                command: executable,
                arguments: ["mcp"]
            )
            .jsonMCPEntry
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

    private static func emitAggregate(
        _ payload: [String: Any],
        json: Bool,
        output: (String) -> Void
    ) {
        if json,
           let data =
            try? JSONSerialization
                .data(
                    withJSONObject:
                        payload,
                    options:
                        [.sortedKeys]
                ),
           let text =
            String(
                data: data,
                encoding: .utf8
            )
        {
            output(text)
            return
        }

        if let data =
            try? JSONSerialization
                .data(
                    withJSONObject:
                        payload,
                    options:
                        [
                            .prettyPrinted,
                            .sortedKeys,
                        ]
                ),
           let text =
            String(
                data: data,
                encoding: .utf8
            )
        {
            output(text)
            return
        }

        output(
            String(
                describing:
                    payload
            )
        )
    }

    private static func aggregateClientRecord(
        _ prepared:
            RightClickSetupAllTransaction
                .PreparedClient,
        applied:
            RightClickOnboardingApplied? = nil,
        mutationExecuted: Bool
    ) -> [String: Any] {
        var record:
            [String: Any] = [
                "client":
                    prepared.plan.clientID,
                "displayName":
                    prepared.plan
                        .clientDisplayName,
                "configuration":
                    prepared.plan
                        .configurationFile
                        .path,
                "operation":
                    prepared.plan
                        .mutation
                        .operation,
                "configurationChanged":
                    mutationExecuted
                    && prepared
                        .plan
                        .mutation
                        .changed
                        ? "true"
                        : "false",
                "registrationBackend":
                    prepared.plan
                        .mutation
                        .backendID,
                "registrationScope":
                    prepared.plan
                        .mutation
                        .scope
                    ?? "client-config",
                "mcpConnection":
                    "NOT_VERIFIED",
            ]

        if applied?
            .connectionState
            == .connected
        {
            record[
                "mcpConnection"
            ] = "CONNECTED"
        }

        return record
    }

    private static func runAll(
        options: Options,
        executable: String,
        home: URL,
        interactive: Bool,
        readAnswer: () -> String?,
        output: (String) -> Void,
        probe: () throws -> String,
        json: Bool
    ) -> Int {
        let applications =
            URL(
                fileURLWithPath:
                    "/Applications"
            )

        let adapters =
            RightClickClientRegistry
                .detected(
                    home: home,
                    applications:
                        applications
                )

        let detectedIDs =
            adapters.map {
                $0.id
            }

        guard !adapters.isEmpty
        else {
            emitAggregate(
                [
                    "client": "all",
                    "status": "FAILED",
                    "detectedClients":
                        detectedIDs,
                    "rollbackStatus":
                        "NOT_REQUIRED",
                    "error":
                        "No supported local client was detected.",
                ],
                json: json,
                output: output
            )

            return 1
        }

        guard
            options.disconnect
            || FileManager.default
                .isExecutableFile(
                    atPath:
                        executable
                )
        else {
            emitAggregate(
                [
                    "client": "all",
                    "status": "FAILED",
                    "detectedClients":
                        detectedIDs,
                    "rollbackStatus":
                        "NOT_REQUIRED",
                    "error":
                        "The RIGHTCLICK executable is missing "
                        + "or not executable: "
                        + executable,
                ],
                json: json,
                output: output
            )

            return 1
        }

        let prepared:
            [
                RightClickSetupAllTransaction
                    .PreparedClient
            ]

        do {
            prepared =
                try RightClickSetupAllTransaction
                    .preflight(
                        adapters:
                            adapters,
                        home:
                            home,
                        executable:
                            executable,
                        disconnect:
                            options.disconnect
                    )
        } catch let failure
            as RightClickSetupAllTransaction
                .PreflightFailure
        {
            emitAggregate(
                [
                    "client": "all",
                    "status": "FAILED",
                    "detectedClients":
                        detectedIDs,
                    "failedClient":
                        failure.clientID,
                    "rollbackStatus":
                        "NOT_REQUIRED",
                    "error":
                        failure.description,
                ],
                json: json,
                output: output
            )

            return 1
        } catch {
            emitAggregate(
                [
                    "client": "all",
                    "status": "FAILED",
                    "detectedClients":
                        detectedIDs,
                    "rollbackStatus":
                        "NOT_REQUIRED",
                    "error":
                        String(
                            describing:
                                error
                        ),
                ],
                json: json,
                output: output
            )

            return 1
        }

        let plannedRecords =
            prepared.map {
                aggregateClientRecord(
                    $0,
                    mutationExecuted:
                        false
                )
            }

        let anyChange =
            prepared.contains {
                $0.plan
                    .mutation
                    .changed
            }

        if options.dryRun {
            emitAggregate(
                [
                    "client": "all",
                    "status": "DRY_RUN",
                    "detectedClients":
                        detectedIDs,
                    "configurationChanged":
                        "false",
                    "rollbackStatus":
                        "NOT_REQUIRED",
                    "localProbe":
                        "NOT_RUN",
                    "clients":
                        plannedRecords,
                ],
                json: json,
                output: output
            )

            return 0
        }

        if anyChange
            && !options.yes
        {
            if !interactive
                || json
            {
                emitAggregate(
                    [
                        "client": "all",
                        "status":
                            "CONSENT_REQUIRED",
                        "detectedClients":
                            detectedIDs,
                        "configurationChanged":
                            "false",
                        "rollbackStatus":
                            "NOT_REQUIRED",
                        "localProbe":
                            "NOT_RUN",
                        "clients":
                            plannedRecords,
                        "next":
                            "Review the aggregate plan, "
                            + "then run setup --all --yes"
                            + (
                                options.disconnect
                                ? " --disconnect"
                                : ""
                            ),
                    ],
                    json: json,
                    output: output
                )

                return 3
            }

            output(
                """
                RIGHTCLICK multi-client setup

                Detected clients:
                \(detectedIDs.joined(separator: ", "))

                All detected clients have been preflighted.
                No client has been modified yet.

                """
            )

            output(
                "Apply this transaction to all detected clients? [y/N]"
            )

            let answer =
                readAnswer()?
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .lowercased()

            guard
                answer == "y"
                || answer == "yes"
            else {
                emitAggregate(
                    [
                        "client": "all",
                        "status": "CANCELLED",
                        "detectedClients":
                            detectedIDs,
                        "configurationChanged":
                            "false",
                        "rollbackStatus":
                            "NOT_REQUIRED",
                        "localProbe":
                            "NOT_RUN",
                        "clients":
                            plannedRecords,
                    ],
                    json: json,
                    output: output
                )

                return 3
            }
        }

        var probeResult =
            "NOT_RUN"

        if !options.disconnect {
            do {
                probeResult =
                    try probe()
            } catch {
                emitAggregate(
                    [
                        "client": "all",
                        "status": "FAILED",
                        "detectedClients":
                            detectedIDs,
                        "failedClient":
                            "rightclick",
                        "configurationChanged":
                            "false",
                        "rollbackStatus":
                            "NOT_REQUIRED",
                        "localProbe":
                            "FAILED",
                        "clients":
                            plannedRecords,
                        "error":
                            String(
                                describing:
                                    error
                            ),
                    ],
                    json: json,
                    output: output
                )

                return 1
            }
        }

        let applied:
            [
                RightClickSetupAllTransaction
                    .AppliedClient
            ]

        do {
            applied =
                try RightClickSetupAllTransaction
                    .apply(
                        prepared
                    )
        } catch let failure
            as RightClickSetupAllTransaction
                .ApplyFailure
        {
            emitAggregate(
                [
                    "client": "all",
                    "status": "FAILED",
                    "detectedClients":
                        detectedIDs,
                    "failedClient":
                        failure.clientID,
                    "configurationChanged":
                        "false",
                    "rollbackStatus":
                        failure.rollbackStatus,
                    "localProbe":
                        probeResult,
                    "clients":
                        plannedRecords,
                    "error":
                        failure.description,
                ],
                json: json,
                output: output
            )

            return 1
        } catch {
            emitAggregate(
                [
                    "client": "all",
                    "status": "FAILED",
                    "detectedClients":
                        detectedIDs,
                    "configurationChanged":
                        "false",
                    "rollbackStatus":
                        "ROLLBACK_FAILED",
                    "localProbe":
                        probeResult,
                    "clients":
                        plannedRecords,
                    "error":
                        String(
                            describing:
                                error
                        ),
                ],
                json: json,
                output: output
            )

            return 1
        }

        let clientRecords =
            applied.map {
                aggregateClientRecord(
                    $0.prepared,
                    applied:
                        $0.result,
                    mutationExecuted:
                        true
                )
            }

        let status: String

        if options.disconnect {
            status =
                anyChange
                ? "DISCONNECTED"
                : "ALREADY_DISCONNECTED"
        } else {
            status =
                anyChange
                ? "CONFIGURED"
                : "ALREADY_CONFIGURED"
        }

        emitAggregate(
            [
                "client": "all",
                "status": status,
                "detectedClients":
                    detectedIDs,
                "configurationChanged":
                    anyChange
                    ? "true"
                    : "false",
                "rollbackStatus":
                    "NOT_REQUIRED",
                "localProbe":
                    probeResult,
                "clients":
                    clientRecords,
            ],
            json: json,
            output: output
        )

        return 0
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

            if options.all {
                return runAll(
                    options:
                        options,
                    executable:
                        executable,
                    home:
                        home,
                    interactive:
                        interactive,
                    readAnswer:
                        readAnswer,
                    output:
                        output,
                    probe:
                        probe,
                    json:
                        json
                )
            }

            let applications =
                URL(
                    fileURLWithPath:
                        "/Applications"
                )

            let adapter:
                any RightClickClientAdapter

            if let clientID =
                options.client
            {
                guard let selected =
                    RightClickClientRegistry
                        .adapter(
                            id: clientID
                        )
                else {
                    throw SetupError(
                        "Unsupported local client."
                    )
                }

                adapter = selected
            } else {
                let detected =
                    RightClickClientRegistry
                        .detected(
                            home: home,
                            applications: applications
                        )

                guard let selected =
                    detected.first
                else {
                    throw SetupError(
                        "No supported local client "
                        + "was detected. Supported IDs: "
                        + RightClickClientRegistry
                            .supportedIDs
                            .joined(separator: ", ")
                        + "."
                    )
                }

                adapter = selected
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

            let notice =
                adapter.setupNotice

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

            payload["next"] =
                adapter.nextMessage(
                    disconnect:
                        options.disconnect
                )

            emit(payload)
            return 0
        } catch {
            emit(["status": "FAILED", "error": String(describing: error),
                  "mcpConnection": "NOT_VERIFIED", "outcomeVerification": "NOT_RUN"])
            return 1
        }
    }
}
