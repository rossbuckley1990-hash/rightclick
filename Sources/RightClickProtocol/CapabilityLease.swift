import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CapabilityLeaseError: Error, Equatable {
    case malformedLease, invalidLimits, malformedEnvelope, untrustedIssuer, invalidSignature
    case subjectMismatch, environmentMismatch, expired, futureIssued, clockRollback, revoked
    case unknownLease, parentMismatch, authorityAmplification, insufficientBudget
    case duplicateLease, reservationConflict, malformedState, capacityExceeded
}

/// Explicit finite ceilings. A zero count or cost grants no authority for that operation.
public struct CapabilityLeaseLimits: Codable, Equatable, Sendable {
    public let maximumExecutions: Int64
    public let maximumChildren: Int64
    public let maximumDescendants: Int64
    public let delegationDepth: Int64
    public let cpuCount: Int64
    public let memoryMiB: Int64
    public let maximumCostUnits: Int64
    public let costUnit: String

    public init(maximumExecutions: Int64, maximumChildren: Int64, maximumDescendants: Int64,
                delegationDepth: Int64, cpuCount: Int64, memoryMiB: Int64,
                maximumCostUnits: Int64, costUnit: String = "micro-usd") throws {
        self.maximumExecutions = maximumExecutions; self.maximumChildren = maximumChildren
        self.maximumDescendants = maximumDescendants; self.delegationDepth = delegationDepth
        self.cpuCount = cpuCount; self.memoryMiB = memoryMiB
        self.maximumCostUnits = maximumCostUnits; self.costUnit = costUnit
        try validate()
    }

    public func validate() throws {
        guard (0...4096).contains(maximumExecutions), (0...64).contains(maximumChildren),
              (0...256).contains(maximumDescendants), (0...2).contains(delegationDepth),
              (1...4).contains(cpuCount), (1...4096).contains(memoryMiB),
              (0...1_000_000).contains(maximumCostUnits), costUnit == "micro-usd",
              maximumChildren <= maximumDescendants,
              delegationDepth > 0 || (maximumChildren == 0 && maximumDescendants == 0)
        else { throw CapabilityLeaseError.invalidLimits }
    }

    fileprivate var canonicalValue: CapabilityValue {
        .object(["executions": .integer(maximumExecutions), "children": .integer(maximumChildren),
                 "descendants": .integer(maximumDescendants), "depth": .integer(delegationDepth),
                 "cpu": .integer(cpuCount), "memoryMiB": .integer(memoryMiB),
                 "cost": .integer(maximumCostUnits), "costUnit": .string(costUnit)])
    }
}

/// Distributed authority constrains local RCIR admission; it contains no provider credentials.
public struct CapabilityLease: Codable, Equatable, Sendable {
    public static let domain = Data("RIGHTCLICK-CAPABILITY-LEASE-1\0".utf8)
    public let leaseID: UUID
    public let issuerPublicKey: Data
    public let subjectPublicKey: Data
    public let subjectRuntimeID: String
    public let environmentID: UUID
    public let parentLeaseID: UUID?
    public let parentLeaseDigest: Data?
    public let issuingExecutionID: String
    public let capabilityIDs: [String]
    public let profileIDs: [String]
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let nonce: Data
    public let limits: CapabilityLeaseLimits
    public let networkAllowlist: [String]

    public init(leaseID: UUID, issuerPublicKey: Data, subjectPublicKey: Data, subjectRuntimeID: String,
                environmentID: UUID, parentLeaseID: UUID? = nil, parentLeaseDigest: Data? = nil,
                issuingExecutionID: String, capabilityIDs: [String], profileIDs: [String],
                issuedAtMilliseconds: Int64, expiresAtMilliseconds: Int64, nonce: Data,
                limits: CapabilityLeaseLimits, networkAllowlist: [String]) throws {
        self.leaseID = leaseID; self.issuerPublicKey = issuerPublicKey; self.subjectPublicKey = subjectPublicKey
        self.subjectRuntimeID = subjectRuntimeID; self.environmentID = environmentID
        self.parentLeaseID = parentLeaseID; self.parentLeaseDigest = parentLeaseDigest
        self.issuingExecutionID = issuingExecutionID; self.capabilityIDs = capabilityIDs.sorted()
        self.profileIDs = profileIDs.sorted(); self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds; self.nonce = nonce
        self.limits = limits; self.networkAllowlist = networkAllowlist.sorted()
        try validate()
    }

