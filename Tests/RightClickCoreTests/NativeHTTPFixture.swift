import Foundation
import RightClickHostFiles
@testable import RightClickCore

/// Test provisioning for the same real Python HTTP fixture on each native host.
/// This chooses an installed interpreter and protects fixture references using
/// the production host-file primitive; it does not fabricate runtime outcomes.
enum NativeHTTPFixture {
    enum PythonClientBootstrapStage: String {
        case installationQuery, installationValidation, interpreterSelection
        case ownedInputPreparation, nativeCompilation, outputValidation
    }
    struct PythonClientInstallationValidation: CustomStringConvertible {
        let empty: Bool
        let isAbsolute: Bool
        let containsQuote: Bool
        let containsEmbeddedLF: Bool
        let startsUTF8BOM: Bool
        var description: String {
            "empty=\(empty) isAbsolute=\(isAbsolute) containsQuote=\(containsQuote) containsEmbeddedLF=\(containsEmbeddedLF) startsUTF8BOM=\(startsUTF8BOM)"
        }
    }
    /// Test-bootstrap diagnostics contain fixed labels and process measurements
    /// only. Do not retain source paths, command arguments or compiler output.
    struct PythonClientBootstrapFailure: Error, CustomStringConvertible {
        let stage: PythonClientBootstrapStage
        let kind: String
        let process: BoundedCapabilityProcess.Diagnostic?
        let validation: PythonClientInstallationValidation?
        var description: String {
            "NativePythonClient stage=\(stage.rawValue) kind=\(kind) processOutcome=\(process?.outcome.rawValue ?? "none") started=\(process.map { String($0.started) } ?? "none") exit=\(process?.terminationStatus.map(String.init) ?? "none") stdoutBytes=\(process.map { String($0.stdoutBytes) } ?? "none") validation=[\(validation?.description ?? "none")]"
        }
    }
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
    struct CompilerInputs {
        let executable: URL, setup: URL, source: URL, header: URL, script: URL, batch: URL
        let client: URL, object: URL, installedQuery: URL, developerCommand: URL
        let packedArguments: [String], ownedArguments: [String]
        var frozenInputs: [(URL, Int)] {
            [(executable, 8_388_608), (setup, 1_048_576), (source, 65_536), (header, 32_768),
             (script, 1_048_576), (batch, 32_768), (installedQuery, 8_388_608), (developerCommand, 65_536)]
        }
    }

