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
        let exactConnection: ((String) -> Bool)?

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
            connectedFragments: [String] = [],
            exactConnection: ((String) -> Bool)? = nil
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
            self.exactConnection = exactConnection
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

    struct MutationFailure: Error, CustomStringConvertible {
        let underlying: Error
        let rollbackStatus: String
        let configurationChanged: String
        var description: String {
            if rollbackStatus == "ROLLBACK_FAILED" {
                return "Native client command failed; the current registration could not safely be restored. "
                    + "Any conflicting newer registration was preserved: \(underlying)"
            }
            return "Native client command failed; the original registration state was verified or restored: \(underlying)"
        }
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
                try requireExactRegistration(plan.contract)
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

    static func rollback(
        _ plan: Plan
    ) throws {
        guard plan.changed else {
            return
        }

        switch plan.operation {
        case "CONFIGURED":
            try requireExactRegistration(plan.contract)
            let result =
                try run(
                    plan.contract.remove
                )

            guard result.status == 0
            else {
                throw RightClickOnboardingError(
                    "Native transaction rollback remove "
                    + "failed with exit "
                    + "\(result.status)."
                )
            }

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
                    "Native transaction rollback could "
                    + "not verify registration removal."
                )
            }

        case "DISCONNECTED":
            let current = try run(plan.contract.inspect)
            guard isAbsent(current, contract: plan.contract) else {
                throw RightClickOnboardingError("Native registration changed after disconnect; the newer state was preserved.")
            }
            let result =
                try run(
                    plan.contract.add
                )

            guard result.status == 0
            else {
                throw RightClickOnboardingError(
                    "Native transaction rollback add "
                    + "failed with exit "
                    + "\(result.status)."
                )
            }

            try requireExactRegistration(
                plan.contract
            )

        default:
            throw RightClickOnboardingError(
                "Unsupported native transaction rollback "
                + "operation: "
                + plan.operation
            )
        }
    }

    private static func requireMutationLease(
        _ plan: Plan
    ) throws {
        let current =
            try run(
                plan.contract.inspect
            )

        switch plan.operation {
        case "CONFIGURED":
            guard isAbsent(
                current,
                contract:
                    plan.contract
            )
            else {
                throw RightClickOnboardingError(
                    "Native RIGHTCLICK registration changed "
                    + "after preflight. Nothing was changed; "
                    + "run setup again."
                )
            }

        case "DISCONNECTED":
            guard
                current.status == 0,
                desiredRegistrationMatches(
                    current.output,
                    contract:
                        plan.contract
                )
            else {
                throw RightClickOnboardingError(
                    "Native RIGHTCLICK registration changed "
                    + "after preflight. Nothing was changed; "
                    + "run setup again."
                )
            }

        default:
            throw RightClickOnboardingError(
                "Unsupported native mutation lease "
                + "operation: "
                + plan.operation
            )
        }
    }

    private static func configure(
        _ plan: Plan
    ) throws -> Applied {
        try requireMutationLease(
            plan
        )

        try performMutation(plan, command: plan.contract.add)

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
            throw recoverFailedMutation(plan, underlying: error)
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
        try requireMutationLease(
            plan
        )

        try performMutation(plan, command: plan.contract.remove)

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
            throw recoverFailedMutation(plan, underlying: error)
        }

        return Applied(
            operation:
                plan.operation,
            connectionState:
                nil
        )
    }

    private static func performMutation(_ plan: Plan, command: Command) throws {
        do {
            let result = try run(command)
            guard result.status == 0 else {
                throw RightClickOnboardingError("Native mutation exited with status \(result.status).")
            }
        } catch {
            throw recoverFailedMutation(plan, underlying: error)
        }
    }

    /// An exit status is not evidence that no write occurred. Inspect again,
    /// restore only an exact owned partial result, and preserve newer entries.
    private static func recoverFailedMutation(_ plan: Plan, underlying: Error) -> MutationFailure {
        do {
            let current = try run(plan.contract.inspect)
            let absent = isAbsent(current, contract: plan.contract)
            let exact = current.status == 0 && desiredRegistrationMatches(current.output, contract: plan.contract)
            if (plan.operation == "CONFIGURED" && absent) || (plan.operation == "DISCONNECTED" && exact) {
                return MutationFailure(underlying: underlying, rollbackStatus: "NOT_REQUIRED", configurationChanged: "false")
            }
            guard (plan.operation == "CONFIGURED" && exact) || (plan.operation == "DISCONNECTED" && absent) else {
                return MutationFailure(underlying: underlying, rollbackStatus: "ROLLBACK_FAILED", configurationChanged: "UNKNOWN")
            }
            try rollback(plan)
            return MutationFailure(underlying: underlying, rollbackStatus: "RESTORED", configurationChanged: "false")
        } catch {
            return MutationFailure(underlying: underlying, rollbackStatus: "ROLLBACK_FAILED", configurationChanged: "UNKNOWN")
        }
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

        let connected = contract.exactConnection?(result.output) ?? (
            !contract.connectedFragments.isEmpty && result.output.split(separator: "\n").contains { line in
                contract.connectedFragments.allSatisfy { line.contains($0) }
            })
        guard connected
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
        let result = try RightClickClientProcess.run(executable: command.executable,
            arguments: command.arguments)
        return Result(status: result.status, output: result.output)
    }
}
