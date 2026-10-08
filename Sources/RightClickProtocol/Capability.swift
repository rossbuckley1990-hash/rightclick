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
    /// Absent in legacy contracts; native capabilities remain host-bound.
    public var runtimeRequirements: RuntimeRequirements?

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
        metadata: [String: String] = [:],
        runtimeRequirements: RuntimeRequirements? = nil
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
        self.runtimeRequirements = runtimeRequirements
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
public enum OutcomeObservationBoundary: String, Codable, Sendable { case none, returnedValue, externalState }
public struct OutcomeEvidence: Codable, Sendable, Equatable {
    public var type: String
    public var boundary: String
    public var outcomeVerified: Bool
    public var observationBoundary: OutcomeObservationBoundary?

    public init(type: String = "none", boundary: String = "No outcome observation.", outcomeVerified: Bool = false,
                observationBoundary: OutcomeObservationBoundary? = nil) {
        self.type = type
        self.boundary = boundary
        self.outcomeVerified = outcomeVerified
        self.observationBoundary = observationBoundary
    }
}

public struct ExecutionRecord: Codable, Sendable {
    public var executionId: String
    public var actionId: String
    public var title: String?
    public var state: ExecutionState
    public var message: String
    public var output: String?
    public var result: CapabilityValue?
    public var rcirEvents: [RCIRExecutionEvent]?
    public var rcirEventPage: RCIRExecutionEventPage?
    public var lifecycle: ExecutionLifecycle?
    public var events: [String]
    public var evidence: OutcomeEvidence
    public var verification: OutcomeVerification?
    public var rcir: RCIRExecutionEvidence?
    /// Non-secret signed nested evidence projected from the durable host ledger.
    /// Its availability never substitutes for the invocation's final outcome.
    public var environmentEvidence: EnvironmentExecutionEvidence?

    public init(
        executionId: String,
        actionId: String,
        title: String? = nil,
        state: ExecutionState,
        message: String,
        output: String? = nil,
        result: CapabilityValue? = nil,
        events: [String] = [],
        evidence: OutcomeEvidence = OutcomeEvidence(),
        verification: OutcomeVerification? = nil,
        rcir: RCIRExecutionEvidence? = nil,
        rcirEvents: [RCIRExecutionEvent]? = nil,
        rcirEventPage: RCIRExecutionEventPage? = nil,
        lifecycle: ExecutionLifecycle? = nil,
        environmentEvidence: EnvironmentExecutionEvidence? = nil
    ) {
        self.executionId = executionId
        self.actionId = actionId
        self.title = title
        self.state = state
        self.message = message
        self.output = output
        self.result = result
        self.rcirEvents = rcirEvents
        self.rcirEventPage = rcirEventPage
        self.lifecycle = lifecycle
        self.environmentEvidence = environmentEvidence
        self.events = events
        self.evidence = evidence
        self.verification = verification
        self.rcir = rcir
    }
}

/// Portable observation retention. Terminal publications may precede the initial
/// response and cannot be overwritten by a late live record or callback.
public final class ExecutionStore: @unchecked Sendable {
    public static let shared = ExecutionStore()
    private struct Entry {
        var record: ExecutionRecord?
        var history: [RCIRExecutionEvent]?
        var terminal: ExecutionRecord?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public func put(_ record: ExecutionRecord) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[record.executionId] ?? Entry()
        if var terminal = entry.terminal {
            terminal.title = terminal.title ?? record.title
            entry.record = terminal
            entry.terminal = terminal
        } else { entry.record = record }
        entries[record.executionId] = entry
    }

    public func get(_ executionId: String) -> ExecutionRecord? {
        lock.lock(); defer { lock.unlock() }
        return entries[executionId]?.terminal ?? entries[executionId]?.record
    }

    /// Capture immutable retained metadata and its complete history together.
    /// Routed aliases may have only an authenticated bounded view, so their
    /// existing page is preserved without manufacturing complete local history.
    public func statusSnapshot(executionId: String, after cursor: Int64 = 0, limit: Int = 64,
                               maximumBytes: Int = 262_144) throws -> ExecutionRecord? {
        guard cursor >= 0 else { throw RCIRError.invalidSequence }
        guard (1...256).contains(limit), (1...262_144).contains(maximumBytes) else { throw RCIRError.invalidLimit }
        lock.lock()
        let record = entries[executionId]?.terminal ?? entries[executionId]?.record
        let history = entries[executionId]?.history
        lock.unlock()
        guard var snapshot = record else { return nil }
        // A nonterminal cached initial response may trail its live owner. Only
        // terminal metadata provides an authoritative retained sequence bound.
        if snapshot.lifecycle?.terminal == true, let sequence = snapshot.lifecycle?.sequence,
           cursor > sequence { throw RCIRError.invalidSequence }
        if let history {
            snapshot.rcirEventPage = try rcirExecutionEventPage(history, after: cursor, limit: limit,
                maximumBytes: maximumBytes, terminal: true)
        } else if let page = snapshot.rcirEventPage {
            // A cached routed page is reusable only for this exact query. Its
            // view cannot justify synthesizing pages for another cursor.
            let matchesCursor = page.nextCursor >= cursor &&
                page.nextCursor - cursor == Int64(page.events.count) &&
                page.events.enumerated().allSatisfy { $0.element.sequence > cursor &&
                    $0.element.sequence - cursor == Int64($0.offset + 1) }
            let bytes = try page.events.reduce(0) { $0 + (try $1.canonicalData().count) }
            if !matchesCursor || page.events.count > limit || bytes > maximumBytes { snapshot.rcirEventPage = nil }
        }
        snapshot.rcirEvents = nil
        return snapshot
    }

