import Foundation

enum RightClickNativeRegistrationBackend {
    struct Command {
        let executable: String
        let arguments: [String]
    }

    struct Contract {
        let backendID: String
        let scope: String
        let inspect: Command
        let add: Command
        let remove: Command

        // Some clients, such as Claude Code, expose a native
        // health surface that independently reports MCP connection.
        // Others, such as the frozen Codex contract, expose only
        // configuration inspection. A missing health command means
        // RIGHTCLICK must not claim CONNECTED.
        let health: Command?

        // Simple textual contracts can use exact required fragments.
        let desiredInspectionFragments: [String]

        // Structured clients may supply an exact semantic matcher.
        // When present this takes precedence over fragments.
        let exactInspection:
            ((String) -> Bool)?

        let absenceMarkers: [String]
        let connectedFragments: [String]

        init(
            backendID: String,
            scope: String,
            inspect: Command,
            add: Command,
            remove: Command,
            health: Command? = nil,
            desiredInspectionFragments: [String] = [],
            exactInspection:
                ((String) -> Bool)? = nil,
            absenceMarkers: [String],
            connectedFragments: [String] = []
        ) {
            self.backendID = backendID
            self.scope = scope
            self.inspect = inspect
            self.add = add
            self.remove = remove
            self.health = health
            self.desiredInspectionFragments =
                desiredInspectionFragments
            self.exactInspection = exactInspection
            self.absenceMarkers = absenceMarkers
            self.connectedFragments =
                connectedFragments
        }
    }

    struct Plan {
        let contract: Contract
        let operation: String
        let changed: Bool
    }

    struct Applied {
        let operation: String
        let connectionState:
            RightClickClientState?
    }

    private struct Result {
        let status: Int32
        let output: String
    }

    static func plan(
        contract: Contract,
        disconnect: Bool
    ) throws -> Plan {
        let result =
            try run(
                contract.inspect
            )

        if result.status == 0 {
            guard desiredRegistrationMatches(
                result.output,
                contract: contract
            )
            else {
                throw RightClickOnboardingError(
                    "A different rightclick registration "
                    + "already exists. It was preserved; "
                    + "review it before switching builds."
                )
            }

            return Plan(
                contract: contract,
                operation:
                    disconnect
                    ? "DISCONNECTED"
                    : "ALREADY_CONFIGURED",
                changed: disconnect
            )
        }

        if isAbsent(
            result,
            contract: contract
        ) {
            return Plan(
                contract: contract,
                operation:
                    disconnect
                    ? "ALREADY_DISCONNECTED"
                    : "CONFIGURED",
                changed: !disconnect
            )
        }

        throw RightClickOnboardingError(
            "Could not safely inspect the client's "
            + "existing RIGHTCLICK registration. "
            + "Native command exited "
            + "\(result.status)."
        )
    }

    static func apply(
        _ plan: Plan
    ) throws -> Applied {
        if !plan.changed {
            if plan.operation ==
                "ALREADY_CONFIGURED"
            {
                let connection =
                    try connectionState(
                        plan.contract
                    )

                return Applied(
                    operation:
                        plan.operation,
                    connectionState:
                        connection
                )
            }

            return Applied(
                operation:
                    plan.operation,
                connectionState:
                    nil
            )
        }

        switch plan.operation {
        case "CONFIGURED":
            return try configure(plan)

        case "DISCONNECTED":
            return try disconnect(plan)

        default:
            throw RightClickOnboardingError(
                "Unsupported native registration "
                + "operation: "
                + plan.operation
            )
        }
    }

    private static func configure(
        _ plan: Plan
    ) throws -> Applied {
        let result =
            try run(
                plan.contract.add
            )

        guard result.status == 0
        else {
            throw RightClickOnboardingError(
                "Native registration failed with exit "
                + "\(result.status): "
                + result.output
            )
        }

        let connection:
            RightClickClientState?

        do {
            try requireExactRegistration(
                plan.contract
            )

            connection =
                try connectionState(
                    plan.contract
                )
        } catch {
            _ =
                try? run(
                    plan.contract.remove
                )

            throw RightClickOnboardingError(
                "Native registration postcondition "
                + "failed; RIGHTCLICK attempted to "
                + "restore the previous unconfigured "
                + "state: \(error)"
            )
        }

        return Applied(
            operation:
                plan.operation,
            connectionState:
                connection
        )
    }

