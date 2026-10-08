import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum EnvironmentEvidenceError: Error, Equatable {
    case malformed
    case untrustedKey
    case invalidSignature
    case bindingMismatch
    case invalidTime
    case invalidSequence
    case independentVerificationRequired
    case unsuccessfulDependency
    case dependencyCycle
    case durableReservationRequired
}

/// Authenticated child assertions are deliberately distinct from host outcomes.
public enum ExecutionProofOutcome: String, Codable, Sendable {
    case accepted, unverified, succeeded, failed, unknown
}

/// Exact portable invocation identity. These strings are locators, never authority.
public struct ExecutionProofBinding: Codable, Sendable {
    public let executionID: String
    public let environmentID: String
    public let parentExecutionID: String?
    public let parentEnvironmentID: String?
    public let parentRuntimeID: String?
    public let runtimeID: String
    public let executableSHA256: String
    public let signerID: String
    public let keyID: String
    public let leaseDigest: String
    public let capabilityID: String
    public let contractDigest: String
    public let requestDigest: String
    public let responseDigest: String

    public init(executionID: String, environmentID: String, parentExecutionID: String?,
                parentEnvironmentID: String?, parentRuntimeID: String?, runtimeID: String,
                executableSHA256: String, signerID: String, keyID: String, leaseDigest: String,
                capabilityID: String, contractDigest: String, requestDigest: String, responseDigest: String) throws {
        self.executionID = executionID; self.environmentID = environmentID
        self.parentExecutionID = parentExecutionID; self.parentEnvironmentID = parentEnvironmentID
        self.parentRuntimeID = parentRuntimeID; self.runtimeID = runtimeID
        self.executableSHA256 = executableSHA256; self.signerID = signerID; self.keyID = keyID
        self.leaseDigest = leaseDigest; self.capabilityID = capabilityID; self.contractDigest = contractDigest
        self.requestDigest = requestDigest; self.responseDigest = responseDigest
        try validate()
    }

    public func canonicalData() throws -> Data { try validate(); return try value.canonicalData(limits: evidenceLimits) }

    fileprivate func validate() throws {
        try evidenceUUID(executionID); try evidenceUUID(environmentID)
        if let parentExecutionID { try evidenceUUID(parentExecutionID) }
        if let parentEnvironmentID { try evidenceUUID(parentEnvironmentID) }
        if let parentRuntimeID { try evidenceIdentity(parentRuntimeID) }
        // A partial parent context cannot silently lose the causal execution/runtime binding.
        guard (parentExecutionID == nil) == (parentEnvironmentID == nil),
              (parentExecutionID == nil) == (parentRuntimeID == nil) else { throw EnvironmentEvidenceError.malformed }
        for identity in [runtimeID, signerID, capabilityID] { try evidenceIdentity(identity) }
        for digest in [executableSHA256, keyID, leaseDigest, contractDigest, requestDigest, responseDigest] {
            try evidenceDigest(digest)
        }
    }

    fileprivate var value: CapabilityValue {
        .object([
            "executionID": .string(executionID), "environmentID": .string(environmentID),
            "parentExecutionID": parentExecutionID.map(CapabilityValue.string) ?? .null,
            "parentEnvironmentID": parentEnvironmentID.map(CapabilityValue.string) ?? .null,
            "parentRuntimeID": parentRuntimeID.map(CapabilityValue.string) ?? .null,
            "runtimeID": .string(runtimeID), "executableSHA256": .string(executableSHA256),
            "signerID": .string(signerID), "keyID": .string(keyID), "leaseDigest": .string(leaseDigest),
            "capabilityID": .string(capabilityID), "contractDigest": .string(contractDigest),
            "requestDigest": .string(requestDigest), "responseDigest": .string(responseDigest)
        ])
    }
}

/// Immutable report. Its signature authenticates reporting, not semantic success.
public struct ExecutionProof: Codable, Sendable {
    public let binding: ExecutionProofBinding
    public let challengeNonce: Data
    public let issuedAtMilliseconds: Int64
    public let observedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let sequence: Int64
    public let predicateID: String
    public let providerAccepted: Bool
    public let reportedOutcome: ExecutionProofOutcome
    public let reportedValue: CapabilityValue?
    public let reportBoundary: String

