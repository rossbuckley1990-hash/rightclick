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

    public init(engine: CapabilityEngine, identity: RemoteNodeIdentity, ledger: RemoteReplayLedger,
                grants: [RemoteCallerGrant], enabled: Bool = false, localApproval: (any RemoteLocalApproval)? = nil,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard grants.count <= 64, Set(grants.map(\.callerID)).count == grants.count else { throw RemoteLinkError.malformed }
        self.engine = engine; self.identity = identity; self.ledger = ledger
        self.enabled = enabled; self.now = now
        self.localApproval = localApproval
        self.grants = Dictionary(uniqueKeysWithValues: grants.map { ($0.callerID, $0) })
    }
    public func revoke(callerID: String) {
        // Retained RCIR checks may run on a headless MCP worker. Revocation
        // shares the same Core executor as every grant read, including status.
        engine.withExclusiveAccess { _ = grants.removeValue(forKey: callerID) }
    }
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
        // No arbitrary target-relative file access or observer references in v1.
        // Host-owned RCIR observers still execute locally and independently.
        if request.operation != .runtime {
            do {
                let item = try engine.inspect(request.item, allowFileInputs: false)
                guard item.kind == "text" || item.kind == "web_url" else { throw RemoteLinkError.unauthorized }
            } catch { throw RemoteLinkError.unauthorized }
        }
        let ownedStatus: (executionID: String, verification: VerificationSpec?)?
        if request.operation == .status {
            ownedStatus = try ledger.statusBinding(request)
            try validateStatusCapability(request)
        } else { ownedStatus = nil }
        if let previous = try ledger.reserve(request, now: admittedAt) {
            return try result(for: request, summary: previous, reused: true)
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
                let exported = try capabilities.filter { grant.capabilityIDs.contains($0.id) && $0.routingOrigin == nil && !$0.id.hasPrefix("remote:") && engine.runtimeEnvironment.supports($0) }.map { capability in
                    RemoteCapabilityDescriptor(id: capability.id, contractDigest: try Self.contractDigest(capability),
                        title: capability.title, safety: capability.safety, invocation: capability.invocation,
                        supportLevel: capability.supportLevel, runtimeRequirements: capability.runtimeRequirements,
                        requiresConfirmation: capability.requiresConfirmation)
                }
                summary = RemoteExecutionSummary(capabilities: exported, lifecycle: [.requested, .authorized, .delivered, .discovered], completedAtMilliseconds: now())
            case .run:
                guard let capability = try engine.capabilities(for: request.item, allowFileInputs: false).capabilities.first(where: { $0.id == request.capabilityID && $0.routingOrigin == nil && !$0.id.hasPrefix("remote:") }),
                      try Self.contractDigest(capability) == request.capabilityDigest else { throw RemoteLinkError.unavailable }
                // Consent comes only from the host's approval implementation.
                let ticket = capability.requiresConfirmation ? localApproval?.approval(for: request, capabilityDigest: request.capabilityDigest!) : nil
                let confirmed = try ticket?.permits(request, capabilityDigest: request.capabilityDigest!, now: now()) ?? false
                enteredEngine = true
                let record = try engine.beginReserved(executionID: ledger.executionID(forRun: request), id: capability.id, item: request.item, confirmed: confirmed,
                    arguments: request.arguments, verification: request.verification,
                    expectedCapability: capability, admissionCheck: {
                        guard self.now() >= admittedAt else { throw RemoteLinkError.clockRollback }
                        try request.validate(now: self.now())
                        if confirmed, try ticket?.permits(request, capabilityDigest: request.capabilityDigest!, now: self.now()) != true { throw RemoteLinkError.unauthorized }
                        guard let current = self.grants[request.callerID], current.publicKey == grant.publicKey else { throw RemoteLinkError.unauthorized }
                        try self.authorize(request, grant: current)
                    }, continuingAdmissionCheck: {
                        guard let current = self.grants[request.callerID], current.publicKey == grant.publicKey else { throw RemoteLinkError.unauthorized }
                        try self.authorize(request, grant: current)
                    }, allowFileInputs: false)
                summary = Self.project(record, verification: request.verification, now: now())
            case .status:
                // Re-evaluate after the durable status reservation. Never call
                // begin, consume an effect lease, or redispatch an original task.
                try validateStatusCapability(request)
                guard let current = grants[request.callerID], current.publicKey == grant.publicKey else { throw RemoteLinkError.unauthorized }
                try authorize(request, grant: current)
                try request.validate(now: now())
                guard let ownedStatus else { throw RemoteLinkError.unauthorized }
                summary = Self.project(engine.executionStatus(ownedStatus.executionID), verification: ownedStatus.verification, now: now())
            default: throw RemoteLinkError.unsupportedOperation
            }
        } catch {
            if request.operation == .status { throw error }
            // A thrown provider call can already have effects. A durable unknown
            // reservation prevents a fresh network retry from dispatching again.
            summary = RemoteExecutionSummary(state: enteredEngine ? .unknown : .unavailable,
                policy: enteredEngine ? .evaluated : .denied, providerAcceptance: enteredEngine ? .unknown : .notInvoked,
                evidenceExecutionID: enteredEngine ? (try? ledger.executionID(forRun: request).uuidString) : nil,
                lifecycle: [.requested, .authorized, .delivered, .unknown],
                error: (error as? RemoteLinkError) ?? .executionUncertain, completedAtMilliseconds: max(now(), admittedAt))
        }
        try summary.validate()
        try ledger.complete(request, summary: summary)
        return try result(for: request, summary: summary, reused: false)
    }
    private func validateStatusCapability(_ request: RemoteExecutionRequest) throws {
        guard let capability = try engine.capabilities(for: request.item, allowFileInputs: false).capabilities.first(where: {
            $0.id == request.capabilityID && $0.routingOrigin == nil && !$0.id.hasPrefix("remote:")
        }), engine.runtimeEnvironment.supports(capability),
              try Self.contractDigest(capability) == request.capabilityDigest else { throw RemoteLinkError.unavailable }
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
    static func contractDigest(_ capability: Capability) throws -> String {
        RemoteWire.digest(try CapabilityDispatchContract.canonicalData(capability))
    }
    private static func project(_ record: ExecutionRecord, verification: VerificationSpec?, now: Int64) -> RemoteExecutionSummary {
        var summary = RemoteExecutionSummary(state: record.state, policy: .evaluated,
            evidenceExecutionID: record.executionId, lifecycle: [.requested, .authorized, .delivered, .executing], completedAtMilliseconds: now)
        if record.locallyAdmittedRCIR && record.rcir?.leaseConsumed == true { summary.taskPhase = record.rcir?.phase }
        switch record.state {
        case .awaitingUser:
            if record.locallyAdmittedRCIR && record.rcir?.leaseConsumed == true && record.rcir?.phase == "inputRequired" {
                summary.providerAcceptance = .accepted
            } else { summary.policy = .confirmationRequired }
            summary.lifecycle.append(.awaitingUser)
        case .unavailable, .unsupported:
            summary.policy = .denied; summary.error = .unavailable; summary.lifecycle.append(.providerRejected)
        case .started where record.locallyAdmittedRCIR && record.rcir?.leaseConsumed == true &&
            ["accepted", "working", "cancelRequested"].contains(record.rcir?.phase ?? ""):
            summary.providerAcceptance = .accepted
            summary.lifecycle.append(.providerAccepted)
        case .started, .unknown, .cancelled:
            summary.state = .unknown; summary.providerAcceptance = .unknown
            summary.error = .executionUncertain; summary.lifecycle.append(.unknown)
        case .rejected:
            if record.rcir?.leaseConsumed == false || record.evidence.type == "rcir_admission_denied" { summary.policy = .denied }
            else { summary.providerAcceptance = .rejected }
            summary.lifecycle.append(.providerRejected)
        case .accepted, .succeeded, .failed:
            let external = record.evidence.observationBoundary == .externalState
            let completePredicates = record.verification?.validatesSuccess(expected: verification) == true
            let verified = record.state == .succeeded && record.evidence.outcomeVerified &&
                ((record.verification?.status == .verifiedSuccess && completePredicates) ||
                 (verification == nil && external && record.rcir?.outcome == "succeeded" && record.locallyAdmittedRCIR && record.rcir?.leaseConsumed == true))
            let failedPredicates = record.verification?.validatesFailure(expected: verification) == true
            let mismatch = record.state == .failed &&
                (failedPredicates || (verification == nil && external && record.rcir?.outcome == "failed" && record.locallyAdmittedRCIR && record.rcir?.leaseConsumed == true))
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
