import Foundation

public enum RCIRReceiptTrustError: Error, Equatable {
    case invalidPolicy, untrustedIssuer, untrustedKey, keyRevoked, keyNotActive
    case receiptOutsideKeyInterval, receiptTooOld, claimMismatch, malformedReceipt, changedPolicy
}

/// Live acceptance requires a currently authorized key and a recent assertion.
/// Historical acceptance permits an explicitly retired/expired key within its
/// declared authorization interval. Revoked keys are rejected in both modes:
/// v1 contains no independently trusted signing timestamp to defeat backdating.
public enum RCIRReceiptTrustMode: String, Sendable { case live, historical }

/// Caller-provisioned trust, never learned from a receipt's embedded locator.
/// Key IDs and issuer identity are out-of-band policy identifiers in v1; they do
/// not attest executable identity or establish when a signature was created.
public struct RCIRReceiptKeyRecord: Sendable {
    public let keyID: String
    public let publicKey: Data
    public let notBefore: Int64
    public let notAfter: Int64
    public let retiredAt: Int64?
    public let revoked: Bool

    public init(keyID: String, publicKey: Data, notBefore: Int64, notAfter: Int64,
                retiredAt: Int64? = nil, revoked: Bool = false) throws {
        try receiptTrustIdentity(keyID)
        guard publicKey.count == 32, notBefore >= 0, notAfter > notBefore,
              retiredAt.map({ notBefore <= $0 && $0 <= notAfter }) ?? true else { throw RCIRReceiptTrustError.invalidPolicy }
        self.keyID = keyID; self.publicKey = publicKey
        self.notBefore = notBefore; self.notAfter = notAfter
        self.retiredAt = retiredAt; self.revoked = revoked
    }
    fileprivate var cutoff: Int64 { min(notAfter, retiredAt ?? notAfter) }
}

/// Trusted caller expectations. A successful signature for another task/lease
/// is never accepted by this policy path. The legacy bare-pin API is preserved.
public struct RCIRReceiptTrustRequest: Sendable {
    public let issuerID: String
    public let taskID: UUID
    public let leaseID: UUID
    public let outcome: RCIRSemanticOutcome?
    public let mode: RCIRReceiptTrustMode
    public init(issuerID: String, taskID: UUID, leaseID: UUID,
                outcome: RCIRSemanticOutcome? = nil, mode: RCIRReceiptTrustMode) throws {
        try receiptTrustIdentity(issuerID)
        self.issuerID = issuerID; self.taskID = taskID; self.leaseID = leaseID
        self.outcome = outcome; self.mode = mode
    }
}

/// A live authorization decision from one retained policy instance. Callers can
/// inspect identifiers but cannot mint a token or supply its private identity.
public struct RCIRReceiptSigningAuthorization: Sendable {
    public let issuerID: String
    public let keyID: String
    public let publicKey: Data
    public let keyRevision: Int64
    fileprivate let policyIdentity: UUID
}

public struct RCIRReceiptTrustDecision: Sendable {
    public let issuerID: String
    public let keyID: String
    public let mode: RCIRReceiptTrustMode
    public let claims: RCIRReceiptClaims
    public let keyRevision: Int64
}

/// One bounded host-owned policy around the existing v1 Ed25519 verifier.
/// Provisioning is explicit. Records cannot be removed, reassigned or unrevoked;
/// tombstones are retained to prevent accidental trust resurrection. A production
/// deployment must protect/persist this state and coordinate distributed writers.
/// This library primitive alone does not wire automatic runtime trust admission.
public final class RCIRReceiptTrustPolicy {
    public let issuerID: String
    public let maximumLiveAge: Int64
    private let clock: () -> Int64
    private let lock = NSLock()
    private let identity = UUID()
    private struct Entry { var record: RCIRReceiptKeyRecord; var revision: Int64 }
    private var entries: [Data: Entry] = [:]
    private var ids: Set<Data> = []
    private var metadataBytes = 0
    private var lastClock: Int64 = 0
    public static let maximumRecords = 64
    public static let maximumMetadataBytes = 131_072

    public init(issuerID: String, records: [RCIRReceiptKeyRecord], maximumLiveAge: Int64 = 60_000,
                clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        try receiptTrustIdentity(issuerID)
        guard !records.isEmpty, records.count <= Self.maximumRecords,
              (1...86_400_000).contains(maximumLiveAge) else { throw RCIRReceiptTrustError.invalidPolicy }
        self.issuerID = issuerID; self.maximumLiveAge = maximumLiveAge; self.clock = clock
        for record in records { try insert(record) }
    }