    public func validate() throws {
        try limits.validate()
        guard issuerPublicKey.count == 32, subjectPublicKey.count == 32, nonce.count == 32,
              LeaseValidation.identifier(subjectRuntimeID), LeaseValidation.identifier(issuingExecutionID),
              (parentLeaseID == nil) == (parentLeaseDigest == nil),
              parentLeaseID != leaseID, parentLeaseDigest == nil || parentLeaseDigest?.count == 32,
              issuedAtMilliseconds >= 0, expiresAtMilliseconds <= 253_402_300_799_999,
              expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds <= 3_600_000,
              !capabilityIDs.isEmpty,
              LeaseValidation.set(capabilityIDs, maximum: 64, valid: LeaseValidation.identifier),
              LeaseValidation.set(profileIDs, maximum: 32, valid: LeaseValidation.identifier),
              LeaseValidation.set(networkAllowlist, maximum: 32, valid: LeaseValidation.origin)
        else { throw CapabilityLeaseError.malformedLease }
    }

    public func canonicalData() throws -> Data {
        try validate()
        var result = Self.domain
        result.append(try CapabilityValue.object([
            "version": .integer(1), "leaseID": .string(leaseID.uuidString),
            "issuerPublicKey": .bytes(issuerPublicKey), "subjectPublicKey": .bytes(subjectPublicKey),
            "subjectRuntimeID": .string(subjectRuntimeID), "environmentID": .string(environmentID.uuidString),
            "parentLeaseID": parentLeaseID.map { .string($0.uuidString) } ?? .null,
            "parentLeaseDigest": parentLeaseDigest.map { .bytes($0) } ?? .null,
            "issuingExecutionID": .string(issuingExecutionID),
            "capabilities": .array(capabilityIDs.map { .string($0) }),
            "profiles": .array(profileIDs.map { .string($0) }),
            "issuedAt": .integer(issuedAtMilliseconds), "expiresAt": .integer(expiresAtMilliseconds),
            "nonce": .bytes(nonce), "limits": limits.canonicalValue,
            "network": .array(networkAllowlist.map { .string($0) })
        ]).canonicalData())
        return result
    }

    public func digest() throws -> Data { Data(SHA256.hash(data: try canonicalData())) }

    /// Called after authenticating both envelopes. All child authority is allocated, never copied.
    public func validateAttenuation(from parent: CapabilityLease) throws {
        try validate(); try parent.validate()
        guard parentLeaseID == parent.leaseID, parentLeaseDigest == (try parent.digest()),
              issuerPublicKey == parent.subjectPublicKey else { throw CapabilityLeaseError.parentMismatch }
        guard Set(capabilityIDs).isSubset(of: Set(parent.capabilityIDs)),
              Set(profileIDs).isSubset(of: Set(parent.profileIDs)),
              Set(networkAllowlist).isSubset(of: Set(parent.networkAllowlist)),
              issuedAtMilliseconds >= parent.issuedAtMilliseconds,
              expiresAtMilliseconds <= parent.expiresAtMilliseconds,
              limits.delegationDepth < parent.limits.delegationDepth,
              limits.maximumExecutions <= parent.limits.maximumExecutions,
              limits.maximumChildren <= parent.limits.maximumChildren,
              limits.maximumDescendants < parent.limits.maximumDescendants,
              limits.cpuCount <= parent.limits.cpuCount, limits.memoryMiB <= parent.limits.memoryMiB,
              limits.maximumCostUnits <= parent.limits.maximumCostUnits,
              limits.costUnit == parent.limits.costUnit
        else { throw CapabilityLeaseError.authorityAmplification }
    }
}