    public init(binding: ExecutionProofBinding, challengeNonce: Data, issuedAtMilliseconds: Int64,
                observedAtMilliseconds: Int64, expiresAtMilliseconds: Int64, sequence: Int64,
                predicateID: String, providerAccepted: Bool, reportedOutcome: ExecutionProofOutcome,
                reportedValue: CapabilityValue?, reportBoundary: String) throws {
        self.binding = binding; self.challengeNonce = challengeNonce
        self.issuedAtMilliseconds = issuedAtMilliseconds; self.observedAtMilliseconds = observedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds; self.sequence = sequence; self.predicateID = predicateID
        self.providerAccepted = providerAccepted; self.reportedOutcome = reportedOutcome
        self.reportedValue = reportedValue; self.reportBoundary = reportBoundary
        try validate()
    }

    public func canonicalData() throws -> Data {
        try validate()
        return try evidenceCanonical("RIGHTCLICK-EXECUTION-PROOF-1\0", .object([
            "version": .integer(1), "binding": binding.value, "challengeNonce": .bytes(challengeNonce),
            "issuedAtMilliseconds": .integer(issuedAtMilliseconds), "observedAtMilliseconds": .integer(observedAtMilliseconds),
            "expiresAtMilliseconds": .integer(expiresAtMilliseconds), "sequence": .integer(sequence),
            "predicateID": .string(predicateID), "providerAccepted": .boolean(providerAccepted),
            "reportedOutcome": .string(reportedOutcome.rawValue), "reportedValue": reportedValue ?? .null,
            "hasReportedValue": .boolean(reportedValue != nil), "reportBoundary": .string(reportBoundary)
        ]))
    }

    public var digest: String { get throws { ExecutionEvidenceDigest.sha256(try canonicalData()) } }

    fileprivate func validate() throws {
        try binding.validate(); try evidenceIdentity(predicateID); try evidenceBoundary(reportBoundary)
        guard challengeNonce.count == 32, issuedAtMilliseconds > 0,
              observedAtMilliseconds >= issuedAtMilliseconds, expiresAtMilliseconds > observedAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds <= 900_000,
              sequence > 0 else { throw EnvironmentEvidenceError.malformed }
        _ = try reportedValue?.canonicalData(limits: evidenceLimits)
    }
}

public struct SignedExecutionProof: Codable, Sendable {
    public let proof: ExecutionProof
    public let signature: Data
    public let publicKey: Data

    public init(proof: ExecutionProof, signature: Data, publicKey: Data) throws {
        self.proof = proof; self.signature = signature; self.publicKey = publicKey
        try validate()
    }

    public static func sign(_ proof: ExecutionProof, using signer: any RCIRReceiptSigning) throws -> Self {
        guard proof.binding.keyID == ExecutionEvidenceDigest.sha256(signer.publicKey) else {
            throw EnvironmentEvidenceError.untrustedKey
        }
        return try .init(proof: proof, signature: signer.sign(proof.canonicalData()), publicKey: signer.publicKey)
    }

    public func verify(trustedPublicKey: Data, using verifier: any RCIRReceiptVerifying) throws {
        try validate()
        guard trustedPublicKey.count == 32, publicKey == trustedPublicKey,
              proof.binding.keyID == ExecutionEvidenceDigest.sha256(trustedPublicKey) else {
            throw EnvironmentEvidenceError.untrustedKey
        }
        guard try verifier.verify(signature: signature, payload: proof.canonicalData(), publicKey: trustedPublicKey)
        else { throw EnvironmentEvidenceError.invalidSignature }
    }

    public func wireData() throws -> Data { try validate(); return try evidenceEncode(self) }
    public static func decodeWire(_ data: Data) throws -> Self {
        let result = try evidenceDecode(Self.self, data); try result.validate(); return result
    }
    fileprivate func validate() throws {
        try proof.validate()
        guard publicKey.count == 32, signature.count == 64 else { throw EnvironmentEvidenceError.malformed }
        _ = try proof.canonicalData()
    }
}

