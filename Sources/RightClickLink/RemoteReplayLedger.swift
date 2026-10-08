#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Durable admission, separate from advisory experience. Reservations precede
/// effects, survive restart, and are never evicted or retried automatically.
public final class RemoteReplayLedger: @unchecked Sendable {
    private struct Ownership: Codable {
        let executionID: String
        let callerDigest: String
        let capabilityDigest: String
        let capabilityIDHash: String
        let itemHash: String
        init(_ request: RemoteExecutionRequest) throws {
            guard let capabilityID = request.capabilityID, RemoteWire.isIdentifier(capabilityID),
                  let digest = request.capabilityDigest, RemoteWire.isDigest(digest),
                  RemoteWire.isDigest(request.callerID) else { throw RemoteLinkError.malformed }
            executionID = UUID().uuidString
            callerDigest = request.callerID
            capabilityDigest = digest
            capabilityIDHash = RemoteWire.digest(Data(capabilityID.utf8))
            itemHash = RemoteWire.digest(Data(request.item.utf8))
        }
        func permits(_ request: RemoteExecutionRequest) -> Bool {
            callerDigest == request.callerID && capabilityDigest == request.capabilityDigest &&
                capabilityIDHash == RemoteWire.digest(Data((request.capabilityID ?? "").utf8)) &&
                itemHash == RemoteWire.digest(Data(request.item.utf8)) &&
                (request.operation == .run || executionID == request.executionID)
        }
        var valid: Bool {
            UUID(uuidString: executionID)?.uuidString == executionID &&
                [callerDigest, capabilityDigest, capabilityIDHash, itemHash].allSatisfy(RemoteWire.isDigest)
        }
    }
    private struct Entry: Codable {
        let intentDigest: String
        let reservedAt: Int64
        var summary: RemoteExecutionSummary?
        var ownership: Ownership? = nil
    }
    private struct Document: Codable {
        var version = 1
        let runtimeID: String
        var lastTime: Int64 = 0
        var seen: Set<String> = []
        var entries: [String: Entry] = [:]
    }
    private let lock = NSLock()
    private let directory: URL
    private let directoryFD: Int32
    private let parentFD: Int32
    private let lockFD: Int32
    private let runtimeID: String
    private let maximumRequests: Int
    private let maximumBytes = 2_097_152

