import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ChildRuntimeEnrollmentError: String, Error, Codable, Sendable {
    case malformed, invalidSignature, untrustedKey, expired, wrongEnvironment, wrongRuntime
    case wrongParent, wrongChallenge, missingObservation, staleObservation
}

/// One software key created on the execution node for one environment
/// incarnation. Custody loss requires explicit re-bootstrap, never replacement.
/// No private-key export or hardware-backed/zeroization guarantee is provided.
public struct EphemeralChildRuntimeSigner: RCIRReceiptSigning {
    private let key: Curve25519.Signing.PrivateKey
    public init() { key = .init() }
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public func sign(_ payload: Data) throws -> Data { try key.signature(for: payload) }
}

/// An authenticated child statement, never independent runtime attestation.
/// The complete immutable handle protects resource correlation and lineage.
public struct ChildRuntimeClaim: Codable, Sendable, Equatable {
    public let version: Int
    public let enrollmentID: String
    public let handle: EnvironmentHandle
    public let manifest: EnvironmentRuntimeManifest
    public let publicKey: Data
    public let challenge: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public var runtimeID: String { "runtime:" + childRuntimeDigest(publicKey) }
    public var deviceID: String { "device:" + childRuntimeDigest(publicKey) }

    public init(enrollmentID: String, handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest,
                publicKey: Data, challenge: Data, issuedAtMilliseconds: Int64, expiresAtMilliseconds: Int64) throws {
        guard EnvironmentIdentity.isCanonicalID(enrollmentID), publicKey.count == 32, challenge.count == 32,
              issuedAtMilliseconds >= handle.createdAtMilliseconds, expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds <= handle.expiresAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds <= 60_000 else { throw ChildRuntimeEnrollmentError.malformed }
        version = 1; self.enrollmentID = enrollmentID; self.handle = handle; self.manifest = manifest
        self.publicKey = publicKey; self.challenge = challenge; self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    public func canonicalData() throws -> Data {
        let resources = handle.spec.resources
        return try childRuntimeCanonical("RIGHTCLICK-CHILD-RUNTIME-CLAIM-1", .object([
            "version": .integer(Int64(version)), "enrollmentID": .string(enrollmentID),
            "handle": .object([
                "environmentID": .string(handle.environmentID), "providerID": .string(handle.providerID),
                "providerResourceID": .string(handle.providerResourceID), "correlationID": .string(handle.correlationID),
                "lineage": .object([
                    "rootEnvironmentID": .string(handle.lineage.rootEnvironmentID),
                    "parentEnvironmentID": handle.lineage.parentEnvironmentID.map(CapabilityValue.string) ?? .null,
                    "parentExecutionID": .string(handle.lineage.parentExecutionID),
                    "parentRuntimeID": .string(handle.lineage.parentRuntimeID), "depth": .integer(Int64(handle.lineage.depth))
                ]),
                "spec": .object([
                    "profileID": .string(handle.spec.profileID), "lifetimeMilliseconds": .integer(handle.spec.lifetimeMilliseconds),
                    "resources": .object([
                        "cpuCount": .integer(Int64(resources.cpuCount)), "memoryMiB": .integer(Int64(resources.memoryMiB)),
                        "maximumCostUnits": .integer(resources.maximumCostUnits), "costUnit": .string(resources.costUnit)
                    ])
                ]),
                "createdAtMilliseconds": .integer(handle.createdAtMilliseconds),
                "expiresAtMilliseconds": .integer(handle.expiresAtMilliseconds)
            ]),
            "manifest": .object([
                "version": .string(manifest.version), "executableSHA256": .string(manifest.executableSHA256),
                "operatingSystem": .string(manifest.operatingSystem.rawValue), "architecture": .string(manifest.architecture)
            ]),
            "publicKey": .bytes(publicKey), "runtimeID": .string(runtimeID), "deviceID": .string(deviceID),
            "challenge": .bytes(challenge), "issuedAtMilliseconds": .integer(issuedAtMilliseconds),
            "expiresAtMilliseconds": .integer(expiresAtMilliseconds)
        ]))
    }
    public func digest() throws -> String { childRuntimeDigest(try canonicalData()) }
    public var challengeDigest: String { childRuntimeDigest(challenge) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, enrollmentID, handle, manifest, publicKey, challenge, issuedAtMilliseconds, expiresAtMilliseconds
    }
    public init(from decoder: Decoder) throws {
        try childRuntimeDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw ChildRuntimeEnrollmentError.malformed }
        try self.init(enrollmentID: c.decode(String.self, forKey: .enrollmentID), handle: c.decode(EnvironmentHandle.self, forKey: .handle),
            manifest: c.decode(EnvironmentRuntimeManifest.self, forKey: .manifest), publicKey: c.decode(Data.self, forKey: .publicKey),
            challenge: c.decode(Data.self, forKey: .challenge), issuedAtMilliseconds: c.decode(Int64.self, forKey: .issuedAtMilliseconds),
            expiresAtMilliseconds: c.decode(Int64.self, forKey: .expiresAtMilliseconds))
    }
}

