import Foundation
import RightClickProtocol

public enum EnvironmentFabricError: Error, Equatable {
    case confirmationRequired, unauthorized, unknownEnvironment, invalidProfile, invalidRuntime
    case capacityExceeded, invalidRequest, dependencyAlreadyConsumed, enrollmentUnavailable
}

/// Opaque admission produced by host code after authenticating the caller. It
/// cannot be decoded from MCP arguments, and is valid only at its issuing host.
public struct EnvironmentAdmissionContext: Sendable {
    public let executionID: String
    public let requestDigest: Data
    public let environmentID: String?
    public let runtimeID: String
    public let subjectPublicKey: Data
    public let leaseID: UUID?
    fileprivate let hostToken: UUID
    fileprivate let requiredDependencies: [ExecutionDependency]
    fileprivate init(executionID: String, requestDigest: Data, environmentID: String?, runtimeID: String,
                     subjectPublicKey: Data, leaseID: UUID?, hostToken: UUID, requiredDependencies: [ExecutionDependency] = []) {
        self.executionID = executionID; self.requestDigest = requestDigest; self.environmentID = environmentID
        self.runtimeID = runtimeID; self.subjectPublicKey = subjectPublicKey; self.leaseID = leaseID
        self.hostToken = hostToken; self.requiredDependencies = requiredDependencies
    }
}

public struct EnvironmentEnrollmentChallenge: Codable, Sendable {
    public let enrollmentID: String
    public let challenge: Data
    public let expiresAtMilliseconds: Int64
}

public struct EnvironmentRecord: Codable, Sendable {
    public let intent: EnvironmentCreateIntent
    public var handle: EnvironmentHandle?
    public var state: EnvironmentState
    public var acceptance: EnvironmentProviderAcceptance?
    public var observation: EnvironmentObservation?
    public var lastPresentObservation: EnvironmentObservation?
    public var runtime: EnvironmentRuntimeObservation?
    public var enrollmentCertificate: SignedChildRuntimeEnrollmentCertificate?
    public var enrollmentChallenge: EnvironmentEnrollmentChallenge?
    public var enrollmentConsumed: Bool
    public var revoked: Bool
    public var leaseIDs: [UUID]
    public let creatingLeaseID: UUID?
    public var stopIntentID: String?
    public var destroyIntentID: String?
    public var events: [String]
    public var environmentID: String { intent.environmentID }
    public var lineage: EnvironmentLineage { intent.lineage }
}

private struct EnvironmentDispatchReservation: Codable {
    let executionID: String
    let environmentID: String
    let capabilityID: String
    let requestDigest: Data
    let callerEnvironmentID: String?
    let callerRuntimeID: String
    let callerPublicKey: Data
    let requiredDependencies: [ExecutionDependency]
    let admittedAtMilliseconds: Int64
}
private struct EnvironmentCreationCount: Codable, Equatable { var children = 0; var descendants = 0 }
private struct EnvironmentDependencyReservation: Codable, Equatable {
    let certificateDigest: String
    let executionID: String
    let requestDigest: String
}
private struct EnvironmentWorkload: Codable {
    let environmentID: String
    let challenge: String
    let nonce: Data
    let requestDigest: String
    let leaseDigest: String
    let runtimeID: String
    let executableSHA256: String
    let publicKey: Data
    let issuedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    var proofDigest: String?
}
private struct EnvironmentExecutionFinalization: Codable {
    enum Origin: String, Codable { case rcirHost, builtinChallenge }
    let origin: Origin
    let state: ExecutionState
    let recordDigest: String
}
private struct EnvironmentFabricState: Codable {
    var records: [String: EnvironmentRecord] = [:]
    var correlations: [String: String] = [:]
    var leases = CapabilityLeaseReservationState()
    var creations: [String: EnvironmentCreationCount] = [:]
    var dispatches: [String: EnvironmentDispatchReservation] = [:]
    var executions: [String: ExecutionRecord] = [:]
    var finalizations: [String: EnvironmentExecutionFinalization] = [:]
    var workloads: [String: EnvironmentWorkload] = [:]
    var proofReservations: [String: SignedExecutionProof] = [:]
    var proofs: [String: SignedExecutionProof] = [:]
    var certificates: [String: SignedExecutionVerificationCertificate] = [:]
    var dependencies: [String: EnvironmentDependencyReservation] = [:]
    var totalReservedCostUnits: Int64 = 0
    var clockHighWaterMilliseconds: Int64 = 0
}

/// Host-owned lifecycle broker. The fixed provider, profiles, operator pins and
/// enrollment verifier are installation choices, never user-selected arguments.
/// Every dispatch reservation is flushed before crossing the provider boundary.
public final class EnvironmentCoordinator: EnvironmentDependencyReservationStore, @unchecked Sendable {
    public typealias EnrollmentVerifier = (EnvironmentHandle, EnvironmentRuntimeManifest,
        EnvironmentEnrollmentChallenge, EnvironmentObservation, Data) throws -> SignedChildRuntimeEnrollmentCertificate

    public let provider: any EnvironmentProvider
    public let hostRuntimeID: String
    public let profiles: [String: EnvironmentRuntimeManifest]
    public let profileCeilings: [String: EnvironmentSpec]
    private let journal: EnvironmentJournal<EnvironmentFabricState>
    private let trustedRootIssuerPublicKeys: [Data]
    private let operatorPublicKey: Data
    private let maximumEnvironments: Int
    private let maximumTotalCostUnits: Int64
    private let now: () -> Int64
    private let enrollmentVerifier: EnrollmentVerifier?
    private let hostToken = UUID()

    public init(provider: any EnvironmentProvider, journalDirectory: URL, hostRuntimeID: String,
                trustedRootIssuerPublicKeys: [Data], profiles: [String: EnvironmentRuntimeManifest],
                profileCeilings: [String: EnvironmentSpec], operatorPublicKey: Data,
                maximumEnvironments: Int = 2, maximumTotalCostUnits: Int64 = 1_000_000,
                enrollmentVerifier: EnrollmentVerifier? = nil,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard EnvironmentIdentity.isRuntimeID(hostRuntimeID), operatorPublicKey.count == 32,
              !trustedRootIssuerPublicKeys.isEmpty, trustedRootIssuerPublicKeys.count <= 32,
              trustedRootIssuerPublicKeys.allSatisfy({ $0.count == 32 }),
              !profiles.isEmpty, profiles.count <= 16, Set(profiles.keys) == Set(profileCeilings.keys),
              (1...16).contains(maximumEnvironments), (1...1_000_000).contains(maximumTotalCostUnits),
              EnvironmentIdentity.isName(provider.id) else { throw EnvironmentFabricError.invalidRequest }
        for (id, ceiling) in profileCeilings {
            guard id == ceiling.profileID else { throw EnvironmentFabricError.invalidProfile }
        }
        self.provider = provider; self.hostRuntimeID = hostRuntimeID; self.profiles = profiles
        self.profileCeilings = profileCeilings; self.operatorPublicKey = operatorPublicKey
        self.trustedRootIssuerPublicKeys = trustedRootIssuerPublicKeys; self.maximumEnvironments = maximumEnvironments
        self.maximumTotalCostUnits = maximumTotalCostUnits; self.enrollmentVerifier = enrollmentVerifier; self.now = now
        journal = try EnvironmentJournal(directory: journalDirectory, identity: hostRuntimeID, initial: EnvironmentFabricState())
        let recovered = try journal.snapshot()
        try validateRecovery(recovered)
        if let recovery = provider as? any EnvironmentProviderRecovery {
            for record in recovered.records.values {
                if let observed = record.lastPresentObservation {
                    try recovery.restoreObservedBinding(intent: record.intent, observation: observed)
                }
            }
        }
    }

    /// Host API: this is local operator authority installed with the broker.
    /// The integration must derive requestDigest from the actual canonical request.
    public func rootAdmission(executionID: String, requestDigest: Data) throws -> EnvironmentAdmissionContext {
        try validateInvocation(executionID, requestDigest)
        return .init(executionID: executionID, requestDigest: requestDigest, environmentID: nil,
                     runtimeID: hostRuntimeID, subjectPublicKey: operatorPublicKey, leaseID: nil, hostToken: hostToken)
    }

    /// Host API called only after Link has authenticated this exact subject.
    /// Enrolled identity and signed lease bindings are checked again at dispatch.
    public func authenticatedAdmission(executionID: String, requestDigest: Data, subjectPublicKey: Data,
                                       runtimeID: String, environmentID: String, leaseID: UUID) throws -> EnvironmentAdmissionContext {
        try validateInvocation(executionID, requestDigest)
        let context = EnvironmentAdmissionContext(executionID: executionID, requestDigest: requestDigest,
            environmentID: environmentID, runtimeID: runtimeID, subjectPublicKey: subjectPublicKey, leaseID: leaseID, hostToken: hostToken)
        try validateAuthority(context, state: journal.snapshot(), at: now())
        return context
    }

    /// Host-installed causal prerequisites, never caller-selected proof bytes or
    /// trust keys. Exact one-use consumption is durable before effects begin.
    public func requiringDependencies(_ dependencies: [ExecutionDependency], admission: EnvironmentAdmissionContext) throws -> EnvironmentAdmissionContext {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard dependencies.count <= 8, Set(dependencies.map(\.proofDigest)).count == dependencies.count else {
            throw EnvironmentFabricError.invalidRequest
        }
        let context = EnvironmentAdmissionContext(executionID: admission.executionID, requestDigest: admission.requestDigest,
            environmentID: admission.environmentID, runtimeID: admission.runtimeID, subjectPublicKey: admission.subjectPublicKey,
            leaseID: admission.leaseID, hostToken: admission.hostToken, requiredDependencies: dependencies)
        try journal.transaction { state in
            try validateAuthority(admission, state: state, at: now())
            for (dependency, validated) in try checkedDependencies(dependencies, admission: context, state: state, at: now()) where dependency.oneUse {
                let next = EnvironmentDependencyReservation(certificateDigest: validated.certificateDigest,
                    executionID: context.executionID, requestDigest: hex(context.requestDigest))
                if let old = state.dependencies[dependency.proofDigest] {
                    guard old == next else { throw EnvironmentFabricError.dependencyAlreadyConsumed }
                } else {
                    guard state.dependencies.count < 128 else { throw EnvironmentFabricError.capacityExceeded }
                    state.dependencies[dependency.proofDigest] = next
                }
            }
        }
        return context
    }

