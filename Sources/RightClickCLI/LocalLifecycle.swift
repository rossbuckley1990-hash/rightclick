import Foundation
import RightClickCore
import RightClickMCP
#if os(Windows)
import RightClickHostFiles
#endif

/// Setup records only the recipe it owns. It never retains an entire client
/// configuration, environment variables, bearer tokens or client output.
enum RightClickClientOwnershipStore {
    struct Record: Codable, Equatable {
        let clientID: String
        let configurationPath: String
        let command: String
        let arguments: [String]
        let executableSHA256: String
        let rightclickVersion: String
    }
    struct State: Codable {
        let schemaVersion: Int
        let clients: [Record]
    }

    static func file(home: URL) -> URL {
        let environment = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            ? ProcessInfo.processInfo.environment : [:]
        return RuntimePlatform.supportDirectory(home: home, environment: environment)
            .appendingPathComponent("client-ownership.json")
    }

    static func read(home: URL) throws -> State {
        let target = file(home: home)
        guard let data = try RightClickJSONConfigBackend.snapshot(target) else {
            return State(schemaVersion: 1, clients: [])
        }
#if os(Windows)
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        let status = target.path.withCString { rc_host_read_file($0, 4 * 1024 * 1024, 1, &bytes, &count) }
        defer { if let bytes { rc_host_free(bytes) } }
        guard status == 0, let bytes, Data(bytes: bytes, count: count) == data else {
            throw RightClickOnboardingError("The client ownership record is not protected by an owner-only ACL.")
        }
#else
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw RightClickOnboardingError("The client ownership record must have private permissions.")
        }
#endif
        try RightClickJSONConfigBackend.rejectDuplicateJSONKeys(data)
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.schemaVersion == 1,
              Set(state.clients.map(\.clientID)).count == state.clients.count,
              Set(state.clients.map(\.configurationPath)).count == state.clients.count,
              state.clients.allSatisfy({
                  RightClickClientRegistry.supportedIDs.contains($0.clientID)
                      && RuntimePlatform.isAbsolutePath($0.configurationPath)
                      && RuntimePlatform.isAbsolutePath($0.command)
                      && $0.arguments == ["mcp"]
                      && $0.executableSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
              }) else {
            throw RightClickOnboardingError("The client ownership record has an unsupported or invalid contract.")
        }
        return state
    }

    static func digest(_ executable: String) throws -> String {
        let value = RightClickRuntime.identity(transport: "setup", executablePath: executable).executableSHA256
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RightClickOnboardingError("Could not hash the selected RIGHTCLICK executable.")
        }
        return value
    }

    static func plan(home: URL, prepared: [RightClickSetupAllTransaction.PreparedClient],
                     disconnect: Bool) throws -> RightClickJSONConfigBackend.Plan {
        let target = file(home: home)
        let original = try RightClickJSONConfigBackend.snapshot(target)
        let state = try read(home: home)
        var records = Dictionary(uniqueKeysWithValues: state.clients.map { ($0.clientID, $0) })
        for client in prepared {
            let plan = client.plan
            if let previous = records[plan.clientID], previous.configurationPath != plan.configurationFile.standardizedFileURL.path {
                throw RightClickOnboardingError("A different configuration location is already recorded for \(plan.clientID). Disconnect that registration before selecting another file.")
            }
            if disconnect { records.removeValue(forKey: plan.clientID) }
            else {
                records[plan.clientID] = Record(clientID: plan.clientID,
                    configurationPath: plan.configurationFile.standardizedFileURL.path,
                    command: plan.recipe.command, arguments: plan.recipe.arguments,
                    executableSHA256: try digest(plan.recipe.command), rightclickVersion: RightClickVersion.current)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let next = State(schemaVersion: 1, clients: records.values.sorted { $0.clientID < $1.clientID })
        guard Set(next.clients.map(\.configurationPath)).count == next.clients.count else {
            throw RightClickOnboardingError("Two client registrations cannot share the same ownership configuration path.")
        }
        var replacement = try encoder.encode(next)
        replacement.append(10)
        let changed = replacement != original && (!next.clients.isEmpty || original != nil)
        return .init(file: target, original: original, replacement: changed ? replacement : original,
                     operation: changed ? "OWNERSHIP_RECORDED" : "OWNERSHIP_UNCHANGED", changed: changed)
    }
}

enum RightClickLocalLifecycle {
    struct ValidationFailure: Error, CustomStringConvertible {
        let underlying: Error
        let rollbackStatus: String
        let rollbackErrors: [String]
        let configurationChanged: String
        var description: String {
            if rollbackStatus == "RESTORED" || rollbackStatus == "NOT_REQUIRED" {
                return "Setup validation failed; the original registrations were restored: \(underlying)"
            }
            return "Setup validation failed; rollback could not safely restore: "
                + rollbackErrors.joined(separator: ", ") + ". Review retained backups and newer client state."
        }
    }

    /// Client registrations and their ownership record form one transaction.
    /// A post-write local transport probe is independent of client connection.
    static func apply(_ prepared: [RightClickSetupAllTransaction.PreparedClient], home: URL,
                      disconnect: Bool = false, afterOwnershipReplace: (() throws -> Void)? = nil,
                      verify: () throws -> Void = {}) throws
        -> [RightClickSetupAllTransaction.AppliedClient] {
        let ownership = try RightClickClientOwnershipStore.plan(home: home, prepared: prepared,
                                                              disconnect: disconnect)
        let selectedIDs = Set(prepared.map { $0.plan.clientID })
        let expectedExecutables: [RightClickClientOwnershipStore.Record]
        if !disconnect, let data = ownership.replacement {
            expectedExecutables = try JSONDecoder().decode(RightClickClientOwnershipStore.State.self, from: data)
                .clients.filter { selectedIDs.contains($0.clientID) }
        } else { expectedExecutables = [] }
        let applied = try RightClickSetupAllTransaction.apply(prepared)
        var recorded: RightClickJSONConfigBackend.Applied?
        do {
            recorded = try RightClickJSONConfigBackend.apply(ownership, afterReplace: afterOwnershipReplace)
            try verify()
            for record in expectedExecutables {
                guard try RightClickClientOwnershipStore.digest(record.command) == record.executableSHA256 else {
                    throw RightClickOnboardingError("The selected RIGHTCLICK executable changed during setup. Retry with a stable installation.")
                }
            }
            return applied
        } catch {
            let ownershipFailure = recorded == nil ? error as? RightClickJSONConfigBackend.MutationFailure : nil
            var failures: [String] = ownershipFailure?.rollbackStatus == "ROLLBACK_FAILED" ? ["ownership record"] : []
            if let recorded {
                do { try RightClickJSONConfigBackend.rollbackTransaction(ownership, applied: recorded) }
                catch { failures.append("ownership record") }
            }
            for client in applied.reversed() where client.prepared.plan.mutation.changed {
                do { try RightClickOnboardingEngine.rollback(client.prepared.plan, applied: client.result) }
                catch { failures.append(client.prepared.plan.clientID) }
            }
            let rollbackRequired = recorded != nil || ownershipFailure?.rollbackStatus == "RESTORED"
                || applied.contains { $0.prepared.plan.mutation.changed }
            throw ValidationFailure(underlying: error,
                rollbackStatus: failures.isEmpty ? (rollbackRequired ? "RESTORED" : "NOT_REQUIRED") : "ROLLBACK_FAILED",
                rollbackErrors: failures,
                configurationChanged: failures.isEmpty ? "false" : "UNKNOWN")
        }
    }

    static func repairPlan(record: RightClickClientOwnershipStore.Record, home: URL,
                           executable: String) throws -> RightClickSetupAllTransaction.PreparedClient {
        let adapter: any RightClickClientAdapter
        if record.clientID == "generic" {
            adapter = RightClickGenericClientAdapter(file: URL(fileURLWithPath: record.configurationPath))
        } else {
            guard let registered = RightClickClientRegistry.adapter(id: record.clientID),
                  registered.configurationFile(home: home).standardizedFileURL.path == record.configurationPath else {
                throw RightClickOnboardingError("The recorded client or configuration location changed; review setup for \(record.clientID).")
            }
            adapter = registered
        }
        let desired = try adapter.connectionRecipe(executable: executable)
        let previous = try RightClickConnectionRecipe.stdio(command: record.command, arguments: record.arguments)
        let mutation: RightClickOnboardingMutation
        if record.clientID == "codex" || record.clientID == "claude" {
            func contract(_ recipe: RightClickConnectionRecipe) throws -> RightClickNativeRegistrationBackend.Contract {
                if let codex = adapter as? RightClickCodexClientAdapter {
                    return try codex.registrationContract(home: home, recipe: recipe)
                }
                guard let claude = adapter as? RightClickClaudeClientAdapter else {
                    throw RightClickOnboardingError("The recorded native client adapter is unavailable.")
                }
                return try claude.registrationContract(home: home, recipe: recipe)
            }
            if previous.command == desired.command {
                mutation = .native(try RightClickNativeRegistrationBackend.plan(contract: contract(desired), disconnect: false))
            } else {
                let old = try RightClickNativeRegistrationBackend.plan(contract: contract(previous), disconnect: true)
                let next = RightClickNativeRegistrationBackend.Plan(contract: try contract(desired),
                    operation: "CONFIGURED", changed: true)
                mutation = old.changed ? .replacingNative(previous: old, replacement: next) : .native(next)
            }
        } else {
            var oldLegacy = previous.jsonMCPEntry
            oldLegacy.removeValue(forKey: "type")
            var newLegacy = desired.jsonMCPEntry
            newLegacy.removeValue(forKey: "type")
            mutation = .json(try RightClickJSONConfigBackend.plan(file: adapter.configurationFile(home: home),
                containerKey: "mcpServers", entryKey: "rightclick", desiredEntry: desired.jsonMCPEntry,
                acceptedExistingEntries: [previous.jsonMCPEntry, oldLegacy, newLegacy], replaceAcceptedExisting: true))
        }
        let plan = RightClickOnboardingPlan(clientID: adapter.id, clientDisplayName: adapter.displayName,
            configurationFile: adapter.configurationFile(home: home), recipe: desired, mutation: mutation)
        return .init(adapter: adapter, plan: plan)
    }

    /// --fix is itself authorization for repairs of recorded RIGHTCLICK entries.
    /// Unowned registrations are never adopted, overwritten or disconnected.
    static func runRepair(args: [String], executable: String,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          output: (String) -> Void = { print($0) }, probe: () throws -> String) -> Int {
        let json = args.contains("--json")
        func emit(_ payload: [String: Any]) {
            let data = try? JSONSerialization.data(withJSONObject: payload, options: json ? [.sortedKeys] : [.prettyPrinted, .sortedKeys])
            output(data.map { String(decoding: $0, as: UTF8.self) } ?? "Repair report could not be encoded.")
        }
        do {
            var seen = Set<String>()
            for argument in args {
                guard ["--fix", "--dry-run", "--json"].contains(argument), seen.insert(argument).inserted else {
                    throw RightClickOnboardingError("doctor --fix supports only --dry-run and --json.")
                }
            }
            guard args.contains("--fix") else { throw RightClickOnboardingError("Repair requires doctor --fix.") }
            let state = try RightClickClientOwnershipStore.read(home: home)
            guard !state.clients.isEmpty else {
                emit(["status": "NO_OWNED_REGISTRATIONS", "configurationChanged": false,
                      "mcpConnection": "NOT_OBSERVED", "next": "Run rightclick setup to select and register a supported client."])
                return 0
            }
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw RightClickOnboardingError("The selected RIGHTCLICK executable is missing or not executable. Reinstall RIGHTCLICK, then retry doctor --fix.")
            }
            let prepared = try state.clients.map { try repairPlan(record: $0, home: home, executable: executable) }
            let newHash = try RightClickClientOwnershipStore.digest(executable)
            let records: [[String: Any]] = zip(state.clients, prepared).map { record, client in
                ["client": record.clientID, "operation": client.plan.mutation.operation,
                 "runtimeChanged": record.executableSHA256 != newHash || record.rightclickVersion != RightClickVersion.current,
                 "mcpConnection": "NOT_OBSERVED"]
            }
            if args.contains("--dry-run") {
                emit(["status": "DRY_RUN", "configurationChanged": false, "localProbe": "NOT_RUN", "clients": records])
                return 0
            }
            let before = try probe()
            var after = "NOT_RUN"
            let applied = try apply(prepared, home: home) { after = try probe() }
            emit(["status": "REPAIRED", "configurationChanged": applied.contains { $0.prepared.plan.mutation.changed },
                  "localProbe": after, "preflightProbe": before, "mcpConnection": "NOT_OBSERVED",
                  "clients": records, "rollbackStatus": "NOT_REQUIRED"])
            return 0
        } catch {
            var payload: [String: Any] = ["status": "FAILED", "error": String(describing: error),
                "mcpConnection": "NOT_OBSERVED", "configurationChanged": "false", "rollbackStatus": "NOT_REQUIRED",
                "next": "Review the preserved registration and private backup, then rerun setup or doctor --fix."]
            if let failure = error as? ValidationFailure {
                payload["rollbackStatus"] = failure.rollbackStatus
                payload["configurationChanged"] = failure.configurationChanged
            } else if let failure = error as? RightClickSetupAllTransaction.ApplyFailure {
                payload["rollbackStatus"] = failure.rollbackStatus
                payload["configurationChanged"] = failure.rollbackStatus == "ROLLBACK_FAILED" ? "UNKNOWN" : "false"
            }
            emit(payload)
            return 1
        }
    }

    static func liveProbe(executable: String) throws -> String {
        try RightClickStdioProbe.run(executable: executable)
    }
}
