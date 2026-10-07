import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CapabilitySource: String, Codable, Sendable {
    case sharingService = "sharing_service"
    case service = "service"
    case actionExtension = "action_extension"
    case system = "system"
}

public enum CapabilitySafety: String, Codable, Sendable {
    case read
    case localReversible = "local_reversible"
    case localWrite = "local_write"
    case externalShare = "external_share"
    case destructive
    case financial
    case securityChange = "security_change"
    case codeExecution = "code_execution"
    case unknown
}

public enum CapabilityInvocation: String, Codable, Sendable {
    case direct
    case interactive
    case unsupported
}

public enum SupportLevel: String, Codable, Sendable {
    case publicSupported = "public_supported"
    case publicDeprecated = "public_deprecated"
    case undocumentedReadOnly = "undocumented_read_only"
    case experimental
}

public struct CapabilityProvider: Codable, Sendable, Equatable {
    public var name: String?
    public var bundleIdentifier: String?

    public init(name: String? = nil, bundleIdentifier: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct Capability: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var source: CapabilitySource
    public var reflectorID: String
    public var provider: CapabilityProvider?
    public var inputs: [String]
    public var output: [String]
    public var safety: CapabilitySafety
    public var invocation: CapabilityInvocation
    public var supportLevel: SupportLevel
    public var requiresConfirmation: Bool
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        source: CapabilitySource,
        reflectorID: String = "unowned",
        provider: CapabilityProvider? = nil,
        inputs: [String] = [],
        output: [String] = [],
        safety: CapabilitySafety,
        invocation: CapabilityInvocation,
        supportLevel: SupportLevel,
        requiresConfirmation: Bool,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.reflectorID = reflectorID
        self.provider = provider
        self.inputs = inputs
        self.output = output
        self.safety = safety
        self.invocation = invocation
        self.supportLevel = supportLevel
        self.requiresConfirmation = requiresConfirmation
        self.metadata = metadata
    }
}

public enum CapabilityID {
    public static func sharing(title: String, publicName: String?) -> String {
        if let publicName, !publicName.isEmpty {
            return "sharing:\(publicName)"
        }
        return "sharing:title:\(slug(title))"
    }

    public static func service(
        bundleIdentifier: String?,
        bundlePath: String? = nil,
        message: String?,
        menuTitle: String
    ) -> String {
        let provider: String

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            // Preserve the existing stable identity for normal bundled providers.
            provider = bundleIdentifier
        } else if let bundlePath, !bundlePath.isEmpty {
            // Some Automator workflows / Services have no CFBundleIdentifier.
            // Their discovered bundle path is therefore the strongest provider
            // locator available to RIGHTCLICK.
            //
            // Hash the canonical path so:
            // - distinct providers cannot collapse to "unknown";
            // - local filesystem paths are not exposed in the capability ID;
            // - identity remains deterministic across discovery and execution.
            let canonicalPath = URL(fileURLWithPath: bundlePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path

            let digest = SHA256.hash(data: Data(canonicalPath.utf8))
            let fingerprint = digest
                .map { String(format: "%02x", $0) }
                .joined()

            provider = "path-sha256-\(fingerprint)"
        } else {
            // Fail to a deterministic descriptive identity rather than collapsing
            // every provider without metadata into one shared "unknown" bucket.
            provider = "title-\(slug(menuTitle))"
        }

        let action = (message?.isEmpty == false ? message! : slug(menuTitle))
        return "service:\(provider):\(action)"
    }

    public static func actionExtension(bundleIdentifier: String?, path: String) -> String {
        let provider = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : slug(path)
        return "action:\(provider)"
    }

    public static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : collapsed
    }
}

public enum RunStatus: String, Codable, Sendable {
    case accepted = "ACCEPTED"
    case verified = "VERIFIED"
    case unavailable = "UNAVAILABLE"
    case rejected = "REJECTED"
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case unsupported = "UNSUPPORTED"
    case failed = "FAILED"
    case unknown = "UNKNOWN"
}

public enum ExecutionState: String, Codable, Sendable {
    case started
    case awaitingUser = "awaiting_user"
    case succeeded
    case accepted
    case unsupported
    case unavailable
    case rejected
    case failed
    case cancelled
    case unknown
}

/// Describes what was observed, separately from the intended outcome.
public struct OutcomeEvidence: Codable, Sendable, Equatable {
    public var type: String
    public var boundary: String
    public var outcomeVerified: Bool

    public init(type: String = "none", boundary: String = "No outcome observation.", outcomeVerified: Bool = false) {
        self.type = type
        self.boundary = boundary
        self.outcomeVerified = outcomeVerified
    }
}

/// An honest status-only summary when the original record exceeds retention
/// capacity. A digest identifies discarded receipt bytes; it is not a receipt,
/// signature, durable export, or independent outcome verification.
public struct ExecutionRetentionEvidence: Codable, Sendable, Equatable {
    public let fullRecordRetained: Bool
    public let originalEncodedBytes: Int
    public let receiptPayloadSHA256: String?
    public let taskPhase: String?
}