    private static func disconnect(
        _ plan: Plan
    ) throws -> Applied {
        let result =
            try run(
                plan.contract.remove
            )

        guard result.status == 0
        else {
            throw RightClickOnboardingError(
                "Native deregistration failed with exit "
                + "\(result.status): "
                + result.output
            )
        }

        do {
            let inspection =
                try run(
                    plan.contract.inspect
                )

            guard isAbsent(
                inspection,
                contract:
                    plan.contract
            )
            else {
                throw RightClickOnboardingError(
                    "Client still reports a RIGHTCLICK "
                    + "registration after native remove."
                )
            }
        } catch {
            _ =
                try? run(
                    plan.contract.add
                )

            throw RightClickOnboardingError(
                "Native deregistration postcondition "
                + "failed; RIGHTCLICK attempted to "
                + "restore the previous registration: "
                + "\(error)"
            )
        }

        return Applied(
            operation:
                plan.operation,
            connectionState:
                nil
        )
    }

    private static func requireExactRegistration(
        _ contract: Contract
    ) throws {
        let result =
            try run(
                contract.inspect
            )

        guard result.status == 0
        else {
            throw RightClickOnboardingError(
                "Client did not return the new "
                + "RIGHTCLICK registration after "
                + "native add."
            )
        }

        guard desiredRegistrationMatches(
            result.output,
            contract: contract
        )
        else {
            throw RightClickOnboardingError(
                "Client returned a different RIGHTCLICK "
                + "registration after native add."
            )
        }
    }

    private static func desiredRegistrationMatches(
        _ output: String,
        contract: Contract
    ) -> Bool {
        if let matcher =
            contract.exactInspection
        {
            return matcher(output)
        }

        return contract
            .desiredInspectionFragments
            .allSatisfy {
                output.contains($0)
            }
    }

    private static func connectionState(
        _ contract: Contract
    ) throws
        -> RightClickClientState?
    {
        guard let health =
            contract.health
        else {
            return nil
        }

        let result =
            try run(health)

        guard result.status == 0
        else {
            throw RightClickOnboardingError(
                "Client MCP health check failed with "
                + "exit \(result.status)."
            )
        }

        guard contract
            .connectedFragments
            .allSatisfy({
                result.output.contains($0)
            })
        else {
            throw RightClickOnboardingError(
                "RIGHTCLICK is configured but the "
                + "client did not report it as "
                + "connected."
            )
        }

        return .connected
    }

    private static func isAbsent(
        _ result: Result,
        contract: Contract
    ) -> Bool {
        guard result.status != 0
        else {
            return false
        }

        return contract
            .absenceMarkers
            .contains {
                result.output.contains($0)
            }
    }

    private static func run(
        _ command: Command
    ) throws -> Result {
        guard
            command.executable
                .hasPrefix("/"),
            !command.executable
                .unicodeScalars
                .contains(
                    where: {
                        CharacterSet
                            .controlCharacters
                            .contains($0)
                    }
                )
        else {
            throw RightClickOnboardingError(
                "Native client executable must be "
                + "an absolute safe path."
            )
        }

        guard FileManager.default
            .isExecutableFile(
                atPath:
                    command.executable
            )
        else {
            throw RightClickOnboardingError(
                "Native client executable is missing "
                + "or not executable: "
                + command.executable
            )
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL =
            URL(
                fileURLWithPath:
                    command.executable
            )

        process.arguments =
            command.arguments

        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw RightClickOnboardingError(
                "Could not launch native client "
                + "command: "
                + String(describing: error)
            )
        }

        process.waitUntilExit()

        let data =
            pipe.fileHandleForReading
                .readDataToEndOfFile()

        let output =
            String(
                data: data,
                encoding: .utf8
            )
            ?? ""

        return Result(
            status:
                process.terminationStatus,
            output:
                output
        )
    }
}
