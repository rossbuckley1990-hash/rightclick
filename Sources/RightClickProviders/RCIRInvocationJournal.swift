import RightClickProtocol
import Foundation
import RightClickHostFiles
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum RCIRJournalError: Error {
    case unsupportedHost, unsafeStorage, corruptStorage, storageFailure
    case invalidIdentity, invalidCheckpoint, duplicateInvocation, capacity
}

/// Durable dispatch identity and status only. This is neither an authority store
/// nor a task executor. Its closed data model cannot receive argument, credential,
/// resource, output, event or observation bytes. Digests are commitments, not
/// encryption or independent verification. Receipt archival remains separate.
final class RCIRInvocationJournal: @unchecked Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let executionID: UUID
        let taskID: UUID
        let leaseID: UUID
        let generation: Int64
        let bindingSHA256: String
        let requestSHA256: String
        let effects: [String]
        let startedAt: Int64
        let deadline: Int64

        init(executionID: String, task: RCIRTask) throws {
            guard let id = UUID(uuidString: executionID), id.uuidString == executionID else {
                throw RCIRJournalError.invalidIdentity
            }
            self.executionID = id; taskID = task.id; leaseID = task.lease.id
            generation = task.lease.binding.generation
            bindingSHA256 = CapabilityJSON.digest(task.lease.binding.bytes)
            requestSHA256 = CapabilityJSON.digest(task.lease.requestBytes)
            effects = Array(Set(task.lease.scopes.map { $0.effect.rawValue })).sorted()
            startedAt = task.startedAt; deadline = task.deadline
            try validate()
        }

        fileprivate func validate() throws {
            guard generation > 0, Self.digest(bindingSHA256), Self.digest(requestSHA256),
                  effects.count <= 7, effects == Array(Set(effects)).sorted(),
                  effects.allSatisfy({ ["read", "write", "delete", "execute", "publish", "subscribe", "securityChange"].contains($0) }),
                  startedAt >= 0, deadline > startedAt, deadline - startedAt <= 86_400_000 else {
                throw RCIRJournalError.invalidIdentity
            }
        }

        fileprivate static func digest(_ text: String) -> Bool {
            text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    struct Ticket: Equatable, Sendable { fileprivate let identity: Identity }

    private struct Entry: Codable, Equatable {
        let identity: Identity
        var phase: String
        var state: ExecutionState
        var outcome: String
        var sequence: Int64
        var updatedAt: Int64
        var receiptSHA256: String?

        var terminal: Bool { ["completed", "failed", "cancelled", "unknown", "notDispatched"].contains(phase) }
        // UNKNOWN is a terminal task state, but its mutation remains unresolved.
        // Do not forget that identity simply to admit new effects or expire TTL.
        var evictable: Bool { phase == "notDispatched" || (terminal && phase != "unknown" && outcome != "unknown" && state != .unknown) }
        func validate() throws {
            try identity.validate()
            guard ["dispatching", "started", "accepted", "working", "inputRequired", "cancelRequested",
                   "completed", "failed", "cancelled", "unknown", "notDispatched"].contains(phase),
                  [ExecutionState.started, .awaitingUser, .accepted, .succeeded, .failed, .cancelled, .unknown, .rejected].contains(state),
                  ["unverified", "succeeded", "failed", "unknown"].contains(outcome),
                  (0...1024).contains(sequence), updatedAt >= identity.startedAt,
                  receiptSHA256.map(Identity.digest) ?? true,
                  outcome != "succeeded" || (phase == "completed" && state == .succeeded),
                  state != .succeeded || outcome == "succeeded" else { throw RCIRJournalError.corruptStorage }
            let coherent: Bool
            switch phase {
            case "dispatching": coherent = state == .unknown && outcome == "unknown" && sequence == 0 && receiptSHA256 == nil
            case "started", "accepted", "working", "cancelRequested":
                coherent = state == .started && outcome == "unverified" && receiptSHA256 == nil
            case "inputRequired": coherent = state == .awaitingUser && outcome == "unverified" && receiptSHA256 == nil
            case "completed":
                coherent = (state == .accepted && outcome == "unverified") || (state == .succeeded && outcome == "succeeded") ||
                    (state == .failed && outcome == "failed")
            case "failed": coherent = state == .failed && outcome == "unverified"
            case "cancelled": coherent = state == .cancelled && outcome == "unverified"
            case "unknown": coherent = state == .unknown && outcome == "unknown"
            case "notDispatched": coherent = state == .rejected && outcome == "unknown" && sequence == 0 && receiptSHA256 == nil
            default: coherent = false
            }
            guard coherent else { throw RCIRJournalError.corruptStorage }
        }
    }

    private struct Document: Codable { let version: Int; let entries: [Entry] }
    private final class DirectoryHandle {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit {
#if os(macOS) || os(Linux)
            close(descriptor)
#endif
        }
    }
    private let lock = NSLock()
    private let directory: URL
    private let parentHandle: DirectoryHandle
    private let directoryHandle: DirectoryHandle
    private var directoryFD: Int32 { directoryHandle.descriptor }
    private let maximumEntries: Int
    private let maximumAgeMilliseconds: Int64
    private let maximumBytes: Int
    private static let header = Data("RIGHTCLICK-INVOCATION-JOURNAL-1\n".utf8)
    private static let marker = Data("RIGHTCLICK-JOURNAL-INITIALIZED-1\n".utf8)
#if os(macOS) || os(Linux)
    private var anchorEstablished = false
    private var initializedMarker: (device: dev_t, inode: ino_t)?
#endif
    // Internal fault seam for native filesystem races, never host/provider/AI
    // configuration. Production starts do not set this hook.
    var beforeCommit: (() throws -> Void)?

    /// Caller selects a canonical private directory with an existing parent.
    /// The POSIX backend pins every ancestor and its directory handle; all files
    /// must be owned regular single-link files without group/other access.
    init(directory: URL, maximumEntries: Int = 1024, maximumBytes: Int = 2_097_152,
         maximumAgeMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1000) throws {
        guard (1...4096).contains(maximumEntries), (1024...8_388_608).contains(maximumBytes),
              (1...2_592_000_000).contains(maximumAgeMilliseconds) else { throw RCIRJournalError.capacity }
        self.directory = directory; self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes; self.maximumAgeMilliseconds = maximumAgeMilliseconds
#if os(macOS) || os(Linux)
        let path = directory.path
        guard directory.isFileURL, RuntimePlatform.isAbsolutePath(path),
              !path.utf8.contains(0), path != "/", let slash = path.lastIndex(of: "/") else { throw RCIRJournalError.unsafeStorage }
        let parentPath = slash == path.startIndex ? "/" : String(path[..<slash])
        // Foundation URL canonicalization collapses /private/var into /var on
        // Darwin, even though /var is a symlink. Use the native physical path.
        guard Self.physicalPath(parentPath) == parentPath else { throw RCIRJournalError.unsafeStorage }
        let parent = try Self.openDirectory(parentPath)
        parentHandle = DirectoryHandle(parent)
        let name = String(path[path.index(after: slash)...])
        guard !name.isEmpty, name != ".", name != ".." else { throw RCIRJournalError.unsafeStorage }
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw RCIRJournalError.storageFailure }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RCIRJournalError.unsafeStorage }
        do {
            try Self.validateDirectory(fd)
            // Persist directory creation before the first dispatch reservation.
            guard fsync(parent) == 0 else { throw RCIRJournalError.storageFailure }
            directoryHandle = DirectoryHandle(fd)
        } catch { close(fd); throw error }
        // Validate any previous history eagerly. No corrupt-history fallback.
        _ = try transaction(now: 0, mutate: false) { _ in () }