/// Host-owned pins from the admitted invocation, not fields copied from a report.
/// The caller must retain nonce and sequence admission state in its durable ledger.
public struct ExecutionProofExpectation: Sendable {
    public let binding: ExecutionProofBinding
    public let challengeNonce: Data
    public let expectedSequence: Int64
    public let minimumIssuedAtMilliseconds: Int64
    public let deadlineMilliseconds: Int64
    public let maximumAgeMilliseconds: Int64
    public let predicateID: String
    public let expectedValue: CapabilityValue

    public init(binding: ExecutionProofBinding, challengeNonce: Data, expectedSequence: Int64,
                minimumIssuedAtMilliseconds: Int64, deadlineMilliseconds: Int64,
                maximumAgeMilliseconds: Int64, predicateID: String, expectedValue: CapabilityValue) throws {
        self.binding = binding; self.challengeNonce = challengeNonce; self.expectedSequence = expectedSequence
        self.minimumIssuedAtMilliseconds = minimumIssuedAtMilliseconds; self.deadlineMilliseconds = deadlineMilliseconds
        self.maximumAgeMilliseconds = maximumAgeMilliseconds; self.predicateID = predicateID; self.expectedValue = expectedValue
        try binding.validate(); try evidenceIdentity(predicateID)
        guard challengeNonce.count == 32, expectedSequence > 0, minimumIssuedAtMilliseconds > 0,
              deadlineMilliseconds > minimumIssuedAtMilliseconds, (1...900_000).contains(maximumAgeMilliseconds)
        else { throw EnvironmentEvidenceError.malformed }
        _ = try expectedValue.canonicalData(limits: evidenceLimits)
    }
}

/// The independent observer sees only these host-owned pins, never child output.
public struct ExecutionObservationRequest: Sendable {
    public let binding: ExecutionProofBinding
    public let challengeNonce: Data
    public let predicateID: String
    public let expectedValue: CapabilityValue
}

public enum HostExecutionOutcome: String, Codable, Sendable { case succeeded, failed, unknown }

/// Constructed by the production adjudicator; retained as data or a host-signed certificate.
public struct HostExecutionVerification: Codable, Sendable {
    public let binding: ExecutionProofBinding
    public let proofDigest: String
    public let challengeNonce: Data
    public let sequence: Int64
    public let predicateID: String
    public let expectedValueDigest: String
    public let observedValueDigest: String?
    public let observerID: String
    public let observationBoundary: String
    public let verifiedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let outcome: HostExecutionOutcome

    fileprivate init(binding: ExecutionProofBinding, proofDigest: String, challengeNonce: Data, sequence: Int64,
                     predicateID: String, expectedValueDigest: String, observedValueDigest: String?, observerID: String,
                     observationBoundary: String, verifiedAtMilliseconds: Int64, expiresAtMilliseconds: Int64,
                     outcome: HostExecutionOutcome) {
        self.binding = binding; self.proofDigest = proofDigest; self.challengeNonce = challengeNonce; self.sequence = sequence
        self.predicateID = predicateID; self.expectedValueDigest = expectedValueDigest; self.observedValueDigest = observedValueDigest
        self.observerID = observerID; self.observationBoundary = observationBoundary; self.verifiedAtMilliseconds = verifiedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds; self.outcome = outcome
    }