/// No embedded key establishes trust: callers pin the issuer outside this envelope.
public struct SignedCapabilityLease: Codable, Equatable, Sendable {
    public let body: CapabilityLease
    public let signature: Data

    public init(body: CapabilityLease, signature: Data) throws {
        try body.validate()
        guard signature.count == 64 else { throw CapabilityLeaseError.malformedEnvelope }
        self.body = body; self.signature = signature
    }

    public static func sign(_ body: CapabilityLease, using signer: any RCIRReceiptSigning) throws -> Self {
        guard signer.publicKey == body.issuerPublicKey else { throw CapabilityLeaseError.untrustedIssuer }
        return try .init(body: body, signature: signer.sign(body.canonicalData()))
    }

    public func verifySignature(trustedIssuerPublicKey: Data,
                                using verifier: any RCIRReceiptVerifying = RCIREd25519Verifier()) throws {
        try body.validate()
        guard signature.count == 64 else { throw CapabilityLeaseError.malformedEnvelope }
        guard trustedIssuerPublicKey.count == 32, trustedIssuerPublicKey == body.issuerPublicKey
        else { throw CapabilityLeaseError.untrustedIssuer }
        guard try verifier.verify(signature: signature, payload: body.canonicalData(), publicKey: trustedIssuerPublicKey)
        else { throw CapabilityLeaseError.invalidSignature }
    }

    @discardableResult
    public func verify(trustedIssuerPublicKey: Data, expectedSubjectPublicKey: Data, expectedSubjectRuntimeID: String,
                       expectedEnvironmentID: UUID, nowMilliseconds: Int64,
                       using verifier: any RCIRReceiptVerifying = RCIREd25519Verifier()) throws -> CapabilityLease {
        try verifySignature(trustedIssuerPublicKey: trustedIssuerPublicKey, using: verifier)
        guard expectedSubjectPublicKey.count == 32, expectedSubjectPublicKey == body.subjectPublicKey,
              expectedSubjectRuntimeID == body.subjectRuntimeID
        else { throw CapabilityLeaseError.subjectMismatch }
        guard expectedEnvironmentID == body.environmentID else { throw CapabilityLeaseError.environmentMismatch }
        try LeaseValidation.time(body, now: nowMilliseconds)
        return body
    }
}

/// Exact dispatch intent. The request digest is from the canonical authenticated Link request.
public struct CapabilityLeaseInvocation: Codable, Equatable, Sendable {
    public let reservationID: UUID
    public let leaseID: UUID
    public let requestDigest: Data
    public let capabilityID: String
    public let profileID: String?
    public let networkDestinations: [String]
    public let cpuCount: Int64
    public let memoryMiB: Int64
    public let costUnits: Int64

    public init(reservationID: UUID, leaseID: UUID, requestDigest: Data, capabilityID: String,
                profileID: String? = nil, networkDestinations: [String], cpuCount: Int64,
                memoryMiB: Int64, costUnits: Int64) throws {
        self.reservationID = reservationID; self.leaseID = leaseID; self.requestDigest = requestDigest
        self.capabilityID = capabilityID; self.profileID = profileID
        self.networkDestinations = networkDestinations.sorted(); self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB; self.costUnits = costUnits
        try validate()
    }

    public func validate() throws {
        guard requestDigest.count == 32, LeaseValidation.identifier(capabilityID),
              profileID == nil || LeaseValidation.identifier(profileID!),
              LeaseValidation.set(networkDestinations, maximum: 32, valid: LeaseValidation.origin),
              (1...4).contains(cpuCount), (1...4096).contains(memoryMiB), (0...1_000_000).contains(costUnits)
        else { throw CapabilityLeaseError.malformedLease }
    }