#else
        throw RCIRJournalError.unsupportedHost
#endif
    }

    /// Write-ahead intent MUST become durable before final fresh consume/enqueue.
    /// A crash before enqueue is conservatively uncertain; this intent alone
    /// never establishes consumption, provider acceptance or a zero-effect claim.
    func reserveDispatch(_ identity: Identity, now: Int64) throws -> Ticket {
        try identity.validate()
        guard now >= identity.startedAt else { throw RCIRJournalError.invalidIdentity }
        return try transaction(now: now) { entries in
            guard entries[identity.executionID] == nil else { throw RCIRJournalError.duplicateInvocation }
            if entries.count >= self.maximumEntries {
                let terminal = entries.values.filter(\.evictable).sorted { $0.updatedAt < $1.updatedAt }
                guard let oldest = terminal.first else { throw RCIRJournalError.capacity }
                entries.removeValue(forKey: oldest.identity.executionID)
            }
            entries[identity.executionID] = Entry(identity: identity, phase: "dispatching", state: .unknown,
                outcome: "unknown", sequence: 0, updatedAt: now, receiptSHA256: nil)
            return Ticket(identity: identity)
        }
    }

    /// No raw receipt is retained. Late independent verification may strengthen
    /// completed/unverified into completed/succeeded or completed/failed.
    func checkpoint(_ ticket: Ticket, task: RCIRTask, record: ExecutionRecord, now: Int64) throws {
        guard task.id == ticket.identity.taskID, task.lease.id == ticket.identity.leaseID,
              try Identity(executionID: record.executionId, task: task) == ticket.identity else {
            throw RCIRJournalError.invalidCheckpoint
        }
        let payload = record.rcir?.signedReceipt?.payload ?? record.rcir?.receipt
        let receiptDigest = payload.flatMap { Data(base64Encoded: $0) }.map(CapabilityJSON.digest)
        try update(ticket, phase: task.phase.rawValue, state: record.state, outcome: task.outcome.rawValue,
                   sequence: task.sequence, receiptSHA256: receiptDigest, now: now)
    }

    func notDispatched(_ ticket: Ticket, now: Int64) throws {
        try update(ticket, phase: "notDispatched", state: .rejected, outcome: "unknown", sequence: 0,
                   receiptSHA256: nil, now: now)
    }

    private func update(_ ticket: Ticket, phase: String, state: ExecutionState, outcome: String,
                        sequence: Int64?, receiptSHA256: String?, now: Int64) throws {
        try transaction(now: now) { entries in
            guard var entry = entries[ticket.identity.executionID], entry.identity == ticket.identity,
                  sequence.map({ $0 >= entry.sequence }) ?? true else { throw RCIRJournalError.invalidCheckpoint }
            if entry.terminal {
                let same = entry.phase == phase && entry.state == state && entry.outcome == outcome
                let stronger = entry.phase == "completed" && entry.outcome == "unverified" && phase == "completed" &&
                    ["unverified", "succeeded", "failed"].contains(outcome)
                guard same || stronger else { throw RCIRJournalError.invalidCheckpoint }
            }
            entry.phase = phase; entry.state = state; entry.outcome = outcome
            entry.sequence = sequence ?? entry.sequence; entry.updatedAt = max(entry.updatedAt, now)
            entry.receiptSHA256 = receiptSHA256 ?? entry.receiptSHA256
            try entry.validate()
            entries[ticket.identity.executionID] = entry
        }
    }

    /// Safe summaries never reconstruct leases, callbacks, arguments or observer
    /// authority. Nonterminal history with no attached live session is UNKNOWN.
    func status(_ executionID: String, now: Int64) throws -> ExecutionRecord? {
        guard let id = UUID(uuidString: executionID), id.uuidString == executionID else { return nil }
        return try transaction(now: now, mutate: false) { entries in
            guard let entry = entries[id] else { return nil }
            let known = entry.terminal
            let identity = entry.identity
            // A retained success assertion without its signed bytes/evidence is
            // historical status, never a fresh verified-success result.
            let state: ExecutionState = known ? (entry.state == .succeeded ? .accepted : entry.state) : .unknown
            return ExecutionRecord(executionId: executionID, actionId: "", state: state,
                message: known
                    ? "Retained invocation status only; original receipt and outcome evidence are not archived."
                    : "Invocation survived restart without a live execution session. Its external outcome is unknown. Do not retry blindly.",
                events: ["task=\(identity.taskID.uuidString)", "lease=\(identity.leaseID.uuidString)",
                         "generation=\(identity.generation)", "requestSHA256=\(identity.requestSHA256)",
                         "lastDurablePhase=\(entry.phase)", "lastDurableState=\(entry.state.rawValue)", "lastDurableOutcome=\(entry.outcome)",
                         "receiptSHA256=\(entry.receiptSHA256 ?? "unavailable")"],
                evidence: OutcomeEvidence(type: "rcir_recovered_journal",
                    boundary: "Durable identity/status summary, not a signed receipt or current independent observation. No authority, remote polling or mutation replay is restored."))
        }
    }

    private func transaction<T>(now: Int64, mutate: Bool = true,
                                _ body: (inout [UUID: Entry]) throws -> T) throws -> T {
        guard now >= 0 else { throw RCIRJournalError.invalidCheckpoint }
        lock.lock(); defer { lock.unlock() }
#if os(macOS) || os(Linux)
        try validateCurrentDirectory()
        let fd = openat(directoryFD, "invocations.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RCIRJournalError.unsafeStorage }
        defer { close(fd) }
        try validateFile(fd, maximum: 0)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RCIRJournalError.storageFailure }
        defer { _ = flock(fd, LOCK_UN) }
        try validateCurrentDirectory()
        try validateWriterLock(fd)
        try ensureAnchor(writerLock: fd)
        let markerIdentity = try initializedMarkerIdentity()
        if let pinned = initializedMarker {
            guard let markerIdentity, markerIdentity.device == pinned.device, markerIdentity.inode == pinned.inode else {
                throw RCIRJournalError.corruptStorage
            }
        }
        let initialized = markerIdentity != nil
        let loaded = try load()
        guard !initialized || loaded != nil else { throw RCIRJournalError.corruptStorage }
        let original = loaded ?? [:]
        guard initialized || original.isEmpty else { throw RCIRJournalError.corruptStorage }
        if let markerIdentity { initializedMarker = markerIdentity }
        try removeAbandonedSnapshot(writerLock: fd)
        if !initialized {
            // Order matters: an interruption after the empty snapshot is safe;
            // an initialized marker with missing history must never mean empty.
            guard original.isEmpty else { throw RCIRJournalError.corruptStorage }
            if loaded == nil { try save(original, writerLock: fd) }
            try initializeMarker(writerLock: fd)
        }
        initializedMarker = try initializedMarkerIdentity()
        guard initializedMarker != nil else { throw RCIRJournalError.corruptStorage }
        var entries = original.filter { _, entry in
            // Unresolved dispatch identities are never evicted to admit new work.
            !entry.evictable || now < entry.updatedAt || now - entry.updatedAt < maximumAgeMilliseconds
        }
        let result = try body(&entries)
        if mutate && entries != original { try save(entries, writerLock: fd) }
        try validateWriterLock(fd)
        try validateAnchor(writerLock: fd)
        try validateInitializedMarker()
        return result
#else
        throw RCIRJournalError.unsupportedHost
#endif
    }

