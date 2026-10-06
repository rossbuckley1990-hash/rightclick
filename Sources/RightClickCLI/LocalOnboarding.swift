import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local-only onboarding. Deliberately independent of bridge, Keychain and setup-state code.
/// Configuration is not evidence of an MCP connection or a verified external outcome.
enum RightClickLocalOnboarding {
    struct SetupError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

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
                guard seen.insert(arg).inserted else {
                    throw SetupError("Repeated option: \(arg)")
                }
                switch arg {
                case "--client":
                    index += 1
                    guard index < args.count, args[index] == "cursor" else {
                        throw SetupError("RIGHTCLICK currently supports --client cursor only.")
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
                throw SetupError("Use --client cursor with --yes to explicitly select the client.")
            }
        }
    }

    struct Plan {
        let file: URL
        let original: Data?
        let replacement: Data?
        let operation: String
        let changed: Bool
    }

    struct Applied {
        let operation: String
        let backup: URL?
    }

    static let usage = """
    rightclick setup
    rightclick setup --client cursor [--yes] [--dry-run] [--json]
    rightclick setup --client cursor --disconnect [--yes] [--dry-run] [--json]

    Local setup changes only Cursor's rightclick entry. No tunnel is prepared or started.
    Dry-run never writes configuration or runs the local probe.
    Existing different rightclick entries are never silently replaced.
    """

    /// Require an explicit, supported bridge request; never inherit one from saved state.
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
        let fm = FileManager.default
        return [
            applications.appendingPathComponent("Cursor.app"),
            home.appendingPathComponent("Applications/Cursor.app"),
            home.appendingPathComponent(".cursor"),
        ].contains { url in
            var directory = ObjCBool(false)
            return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
    }

    static func desiredEntry(executable: String) throws -> [String: Any] {
        guard executable.hasPrefix("/"),
              !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !executable.contains("${") else {
            throw SetupError("The executable must be an absolute path without control characters or client interpolation syntax.")
        }
        return ["type": "stdio", "command": executable, "args": ["mcp"]]
    }

    /// Reject symlinks and non-regular targets. Do not follow an unexpected configuration redirect.
    static func inspectPath(_ file: URL) throws {
        let fm = FileManager.default
        var path = file.standardizedFileURL
        var isTarget = true
        while path.path != "/" {
            if let attrs = try? fm.attributesOfItem(atPath: path.path) {
                let type = attrs[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    // macOS exposes /var as the system-owned alias /var -> /private/var.
                    // Permit only that exact root-level alias. All other symlink
                    // components remain fail-closed.
                    let destination = try? fm.destinationOfSymbolicLink(atPath: path.path)
                    let trustedMacOSVarAlias =
                        path.path == "/var"
                        && (destination == "private/var" || destination == "/private/var")

                    guard trustedMacOSVarAlias else {
                        throw SetupError("Refusing a symbolic link in configuration path: \(path.path)")
                    }
                } else {
                    guard type == (isTarget ? .typeRegular : .typeDirectory) else {
                        throw SetupError("Unexpected file type in configuration path: \(path.path)")
                    }
                    if isTarget, let links = attrs[.referenceCount] as? NSNumber, links.intValue > 1 {
                        throw SetupError("Refusing a hard-linked configuration file.")
                    }
                }
            } else if fm.fileExists(atPath: path.path) {
                throw SetupError("Cannot inspect configuration path: \(path.path)")
            }
            isTarget = false
            path.deleteLastPathComponent()
        }
    }

    static func snapshot(_ file: URL) throws -> Data? {
        try inspectPath(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 4 * 1024 * 1024 else {
            throw SetupError("Configuration exceeds the 4 MiB safety limit.")
        }
        return try Data(contentsOf: file)
    }

    /// Pure merge planning: unrelated values are preserved semantically; invalid inputs fail closed.
    static func plan(file: URL, executable: String, disconnect: Bool = false) throws -> Plan {
        let entry = try desiredEntry(executable: executable)
        let original = try snapshot(file)
        var root: [String: Any] = [:]
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SetupError("Configuration root must be a JSON object. Nothing was changed.")
            }
            try rejectDuplicateJSONKeys(original)
            root = object
        }
        var servers: [String: Any] = [:]
        if let present = root["mcpServers"] {
            guard let object = present as? [String: Any] else {
                throw SetupError("mcpServers must be a JSON object. Nothing was changed.")
            }
            servers = object
        }
        if let present = servers["rightclick"] {
            // Accept the previous equivalent shape (without type); never drop extra settings.
            var legacy = entry
            legacy.removeValue(forKey: "type")
            guard let object = present as? NSDictionary,
                  object.isEqual(to: entry) || object.isEqual(to: legacy) else {
                throw SetupError("A different rightclick entry already exists. It was preserved; review it before switching builds.")
            }
            if !disconnect {
                return Plan(file: file, original: original, replacement: original, operation: "ALREADY_CONFIGURED", changed: false)
            }
            servers.removeValue(forKey: "rightclick")
        } else {
            if disconnect {
                return Plan(file: file, original: original, replacement: original, operation: "ALREADY_DISCONNECTED", changed: false)
            }
            servers["rightclick"] = entry
        }
        root["mcpServers"] = servers
        var replacement = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        replacement.append(0x0A)
        return Plan(file: file, original: original, replacement: replacement,
                    operation: disconnect ? "DISCONNECTED" : "CONFIGURED", changed: true)
    }

    /// JSONSerialization accepts duplicate keys. Refuse those rather than silently losing settings.
    /// Called only after JSONSerialization has validated the JSON grammar.
    private static func rejectDuplicateJSONKeys(_ data: Data) throws {
        let bytes = Array(data)
        var index = 0
        func skipSpace() {
            while index < bytes.count && [UInt8(9), 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        func stringToken() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    let token = Data(bytes[start..<index])
                    guard let value = try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else {
                        throw SetupError("Invalid JSON string.")
                    }
                    return value
                }
                index += 1
            }
            throw SetupError("Unterminated JSON string.")
        }
        func visit(depth: Int) throws {
            guard depth < 128 else { throw SetupError("Configuration nesting exceeds the safety limit.") }
            skipSpace()
            guard index < bytes.count else { throw SetupError("Incomplete JSON configuration.") }
            switch bytes[index] {
            case 123: // object
                index += 1
                skipSpace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                var keys = Set<String>()
                while index < bytes.count {
                    skipSpace()
                    guard index < bytes.count && bytes[index] == 34 else { throw SetupError("Invalid JSON object key.") }
                    let key = try stringToken()
                    guard keys.insert(key).inserted else {
                        throw SetupError("Configuration has duplicate JSON object keys. Nothing was changed.")
                    }
                    skipSpace()
                    guard index < bytes.count && bytes[index] == 58 else { throw SetupError("Invalid JSON object separator.") }
                    index += 1
                    try visit(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw SetupError("Incomplete JSON object.") }
                    if bytes[index] == 125 { index += 1; return }
                    guard bytes[index] == 44 else { throw SetupError("Invalid JSON object delimiter.") }
                    index += 1
                }
            case 91: // array
                index += 1
                skipSpace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                while index < bytes.count {
                    try visit(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw SetupError("Incomplete JSON array.") }
                    if bytes[index] == 93 { index += 1; return }
                    guard bytes[index] == 44 else { throw SetupError("Invalid JSON array delimiter.") }
                    index += 1
                }
            case 34: _ = try stringToken()
            default:
                while index < bytes.count && ![UInt8(9), 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            }
        }
        // A UTF-8 BOM is accepted by Foundation and does not contain JSON keys.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        try visit(depth: 0)
        skipSpace()
        guard index == bytes.count else { throw SetupError("Could not safely inspect the JSON configuration.") }
    }

    static func apply(_ plan: Plan) throws -> Applied {
        guard plan.changed else { return Applied(operation: plan.operation, backup: nil) }
        let fm = FileManager.default
        let directory = plan.file.deletingLastPathComponent()
        guard try snapshot(plan.file) == plan.original else {
            throw SetupError("Configuration changed after the preview. Nothing was written; run setup again.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Serialise RIGHTCLICK installers. This does not lock out editors or other clients.
        let lock = directory.appendingPathComponent(".rightclick-setup.lock")
        do {
            try fm.createDirectory(at: lock, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw SetupError("Another setup lock exists or cannot be created. No configuration was written. Check \(lock.path).")
        }
        defer { try? fm.removeItem(at: lock) }
        guard try snapshot(plan.file) == plan.original else {
            throw SetupError("Configuration changed after the preview. Nothing was written; run setup again.")
        }
        var backup: URL?
        if let original = plan.original {
            let url = directory.appendingPathComponent("mcp.json.rightclick-backup-\(UUID().uuidString)")
            try writePrivate(original, to: url)
            backup = url
        }
        let temporary = directory.appendingPathComponent(".rightclick-setup-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard let replacement = plan.replacement else { throw SetupError("Missing planned configuration.") }
        try writePrivate(replacement, to: temporary)
        guard try snapshot(plan.file) == plan.original else {
            throw SetupError("Configuration changed during setup. No replacement was made. A private backup may have been retained.")
        }
        let rc = temporary.path.withCString { source in
            plan.file.path.withCString { destination in rename(source, destination) }
        }
        guard rc == 0 else { throw SetupError("Atomic configuration replacement failed (errno \(errno)).") }
        guard try Data(contentsOf: plan.file) == replacement else {
            throw SetupError("Configuration changed or could not be verified after writing. Check the private backup before proceeding.")
        }
        return Applied(operation: plan.operation, backup: backup)
    }

    private static func writePrivate(_ data: Data, to file: URL) throws {
        let fd = file.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw SetupError("Could not create a private configuration file (errno \(errno)).") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
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
            guard options.client != nil || cursorDetected(home: home) else {
                throw SetupError("No supported local client was detected. RIGHTCLICK currently supports Cursor; use --client cursor to explicitly prepare its configuration.")
            }
            guard options.disconnect || FileManager.default.isExecutableFile(atPath: executable) else {
                throw SetupError("The RIGHTCLICK executable is missing or not executable: \(executable)")
            }
            let file = home.appendingPathComponent(".cursor/mcp.json")
            let planned = try plan(file: file, executable: executable, disconnect: options.disconnect)
            var payload: [String: String] = [
                "client": "cursor", "configuration": file.path,
                "command": executable, "arguments": "mcp", "transport": "stdio",
                "operation": planned.operation, "configurationChanged": "false",
                "mcpConnection": "NOT_VERIFIED", "outcomeVerification": "NOT_RUN",
                "localProbe": "NOT_RUN", "bridge": "NOT_TOUCHED", "keychain": "NOT_TOUCHED",
                "notice": "Cursor can launch this executable and request its discovered capabilities. Existing action confirmations still apply. Close Cursor while changing its configuration.",
            ]
            if options.dryRun {
                payload["status"] = "DRY_RUN"
                emit(payload)
                return 0
            }
            if planned.changed && !options.yes {
                if !interactive || options.json {
                    payload["status"] = "CONSENT_REQUIRED"
                    payload["next"] = "Review this plan, then run setup --client cursor --yes" + (options.disconnect ? " --disconnect" : "")
                    emit(payload)
                    return 3
                }
                output("RIGHTCLICK local setup\n\nClient: Cursor\nConfiguration: \(file.path)\nExecutable: \(executable)\nArguments: mcp\nChange: \(planned.operation)\n\n\(payload["notice"]!)\nNo tunnel, bridge, Keychain or other client will be configured.\n")
                output("Apply this change? [y/N]")
                let answer = readAnswer()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard answer == "y" || answer == "yes" else {
                    payload["status"] = "CANCELLED"
                    emit(payload)
                    return 3
                }
            }
            if !options.disconnect { payload["localProbe"] = try probe() }
            let result = try apply(planned)
            payload["status"] = result.operation
            payload["configurationChanged"] = planned.changed ? "true" : "false"
            if let backup = result.backup { payload["backup"] = backup.path }
            payload["next"] = options.disconnect
                ? "Reload Cursor to stop using this entry. No process was stopped by setup."
                : "Open Cursor, enable RIGHTCLICK in its MCP settings if required, and start a new chat. Ask: Use RIGHTCLICK to inspect the exact text RightClick, then list applicable capabilities. Do not invoke any capability yet."
            emit(payload)
            return 0
        } catch {
            emit(["status": "FAILED", "error": String(describing: error),
                  "mcpConnection": "NOT_VERIFIED", "outcomeVerification": "NOT_RUN"])
            return 1
        }
    }
}
