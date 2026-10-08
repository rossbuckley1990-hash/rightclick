import Foundation
import RightClickCore

public enum RemoteRuntimeAvailability: String, Codable { case online, offline, stale }
public struct RemoteRuntimeRegistration {
    public let descriptor: RemoteRuntimeDescriptor
    public let availability: RemoteRuntimeAvailability
}

/// Installed by the parent host. Neither observer keys nor admitted invocation
/// expectations may come from the child response or contextual tool arguments.
public struct RemoteEnvironmentVerificationPolicy {
    public let trustedHostPublicKey: Data
    private let expectationResolver: (RemoteExecutionRequest) throws -> ExecutionProofExpectation
    private let failureResolver: ((RemoteExecutionRequest) throws -> Bool)?
    private let now: () -> Int64

    public init(trustedHostPublicKey: Data,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                expectationResolver: @escaping (RemoteExecutionRequest) throws -> ExecutionProofExpectation,
                failureResolver: ((RemoteExecutionRequest) throws -> Bool)? = nil) throws {
        guard trustedHostPublicKey.count == 32 else { throw RemoteLinkError.unauthorized }
        self.trustedHostPublicKey = trustedHostPublicKey; self.now = now; self.expectationResolver = expectationResolver
        self.failureResolver = failureResolver
    }

    fileprivate func verify(_ summary: RemoteExecutionSummary, originalRequest: RemoteExecutionRequest,
                            trustedRuntimeKey: Data) throws {
        guard originalRequest.operation == .run, originalRequest.capabilityID == "environment:execute",
              trustedHostPublicKey != trustedRuntimeKey else { throw EnvironmentEvidenceError.independentVerificationRequired }
        if summary.state == .failed, summary.verification == .verifiedFailure {
            // Failed full RCIR invocations cannot mint successful dependency
            // proof authority. A parent-installed broker can instead check its
            // immutable negative adjudication and exact admitted request locally.
            guard summary.evidenceExecutionID == originalRequest.requestID.uuidString,
                  summary.executionLifecycle?.executionID == originalRequest.requestID.uuidString,
                  summary.observationBoundary == .externalState,
                  now() >= summary.completedAtMilliseconds, now() >= originalRequest.issuedAtMilliseconds,
                  try failureResolver?(originalRequest) == true else {
                throw EnvironmentEvidenceError.independentVerificationRequired
            }
            return
        }
        guard summary.state == .succeeded, summary.verification == .verifiedSuccess,
              let audit = summary.environmentEvidence, let signed = audit.signedProof,
              let certificate = audit.verificationCertificate else {
            throw EnvironmentEvidenceError.independentVerificationRequired
        }
        // This resolver reads the parent's durable admission and recompiles the
        // original authenticated request, including predicates and dependencies.
        let expectation = try expectationResolver(originalRequest)
        let now = self.now()
        let proof = signed.proof, verified = certificate.verification
        try summary.validateEnvironmentEvidence(trustedRuntimeKey: trustedRuntimeKey, request: originalRequest)
        try signed.verify(trustedPublicKey: trustedRuntimeKey, using: RCIREd25519Verifier())
        try certificate.verify(trustedHostPublicKey: trustedHostPublicKey, using: RCIREd25519Verifier())
        let expectedValueDigest = try ExecutionEvidenceDigest.capabilityValue(expectation.expectedValue)
        guard expectation.binding.executionID == originalRequest.requestID.uuidString,
              expectation.binding.capabilityID == originalRequest.capabilityID,
              expectation.binding.environmentID == (try EnvironmentIdentity.environmentID(from: originalRequest.item)),
              expectation.binding.runtimeID == RemoteWire.runtimeID(trustedRuntimeKey),
              expectation.binding.keyID == ExecutionEvidenceDigest.sha256(trustedRuntimeKey),
              try proof.binding.canonicalData() == expectation.binding.canonicalData(),
              try verified.binding.canonicalData() == expectation.binding.canonicalData(),
              proof.challengeNonce == expectation.challengeNonce, verified.challengeNonce == expectation.challengeNonce,
              proof.sequence == expectation.expectedSequence, verified.sequence == expectation.expectedSequence,
              proof.predicateID == expectation.predicateID, verified.predicateID == expectation.predicateID,
              verified.proofDigest == (try proof.digest),
              expectation.binding.responseDigest == expectedValueDigest,
              verified.expectedValueDigest == expectedValueDigest, verified.observedValueDigest == expectedValueDigest,
              verified.outcome == .succeeded else { throw EnvironmentEvidenceError.bindingMismatch }
        guard now >= proof.observedAtMilliseconds, now < proof.expiresAtMilliseconds,
              now < expectation.deadlineMilliseconds,
              proof.issuedAtMilliseconds >= expectation.minimumIssuedAtMilliseconds,
              proof.expiresAtMilliseconds <= expectation.deadlineMilliseconds,
              now - proof.issuedAtMilliseconds <= expectation.maximumAgeMilliseconds,
              now >= verified.verifiedAtMilliseconds, verified.verifiedAtMilliseconds >= proof.observedAtMilliseconds,
              now < verified.expiresAtMilliseconds, verified.expiresAtMilliseconds <= proof.expiresAtMilliseconds,
              now - verified.verifiedAtMilliseconds <= expectation.maximumAgeMilliseconds else {
            throw EnvironmentEvidenceError.invalidTime
        }
    }
}