#if os(macOS) || os(Linux)
    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        let fd = path.withCString { rc_host_open_trusted_directory($0) }
        guard fd >= 0 else { throw RCIRJournalError.unsafeStorage }
        return fd
    }

    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw RCIRJournalError.unsafeStorage }
        try validateACL(fd)
    }

    private static func validateACL(_ fd: Int32) throws {
#if os(macOS)
        // Darwin extended allow entries can grant access beyond mode 0600/0700.
        // Refuse extended ACLs rather than interpreting or weakening host policy.
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw RCIRJournalError.unsafeStorage }
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
              errno == EINVAL else { throw RCIRJournalError.unsafeStorage }
#endif
    }

    private func validateCurrentDirectory() throws {
        try Self.validateDirectory(directoryFD)
        let parent = try Self.openDirectory(directory.deletingLastPathComponent().path)
        defer { close(parent) }
        var observedParent = stat(), pinnedParent = stat()
        guard fstat(parent, &observedParent) == 0, fstat(parentHandle.descriptor, &pinnedParent) == 0,
              observedParent.st_dev == pinnedParent.st_dev, observedParent.st_ino == pinnedParent.st_ino else {
            throw RCIRJournalError.unsafeStorage
        }
        var current = stat(), pinned = stat()
        guard lstat(directory.path, &current) == 0, fstat(directoryFD, &pinned) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino,
              Self.physicalPath(directory.path) == directory.path else { throw RCIRJournalError.unsafeStorage }
    }

    private func validateFile(_ fd: Int32, maximum: Int) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximum else { throw RCIRJournalError.unsafeStorage }
        try Self.validateACL(fd)
    }

    private func validateWriterLock(_ fd: Int32) throws {
        try validateNamedFile(fd, name: "invocations.lock", maximum: 0)
    }

    private func validateNamedFile(_ fd: Int32, name: String, maximum: Int) throws {
        try validateFile(fd, maximum: maximum)
        var pinned = stat(), named = stat()
        guard fstat(fd, &pinned) == 0,
              fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_dev == pinned.st_dev, named.st_ino == pinned.st_ino,
              named.st_nlink == 1 else { throw RCIRJournalError.unsafeStorage }
    }

    private var anchorName: String {
        ".rightclick-invocations-" + CapabilityJSON.digest(Data(directory.lastPathComponent.utf8)) + ".initialized"
    }
    private func anchorData(writerLock: Int32) throws -> Data {
        var child = stat(), writer = stat()
        guard fstat(directoryFD, &child) == 0, fstat(writerLock, &writer) == 0 else {
            throw RCIRJournalError.unsafeStorage
        }
        return Data(("RIGHTCLICK-JOURNAL-ANCHOR-1\n" + String(child.st_dev) + ":" + String(child.st_ino) +
            "\n" + String(writer.st_dev) + ":" + String(writer.st_ino)).utf8)
    }
    private func ensureAnchor(writerLock: Int32) throws {
        let parent = parentHandle.descriptor
        let existing = openat(parent, anchorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let expected = try anchorData(writerLock: writerLock)
        if existing >= 0 {
            defer { close(existing) }
            try validateFile(existing, maximum: 1024)
            var buffer = [UInt8](repeating: 0, count: 1025)
            let count = buffer.withUnsafeMutableBytes { read(existing, $0.baseAddress!, $0.count) }
            guard count >= 0, Data(buffer.prefix(count)) == expected else { throw RCIRJournalError.corruptStorage }
            var pinned = stat(), named = stat()
            guard fstat(existing, &pinned) == 0, fstatat(parent, anchorName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino else { throw RCIRJournalError.unsafeStorage }
            anchorEstablished = true
            return
        }
        guard !anchorEstablished, errno == ENOENT, try initializedMarkerIdentity() == nil, try load() == nil,
              try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["invocations.lock"] else {
            throw RCIRJournalError.corruptStorage
        }
        let created = openat(parent, anchorName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard created >= 0 else { throw RCIRJournalError.unsafeStorage }
        defer { close(created) }
        try expected.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(created, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RCIRJournalError.storageFailure }
                offset += count
            }
        }
        try validateFile(created, maximum: 1024)
        guard fsync(created) == 0, fsync(parent) == 0 else { throw RCIRJournalError.storageFailure }
        anchorEstablished = true
        try validateAnchor(writerLock: writerLock)
    }

    /// Once initialized, losing the sibling anchor is corruption, never a fresh journal.
    private func validateAnchor(writerLock: Int32) throws {
        guard anchorEstablished else { throw RCIRJournalError.corruptStorage }
        // ensureAnchor cannot create after anchorEstablished; it also rechecks the
        // pinned directory and writer identity encoded in the persisted anchor.
        try ensureAnchor(writerLock: writerLock)
    }

    private func initializedMarkerIdentity() throws -> (device: dev_t, inode: ino_t)? {
        let fd = openat(directoryFD, "initialized", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RCIRJournalError.unsafeStorage
        }
        defer { close(fd) }
        try validateFile(fd, maximum: Self.marker.count)
        var bytes = [UInt8](repeating: 0, count: Self.marker.count + 1), count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if n < 0 { if errno == EINTR { continue }; throw RCIRJournalError.storageFailure }
            if n == 0 { break }; count += n
        }
        guard Data(bytes.prefix(count)) == Self.marker else { throw RCIRJournalError.corruptStorage }
        var pinned = stat(), named = stat()
        guard fstat(fd, &pinned) == 0, fstatat(directoryFD, "initialized", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == pinned.st_dev, named.st_ino == pinned.st_ino, named.st_nlink == 1 else {
            throw RCIRJournalError.unsafeStorage
        }
        return (pinned.st_dev, pinned.st_ino)
    }

    private func validateInitializedMarker() throws {
        guard let pinned = initializedMarker else { return }
        guard let current = try initializedMarkerIdentity(), current.device == pinned.device, current.inode == pinned.inode else {
            throw RCIRJournalError.corruptStorage
        }
    }

    private func initializeMarker(writerLock: Int32) throws {
        try validateWriterLock(writerLock)
        let fd = openat(directoryFD, "initialized", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RCIRJournalError.storageFailure }
        defer { close(fd) }
        try Self.marker.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw RCIRJournalError.storageFailure }
                guard n > 0 else { throw RCIRJournalError.storageFailure }; offset += n
            }
        }
        guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw RCIRJournalError.storageFailure }
        try validateWriterLock(writerLock)
    }

    /// One fixed private staging file bounds crash leftovers to one snapshot.
    /// Only a protected regular single-link file is eligible for cleanup, and
    /// only while holding the same named writer lock as the committed history.
    private func removeAbandonedSnapshot(writerLock: Int32) throws {
        let fd = openat(directoryFD, "invocations.tmp", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return }
            throw RCIRJournalError.unsafeStorage
        }
        defer { close(fd) }
        try validateFile(fd, maximum: maximumBytes)
        var pinned = stat(), named = stat()
        guard fstat(fd, &pinned) == 0, fstatat(directoryFD, "invocations.tmp", &named, AT_SYMLINK_NOFOLLOW) == 0,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino, named.st_nlink == 1 else {
            throw RCIRJournalError.unsafeStorage
        }
        try validateWriterLock(writerLock)
        try validateInitializedMarker()
        guard unlinkat(directoryFD, "invocations.tmp", 0) == 0, fsync(directoryFD) == 0 else {
            throw RCIRJournalError.storageFailure
        }
    }

    private func encode(_ entries: [UUID: Entry]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(version: 1, entries: entries.values.sorted {
            $0.identity.executionID.uuidString < $1.identity.executionID.uuidString
        }))
    }

    private func load() throws -> [UUID: Entry]? {
        let fd = openat(directoryFD, "invocations.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RCIRJournalError.unsafeStorage
        }
        defer { close(fd) }
        try validateFile(fd, maximum: maximumBytes)
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1), count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if n < 0 { if errno == EINTR { continue }; throw RCIRJournalError.storageFailure }
            if n == 0 { break }; count += n
        }
        let data = Data(bytes.prefix(count))
        guard count <= maximumBytes, data.starts(with: Self.header), data.count > Self.header.count + 65 else {
            throw RCIRJournalError.corruptStorage
        }
        let payload = Data(data.dropFirst(Self.header.count).dropLast(65))
        let trailer = Data(data.suffix(65))
        guard trailer == Data(("\n" + CapabilityJSON.digest(payload)).utf8) else { throw RCIRJournalError.corruptStorage }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: payload) }
        catch { throw RCIRJournalError.corruptStorage }
        guard document.version == 1, document.entries.count <= maximumEntries else { throw RCIRJournalError.corruptStorage }
        var entries: [UUID: Entry] = [:]
        for entry in document.entries {
            try entry.validate()
            guard entries[entry.identity.executionID] == nil else { throw RCIRJournalError.corruptStorage }
            entries[entry.identity.executionID] = entry
        }
        // Reject unknown fields, duplicate keys and noncanonical framing even
        // when JSONDecoder would otherwise silently discard the extra material.
        guard try encode(entries) == payload else { throw RCIRJournalError.corruptStorage }
        return entries
    }

    private func save(_ entries: [UUID: Entry], writerLock: Int32) throws {
        let payload = try encode(entries)
        let data = Self.header + payload + Data(("\n" + CapabilityJSON.digest(payload)).utf8)
        guard entries.count <= maximumEntries, data.count <= maximumBytes else { throw RCIRJournalError.capacity }
        let name = "invocations.tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RCIRJournalError.storageFailure }
        defer { close(fd); _ = unlinkat(directoryFD, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw RCIRJournalError.storageFailure }
                guard n > 0 else { throw RCIRJournalError.storageFailure }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw RCIRJournalError.storageFailure }
        try beforeCommit?()
        try validateCurrentDirectory()
        try validateWriterLock(writerLock)
        try validateAnchor(writerLock: writerLock)
        try validateInitializedMarker()
        // The pathname being renamed must still name the private inode we
        // wrote and synced, rather than a substituted file or symlink.
        try validateNamedFile(fd, name: name, maximum: maximumBytes)
        guard renameat(directoryFD, name, directoryFD, "invocations.json") == 0, fsync(directoryFD) == 0 else {
            throw RCIRJournalError.storageFailure
        }
        try validateNamedFile(fd, name: "invocations.json", maximum: maximumBytes)
        try validateWriterLock(writerLock)
        try validateAnchor(writerLock: writerLock)
    }
