import Foundation
import RightClickCore

/// Host-owned admission. MainActor preserves the native Mac execution thread
/// and serializes the original engine on headless nodes as well.
@MainActor
public final class RemoteExecutionDispatcher {
    public let identity: RemoteNodeIdentity
    private let engine: CapabilityEngine
    private let ledger: RemoteReplayLedger
    private let enabled: Bool
    private let now: () -> Int64
    private let localApproval: (any RemoteLocalApproval)?
    private var grants: [String: RemoteCallerGrant]
    private var activeExecutions: Set<String> = []
    private var observationEnvelopes: [String: Int64] = [:]
    private var lastObservationTime: Int64 = 0

    public init(engine: CapabilityEngine, identity: RemoteNodeIdentity, ledger: RemoteReplayLedger,
                grants: [RemoteCallerGrant], enabled: Bool = false, localApproval: (any RemoteLocalApproval)? = nil,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard grants.count <= 64, Set(grants.map(\.callerID)).count == grants.count else { throw RemoteLinkError.malformed }
        self.engine = engine; self.identity = identity; self.ledger = ledger
        self.enabled = enabled; self.now = now
        self.localApproval = localApproval
        self.grants = Dictionary(uniqueKeysWithValues: grants.map { ($0.callerID, $0) })
    }
    public func revoke(callerID: String) { grants.removeValue(forKey: callerID) }
    public func establishOutboundConnection(to relay: SimulatedLinkRelay) async throws {
        guard enabled else { throw RemoteLinkError.disabled }
        await relay.attachOutboundNode(self, runtimeID: identity.runtimeID)
    }