    fileprivate func digest() throws -> Data {
        try validate()
        let value = CapabilityValue.object([
            "reservationID": .string(reservationID.uuidString), "leaseID": .string(leaseID.uuidString),
            "requestDigest": .bytes(requestDigest), "capabilityID": .string(capabilityID),
            "profileID": profileID.map { .string($0) } ?? .null,
            "network": .array(networkDestinations.map { .string($0) }),
            "cpu": .integer(cpuCount), "memoryMiB": .integer(memoryMiB), "cost": .integer(costUnits)
        ])
        var bytes = Data("RIGHTCLICK-LEASE-RESERVATION-1\0".utf8)
        bytes.append(try value.canonicalData())
        return Data(SHA256.hash(data: bytes))
    }
}

public struct CapabilityLeaseBudget: Codable, Equatable, Sendable {
    public let signedLease: SignedCapabilityLease
    public fileprivate(set) var remainingExecutions: Int64
    public fileprivate(set) var remainingChildren: Int64
    public fileprivate(set) var remainingDescendants: Int64
    public fileprivate(set) var remainingCostUnits: Int64
    public fileprivate(set) var revoked: Bool

    fileprivate init(_ signed: SignedCapabilityLease) {
        signedLease = signed
        let limits = signed.body.limits
        remainingExecutions = limits.maximumExecutions; remainingChildren = limits.maximumChildren
        remainingDescendants = limits.maximumDescendants; remainingCostUnits = limits.maximumCostUnits
        revoked = false
    }
}

public struct CapabilityLeaseReservation: Sendable, Equatable {
    public let reservationID: UUID
    public let leaseID: UUID
    public let alreadyReserved: Bool
}

/// A pure serialisable transaction candidate, NOT a durability or dispatch implementation.
/// Core must persist the complete transitioned value atomically BEFORE any external effect.
public struct CapabilityLeaseReservationState: Codable, Equatable, Sendable {
    private var budgets: [String: CapabilityLeaseBudget] = [:]
    private var reservations: [String: CapabilityLeaseInvocation] = [:]
    public private(set) var clockHighWaterMilliseconds: Int64 = 0
    public init() {}
    public var leaseCount: Int { budgets.count }
    public var reservationCount: Int { reservations.count }
    public func budget(for leaseID: UUID) -> CapabilityLeaseBudget? { budgets[leaseID.uuidString] }

    /// Must use the host-configured issuer and enrolled subject; never use the body's own key as a pin.
    public mutating func registerRoot(_ signed: SignedCapabilityLease, trustedIssuerPublicKey: Data,
                                      expectedSubjectPublicKey: Data, expectedSubjectRuntimeID: String, expectedEnvironmentID: UUID,
                                      nowMilliseconds: Int64) throws {
        try validateShape()
        try checkClock(nowMilliseconds)
        let body = try signed.verify(trustedIssuerPublicKey: trustedIssuerPublicKey,
                                     expectedSubjectPublicKey: expectedSubjectPublicKey,
                                     expectedSubjectRuntimeID: expectedSubjectRuntimeID,
                                     expectedEnvironmentID: expectedEnvironmentID, nowMilliseconds: nowMilliseconds)
        guard body.parentLeaseID == nil else { throw CapabilityLeaseError.parentMismatch }
        if let existing = budgets[body.leaseID.uuidString] {
            guard existing.signedLease == signed else { throw CapabilityLeaseError.duplicateLease }
            guard !existing.revoked else { throw CapabilityLeaseError.revoked }
            clockHighWaterMilliseconds = nowMilliseconds
            return
        }
        guard budgets.count < 1024 else { throw CapabilityLeaseError.capacityExceeded }
        budgets[body.leaseID.uuidString] = .init(signed)
        clockHighWaterMilliseconds = nowMilliseconds
    }