public struct SignedChildRuntimeClaim: Codable, Sendable, Equatable {
    public let version: Int
    public let algorithm: String
    public let claim: ChildRuntimeClaim
    public let signature: Data

    public init(claim: ChildRuntimeClaim, signature: Data) throws {
        guard signature.count == 64 else { throw ChildRuntimeEnrollmentError.malformed }
        version = 1; algorithm = "Ed25519"; self.claim = claim; self.signature = signature
    }
    public static func sign(_ claim: ChildRuntimeClaim, using signer: any RCIRReceiptSigning) throws -> Self {
        guard signer.publicKey == claim.publicKey else { throw ChildRuntimeEnrollmentError.untrustedKey }
        return try .init(claim: claim, signature: signer.sign(claim.canonicalData()))
    }
    /// The trusted key must come from a separate bootstrap/provider observation.
    public func verify(trustedPublicKey: Data) throws -> ChildRuntimeClaim {
        guard trustedPublicKey.count == 32, trustedPublicKey == claim.publicKey else { throw ChildRuntimeEnrollmentError.untrustedKey }
        guard try RCIREd25519Verifier().verify(signature: signature, payload: claim.canonicalData(), publicKey: trustedPublicKey)
        else { throw ChildRuntimeEnrollmentError.invalidSignature }
        return claim
    }
    public func wireData() throws -> Data { try childRuntimeWireEncode(self) }
    public static func decode(_ data: Data) throws -> Self { try childRuntimeWireDecode(Self.self, data) }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, algorithm, claim, signature }
    public init(from decoder: Decoder) throws {
        try childRuntimeDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1, try c.decode(String.self, forKey: .algorithm) == "Ed25519"
        else { throw ChildRuntimeEnrollmentError.malformed }
        try self.init(claim: c.decode(ChildRuntimeClaim.self, forKey: .claim), signature: c.decode(Data.self, forKey: .signature))
    }
}

/// A host verification authority signs this after independent bootstrap checks.
/// It conveys enrollment only: no workload success, authority, or user consent.
public struct ChildRuntimeEnrollmentCertificate: Codable, Sendable, Equatable {
    public let version: Int
    public let claim: ChildRuntimeClaim
    public let issuerPublicKey: Data
    public let environmentObservedAtMilliseconds: Int64
    public let runtimeObservedAtMilliseconds: Int64
    public let verifiedAtMilliseconds: Int64
    public let environmentObservationBoundary: String
    public let runtimeObservationBoundary: String
    public var issuerRuntimeID: String { "runtime:" + childRuntimeDigest(issuerPublicKey) }
    public var claimDigest: String { get throws { try claim.digest() } }

    public init(claim: ChildRuntimeClaim, issuerPublicKey: Data, environmentObservedAtMilliseconds: Int64,
                runtimeObservedAtMilliseconds: Int64, verifiedAtMilliseconds: Int64,
                environmentObservationBoundary: String, runtimeObservationBoundary: String) throws {
        guard issuerPublicKey.count == 32, environmentObservedAtMilliseconds >= claim.handle.createdAtMilliseconds,
              runtimeObservedAtMilliseconds >= claim.handle.createdAtMilliseconds,
              runtimeObservedAtMilliseconds <= environmentObservedAtMilliseconds,
              environmentObservedAtMilliseconds <= verifiedAtMilliseconds,
              verifiedAtMilliseconds >= claim.issuedAtMilliseconds, verifiedAtMilliseconds < claim.expiresAtMilliseconds,
              childRuntimeBoundaryValid(environmentObservationBoundary), childRuntimeBoundaryValid(runtimeObservationBoundary)
        else { throw ChildRuntimeEnrollmentError.malformed }
        version = 1; self.claim = claim; self.issuerPublicKey = issuerPublicKey
        self.environmentObservedAtMilliseconds = environmentObservedAtMilliseconds
        self.runtimeObservedAtMilliseconds = runtimeObservedAtMilliseconds; self.verifiedAtMilliseconds = verifiedAtMilliseconds
        self.environmentObservationBoundary = environmentObservationBoundary; self.runtimeObservationBoundary = runtimeObservationBoundary
    }
    public func canonicalData() throws -> Data {
        try childRuntimeCanonical("RIGHTCLICK-CHILD-ENROLLMENT-CERTIFICATE-1", .object([
            "version": .integer(Int64(version)), "claim": .bytes(try claim.canonicalData()),
            "issuerPublicKey": .bytes(issuerPublicKey), "issuerRuntimeID": .string(issuerRuntimeID),
            "environmentObservedAtMilliseconds": .integer(environmentObservedAtMilliseconds),
            "runtimeObservedAtMilliseconds": .integer(runtimeObservedAtMilliseconds),
            "verifiedAtMilliseconds": .integer(verifiedAtMilliseconds),
            "environmentObservationBoundary": .string(environmentObservationBoundary),
            "runtimeObservationBoundary": .string(runtimeObservationBoundary)
        ]))
    }
    public func digest() throws -> String { childRuntimeDigest(try canonicalData()) }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, claim, issuerPublicKey, environmentObservedAtMilliseconds, runtimeObservedAtMilliseconds
        case verifiedAtMilliseconds, environmentObservationBoundary, runtimeObservationBoundary
    }
    public init(from decoder: Decoder) throws {
        try childRuntimeDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw ChildRuntimeEnrollmentError.malformed }
        try self.init(claim: c.decode(ChildRuntimeClaim.self, forKey: .claim), issuerPublicKey: c.decode(Data.self, forKey: .issuerPublicKey),
            environmentObservedAtMilliseconds: c.decode(Int64.self, forKey: .environmentObservedAtMilliseconds),
            runtimeObservedAtMilliseconds: c.decode(Int64.self, forKey: .runtimeObservedAtMilliseconds),
            verifiedAtMilliseconds: c.decode(Int64.self, forKey: .verifiedAtMilliseconds),
            environmentObservationBoundary: c.decode(String.self, forKey: .environmentObservationBoundary),
            runtimeObservationBoundary: c.decode(String.self, forKey: .runtimeObservationBoundary))
    }
}