/// Explicit local enrollment pins keys separately from relay/catalog responses.
/// Contextual catalogs expire, and routes always retain their original target.
public final class RemoteRuntimeRegistry: @unchecked Sendable {
    private struct Catalog { let capabilities: [RemoteCapabilityDescriptor]; let expiresAt: Int64 }
    private struct Peer {
        let client: RemoteLinkClient
        let descriptor: RemoteRuntimeDescriptor
        let generation: UUID
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
        var peer = peers[descriptor.runtimeID] ?? Peer(client: client, descriptor: descriptor, generation: token)
        guard peer.client === client,
              peer.descriptor.runtimeID == descriptor.runtimeID,
              peer.descriptor.deviceID == descriptor.deviceID,
              peer.descriptor.operatingSystem == descriptor.operatingSystem,
              peer.descriptor.architecture == descriptor.architecture,
              peer.catalogs.count < 8 || peer.catalogs[itemKey(item)] != nil else { throw RemoteLinkError.idempotencyConflict }
        peer.catalogs[itemKey(item)] = Catalog(capabilities: capabilities, expiresAt: expires)
        // Authenticated re-enrollment of this same peer restores observation of
        // its existing executions. Explicit removal discards the peer, so a
        // later enrollment receives a new generation and cannot revive owners.
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
    fileprivate func reflectors(item: String?, environmentVerificationPolicy: RemoteEnvironmentVerificationPolicy?) -> [any CapabilityReflector] {
        lock.lock(); defer { lock.unlock() }
        return peers.values.compactMap { peer in
            guard peer.online else { return nil }
            let catalog = item.map { peer.catalogs[itemKey($0)] } ?? peer.catalogs.values.first { $0.expiresAt > now() }
            guard let catalog, catalog.expiresAt > now() else { return nil }
            return RemoteRoutedReflector(client: peer.client, descriptor: peer.descriptor,
                catalog: catalog.capabilities, itemKey: item.map(itemKey), expiresAt: catalog.expiresAt, now: now,
                environmentVerificationPolicy: environmentVerificationPolicy,
                isEnrolled: { [weak self] in self?.isEnrolled(peer.descriptor.runtimeID, client: peer.client, generation: peer.generation) == true },
                failed: { [weak self] in self?.markOffline(runtimeID: peer.descriptor.runtimeID) })
        }
    }
    private func isEnrolled(_ id: String, client: RemoteLinkClient, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard let peer = peers[id] else { return false }
        return peer.online && peer.client === client && peer.generation == generation
    }
    fileprivate func invalidate() { lock.lock(); defer { lock.unlock() }; peers = peers.mapValues { var peer = $0; peer.catalogs = [:]; return peer } }
    private func itemKey(_ item: String) -> String { RemoteWire.digest(Data(item.utf8)) }
}

public final class RemoteCapabilitySource: ContextualCapabilityReflectorSource {
    public let id = "rightclick.link"
    private let registry: RemoteRuntimeRegistry
    private let environmentVerificationPolicy: RemoteEnvironmentVerificationPolicy?
    public init(registry: RemoteRuntimeRegistry, environmentVerificationPolicy: RemoteEnvironmentVerificationPolicy? = nil) {
        self.registry = registry; self.environmentVerificationPolicy = environmentVerificationPolicy
    }
    public func reflectors() -> [any CapabilityReflector] { registry.reflectors(item: nil, environmentVerificationPolicy: environmentVerificationPolicy) }
    public func reflectors(for item: ContentItem) -> [any CapabilityReflector] {
        registry.reflectors(item: Self.raw(item), environmentVerificationPolicy: environmentVerificationPolicy)
    }
    public func invalidateSnapshot() { registry.invalidate() }
    static func raw(_ item: ContentItem) -> String { item.text ?? item.url ?? item.path ?? item.display }
}

private final class RemoteRoutedReflector: CapabilityRoutingReflector, CapabilityExecutionStatusReflector {
    let id: String
    let executionEnvironment: RuntimeEnvironment
    let completionWaitSeconds: TimeInterval = 0
    private let client: RemoteLinkClient
    private let catalog: [RemoteCapabilityDescriptor]
    private let itemKey: String?
    private let expiresAt: Int64
    private let now: () -> Int64
    private let environmentVerificationPolicy: RemoteEnvironmentVerificationPolicy?
    private let isEnrolled: () -> Bool
    private let failed: () -> Void
    private struct ExecutionHandle {
        let request: RemoteExecutionRequest
        let capability: Capability
        let verification: VerificationSpec?
        var pending: Task<ExecutionRecord, Never>?
        var record: ExecutionRecord
    }
    private let executionLock = NSLock()
    private var executions: [String: ExecutionHandle] = [:]
    init(client: RemoteLinkClient, descriptor: RemoteRuntimeDescriptor, catalog: [RemoteCapabilityDescriptor],
         itemKey: String?, expiresAt: Int64, now: @escaping () -> Int64,
         environmentVerificationPolicy: RemoteEnvironmentVerificationPolicy?,
         isEnrolled: @escaping () -> Bool, failed: @escaping () -> Void) {
        self.client = client; self.catalog = catalog; self.itemKey = itemKey; self.expiresAt = expiresAt
        self.now = now; self.environmentVerificationPolicy = environmentVerificationPolicy
        self.isEnrolled = isEnrolled; self.failed = failed
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
        guard executions.count < 1024 else { executionLock.unlock(); throw RemoteLinkError.limitExceeded }
        executions[executionID] = .init(request: request, capability: capability, verification: verification,
            pending: nil, record: initial)
        let pending = Task { () -> ExecutionRecord in
            let record: ExecutionRecord
            do {
                guard self.isEnrolled() else { throw RemoteLinkError.unavailable }
                let summary = try await self.client.send(request).summary
                guard self.isEnrolled() else { throw RemoteLinkError.unauthorized }
                record = self.record(summary, originalRequest: request, executionID: executionID, capability: capability, verification: verification)
            } catch {
                self.failed()
                record = ExecutionRecord(executionId: executionID, actionId: capability.id, state: .unknown,
                    message: "Remote delivery or result integrity is uncertain. Do not retry on another node.")
            }
            self.store(record, executionID: executionID)
            ExecutionStore.shared.put(record)
            return record
        }
        executions[executionID]?.pending = pending
        executionLock.unlock()
        return initial
    }