    /// Debits execution/cost allocations and an entire child subtree from the parent's remaining quota.
    /// No refund is made for failed or ambiguous external creation.
    public mutating func allocateDelegation(_ child: SignedCapabilityLease, parentLeaseID: UUID,
                                           authenticatedSubjectPublicKey: Data, authenticatedRuntimeID: String, authenticatedEnvironmentID: UUID,
                                           expectedChildSubjectPublicKey: Data, expectedChildRuntimeID: String,
                                           expectedChildEnvironmentID: UUID, trustedRootIssuerPublicKeys: [Data],
                                           nowMilliseconds: Int64) throws {
        try validate(trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys)
        try checkClock(nowMilliseconds)
        try activeChain(parentLeaseID, now: nowMilliseconds)
        guard var parent = budgets[parentLeaseID.uuidString] else { throw CapabilityLeaseError.unknownLease }
        try authenticate(parent.signedLease.body, subject: authenticatedSubjectPublicKey,
                         runtimeID: authenticatedRuntimeID, environment: authenticatedEnvironmentID)
        let body = try child.verify(trustedIssuerPublicKey: parent.signedLease.body.subjectPublicKey,
                                    expectedSubjectPublicKey: expectedChildSubjectPublicKey,
                                    expectedSubjectRuntimeID: expectedChildRuntimeID,
                                    expectedEnvironmentID: expectedChildEnvironmentID, nowMilliseconds: nowMilliseconds)
        try body.validateAttenuation(from: parent.signedLease.body)
        if let existing = budgets[body.leaseID.uuidString] {
            guard existing.signedLease == child else { throw CapabilityLeaseError.duplicateLease }
            try activeChain(body.leaseID, now: nowMilliseconds)
            clockHighWaterMilliseconds = nowMilliseconds
            return
        }
        guard budgets.count < 1024 else { throw CapabilityLeaseError.capacityExceeded }
        let subtreeCapacity = 1 + body.limits.maximumDescendants
        guard parent.remainingExecutions >= body.limits.maximumExecutions,
              parent.remainingChildren >= 1, parent.remainingDescendants >= subtreeCapacity,
              parent.remainingCostUnits >= body.limits.maximumCostUnits
        else { throw CapabilityLeaseError.insufficientBudget }
        parent.remainingExecutions -= body.limits.maximumExecutions
        parent.remainingChildren -= 1; parent.remainingDescendants -= subtreeCapacity
        parent.remainingCostUnits -= body.limits.maximumCostUnits
        budgets[parentLeaseID.uuidString] = parent
        budgets[body.leaseID.uuidString] = .init(child)
        clockHighWaterMilliseconds = nowMilliseconds
    }

    /// Subject/environment values MUST come from a successfully authenticated Link session.
    /// alreadyReserved means reconcile the retained effect; it is not permission to dispatch again.
    public mutating func reserveExecution(_ invocation: CapabilityLeaseInvocation,
                                          authenticatedSubjectPublicKey: Data, authenticatedRuntimeID: String, authenticatedEnvironmentID: UUID,
                                          trustedRootIssuerPublicKeys: [Data], nowMilliseconds: Int64) throws -> CapabilityLeaseReservation {
        try validate(trustedRootIssuerPublicKeys: trustedRootIssuerPublicKeys)
        try invocation.validate(); try checkClock(nowMilliseconds)
        try activeChain(invocation.leaseID, now: nowMilliseconds)
        guard var budget = budgets[invocation.leaseID.uuidString] else { throw CapabilityLeaseError.unknownLease }
        let body = budget.signedLease.body
        try authenticate(body, subject: authenticatedSubjectPublicKey, runtimeID: authenticatedRuntimeID, environment: authenticatedEnvironmentID)
        guard body.capabilityIDs.contains(invocation.capabilityID),
              invocation.profileID == nil || body.profileIDs.contains(invocation.profileID!),
              Set(invocation.networkDestinations).isSubset(of: Set(body.networkAllowlist)),
              invocation.cpuCount <= body.limits.cpuCount, invocation.memoryMiB <= body.limits.memoryMiB
        else { throw CapabilityLeaseError.authorityAmplification }
        if let old = reservations[invocation.reservationID.uuidString] {
            guard try old.digest() == invocation.digest() else { throw CapabilityLeaseError.reservationConflict }
            clockHighWaterMilliseconds = nowMilliseconds
            return .init(reservationID: invocation.reservationID, leaseID: invocation.leaseID, alreadyReserved: true)
        }
        guard reservations.count < 8192 else { throw CapabilityLeaseError.capacityExceeded }
        guard budget.remainingExecutions >= 1, budget.remainingCostUnits >= invocation.costUnits
        else { throw CapabilityLeaseError.insufficientBudget }
        budget.remainingExecutions -= 1; budget.remainingCostUnits -= invocation.costUnits
        budgets[invocation.leaseID.uuidString] = budget
        reservations[invocation.reservationID.uuidString] = invocation
        clockHighWaterMilliseconds = nowMilliseconds
        return .init(reservationID: invocation.reservationID, leaseID: invocation.leaseID, alreadyReserved: false)
    }