    /// Rotation adds a separately provisioned key; it never replaces a revoked
    /// key or makes an embedded key trusted. Retire the old record explicitly.
    public func register(_ record: RCIRReceiptKeyRecord) throws {
        lock.lock(); defer { lock.unlock() }; try insert(record)
    }
    private func insert(_ record: RCIRReceiptKeyRecord) throws {
        let id = Data(record.keyID.utf8), size = id.count + record.publicKey.count + 32
        guard entries.count < Self.maximumRecords, entries[record.publicKey] == nil,
              !ids.contains(id), size <= Self.maximumMetadataBytes - metadataBytes else { throw RCIRReceiptTrustError.invalidPolicy }
        entries[record.publicKey] = .init(record: record, revision: 1)
        ids.insert(id); metadataBytes += size
    }
    public func retire(keyID: String, at time: Int64) throws {
        try mutate(keyID) { entry in
            guard entry.record.notBefore <= time, time <= entry.record.cutoff else { throw RCIRReceiptTrustError.invalidPolicy }
            let r = entry.record
            entry.record = try .init(keyID: r.keyID, publicKey: r.publicKey, notBefore: r.notBefore,
                notAfter: r.notAfter, retiredAt: time, revoked: r.revoked)
        }
    }
    public func revoke(keyID: String) throws {
        try mutate(keyID) { entry in
            let r = entry.record
            entry.record = try .init(keyID: r.keyID, publicKey: r.publicKey, notBefore: r.notBefore,
                notAfter: r.notAfter, retiredAt: r.retiredAt, revoked: true)
        }
    }
    private func mutate(_ keyID: String, change: (inout Entry) throws -> Void) throws {
        try receiptTrustIdentity(keyID)
        lock.lock(); defer { lock.unlock() }
        guard let key = entries.first(where: { $0.value.record.keyID.utf8.elementsEqual(keyID.utf8) })?.key,
              var entry = entries[key], entry.revision < Int64.max else { throw RCIRReceiptTrustError.invalidPolicy }
        try change(&entry); entry.revision += 1; entries[key] = entry
    }

    /// Live signing authority only; this does not sign or attest a payload.
    /// The returned token must be revalidated around the existing callback.
    public func authorization(for publicKey: Data) throws -> RCIRReceiptSigningAuthorization {
        let time = clock()
        lock.lock(); defer { lock.unlock() }
        let now = try monotonicTime(time)
        guard let entry = entries[publicKey] else { throw RCIRReceiptTrustError.untrustedKey }
        try authorized(entry.record, mode: .live, now: now)
        return .init(issuerID: issuerID, keyID: entry.record.keyID, publicKey: publicKey,
                     keyRevision: entry.revision, policyIdentity: identity)
    }

    public func revalidate(_ token: RCIRReceiptSigningAuthorization) throws {
        let time = clock()
        lock.lock(); defer { lock.unlock() }
        let now = try monotonicTime(time)
        guard token.policyIdentity == identity,
              token.issuerID.utf8.elementsEqual(issuerID.utf8),
              let entry = entries[token.publicKey],
              token.keyID.utf8.elementsEqual(entry.record.keyID.utf8) else { throw RCIRReceiptTrustError.changedPolicy }
        try authorized(entry.record, mode: .live, now: now)
        guard token.keyRevision == entry.revision else { throw RCIRReceiptTrustError.changedPolicy }
    }