    public func canonicalData() throws -> Data {
        try binding.validate(); try evidenceDigest(proofDigest); try evidenceDigest(expectedValueDigest)
        if let observedValueDigest { try evidenceDigest(observedValueDigest) }
        try evidenceIdentity(predicateID); try evidenceIdentity(observerID); try evidenceBoundary(observationBoundary)
        guard challengeNonce.count == 32, sequence > 0, verifiedAtMilliseconds > 0,
              expiresAtMilliseconds > verifiedAtMilliseconds,
              (outcome == .unknown) == (observedValueDigest == nil),
              outcome != .succeeded || observedValueDigest == expectedValueDigest,
              outcome != .failed || observedValueDigest != expectedValueDigest else { throw EnvironmentEvidenceError.malformed }
        return try evidenceCanonical("RIGHTCLICK-HOST-EXECUTION-VERIFICATION-1\0", .object([
            "version": .integer(1), "binding": binding.value, "proofDigest": .string(proofDigest),
            "challengeNonce": .bytes(challengeNonce), "sequence": .integer(sequence), "predicateID": .string(predicateID),
            "expectedValueDigest": .string(expectedValueDigest), "observedValueDigest": observedValueDigest.map(CapabilityValue.string) ?? .null,
            "observerID": .string(observerID), "observationBoundary": .string(observationBoundary),
            "verifiedAtMilliseconds": .integer(verifiedAtMilliseconds), "expiresAtMilliseconds": .integer(expiresAtMilliseconds),
            "outcome": .string(outcome.rawValue)
        ]))
    }
}

public enum ExecutionProofAdjudicator {
    public static func adjudicate(_ signedProof: SignedExecutionProof, expectation: ExecutionProofExpectation,
                                  trustedPublicKey: Data, observerID: String, observationBoundary: String,
                                  nowMilliseconds: Int64, using verifier: any RCIRReceiptVerifying,
                                  observe: (ExecutionObservationRequest) throws -> CapabilityValue?) throws -> HostExecutionVerification {
        try signedProof.verify(trustedPublicKey: trustedPublicKey, using: verifier)
        let proof = signedProof.proof
        guard try proof.binding.canonicalData() == expectation.binding.canonicalData(),
              proof.challengeNonce == expectation.challengeNonce,
              proof.predicateID.utf8.elementsEqual(expectation.predicateID.utf8) else {
            throw EnvironmentEvidenceError.bindingMismatch
        }
        guard proof.sequence == expectation.expectedSequence else { throw EnvironmentEvidenceError.invalidSequence }
        guard nowMilliseconds >= proof.observedAtMilliseconds, nowMilliseconds < proof.expiresAtMilliseconds,
              nowMilliseconds < expectation.deadlineMilliseconds,
              proof.issuedAtMilliseconds >= expectation.minimumIssuedAtMilliseconds,
              proof.expiresAtMilliseconds <= expectation.deadlineMilliseconds,
              nowMilliseconds - proof.issuedAtMilliseconds <= expectation.maximumAgeMilliseconds else {
            throw EnvironmentEvidenceError.invalidTime
        }
        try evidenceIdentity(observerID); try evidenceBoundary(observationBoundary)
        let expected = try expectation.expectedValue.canonicalData(limits: evidenceLimits)
        let request = ExecutionObservationRequest(binding: expectation.binding, challengeNonce: expectation.challengeNonce,
                                                  predicateID: expectation.predicateID, expectedValue: expectation.expectedValue)
        // Observer errors, missing resources and malformed observations preserve uncertainty.
        let observed: Data?
        do { observed = try observe(request)?.canonicalData(limits: evidenceLimits) } catch { observed = nil }
        let outcome: HostExecutionOutcome = observed.map { $0 == expected ? .succeeded : .failed } ?? .unknown
        return HostExecutionVerification(binding: proof.binding, proofDigest: try proof.digest, challengeNonce: proof.challengeNonce,
            sequence: proof.sequence, predicateID: proof.predicateID, expectedValueDigest: ExecutionEvidenceDigest.sha256(expected),
            observedValueDigest: observed.map(ExecutionEvidenceDigest.sha256), observerID: observerID,
            observationBoundary: observationBoundary, verifiedAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: min(proof.expiresAtMilliseconds, expectation.deadlineMilliseconds), outcome: outcome)
    }
}

/// Durable authorization evidence signed by the observing host, never by the child.
public struct SignedExecutionVerificationCertificate: Codable, Sendable {
    public let verification: HostExecutionVerification
    public let signature: Data
    public let publicKey: Data