    /// Fixed test acquisition schema. The owned batch carries no agent/provider
    /// shell input; direct invocation arguments keep their usual runtime grammar.
    static func compilerInputs(script: URL, directory: URL) throws -> CompilerInputs {
        var stage = PythonClientBootstrapStage.installationQuery
        var diagnostic: BoundedCapabilityProcess.Diagnostic?
        var validation: PythonClientInstallationValidation?
        do {
            let environment = ProcessInfo.processInfo.environment
            let programs = environment.first { $0.key.caseInsensitiveCompare("ProgramFiles(x86)") == .orderedSame }?.value ?? "C:\\Program Files (x86)"
            let whereTool = URL(fileURLWithPath: programs).appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
            let installed = try BoundedCapabilityProcess.run(executable: whereTool,
                arguments: ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
                timeout: 5, maximumBytes: 32_768,
                hostContext: try TrustedHostProcessContext.resolving(.machineApplicationData),
                diagnostic: { diagnostic = $0 })
            stage = .installationValidation
            let installation = String(decoding: installed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            validation = .init(empty: installation.isEmpty, isAbsolute: RuntimePlatform.isAbsolutePath(installation),
                containsQuote: installation.contains("\""), containsEmbeddedLF: installation.contains("\n"),
                startsUTF8BOM: installed.prefix(3).elementsEqual([239, 187, 191]))
            guard RuntimePlatform.isAbsolutePath(installation), !installation.contains("\""), !installation.contains("\n") else { throw RCIRError.unavailable }
            let setup = URL(fileURLWithPath: installation).appendingPathComponent("VC/Auxiliary/Build/vcvars64.bat")
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = directory.appendingPathComponent("client-launcher.c"), header = directory.appendingPathComponent("windows-python-client-paths.h")
            let client = directory.appendingPathComponent("client.exe"), object = directory.appendingPathComponent("client.obj")
            func literal(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            stage = .interpreterSelection
            diagnostic = nil
            let interpreter = try python()
            stage = .ownedInputPreparation
            try writePrivate(Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/windows-python-client-launcher.c")), to: source)
            let declaration = "#define RIGHTCLICK_FIXTURE_PYTHON L\"\(literal(interpreter.path))\"\n#define RIGHTCLICK_FIXTURE_SCRIPT L\"\(literal(script.path))\"\n"
            try writePrivate(Data(declaration.utf8), to: header)
            func native(_ file: URL) throws -> String {
                let path = file.path.replacingOccurrences(of: "/", with: "\\")
                guard RuntimePlatform.isAbsolutePath(path),
                      !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      !path.contains("\""), !path.contains("%"), !path.contains("!") else { throw RCIRError.unavailable }
                return path
            }
            let command = "call \"\(try native(setup))\" > nul && cl /nologo /std:c17 \"\(try native(source))\" /Fe:\"\(try native(client))\" /Fo:\"\(try native(object))\""
            let developerCommand = URL(fileURLWithPath: installation).appendingPathComponent("Common7/Tools/VsDevCmd.bat")
            let developerBytes = try CapabilityArtifactSnapshot.read(source: developerCommand, maximum: 65_536)
            let developerText = String(decoding: developerBytes, as: UTF8.self)
            guard developerText.contains("if \"%VSCMD_SKIP_SENDTELEMETRY%\"==\"\""),
                  developerText.lowercased().contains("powershell") else { throw RCIRError.unavailable }
            let batch = directory.appendingPathComponent("compile-client.bat")
            let batchBody = "@echo off\r\nset \"VSCMD_SKIP_SENDTELEMETRY=1\"\r\n" + command + "\r\n"
            guard batchBody.utf8.allSatisfy({ $0 < 128 }) else { throw RCIRError.unavailable }
            try writePrivate(Data(batchBody.utf8), to: batch)
            let system = environment.first { $0.key.caseInsensitiveCompare("SystemRoot") == .orderedSame }?.value ?? "C:\\Windows"
            let executable = URL(fileURLWithPath: system + "\\System32\\cmd.exe")
            return CompilerInputs(executable: executable, setup: setup, source: source, header: header,
                script: script, batch: batch, client: client, object: object, installedQuery: whereTool,
                developerCommand: developerCommand, packedArguments: ["/d", "/s", "/c", command],
                ownedArguments: ["/d", "/c", try native(batch)])
        } catch {
            let kind = (error as? RCIRError).map { String(describing: $0) } ??
                (error as? CocoaError).map { "cocoa_" + String($0.code.rawValue) } ?? "other"
            throw PythonClientBootstrapFailure(stage: stage, kind: kind, process: diagnostic,
                validation: stage == .installationValidation ? validation : nil)
        }
    }

    static func isAMD64PE(_ bytes: Data) -> Bool {
        guard bytes.count >= 64, bytes.prefix(2).elementsEqual([77, 90]) else { return false }
        let offset = (0..<4).reduce(0) { $0 | (Int(bytes[60 + $1]) << (8 * $1)) }
        return offset <= bytes.count - 6 && bytes[offset..<(offset + 6)].elementsEqual([80, 69, 0, 0, 100, 134])
    }

    static func pythonClient(script: URL, directory: URL) throws -> URL {
        let inputs = try compilerInputs(script: script, directory: directory)
        var stage = PythonClientBootstrapStage.nativeCompilation
        var diagnostic: BoundedCapabilityProcess.Diagnostic?
        do {
            stage = .nativeCompilation
            _ = try BoundedCapabilityProcess.run(executable: inputs.executable, arguments: inputs.ownedArguments,
                timeout: 10, maximumBytes: 16_384,
                hostContext: try TrustedHostProcessContext.resolving(.systemExecutableSearch), diagnostic: { diagnostic = $0 })
            stage = .outputValidation
            let bytes = try CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608)
            guard isAMD64PE(bytes) else { throw RCIRError.unavailable }
            return inputs.client
        } catch {
            let kind = (error as? RCIRError).map { String(describing: $0) } ??
                (error as? CocoaError).map { "cocoa_" + String($0.code.rawValue) } ?? "other"
            throw PythonClientBootstrapFailure(stage: stage, kind: kind, process: diagnostic,
                validation: nil)
        }
    }
    static func nativeCommand(_ executable: String, _ arguments: [String],
                              diagnostic: ((BoundedCapabilityProcess.Diagnostic) -> Void)? = nil) throws {
        let system = ProcessInfo.processInfo.environment.first {
            $0.key.caseInsensitiveCompare("SystemRoot") == .orderedSame
        }?.value ?? "C:\\Windows"
        _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: system + "\\System32\\" + executable),
            arguments: arguments, timeout: 5, maximumBytes: 16_384, diagnostic: diagnostic)
    }
    static func junction(_ alias: URL, target: URL) throws {
        try nativeCommand("cmd.exe", ["/d", "/c", "mklink", "/J",
            alias.path.replacingOccurrences(of: "/", with: "\\"),
            target.path.replacingOccurrences(of: "/", with: "\\")])
    }
#endif
}