    /// The parent must already exist. Provisioning is explicit, never normal
    /// startup. Missing history after provisioning is a permanent denial.
    public init(directory: URL, runtimeID: String, maximumRequests: Int = 1024) throws {
        guard (1...1024).contains(maximumRequests), RemoteWire.isIdentifier(runtimeID), directory.isFileURL,
              directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw RemoteLinkError.storageUnavailable
        }
        try Self.validateTrustedAncestors(directory.deletingLastPathComponent())
        let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw RemoteLinkError.storageUnavailable }
        let created = mkdirat(parent, directory.lastPathComponent, 0o700) == 0
        guard created || errno == EEXIST else { close(parent); throw RemoteLinkError.storageUnavailable }
        let fd = openat(parent, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { close(parent); throw RemoteLinkError.storageUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFDIR, Self.hasProtectedACL(fd), !created || fsync(parent) == 0 else {
            close(fd); close(parent); throw RemoteLinkError.storageUnavailable
        }
        var writer = openat(fd, "link.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let newLock = writer >= 0
        if writer < 0 && errno == EEXIST { writer = openat(fd, "link.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard writer >= 0 else { close(fd); close(parent); throw RemoteLinkError.storageUnavailable }
        self.directory = directory; directoryFD = fd; parentFD = parent; lockFD = writer
        self.runtimeID = runtimeID; self.maximumRequests = maximumRequests
        // A throwing fully initialized class runs deinit and closes descriptors.
        try validateFile(writer, maximum: 0)
        guard flock(writer, LOCK_EX | LOCK_NB) == 0 else { throw RemoteLinkError.storageUnavailable }
        defer { _ = flock(writer, LOCK_UN) }
        try validateLocation(requireAnchor: false)
        let anchor = openat(parentFD, anchorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if anchor >= 0 {
            defer { close(anchor) }; try validateAnchor(anchor)
            guard !created else { throw RemoteLinkError.storageUnavailable }
        } else {
            guard errno == ENOENT, created, newLock else { throw RemoteLinkError.storageUnavailable }
            let anchor = openat(parentFD, anchorName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard anchor >= 0 else { throw RemoteLinkError.storageUnavailable }
            defer { close(anchor) }
            try writeAll(anchorData(), to: anchor)
            guard fsync(anchor) == 0, fsync(parentFD) == 0 else { throw RemoteLinkError.storageUnavailable }
        }
        let marker = openat(fd, "link.initialized", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if marker >= 0 {
            defer { close(marker) }
            try validateMarker(marker)
            _ = try load()
        } else {
            // Existing lock/history without a marker is an ambiguous incomplete
            // provisioning attempt. Never reinterpret it as an empty ledger.
            guard errno == ENOENT, newLock, created else { throw RemoteLinkError.storageUnavailable }
            let marker = openat(fd, "link.initialized", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard marker >= 0 else { throw RemoteLinkError.storageUnavailable }
            defer { close(marker) }
            try writeAll(Data(runtimeID.utf8), to: marker)
            guard fsync(marker) == 0, fsync(writer) == 0, fsync(fd) == 0 else { throw RemoteLinkError.storageUnavailable }
            try save(Document(runtimeID: runtimeID))
        }
    }
    deinit { close(lockFD); close(directoryFD); close(parentFD) }

    /// nil identifies the unique winner. An unresolved reservation is unknown,
    /// including after process death, and never enters the engine again.
    func reserve(_ request: RemoteExecutionRequest, now: Int64) throws -> RemoteExecutionSummary? {
        guard request.targetRuntimeID == runtimeID else { throw RemoteLinkError.wrongRuntime }
        let intent = try request.intentDigest()
        return try transaction { current in
            guard now >= current.lastTime else { throw RemoteLinkError.clockRollback }
            let requestKey = self.key("request", request.callerID, request.requestID.uuidString)
            let nonceKey = self.key("nonce", request.callerID, request.nonce.base64EncodedString())
            let idempotencyKey = self.key("intent", request.callerID, request.idempotencyKey.uuidString)
            guard !current.seen.contains(requestKey), !current.seen.contains(nonceKey) else { throw RemoteLinkError.replay }
            guard current.seen.count + 2 <= self.maximumRequests * 2 else { throw RemoteLinkError.limitExceeded }
            let previous = current.entries[idempotencyKey]
            if let previous, previous.intentDigest != intent { throw RemoteLinkError.idempotencyConflict }
            current.seen.formUnion([requestKey, nonceKey]); current.lastTime = now
            if previous == nil { current.entries[idempotencyKey] = Entry(intentDigest: intent, reservedAt: now, summary: nil, ownership: request.operation == .run ? try Ownership(request) : nil) }
            if let previous {
                return previous.summary ?? RemoteExecutionSummary(state: .unknown, policy: .evaluated,
                    providerAcceptance: .unknown, evidenceExecutionID: previous.ownership?.executionID,
                    lifecycle: [.requested, .authorized, .delivered, .unknown],
                    error: .executionUncertain, completedAtMilliseconds: previous.reservedAt)
            }
            return nil
        }
    }

    /// Ownership was persisted with the RUN intent before the engine can start.
    /// Historical pre-extension entries have no ownership and deny status safely.
    func executionID(forRun request: RemoteExecutionRequest) throws -> UUID {
        guard request.operation == .run else { throw RemoteLinkError.unauthorized }
        return try transaction { current in
            let key = self.key("intent", request.callerID, request.idempotencyKey.uuidString)
            guard let entry = current.entries[key], entry.intentDigest == (try request.intentDigest()),
                  let owner = entry.ownership, owner.permits(request),
                  let id = UUID(uuidString: owner.executionID) else { throw RemoteLinkError.unauthorized }
            return id
        }
    }
    func executionID(forStatus request: RemoteExecutionRequest) throws -> String {
        guard request.operation == .status else { throw RemoteLinkError.unauthorized }
        return try transaction { current in
            let owners = current.entries.values.compactMap(\.ownership).filter { $0.permits(request) }
            guard owners.count == 1 else { throw RemoteLinkError.unauthorized }
            return owners[0].executionID
        }
    }

    func complete(_ request: RemoteExecutionRequest, summary: RemoteExecutionSummary) throws {
        try summary.validate()
        try transaction { current in
            let idempotencyKey = self.key("intent", request.callerID, request.idempotencyKey.uuidString)
            guard var entry = current.entries[idempotencyKey], entry.summary == nil,
                  entry.intentDigest == (try request.intentDigest()), summary.completedAtMilliseconds >= entry.reservedAt
            else { throw RemoteLinkError.storageUnavailable }
            if let owner = entry.ownership, let returnedID = summary.evidenceExecutionID,
               returnedID != owner.executionID { throw RemoteLinkError.storageUnavailable }
            entry.summary = summary; current.entries[idempotencyKey] = entry
        }
    }

    private func key(_ domain: String, _ caller: String, _ value: String) -> String {
        RemoteWire.digest(Data((domain + "\0" + runtimeID + "\0" + caller + "\0" + value).utf8))
    }
    private func transaction<T>(_ body: (inout Document) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw RemoteLinkError.storageUnavailable }
        defer { _ = flock(lockFD, LOCK_UN) }
        try validateLocation()
        let marker = openat(directoryFD, "link.initialized", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard marker >= 0 else { throw RemoteLinkError.storageUnavailable }
        defer { close(marker) }; try validateMarker(marker)
        var document = try load()
        let result = try body(&document)
        try validateLocation()
        try save(document)
        return result
    }
    private var anchorName: String { ".rightclick-link-" + RemoteWire.digest(Data((runtimeID + "\0" + directory.lastPathComponent).utf8)) + ".initialized" }
    private func anchorData() throws -> Data {
        var info = stat(), writer = stat()
        guard fstat(directoryFD, &info) == 0, fstat(lockFD, &writer) == 0 else { throw RemoteLinkError.storageUnavailable }
        return Data((runtimeID + "\0" + String(info.st_dev) + ":" + String(info.st_ino) +
            "\0" + String(writer.st_dev) + ":" + String(writer.st_ino)).utf8)
    }
    private func validateAnchor(_ fd: Int32) throws {
        try validateFile(fd, maximum: 1024)
        guard try readAll(fd, maximum: 1024) == anchorData() else { throw RemoteLinkError.storageUnavailable }
    }
    private func validateLocation(requireAnchor: Bool = true) throws {
        guard directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path else { throw RemoteLinkError.storageUnavailable }
        try Self.validateTrustedAncestors(directory.deletingLastPathComponent())
        let currentParent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentParent >= 0 else { throw RemoteLinkError.storageUnavailable }
        defer { close(currentParent) }
        try sameFile(currentParent, parentFD)
        let current = openat(parentFD, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw RemoteLinkError.storageUnavailable }
        defer { close(current) }; try sameFile(current, directoryFD)
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              Self.hasProtectedACL(directoryFD) else { throw RemoteLinkError.storageUnavailable }
        let namedLock = openat(directoryFD, "link.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard namedLock >= 0 else { throw RemoteLinkError.storageUnavailable }
        defer { close(namedLock) }
        try validateFile(lockFD, maximum: 0); try sameFile(namedLock, lockFD)
        if requireAnchor {
            let anchor = openat(parentFD, anchorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard anchor >= 0 else { throw RemoteLinkError.storageUnavailable }
            defer { close(anchor) }; try validateAnchor(anchor)
        }
    }
    /// Every ancestor must resist replacement by another local UID. Root-owned
    /// sticky temporary directories are safe; writable non-sticky directories
    /// and directories owned by other users are not trusted journal locations.
    private static func validateTrustedAncestors(_ parent: URL) throws {
        // Foundation keeps macOS system aliases such as /var in some URL
        // representations. Inspect the actual POSIX ancestry, never those aliases.
        guard let resolved = realpath(parent.path, nil) else { throw RemoteLinkError.storageUnavailable }
        defer { free(resolved) }
        let resolvedPath = String(cString: resolved)
        var path = "/"
        for component in ["/"] + (resolvedPath as NSString).pathComponents.dropFirst() {
            if component != "/" { path = (path as NSString).appendingPathComponent(component) }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RemoteLinkError.storageUnavailable }
            var info = stat()
            let valid = fstat(fd, &info) == 0 && (info.st_uid == 0 || info.st_uid == geteuid()) &&
                (info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & 0o1000 != 0)) && hasProtectedACL(fd)
            close(fd)
            guard valid else { throw RemoteLinkError.storageUnavailable }
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
        guard fstat(left, &a) == 0, fstat(right, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw RemoteLinkError.storageUnavailable }
    }
    private func validateFile(_ fd: Int32, maximum: Int) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximum,
              Self.hasProtectedACL(fd) else { throw RemoteLinkError.storageUnavailable }
    }
    private func validateMarker(_ fd: Int32) throws {
        try validateFile(fd, maximum: 512)
        guard try readAll(fd, maximum: 512) == Data(runtimeID.utf8) else { throw RemoteLinkError.storageUnavailable }
    }
    private func load() throws -> Document {
        let fd = openat(directoryFD, "link.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteLinkError.storageUnavailable }
        defer { close(fd) }; try validateFile(fd, maximum: maximumBytes)
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: readAll(fd, maximum: maximumBytes)) }
        catch { throw RemoteLinkError.storageUnavailable }
        guard document.version == 1, document.runtimeID == runtimeID, document.lastTime >= 0,
              document.seen.count <= 2048, document.seen.count % 2 == 0,
              document.entries.count <= document.seen.count / 2, document.entries.count <= 1024,
              document.seen.allSatisfy(RemoteWire.isDigest),
              document.entries.allSatisfy({ RemoteWire.isDigest($0.key) && RemoteWire.isDigest($0.value.intentDigest) &&
                  $0.value.reservedAt > 0 && $0.value.reservedAt <= document.lastTime }) else { throw RemoteLinkError.storageUnavailable }
        var ownedIDs = Set<String>()
        for entry in document.entries.values {
            if let owner = entry.ownership {
                guard owner.valid, ownedIDs.insert(owner.executionID).inserted,
                      entry.summary?.evidenceExecutionID.map({ $0 == owner.executionID }) ?? true else {
                    throw RemoteLinkError.storageUnavailable
                }
            }
            if let summary = entry.summary {
                guard summary.completedAtMilliseconds >= entry.reservedAt else { throw RemoteLinkError.storageUnavailable }
                try summary.validate()
            }
        }
        return document
    }
    private func readAll(_ fd: Int32, maximum: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximum + 1), count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if n < 0 { if errno == EINTR { continue }; throw RemoteLinkError.storageUnavailable }
            if n == 0 { break }; count += n
        }
        guard count <= maximum else { throw RemoteLinkError.storageUnavailable }
        return Data(bytes.prefix(count))
    }
    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw RemoteLinkError.storageUnavailable }
                guard n > 0 else { throw RemoteLinkError.storageUnavailable }; offset += n
            }
        }
    }
    private func save(_ document: Document) throws {
        let data = try RemoteWire.encode(document)
        guard data.count <= maximumBytes else { throw RemoteLinkError.limitExceeded }
        // One fixed crash staging file; inspect before removing under the lock.
        let stale = openat(directoryFD, "link.staging", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if stale >= 0 {
            defer { close(stale) }; try validateFile(stale, maximum: maximumBytes)
            guard unlinkat(directoryFD, "link.staging", 0) == 0 else { throw RemoteLinkError.storageUnavailable }
        } else if errno != ENOENT { throw RemoteLinkError.storageUnavailable }
        let fd = openat(directoryFD, "link.staging", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteLinkError.storageUnavailable }
        defer { close(fd); _ = unlinkat(directoryFD, "link.staging", 0) }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0, renameat(directoryFD, "link.staging", directoryFD, "link.json") == 0, fsync(directoryFD) == 0 else {
            throw RemoteLinkError.storageUnavailable
        }
    }
}