    public init(verification: HostExecutionVerification, signature: Data, publicKey: Data) throws {
        self.verification = verification; self.signature = signature; self.publicKey = publicKey
        try validate()
    }
    public static func sign(_ verification: HostExecutionVerification, using signer: any RCIRReceiptSigning) throws -> Self {
        try .init(verification: verification, signature: signer.sign(verification.canonicalData()), publicKey: signer.publicKey)
    }
    public func verify(trustedHostPublicKey: Data, using verifier: any RCIRReceiptVerifying) throws {
        try validate()
        guard trustedHostPublicKey.count == 32, publicKey == trustedHostPublicKey else { throw EnvironmentEvidenceError.untrustedKey }
        guard try verifier.verify(signature: signature, payload: verification.canonicalData(), publicKey: trustedHostPublicKey)
        else { throw EnvironmentEvidenceError.invalidSignature }
    }
    public var digest: String { get throws { ExecutionEvidenceDigest.sha256(try verification.canonicalData()) } }
    public func wireData() throws -> Data { try validate(); return try evidenceEncode(self) }
    public static func decodeWire(_ data: Data) throws -> Self {
        let result = try evidenceDecode(Self.self, data); try result.validate(); return result
    }
    private func validate() throws {
        _ = try verification.canonicalData()
        guard signature.count == 64, publicKey.count == 32 else { throw EnvironmentEvidenceError.malformed }
    }
}

public struct ExecutionDependency: Codable, Sendable {
    public let executionID: String
    public let environmentID: String
    public let requestDigest: String
    public let proofDigest: String
    public let predicateID: String
    public let observerID: String
    public let maximumAgeMilliseconds: Int64
    public let oneUse: Bool

    public init(executionID: String, environmentID: String, requestDigest: String, proofDigest: String,
                predicateID: String, observerID: String, maximumAgeMilliseconds: Int64, oneUse: Bool) throws {
        self.executionID = executionID; self.environmentID = environmentID; self.requestDigest = requestDigest
        self.proofDigest = proofDigest; self.predicateID = predicateID; self.observerID = observerID
        self.maximumAgeMilliseconds = maximumAgeMilliseconds; self.oneUse = oneUse
        try validate()
    }
    fileprivate func validate() throws {
        try evidenceUUID(executionID); try evidenceUUID(environmentID)
        try evidenceDigest(requestDigest); try evidenceDigest(proofDigest)
        try evidenceIdentity(predicateID); try evidenceIdentity(observerID)
        guard (1...900_000).contains(maximumAgeMilliseconds) else { throw EnvironmentEvidenceError.malformed }
    }
}

/// Implementations MUST atomically persist the first reservation before returning.
/// Same consumer execution + request digest retries reuse it; all others reject.
/// Store failures throw. An in-memory store does not satisfy this contract.
public protocol EnvironmentDependencyReservationStore {
    func reserve(dependencyProofDigest: String, certificateDigest: String,
                 consumingExecutionID: String, consumingRequestDigest: String) throws
}

public struct ValidatedExecutionDependency: Sendable {
    public let executionID: String
    public let environmentID: String
    public let proofDigest: String
    public let certificateDigest: String
    public let consumingExecutionID: String
    public let consumingRequestDigest: String
}

