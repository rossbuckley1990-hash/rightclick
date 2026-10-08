#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import RightClickProtocol

public enum EnvironmentJournalError: Error { case storageUnavailable, limitExceeded }
private func environmentJournalDigest(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
}

/// Protected write-ahead storage uses the existing Link ledger custody rules.
/// Each successful transaction fsyncs the state before its caller may dispatch.
/// Missing history, replacement, unsafe permissions or corrupt data denies work.
public final class EnvironmentJournal<State: Codable>: @unchecked Sendable {
    private struct Document: Codable { let version: Int; let identity: String; var state: State }
    private let lock = NSLock()
    private let directory: URL
    private let directoryFD: Int32
    private let parentFD: Int32
    private let lockFD: Int32
    private let runtimeID: String
    private let maximumBytes = 2_097_152
    public init(directory: URL, identity: String, initial: State) throws {
        let runtimeID = identity
        guard (1...256).contains(runtimeID.utf8.count), !runtimeID.utf8.contains(0), directory.isFileURL,
              directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw EnvironmentJournalError.storageUnavailable
        }
        try Self.validateTrustedAncestors(directory.deletingLastPathComponent())
        let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        let created = mkdirat(parent, directory.lastPathComponent, 0o700) == 0
        guard created || errno == EEXIST else { close(parent); throw EnvironmentJournalError.storageUnavailable }
        let fd = openat(parent, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { close(parent); throw EnvironmentJournalError.storageUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFDIR, Self.hasProtectedACL(fd), !created || fsync(parent) == 0 else {
            close(fd); close(parent); throw EnvironmentJournalError.storageUnavailable
        }
        var writer = openat(fd, "environment.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let newLock = writer >= 0
        if writer < 0 && errno == EEXIST { writer = openat(fd, "environment.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard writer >= 0 else { close(fd); close(parent); throw EnvironmentJournalError.storageUnavailable }
        self.directory = directory; directoryFD = fd; parentFD = parent; lockFD = writer
        self.runtimeID = runtimeID
        // A throwing fully initialized class runs deinit and closes descriptors.
        try validateFile(writer, maximum: 0)
        guard flock(writer, LOCK_EX | LOCK_NB) == 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { _ = flock(writer, LOCK_UN) }
        try validateLocation(requireAnchor: false)
        let anchor = openat(parentFD, anchorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if anchor >= 0 {
            defer { close(anchor) }; try validateAnchor(anchor)
            guard !created else { throw EnvironmentJournalError.storageUnavailable }
        } else {
            guard errno == ENOENT, created, newLock else { throw EnvironmentJournalError.storageUnavailable }
            let anchor = openat(parentFD, anchorName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard anchor >= 0 else { throw EnvironmentJournalError.storageUnavailable }
            defer { close(anchor) }
            try writeAll(anchorData(), to: anchor)
            guard fsync(anchor) == 0, fsync(parentFD) == 0 else { throw EnvironmentJournalError.storageUnavailable }
        }
        let marker = openat(fd, "environment.initialized", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if marker >= 0 {
            defer { close(marker) }
            try validateMarker(marker)
            _ = try load()
        } else {
            // Existing lock/history without a marker is an ambiguous incomplete
            // provisioning attempt. Never reinterpret it as an empty ledger.
            guard errno == ENOENT, newLock, created else { throw EnvironmentJournalError.storageUnavailable }
            let marker = openat(fd, "environment.initialized", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard marker >= 0 else { throw EnvironmentJournalError.storageUnavailable }
            defer { close(marker) }
            try writeAll(Data(runtimeID.utf8), to: marker)
            guard fsync(marker) == 0, fsync(writer) == 0, fsync(fd) == 0 else { throw EnvironmentJournalError.storageUnavailable }
            try save(Document(version: 1, identity: runtimeID, state: initial))
        }
    }
    deinit { close(lockFD); close(directoryFD); close(parentFD) }


    public func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { _ = flock(lockFD, LOCK_UN) }
        try validateLocation()
        let marker = openat(directoryFD, "environment.initialized", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { close(marker) }; try validateMarker(marker)
        var document = try load()
        let result = try body(&document.state)
        try validateLocation()
        try save(document)
        return result
    }
    public func snapshot() throws -> State { try transaction { $0 } }
    private var anchorName: String { ".rightclick-environment-" + environmentJournalDigest(Data((runtimeID + "\0" + directory.lastPathComponent).utf8)) + ".initialized" }
    private func anchorData() throws -> Data {
        var info = stat(), writer = stat()
        guard fstat(directoryFD, &info) == 0, fstat(lockFD, &writer) == 0 else { throw EnvironmentJournalError.storageUnavailable }
        return Data((runtimeID + "\0" + String(info.st_dev) + ":" + String(info.st_ino) +
            "\0" + String(writer.st_dev) + ":" + String(writer.st_ino)).utf8)
    }
    private func validateAnchor(_ fd: Int32) throws {
        try validateFile(fd, maximum: 1024)
        guard try readAll(fd, maximum: 1024) == anchorData() else { throw EnvironmentJournalError.storageUnavailable }
    }
    private func validateLocation(requireAnchor: Bool = true) throws {
        guard directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path else { throw EnvironmentJournalError.storageUnavailable }
        try Self.validateTrustedAncestors(directory.deletingLastPathComponent())
        let currentParent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentParent >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { close(currentParent) }
        try sameFile(currentParent, parentFD)
        let current = openat(parentFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { close(current) }; try sameFile(current, directoryFD)
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              Self.hasProtectedACL(directoryFD) else { throw EnvironmentJournalError.storageUnavailable }
        let namedLock = openat(directoryFD, "environment.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard namedLock >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { close(namedLock) }
        try validateFile(lockFD, maximum: 0); try sameFile(namedLock, lockFD)
        if requireAnchor {
            let anchor = openat(parentFD, anchorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard anchor >= 0 else { throw EnvironmentJournalError.storageUnavailable }
            defer { close(anchor) }; try validateAnchor(anchor)
        }
    }
    /// Every ancestor must resist replacement by another local UID. Root-owned
    /// sticky temporary directories are safe; writable non-sticky directories
    /// and directories owned by other users are not trusted journal locations.
    private static func validateTrustedAncestors(_ parent: URL) throws {
        // Foundation keeps macOS system aliases such as /var in some URL
        // representations. Inspect the actual POSIX ancestry, never those aliases.
        guard let resolved = realpath(parent.path, nil) else { throw EnvironmentJournalError.storageUnavailable }
        defer { free(resolved) }
        let resolvedPath = String(cString: resolved)
        var path = "/"
        for component in ["/"] + (resolvedPath as NSString).pathComponents.dropFirst() {
            if component != "/" { path = (path as NSString).appendingPathComponent(component) }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw EnvironmentJournalError.storageUnavailable }
            var info = stat()
            let valid = fstat(fd, &info) == 0 && (info.st_uid == 0 || info.st_uid == geteuid()) &&
                (info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & 0o1000 != 0)) && hasProtectedACL(fd)
            close(fd)
            guard valid else { throw EnvironmentJournalError.storageUnavailable }
        }
    }
    private static func hasProtectedACL(_ fd: Int32) -> Bool {
        #if os(macOS)
        // macOS ACL grants need not appear in POSIX mode bits. Deny any
        // extended write/delete/security grant, including inherited grants.
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        var count = 0
        while acl_get_entry(acl, selector, &entry) == 0 {
            guard let entry, count < 1024 else { return false }
            count += 1; selector = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = acl_tag_t(rawValue: 0)
            guard acl_get_tag_type(entry, &tag) == 0 else { return false }
            if tag == ACL_EXTENDED_ALLOW {
                var permissions: acl_permset_t?
                guard acl_get_permset(entry, &permissions) == 0, let permissions else { return false }
                for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                    ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                    guard acl_get_perm_np(permissions, permission) == 0 else { return false }
                }
            }
        }
        return errno == EINVAL
        #else
        // Linux ACL effective write grants are reflected by the POSIX mask
        // bits already rejected above; no additional libacl dependency.
        return true
        #endif
    }
    private func sameFile(_ left: Int32, _ right: Int32) throws {
        var a = stat(), b = stat()
        guard fstat(left, &a) == 0, fstat(right, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw EnvironmentJournalError.storageUnavailable }
    }
    private func validateFile(_ fd: Int32, maximum: Int) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximum,
              Self.hasProtectedACL(fd) else { throw EnvironmentJournalError.storageUnavailable }
    }
    private func validateMarker(_ fd: Int32) throws {
        try validateFile(fd, maximum: 512)
        guard try readAll(fd, maximum: 512) == Data(runtimeID.utf8) else { throw EnvironmentJournalError.storageUnavailable }
    }

    private func load() throws -> Document {
        let fd = openat(directoryFD, "environment.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { close(fd) }; try validateFile(fd, maximum: maximumBytes)
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: readAll(fd, maximum: maximumBytes)) }
        catch { throw EnvironmentJournalError.storageUnavailable }
        guard document.version == 1, document.identity == runtimeID else { throw EnvironmentJournalError.storageUnavailable }
        return document
    }
    private func readAll(_ fd: Int32, maximum: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximum + 1), count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if n < 0 { if errno == EINTR { continue }; throw EnvironmentJournalError.storageUnavailable }
            if n == 0 { break }; count += n
        }
        guard count <= maximum else { throw EnvironmentJournalError.storageUnavailable }
        return Data(bytes.prefix(count))
    }
    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw EnvironmentJournalError.storageUnavailable }
                guard n > 0 else { throw EnvironmentJournalError.storageUnavailable }; offset += n
            }
        }
    }
    private func save(_ document: Document) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw EnvironmentJournalError.limitExceeded }
        // One fixed crash staging file; inspect before removing under the lock.
        let stale = openat(directoryFD, "environment.staging", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if stale >= 0 {
            defer { close(stale) }; try validateFile(stale, maximum: maximumBytes)
            guard unlinkat(directoryFD, "environment.staging", 0) == 0 else { throw EnvironmentJournalError.storageUnavailable }
        } else if errno != ENOENT { throw EnvironmentJournalError.storageUnavailable }
        let fd = openat(directoryFD, "environment.staging", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EnvironmentJournalError.storageUnavailable }
        defer { close(fd); _ = unlinkat(directoryFD, "environment.staging", 0) }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0, renameat(directoryFD, "environment.staging", directoryFD, "environment.json") == 0, fsync(directoryFD) == 0 else {
            throw EnvironmentJournalError.storageUnavailable
        }
    }
}