    public func canSatisfyDependencies(_ dependencies: [ExecutionDependency]) throws -> Bool {
        guard dependencies.count <= 8, Set(dependencies.map(\.proofDigest)).count == dependencies.count else { return false }
        let context = try rootAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: 0, count: 32))
        let state = try journal.snapshot()
        do {
            _ = try checkedDependencies(dependencies, admission: context, state: state, at: now())
            return !dependencies.contains { $0.oneUse && state.dependencies[$0.proofDigest] != nil }
        } catch { return false }
    }

    public func records() throws -> [EnvironmentRecord] {
        try journal.snapshot().records.values.sorted { $0.environmentID < $1.environmentID }
    }
    public func record(environmentID: String) throws -> EnvironmentRecord? { try journal.snapshot().records[environmentID] }
    public func executionRecord(_ executionID: String) throws -> ExecutionRecord? { try journal.snapshot().executions[executionID] }
    public func executionEnvironmentID(_ executionID: String) throws -> String? {
        try journal.snapshot().dispatches[executionID]?.environmentID
    }
    /// Receipt access retains the authenticated owner's immutable enrollment
    /// pins. Revocation prevents effects without erasing that owner's history.
    public func canReadExecution(executionID: String, subjectPublicKey: Data? = nil,
                                 runtimeID: String? = nil, environmentID: String? = nil) throws -> Bool {
        let state = try journal.snapshot()
        guard let dispatch = state.dispatches[executionID] else { return false }
        if let subjectPublicKey, let runtimeID, let environmentID {
            guard dispatch.callerPublicKey == subjectPublicKey, dispatch.callerRuntimeID == runtimeID,
                  dispatch.callerEnvironmentID == environmentID,
                  let enrollment = state.records[environmentID]?.enrollmentCertificate?.certificate.claim else { return false }
            return enrollment.publicKey == subjectPublicKey && enrollment.runtimeID == runtimeID
        }
        return subjectPublicKey == nil && runtimeID == nil && environmentID == nil
    }
    public func enrollmentChallenge(environmentID: String) throws -> EnvironmentEnrollmentChallenge? {
        try journal.snapshot().records[environmentID]?.enrollmentChallenge
    }

    public func create(spec: EnvironmentSpec, correlationID: String, admission: EnvironmentAdmissionContext,
                       confirmed: Bool) throws -> EnvironmentRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard confirmed else { throw EnvironmentFabricError.confirmationRequired }
        guard provider.support.supportsCreate, provider.support.enforcesTTL else { throw EnvironmentError.unsupported }
        guard EnvironmentIdentity.isCanonicalID(correlationID), let ceiling = profileCeilings[spec.profileID],
              spec.isWithin(ceiling) else { throw EnvironmentFabricError.invalidProfile }
        if let caller = admission.environmentID { _ = try observe(environmentID: caller) }
        let timestamp = now()
        let reserved: (EnvironmentRecord, Bool) = try journal.transaction { state in
            try validateAuthority(admission, state: state, at: timestamp)
            let capability = admission.environmentID == nil ? "environment:create" : "environment:create-child"
            if let oldID = state.correlations[correlationID], let old = state.records[oldID] {
                guard old.intent.spec == spec, old.intent.creationExecutionID == admission.executionID,
                      old.lineage.parentEnvironmentID == admission.environmentID,
                      let dispatch = state.dispatches[admission.executionID], dispatch.requestDigest == admission.requestDigest,
                      dispatch.capabilityID == capability else { throw EnvironmentError.idempotencyConflict }
                return (old, false)
            }
            guard state.records.count < maximumEnvironments,
                  spec.resources.maximumCostUnits <= maximumTotalCostUnits - state.totalReservedCostUnits else {
                throw EnvironmentFabricError.capacityExceeded
            }
            let identifier = UUID().uuidString
            let lineage: EnvironmentLineage
            if let parentID = admission.environmentID {
                guard let parent = state.records[parentID], parent.state == .ready || parent.state == .running,
                      !parent.revoked, let runtime = parent.runtime, runtime.runtimeID == admission.runtimeID,
                      parent.lineage.depth < EnvironmentLimits.maximumDepth,
                      timestamp <= parent.intent.expiresAtMilliseconds - spec.lifetimeMilliseconds else { throw EnvironmentFabricError.unauthorized }
                lineage = try .init(rootEnvironmentID: parent.lineage.rootEnvironmentID, parentEnvironmentID: parentID,
                                    parentExecutionID: admission.executionID, parentRuntimeID: runtime.runtimeID, depth: parent.lineage.depth + 1)
                try reserveCreationCounts(admission, spec: spec, state: &state, at: timestamp)
            } else {
                lineage = try .init(rootEnvironmentID: identifier, parentExecutionID: admission.executionID,
                                    parentRuntimeID: hostRuntimeID, depth: 0)
            }
            let intent = try EnvironmentCreateIntent(environmentID: identifier, correlationID: correlationID,
                creationExecutionID: admission.executionID, spec: spec, lineage: lineage,
                createdAtMilliseconds: timestamp, expiresAtMilliseconds: timestamp + spec.lifetimeMilliseconds)
            try reserveDispatch(admission, capabilityID: capability, environmentID: identifier, spec: spec, state: &state, at: timestamp)
            let record = EnvironmentRecord(intent: intent, handle: nil, state: .creating, acceptance: nil, observation: nil,
                lastPresentObservation: nil, runtime: nil, enrollmentCertificate: nil, enrollmentChallenge: nil,
                enrollmentConsumed: false, revoked: false, leaseIDs: [], creatingLeaseID: admission.leaseID, stopIntentID: nil, destroyIntentID: nil,
                events: ["Create intent durably reserved before provider dispatch."])
            state.records[identifier] = record; state.correlations[correlationID] = identifier
            state.totalReservedCostUnits += spec.resources.maximumCostUnits
            state.executions[admission.executionID] = execution(admission.executionID, capability, .started, "Creation reserved.", identifier)
            return (record, true)
        }
        if reserved.1 {
            try revalidateEffect(admission, environmentID: reserved.0.environmentID)
            let acceptance = safeAcceptance { try provider.create(reserved.0.intent) }
            try journal.transaction { state in
                state.records[reserved.0.environmentID]?.acceptance = acceptance
                // API acceptance binds a locator, never existence. Retain that
                // exact identity even if an asynchronous create is not visible yet.
                if let resourceID = acceptance.providerResourceID {
                    let bound = try handle(reserved.0.intent, resourceID: resourceID)
                    if let old = state.records[reserved.0.environmentID]?.handle, old != bound { throw EnvironmentError.unsafeDuplicate }
                    state.records[reserved.0.environmentID]?.handle = bound
                }
                if state.finalizations[admission.executionID] == nil {
                    state.executions[admission.executionID] = execution(admission.executionID,
                        admission.environmentID == nil ? "environment:create" : "environment:create-child", acceptanceState(acceptance),
                        "Provider response retained; independent existence observation is required.", reserved.0.environmentID)
                }
            }
        }
        return try observe(environmentID: reserved.0.environmentID)
    }

    /// Independent observation of an exact retained correlation. Never retries create.
    public func observe(environmentID: String) throws -> EnvironmentRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard let record = try journal.snapshot().records[environmentID] else { throw EnvironmentFabricError.unknownEnvironment }
        let observation = try exactObservation(record)
        return try journal.transaction { state in
            guard var current = state.records[environmentID] else { throw EnvironmentFabricError.unknownEnvironment }
            let reopenedForCleanup = current.state == .destroyed && observation.presence == .present
            let unboundAbsence = observation.presence == .absent && current.handle == nil
            current.observation = observation
            switch observation.presence {
            case .present:
                current.lastPresentObservation = observation
                let observedHandle = try handle(current.intent, resourceID: observation.providerResourceID!)
                if let old = current.handle, old != observedHandle { throw EnvironmentError.unsafeDuplicate }
                if reopenedForCleanup && current.handle == nil { throw EnvironmentError.unsafeDuplicate }
                current.handle = observedHandle
                if current.revoked, current.destroyIntentID != nil {
                    current.runtime = nil; current.state = .stopping
                    append("Original uncertain create became identifiable; retained intent remains cleanup-only.", to: &current)
                }
                if reopenedForCleanup {
                    current.runtime = nil; current.revoked = true; current.state = .stopping
                    append("Exact retained resource reappeared after absence; reopened only for revoked cleanup.", to: &current)
                }
                if let enrolled = current.runtime, current.destroyIntentID == nil {
                    let stopped = [.stopping, .destroying, .failed].contains(observation.state)
                    let changed = observation.runtime.map { $0.publicKey != enrolled.publicKey || $0.manifest != enrolled.manifest } ?? false
                    if stopped || changed {
                        current.runtime = nil; current.revoked = true; current.state = .failed
                        for id in current.leaseIDs { try state.leases.revoke(leaseID: id) }
                        append("Independent runtime identity changed or stopped; authority revoked permanently.", to: &current)
                    } else if observation.runtime == nil || ![.ready, .running].contains(observation.state) {
                        current.state = .unknown
                        append("Independent runtime observation missing; effects suspended.", to: &current)
                    }
                }
                // Created/bootstrapped provider state is not runtime enrollment.
                if current.destroyIntentID == nil, !current.revoked,
                   current.state == .creating || (current.state == .unknown && (current.runtime == nil || (observation.runtime != nil && [.ready, .running].contains(observation.state)))) {
                    current.state = current.runtime == nil ? .bootstrapping : .ready
                }
            case .absent:
                current.runtime = nil; current.revoked = true
                for id in current.leaseIDs { try state.leases.revoke(leaseID: id) }
                let descendantsAbsent = descendants(environmentID, state: state).allSatisfy {
                    $0.state == .destroyed && $0.observation?.presence == .absent
                }
                if !descendantsAbsent {
                    for child in Array(state.records.values) where child.lineage.parentEnvironmentID == environmentID {
                        try reserveTeardown(child.environmentID, state: &state)
                    }
                }
                // Without a bound resource locator, absence cannot establish
                // that an already-issued create will not materialize later.
                current.state = !unboundAbsence && descendantsAbsent ? .destroyed : .unknown
            case .unknown: current.state = .unknown
            }
            append("Independent provider presence: " + observation.presence.rawValue, to: &current)
            state.records[environmentID] = current
            if reopenedForCleanup {
                // Revoke the complete subtree and flush idempotent cleanup IDs
                // before any stop/delete. No runtime or lease can be reactivated.
                try reserveTeardown(environmentID, state: &state)
                current = state.records[environmentID]!
            }
            if unboundAbsence {
                try reserveTeardown(environmentID, state: &state)
                current = state.records[environmentID]!
                current.state = .unknown
                append("Unbound create absence remains uncertain; cleanup intent retained without replaying create.", to: &current)
                state.records[environmentID] = current
            }
            if !reopenedForCleanup, state.finalizations[current.intent.creationExecutionID] == nil,
               var execution = state.executions[current.intent.creationExecutionID], execution.actionId.hasSuffix("create") || execution.actionId.hasSuffix("create-child") {
                execution.state = observation.presence == .present ? .succeeded : observation.presence == .unknown ? .unknown : .failed
                execution.message = observation.presence == .present ? "Environment existence independently observed; runtime enrollment is pending." : "Environment creation could not be established."
                execution.evidence = OutcomeEvidence(type: "environment-presence", boundary: observation.observationBoundary,
                    outcomeVerified: observation.presence == .present, observationBoundary: .externalState)
                state.executions[execution.executionId] = execution
            }
            return current
        }
    }

    public func bootstrap(environmentID: String, admission: EnvironmentAdmissionContext, confirmed: Bool) throws -> EnvironmentRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard confirmed else { throw EnvironmentFabricError.confirmationRequired }
        guard provider.support.supportsBootstrap else { throw EnvironmentError.unsupported }
        let timestamp = now()
        let reserved: (EnvironmentHandle, EnvironmentRuntimeManifest, Bool) = try journal.transaction { state in
            try validateAuthority(admission, state: state, at: timestamp)
            try validateTarget(admission, environmentID: environmentID, state: state)
            guard var record = state.records[environmentID], let handle = record.handle,
                  record.observation?.presence == .present, !record.revoked, record.destroyIntentID == nil,
                  let manifest = profiles[record.intent.spec.profileID], timestamp < record.intent.expiresAtMilliseconds else {
                throw EnvironmentFabricError.invalidRuntime
            }
            let dispatch = try reserveDispatch(admission, capabilityID: "environment:bootstrap", environmentID: environmentID,
                spec: nil, state: &state, at: timestamp)
            if dispatch {
                guard record.enrollmentChallenge == nil, record.runtime == nil else { throw EnvironmentFabricError.invalidRuntime }
                record.state = .bootstrapping
                record.enrollmentChallenge = .init(enrollmentID: UUID().uuidString, challenge: randomNonce(),
                    expiresAtMilliseconds: min(record.intent.expiresAtMilliseconds, timestamp + 60_000))
                append("Bootstrap and single-use runtime enrollment challenge reserved.", to: &record)
                state.records[environmentID] = record
                state.executions[admission.executionID] = execution(admission.executionID, "environment:bootstrap", .started, "Bootstrap reserved.", environmentID)
            }
            return (handle, manifest, dispatch)
        }
        if reserved.2 {
            try revalidateEffect(admission, environmentID: environmentID)
            let acceptance = safeAcceptance { try provider.bootstrap(reserved.0, manifest: reserved.1) }
            try journal.transaction { state in
                state.records[environmentID]?.acceptance = acceptance
                if state.finalizations[admission.executionID] == nil {
                    state.executions[admission.executionID] = execution(admission.executionID, "environment:bootstrap", acceptanceState(acceptance),
                        "Bootstrap response retained; verified runtime enrollment remains required.", environmentID)
                }
            }
        }
        return try observe(environmentID: environmentID)
    }

    /// Host-only enrollment. A callback installed when the broker is constructed
    /// verifies proof of possession and parent pins; request arguments cannot replace it.
    public func enroll(environmentID: String, response: Data) throws -> EnvironmentRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard response.count <= 131_072, let enrollmentVerifier else { throw EnvironmentFabricError.enrollmentUnavailable }
        guard let record = try journal.snapshot().records[environmentID], !record.revoked,
              !record.enrollmentConsumed, let handle = record.handle, let challenge = record.enrollmentChallenge,
              let manifest = profiles[record.intent.spec.profileID], now() < challenge.expiresAtMilliseconds else {
            throw EnvironmentFabricError.invalidRuntime
        }
        let observation = try exactObservation(record)
        guard observation.presence == .present else { throw EnvironmentFabricError.invalidRuntime }
        let signedCertificate = try enrollmentVerifier(handle, manifest, challenge, observation, response)
        let certificate = try signedCertificate.verify(trustedPublicKey: operatorPublicKey, now: now())
        let claim = certificate.claim
        guard claim.handle == handle, claim.manifest == manifest, claim.enrollmentID == challenge.enrollmentID,
              claim.challenge == challenge.challenge, claim.expiresAtMilliseconds <= challenge.expiresAtMilliseconds,
              certificate.environmentObservedAtMilliseconds == observation.observedAtMilliseconds else {
            throw EnvironmentFabricError.invalidRuntime
        }
        let runtime = try EnvironmentRuntimeObservation(manifest: claim.manifest, publicKey: claim.publicKey,
            observedAtMilliseconds: certificate.runtimeObservedAtMilliseconds, observationBoundary: certificate.runtimeObservationBoundary)
        // A separately observed runtime, when available, must agree with enrollment.
        if let independent = observation.runtime {
            guard independent.manifest == manifest, independent.publicKey == runtime.publicKey else { throw EnvironmentFabricError.invalidRuntime }
        }
        return try journal.transaction { state in
            guard var current = state.records[environmentID], !current.enrollmentConsumed, !current.revoked,
                  current.enrollmentChallenge?.enrollmentID == challenge.enrollmentID,
                  now() < challenge.expiresAtMilliseconds else { throw EnvironmentFabricError.invalidRuntime }
            current.runtime = runtime; current.enrollmentConsumed = true; current.observation = observation; current.state = .ready
            current.enrollmentCertificate = signedCertificate
            append("Runtime possession and manifest verified by the installed enrollment verifier.", to: &current)
            state.records[environmentID] = current
            return current
        }
    }

    /// Install a host-issued root lease against the already enrolled subject.
    public func installSignedLease(_ signed: SignedCapabilityLease) throws {
        try journal.transaction { state in
            let id = signed.body.environmentID.uuidString
            guard var record = state.records[id], !record.revoked, let runtime = record.runtime,
                  record.lineage.depth == 0,
                  signed.body.issuingExecutionID == record.intent.creationExecutionID,
                  trustedRootIssuerPublicKeys.contains(signed.body.issuerPublicKey),
                  signed.body.expiresAtMilliseconds <= record.intent.expiresAtMilliseconds else { throw EnvironmentFabricError.unauthorized }
            try validateLeaseResources(signed.body, spec: record.intent.spec)
            try state.leases.registerRoot(signed, trustedIssuerPublicKey: signed.body.issuerPublicKey,
                expectedSubjectPublicKey: runtime.publicKey, expectedSubjectRuntimeID: runtime.runtimeID,
                expectedEnvironmentID: signed.body.environmentID, nowMilliseconds: now())
            if !record.leaseIDs.contains(signed.body.leaseID) { record.leaseIDs.append(signed.body.leaseID) }
            state.records[id] = record
        }
    }

    public func delegateSignedLease(_ child: SignedCapabilityLease, parentLeaseID: UUID, admission: EnvironmentAdmissionContext) throws {
        try journal.transaction { state in
            try validateAuthority(admission, state: state, at: now())
            guard admission.leaseID == parentLeaseID, let parentID = admission.environmentID,
                  var record = state.records[child.body.environmentID.uuidString], !record.revoked,
                  record.lineage.parentEnvironmentID == parentID,
                  child.body.issuingExecutionID == record.intent.creationExecutionID,
                  child.body.expiresAtMilliseconds <= record.intent.expiresAtMilliseconds,
                  let runtime = record.runtime else { throw EnvironmentFabricError.unauthorized }
            try validateLeaseResources(child.body, spec: record.intent.spec)
            try state.leases.allocateDelegation(child, parentLeaseID: parentLeaseID,
                authenticatedSubjectPublicKey: admission.subjectPublicKey, authenticatedRuntimeID: admission.runtimeID,
                authenticatedEnvironmentID: UUID(uuidString: parentID)!, expectedChildSubjectPublicKey: runtime.publicKey,
                expectedChildRuntimeID: runtime.runtimeID, expectedChildEnvironmentID: child.body.environmentID,
                trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys, nowMilliseconds: now())
            if !record.leaseIDs.contains(child.body.leaseID) { record.leaseIDs.append(child.body.leaseID) }
            state.records[record.environmentID] = record
        }
    }

    /// Narrow approved workload only. Provider acceptance remains accepted until
    /// a separate observation reads the exact challenge from the resource.
    public func executeChallenge(environmentID: String, challenge: String, admission: EnvironmentAdmissionContext,
                                 confirmed: Bool) throws -> ExecutionRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard confirmed else { throw EnvironmentFabricError.confirmationRequired }
        guard provider.support.supportsChallenge else { throw EnvironmentError.unsupported }
        guard !challenge.isEmpty, challenge.utf8.count <= EnvironmentLimits.maximumChallengeBytes,
              challenge.utf8.allSatisfy({ (33...126).contains($0) }) else { throw EnvironmentFabricError.invalidRequest }
        _ = try observe(environmentID: environmentID)
        let timestamp = now()
        let reserved: (EnvironmentHandle, Bool) = try journal.transaction { state in
            try validateAuthority(admission, state: state, at: timestamp)
            try validateTarget(admission, environmentID: environmentID, state: state)
            guard var record = state.records[environmentID], let handle = record.handle, let runtime = record.runtime,
                  record.state == .ready || record.state == .running, !record.revoked, record.destroyIntentID == nil,
                  timestamp < record.intent.expiresAtMilliseconds else { throw EnvironmentFabricError.invalidRuntime }
            if let old = state.workloads[admission.executionID] {
                guard old.challenge == challenge, old.environmentID == environmentID,
                      old.requestDigest == hex(admission.requestDigest) else { throw EnvironmentError.idempotencyConflict }
                return (handle, false)
            }
            guard state.workloads.count < 16 else { throw EnvironmentFabricError.capacityExceeded }
            let dispatch = try reserveDispatch(admission, capabilityID: "environment:execute", environmentID: environmentID,
                spec: nil, state: &state, at: timestamp)
            guard dispatch else { throw EnvironmentError.idempotencyConflict }
            // Even a local operator dispatch into an enrolled runtime must have a
            // signed narrow workload grant, and consume its quota before dispatch.
            let leaseID: UUID
            if let admitted = admission.leaseID { leaseID = admitted }
            else {
                guard let installed = record.leaseIDs.first(where: {
                    guard let budget = state.leases.budget(for: $0) else { return false }
                    guard budget.remainingExecutions > 0, budget.signedLease.body.capabilityIDs.contains("environment:execute") else { return false }
                    let targetContext = EnvironmentAdmissionContext(executionID: admission.executionID, requestDigest: admission.requestDigest,
                        environmentID: environmentID, runtimeID: runtime.runtimeID, subjectPublicKey: runtime.publicKey, leaseID: $0, hostToken: hostToken)
                    return (try? validateAuthority(targetContext, state: state, at: timestamp)) != nil
                }) else { throw EnvironmentFabricError.unauthorized }
                leaseID = installed
                let invocation = try leaseInvocation(admission, leaseID: leaseID, capabilityID: "environment:execute", spec: record.intent.spec)
                _ = try state.leases.reserveExecution(invocation, authenticatedSubjectPublicKey: runtime.publicKey,
                    authenticatedRuntimeID: runtime.runtimeID, authenticatedEnvironmentID: UUID(uuidString: environmentID)!,
                    trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys, nowMilliseconds: timestamp)
            }
            guard let lease = state.leases.budget(for: leaseID)?.signedLease.body else { throw EnvironmentFabricError.unauthorized }
            state.workloads[admission.executionID] = EnvironmentWorkload(environmentID: environmentID, challenge: challenge,
                nonce: randomNonce(), requestDigest: hex(admission.requestDigest), leaseDigest: hex(try lease.digest()),
                runtimeID: runtime.runtimeID, executableSHA256: runtime.manifest.executableSHA256, publicKey: runtime.publicKey,
                issuedAtMilliseconds: timestamp, expiresAtMilliseconds: min(record.intent.expiresAtMilliseconds, lease.expiresAtMilliseconds, timestamp + 900_000), proofDigest: nil)
            record.state = .running; state.records[environmentID] = record
            state.executions[admission.executionID] = execution(admission.executionID, "environment:execute", .started, "Workload intent reserved.", environmentID)
            return (handle, true)
        }
        if reserved.1 {
            try revalidateEffect(admission, environmentID: environmentID)
            let acceptance = safeAcceptance { try provider.executeChallenge(reserved.0, executionID: admission.executionID, challenge: challenge) }
            try journal.transaction { state in
                state.records[environmentID]?.acceptance = acceptance
                if state.finalizations[admission.executionID] == nil {
                    state.executions[admission.executionID] = execution(admission.executionID, "environment:execute", acceptanceState(acceptance),
                        "Provider response retained; workload postcondition requires independent observation.", environmentID)
                }
            }
        }
        guard let result = try executionRecord(admission.executionID) else { throw EnvironmentFabricError.invalidRequest }
        return result
    }

    public func observeChallenge(executionID: String) throws -> CapabilityValue? {
        let state = try journal.snapshot()
        guard let work = state.workloads[executionID], let record = state.records[work.environmentID],
              let handle = record.handle, now() >= work.issuedAtMilliseconds, now() < work.expiresAtMilliseconds else {
            return nil
        }
        return try provider.observeChallenge(handle, executionID: executionID).map(CapabilityValue.string)
    }

    /// Host publication from the existing RCIR engine. A success publication is
    /// checked against this broker's independent workload read before retention.
    public func storeExecutionRecord(_ record: ExecutionRecord) throws {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard (try JSONEncoder().encode(record)).count <= 65_536 else { throw EnvironmentFabricError.invalidRequest }
        let digest = try executionRecordDigest(record)
        let snapshot = try journal.snapshot()
        if let finalization = snapshot.finalizations[record.executionId] {
            guard finalization.recordDigest == digest else { throw EnvironmentError.idempotencyConflict }
            return
        }
        if record.state == .succeeded, let work = snapshot.workloads[record.executionId] {
            guard let observed = try observeChallenge(executionID: record.executionId),
                  try observed.canonicalData() == CapabilityValue.string(work.challenge).canonicalData() else {
                throw EnvironmentFabricError.invalidRequest
            }
        }
        try journal.transaction { state in
            guard let dispatch = state.dispatches[record.executionId],
                  record.actionId == dispatch.capabilityID else { throw EnvironmentFabricError.invalidRequest }
            guard state.finalizations[record.executionId] == nil else { throw EnvironmentError.idempotencyConflict }
            state.executions[record.executionId] = record
            state.finalizations[record.executionId] = .init(origin: .rcirHost, state: record.state, recordDigest: digest)
            if let work = state.workloads[record.executionId], var resource = state.records[work.environmentID],
               resource.runtime != nil, resource.destroyIntentID == nil, !resource.revoked {
                resource.state = record.state == .unknown ? .unknown : runtimeIsFresh(resource, at: now()) ? .ready : .unknown
                state.records[work.environmentID] = resource
            }
        }
    }

    public func verifyChallenge(executionID: String) throws -> ExecutionRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        let state = try journal.snapshot()
        guard let workload = state.workloads[executionID], let record = state.records[workload.environmentID],
              let handle = record.handle else { throw EnvironmentFabricError.invalidRequest }
        let observed: String?
        do { observed = try provider.observeChallenge(handle, executionID: executionID) } catch { observed = nil }
        return try journal.transaction { state in
            guard var result = state.executions[executionID] else { throw EnvironmentFabricError.invalidRequest }
            // Resource readback remains current without reopening the engine's
            // immutable adjudication of the original caller postcondition.
            if state.finalizations[executionID] != nil { return result }
            let fresh = now() >= workload.issuedAtMilliseconds && now() < workload.expiresAtMilliseconds
            result.state = !fresh || observed == nil ? .unknown : observed == workload.challenge ? .succeeded : .failed
            result.message = result.state == .succeeded ? "Exact challenge independently observed." : result.state == .failed ? "Observed challenge did not match the requested postcondition." : "Independent observation is unavailable or expired."
            result.result = observed.map(CapabilityValue.string)
            result.evidence = OutcomeEvidence(type: "environment-challenge", boundary: "Configured provider separate challenge observation.",
                outcomeVerified: result.state == .succeeded, observationBoundary: .externalState)
            state.executions[executionID] = result
            if state.records[workload.environmentID]?.destroyIntentID == nil, state.records[workload.environmentID]?.runtime != nil {
                state.records[workload.environmentID]?.state = observed == nil ? .unknown : .ready
            }
            return result
        }
    }

    /// Independent observer input is pinned against the retained workload; child
    /// supplied values never define the expected postcondition or target resource.
    public func observeExecution(_ request: ExecutionObservationRequest) throws -> CapabilityValue? {
        let state = try journal.snapshot()
        guard let work = state.workloads[request.binding.executionID], let record = state.records[work.environmentID],
              let handle = record.handle, request.binding.environmentID == work.environmentID,
              request.binding.requestDigest == work.requestDigest, request.binding.runtimeID == work.runtimeID,
              request.binding.executableSHA256 == work.executableSHA256, request.binding.leaseDigest == work.leaseDigest,
              request.challengeNonce == work.nonce, request.predicateID == "environment.challenge.equals",
              try request.expectedValue.canonicalData() == CapabilityValue.string(work.challenge).canonicalData(),
              now() < work.expiresAtMilliseconds else {
            throw EnvironmentEvidenceError.bindingMismatch
        }
        return try provider.observeChallenge(handle, executionID: request.binding.executionID).map(CapabilityValue.string)
    }

    public func proofExpectation(executionID: String) throws -> ExecutionProofExpectation {
        let state = try journal.snapshot()
        guard let work = state.workloads[executionID], let record = state.records[work.environmentID] else { throw EnvironmentFabricError.invalidRequest }
        let parent = record.lineage.parentEnvironmentID
        let binding = try ExecutionProofBinding(executionID: executionID, environmentID: work.environmentID,
            parentExecutionID: parent == nil ? nil : record.lineage.parentExecutionID, parentEnvironmentID: parent,
            parentRuntimeID: parent == nil ? nil : record.lineage.parentRuntimeID, runtimeID: work.runtimeID,
            executableSHA256: work.executableSHA256, signerID: work.runtimeID, keyID: ExecutionEvidenceDigest.sha256(work.publicKey),
            leaseDigest: work.leaseDigest, capabilityID: "environment:execute",
            contractDigest: ExecutionEvidenceDigest.sha256(Data("RIGHTCLICK-ENVIRONMENT-CHALLENGE-1".utf8)),
            requestDigest: work.requestDigest, responseDigest: try ExecutionEvidenceDigest.capabilityValue(.string(work.challenge)))
        return try .init(binding: binding, challengeNonce: work.nonce, expectedSequence: 1,
            minimumIssuedAtMilliseconds: work.issuedAtMilliseconds, deadlineMilliseconds: work.expiresAtMilliseconds,
            maximumAgeMilliseconds: 900_000, predicateID: "environment.challenge.equals", expectedValue: .string(work.challenge))
    }

    /// Parent-owned expectation for a specific authenticated Link request.
    /// The node's execution UUID must be that original request UUID. Complete
    /// contextual arguments, caller predicates and installed dependencies are
    /// compiled again; an old valid proof cannot certify a different invocation.
    public func remoteProofExpectation(executionID: String, capabilityID: String, item: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String? = nil) throws -> ExecutionProofExpectation {
        let state = try journal.snapshot()
        guard let dispatch = state.dispatches[executionID], dispatch.capabilityID == capabilityID,
              capabilityID == "environment:execute",
              state.records[dispatch.environmentID]?.handle?.uri == item,
              state.finalizations[executionID]?.origin == .rcirHost,
              state.finalizations[executionID]?.state == .succeeded else { throw EnvironmentEvidenceError.bindingMismatch }
        let digest = try EnvironmentContextualInvocation.digest(executionID: executionID, capabilityID: capabilityID,
            item: item, arguments: arguments, verification: verification, expectedOutput: expectedOutput,
            dependencies: dispatch.requiredDependencies)
        guard digest == dispatch.requestDigest else { throw EnvironmentEvidenceError.bindingMismatch }
        return try proofExpectation(executionID: executionID)
    }

    /// Host-installed parent adjudication of a negative result. This reads the
    /// complete immutable RCIR contract and a fresh separate observation; it
    /// never creates proof, certificate, or dependency authority for a failure.
    public func remoteFailureAdjudication(executionID: String, capabilityID: String, targetRuntimeID: String,
        item: String, arguments: CapabilityArguments?, verification: VerificationSpec?,
        expectedOutput: String? = nil) throws -> Bool {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        let state = try journal.snapshot(), timestamp = now()
        guard let dispatch = state.dispatches[executionID], dispatch.capabilityID == capabilityID,
              capabilityID == "environment:execute", let work = state.workloads[executionID],
              work.runtimeID == targetRuntimeID, let handle = state.records[dispatch.environmentID]?.handle,
              handle.uri == item, let final = state.finalizations[executionID],
              final.origin == .rcirHost, final.state == .failed,
              let record = state.executions[executionID], record.state == .failed,
              record.rcir?.outcome == "failed", record.lifecycle?.verification == .verifiedFailure,
              record.evidence.observationBoundary == .externalState,
              timestamp >= work.issuedAtMilliseconds, timestamp < work.expiresAtMilliseconds else { return false }
        let digest = try EnvironmentContextualInvocation.digest(executionID: executionID, capabilityID: capabilityID,
            item: item, arguments: arguments, verification: verification, expectedOutput: expectedOutput,
            dependencies: dispatch.requiredDependencies)
        guard digest == dispatch.requestDigest else { return false }
        return try provider.observeChallenge(handle, executionID: executionID) != nil
    }

    /// Verifies and retains the complete signed evidence; semantic success comes
    /// from the host's separate observation, never reportedOutcome.
    public func adjudicateProof(_ proof: SignedExecutionProof, using verifier: any RCIRReceiptVerifying = RCIREd25519Verifier(),
                                hostSigner: any RCIRReceiptSigning) throws -> SignedExecutionVerificationCertificate {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard hostSigner.publicKey == operatorPublicKey else { throw EnvironmentEvidenceError.untrustedKey }
        let id = proof.proof.binding.executionID
        let expectation = try proofExpectation(executionID: id)
        let state = try journal.snapshot()
        if let finalization = state.finalizations[id], finalization.state != .succeeded {
            throw EnvironmentEvidenceError.unsuccessfulDependency
        }
        guard let work = state.workloads[id], work.proofDigest == nil else { throw EnvironmentEvidenceError.invalidSequence }
        try proof.verify(trustedPublicKey: work.publicKey, using: verifier)
        guard try proof.proof.binding.canonicalData() == expectation.binding.canonicalData(),
              proof.proof.challengeNonce == expectation.challengeNonce, proof.proof.sequence == expectation.expectedSequence,
              proof.proof.predicateID == expectation.predicateID else { throw EnvironmentEvidenceError.bindingMismatch }
        guard try proof.wireData().count <= 8192 else { throw EnvironmentFabricError.capacityExceeded }
        // Consume the proof sequence durably before observation/finalization. A
        // crash here retains an unresolved proof, never grants replay authority.
        try journal.transaction { current in
            if let finalization = current.finalizations[id], finalization.state != .succeeded { throw EnvironmentEvidenceError.unsuccessfulDependency }
            guard current.proofReservations[id] == nil, current.workloads[id]?.proofDigest == nil else { throw EnvironmentEvidenceError.invalidSequence }
            current.proofReservations[id] = proof
        }
        let verification = try ExecutionProofAdjudicator.adjudicate(proof, expectation: expectation,
            trustedPublicKey: work.publicKey, observerID: hostRuntimeID,
            observationBoundary: "Configured provider separate challenge observation.", nowMilliseconds: now(), using: verifier,
            observe: observeExecution)
        let certificate = try SignedExecutionVerificationCertificate.sign(verification, using: hostSigner)
        try retainEvidence(proof, certificate: certificate, using: verifier)
        return certificate
    }

    public func retainEvidence(_ proof: SignedExecutionProof, certificate: SignedExecutionVerificationCertificate,
                               using verifier: any RCIRReceiptVerifying = RCIREd25519Verifier()) throws {
        guard try proof.wireData().count <= 8192, try certificate.wireData().count <= 8192 else { throw EnvironmentFabricError.capacityExceeded }
        let expectation = try proofExpectation(executionID: proof.proof.binding.executionID)
        try journal.transaction { state in
            let id = proof.proof.binding.executionID
            if let finalization = state.finalizations[id], finalization.state != .succeeded { throw EnvironmentEvidenceError.unsuccessfulDependency }
            guard var work = state.workloads[id], work.proofDigest == nil else { throw EnvironmentEvidenceError.invalidSequence }
            if let reserved = state.proofReservations[id] {
                guard try reserved.proof.digest == proof.proof.digest else { throw EnvironmentEvidenceError.invalidSequence }
            }
            try proof.verify(trustedPublicKey: work.publicKey, using: verifier)
            try certificate.verify(trustedHostPublicKey: operatorPublicKey, using: verifier)
            let verification = certificate.verification
            guard try proof.proof.binding.canonicalData() == expectation.binding.canonicalData(),
                  try verification.binding.canonicalData() == expectation.binding.canonicalData(),
                  proof.proof.challengeNonce == work.nonce, verification.challengeNonce == work.nonce,
                  proof.proof.sequence == 1, verification.sequence == 1,
                  proof.proof.predicateID == expectation.predicateID,
                  proof.proof.issuedAtMilliseconds >= work.issuedAtMilliseconds,
                  proof.proof.observedAtMilliseconds <= verification.verifiedAtMilliseconds,
                  proof.proof.expiresAtMilliseconds <= work.expiresAtMilliseconds,
                  verification.expiresAtMilliseconds <= proof.proof.expiresAtMilliseconds,
                  try verification.proofDigest == proof.proof.digest,
                  try verification.expectedValueDigest == ExecutionEvidenceDigest.capabilityValue(.string(work.challenge)),
                  verification.predicateID == expectation.predicateID, verification.observerID == hostRuntimeID,
                  now() >= verification.verifiedAtMilliseconds, now() < verification.expiresAtMilliseconds,
                  verification.expiresAtMilliseconds <= work.expiresAtMilliseconds else { throw EnvironmentEvidenceError.bindingMismatch }
            work.proofDigest = try proof.proof.digest; state.workloads[id] = work
            state.proofReservations[id] = proof
            state.proofs[id] = proof; state.certificates[id] = certificate
            if state.finalizations[id] == nil {
                state.executions[id]?.state = verification.outcome == .succeeded ? .succeeded : verification.outcome == .failed ? .failed : .unknown
                guard let result = state.executions[id] else { throw EnvironmentFabricError.invalidRequest }
                state.finalizations[id] = .init(origin: .builtinChallenge, state: result.state, recordDigest: try executionRecordDigest(result))
                if var resource = state.records[work.environmentID], resource.runtime != nil,
                   resource.destroyIntentID == nil, !resource.revoked {
                    resource.state = verification.outcome == .unknown ? .unknown : runtimeIsFresh(resource, at: now()) ? .ready : .unknown
                    state.records[work.environmentID] = resource
                }
            }
        }
    }

    public func evidence(executionID: String) throws -> (SignedExecutionProof?, SignedExecutionVerificationCertificate?) {
        let state = try journal.snapshot()
        return (state.proofs[executionID], state.executions[executionID]?.state == .succeeded ? state.certificates[executionID] : nil)
    }
    /// Complete audit evidence includes superseded challenge verification and
    /// the final existing-engine outcome; it grants no dependency authority.
    public func auditEvidence(executionID: String) throws -> (SignedExecutionProof?, SignedExecutionVerificationCertificate?, ExecutionRecord?) {
        let state = try journal.snapshot(); return (state.proofs[executionID], state.certificates[executionID], state.executions[executionID])
    }

    public func reserve(dependencyProofDigest: String, certificateDigest: String,
                        consumingExecutionID: String, consumingRequestDigest: String) throws {
        guard EnvironmentIdentity.isDigest(dependencyProofDigest), EnvironmentIdentity.isDigest(certificateDigest),
              EnvironmentIdentity.isCanonicalID(consumingExecutionID), EnvironmentIdentity.isDigest(consumingRequestDigest) else {
            throw EnvironmentFabricError.invalidRequest
        }
        try journal.transaction { state in
            if let local = state.proofs.first(where: { (try? $0.value.proof.digest) == dependencyProofDigest }) {
                guard state.executions[local.key]?.state == .succeeded,
                      (try state.certificates[local.key]?.digest) == certificateDigest else { throw EnvironmentEvidenceError.unsuccessfulDependency }
            }
            guard state.dependencies.count < 128 || state.dependencies[dependencyProofDigest] != nil else { throw EnvironmentFabricError.capacityExceeded }
            let next = EnvironmentDependencyReservation(certificateDigest: certificateDigest,
                executionID: consumingExecutionID, requestDigest: consumingRequestDigest)
            if let old = state.dependencies[dependencyProofDigest] {
                guard old == next else { throw EnvironmentFabricError.dependencyAlreadyConsumed }; return
            }
            state.dependencies[dependencyProofDigest] = next
        }
    }

    public func destroy(environmentID: String, admission: EnvironmentAdmissionContext, confirmed: Bool) throws -> EnvironmentRecord {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        guard confirmed else { throw EnvironmentFabricError.confirmationRequired }
        try journal.transaction { state in
            try validateAuthority(admission, state: state, at: now())
            try validateTarget(admission, environmentID: environmentID, state: state)
            _ = try reserveDispatch(admission, capabilityID: "environment:destroy", environmentID: environmentID, spec: nil, state: &state, at: now())
            if state.finalizations[admission.executionID] == nil {
                state.executions[admission.executionID] = execution(admission.executionID, "environment:destroy", .started, "Recursive teardown reserved.", environmentID)
            }
            try reserveTeardown(environmentID, state: &state)
        }
        try teardown(environmentID)
        guard let result = try record(environmentID: environmentID) else { throw EnvironmentFabricError.unknownEnvironment }
        try journal.transaction { state in
            guard state.finalizations[admission.executionID] == nil else { return }
            state.executions[admission.executionID] = execution(admission.executionID, "environment:destroy",
                result.state == .destroyed ? .succeeded : .unknown,
                result.state == .destroyed ? "Resource and all descendants independently observed absent." : "Teardown remains uncertain and will be reconciled.", environmentID)
            if result.state == .destroyed {
                state.executions[admission.executionID]?.evidence = OutcomeEvidence(type: "environment-absence",
                    boundary: result.observation?.observationBoundary ?? "Exact correlation independently observed absent.",
                    outcomeVerified: true, observationBoundary: .externalState)
            }
        }
        return result
    }

    /// Host safety cleanup can revoke expired resources even after caller grants
    /// expire. It cannot create/bootstrap/execute or touch unrecorded resources.
    public func reconcile() throws -> [EnvironmentRecord] {
        try journal.lockEffects(); defer { journal.unlockEffects() }
        let timestamp = now()
        try journal.transaction { state in
            try clock(&state, at: timestamp)
            for record in Array(state.records.values) where record.state != .destroyed {
                let expiredLease = record.leaseIDs.contains {
                    guard let budget = state.leases.budget(for: $0) else { return true }
                    return budget.revoked || timestamp >= budget.signedLease.body.expiresAtMilliseconds
                }
                if record.intent.expiresAtMilliseconds <= timestamp || expiredLease || record.revoked { try reserveTeardown(record.environmentID, state: &state) }
            }
        }
        let snapshot = try journal.snapshot()
        // Inventory detects duplicate/mismatched ownership; only exact retained
        // intents are ever cleanup targets. Never adopt arbitrary provider rows.
        do {
            let listed = try provider.list()
            guard listed.count <= 1024 else { throw EnvironmentError.unsafeDuplicate }
            for record in snapshot.records.values {
                let matches = listed.filter { $0.correlationID == record.intent.correlationID && $0.presence == .present }
                if matches.count > 1 || matches.contains(where: { $0.environmentID != record.environmentID }) {
                    throw EnvironmentError.unsafeDuplicate
                }
            }
        } catch let error as EnvironmentError where error == .unsafeDuplicate { throw error }
        catch { /* Inventory transport failure is uncertain; exact reads still run. */ }
        for record in snapshot.records.values.sorted(by: { $0.lineage.depth > $1.lineage.depth }) {
            // Terminal absence is a historical observation, not proof that an
            // already-issued asynchronous create can never become visible later.
            let observed = try observe(environmentID: record.environmentID)
            if observed.state != .destroyed, observed.destroyIntentID != nil { try teardown(record.environmentID) }
        }
        try journal.transaction { state in
            for (id, dispatch) in state.dispatches where dispatch.capabilityID == "environment:destroy" {
                guard let record = state.records[dispatch.environmentID], record.state == .destroyed,
                      state.finalizations[id] == nil,
                      var execution = state.executions[id], [.started, .accepted, .unknown].contains(execution.state) else { continue }
                execution.state = .succeeded
                execution.message = "Reconciliation independently observed resource and all descendants absent."
                execution.evidence = OutcomeEvidence(type: "environment-absence",
                    boundary: record.observation?.observationBoundary ?? "Exact correlation independently observed absent.",
                    outcomeVerified: true, observationBoundary: .externalState)
                state.executions[id] = execution
            }
        }
        return try records()
    }

    public func canDiscover(capabilityID: String, environmentID: String?, subjectPublicKey: Data? = nil,
                            runtimeID: String? = nil, leaseID: UUID? = nil) throws -> Bool {
        let state = try journal.snapshot(), timestamp = now()
        let context: EnvironmentAdmissionContext
        if let subjectPublicKey, let runtimeID, let environmentID, let leaseID {
            context = .init(executionID: UUID().uuidString, requestDigest: Data(repeating: 0, count: 32), environmentID: environmentID,
                runtimeID: runtimeID, subjectPublicKey: subjectPublicKey, leaseID: leaseID, hostToken: hostToken)
        } else {
            guard subjectPublicKey == nil, runtimeID == nil, leaseID == nil else { return false }
            context = try rootAdmission(executionID: UUID().uuidString, requestDigest: Data(repeating: 0, count: 32))
        }
        do { try validateAuthority(context, state: state, at: timestamp) } catch { return false }
        if let leaseID {
            guard let budget = state.leases.budget(for: leaseID), budget.remainingExecutions > 0,
                  budget.signedLease.body.capabilityIDs.contains(capabilityID) else { return false }
        }
        if capabilityID == "environment:create" { return environmentID == nil && provider.support.supportsCreate && provider.support.enforcesTTL && state.records.count < maximumEnvironments }
        guard let environmentID, let record = state.records[environmentID] else { return false }
        if capabilityID == "environment:observe" { return true }
        if capabilityID == "environment:destroy" { return provider.support.supportsDestroy && record.state != .destroyed }
        guard !record.revoked, record.destroyIntentID == nil, timestamp < record.intent.expiresAtMilliseconds else { return false }
        if capabilityID == "environment:bootstrap" { return provider.support.supportsBootstrap && record.handle != nil && record.runtime == nil && record.enrollmentChallenge == nil }
        if capabilityID == "environment:execute" {
            guard provider.support.supportsChallenge, let runtime = record.runtime, record.state == .ready else { return false }
            if leaseID != nil { return true }
            return record.leaseIDs.contains { id in
                guard let budget = state.leases.budget(for: id), budget.remainingExecutions > 0,
                      budget.signedLease.body.capabilityIDs.contains(capabilityID) else { return false }
                let context = EnvironmentAdmissionContext(executionID: UUID().uuidString, requestDigest: Data(repeating: 0, count: 32),
                    environmentID: environmentID, runtimeID: runtime.runtimeID, subjectPublicKey: runtime.publicKey, leaseID: id, hostToken: hostToken)
                return (try? validateAuthority(context, state: state, at: timestamp)) != nil
            }
        }
        if capabilityID == "environment:create-child", let leaseID,
           let budget = state.leases.budget(for: leaseID) {
            return provider.support.supportsCreate && provider.support.enforcesTTL && record.runtime != nil && record.state == .ready &&
                record.lineage.depth < EnvironmentLimits.maximumDepth && state.records.count < maximumEnvironments &&
                (state.creations[leaseID.uuidString]?.children ?? 0) < budget.signedLease.body.limits.maximumChildren &&
                (state.creations[leaseID.uuidString]?.descendants ?? 0) < budget.signedLease.body.limits.maximumDescendants
        }
        return false
    }

    private func teardown(_ environmentID: String) throws {
        let snapshot = try journal.snapshot()
        guard let root = snapshot.records[environmentID] else { throw EnvironmentFabricError.unknownEnvironment }
        if root.state == .destroyed { return }
        let children = snapshot.records.values.filter { $0.lineage.parentEnvironmentID == environmentID }.sorted { $0.environmentID < $1.environmentID }
        for child in children { try teardown(child.environmentID) }
        let fresh = try journal.snapshot()
        guard descendants(environmentID, state: fresh).allSatisfy({ $0.state == .destroyed && $0.observation?.presence == .absent }) else {
            try journal.transaction { state in state.records[environmentID]?.state = .unknown }; return
        }
        // Read-before-dispatch handles previous accepted/uncertain deletion.
        let observed = try observe(environmentID: environmentID)
        if observed.state == .destroyed { return }
        guard observed.observation?.presence == .present, let handle = observed.handle,
              let intent = observed.destroyIntentID else { return }
        guard provider.support.supportsDestroy else { throw EnvironmentError.unsupported }
        if provider.support.supportsStop {
            guard let stopIntent = observed.stopIntentID else { throw EnvironmentFabricError.invalidRequest }
            try journal.transaction { state in state.records[environmentID]?.state = .stopping }
            _ = safeAcceptance { try provider.stop(handle, idempotencyKey: stopIntent) }
        }
        try journal.transaction { state in state.records[environmentID]?.state = .destroying }
        let accepted = safeAcceptance { try provider.destroy(handle, idempotencyKey: intent) }
        try journal.transaction { state in state.records[environmentID]?.acceptance = accepted }
        _ = try observe(environmentID: environmentID)
    }

    private func reserveTeardown(_ environmentID: String, state: inout EnvironmentFabricState) throws {
        guard let root = state.records[environmentID] else { throw EnvironmentFabricError.unknownEnvironment }
        let all = [root] + descendants(environmentID, state: state)
        for original in all {
            var record = original
            record.revoked = true; record.runtime = nil
            for id in record.leaseIDs { try state.leases.revoke(leaseID: id) }
            if record.stopIntentID == nil { record.stopIntentID = UUID().uuidString }
            if record.destroyIntentID == nil { record.destroyIntentID = UUID().uuidString }
            if record.state != .destroyed { record.state = .stopping }
            append("Runtime authority revoked and recursive destroy intent durably reserved.", to: &record)
            state.records[record.environmentID] = record
        }
    }

    private func reserveCreationCounts(_ admission: EnvironmentAdmissionContext, spec: EnvironmentSpec,
                                       state: inout EnvironmentFabricState, at timestamp: Int64) throws {
        guard let leaseID = admission.leaseID else { throw EnvironmentFabricError.unauthorized }
        var cursor: UUID? = leaseID, seen = Set<UUID>()
        while let id = cursor {
            guard seen.insert(id).inserted, let budget = state.leases.budget(for: id), !budget.revoked,
                  timestamp <= budget.signedLease.body.expiresAtMilliseconds - spec.lifetimeMilliseconds else { throw EnvironmentFabricError.unauthorized }
            let lease = budget.signedLease.body
            var count = state.creations[id.uuidString] ?? .init()
            guard count.descendants < lease.limits.maximumDescendants else { throw CapabilityLeaseError.insufficientBudget }
            count.descendants += 1
            if id == leaseID {
                guard count.children < lease.limits.maximumChildren else { throw CapabilityLeaseError.insufficientBudget }
                count.children += 1
            }
            state.creations[id.uuidString] = count; cursor = lease.parentLeaseID
        }
    }

    @discardableResult
    private func reserveDispatch(_ admission: EnvironmentAdmissionContext, capabilityID: String, environmentID: String,
                                 spec: EnvironmentSpec?, state: inout EnvironmentFabricState, at timestamp: Int64) throws -> Bool {
        try validateAuthority(admission, state: state, at: timestamp)
        try clock(&state, at: timestamp)
        if let old = state.dispatches[admission.executionID] {
            guard old.requestDigest == admission.requestDigest, old.environmentID == environmentID,
                  old.capabilityID == capabilityID else { throw EnvironmentError.idempotencyConflict }
            return false
        }
        guard state.dispatches.count < 128 else { throw EnvironmentFabricError.capacityExceeded }
        if let leaseID = admission.leaseID, let id = admission.environmentID {
            let targetSpec = spec ?? state.records[environmentID]?.intent.spec
            _ = try state.leases.reserveExecution(leaseInvocation(admission, leaseID: leaseID, capabilityID: capabilityID, spec: targetSpec),
                authenticatedSubjectPublicKey: admission.subjectPublicKey, authenticatedRuntimeID: admission.runtimeID,
                authenticatedEnvironmentID: UUID(uuidString: id)!, trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys,
                nowMilliseconds: timestamp)
        }
        state.dispatches[admission.executionID] = .init(executionID: admission.executionID, environmentID: environmentID,
            capabilityID: capabilityID, requestDigest: admission.requestDigest, callerEnvironmentID: admission.environmentID,
            callerRuntimeID: admission.runtimeID, callerPublicKey: admission.subjectPublicKey,
            requiredDependencies: admission.requiredDependencies, admittedAtMilliseconds: timestamp)
        return true
    }

    private func leaseInvocation(_ context: EnvironmentAdmissionContext, leaseID: UUID, capabilityID: String,
                                 spec: EnvironmentSpec?) throws -> CapabilityLeaseInvocation {
        guard let spec else { throw EnvironmentFabricError.invalidProfile }
        // The bounded cost of this VM was already charged at creation. Its
        // actual CPU/memory/profile remain required for every delegated effect.
        let createsResource = capabilityID == "environment:create" || capabilityID == "environment:create-child"
        return try .init(reservationID: UUID(uuidString: context.executionID)!, leaseID: leaseID, requestDigest: context.requestDigest,
            capabilityID: capabilityID, profileID: spec.profileID, networkDestinations: [], cpuCount: Int64(spec.resources.cpuCount),
            memoryMiB: Int64(spec.resources.memoryMiB), costUnits: createsResource ? spec.resources.maximumCostUnits : 0)
    }
    private func validateLeaseResources(_ lease: CapabilityLease, spec: EnvironmentSpec) throws {
        guard lease.profileIDs.contains(spec.profileID), lease.limits.cpuCount >= Int64(spec.resources.cpuCount),
              lease.limits.memoryMiB >= Int64(spec.resources.memoryMiB), lease.limits.costUnit == spec.resources.costUnit,
              lease.limits.maximumCostUnits >= spec.resources.maximumCostUnits else { throw CapabilityLeaseError.authorityAmplification }
    }

    private func validateAuthority(_ context: EnvironmentAdmissionContext, state: EnvironmentFabricState, at timestamp: Int64) throws {
        guard context.hostToken == hostToken else { throw EnvironmentFabricError.unauthorized }
        try validateInvocation(context.executionID, context.requestDigest)
        guard timestamp >= state.clockHighWaterMilliseconds else { throw CapabilityLeaseError.clockRollback }
        if let environmentID = context.environmentID {
            guard let record = state.records[environmentID], !record.revoked, let runtime = record.runtime,
                  runtimeIsFresh(record, at: timestamp),
                  runtime.publicKey == context.subjectPublicKey, runtime.runtimeID == context.runtimeID,
                  timestamp < record.intent.expiresAtMilliseconds, let leaseID = context.leaseID,
                  record.leaseIDs.contains(leaseID) else { throw EnvironmentFabricError.unauthorized }
            try state.leases.validate(trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys)
            var cursor: UUID? = leaseID, seen = Set<UUID>()
            while let id = cursor {
                guard seen.insert(id).inserted, let budget = state.leases.budget(for: id), !budget.revoked,
                      timestamp >= budget.signedLease.body.issuedAtMilliseconds,
                      timestamp < budget.signedLease.body.expiresAtMilliseconds else { throw EnvironmentFabricError.unauthorized }
                cursor = budget.signedLease.body.parentLeaseID
            }
            guard let lease = state.leases.budget(for: leaseID)?.signedLease.body,
                  lease.subjectPublicKey == context.subjectPublicKey, lease.subjectRuntimeID == context.runtimeID,
                  lease.environmentID.uuidString == environmentID else { throw EnvironmentFabricError.unauthorized }
            try validateLeaseResources(lease, spec: record.intent.spec)
        } else {
            guard context.leaseID == nil, context.subjectPublicKey == operatorPublicKey,
                  context.runtimeID == hostRuntimeID else { throw EnvironmentFabricError.unauthorized }
        }
        for (dependency, validated) in try checkedDependencies(context.requiredDependencies, admission: context, state: state, at: timestamp) where dependency.oneUse {
            guard state.dependencies[dependency.proofDigest] == .init(certificateDigest: validated.certificateDigest,
                executionID: context.executionID, requestDigest: hex(context.requestDigest)) else { throw EnvironmentFabricError.dependencyAlreadyConsumed }
        }
    }
    private func checkedDependencies(_ dependencies: [ExecutionDependency], admission: EnvironmentAdmissionContext,
                                     state: EnvironmentFabricState, at timestamp: Int64) throws -> [(ExecutionDependency, ValidatedExecutionDependency)] {
        guard timestamp >= state.clockHighWaterMilliseconds, dependencies.count <= 8 else { throw CapabilityLeaseError.clockRollback }
        return try dependencies.map { dependency in
            guard state.executions[dependency.executionID]?.state == .succeeded, state.finalizations[dependency.executionID] != nil,
                  let proof = state.proofs[dependency.executionID], let certificate = state.certificates[dependency.executionID],
                  let workload = state.workloads[dependency.executionID], workload.environmentID == dependency.environmentID,
                  let enrolled = state.records[dependency.environmentID]?.enrollmentCertificate?.certificate.claim,
                  enrolled.publicKey == workload.publicKey else { throw EnvironmentEvidenceError.unsuccessfulDependency }
            // The signature/timing/binding validator is pure here. The one-use
            // reservation is checked/updated in this same journal transaction.
            let pure = try ExecutionDependency(executionID: dependency.executionID, environmentID: dependency.environmentID,
                requestDigest: dependency.requestDigest, proofDigest: dependency.proofDigest, predicateID: dependency.predicateID,
                observerID: dependency.observerID, maximumAgeMilliseconds: dependency.maximumAgeMilliseconds, oneUse: false)
            let validated = try ExecutionDependencyValidator.validate(pure, proof: proof, certificate: certificate,
                trustedChildPublicKey: workload.publicKey, trustedHostPublicKey: operatorPublicKey,
                consumingExecutionID: admission.executionID, consumingRequestDigest: hex(admission.requestDigest),
                nowMilliseconds: timestamp, using: RCIREd25519Verifier())
            return (dependency, validated)
        }
    }

    private func validateTarget(_ admission: EnvironmentAdmissionContext, environmentID: String, state: EnvironmentFabricState) throws {
        guard state.records[environmentID] != nil else { throw EnvironmentFabricError.unknownEnvironment }
        if let callerID = admission.environmentID {
            guard callerID == environmentID else { throw EnvironmentFabricError.unauthorized }
        }
    }
    private func revalidateEffect(_ admission: EnvironmentAdmissionContext, environmentID: String) throws {
        if let caller = admission.environmentID { _ = try observe(environmentID: caller) }
        if (try journal.snapshot().dispatches[admission.executionID]?.capabilityID) == "environment:execute" {
            _ = try observe(environmentID: environmentID)
        }
        let state = try journal.snapshot(), timestamp = now()
        try validateAuthority(admission, state: state, at: timestamp)
        guard let record = state.records[environmentID], !record.revoked, record.destroyIntentID == nil,
              timestamp < record.intent.expiresAtMilliseconds,
              state.dispatches[admission.executionID]?.requestDigest == admission.requestDigest else { throw EnvironmentFabricError.unauthorized }
        if state.dispatches[admission.executionID]?.capabilityID == "environment:execute" {
            guard runtimeIsFresh(record, at: timestamp) else { throw EnvironmentFabricError.invalidRuntime }
        }
    }
    private func runtimeIsFresh(_ record: EnvironmentRecord, at timestamp: Int64) -> Bool {
        guard record.state == .ready || record.state == .running, !record.revoked,
              let enrolled = record.runtime, let observation = record.observation, observation.presence == .present,
              let observed = observation.runtime, [.ready, .running].contains(observation.state),
              observed.publicKey == enrolled.publicKey, observed.manifest == enrolled.manifest,
              timestamp >= observation.observedAtMilliseconds, timestamp - observation.observedAtMilliseconds <= 30_000,
              timestamp >= observed.observedAtMilliseconds, timestamp - observed.observedAtMilliseconds <= 30_000 else { return false }
        return true
    }
    private func clock(_ state: inout EnvironmentFabricState, at timestamp: Int64) throws {
        guard timestamp > 0, timestamp >= state.clockHighWaterMilliseconds else { throw CapabilityLeaseError.clockRollback }
        state.clockHighWaterMilliseconds = timestamp
    }
    private func validateInvocation(_ executionID: String, _ requestDigest: Data) throws {
        guard EnvironmentIdentity.isCanonicalID(executionID), requestDigest.count == 32 else { throw EnvironmentFabricError.invalidRequest }
    }
    private func descendants(_ environmentID: String, state: EnvironmentFabricState) -> [EnvironmentRecord] {
        state.records.values.filter { record in
            var cursor = record.lineage.parentEnvironmentID, seen = Set<String>()
            while let parent = cursor, seen.insert(parent).inserted {
                if parent == environmentID { return true }; cursor = state.records[parent]?.lineage.parentEnvironmentID
            }
            return false
        }
    }
    private func exactObservation(_ record: EnvironmentRecord) throws -> EnvironmentObservation {
        do {
            let observation = try provider.observe(correlationID: record.intent.correlationID)
            guard observation.environmentID == record.environmentID, observation.correlationID == record.intent.correlationID,
                  observation.observedAtMilliseconds >= record.intent.createdAtMilliseconds,
                  observation.observedAtMilliseconds <= now(),
                  record.handle == nil || observation.providerResourceID == nil || observation.providerResourceID == record.handle?.providerResourceID else {
                throw EnvironmentError.invalidObservation
            }
            return observation
        } catch {
            return try .init(environmentID: record.environmentID, correlationID: record.intent.correlationID,
                providerResourceID: record.handle?.providerResourceID, presence: .unknown, state: .unknown,
                observedAtMilliseconds: max(now(), record.intent.createdAtMilliseconds), observationBoundary: "Provider observation unavailable or identity mismatch.")
        }
    }
    private func handle(_ intent: EnvironmentCreateIntent, resourceID: String) throws -> EnvironmentHandle {
        try .init(environmentID: intent.environmentID, providerID: provider.id, providerResourceID: resourceID,
            correlationID: intent.correlationID, lineage: intent.lineage, spec: intent.spec,
            createdAtMilliseconds: intent.createdAtMilliseconds, expiresAtMilliseconds: intent.expiresAtMilliseconds)
    }
    private func safeAcceptance(_ body: () throws -> EnvironmentProviderAcceptance) -> EnvironmentProviderAcceptance {
        do { return try body() } catch { return try! .init(acceptance: .unknown, message: "Provider dispatch outcome uncertain; retained intent requires reconciliation.") }
    }
    private func acceptanceState(_ acceptance: EnvironmentProviderAcceptance) -> ExecutionState {
        acceptance.acceptance == .accepted ? .accepted : acceptance.acceptance == .rejected ? .rejected : .unknown
    }
    private func execution(_ id: String, _ capability: String, _ state: ExecutionState, _ message: String, _ environmentID: String) -> ExecutionRecord {
        .init(executionId: id, actionId: capability, state: state, message: message, output: "rcenv://" + environmentID)
    }
    private func executionRecordDigest(_ record: ExecutionRecord) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ExecutionEvidenceDigest.sha256(try encoder.encode(record))
    }
    private func append(_ event: String, to record: inout EnvironmentRecord) {
        record.events.append(event); if record.events.count > 32 { record.events.removeFirst(record.events.count - 32) }
    }
    private func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator(); return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func validateRecovery(_ state: EnvironmentFabricState) throws {
        guard state.records.count <= maximumEnvironments, state.correlations.count == state.records.count,
              state.dispatches.count <= 128, state.executions.count <= 128, state.dependencies.count <= 128,
              state.workloads.count <= 16, state.proofReservations.count <= 16, state.proofs.count <= 16, state.certificates.count == state.proofs.count,
              state.totalReservedCostUnits >= 0, state.totalReservedCostUnits <= maximumTotalCostUnits,
              state.totalReservedCostUnits == state.records.values.reduce(0, { $0 + $1.intent.spec.resources.maximumCostUnits }) else {
            throw EnvironmentFabricError.invalidRequest
        }
        try state.leases.validate(trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys)
        for (id, finalization) in state.finalizations {
            guard let record = state.executions[id], finalization.state == record.state,
                  try finalization.recordDigest == executionRecordDigest(record) else { throw EnvironmentFabricError.invalidRequest }
        }
        var expectedCreations: [String: EnvironmentCreationCount] = [:]
        for (id, record) in state.records {
            guard id == record.environmentID, state.correlations[record.intent.correlationID] == id,
                  profileCeilings[record.intent.spec.profileID].map(record.intent.spec.isWithin) == true,
                  record.handle.map({ $0.providerID == provider.id && $0.environmentID == id && $0.lineage == record.lineage && $0.spec == record.intent.spec }) ?? true,
                  !record.enrollmentConsumed || record.enrollmentChallenge != nil,
                  record.runtime == nil || record.enrollmentConsumed,
                  record.runtime.map({ $0.manifest == profiles[record.intent.spec.profileID] }) ?? true else {
                throw EnvironmentFabricError.invalidRequest
            }
            if let certificate = record.enrollmentCertificate {
                let body = certificate.certificate, claim = body.claim
                guard body.issuerPublicKey == operatorPublicKey,
                      try RCIREd25519Verifier().verify(signature: certificate.signature, payload: body.canonicalData(), publicKey: operatorPublicKey),
                      claim.handle == record.handle, claim.manifest == profiles[record.intent.spec.profileID],
                      claim.enrollmentID == record.enrollmentChallenge?.enrollmentID,
                      claim.challenge == record.enrollmentChallenge?.challenge,
                      record.runtime == nil || record.runtime?.publicKey == claim.publicKey else { throw EnvironmentFabricError.invalidRuntime }
            }
            for leaseID in record.leaseIDs {
                guard let lease = state.leases.budget(for: leaseID)?.signedLease.body,
                      let claim = record.enrollmentCertificate?.certificate.claim,
                      lease.environmentID.uuidString == id, lease.subjectPublicKey == claim.publicKey,
                      lease.subjectRuntimeID == claim.runtimeID, lease.expiresAtMilliseconds <= record.intent.expiresAtMilliseconds,
                      !record.revoked || state.leases.budget(for: leaseID)?.revoked == true else { throw EnvironmentFabricError.unauthorized }
                try validateLeaseResources(lease, spec: record.intent.spec)
            }
            if let parentID = record.lineage.parentEnvironmentID {
                guard let parent = state.records[parentID], parent.lineage.depth + 1 == record.lineage.depth,
                      parent.lineage.rootEnvironmentID == record.lineage.rootEnvironmentID,
                      parent.enrollmentCertificate?.certificate.claim.runtimeID == record.lineage.parentRuntimeID,
                      record.intent.expiresAtMilliseconds <= parent.intent.expiresAtMilliseconds,
                      let creatingLeaseID = record.creatingLeaseID,
                      state.leases.budget(for: creatingLeaseID)?.signedLease.body.environmentID.uuidString == parentID else { throw EnvironmentError.invalidLineage }
                var cursor: UUID? = creatingLeaseID, seen = Set<UUID>()
                while let leaseID = cursor {
                    guard seen.insert(leaseID).inserted, let lease = state.leases.budget(for: leaseID)?.signedLease.body else { throw EnvironmentFabricError.invalidRequest }
                    var count = expectedCreations[leaseID.uuidString] ?? .init()
                    count.descendants += 1
                    if leaseID == creatingLeaseID { count.children += 1 }
                    guard count.children <= lease.limits.maximumChildren, count.descendants <= lease.limits.maximumDescendants else { throw CapabilityLeaseError.insufficientBudget }
                    expectedCreations[leaseID.uuidString] = count; cursor = lease.parentLeaseID
                }
            } else {
                guard record.creatingLeaseID == nil, record.lineage.parentRuntimeID == hostRuntimeID else { throw EnvironmentError.invalidLineage }
            }
        }
        guard expectedCreations == state.creations else { throw EnvironmentFabricError.invalidRequest }
        for (id, dispatch) in state.dispatches {
            guard id == dispatch.executionID, EnvironmentIdentity.isCanonicalID(id), dispatch.requestDigest.count == 32,
                  state.records[dispatch.environmentID] != nil, dispatch.callerPublicKey.count == 32,
                  dispatch.requiredDependencies.count <= 8, dispatch.admittedAtMilliseconds > 0,
                  dispatch.admittedAtMilliseconds <= state.clockHighWaterMilliseconds,
                  state.executions[id]?.actionId == dispatch.capabilityID else { throw EnvironmentFabricError.invalidRequest }
            for dependency in dispatch.requiredDependencies {
                guard let proof = state.proofs[dependency.executionID], let certificate = state.certificates[dependency.executionID],
                      let work = state.workloads[dependency.executionID], state.finalizations[dependency.executionID]?.state == .succeeded else {
                    throw EnvironmentEvidenceError.unsuccessfulDependency
                }
                let pure = try ExecutionDependency(executionID: dependency.executionID, environmentID: dependency.environmentID,
                    requestDigest: dependency.requestDigest, proofDigest: dependency.proofDigest, predicateID: dependency.predicateID,
                    observerID: dependency.observerID, maximumAgeMilliseconds: dependency.maximumAgeMilliseconds, oneUse: false)
                let validated = try ExecutionDependencyValidator.validate(pure, proof: proof, certificate: certificate,
                    trustedChildPublicKey: work.publicKey, trustedHostPublicKey: operatorPublicKey,
                    consumingExecutionID: id, consumingRequestDigest: hex(dispatch.requestDigest),
                    nowMilliseconds: dispatch.admittedAtMilliseconds, using: RCIREd25519Verifier())
                if dependency.oneUse {
                    guard state.dependencies[dependency.proofDigest] == .init(certificateDigest: validated.certificateDigest,
                        executionID: id, requestDigest: hex(dispatch.requestDigest)) else { throw EnvironmentFabricError.dependencyAlreadyConsumed }
                }
            }
            if let owner = dispatch.callerEnvironmentID {
                guard let claim = state.records[owner]?.enrollmentCertificate?.certificate.claim,
                      dispatch.callerPublicKey == claim.publicKey, dispatch.callerRuntimeID == claim.runtimeID else { throw EnvironmentFabricError.unauthorized }
            } else {
                guard dispatch.callerPublicKey == operatorPublicKey, dispatch.callerRuntimeID == hostRuntimeID else { throw EnvironmentFabricError.unauthorized }
            }
        }
        for (id, work) in state.workloads {
            guard let record = state.records[work.environmentID], let claim = record.enrollmentCertificate?.certificate.claim,
                  let dispatch = state.dispatches[id], dispatch.capabilityID == "environment:execute",
                  dispatch.environmentID == work.environmentID, hex(dispatch.requestDigest) == work.requestDigest,
                  work.nonce.count == 32, work.publicKey == claim.publicKey, work.runtimeID == claim.runtimeID,
                  work.executableSHA256 == claim.manifest.executableSHA256, EnvironmentIdentity.isDigest(work.leaseDigest),
                  work.issuedAtMilliseconds >= record.intent.createdAtMilliseconds,
                  work.expiresAtMilliseconds <= record.intent.expiresAtMilliseconds,
                  work.expiresAtMilliseconds > work.issuedAtMilliseconds else { throw EnvironmentFabricError.invalidRequest }
            if let proof = state.proofReservations[id] {
                try proof.verify(trustedPublicKey: work.publicKey, using: RCIREd25519Verifier())
                guard proof.proof.challengeNonce == work.nonce, proof.proof.binding.executionID == id,
                      proof.proof.binding.environmentID == work.environmentID,
                      proof.proof.binding.requestDigest == work.requestDigest else { throw EnvironmentEvidenceError.bindingMismatch }
            }
            if let proof = state.proofs[id], let certificate = state.certificates[id] {
                try proof.verify(trustedPublicKey: work.publicKey, using: RCIREd25519Verifier())
                let body = certificate.verification
                guard certificate.publicKey == operatorPublicKey,
                      try RCIREd25519Verifier().verify(signature: certificate.signature, payload: body.canonicalData(), publicKey: operatorPublicKey),
                      try body.proofDigest == proof.proof.digest, try work.proofDigest == proof.proof.digest,
                      try body.binding.canonicalData() == proof.proof.binding.canonicalData() else { throw EnvironmentEvidenceError.bindingMismatch }
            } else {
                guard work.proofDigest == nil else { throw EnvironmentEvidenceError.bindingMismatch }
            }
        }
    }
}
