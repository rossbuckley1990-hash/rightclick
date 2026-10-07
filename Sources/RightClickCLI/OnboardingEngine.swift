import Foundation
import RightClickCore
import RightClickHostFiles
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct RightClickOnboardingError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum RightClickClientState: String, Codable {
    case notDetected = "NOT_DETECTED"
    case detected = "DETECTED"
    case configured = "CONFIGURED"
    case connected = "CONNECTED"
    case liveAttested = "LIVE_ATTESTED"
    case failed = "FAILED"
}

struct RightClickConnectionRecipe {
    enum Transport: String { case stdio }
    let transport: Transport
    let command: String
    let arguments: [String]

    static func stdio(command: String, arguments: [String]) throws -> Self {
        guard RuntimePlatform.isAbsolutePath(command),
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !command.contains("$" + "{") else {
            throw RightClickOnboardingError("The executable must be an absolute path without control characters or client interpolation syntax.")
        }
        return Self(transport: .stdio, command: command, arguments: arguments)
    }

    var jsonMCPEntry: [String: Any] {
        ["type": transport.rawValue, "command": command, "args": arguments]
    }
}

protocol RightClickClientAdapter {
    var id: String { get }
    var displayName: String { get }
    var setupNotice: String { get }

    func nextMessage(
        disconnect: Bool
    ) -> String

    func detected(
        home: URL,
        applications: URL
    ) -> Bool

    func configurationFile(
        home: URL
    ) -> URL

    func connectionRecipe(
        executable: String
    ) throws -> RightClickConnectionRecipe

    func planConfiguration(
        home: URL,
        recipe: RightClickConnectionRecipe,
        disconnect: Bool
    ) throws -> RightClickOnboardingMutation
}

extension RightClickClientAdapter {
    var setupNotice: String {
        displayName
            + " will use RIGHTCLICK through its "
            + "configured MCP surface."
    }

    func nextMessage(
        disconnect: Bool
    ) -> String {
        if disconnect {
            return displayName
                + " no longer has the RIGHTCLICK "
                + "MCP registration."
        }

        return "Start a new "
            + displayName
            + " session and ask it to use RIGHTCLICK."
    }
}

struct RightClickCursorClientAdapter: RightClickClientAdapter {
    let id = "cursor"
    let displayName = "Cursor"

    let setupNotice =
        "Cursor can launch this executable and request "
        + "its discovered capabilities. Existing action "
        + "confirmations still apply. Close Cursor while "
        + "changing its configuration."

    func nextMessage(
        disconnect: Bool
    ) -> String {
        if disconnect {
            return "Reload Cursor to stop using this entry. "
                + "No process was stopped by setup."
        }

        return "Open Cursor, enable RIGHTCLICK in its MCP "
            + "settings if required, and start a new chat. "
            + "Ask: Use RIGHTCLICK to inspect the exact "
            + "text RightClick, then list applicable "
            + "capabilities. Do not invoke any capability yet."
    }

    func detected(home: URL, applications: URL = URL(fileURLWithPath: "/Applications")) -> Bool {
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

    func configurationFile(home: URL) -> URL {
        home.appendingPathComponent(".cursor/mcp.json")
    }

    func connectionRecipe(executable: String) throws -> RightClickConnectionRecipe {
        try .stdio(command: executable, arguments: ["mcp"])
    }

    func planConfiguration(home: URL, recipe: RightClickConnectionRecipe, disconnect: Bool) throws -> RightClickOnboardingMutation {
        let desired = recipe.jsonMCPEntry
        var legacy = desired
        legacy.removeValue(forKey: "type")
        return .json(try RightClickJSONConfigBackend.plan(
            file: configurationFile(home: home),
            containerKey: "mcpServers",
            entryKey: "rightclick",
            desiredEntry: desired,
            acceptedExistingEntries: [legacy],
            disconnect: disconnect
        ))
    }
}

enum RightClickOnboardingMutation {
    case json(RightClickJSONConfigBackend.Plan)
    case native(RightClickNativeRegistrationBackend.Plan)
    case replacingNative(previous: RightClickNativeRegistrationBackend.Plan, replacement: RightClickNativeRegistrationBackend.Plan)