    func executionStatus(executionID: String, cursor: Int64, limit: Int, maximumBytes: Int) async throws -> ExecutionRecord? {
        guard let handle = handle(executionID) else { return nil }
        // An initial response can complete before context_run returns. Awaiting
        // that one pending exchange never starts another consequential request.
        let initial = await handle.pending?.value ?? handle.record
        guard let live = initial.lifecycle else { return initial }
        guard isEnrolled() else { throw RemoteLinkError.unavailable }
        let request = client.makeStatusRequest(for: handle.request, executionID: live.executionID,
            originatingRequestID: UUID(uuidString: live.originatingRequestID), cursor: cursor, limit: limit,
            maximumBytes: min(maximumBytes, 16_384))
        do {
            let summary = try await client.send(request).summary
            guard isEnrolled() else { throw RemoteLinkError.unauthorized }
            let record = self.record(summary, originalRequest: handle.request, executionID: executionID,
                capability: handle.capability, verification: handle.verification)
            store(record, executionID: executionID)
            return record
        } catch {
            if error as? RemoteLinkError == .connectionLost || error as? RemoteLinkError == .unavailable {
                failed()
                return .init(executionId: executionID, actionId: handle.capability.id, state: .unknown,
                    message: "Remote execution cannot currently be observed. Its effect is uncertain; do not redispatch.")
            }
            throw error
        }
    }