#endif
}

/// Operator-selected storage only. No automatic default directory or plaintext
/// authority fallback. Shared objects serialize callers; the file lock serializes
/// separate processes without waiting or treating another process as recoverable.
enum RCIRJournalConfiguration {
    static let checkpointFailure = "Durable status checkpoint failed. The earlier dispatch intent remains uncertain on restart; current outcome evidence is preserved."
    private static let lock = NSLock()
    private static var journals: [String: RCIRInvocationJournal] = [:]
    static func load() throws -> RCIRInvocationJournal? {
        guard let path = ProcessInfo.processInfo.environment["RIGHTCLICK_INVOCATION_JOURNAL"] else { return nil }
        guard !path.isEmpty, RuntimePlatform.isAbsolutePath(path) else { throw RCIRJournalError.unsafeStorage }
        lock.lock(); defer { lock.unlock() }
        if let journal = journals[path] { return journal }
        guard journals.count < 64 else { throw RCIRJournalError.capacity }
        let journal = try RCIRInvocationJournal(directory: URL(fileURLWithPath: path, isDirectory: true))
        journals[path] = journal
        return journal
    }
    static var volatileBoundary: String {
#if os(Windows)
        "Durable invocation journal is unavailable on Windows; this execution has volatile history."
#else
        "Durable invocation journal is not enabled; this execution has volatile history."
#endif
    }
}