    /// Ancestor revocation is checked dynamically, preserving every descendant's audit record.
    public mutating func revoke(leaseID: UUID) throws {
        try validateShape()
        guard var value = budgets[leaseID.uuidString] else { throw CapabilityLeaseError.unknownLease }
        value.revoked = true; budgets[leaseID.uuidString] = value
    }

    /// Recovery must supply the original host pins, not keys decoded from the journal.
    public func validate(trustedRootIssuerPublicKeys: [Data]) throws {
        try validateShape()
        guard !trustedRootIssuerPublicKeys.isEmpty, trustedRootIssuerPublicKeys.count <= 32,
              trustedRootIssuerPublicKeys.allSatisfy({ $0.count == 32 }) else { throw CapabilityLeaseError.untrustedIssuer }
        for entry in budgets.values {
            let signed = entry.signedLease; let body = signed.body
            if let parentID = body.parentLeaseID {
                guard let parent = budgets[parentID.uuidString] else { throw CapabilityLeaseError.malformedState }
                try signed.verifySignature(trustedIssuerPublicKey: parent.signedLease.body.subjectPublicKey)
                try body.validateAttenuation(from: parent.signedLease.body)
            } else {
                guard trustedRootIssuerPublicKeys.contains(body.issuerPublicKey) else { throw CapabilityLeaseError.untrustedIssuer }
                try signed.verifySignature(trustedIssuerPublicKey: body.issuerPublicKey)
            }
            var seen = Set<UUID>(); var cursor: UUID? = body.leaseID
            while let current = cursor {
                guard seen.insert(current).inserted, seen.count <= 3,
                      let node = budgets[current.uuidString] else { throw CapabilityLeaseError.malformedState }
                cursor = node.signedLease.body.parentLeaseID
            }
        }
        // Check conservation after recovery: direct allocations plus local reservations cannot exceed a signed grant.
        for entry in budgets.values {
            let body = entry.signedLease.body
            let children = budgets.values.filter { $0.signedLease.body.parentLeaseID == body.leaseID }
            let local = reservations.values.filter { $0.leaseID == body.leaseID }
            let executions = children.reduce(Int64(local.count)) { $0 + $1.signedLease.body.limits.maximumExecutions }
            let descendants = children.reduce(Int64(0)) { $0 + 1 + $1.signedLease.body.limits.maximumDescendants }
            let cost = children.reduce(local.reduce(Int64(0)) { $0 + $1.costUnits }) { $0 + $1.signedLease.body.limits.maximumCostUnits }
            guard entry.remainingExecutions == body.limits.maximumExecutions - executions,
                  entry.remainingChildren == body.limits.maximumChildren - Int64(children.count),
                  entry.remainingDescendants == body.limits.maximumDescendants - descendants,
                  entry.remainingCostUnits == body.limits.maximumCostUnits - cost
            else { throw CapabilityLeaseError.malformedState }
        }
    }