    public func handle(_ bytes: Data) throws -> Data {
        try engine.withExclusiveAccess { try handleExclusively(bytes) }
    }
    private func handleExclusively(_ bytes: Data) throws -> Data {
        guard enabled else { throw RemoteLinkError.disabled }
        let envelope = try RemoteWire.decode(SignedRemoteMessage.self, bytes, maximum: RemoteWire.maximumWireBytes)
        let request = try RemoteWire.decode(RemoteExecutionRequest.self, envelope.payload)
        guard let grant = grants[request.callerID] else { throw RemoteLinkError.unauthenticated }
        try envelope.authenticate(domain: RemoteWire.requestDomain, trustedKey: grant.publicKey)
        let admittedAt = now()
        try request.validate(now: admittedAt)
        guard request.targetRuntimeID == identity.runtimeID, request.targetDeviceID == identity.deviceID else { throw RemoteLinkError.wrongRuntime }
        try authorize(request, grant: grant)
        observationEnvelopes = observationEnvelopes.filter { $0.value > admittedAt }
        let observationalKeys = ["request:" + request.callerID + ":" + request.requestID.uuidString,
                                 "nonce:" + request.callerID + ":" + request.nonce.base64EncodedString()]
        guard observationalKeys.allSatisfy({ observationEnvelopes[$0] == nil }) else { throw RemoteLinkError.replay }
        if request.operation == .status {
            return try statusResult(for: request, grant: grant, admittedAt: admittedAt)
        }
        // No arbitrary target-relative file access or observer references in v1.
        // Host-owned RCIR observers still execute locally and independently.
        if request.operation != .runtime {
            do {
                let item = try engine.inspect(request.item, allowFileInputs: false)
                guard item.kind == "text" || item.kind == "web_url" else { throw RemoteLinkError.unauthorized }
            } catch { throw RemoteLinkError.unauthorized }
        }
        if let previous = try ledger.reserve(request, now: admittedAt) {
            var retained = previous
            if let live = previous.executionLifecycle, !live.terminal {
                var poll = request; poll.operation = .status; poll.item = ""; poll.arguments = nil; poll.verification = nil
                poll.status = .init(originatingRequestID: UUID(uuidString: live.originatingRequestID)!, executionID: live.executionID)
                retained = try currentStatus(for: poll, grant: grant)
            }
            return try result(for: request, summary: retained, reused: true)
        }
        let summary: RemoteExecutionSummary
        var enteredEngine = false
        do {
            switch request.operation {
            case .runtime:
                let descriptor = RemoteRuntimeDescriptor(version: 1, runtimeID: identity.runtimeID,
                    deviceID: identity.deviceID, operatingSystem: engine.runtimeEnvironment.operatingSystem,
                    architecture: engine.runtimeEnvironment.architecture, operations: grant.operations.sorted { $0.rawValue < $1.rawValue })
                summary = RemoteExecutionSummary(runtime: descriptor, lifecycle: [.requested, .authorized, .delivered, .discovered], completedAtMilliseconds: now())
            case .actions:
                let capabilities = try engine.capabilities(for: request.item, allowFileInputs: false).capabilities
                let exported = try capabilities.filter { grant.capabilityIDs.contains($0.id) && !$0.id.hasPrefix("remote:") && engine.runtimeEnvironment.supports($0) }.map { capability in
                    RemoteCapabilityDescriptor(id: capability.id, contractDigest: try Self.contractDigest(capability),
                        title: capability.title, safety: capability.safety, invocation: capability.invocation,
                        supportLevel: capability.supportLevel, runtimeRequirements: capability.runtimeRequirements,
                        requiresConfirmation: capability.requiresConfirmation)
                }
                summary = RemoteExecutionSummary(capabilities: exported, lifecycle: [.requested, .authorized, .delivered, .discovered], completedAtMilliseconds: now())
            case .run:
                guard let capability = try engine.capabilities(for: request.item, allowFileInputs: false).capabilities.first(where: { $0.id == request.capabilityID && !$0.id.hasPrefix("remote:") }),
                      try Self.contractDigest(capability) == request.capabilityDigest else { throw RemoteLinkError.unavailable }
                // Consent comes only from the host's approval implementation.
                let ticket = capability.requiresConfirmation ? localApproval?.approval(for: request, capabilityDigest: request.capabilityDigest!) : nil
                let confirmed = try ticket?.permits(request, capabilityDigest: request.capabilityDigest!, now: now()) ?? false
                enteredEngine = true
                let record = try engine.begin(id: capability.id, item: request.item, confirmed: confirmed,
                    arguments: request.arguments, verification: request.verification,
                    expectedCapability: capability, admissionCheck: {
                        guard self.now() >= admittedAt else { throw RemoteLinkError.clockRollback }
                        try request.validate(now: self.now())
                        if confirmed, try ticket?.permits(request, capabilityDigest: request.capabilityDigest!, now: self.now()) != true { throw RemoteLinkError.unauthorized }
                        guard let current = self.grants[request.callerID], current.publicKey == grant.publicKey else { throw RemoteLinkError.unauthorized }
                        try self.authorize(request, grant: current)
                    }, allowFileInputs: false)
                var projected = Self.project(record, request: request, runtimeID: identity.runtimeID,
                    exportsValues: grant.exportValueCapabilityIDs.contains(capability.id), now: now())
                if let live = projected.executionLifecycle {
                    let history = Self.safeEvents(record.rcirEvents ?? [], exportsValues: grant.exportValueCapabilityIDs.contains(capability.id))
                    projected.eventPage = try rcirExecutionEventPage(history, after: 0, limit: 64,
                        maximumBytes: 16_384, terminal: live.terminal)
                }
                summary = projected
                if record.lifecycle?.terminal == false { activeExecutions.insert(record.executionId) }
            default: throw RemoteLinkError.unsupportedOperation
            }
        } catch {
            // A thrown provider call can already have effects. A durable unknown
            // reservation prevents a fresh network retry from dispatching again.
            summary = RemoteExecutionSummary(state: enteredEngine ? .unknown : .unavailable,
                policy: enteredEngine ? .evaluated : .denied, providerAcceptance: enteredEngine ? .unknown : .notInvoked,
                lifecycle: [.requested, .authorized, .delivered, .unknown],
                error: (error as? RemoteLinkError) ?? .executionUncertain, completedAtMilliseconds: max(now(), admittedAt))
        }
        try summary.validate()
        let events = summary.executionLifecycle.flatMap { ExecutionStore.shared.get($0.executionID)?.rcirEvents }.map {
            Self.safeEvents($0, exportsValues: grant.exportValueCapabilityIDs.contains(request.capabilityID ?? ""))
        }
        try ledger.complete(request, summary: summary, events: events)
        return try result(for: request, summary: summary, reused: false)
    }
    private func authorize(_ request: RemoteExecutionRequest, grant: RemoteCallerGrant) throws {
        guard grant.operations.contains(request.operation),
              (request.operation != .run && request.operation != .status) || request.capabilityID.map(grant.capabilityIDs.contains) == true else { throw RemoteLinkError.unauthorized }
    }
    private func result(for request: RemoteExecutionRequest, summary: RemoteExecutionSummary, reused: Bool) throws -> Data {
        try summary.validate()
        let result = RemoteExecutionResult(version: 1, requestID: request.requestID,
            requestDigest: RemoteWire.digest(try RemoteWire.encode(request)), callerID: request.callerID,
            runtimeID: identity.runtimeID, deviceID: identity.deviceID, idempotencyKey: request.idempotencyKey,
            reused: reused, summary: summary)
        return try SignedRemoteMessage.seal(result, domain: RemoteWire.resultDomain, signer: identity)
    }
    private func statusResult(for request: RemoteExecutionRequest, grant: RemoteCallerGrant, admittedAt: Int64) throws -> Data {
        // Cache applies only to nonconsequential observations. Expired envelopes
        // can never validate again; consequential journal entries never expire.
        guard admittedAt >= lastObservationTime else { throw RemoteLinkError.clockRollback }
        observationEnvelopes = observationEnvelopes.filter { $0.value > admittedAt }
        let keys = ["request:" + request.callerID + ":" + request.requestID.uuidString,
                    "nonce:" + request.callerID + ":" + request.nonce.base64EncodedString()]
        guard keys.allSatisfy({ observationEnvelopes[$0] == nil }), try !ledger.hasSeenEnvelope(request) else { throw RemoteLinkError.replay }
        guard observationEnvelopes.count + 2 <= 2048 else { throw RemoteLinkError.limitExceeded }
        let summary = try currentStatus(for: request, grant: grant)
        for key in keys { observationEnvelopes[key] = request.expiresAtMilliseconds }
        lastObservationTime = admittedAt
        return try result(for: request, summary: summary, reused: true)
    }

