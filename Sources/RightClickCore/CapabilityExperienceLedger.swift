import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Advisory, payload-free experience. This is not an execution journal or an authority store.
public enum CapabilityExperienceOutcome: String, Codable, Sendable {
    case acceptedUnverified, predicatesVerified, failed, unknown
}

public struct CapabilityExperienceEntry: Codable, Equatable, Sendable {
    public let executionID: UUID
    public let contractKey: String
    public let outcome: CapabilityExperienceOutcome
    public let observedAt: Date
}

public enum CapabilityExperienceError: Error {
    case invalidKey, invalidBounds, unsafeStorage, corruptStorage, storageFailure
}

/// Bounded, local, multi-process-safe storage. No requests, outputs, credentials,
/// provider prose or executable recipes are accepted by this API.
public final class CapabilityExperienceLedger: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let entries: [CapabilityExperienceEntry]
    }
    private let lock = NSLock()
    private var memory: [UUID: CapabilityExperienceEntry] = [:]
    private let directoryFD: Int32?
    public let maximumEntries: Int
    public let maximumAge: TimeInterval
    private let maximumBytes = 524_288

    /// A nil directory uses memory only. A disk directory must have an existing,
    /// canonical parent, be owned by this user, and have no group/other access.
    public init(directory: URL? = nil, maximumEntries: Int = 512,
                maximumAge: TimeInterval = 7 * 24 * 60 * 60) throws {
        guard (1...1024).contains(maximumEntries), maximumAge.isFinite,
              maximumAge > 0, maximumAge <= 30 * 24 * 60 * 60 else {
            throw CapabilityExperienceError.invalidBounds
        }
        self.maximumEntries = maximumEntries
        self.maximumAge = maximumAge
        guard let directory else { directoryFD = nil; return }
        guard directory.isFileURL,
              directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw CapabilityExperienceError.unsafeStorage
        }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw CapabilityExperienceError.storageFailure
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CapabilityExperienceError.unsafeStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            close(fd)
            throw CapabilityExperienceError.unsafeStorage
        }
        directoryFD = fd
    }

    deinit { if let directoryFD { close(directoryFD) } }

    public func entries(now: Date = Date()) throws -> [CapabilityExperienceEntry] {
        try transaction(now: now) { $0.values.sorted { $0.executionID.uuidString < $1.executionID.uuidString } }
    }

    public func record(executionID: UUID, contractKey: String,
                       outcome: CapabilityExperienceOutcome, now: Date = Date()) throws {
        guard Self.validKey(contractKey) else { throw CapabilityExperienceError.invalidKey }
        try transaction(now: now) { records in
            if let old = records[executionID] {
                guard old.contractKey == contractKey else { throw CapabilityExperienceError.invalidKey }
                // Repeated callbacks are one run. A late acceptance callback must not
                // erase a stronger observation already made for this execution.
                if old.outcome == outcome || (outcome == .acceptedUnverified &&
                    (old.outcome == .predicatesVerified || old.outcome == .failed)) { return }
            }
            records[executionID] = CapabilityExperienceEntry(executionID: executionID,
                contractKey: contractKey, outcome: outcome, observedAt: now)
        }
    }

    public func forgetAll() throws {
        try transaction(now: Date()) { $0.removeAll() }
    }

    private static func validKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func transaction<T>(now: Date,
        _ body: (inout [UUID: CapabilityExperienceEntry]) throws -> T) throws -> T {
        guard now.timeIntervalSince1970.isFinite else { throw CapabilityExperienceError.invalidBounds }
        lock.lock()
        defer { lock.unlock() }
        var lockFD: Int32 = -1
        if let directoryFD {
            lockFD = openat(directoryFD, "experience.lock",
                O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw CapabilityExperienceError.unsafeStorage }
            do { try validateFile(lockFD) } catch { close(lockFD); throw error }
            // Advisory memory must never hang execution behind another process.
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                close(lockFD)
                throw CapabilityExperienceError.storageFailure
            }
        }
        defer { if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); close(lockFD) } }
        let original = try load()
        var records = original.filter { _, entry in
            entry.observedAt <= now && now.timeIntervalSince(entry.observedAt) < maximumAge
        }
        trim(&records)
        let result = try body(&records)
        trim(&records)
        if records != original { try save(records) }
        memory = records
        return result
    }

    private func trim(_ records: inout [UUID: CapabilityExperienceEntry]) {
        if records.count > maximumEntries {
            let retained = records.values.sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
                return $0.executionID.uuidString < $1.executionID.uuidString
            }.prefix(maximumEntries)
            records = Dictionary(uniqueKeysWithValues: retained.map { ($0.executionID, $0) })
        }
    }

    private func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw CapabilityExperienceError.unsafeStorage
        }
    }

    private func load() throws -> [UUID: CapabilityExperienceEntry] {
        guard let directoryFD else { return memory }
        let fd = openat(directoryFD, "experience.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            throw CapabilityExperienceError.unsafeStorage
        }
        defer { close(fd) }
        try validateFile(fd)
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes {
                read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if n < 0 { if errno == EINTR { continue }; throw CapabilityExperienceError.storageFailure }
            if n == 0 { break }
            count += n
        }
        guard count <= maximumBytes else { throw CapabilityExperienceError.corruptStorage }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: Data(bytes.prefix(count))) }
        catch { throw CapabilityExperienceError.corruptStorage }
        guard document.version == 1, document.entries.count <= 1024 else {
            throw CapabilityExperienceError.corruptStorage
        }
        var result: [UUID: CapabilityExperienceEntry] = [:]
        for entry in document.entries {
            guard Self.validKey(entry.contractKey), entry.observedAt.timeIntervalSince1970.isFinite,
                  result[entry.executionID] == nil else { throw CapabilityExperienceError.corruptStorage }
            result[entry.executionID] = entry
        }
        return result
    }

    private func save(_ records: [UUID: CapabilityExperienceEntry]) throws {
        guard let directoryFD else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, entries: records.values.sorted {
            $0.executionID.uuidString < $1.executionID.uuidString
        }))
        guard data.count <= maximumBytes else { throw CapabilityExperienceError.corruptStorage }
        let name = "experience-" + UUID().uuidString + ".tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CapabilityExperienceError.storageFailure }
        defer { close(fd); _ = unlinkat(directoryFD, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw CapabilityExperienceError.storageFailure }
                guard n > 0 else { throw CapabilityExperienceError.storageFailure }
                offset += n
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, name, directoryFD, "experience.json") == 0 else {
            throw CapabilityExperienceError.storageFailure
        }
        guard fsync(directoryFD) == 0 else { throw CapabilityExperienceError.storageFailure }
    }
}
