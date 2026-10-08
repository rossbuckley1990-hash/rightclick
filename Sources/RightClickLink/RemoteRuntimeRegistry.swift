import Foundation
import RightClickCore

public enum RemoteRuntimeAvailability: String, Codable { case online, offline, stale }
public struct RemoteRuntimeRegistration {
    public let descriptor: RemoteRuntimeDescriptor
    public let availability: RemoteRuntimeAvailability
}

/// Explicit local enrollment pins keys separately from relay/catalog responses.
/// Contextual catalogs expire, and routes always retain their original target.
public final class RemoteRuntimeRegistry: @unchecked Sendable {
    private struct Catalog { let capabilities: [RemoteCapabilityDescriptor]; let expiresAt: Int64 }
    private struct Peer {
        let client: RemoteLinkClient
        let descriptor: RemoteRuntimeDescriptor
        var catalogs: [String: Catalog] = [:]
        var online = true
    }
    private let lock = NSLock()
    private var peers: [String: Peer] = [:]
    private var enrollments: [String: UUID] = [:]
    private let now: () -> Int64
    public init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.now = now }
    public func enroll(_ client: RemoteLinkClient, item: String) async throws {
        let token = try beginEnrollment(client.target.runtimeID)
        defer { endEnrollment(client.target.runtimeID, token: token) }
        let hello = try await client.send(client.makeRequest(operation: .runtime))
        guard let descriptor = hello.summary.runtime, descriptor.runtimeID == client.target.runtimeID,
              descriptor.deviceID == client.target.deviceID else { throw RemoteLinkError.wrongRuntime }
        let request = client.makeRequest(operation: .actions, item: item)
        let result = try await client.send(request)
        guard result.summary.error == nil, result.summary.lifecycle.last == .discovered,
              result.summary.completedAtMilliseconds <= now(), result.summary.completedAtMilliseconds >= request.issuedAtMilliseconds,
              result.summary.capabilities.allSatisfy({ $0.runtimeRequirements?.permits(os: descriptor.operatingSystem, architecture: descriptor.architecture) ?? true })
        else { throw RemoteLinkError.unavailable }
        let expires = min(request.expiresAtMilliseconds, result.summary.completedAtMilliseconds + 60_000)
        guard expires > now() else { throw RemoteLinkError.expired }
        try store(client, descriptor: descriptor, item: item, capabilities: result.summary.capabilities, expires: expires, token: token)
    }
    private func beginEnrollment(_ id: String) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard enrollments.count < 16 || enrollments[id] != nil else { throw RemoteLinkError.limitExceeded }
        let token = UUID(); enrollments[id] = token; return token
    }
    private func endEnrollment(_ id: String, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if enrollments[id] == token { enrollments.removeValue(forKey: id) }
    }
    private func store(_ client: RemoteLinkClient, descriptor: RemoteRuntimeDescriptor, item: String,
        capabilities: [RemoteCapabilityDescriptor], expires: Int64, token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard enrollments[descriptor.runtimeID] == token else { throw RemoteLinkError.unauthorized }
        guard peers.count < 16 || peers[descriptor.runtimeID] != nil else { throw RemoteLinkError.limitExceeded }
        var peer = peers[descriptor.runtimeID] ?? Peer(client: client, descriptor: descriptor)
        guard peer.client === client,
              peer.descriptor.operatingSystem == descriptor.operatingSystem,
              peer.descriptor.architecture == descriptor.architecture,
              peer.catalogs.count < 8 || peer.catalogs[itemKey(item)] != nil else { throw RemoteLinkError.idempotencyConflict }
        peer.catalogs[itemKey(item)] = Catalog(capabilities: capabilities, expiresAt: expires)
        peer.online = true; peers[descriptor.runtimeID] = peer
    }
    public func remove(runtimeID: String) {
        lock.lock(); defer { lock.unlock() }
        peers.removeValue(forKey: runtimeID); enrollments.removeValue(forKey: runtimeID)
    }
    public func markOffline(runtimeID: String) { lock.lock(); defer { lock.unlock() }; peers[runtimeID]?.online = false }
    public func registrations() -> [RemoteRuntimeRegistration] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.map { peer in
            .init(descriptor: peer.descriptor, availability: !peer.online ? .offline :
                peer.catalogs.values.contains(where: { $0.expiresAt > now() }) ? .online : .stale)
        }.sorted { $0.descriptor.runtimeID < $1.descriptor.runtimeID }
    }
    fileprivate func reflectors(item: String?) -> [any CapabilityReflector] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.compactMap { peer in
            guard peer.online else { return nil }
            let catalog = item.map { peer.catalogs[itemKey($0)] } ?? peer.catalogs.values.first { $0.expiresAt > now() }
            guard let catalog, catalog.expiresAt > now() else { return nil }
            return RemoteRoutedReflector(client: peer.client, descriptor: peer.descriptor,
                catalog: catalog.capabilities, itemKey: item.map(itemKey), expiresAt: catalog.expiresAt, now: now,
                isEnrolled: { [weak self] in self?.isEnrolled(peer.descriptor.runtimeID, client: peer.client) == true },
                failed: { [weak self] in self?.markOffline(runtimeID: peer.descriptor.runtimeID) })
        }
    }
    private func isEnrolled(_ id: String, client: RemoteLinkClient) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard let peer = peers[id] else { return false }
        return peer.online && peer.client === client
    }
    fileprivate func invalidate() { lock.lock(); defer { lock.unlock() }; peers = peers.mapValues { var peer = $0; peer.catalogs = [:]; return peer } }
    private func itemKey(_ item: String) -> String { RemoteWire.digest(Data(item.utf8)) }
}

