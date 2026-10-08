import Foundation

/// Test provisioning for the same real Python HTTP fixture on each native host.
/// This chooses an installed interpreter and protects fixture references using
/// the production host-file primitive; it does not fabricate runtime outcomes.
enum NativeHTTPFixture {
    private static let captureLock = NSLock()
    private static var captures: [ObjectIdentifier: StartupStderr] = [:]

    private final class StartupStderr: @unchecked Sendable {
        let pipe = Pipe()
        let directory: URL
        private let lock = NSLock()
        private var prefix = Data()
        private var totalBytes = 0
        private var retain = false

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-native-fixture-stderr-" + UUID().uuidString)
            try NativeHTTPFixture.createPrivateDirectory(directory)
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let bytes = handle.availableData
                lock.lock(); defer { lock.unlock() }
                totalBytes += bytes.count
                prefix.append(bytes.prefix(max(0, 65_536 - prefix.count)))
                if retain { persist() }
                if bytes.isEmpty { handle.readabilityHandler = nil }
            }
        }
        // Called with the lock held. Only owner-protected diagnostic files are
        // written; neither stderr, fixture arguments nor its path enters errors.
        private func persist() {
            let file = directory.appendingPathComponent("stderr.private")
            if FileManager.default.fileExists(atPath: file.path) {
                try? NativeHTTPFixture.replacePrivate(prefix, at: file)
            } else { try? NativeHTTPFixture.writePrivate(prefix, to: file) }
        }
        func requestRetention() {
            lock.lock(); defer { lock.unlock() }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? NativeHTTPFixture.createPrivateDirectory(directory)
            }
            retain = true; persist()
        }
        func complete() {
            lock.lock(); defer { lock.unlock() }
            if retain { persist() }
            else { try? FileManager.default.removeItem(at: directory) }
        }
        func closeParentWriter() { try? pipe.fileHandleForWriting.close() }
    }

    /// Drain stderr continuously into a bounded prefix so a failing child cannot
    /// block startup. Keep it privately only if readiness fails; never print it.
    static func captureStartupStderr(_ process: Process) throws {
        let capture = try StartupStderr()
        captureLock.lock(); captures[ObjectIdentifier(process)] = capture; captureLock.unlock()
        process.standardError = capture.pipe
        process.terminationHandler = { _ in capture.complete() }
    }

    static func runFixture(_ process: Process) throws {
        try captureStartupStderr(process)
        do {
            try process.run()
            captureLock.lock(); let capture = captures[ObjectIdentifier(process)]; captureLock.unlock()
            capture?.closeParentWriter()
        }
        catch {
            captureLock.lock(); let capture = captures.removeValue(forKey: ObjectIdentifier(process)); captureLock.unlock()
            capture?.requestRetention()
            capture?.closeParentWriter()
            throw error
        }
    }

    enum ReadinessError: Error {
        case exitedBeforeReadiness
        case invalidPortBeforeDeadline
    }
    /// A marker's existence is not readiness: a writer can create an empty
    /// file before completing its bytes. Bound both time and input size, and
    /// return only a decimal TCP port; never construct an incomplete URL.
    static func waitForPort(_ file: URL, process: Process, timeout: TimeInterval = 3) throws -> UInt16 {
        var ready = false
        defer {
            captureLock.lock(); let capture = captures.removeValue(forKey: ObjectIdentifier(process)); captureLock.unlock()
            if !ready { capture?.requestRetention() }
        }
        guard timeout > 0, timeout <= 3 else { throw ReadinessError.invalidPortBeforeDeadline }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard process.isRunning else { throw ReadinessError.exitedBeforeReadiness }
            if let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                // Five decimal digits plus CRLF is the longest valid marker.
                // Read one more byte so a valid prefix cannot hide trailing data.
                if let bytes = try? handle.read(upToCount: 8) {
                    let digits: Data.SubSequence
                    if bytes.suffix(2).elementsEqual([13, 10]) { digits = bytes.dropLast(2) }
                    else if bytes.last == 10 { digits = bytes.dropLast() }
                    else { digits = bytes[...] }
                    if !digits.isEmpty, digits.count <= 5,
                       digits.allSatisfy({ (48...57).contains($0) }),
                       let port = UInt16(String(decoding: digits, as: UTF8.self)), port > 0 {
                        ready = true; return port
                    }
                }
            }
            Thread.sleep(forTimeInterval: min(0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        throw ReadinessError.invalidPortBeforeDeadline
    }
    static func createPrivateDirectory(_ directory: URL) throws {
#if os(Windows)
        guard directory.path.withCString({ rc_host_create_private_directory($0) }) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
#else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
#endif
    }
    static func writePrivate(_ bytes: Data, to file: URL) throws {
#if os(Windows)
        let result = bytes.withUnsafeBytes { buffer in
            file.path.withCString { rc_host_create_private_file($0, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        }
        guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
#else
        try bytes.write(to: file, options: .withoutOverwriting)
        try protect(file)
#endif
    }
    static func python() throws -> URL {
#if os(Windows)
        // Windows environment names are case-insensitive; Foundation preserves
        // their spelling in this dictionary (for example, "Path").
        let environment = ProcessInfo.processInfo.environment
        let path = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let candidates = path.split(separator: ";").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("python.exe")
        }
        guard let result = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return result
#else
        return URL(fileURLWithPath: "/usr/bin/python3")
#endif
    }
    static func protect(_ file: URL, directory: Bool = false) throws {
#if os(Windows)
        guard file.path.withCString({ rc_host_harden_private($0, directory ? 1 : 0) }) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
#else
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: file.path)
#endif
    }
    static func release(_ file: URL) throws {
#if os(Windows)
        guard file.path.withCString({ rc_host_release_snapshot($0) }) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
#endif
    }
    static func remove(_ root: URL) throws {
        // A setup failure may occur before creating this fixture's root. This
        // cleanup guard preserves the original error rather than replacing it.
        guard FileManager.default.fileExists(atPath: root.path) else { return }
#if os(Windows)
        // Only fixture-owned regular files can have their private read-only
        // flag cleared; the production helper rejects redirects and other ACLs.
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                _ = file.path.withCString { rc_host_release_snapshot($0) }
            }
        }