    /// Atomically reconcile a separately provisioned snapshot into retained
    /// state. Omission is never revocation: tombstones must remain explicit.
    /// Only additions, earlier retirement and irreversible revocation are legal.
    public func reconcile(issuerID: String, records: [RCIRReceiptKeyRecord], maximumLiveAge: Int64) throws {
        guard issuerID.utf8.elementsEqual(self.issuerID.utf8),
              maximumLiveAge == self.maximumLiveAge, !records.isEmpty,
              records.count <= Self.maximumRecords else { throw RCIRReceiptTrustError.invalidPolicy }
        lock.lock(); defer { lock.unlock() }
        var next: [Data: Entry] = [:]
        var nextIDs: Set<Data> = []
        var nextBytes = 0
        for record in records {
            let id = Data(record.keyID.utf8), size = id.count + record.publicKey.count + 32
            guard next[record.publicKey] == nil, nextIDs.insert(id).inserted,
                  size <= Self.maximumMetadataBytes - nextBytes else { throw RCIRReceiptTrustError.invalidPolicy }
            if let old = entries[record.publicKey] {
                guard old.record.keyID.utf8.elementsEqual(record.keyID.utf8),
                      old.record.notBefore == record.notBefore, old.record.notAfter == record.notAfter,
                      !old.record.revoked || record.revoked,
                      old.record.retiredAt.map({ oldTime in record.retiredAt.map({ $0 <= oldTime }) ?? false }) ?? true
                else { throw RCIRReceiptTrustError.invalidPolicy }
                let changed = old.record.revoked != record.revoked || old.record.retiredAt != record.retiredAt
                guard !changed || old.revision < Int64.max else { throw RCIRReceiptTrustError.invalidPolicy }
                next[record.publicKey] = .init(record: record, revision: old.revision + (changed ? 1 : 0))
            } else {
                guard !ids.contains(id) else { throw RCIRReceiptTrustError.invalidPolicy }
                next[record.publicKey] = .init(record: record, revision: 1)
            }
            nextBytes += size
        }
        guard entries.keys.allSatisfy({ next[$0] != nil }) else { throw RCIRReceiptTrustError.invalidPolicy }
        // No mutation before every constraint passes, including old tombstones.
        entries = next; ids = nextIDs; metadataBytes = nextBytes
    }

    public func verify(_ receipt: RCIRSignedReceipt, expecting request: RCIRReceiptTrustRequest,
                       using verifier: any RCIRReceiptVerifying) throws -> RCIRReceiptTrustDecision {
        guard issuerID.utf8.elementsEqual(request.issuerID.utf8) else { throw RCIRReceiptTrustError.untrustedIssuer }
        let snapshot: Entry
        let initialTime = clock()
        lock.lock()
        do {
            let now = try monotonicTime(initialTime)
            guard let entry = entries[receipt.publicKey] else { throw RCIRReceiptTrustError.untrustedKey }
            try authorized(entry.record, mode: request.mode, now: now)
            snapshot = entry; lock.unlock()
        } catch { lock.unlock(); throw error }

        // No lock around the backend: real callbacks may revoke/retire a record.
        // A second locked policy decision below prevents acceptance across that
        // race. No second signer or alternative signature algorithm is involved.
        do { try receipt.verify(trustedPublicKey: snapshot.record.publicKey, using: verifier) }
        catch { throw RCIRReceiptError.invalidSignature }
        let claims = try RCIRReceiptClaims.read(receipt.payload)
        guard claims.taskID == request.taskID, claims.leaseID == request.leaseID,
              request.outcome.map({ $0 == claims.outcome }) ?? true else { throw RCIRReceiptTrustError.claimMismatch }
        let finalTime = clock()
        lock.lock(); defer { lock.unlock() }
        let now = try monotonicTime(finalTime)
        guard let current = entries[receipt.publicKey] else { throw RCIRReceiptTrustError.changedPolicy }
        try authorized(current.record, mode: request.mode, now: now)
        guard current.revision == snapshot.revision else { throw RCIRReceiptTrustError.changedPolicy }
        guard claims.startedAt >= current.record.notBefore, claims.lastObservationTime < current.record.cutoff,
              claims.lastObservationTime <= now else { throw RCIRReceiptTrustError.receiptOutsideKeyInterval }
        if request.mode == .live, now - claims.lastObservationTime > maximumLiveAge { throw RCIRReceiptTrustError.receiptTooOld }
        return .init(issuerID: issuerID, keyID: current.record.keyID, mode: request.mode,
                     claims: claims, keyRevision: current.revision)
    }
    private func authorized(_ record: RCIRReceiptKeyRecord, mode: RCIRReceiptTrustMode, now: Int64) throws {
        guard !record.revoked else { throw RCIRReceiptTrustError.keyRevoked }
        if mode == .live, !(record.notBefore <= now && now < record.cutoff) { throw RCIRReceiptTrustError.keyNotActive }
    }
    private func monotonicTime(_ now: Int64) throws -> Int64 {
        guard now >= 0 else { throw RCIRReceiptTrustError.invalidPolicy }
        lastClock = max(lastClock, now); return lastClock
    }
}

private func receiptTrustIdentity(_ text: String) throws {
    guard !text.isEmpty, text.utf8.count <= 512, !text.contains("*"),
          text.rangeOfCharacter(from: .controlCharacters) == nil else { throw RCIRReceiptTrustError.invalidPolicy }
}