    var operation: String {
        switch self {
        case .json(let plan):
            return plan.operation
        case .native(let plan):
            return plan.operation
        case .replacingNative:
            return "REPAIRED"
        }
    }

    var changed: Bool {
        switch self {
        case .json(let plan):
            return plan.changed
        case .native(let plan):
            return plan.changed
        case .replacingNative:
            return true
        }
    }

    var backendID: String {
        switch self {
        case .json:
            return "json-config"
        case .native(let plan):
            return plan.contract.backendID
        case .replacingNative(_, let replacement):
            return replacement.contract.backendID
        }
    }

    var scope: String? {
        switch self {
        case .json:
            return nil
        case .native(let plan):
            return plan.contract.scope
        case .replacingNative(_, let replacement):
            return replacement.contract.scope
        }
    }
}

struct RightClickOnboardingPlan {
    let clientID: String
    let clientDisplayName: String
    let configurationFile: URL
    let recipe: RightClickConnectionRecipe
    let mutation: RightClickOnboardingMutation
}

struct RightClickOnboardingApplied {
    let operation: String
    let backup: URL?
    let connectionState: RightClickClientState?
}

enum RightClickOnboardingEngine {
    static func plan(adapter: any RightClickClientAdapter, home: URL, executable: String, disconnect: Bool = false) throws -> RightClickOnboardingPlan {
        let recipe = try adapter.connectionRecipe(executable: executable)
        return RightClickOnboardingPlan(
            clientID: adapter.id,
            clientDisplayName: adapter.displayName,
            configurationFile: adapter.configurationFile(home: home),
            recipe: recipe,
            mutation: try adapter.planConfiguration(home: home, recipe: recipe, disconnect: disconnect)
        )
    }

    static func apply(_ plan: RightClickOnboardingPlan) throws -> RightClickOnboardingApplied {
        switch plan.mutation {
        case .json(let mutation):
            let result = try RightClickJSONConfigBackend.apply(mutation)

            return RightClickOnboardingApplied(
                operation: result.operation,
                backup: result.backup,
                connectionState: nil
            )

        case .native(let mutation):
            let result = try RightClickNativeRegistrationBackend.apply(mutation)

            return RightClickOnboardingApplied(
                operation: result.operation,
                backup: nil,
                connectionState: result.connectionState
            )
        case .replacingNative(let previous, let replacement):
            _ = try RightClickNativeRegistrationBackend.apply(previous)
            do {
                let result = try RightClickNativeRegistrationBackend.apply(replacement)
                return RightClickOnboardingApplied(operation: "REPAIRED", backup: nil,
                    connectionState: result.connectionState)
            } catch {
                do { try RightClickNativeRegistrationBackend.rollback(previous) }
                catch let rollbackError {
                    throw RightClickNativeRegistrationBackend.MutationFailure(underlying: rollbackError,
                        rollbackStatus: "ROLLBACK_FAILED", configurationChanged: "UNKNOWN")
                }
                throw RightClickNativeRegistrationBackend.MutationFailure(underlying: error,
                    rollbackStatus: "RESTORED", configurationChanged: "false")
            }
        }
    }

