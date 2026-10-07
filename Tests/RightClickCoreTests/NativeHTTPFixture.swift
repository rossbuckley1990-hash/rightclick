import Foundation
import RightClickHostFiles
@testable import RightClickCore

/// Test provisioning for the same real Python HTTP fixture on each native host.
/// This chooses an installed interpreter and protects fixture references using
/// the production host-file primitive; it does not fabricate runtime outcomes.
enum NativeHTTPFixture {
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
