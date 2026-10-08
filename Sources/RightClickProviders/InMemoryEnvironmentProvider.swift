import Foundation
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private final class SimulatedRuntimeSigningProxy: RCIRReceiptSigning {
    let publicKey: Data
    private let perform: (Data) throws -> Data
    init(publicKey: Data, perform: @escaping (Data) throws -> Data) {
        self.publicKey = publicKey; self.perform = perform
    }
    func sign(_ payload: Data) throws -> Data { try perform(payload) }
}

/// A deterministic test substrate. API acceptance and independently observed
/// reality use separate paths so a dishonest callback cannot verify itself.
/// This is not a Linux VM and does not establish real-cloud or process evidence.
public final class InMemoryEnvironmentProvider: EnvironmentProvider {
    public struct Faults {
        public var partitioned = false
        public var createAcceptedThenCrashOnce = false
        public var bootstrapAcceptedWithoutRuntime = false
        public var deleteAcceptedStillPresent = false
        public var suppressChallengeEffect = false
        public var reportedChallengeOverride: String?
        public var observedChallengeOverride: String?
        public var runtimeManifestOverride: EnvironmentRuntimeManifest?
        public init() {}
    }

    public let id: String
    public let support = EnvironmentProviderSupport(supportsCreate: true, supportsBootstrap: true,
        supportsChallenge: true, supportsStop: true, supportsDestroy: true, enforcesTTL: true, nativeCreateIdempotency: true)
    private let lock = NSLock()
    private let clock: () -> Int64
    private let capacity: Int
    private var faults = Faults()
    private struct Resource {
        let intent: EnvironmentCreateIntent
        let resourceID: String
        var state: EnvironmentState = .bootstrapping
        var present = true
        var manifest: EnvironmentRuntimeManifest?
        // Custody stays within the simulated execution node. Never export it.
        var signer: Curve25519.Signing.PrivateKey?
        var challenges: [String: String] = [:]
        var observedChallenges: [String: String] = [:]
        var enrollmentClaims: [String: Data] = [:]
        var delegatedLeases: [String: Data] = [:]
    }
    private var resources: [String: Resource] = [:]
    private var operationKeys: [String: String] = [:]
    private var events: [String] = []