    static func rollback(
        _ plan: RightClickOnboardingPlan,
        applied: RightClickOnboardingApplied
    ) throws {
        guard plan.mutation.changed else {
            return
        }

        switch plan.mutation {
        case .json(let mutation):
            try RightClickJSONConfigBackend
                .rollbackTransaction(
                    mutation,
                    applied:
                        .init(
                            operation:
                                applied.operation,
                            backup:
                                applied.backup
                        )
                )

        case .native(let mutation):
            try RightClickNativeRegistrationBackend
                .rollback(
                    mutation
                )
        case .replacingNative(let previous, let replacement):
            try RightClickNativeRegistrationBackend.rollback(replacement)
            try RightClickNativeRegistrationBackend.rollback(previous)
        }
    }
}

enum RightClickJSONConfigBackend {
    struct MutationFailure: Error, CustomStringConvertible {
        let underlying: Error
        let rollbackStatus: String
        let configurationChanged: String
        var description: String {
            if rollbackStatus == "RESTORED" {
                return "Configuration postcondition failed; the original state was restored: \(underlying)"
            }
            return "Configuration postcondition failed; rollback could not safely restore the original state. "
                + "Newer client content was preserved; review retained private backups: \(underlying)"
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

    /// Keep every lexical ancestor for the symlink checks below. Foundation's
    /// standardizedFileURL can rewrite a parent alias such as /private/tmp,
    /// so normalize its directory representation without resolving that alias.
    static func configurationAncestors(_ file: URL, maximumDepth: Int = 512) throws -> [URL] {
        var path = file.standardizedFileURL
        var visited = Set<String>()
        var ancestors: [URL] = []
        while true {
            guard ancestors.count < maximumDepth, visited.insert(path.path).inserted else {
                throw RightClickOnboardingError("Configuration path exceeds the bounded ancestor inspection limit.")
            }
            ancestors.append(path)
            if path.path == "/" { break }
            let parent = URL(fileURLWithPath: path.path, isDirectory: true).deletingLastPathComponent()
            if parent.path == path.path { break }
            path = parent
        }
        return ancestors
    }

    static func inspectPath(_ file: URL) throws {
        let fm = FileManager.default
        for (index, path) in try configurationAncestors(file).enumerated() {
            let isTarget = index == 0
            if let attrs = try? fm.attributesOfItem(atPath: path.path) {
                let type = attrs[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    let destination = try? fm.destinationOfSymbolicLink(atPath: path.path)
                    let trustedMacOSVarAlias = path.path == "/var"
                        && (destination == "private/var" || destination == "/private/var")
                    guard trustedMacOSVarAlias else {
                        throw RightClickOnboardingError("Refusing a symbolic link in configuration path: \(path.path)")
                    }
                } else {
                    guard type == (isTarget ? .typeRegular : .typeDirectory) else {
                        throw RightClickOnboardingError("Unexpected file type in configuration path: \(path.path)")
                    }
                    if isTarget, let links = attrs[.referenceCount] as? NSNumber, links.intValue > 1 {
                        throw RightClickOnboardingError("Refusing a hard-linked configuration file.")
                    }
                }
            } else if fm.fileExists(atPath: path.path) {
                throw RightClickOnboardingError("Cannot inspect configuration path: \(path.path)")
            }
        }
    }

    static func snapshot(_ file: URL) throws -> Data? {
        try inspectPath(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 4 * 1024 * 1024 else {
            throw RightClickOnboardingError("Configuration exceeds the 4 MiB safety limit.")
        }
#if os(Windows)
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        let status = file.path.withCString { rc_host_read_file($0, 4 * 1024 * 1024, 0, &bytes, &count) }
        defer { if let bytes { rc_host_free(bytes) } }
        guard status == 0, let bytes else {
            throw RightClickOnboardingError("Could not safely read the selected configuration file.")
        }
        return Data(bytes: bytes, count: count)
#else
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw RightClickOnboardingError("Could not safely open the selected configuration file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1, information.st_uid == geteuid(),
              information.st_size >= 0, information.st_size <= 4 * 1024 * 1024 else {
            throw RightClickOnboardingError("The configuration file is not a bounded, owner-controlled regular file.")
        }
        var result = Data()
        while true {
            let chunk = try handle.read(upToCount: min(65_536, 4 * 1024 * 1024 + 1 - result.count)) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
            guard result.count <= 4 * 1024 * 1024 else {
                throw RightClickOnboardingError("Configuration exceeds the 4 MiB safety limit.")
            }
        }
        return result
#endif
    }

    static func plan(
        file: URL,
        containerKey: String,
        entryKey: String,
        desiredEntry: [String: Any],
        acceptedExistingEntries: [[String: Any]] = [],
        disconnect: Bool = false,
        replaceAcceptedExisting: Bool = false
    ) throws -> Plan {
        let original = try snapshot(file)
        var root: [String: Any] = [:]
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw RightClickOnboardingError("Configuration root must be a JSON object. Nothing was changed.")
            }
            try rejectDuplicateJSONKeys(original)
            root = object
        }

        var entries: [String: Any] = [:]
        if let present = root[containerKey] {
            guard let object = present as? [String: Any] else {
                throw RightClickOnboardingError("\(containerKey) must be a JSON object. Nothing was changed.")
            }
            entries = object
        }

        if let present = entries[entryKey] {
            guard let object = present as? NSDictionary else {
                throw conflictingEntry(entryKey)
            }
            let accepted = [desiredEntry] + acceptedExistingEntries
            guard accepted.contains(where: { object.isEqual(to: $0) }) else {
                throw conflictingEntry(entryKey)
            }
            if !disconnect {
                if !replaceAcceptedExisting || object.isEqual(to: desiredEntry) {
                    return Plan(file: file, original: original, replacement: original, operation: "ALREADY_CONFIGURED", changed: false)
                }
                entries[entryKey] = desiredEntry
            } else {
                entries.removeValue(forKey: entryKey)
            }
        } else {
            if disconnect {
                return Plan(file: file, original: original, replacement: original, operation: "ALREADY_DISCONNECTED", changed: false)
            }
            entries[entryKey] = desiredEntry
        }

        root[containerKey] = entries
        var replacement = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        replacement.append(0x0A)
        return Plan(file: file, original: original, replacement: replacement,
                    operation: disconnect ? "DISCONNECTED" : "CONFIGURED", changed: true)
    }

    private static func conflictingEntry(_ entryKey: String) -> RightClickOnboardingError {
        RightClickOnboardingError("A different \(entryKey) entry already exists. It was preserved; review it before switching builds.")
    }

    static func apply(_ plan: Plan, afterReplace: (() throws -> Void)? = nil) throws -> Applied {
        guard plan.changed else { return Applied(operation: plan.operation, backup: nil) }
        let fm = FileManager.default
        let directory = plan.file.deletingLastPathComponent()

        guard try snapshot(plan.file) == plan.original else {
            throw RightClickOnboardingError("Configuration changed after the preview. Nothing was written; run setup again.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: privateDirectoryAttributes)

        let lock = directory.appendingPathComponent(".rightclick-setup.lock")
        do {
            try fm.createDirectory(at: lock, withIntermediateDirectories: false, attributes: privateDirectoryAttributes)
        } catch {
            throw RightClickOnboardingError("Another setup lock exists or cannot be created. No configuration was written. Check \(lock.path).")
        }
        defer { try? fm.removeItem(at: lock) }

        guard try snapshot(plan.file) == plan.original else {
            throw RightClickOnboardingError("Configuration changed after the preview. Nothing was written; run setup again.")
        }

        var backup: URL?
        if let original = plan.original {
            let url = directory.appendingPathComponent("\(plan.file.lastPathComponent).rightclick-backup-\(UUID().uuidString)")
            try writePrivate(original, to: url)
            backup = url
        }

        let temporary = directory.appendingPathComponent(".rightclick-setup-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard let replacement = plan.replacement else {
            throw RightClickOnboardingError("Missing planned configuration.")
        }
        try writePrivate(replacement, to: temporary)

        guard try snapshot(plan.file) == plan.original else {
            throw RightClickOnboardingError("Configuration changed during setup. No replacement was made. A private backup may have been retained.")
        }

        try replacePrivate(temporary, with: plan.file)

        do {
            try afterReplace?()
            guard try snapshot(plan.file) == replacement else {
                throw RightClickOnboardingError("Configuration changed or could not be verified after writing.")
            }
        } catch {
            do {
                guard try snapshot(plan.file) == plan.replacement else {
                    throw RightClickOnboardingError("Configuration changed after setup; the newer state was preserved. Restore the retained private backup only after reviewing it.")
                }
                try rollback(plan)
            } catch let rollbackError {
                throw MutationFailure(underlying: rollbackError, rollbackStatus: "ROLLBACK_FAILED",
                    configurationChanged: "UNKNOWN")
            }
            throw MutationFailure(underlying: error, rollbackStatus: "RESTORED", configurationChanged: "false")
        }

        return Applied(operation: plan.operation, backup: backup)
    }

    static func rollbackTransaction(
        _ plan: Plan,
        applied: Applied
    ) throws {
        guard plan.changed else {
            return
        }

        if let replacement =
            plan.replacement
        {
            guard
                try snapshot(
                    plan.file
                ) == replacement
            else {
                throw RightClickOnboardingError(
                    "Configuration changed after the "
                    + "transaction applied it. Refusing "
                    + "to overwrite the newer state "
                    + "during rollback."
                )
            }
        }

        try rollback(plan)

        if let backup =
            applied.backup,
           FileManager.default
            .fileExists(
                atPath:
                    backup.path
            )
        {
            try FileManager.default
                .removeItem(
                    at: backup
                )
        }
    }

    private static func rollback(_ plan: Plan) throws {
        let fm = FileManager.default
        if let original = plan.original {
            let directory = plan.file.deletingLastPathComponent()
            let rollbackFile = directory.appendingPathComponent(".rightclick-rollback-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: rollbackFile) }
            try writePrivate(original, to: rollbackFile)
            try replacePrivate(rollbackFile, with: plan.file)
            guard try snapshot(plan.file) == original else {
                throw RightClickOnboardingError("Rollback could not be verified.")
            }
            return
        }

        if fm.fileExists(atPath: plan.file.path) { try fm.removeItem(at: plan.file) }
        guard !fm.fileExists(atPath: plan.file.path) else {
            throw RightClickOnboardingError("Rollback could not remove the newly created configuration.")
        }
    }

    static func rejectDuplicateJSONKeys(_ data: Data) throws {
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
                        throw RightClickOnboardingError("Invalid JSON string.")
                    }
                    return value
                }
                index += 1
            }
            throw RightClickOnboardingError("Unterminated JSON string.")
        }

        func visit(depth: Int) throws {
            guard depth < 128 else { throw RightClickOnboardingError("Configuration nesting exceeds the safety limit.") }
            skipSpace()
            guard index < bytes.count else { throw RightClickOnboardingError("Incomplete JSON configuration.") }
            switch bytes[index] {
            case 123:
                index += 1
                skipSpace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                var keys = Set<String>()
                while index < bytes.count {
                    skipSpace()
                    guard index < bytes.count && bytes[index] == 34 else { throw RightClickOnboardingError("Invalid JSON object key.") }
                    let key = try stringToken()
                    guard keys.insert(key).inserted else {
                        throw RightClickOnboardingError("Configuration has duplicate JSON object keys. Nothing was changed.")
                    }
                    skipSpace()
                    guard index < bytes.count && bytes[index] == 58 else { throw RightClickOnboardingError("Invalid JSON object separator.") }
                    index += 1
                    try visit(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw RightClickOnboardingError("Incomplete JSON object.") }
                    if bytes[index] == 125 { index += 1; return }
                    guard bytes[index] == 44 else { throw RightClickOnboardingError("Invalid JSON object delimiter.") }
                    index += 1
                }
            case 91:
                index += 1
                skipSpace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                while index < bytes.count {
                    try visit(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw RightClickOnboardingError("Incomplete JSON array.") }
                    if bytes[index] == 93 { index += 1; return }
                    guard bytes[index] == 44 else { throw RightClickOnboardingError("Invalid JSON array delimiter.") }
                    index += 1
                }
            case 34:
                _ = try stringToken()
            default:
                while index < bytes.count && ![UInt8(9), 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            }
        }

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        try visit(depth: 0)
        skipSpace()
        guard index == bytes.count else {
            throw RightClickOnboardingError("Could not safely inspect the JSON configuration.")
        }
    }

    private static var privateDirectoryAttributes: [FileAttributeKey: Any] {
#if os(Windows)
        return [:]
#else
        return [.posixPermissions: 0o700]
#endif
    }

    private static func replacePrivate(_ source: URL, with destination: URL) throws {
#if os(Windows)
        let status = source.path.withCString { from in
            destination.path.withCString { to in rc_host_replace_config(from, to) }
        }
#else
        let status = source.path.withCString { from in
            destination.path.withCString { to in rename(from, to) }
        }
#endif
        guard status == 0 else { throw RightClickOnboardingError("Atomic configuration replacement failed.") }
    }

    private static func writePrivate(_ data: Data, to file: URL) throws {
#if os(Windows)
        let status = data.withUnsafeBytes { bytes in
            file.path.withCString { path in
                rc_host_write_private_config(path, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        }
        guard status == 0 else { throw RightClickOnboardingError("Could not create an owner-only configuration file.") }
#else
        let fd = file.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else {
            throw RightClickOnboardingError("Could not create a private configuration file (errno \(errno)).")
        }
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
#endif
    }
}
