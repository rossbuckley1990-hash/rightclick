import Foundation
import RightClickHostFiles

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
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";").map {
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
}