#endif
        try FileManager.default.removeItem(at: root)
    }

    static func replacePrivate(_ bytes: Data, at file: URL) throws {
#if os(Windows)
        try release(file)
        try bytes.write(to: file)
        try protect(file)
#else
        try bytes.write(to: file)
#endif
    }

#if os(Windows)
    static func pythonClient(script: URL, directory: URL) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let programs = environment.first { $0.key.caseInsensitiveCompare("ProgramFiles(x86)") == .orderedSame }?.value ?? "C:\\Program Files (x86)"
        let whereTool = URL(fileURLWithPath: programs).appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
        let installed = try BoundedCapabilityProcess.run(executable: whereTool,
            arguments: ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
            timeout: 5, maximumBytes: 32_768)
        let installation = String(decoding: installed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard RuntimePlatform.isAbsolutePath(installation), !installation.contains("\""), !installation.contains("\n") else { throw RCIRError.unavailable }
        let setup = URL(fileURLWithPath: installation).appendingPathComponent("VC/Auxiliary/Build/vcvars64.bat")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = directory.appendingPathComponent("client-launcher.c"), header = directory.appendingPathComponent("windows-python-client-paths.h")
        let client = directory.appendingPathComponent("client.exe"), object = directory.appendingPathComponent("client.obj")
        func literal(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        try writePrivate(Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/windows-python-client-launcher.c")), to: source)
        let declaration = "#define RIGHTCLICK_FIXTURE_PYTHON L\"\(literal(try python().path))\"\n#define RIGHTCLICK_FIXTURE_SCRIPT L\"\(literal(script.path))\"\n"
        try writePrivate(Data(declaration.utf8), to: header)
        func native(_ file: URL) -> String { file.path.replacingOccurrences(of: "/", with: "\\") }
        let command = "call \"\(native(setup))\" > nul && cl /nologo /std:c17 \"\(native(source))\" /Fe:\"\(native(client))\" /Fo:\"\(native(object))\""
        try nativeCommand("cmd.exe", ["/d", "/s", "/c", command])
        guard FileManager.default.fileExists(atPath: client.path) else { throw RCIRError.unavailable }
        return client
    }
    static func nativeCommand(_ executable: String, _ arguments: [String]) throws {
        let system = ProcessInfo.processInfo.environment.first {
            $0.key.caseInsensitiveCompare("SystemRoot") == .orderedSame
        }?.value ?? "C:\\Windows"
        _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: system + "\\System32\\" + executable),
            arguments: arguments, timeout: 5, maximumBytes: 16_384)
    }
    static func junction(_ alias: URL, target: URL) throws {
        try nativeCommand("cmd.exe", ["/d", "/c", "mklink", "/J",
            alias.path.replacingOccurrences(of: "/", with: "\\"),
            target.path.replacingOccurrences(of: "/", with: "\\")])
    }
#endif
}
