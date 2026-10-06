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
        let health: Command
        let desiredInspectionFragments: [String]
        let absenceMarkers: [String]
        let connectedFragments: [String]
    }

    struct Plan {
        let contract: Contract
        let operation: String
        let changed: Bool
    }

    struct Applied {
        let operation: String
        let connectionState: RightClickClientState?
    }

    private struct Result {
        let status: Int32
        let output: String
    }

    static func plan(
        contract: Contract,
        disconnect: Bool
    ) throws -> Plan {
        let result = try run(contract.inspect)

        if result.status == 0 {
            let exact = contract
                .desiredInspectionFragments
                .allSatisfy {
                    result.output.contains($0)
                }

            guard exact else {
                throw RightClickOnboardingError(
                    "A different rightclick registration already exists. "
                    + "It was preserved; review it before switching builds."
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
            "Could not safely inspect the client's existing "
            + "RIGHTCLICK registration. Native command exited "
            + "\(result.status)."
        )
    }

    static func apply(
        _ plan: Plan
    ) throws -> Applied {
        if !plan.changed {
            if plan.operation == "ALREADY_CONFIGURED" {
                try requireConnected(
                    plan.contract
                )

                return Applied(
                    operation: plan.operation,
                    connectionState: .connected
                )
            }

            return Applied(
                operation: plan.operation,
                connectionState: nil
            )
        }

        switch plan.operation {
        case "CONFIGURED":
            return try configure(plan)

        case "DISCONNECTED":
            return try disconnect(plan)

        default:
            throw RightClickOnboardingError(
                "Unsupported native registration operation: "
                + plan.operation
            )
        }
    }

    private static func configure(
        _ plan: Plan
    ) throws -> Applied {
        let result = try run(
            plan.contract.add
        )

        guard result.status == 0 else {
            throw RightClickOnboardingError(
                "Native registration failed with exit "
                + "\(result.status): "
                + result.output
            )
        }

        do {
            try requireExactRegistration(
                plan.contract
            )

            try requireConnected(
                plan.contract
            )
        } catch {
            _ = try? run(
                plan.contract.remove
            )

            throw RightClickOnboardingError(
                "Native registration postcondition failed; "
                + "RIGHTCLICK attempted to restore the previous "
                + "unconfigured state: \(error)"
            )
        }

        return Applied(
            operation: plan.operation,
            connectionState: .connected
        )
    }

    private static func disconnect(
        _ plan: Plan
    ) throws -> Applied {
        let result = try run(
            plan.contract.remove
        )

        guard result.status == 0 else {
            throw RightClickOnboardingError(
                "Native deregistration failed with exit "
                + "\(result.status): "
                + result.output
            )
        }

        do {
            let inspection = try run(
                plan.contract.inspect
            )

            guard isAbsent(
                inspection,
                contract: plan.contract
            ) else {
                throw RightClickOnboardingError(
                    "Client still reports a RIGHTCLICK "
                    + "registration after native remove."
                )
            }
        } catch {
            _ = try? run(
                plan.contract.add
            )

            throw RightClickOnboardingError(
                "Native deregistration postcondition failed; "
                + "RIGHTCLICK attempted to restore the previous "
                + "registration: \(error)"
            )
        }

        return Applied(
            operation: plan.operation,
            connectionState: nil
        )
    }

    private static func requireExactRegistration(
        _ contract: Contract
    ) throws {
        let result = try run(
            contract.inspect
        )

        guard result.status == 0 else {
            throw RightClickOnboardingError(
                "Client did not return the new RIGHTCLICK "
                + "registration after native add."
            )
        }

        guard contract
            .desiredInspectionFragments
            .allSatisfy({
                result.output.contains($0)
            })
        else {
            throw RightClickOnboardingError(
                "Client returned a different RIGHTCLICK "
                + "registration after native add."
            )
        }
    }

    private static func requireConnected(
        _ contract: Contract
    ) throws {
        let result = try run(
            contract.health
        )

        guard result.status == 0 else {
            throw RightClickOnboardingError(
                "Client MCP health check failed with exit "
                + "\(result.status)."
            )
        }

        guard contract
            .connectedFragments
            .allSatisfy({
                result.output.contains($0)
            })
        else {
            throw RightClickOnboardingError(
                "RIGHTCLICK is configured but the client did "
                + "not report it as connected."
            )
        }
    }

    private static func isAbsent(
        _ result: Result,
        contract: Contract
    ) -> Bool {
        guard result.status != 0 else {
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
        guard command.executable.hasPrefix("/"),
              !command.executable.unicodeScalars.contains(
                where: {
                    CharacterSet
                        .controlCharacters
                        .contains($0)
                }
              )
        else {
            throw RightClickOnboardingError(
                "Native client executable must be an "
                + "absolute safe path."
            )
        }

        guard FileManager.default
            .isExecutableFile(
                atPath: command.executable
            )
        else {
            throw RightClickOnboardingError(
                "Native client executable is missing or "
                + "not executable: "
                + command.executable
            )
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(
            fileURLWithPath: command.executable
        )

        process.arguments =
            command.arguments

        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw RightClickOnboardingError(
                "Could not launch native client command: "
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