    public func update(_ executionId: String, _ body: (inout ExecutionRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[executionId], entry.terminal == nil, var record = entry.record else { return }
        body(&record); entry.record = record; entries[executionId] = entry
    }

    /// Retain receipt, typed result and history atomically before live ownership
    /// is removed. Repeated terminal publication is immutable.
    public func putTerminal(_ record: ExecutionRecord, events: [RCIRExecutionEvent]) throws {
        guard record.lifecycle?.terminal == true || record.rcirEventPage?.terminal == true else {
            throw RCIRError.invalidTransition
        }
        try validateHistory(events)
        lock.lock(); defer { lock.unlock() }
        var entry = entries[record.executionId] ?? Entry()
        if let oldHistory = entry.history {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(oldHistory) == encoder.encode(events) else { throw RCIRError.invalidTransition }
        }
        if let existing = entry.terminal {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(existing) == encoder.encode(record) else { throw RCIRError.invalidTransition }
            return
        }
        entry.history = events; entry.terminal = record; entry.record = record
        entries[record.executionId] = entry
    }

    /// Retain authenticated terminal metadata for a routed local alias without
    /// claiming its bounded view is the complete execution-node event history.
    /// Only the infrastructure verifier calls this after validating the signer.
    public func putTerminalSnapshot(_ record: ExecutionRecord) throws {
        guard let lifecycle = record.lifecycle, lifecycle.version == 1, lifecycle.terminal,
              [.completed, .failed, .cancelled, .unknown].contains(lifecycle.phase),
              lifecycle.sequence >= 0, lifecycle.generation > 0 else { throw RCIRError.invalidTransition }
        if let page = record.rcirEventPage {
            guard page.terminal, page.events.count <= 256, page.nextCursor >= 0,
                  page.nextCursor <= lifecycle.sequence else { throw RCIRError.invalidSequence }
            try validateView(page.events, maximum: 262_144)
            if let last = page.events.last {
                guard last.sequence == page.nextCursor else { throw RCIRError.invalidSequence }
            }
        }
        if let events = record.rcirEvents {
            guard events.count <= 1_024 else { throw RCIRError.invalidLimit }
            try validateView(events, maximum: 262_144)
        }
        lock.lock(); defer { lock.unlock() }
        var entry = entries[record.executionId] ?? Entry()
        if let existing = entry.terminal {
            var old = existing, new = record
            old.rcirEventPage = nil; old.rcirEvents = nil
            new.rcirEventPage = nil; new.rcirEvents = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(old) == encoder.encode(new) else { throw RCIRError.invalidTransition }
        }
        entry.terminal = record; entry.record = record
        entries[record.executionId] = entry
    }

    private func validateView(_ events: [RCIRExecutionEvent], maximum: Int) throws {
        var bytes = 0, previous: Int64?
        for event in events {
            guard event.sequence > 0 else { throw RCIRError.invalidSequence }
            if let previous { guard previous < Int64.max, event.sequence == previous + 1 else { throw RCIRError.invalidSequence } }
            let size = try event.canonicalData().count
            guard size <= maximum - bytes else { throw RCIRError.invalidLimit }
            bytes += size; previous = event.sequence
        }
    }

    public func putRCIRHistory(_ events: [RCIRExecutionEvent], executionId: String) throws {
        try validateHistory(events)
        lock.lock(); defer { lock.unlock() }
        var entry = entries[executionId] ?? Entry()
        if let old = entry.history {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(old) == encoder.encode(events) else { throw RCIRError.invalidTransition }
        } else { entry.history = events }
        entries[executionId] = entry
    }

    public func rcirEventPage(executionId: String, after cursor: Int64 = 0, limit: Int = 64,
                             maximumBytes: Int = 262_144) throws -> RCIRExecutionEventPage? {
        guard cursor >= 0 else { throw RCIRError.invalidSequence }
        guard (1...256).contains(limit), (1...262_144).contains(maximumBytes) else { throw RCIRError.invalidLimit }
        lock.lock(); let history = entries[executionId]?.history; lock.unlock()
        guard let history else { return nil }
        return try rcirExecutionEventPage(history, after: cursor, limit: limit,
                                         maximumBytes: maximumBytes, terminal: true)
    }

    private func validateHistory(_ events: [RCIRExecutionEvent]) throws {
        guard events.count <= 1_024 else { throw RCIRError.invalidLimit }
        var bytes = 0
        for (index, event) in events.enumerated() {
            guard event.sequence == Int64(index + 1) else { throw RCIRError.invalidSequence }
            let size = try event.canonicalData().count
            guard size <= 262_144 - bytes else { throw RCIRError.invalidLimit }
            bytes += size
        }
    }
}

public struct RunResult: Codable, Sendable {
    public var status: RunStatus
    public var actionID: String
    public var title: String?
    public var message: String
    public var output: String?
    public var result: CapabilityValue?
    public var rcirEvents: [RCIRExecutionEvent]?
    public var rcirEventPage: RCIRExecutionEventPage?
    public var lifecycle: ExecutionLifecycle?
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
        result: CapabilityValue? = nil,
        requiresConfirmation: Bool = false,
        supportLevel: SupportLevel? = nil,
        evidence: OutcomeEvidence = OutcomeEvidence(),
        verification: OutcomeVerification? = nil,
        rcir: RCIRExecutionEvidence? = nil,
        rcirEvents: [RCIRExecutionEvent]? = nil,
        rcirEventPage: RCIRExecutionEventPage? = nil,
        lifecycle: ExecutionLifecycle? = nil
    ) {
        self.status = status
        self.actionID = actionID
        self.title = title
        self.message = message
        self.output = output
        self.result = result
        self.rcirEvents = rcirEvents
        self.rcirEventPage = rcirEventPage
        self.lifecycle = lifecycle
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