    private func currentStatus(for request: RemoteExecutionRequest, grant: RemoteCallerGrant) throws -> RemoteExecutionSummary {
        guard let query = request.status else { throw RemoteLinkError.malformed }
        let (retained, retainedEvents) = try ledger.statusSnapshot(request)
        guard let previous = retained.executionLifecycle else { throw RemoteLinkError.unavailable }
        if previous.terminal {
            var snapshot = retained
            snapshot.eventPage = try rcirExecutionEventPage(retainedEvents ?? [], after: query.cursor,
                limit: query.limit, maximumBytes: query.maximumBytes, terminal: true)
            // Unknown restart evidence can have a previous sequence but no page.
            if retainedEvents == nil, previous.sequence != 0 { throw RemoteLinkError.unavailable }
            return snapshot
        }
        let snapshot: RemoteExecutionSummary
        var events: [RCIRExecutionEvent]? = nil
        if activeExecutions.contains(query.executionID) {
            let record = engine.executionStatus(query.executionID)
            guard let current = record.lifecycle, current.taskID == previous.taskID,
                  current.generation == previous.generation else { throw RemoteLinkError.staleGeneration }
            var projected = Self.project(record, request: request, runtimeID: identity.runtimeID,
                exportsValues: grant.exportValueCapabilityIDs.contains(request.capabilityID ?? ""), now: now())
            events = record.rcirEvents.map { Self.safeEvents($0, exportsValues: grant.exportValueCapabilityIDs.contains(request.capabilityID ?? "")) }
            projected.eventPage = try rcirExecutionEventPage(events ?? [], after: query.cursor, limit: query.limit,
                maximumBytes: query.maximumBytes, terminal: current.terminal)
            snapshot = projected
        } else {
            // The host process lost live ownership. Preserve binding and refuse
            // redispatch; a surviving reservation is not evidence of completion.
            var unknown = retained; unknown.state = .unknown; unknown.providerAcceptance = .unknown
            unknown.verification = .unverified; unknown.observationBoundary = .none; unknown.result = nil
            unknown.error = .executionUncertain
            unknown.executionLifecycle = .init(executionID: previous.executionID,
                originatingRequestID: previous.originatingRequestID, runtimeID: previous.runtimeID,
                taskID: previous.taskID, generation: previous.generation, taskShape: previous.taskShape,
                phase: .unknown, semanticOutcome: .unknown, sequence: previous.sequence, terminal: true,
                providerAcceptance: .unknown, verification: .unverified, observationBoundary: .none)
            let history = retainedEvents ?? []
            guard Int64(history.count) == previous.sequence else { throw RemoteLinkError.storageUnavailable }
            unknown.eventPage = try rcirExecutionEventPage(history, after: query.cursor, limit: query.limit,
                maximumBytes: query.maximumBytes, terminal: true)
            snapshot = unknown; events = history
        }
        try ledger.updateExecution(request, summary: snapshot, events: events)
        if snapshot.executionLifecycle?.terminal == true { activeExecutions.remove(query.executionID) }
        return snapshot
    }

    private static func safeEvents(_ events: [RCIRExecutionEvent], exportsValues: Bool) -> [RCIRExecutionEvent] {
        events.map { .init(sequence: $0.sequence, time: $0.time, kind: $0.kind, value: exportsValues ? $0.value : .null) }
    }