public enum ExecutionDependencyValidator {
    public static func validate(_ dependency: ExecutionDependency, proof: SignedExecutionProof,
                                certificate: SignedExecutionVerificationCertificate?, trustedChildPublicKey: Data,
                                trustedHostPublicKey: Data, consumingExecutionID: String, consumingRequestDigest: String,
                                nowMilliseconds: Int64, using verifier: any RCIRReceiptVerifying,
                                reservationStore: (any EnvironmentDependencyReservationStore)? = nil) throws -> ValidatedExecutionDependency {
        try dependency.validate(); try evidenceUUID(consumingExecutionID); try evidenceDigest(consumingRequestDigest)
        guard !consumingExecutionID.utf8.elementsEqual(dependency.executionID.utf8) else {
            throw EnvironmentEvidenceError.dependencyCycle
        }
        try proof.verify(trustedPublicKey: trustedChildPublicKey, using: verifier)
        guard let certificate else { throw EnvironmentEvidenceError.independentVerificationRequired }
        try certificate.verify(trustedHostPublicKey: trustedHostPublicKey, using: verifier)
        let record = certificate.verification
        let body = proof.proof
        guard record.outcome == .succeeded else { throw EnvironmentEvidenceError.unsuccessfulDependency }
        guard try record.binding.canonicalData() == body.binding.canonicalData(), record.proofDigest == (try body.digest),
              record.challengeNonce == body.challengeNonce, record.sequence == body.sequence,
              record.predicateID.utf8.elementsEqual(body.predicateID.utf8),
              dependency.executionID.utf8.elementsEqual(body.binding.executionID.utf8),
              dependency.environmentID.utf8.elementsEqual(body.binding.environmentID.utf8),
              dependency.requestDigest == body.binding.requestDigest, dependency.proofDigest == record.proofDigest,
              dependency.predicateID.utf8.elementsEqual(record.predicateID.utf8),
              dependency.observerID.utf8.elementsEqual(record.observerID.utf8) else {
            throw EnvironmentEvidenceError.bindingMismatch
        }
        guard nowMilliseconds >= record.verifiedAtMilliseconds, nowMilliseconds < record.expiresAtMilliseconds,
              record.verifiedAtMilliseconds >= body.observedAtMilliseconds,
              record.expiresAtMilliseconds <= body.expiresAtMilliseconds,
              nowMilliseconds - record.verifiedAtMilliseconds <= dependency.maximumAgeMilliseconds,
              nowMilliseconds - body.issuedAtMilliseconds <= dependency.maximumAgeMilliseconds else {
            throw EnvironmentEvidenceError.invalidTime
        }
        let certificateDigest = try certificate.digest
        if dependency.oneUse {
            guard let reservationStore else { throw EnvironmentEvidenceError.durableReservationRequired }
            try reservationStore.reserve(dependencyProofDigest: dependency.proofDigest, certificateDigest: certificateDigest,
                consumingExecutionID: consumingExecutionID, consumingRequestDigest: consumingRequestDigest)
        }
        return ValidatedExecutionDependency(executionID: dependency.executionID, environmentID: dependency.environmentID,
            proofDigest: dependency.proofDigest, certificateDigest: certificateDigest,
            consumingExecutionID: consumingExecutionID, consumingRequestDigest: consumingRequestDigest)
    }
}

public enum ExecutionEvidenceDigest {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func capabilityValue(_ value: CapabilityValue) throws -> String {
        sha256(try value.canonicalData(limits: evidenceLimits))
    }
}

private let evidenceLimits = CapabilityABILimits(maxDepth: 16, maxNodes: 1024, maxBytes: 131_072)
private func evidenceCanonical(_ domain: String, _ value: CapabilityValue) throws -> Data {
    var result = Data(domain.utf8); result.append(try value.canonicalData(limits: evidenceLimits)); return result
}
private func evidenceUUID(_ value: String) throws {
    guard let id = UUID(uuidString: value), id.uuidString.utf8.elementsEqual(value.utf8) else { throw EnvironmentEvidenceError.malformed }
}
private func evidenceIdentity(_ value: String) throws {
    guard (1...256).contains(value.utf8.count), value.utf8.allSatisfy({ (33...126).contains($0) })
    else { throw EnvironmentEvidenceError.malformed }
}
private func evidenceBoundary(_ value: String) throws {
    guard (1...1024).contains(value.utf8.count), value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
    else { throw EnvironmentEvidenceError.malformed }
}
private func evidenceDigest(_ value: String) throws {
    guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw EnvironmentEvidenceError.malformed }
}
private func evidenceEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= 262_144 else { throw EnvironmentEvidenceError.malformed }; return data
}
private func evidenceDecode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    guard data.count <= 262_144 else { throw EnvironmentEvidenceError.malformed }
    return try JSONDecoder().decode(type, from: data)
}