    private func validateShape() throws {
        guard budgets.count <= 1024, reservations.count <= 8192,
              (0...253_402_300_799_999).contains(clockHighWaterMilliseconds)
        else { throw CapabilityLeaseError.malformedState }
        for (key, budget) in budgets {
            let body = budget.signedLease.body; try body.validate()
            guard key == body.leaseID.uuidString, budget.signedLease.signature.count == 64,
                  (0...body.limits.maximumExecutions).contains(budget.remainingExecutions),
                  (0...body.limits.maximumChildren).contains(budget.remainingChildren),
                  (0...body.limits.maximumDescendants).contains(budget.remainingDescendants),
                  (0...body.limits.maximumCostUnits).contains(budget.remainingCostUnits)
            else { throw CapabilityLeaseError.malformedState }
        }
        for (key, invocation) in reservations {
            try invocation.validate()
            guard key == invocation.reservationID.uuidString,
                  let body = budgets[invocation.leaseID.uuidString]?.signedLease.body,
                  body.capabilityIDs.contains(invocation.capabilityID),
                  invocation.profileID == nil || body.profileIDs.contains(invocation.profileID!),
                  Set(invocation.networkDestinations).isSubset(of: Set(body.networkAllowlist)),
                  invocation.cpuCount <= body.limits.cpuCount, invocation.memoryMiB <= body.limits.memoryMiB
            else { throw CapabilityLeaseError.malformedState }
        }
    }

    private func checkClock(_ now: Int64) throws {
        guard (0...253_402_300_799_999).contains(now), now >= clockHighWaterMilliseconds
        else { throw CapabilityLeaseError.clockRollback }
    }

    private func activeChain(_ leaseID: UUID, now: Int64) throws {
        var cursor: UUID? = leaseID; var seen = Set<UUID>()
        while let current = cursor {
            guard seen.insert(current).inserted, seen.count <= 3 else { throw CapabilityLeaseError.malformedState }
            guard let budget = budgets[current.uuidString] else { throw CapabilityLeaseError.unknownLease }
            guard !budget.revoked else { throw CapabilityLeaseError.revoked }
            try LeaseValidation.time(budget.signedLease.body, now: now)
            cursor = budget.signedLease.body.parentLeaseID
        }
    }

    private func authenticate(_ body: CapabilityLease, subject: Data, runtimeID: String, environment: UUID) throws {
        guard subject.count == 32, subject == body.subjectPublicKey, runtimeID == body.subjectRuntimeID
        else { throw CapabilityLeaseError.subjectMismatch }
        guard environment == body.environmentID else { throw CapabilityLeaseError.environmentMismatch }
    }
}

private enum LeaseValidation {
    static func identifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 256 && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 47, 58, 95].contains($0)
        }
    }
    static func set(_ values: [String], maximum: Int, valid: (String) -> Bool) -> Bool {
        values.count <= maximum && values == values.sorted() && Set(values).count == values.count && values.allSatisfy(valid)
    }
    static func origin(_ value: String) -> Bool {
        guard value.utf8.count <= 256, value.utf8.allSatisfy({ (33...126).contains($0) }),
              let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty, host == host.lowercased(),
              !host.contains("*"), !host.hasSuffix("."), components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              components.port == nil || ((1...65535).contains(components.port!) && components.port != 443),
              components.url?.absoluteString == value, !value.contains("%")
        else { return false }
        return true
    }
    static func time(_ body: CapabilityLease, now: Int64) throws {
        guard now >= body.issuedAtMilliseconds else { throw CapabilityLeaseError.futureIssued }
        guard now < body.expiresAtMilliseconds else { throw CapabilityLeaseError.expired }
    }
}