    static func contractDigest(_ capability: Capability) throws -> String {
        RemoteWire.digest(try CapabilityDispatchContract.canonicalData(capability))
    }
    private static func project(_ record: ExecutionRecord, request: RemoteExecutionRequest, runtimeID: String, exportsValues: Bool, now: Int64) -> RemoteExecutionSummary {
        var summary = RemoteExecutionSummary(state: record.state, policy: .evaluated,
            evidenceExecutionID: record.executionId, lifecycle: [.requested, .authorized, .delivered, .executing], completedAtMilliseconds: now)
        if let live = record.lifecycle {
            summary.executionLifecycle = ExecutionLifecycle(version: live.version, executionID: live.executionID,
                originatingRequestID: request.status?.originatingRequestID.uuidString ?? request.requestID.uuidString,
                runtimeID: runtimeID, taskID: live.taskID, generation: live.generation, taskShape: live.taskShape,
                phase: live.phase, semanticOutcome: live.semanticOutcome, sequence: live.sequence, terminal: live.terminal,
                providerAcceptance: live.providerAcceptance, verification: live.verification,
                observationBoundary: live.observationBoundary, evidenceID: live.evidenceID,
                receiptAvailable: live.receiptAvailable, signedReceiptAvailable: live.signedReceiptAvailable)
            summary.providerAcceptance = RemoteProviderAcceptance(rawValue: live.providerAcceptance.rawValue)!
            summary.verification = live.verification; summary.observationBoundary = live.observationBoundary
            if let page = record.rcirEventPage {
                summary.eventPage = .init(events: safeEvents(page.events, exportsValues: exportsValues),
                    nextCursor: page.nextCursor, hasMore: page.hasMore, terminal: page.terminal)
            }
            summary.result = exportsValues ? record.result : nil
            if live.providerAcceptance == .accepted { summary.lifecycle.append(.providerAccepted) }
            if live.terminal { summary.lifecycle.append(live.verification == .verifiedSuccess ? .verified : .unverified) }
            return summary
        }
        switch record.state {
        case .awaitingUser:
            summary.policy = .confirmationRequired; summary.lifecycle.append(.awaitingUser)
        case .unavailable, .unsupported:
            summary.policy = .denied; summary.error = .unavailable; summary.lifecycle.append(.providerRejected)
        case .started, .unknown, .cancelled:
            summary.state = .unknown; summary.providerAcceptance = .unknown
            summary.error = .executionUncertain; summary.lifecycle.append(.unknown)
        case .rejected:
            if record.rcir?.leaseConsumed == false || record.evidence.type == "rcir_admission_denied" { summary.policy = .denied }
            else { summary.providerAcceptance = .rejected }
            summary.lifecycle.append(.providerRejected)
        case .accepted, .succeeded, .failed:
            let external = record.evidence.observationBoundary == .externalState || record.evidence.type == "rcir_http_readback" || record.evidence.type == "rcir_http_readback_mismatch"
            let completePredicates = record.verification.map {
                !$0.predicates.isEmpty && $0.predicates.allSatisfy { $0.evaluated && $0.passed }
            } ?? false
            let verified = record.state == .succeeded && record.evidence.outcomeVerified &&
                ((record.verification?.status == .verifiedSuccess && completePredicates) ||
                 (external && record.rcir?.outcome == "succeeded" && record.rcir?.leaseConsumed == true))
            let failedPredicates = record.verification.map {
                $0.status == .verifiedFailure && !$0.predicates.isEmpty &&
                $0.predicates.allSatisfy(\.evaluated) && $0.predicates.contains { !$0.passed }
            } ?? false
            let mismatch = record.state == .failed &&
                (failedPredicates || (external && record.rcir?.outcome == "failed" && record.rcir?.leaseConsumed == true))
            if verified || mismatch || record.state == .accepted || record.state == .succeeded ||
                (record.state == .failed && record.verification != nil) {
                summary.providerAcceptance = .accepted; summary.lifecycle.append(.providerAccepted)
                if verified || mismatch {
                    summary.verification = verified ? .verifiedSuccess : .verifiedFailure
                    summary.observationBoundary = external ? .externalState : .returnedValue
                    summary.lifecycle.append(verified ? .verified : .unverified)
                } else {
                    summary.state = .accepted; summary.lifecycle.append(.unverified)
                }
            } else {
                summary.providerAcceptance = record.rcir?.leaseConsumed == false ? .notInvoked : .unknown
                if summary.providerAcceptance == .notInvoked { summary.policy = .denied }
                summary.lifecycle.append(.providerRejected)
            }
        }
        return summary
    }
}
