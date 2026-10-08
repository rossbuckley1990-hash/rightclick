import RightClickProtocol
import Foundation

/// Bounded host-private reuse of executable bytes, never credentials, signing
/// keys, declarations, policy or issuer responses. Reuse still reads and hashes
/// the full current source, including a final check before returning a snapshot.
/// External contracts keep their own immutable incarnation alive independently
/// of this cache's entry/byte/retention limits.
final class CapabilityExecutableSnapshotPool {
    static let shared = CapabilityExecutableSnapshotPool()
    private struct Entry {
        let snapshot: CapabilityArtifactSnapshot
        let bytes: Int
        let createdAt: TimeInterval
        var lastUsed: TimeInterval
    }
    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let retention: TimeInterval
    private let clock: () -> TimeInterval
    private var expiryTimer: DispatchSourceTimer?

    init(maximumEntries: Int = 4, maximumBytes: Int = 268_435_456, retention: TimeInterval = 30,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes
        self.retention = retention; self.clock = clock
    }
    deinit { expiryTimer?.cancel() }

    private func scheduleExpiryLocked() {
        guard let earliest = entries.values.map(\.createdAt).min() else {
            expiryTimer?.cancel(); expiryTimer = nil; return
        }
        if expiryTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.setEventHandler { [weak self] in self?.expireEntries() }
            expiryTimer = timer; timer.resume()
        }
        expiryTimer?.schedule(deadline: .now() + max(0, earliest + retention - clock()))
    }
    private func expireEntries() {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if now.isFinite, now >= 0 {
            entries = entries.filter { now >= $0.value.createdAt && now - $0.value.createdAt < retention }
        } else { entries.removeAll() }
        scheduleExpiryLocked()
    }

    func acquire(executable source: URL, maximum: Int,
                 beforeReturn: (() -> Void)? = nil) throws -> CapabilityArtifactSnapshot {
        guard (1...4).contains(maximumEntries), (1...268_435_456).contains(maximumBytes),
            retention.isFinite, retention > 0, retention <= 30,
            (1...268_435_456).contains(maximum), source.isFileURL,
            RuntimePlatform.isAbsolutePath(source.path) else { throw RCIRError.invalidLimit }
        let now = clock()
        guard now.isFinite, now >= 0 else { throw RCIRError.invalidLimit }
        // Foundation may rewrite system aliases when a file disappears.
        // Cache the exact host-selected path bytes; normalization cannot keep a
        // withdrawn source alive or collapse distinct Unicode file identities.
        let key = Data(source.path.utf8)
        let snapshot: CapabilityArtifactSnapshot
        lock.lock()
        do {
            entries = entries.filter { now >= $0.value.createdAt && now - $0.value.createdAt < retention }
            guard FileManager.default.isExecutableFile(atPath: source.path) else {
                entries.removeValue(forKey: key); scheduleExpiryLocked(); throw RCIRError.unavailable
            }
            if var entry = entries[key], entry.snapshot.sourceStillMatches() {
                guard entry.bytes <= maximum else { throw RCIRError.invalidLimit }
                entry.lastUsed = now; entries[key] = entry; snapshot = entry.snapshot
            } else {
                entries.removeValue(forKey: key)
                let acquired = try CapabilityArtifactSnapshot(source: source,
                    maximum: min(maximum, maximumBytes), executable: true)
                // Size is used only to account for sealed private storage, never
                // as source identity; acquisition/return use full byte hashes.
                guard let bytes = try FileManager.default.attributesOfItem(atPath: acquired.file.path)[.size] as? Int,
                    bytes >= 0, bytes <= maximumBytes else { throw RCIRError.invalidLimit }
                while entries.count >= maximumEntries || entries.values.reduce(0, { $0 + $1.bytes }) + bytes > maximumBytes {
                    guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else {
                        throw RCIRError.invalidLimit
                    }
                    entries.removeValue(forKey: oldest)
                }
                entries[key] = Entry(snapshot: acquired, bytes: bytes, createdAt: now, lastUsed: now)
                snapshot = acquired
            }
            scheduleExpiryLocked()
            lock.unlock()
        } catch { lock.unlock(); throw error }
        beforeReturn?()
        guard FileManager.default.isExecutableFile(atPath: source.path), snapshot.sourceStillMatches() else {
            lock.lock()
            if entries[key]?.snapshot === snapshot { entries.removeValue(forKey: key) }
            scheduleExpiryLocked()
            lock.unlock()
            throw RCIRError.unavailable
        }
        return snapshot
    }

    var retainedBudget: (entries: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (entries.count, entries.values.reduce(0, { $0 + $1.bytes }))
    }
}