public struct ExecutionRecord: Codable, Sendable {
    public var executionId: String
    public var actionId: String
    public var title: String?
    public var state: ExecutionState
    public var message: String
    public var output: String?
    public var events: [String]
    public var evidence: OutcomeEvidence
    public var verification: OutcomeVerification?
    public var rcir: RCIRExecutionEvidence?
    public var retention: ExecutionRetentionEvidence?

    public init(
        executionId: String,
        actionId: String,
        title: String? = nil,
        state: ExecutionState,
        message: String,
        output: String? = nil,
        events: [String] = [],
        evidence: OutcomeEvidence = OutcomeEvidence(),
        verification: OutcomeVerification? = nil,
        rcir: RCIRExecutionEvidence? = nil,
        retention: ExecutionRetentionEvidence? = nil
    ) {
        self.executionId = executionId
        self.actionId = actionId
        self.title = title
        self.state = state
        self.message = message
        self.output = output
        self.events = events
        self.evidence = evidence
        self.verification = verification
        self.rcir = rcir
        self.retention = retention
    }
}

public final class ExecutionStore: @unchecked Sendable {
    public static let shared = ExecutionStore()
    public struct Statistics: Sendable {
        public let records: Int
        public let encodedBytes: Int
        public let reservedBytes: Int
        public let activeRecords: Int
    }
    private struct Entry {
        var record: ExecutionRecord
        var encodedBytes: Int
        var accountedBytes: Int
        var active: Bool
        var ordinal: UInt64
        var terminalAt: UInt64?
    }
    private let lock = NSLock()
    private var records: [String: Entry] = [:]
    private var accountedBytes = 0
    private var ordinal: UInt64 = 0
    private var lastNow: UInt64 = 0
    private let maximumRecords: Int
    private let maximumEncodedBytes: Int
    private let timeToLiveNanoseconds: UInt64
    private let clock: @Sendable () -> UInt64

    /// Bounded volatile history, not durable receipt storage. Active reservations
    /// survive history expiry/eviction until their callback reports a terminal
    /// state. Their compact-summary byte allowance is reserved before dispatch.
    public init(maximumRecords: Int = 1_024, maximumEncodedBytes: Int = 16_777_216,
                timeToLiveNanoseconds: UInt64 = 300_000_000_000,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        precondition(maximumRecords >= 0 && maximumEncodedBytes >= 0)
        self.maximumRecords = maximumRecords
        self.maximumEncodedBytes = maximumEncodedBytes
        self.timeToLiveNanoseconds = timeToLiveNanoseconds
        self.clock = clock
    }

    /// False means no reservation/history was stored. Callers must check an
    /// initial started reservation before dispatching an external task.
    @discardableResult public func put(_ record: ExecutionRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = monotonicNow()
        expire(at: now)
        return retain(record, previous: records[record.executionId], at: now)
    }