public final class RemoteCapabilitySource: ContextualCapabilityReflectorSource {
    public let id = "rightclick.link"
    private let registry: RemoteRuntimeRegistry
    public init(registry: RemoteRuntimeRegistry) { self.registry = registry }
    public func reflectors() -> [any CapabilityReflector] { registry.reflectors(item: nil) }
    public func reflectors(for item: ContentItem) -> [any CapabilityReflector] { registry.reflectors(item: Self.raw(item)) }
    public func invalidateSnapshot() { registry.invalidate() }
    static func raw(_ item: ContentItem) -> String { item.text ?? item.url ?? item.path ?? item.display }
}

private final class RemoteRoutedReflector: CapabilityRoutingReflector, CapabilityExecutionStatusReflector {
    var routingOrigin: CapabilityRoutingOrigin {
        .init(transport: "rightclick-link", executionRuntimeID: client.target.runtimeID)
    }
    let id: String
    let executionEnvironment: RuntimeEnvironment
    let completionWaitSeconds: TimeInterval = 65
    private let client: RemoteLinkClient
    private let catalog: [RemoteCapabilityDescriptor]
    private let itemKey: String?
    private let expiresAt: Int64
    private let now: () -> Int64
    private let isEnrolled: () -> Bool
    private let failed: () -> Void
    private struct OwnedExecution {
        let capability: Capability
        let item: String
        let remoteCapabilityID: String
        let contractDigest: String
        let verification: VerificationSpec?
        var remoteExecutionID: String?
        var inFlight = true
        var transportUncertain = false
    }
    private let executionLock = NSLock()
    private var executions: [String: OwnedExecution] = [:]
    init(client: RemoteLinkClient, descriptor: RemoteRuntimeDescriptor, catalog: [RemoteCapabilityDescriptor],
         itemKey: String?, expiresAt: Int64, now: @escaping () -> Int64, isEnrolled: @escaping () -> Bool, failed: @escaping () -> Void) {
        self.client = client; self.catalog = catalog; self.itemKey = itemKey; self.expiresAt = expiresAt
        self.now = now; self.isEnrolled = isEnrolled; self.failed = failed
        id = "link:" + RemoteWire.digest(client.target.publicKey)
        executionEnvironment = .init(operatingSystem: descriptor.operatingSystem, architecture: descriptor.architecture)
    }
    func capabilities(for item: ContentItem) throws -> [Capability] {
        let raw = RemoteCapabilitySource.raw(item)
        guard isEnrolled(), expiresAt > now(), itemKey == nil || itemKey == RemoteWire.digest(Data(raw.utf8)) else { return [] }
        return catalog.map {
            Capability(id: routeID($0.id), title: $0.title, source: .system, reflectorID: id,
                safety: $0.safety, invocation: $0.invocation, supportLevel: $0.supportLevel,
                requiresConfirmation: $0.requiresConfirmation,
                metadata: ["substrate":"rightclick-link", "link.runtimeID":client.target.runtimeID,
                           "link.capabilityDigest":$0.contractDigest, "link.capabilityID":$0.id],
                runtimeRequirements: $0.runtimeRequirements)
        }
    }
    func providers() -> [ProviderSummary] { [.init(name: "RIGHTCLICK node " + String(client.target.runtimeID.suffix(12)), source: "rightclick-link", capabilityTitles: catalog.map(\.title))] }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        try begin(capability: capability, item: item, executionID: executionID, arguments: nil)
    }
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?) throws -> ExecutionRecord {
        try submit(capability: capability, item: item, executionID: executionID, arguments: arguments, verification: nil)
    }
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
        try submit(capability: capability, item: item, executionID: executionID, arguments: arguments, verification: verification)
    }
    private func submit(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?) throws -> ExecutionRecord {
        guard isEnrolled(), expiresAt > now(), let entry = catalog.first(where: { routeID($0.id) == capability.id }) else { throw RemoteLinkError.unavailable }
        let request = client.makeRequest(operation: .run, item: RemoteCapabilitySource.raw(item), capabilityID: entry.id,
            capabilityDigest: entry.contractDigest, arguments: arguments, verification: verification)
        let initial = ExecutionRecord(executionId: executionID, actionId: capability.id, state: .started, message: "Requested enrolled RIGHTCLICK node.")
        ExecutionStore.shared.put(initial)
        executionLock.lock()
        executions = executions.filter { ExecutionStore.shared.get($0.key) != nil }
        executions[executionID] = OwnedExecution(capability: capability, item: RemoteCapabilitySource.raw(item),
            remoteCapabilityID: entry.id, contractDigest: entry.contractDigest, verification: verification)
        executionLock.unlock()
        Task {
            do {
                guard self.isEnrolled(), self.expiresAt > self.now() else { throw RemoteLinkError.unavailable }
                let summary = try await self.client.send(request).summary
                guard self.isEnrolled() else { throw RemoteLinkError.unauthorized }
                self.install(summary, executionID: executionID)
            } catch { self.installUnknown(executionID) }
        }
        return initial
    }
    func executionStatus(_ executionID: String) -> ExecutionRecord? {
        executionLock.lock()
        guard var owned = executions[executionID], let retained = ExecutionStore.shared.get(executionID) else {
            executionLock.unlock(); return nil
        }
        guard !owned.inFlight, let remoteID = owned.remoteExecutionID,
              ([.started, .accepted, .awaitingUser].contains(retained.state) ||
               (retained.state == .unknown && owned.transportUncertain)) else {
            executionLock.unlock(); return retained
        }
        owned.inFlight = true; executions[executionID] = owned
        executionLock.unlock()
        let request = client.makeRequest(operation: .status, item: owned.item, capabilityID: owned.remoteCapabilityID,
            capabilityDigest: owned.contractDigest, executionID: remoteID)
        Task {
            do {
                guard self.isEnrolled() else { throw RemoteLinkError.unavailable }
                let summary = try await self.client.send(request).summary
                guard self.isEnrolled() else { throw RemoteLinkError.unauthorized }
                self.install(summary, executionID: executionID)
            } catch { self.installUnknown(executionID) }
        }
        return retained
    }
    private func install(_ summary: RemoteExecutionSummary, executionID: String) {
        executionLock.lock(); defer { executionLock.unlock() }
        guard var owned = executions[executionID] else { return }
        owned.remoteExecutionID = summary.evidenceExecutionID; owned.inFlight = false; owned.transportUncertain = false
        executions[executionID] = owned
        let predicates = summary.verification == .verifiedSuccess ? (owned.verification?.predicates ?? []).map {
            PredicateVerification(predicate: $0, evaluated: true, passed: true, message: "Authenticated execution-node observation.")
        } : []
        var record = ExecutionRecord(executionId: executionID, actionId: owned.capability.id, title: owned.capability.title,
            state: summary.state ?? .unknown, message: "Authenticated node result: " + (summary.error?.rawValue ?? summary.taskPhase ?? "completed"),
            events: summary.evidenceExecutionID.map { ["remote evidence " + $0] } ?? [],
            evidence: OutcomeEvidence(type: "remote_" + summary.observationBoundary.rawValue,
                boundary: "Enrolled execution-node assertion; raw evidence remains on that node.",
                outcomeVerified: summary.verification == .verifiedSuccess, observationBoundary: summary.observationBoundary),
            verification: OutcomeVerification(status: summary.verification, predicates: predicates))
        record.authenticatedNodeVerification = summary.verification == .verifiedSuccess || summary.verification == .verifiedFailure
        ExecutionStore.shared.put(record)
    }
    private func installUnknown(_ executionID: String) {
        failed()
        executionLock.lock(); defer { executionLock.unlock() }
        guard var owned = executions[executionID] else { return }
        owned.inFlight = false; owned.transportUncertain = true; executions[executionID] = owned
        ExecutionStore.shared.put(ExecutionRecord(executionId: executionID, actionId: owned.capability.id, state: .unknown,
            message: "Remote delivery, status or result integrity is uncertain. Do not retry on another node."))
    }
    private func routeID(_ capability: String) -> String { "remote:" + RemoteWire.digest(client.target.publicKey) + ":" + RemoteWire.digest(Data(capability.utf8)) }
}