    public init(id: String = "in-memory-environment", clock: @escaping () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }, capacity: Int = 64) throws {
        guard EnvironmentIdentity.isName(id), (1...1024).contains(capacity) else { throw EnvironmentError.invalidLimits }
        self.id = id; self.clock = clock; self.capacity = capacity
    }

    /// Host-only fault injection, never selected by capability arguments.
    public func configureFaults(_ update: (inout Faults) -> Void) {
        lock.lock(); defer { lock.unlock() }; update(&faults)
    }
    public var operationLog: [String] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    public var activeRuntimeCount: Int {
        lock.lock(); defer { lock.unlock() }; expireResources()
        return resources.values.filter { $0.present && $0.signer != nil }.count
    }

    /// Composes a simulated guest's Link endpoint with its enrolled identity.
    /// This host-only harness hook is never exposed through contextual tools.
    /// The proxy exports no private key and loses signing authority on stop,
    /// destruction or TTL expiry. It proves protocol identity continuity only;
    /// the fake guest and its test host still share one process.
    public func withSimulatedRuntimeSigner<T>(environmentID: String,
        compose: (any RCIRReceiptSigning) throws -> T) throws -> T {
        lock.lock(); expireResources()
        guard let resource = resources.values.first(where: { $0.intent.environmentID == environmentID }),
              resource.present, resource.state == .ready, let signer = resource.signer else {
            lock.unlock(); throw EnvironmentError.invalidState
        }
        let key = signer.publicKey.rawRepresentation
        lock.unlock()
        return try compose(SimulatedRuntimeSigningProxy(publicKey: key) { [weak self] payload in
            guard let self else { throw EnvironmentError.unavailable }
            self.lock.lock(); defer { self.lock.unlock() }
            self.expireResources(); try self.requireConnection()
            guard let current = self.resources.values.first(where: { $0.intent.environmentID == environmentID }),
                  current.present, current.state == .ready, let currentSigner = current.signer,
                  currentSigner.publicKey.rawRepresentation == key else { throw EnvironmentError.invalidState }
            return try currentSigner.signature(for: payload)
        })
    }

    public func create(_ intent: EnvironmentCreateIntent) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        if let existing = resources[intent.correlationID] {
            guard existing.intent == intent else { throw EnvironmentError.idempotencyConflict }
            return try acceptance(resourceID: existing.resourceID)
        }
        guard !resources.values.contains(where: { $0.intent.environmentID == intent.environmentID }) else {
            throw EnvironmentError.idempotencyConflict
        }
        guard intent.createdAtMilliseconds <= clock(), intent.expiresAtMilliseconds > clock() else { throw EnvironmentError.expired }
        guard resources.count < capacity else { throw EnvironmentError.unavailable }
        let resourceID = "mem-" + intent.correlationID.lowercased()
        resources[intent.correlationID] = Resource(intent: intent, resourceID: resourceID)
        events.append("create:" + intent.environmentID)
        if faults.createAcceptedThenCrashOnce {
            faults.createAcceptedThenCrashOnce = false
            throw EnvironmentError.unavailable // Real resource survives loss of acceptance.
        }
        return try acceptance(resourceID: resourceID)
    }

    public func observe(correlationID: String) throws -> EnvironmentObservation {
        lock.lock(); defer { lock.unlock() }; expireResources()
        guard EnvironmentIdentity.isCanonicalID(correlationID), let resource = resources[correlationID] else {
            throw EnvironmentError.invalidIdentity // An unknown locator is never proof of absence.
        }
        return try observation(resource, unknown: faults.partitioned)
    }
    public func list() throws -> [EnvironmentObservation] {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        return try resources.keys.sorted().map { try observation(resources[$0]!) }
    }
    public func bootstrap(_ handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        var resource = try matched(handle, requirePresent: true)
        guard resource.state == .bootstrapping || resource.state == .ready else { throw EnvironmentError.invalidState }
        if let original = resource.manifest {
            guard original == manifest else { throw EnvironmentError.idempotencyConflict }
        } else if !faults.bootstrapAcceptedWithoutRuntime {
            resource.manifest = manifest
            resource.signer = Curve25519.Signing.PrivateKey()
            resource.state = .ready
            resources[handle.correlationID] = resource
            events.append("bootstrap:" + handle.environmentID)
        }
        return try acceptance(resourceID: resource.resourceID)
    }
    public func executeChallenge(_ handle: EnvironmentHandle, executionID: String, challenge: String) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        guard EnvironmentIdentity.isCanonicalID(executionID), Self.validChallenge(challenge) else { throw EnvironmentError.invalidIdentity }
        var resource = try matched(handle, requirePresent: true)
        guard resource.state == .ready, resource.signer != nil else { throw EnvironmentError.invalidState }
        if let previous = resource.challenges[executionID] {
            guard previous == challenge else { throw EnvironmentError.idempotencyConflict }
        } else {
            resource.challenges[executionID] = challenge
            if !faults.suppressChallengeEffect { resource.observedChallenges[executionID] = challenge }
            resources[handle.correlationID] = resource
            events.append("challenge:" + handle.environmentID + ":" + executionID)
        }
        return try acceptance(resourceID: resource.resourceID)
    }
    public func observeChallenge(_ handle: EnvironmentHandle, executionID: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        guard EnvironmentIdentity.isCanonicalID(executionID) else { throw EnvironmentError.invalidIdentity }
        let resource = try matched(handle, requirePresent: true)
        return faults.observedChallengeOverride ?? resource.observedChallenges[executionID]
    }
    public func stop(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        var resource = try matched(handle)
        try reserveOperation("stop", handle: handle, key: idempotencyKey)
        if resource.present { resource.state = .stopping; resource.signer = nil; resources[handle.correlationID] = resource }
        events.append("stop:" + handle.environmentID)
        return try acceptance(resourceID: resource.resourceID)
    }
    public func destroy(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        var resource = try matched(handle)
        try reserveOperation("destroy", handle: handle, key: idempotencyKey)
        if !faults.deleteAcceptedStillPresent {
            resource.present = false; resource.state = .destroyed; resource.signer = nil
            resource.observedChallenges.removeAll(); resources[handle.correlationID] = resource
        }
        events.append("destroy:" + handle.environmentID)
        return try acceptance(resourceID: resource.resourceID)
    }

    /// Simulated child assertion for the host integration harness. Its signature
    /// cannot establish VM/process execution or independent semantic success.
    public func signedExecutionProof(_ proof: ExecutionProof) throws -> SignedExecutionProof {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        guard let resource = resources.values.first(where: { $0.intent.environmentID == proof.binding.environmentID }),
              resource.present, resource.state == .ready, let signer = resource.signer, let manifest = resource.manifest else {
            throw EnvironmentError.invalidState
        }
        let keyID = ExecutionEvidenceDigest.sha256(signer.publicKey.rawRepresentation)
        guard proof.binding.runtimeID == "runtime:" + keyID, proof.binding.keyID == keyID,
              proof.binding.signerID == proof.binding.runtimeID, proof.binding.executableSHA256 == manifest.executableSHA256,
              proof.binding.capabilityID == "environment:execute", let challenge = resource.challenges[proof.binding.executionID],
              proof.issuedAtMilliseconds >= resource.intent.createdAtMilliseconds, proof.observedAtMilliseconds <= clock(),
              proof.expiresAtMilliseconds <= resource.intent.expiresAtMilliseconds, proof.expiresAtMilliseconds > clock() else {
            throw EnvironmentEvidenceError.bindingMismatch
        }
        guard let report = proof.reportedValue, case .string(let reportedValue) = report,
              reportedValue == (faults.reportedChallengeOverride ?? challenge) else { throw EnvironmentEvidenceError.bindingMismatch }
        if let parentEnvironmentID = resource.intent.lineage.parentEnvironmentID {
            guard proof.binding.parentEnvironmentID == parentEnvironmentID,
                  proof.binding.parentExecutionID == resource.intent.lineage.parentExecutionID,
                  proof.binding.parentRuntimeID == resource.intent.lineage.parentRuntimeID else {
                throw EnvironmentEvidenceError.bindingMismatch
            }
        } else {
            guard proof.binding.parentEnvironmentID == nil, proof.binding.parentExecutionID == nil,
                  proof.binding.parentRuntimeID == nil else { throw EnvironmentEvidenceError.bindingMismatch }
        }
        return try SignedExecutionProof(proof: proof, signature: signer.signature(for: proof.canonicalData()),
            publicKey: signer.publicKey.rawRepresentation)
    }

    /// Typed enrollment proof generated by the simulated node, with exact
    /// resource/profile/key custody checks. This does not prove a process ran.
    public func signedRuntimeClaim(_ claim: ChildRuntimeClaim) throws -> SignedChildRuntimeClaim {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        var resource = try matched(claim.handle, requirePresent: true)
        guard resource.state == .ready, let manifest = resource.manifest, let signer = resource.signer,
              manifest == claim.manifest, claim.publicKey == signer.publicKey.rawRepresentation,
              claim.issuedAtMilliseconds >= resource.intent.createdAtMilliseconds, claim.issuedAtMilliseconds <= clock(),
              claim.expiresAtMilliseconds <= resource.intent.expiresAtMilliseconds, claim.expiresAtMilliseconds > clock() else {
            throw EnvironmentError.invalidIdentity
        }
        let data = try claim.canonicalData()
        if let previous = resource.enrollmentClaims[claim.enrollmentID], previous != data { throw EnvironmentError.idempotencyConflict }
        resource.enrollmentClaims[claim.enrollmentID] = data
        resources[claim.handle.correlationID] = resource
        return try SignedChildRuntimeClaim(claim: claim, signature: signer.signature(for: data))
    }

    /// Simulated A-to-B issuance with node-local key custody. The coordinator
    /// must still authenticate the persisted parent lease and enforce complete
    /// attenuation, revocation and cumulative budgets before installing this.
    public func signedCapabilityLease(_ lease: CapabilityLease, issuerEnvironmentID: String) throws -> SignedCapabilityLease {
        lock.lock(); defer { lock.unlock() }; expireResources(); try requireConnection()
        guard EnvironmentIdentity.isCanonicalID(issuerEnvironmentID),
              let issuerCorrelation = resources.keys.first(where: { resources[$0]!.intent.environmentID == issuerEnvironmentID }),
              var issuer = resources[issuerCorrelation], issuer.present, issuer.state == .ready, let signer = issuer.signer,
              let subject = resources.values.first(where: { $0.intent.environmentID == lease.environmentID.uuidString }),
              subject.present, subject.state == .ready, let subjectSigner = subject.signer,
              lease.issuerPublicKey == signer.publicKey.rawRepresentation,
              lease.subjectPublicKey == subjectSigner.publicKey.rawRepresentation,
              lease.subjectRuntimeID == "runtime:" + ExecutionEvidenceDigest.sha256(subjectSigner.publicKey.rawRepresentation),
              subject.intent.lineage.parentEnvironmentID == issuerEnvironmentID,
              subject.intent.lineage.depth == issuer.intent.lineage.depth + 1,
              lease.issuingExecutionID == subject.intent.creationExecutionID,
              lease.parentLeaseID != nil, lease.parentLeaseDigest != nil,
              lease.issuedAtMilliseconds >= max(issuer.intent.createdAtMilliseconds, subject.intent.createdAtMilliseconds),
              lease.issuedAtMilliseconds <= clock(), lease.expiresAtMilliseconds > clock(),
              lease.expiresAtMilliseconds <= min(issuer.intent.expiresAtMilliseconds, subject.intent.expiresAtMilliseconds) else {
            throw CapabilityLeaseError.parentMismatch
        }
        let bytes = try lease.canonicalData()
        let key = lease.leaseID.uuidString
        if let previous = issuer.delegatedLeases[key], previous != bytes { throw EnvironmentError.idempotencyConflict }
        issuer.delegatedLeases[key] = bytes
        resources[issuerCorrelation] = issuer
        return try SignedCapabilityLease(body: lease, signature: signer.signature(for: bytes))
    }

    public func signedCapabilityLease(_ lease: CapabilityLease) throws -> SignedCapabilityLease {
        lock.lock()
        let issuerID = resources.values.first { $0.signer?.publicKey.rawRepresentation == lease.issuerPublicKey }?.intent.environmentID
        lock.unlock()
        guard let issuerID else { throw CapabilityLeaseError.untrustedIssuer }
        // Revalidates the active identity after taking the lock in the typed path.
        return try signedCapabilityLease(lease, issuerEnvironmentID: issuerID)
    }

    private func requireConnection() throws {
        if faults.partitioned { throw EnvironmentError.unavailable }
    }
    private func expireResources() {
        let now = clock()
        for key in Array(resources.keys) where resources[key]!.present && resources[key]!.intent.expiresAtMilliseconds <= now {
            resources[key]!.present = false; resources[key]!.state = .destroyed; resources[key]!.signer = nil
            resources[key]!.observedChallenges.removeAll()
            events.append("ttl:" + resources[key]!.intent.environmentID)
        }
    }
    private func matched(_ handle: EnvironmentHandle, requirePresent: Bool = false) throws -> Resource {
        guard handle.providerID == id, let resource = resources[handle.correlationID],
              resource.resourceID == handle.providerResourceID, resource.intent.environmentID == handle.environmentID,
              resource.intent.lineage == handle.lineage, resource.intent.spec == handle.spec,
              resource.intent.createdAtMilliseconds == handle.createdAtMilliseconds,
              resource.intent.expiresAtMilliseconds == handle.expiresAtMilliseconds else { throw EnvironmentError.invalidIdentity }
        if requirePresent && !resource.present { throw EnvironmentError.expired }
        return resource
    }
    private func reserveOperation(_ kind: String, handle: EnvironmentHandle, key: String) throws {
        guard EnvironmentIdentity.isCanonicalID(key) else { throw EnvironmentError.invalidIdentity }
        let intent = kind + ":" + handle.environmentID + ":" + handle.providerResourceID
        if let previous = operationKeys[key], previous != intent { throw EnvironmentError.idempotencyConflict }
        operationKeys[key] = intent
    }
    private func acceptance(resourceID: String) throws -> EnvironmentProviderAcceptance {
        try EnvironmentProviderAcceptance(acceptance: .accepted, providerResourceID: resourceID, message: "Simulator accepted; independent observation required.")
    }
    private func observation(_ resource: Resource, unknown: Bool = false) throws -> EnvironmentObservation {
        let now = max(1, clock())
        var runtime: EnvironmentRuntimeObservation?
        if !unknown && resource.present, let manifest = resource.manifest, let signer = resource.signer {
            runtime = try EnvironmentRuntimeObservation(manifest: faults.runtimeManifestOverride ?? manifest,
                publicKey: signer.publicKey.rawRepresentation, observedAtMilliseconds: now, observationBoundary: "in-memory-runtime-observer")
        }
        return try EnvironmentObservation(environmentID: resource.intent.environmentID, correlationID: resource.intent.correlationID,
            providerResourceID: resource.resourceID, presence: unknown ? .unknown : (resource.present ? .present : .absent),
            state: unknown ? .unknown : resource.state, observedAtMilliseconds: now, runtime: runtime,
            observationBoundary: "in-memory-independent-resource-observer")
    }
    private static func validChallenge(_ challenge: String) -> Bool {
        !challenge.isEmpty && challenge.utf8.count <= EnvironmentLimits.maximumChallengeBytes &&
            challenge.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