    public func get(_ executionId: String) -> ExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        expire(at: monotonicNow())
        return records[executionId]?.record
    }

    /// The callback always runs for a reserved active task, including when its
    /// previous output was compacted. It may release external session ownership.
    @discardableResult public func update(_ executionId: String, _ body: (inout ExecutionRecord) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = monotonicNow()
        expire(at: now)
        guard let previous = records[executionId] else { return false }
        var record = previous.record
        body(&record)
        // An update cannot move a reservation to another execution/capability.
        record.executionId = previous.record.executionId
        record.actionId = previous.record.actionId
        return retain(record, previous: previous, at: now)
    }

    public func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        expire(at: monotonicNow())
        return Statistics(records: records.count,
                          encodedBytes: records.values.reduce(0) { $0 + $1.encodedBytes },
                          reservedBytes: accountedBytes,
                          activeRecords: records.values.filter(\.active).count)
    }

    private func monotonicNow() -> UInt64 {
        lastNow = max(lastNow, clock())
        return lastNow
    }

    private func expire(at now: UInt64) {
        for (id, entry) in records where !entry.active {
            if let terminalAt = entry.terminalAt, now - terminalAt >= timeToLiveNanoseconds { remove(id) }
        }
    }

    private func remove(_ id: String) {
        if let removed = records.removeValue(forKey: id) { accountedBytes -= removed.accountedBytes }
    }

    private func isPending(_ record: ExecutionRecord, previouslyActive: Bool) -> Bool {
        if [.succeeded, .unsupported, .unavailable, .rejected, .failed, .cancelled, .unknown].contains(record.state) { return false }
        let phase = record.rcir?.phase ?? record.retention?.taskPhase
        if let phase { return ["started", "accepted", "working", "inputRequired", "cancelRequested"].contains(phase) }
        return record.state == .started || (previouslyActive && record.state == .awaitingUser)
    }

    private func compact(_ record: ExecutionRecord, size: Int, reserve: Bool = false) -> ExecutionRecord {
        let receipt = record.rcir?.signedReceipt?.payload ?? record.rcir?.receipt
        let digest = (reserve ? nil : receipt).flatMap { Data(base64Encoded: $0) }.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? record.retention?.receiptPayloadSHA256
        let annotation = ExecutionRetentionEvidence(
            fullRecordRetained: false,
            originalEncodedBytes: reserve ? Int.max : max(size, record.retention?.originalEncodedBytes ?? 0),
            receiptPayloadSHA256: reserve ? String(repeating: "0", count: 64) : digest,
            taskPhase: reserve ? "cancelRequested" : (record.rcir?.phase ?? record.retention?.taskPhase))
        return ExecutionRecord(executionId: record.executionId, actionId: record.actionId,
                               state: reserve ? .awaitingUser : record.state,
                               message: "History was compacted; output, events, observations and receipt are not retained. No durable receipt export exists.",
                               evidence: OutcomeEvidence(type: "retention_summary",
                                   boundary: "Status identity and state only; full evidence/output is not retained and this summary does not verify an outcome."),
                               retention: annotation)
    }

    private func encodedSize(_ record: ExecutionRecord) -> Int? {
        (try? JSONEncoder().encode(record))?.count
    }

    private func retain(_ incoming: ExecutionRecord, previous: Entry?, at now: UInt64) -> Bool {
        let active = isPending(incoming, previouslyActive: previous?.active ?? false)
        guard let fullSize = encodedSize(incoming),
              let summaryReserve = encodedSize(compact(incoming, size: fullSize, reserve: true)) else { return false }
        // Reserve worst-case summary length up front, including its receipt
        // digest and lifecycle phase, so active updates never lose bookkeeping.
        let minimum = active ? summaryReserve : 0
        let available = maximumEncodedBytes - (accountedBytes - (previous?.accountedBytes ?? 0))
        let activeOthers = records.values.filter { $0.active && $0.record.executionId != incoming.executionId }
        let activeBytes = activeOthers.reduce(0) { $0 + $1.accountedBytes }
        var record = incoming
        var size = fullSize
        var charge = max(size, minimum)
        if charge > maximumEncodedBytes - activeBytes || (active && charge > available) {
            record = compact(incoming, size: fullSize)
            guard let compactSize = encodedSize(record) else { return false }
            size = compactSize
            charge = max(size, minimum)
        }
        // Refuse impossible new reservations before evicting any history.
        guard maximumRecords > activeOthers.count, charge <= maximumEncodedBytes - activeBytes else {
            if let previous, !active { remove(previous.record.executionId) }
            return false
        }
        if let previous { remove(previous.record.executionId) }
        while records.count >= maximumRecords || charge > maximumEncodedBytes - accountedBytes {
            guard let victim = records.values.filter({ !$0.active }).min(by: {
                $0.ordinal == $1.ordinal ? $0.record.executionId < $1.record.executionId : $0.ordinal < $1.ordinal
            }) else { return false }
            remove(victim.record.executionId)
        }
        if ordinal == UInt64.max {
            let ids = records.values.sorted { $0.ordinal < $1.ordinal }.map { $0.record.executionId }
            for (index, id) in ids.enumerated() { records[id]?.ordinal = UInt64(index) }
            ordinal = UInt64(ids.count)
        }
        let order = previous?.ordinal ?? ordinal
        if previous == nil { ordinal += 1 }
        let terminalAt = active ? nil : (previous?.terminalAt ?? now)
        records[incoming.executionId] = Entry(record: record, encodedBytes: size,
            accountedBytes: charge, active: active, ordinal: order, terminalAt: terminalAt)
        accountedBytes += charge
        return true
    }
}

public struct RunResult: Codable, Sendable {
    public var status: RunStatus
    public var actionID: String
    public var title: String?
    public var message: String
    public var output: String?
    public var requiresConfirmation: Bool
    public var supportLevel: SupportLevel?
    public var evidence: OutcomeEvidence
    public var verification: OutcomeVerification?
    public var rcir: RCIRExecutionEvidence?

    public init(
        status: RunStatus,
        actionID: String,
        title: String? = nil,
        message: String,
        output: String? = nil,
        requiresConfirmation: Bool = false,
        supportLevel: SupportLevel? = nil,
        evidence: OutcomeEvidence = OutcomeEvidence(),
        verification: OutcomeVerification? = nil,
        rcir: RCIRExecutionEvidence? = nil
    ) {
        self.status = status
        self.actionID = actionID
        self.title = title
        self.message = message
        self.output = output
        self.requiresConfirmation = requiresConfirmation
        self.supportLevel = supportLevel
        self.evidence = evidence
        self.verification = verification
        self.rcir = rcir
    }
}

public func dedupeCapabilities(_ capabilities: [Capability]) -> [Capability] {
    var seen = Set<String>()
    var result: [Capability] = []
    for capability in capabilities {
        if seen.insert(capability.id).inserted {
            result.append(capability)
        }
    }
    return result
}