public struct SignedChildRuntimeEnrollmentCertificate: Codable, Sendable, Equatable {
    public let version: Int
    public let algorithm: String
    public let certificate: ChildRuntimeEnrollmentCertificate
    public let signature: Data
    public init(certificate: ChildRuntimeEnrollmentCertificate, signature: Data) throws {
        guard signature.count == 64 else { throw ChildRuntimeEnrollmentError.malformed }
        version = 1; algorithm = "Ed25519"; self.certificate = certificate; self.signature = signature
    }
    public static func sign(_ certificate: ChildRuntimeEnrollmentCertificate, using signer: any RCIRReceiptSigning) throws -> Self {
        guard signer.publicKey == certificate.issuerPublicKey else { throw ChildRuntimeEnrollmentError.untrustedKey }
        return try .init(certificate: certificate, signature: signer.sign(certificate.canonicalData()))
    }
    /// Core can authenticate this host certificate without depending on Link.
    /// Caller still pins exact expectation and consumes its nonce durably.
    public func verify(trustedPublicKey: Data, now: Int64) throws -> ChildRuntimeEnrollmentCertificate {
        guard trustedPublicKey.count == 32, trustedPublicKey == certificate.issuerPublicKey else { throw ChildRuntimeEnrollmentError.untrustedKey }
        guard now >= certificate.verifiedAtMilliseconds, now < certificate.claim.expiresAtMilliseconds,
              now - certificate.runtimeObservedAtMilliseconds <= 60_000 else { throw ChildRuntimeEnrollmentError.expired }
        guard try RCIREd25519Verifier().verify(signature: signature, payload: certificate.canonicalData(), publicKey: trustedPublicKey)
        else { throw ChildRuntimeEnrollmentError.invalidSignature }
        return certificate
    }
    public func wireData() throws -> Data { try childRuntimeWireEncode(self) }
    public static func decode(_ data: Data) throws -> Self { try childRuntimeWireDecode(Self.self, data) }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, algorithm, certificate, signature }
    public init(from decoder: Decoder) throws {
        try childRuntimeDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1, try c.decode(String.self, forKey: .algorithm) == "Ed25519"
        else { throw ChildRuntimeEnrollmentError.malformed }
        try self.init(certificate: c.decode(ChildRuntimeEnrollmentCertificate.self, forKey: .certificate), signature: c.decode(Data.self, forKey: .signature))
    }
}

private func childRuntimeDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func childRuntimeCanonical(_ domain: String, _ value: CapabilityValue) throws -> Data {
    Data((domain + "\0").utf8) + (try value.canonicalData(limits: .init(maxDepth: 8, maxNodes: 256, maxBytes: 16_384)))
}
private func childRuntimeBoundaryValid(_ value: String) -> Bool {
    (1...1024).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}
private struct ChildRuntimeDecodeKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func childRuntimeDecodeKeys<Keys: CodingKey & CaseIterable>(_ decoder: Decoder, allowed: Keys.Type) throws {
    let keys = try decoder.container(keyedBy: ChildRuntimeDecodeKey.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: Set(Keys.allCases.map(\.stringValue))) else { throw ChildRuntimeEnrollmentError.malformed }
}
private func childRuntimeWireEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= 32_768 else { throw ChildRuntimeEnrollmentError.malformed }
    return data
}
private func childRuntimeWireDecode<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
    guard !data.isEmpty, data.count <= 32_768 else { throw ChildRuntimeEnrollmentError.malformed }
    var depth = 0, quoted = false, escaped = false
    for byte in data {
        if quoted {
            if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
        } else if byte == 34 { quoted = true }
        else if byte == 123 || byte == 91 { depth += 1; if depth > 16 { throw ChildRuntimeEnrollmentError.malformed } }
        else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { throw ChildRuntimeEnrollmentError.malformed } }
    }
    guard depth == 0, !quoted else { throw ChildRuntimeEnrollmentError.malformed }
    do {
        let value = try JSONDecoder().decode(type, from: data)
        // Reject duplicate/unknown fields and alternate wire representations.
        guard try childRuntimeWireEncode(value) == data else { throw ChildRuntimeEnrollmentError.malformed }
        return value
    } catch { throw ChildRuntimeEnrollmentError.malformed }
}