    private func handle(_ executionID: String) -> ExecutionHandle? {
        executionLock.lock(); defer { executionLock.unlock() }; return executions[executionID]
    }
    private func store(_ record: ExecutionRecord, executionID: String) {
        if record.lifecycle?.terminal == true {
            // Retain the authenticated terminal alias before a delayed initial
            // Core record can overwrite it. Pages remain observational views.
            do { try ExecutionStore.shared.putTerminalSnapshot(record) }
            catch { return }
        }
        executionLock.lock(); defer { executionLock.unlock() }
        executions[executionID]?.record = record; executions[executionID]?.pending = nil
    }
    private func record(_ summary: RemoteExecutionSummary, originalRequest: RemoteExecutionRequest, executionID: String,
                               capability: Capability, verification: VerificationSpec?) -> ExecutionRecord {
        if originalRequest.capabilityID == "environment:execute" {
            do {
                guard let environmentVerificationPolicy else { throw EnvironmentEvidenceError.independentVerificationRequired }
                try environmentVerificationPolicy.verify(summary, originalRequest: originalRequest,
                    trustedRuntimeKey: client.target.publicKey)
            } catch {
                return unverifiedEnvironmentRecord(summary, executionID: executionID, capability: capability)
            }
        }
        let predicates = summary.verification == .verifiedSuccess ? (verification?.predicates ?? []).map {
            PredicateVerification(predicate: $0, evaluated: true, passed: true, message: "Authenticated execution-node observation.")
        } : []
        return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
            state: summary.state ?? .unknown, message: "Authenticated execution-node lifecycle: " + (summary.executionLifecycle?.phase.rawValue ?? summary.error?.rawValue ?? "completed"),
            result: summary.result, events: summary.evidenceExecutionID.map { ["remote evidence " + $0] } ?? [],
            evidence: OutcomeEvidence(type: "remote_" + summary.observationBoundary.rawValue,
                boundary: originalRequest.capabilityID == "environment:execute" ?
                    "Parent host independently adjudicated this exact admitted environment invocation." :
                    "Enrolled execution-node assertion; canonical receipts and private observations remain on that node.",
                outcomeVerified: summary.verification == .verifiedSuccess, observationBoundary: summary.observationBoundary),
            verification: OutcomeVerification(status: summary.verification, predicates: predicates),
            rcirEvents: summary.eventPage?.events, rcirEventPage: summary.eventPage, lifecycle: summary.executionLifecycle,
            environmentEvidence: summary.environmentEvidence)
    }

    private func unverifiedEnvironmentRecord(_ summary: RemoteExecutionSummary, executionID: String,
                                             capability: Capability) -> ExecutionRecord {
        let accepted = summary.providerAcceptance == .accepted
        let active = summary.executionLifecycle?.terminal == false
        let failedAssertion = summary.state == .failed
        let unknown = summary.state == .unknown || (!accepted && !active && !failedAssertion)
        let lifecycle = summary.executionLifecycle.map { live in
            ExecutionLifecycle(version: live.version, executionID: live.executionID, originatingRequestID: live.originatingRequestID,
                runtimeID: live.runtimeID, taskID: live.taskID, generation: live.generation, taskShape: live.taskShape,
                phase: active ? live.phase : (unknown ? .unknown : (accepted ? .completed : .failed)),
                semanticOutcome: unknown ? .unknown : .unverified, sequence: live.sequence, terminal: live.terminal,
                providerAcceptance: live.providerAcceptance, verification: .unverified, observationBoundary: .none,
                evidenceID: live.evidenceID, receiptAvailable: live.receiptAvailable, signedReceiptAvailable: live.signedReceiptAvailable)
        }
        return .init(executionId: executionID, actionId: capability.id, title: capability.title,
            state: active ? (summary.state == .awaitingUser ? .awaitingUser : .started) : (unknown ? .unknown : (failedAssertion ? .failed : .accepted)),
            message: "The execution node reported a result. Parent verification against its admitted request and independent observer is unavailable or did not match.",
            result: summary.result, events: summary.evidenceExecutionID.map { ["unverified remote assertion " + $0] } ?? [],
            evidence: .init(type: "remote_environment_assertion", boundary: "Child assertion retained for audit; parent outcome remains unverified.",
                outcomeVerified: false, observationBoundary: OutcomeObservationBoundary.none), verification: .init(status: .unverified, predicates: []),
            rcirEvents: summary.eventPage?.events, rcirEventPage: summary.eventPage, lifecycle: lifecycle,
            environmentEvidence: summary.environmentEvidence)
    }
    private func routeID(_ capability: String) -> String { "remote:" + RemoteWire.digest(client.target.publicKey) + ":" + RemoteWire.digest(Data(capability.utf8)) }
}
