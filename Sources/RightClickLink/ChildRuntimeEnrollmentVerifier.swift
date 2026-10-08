import Foundation
import RightClickProtocol

/// Only the verifier constructs this in-memory result. Crossing into Core uses
/// a signed host certificate rather than a publicly forgeable verified flag.
public struct VerifiedChildRuntimeEnrollment {
    public let claim: ChildRuntimeClaim
    public let claimDigest: String
    public let observation: EnvironmentObservation
    public let verifiedAtMilliseconds: Int64
    public var runtimeID: String { claim.runtimeID }
    public var publicKey: Data { claim.publicKey }
    public var challengeDigest: String { claim.challengeDigest }

    fileprivate init(claim: ChildRuntimeClaim, observation: EnvironmentObservation, now: Int64) throws {
        self.claim = claim; claimDigest = try claim.digest(); self.observation = observation; verifiedAtMilliseconds = now
    }
    public func certificate(using signer: any RCIRReceiptSigning) throws -> SignedChildRuntimeEnrollmentCertificate {
        guard let runtime = observation.runtime else { throw ChildRuntimeEnrollmentError.missingObservation }
        return try .sign(.init(claim: claim, issuerPublicKey: signer.publicKey,
            environmentObservedAtMilliseconds: observation.observedAtMilliseconds,
            runtimeObservedAtMilliseconds: runtime.observedAtMilliseconds, verifiedAtMilliseconds: verifiedAtMilliseconds,
            environmentObservationBoundary: observation.observationBoundary, runtimeObservationBoundary: runtime.observationBoundary), using: signer)
    }
}

public enum ChildRuntimeEnrollmentVerifier {
    /// Pure verification only. The host pins the expectation and independent
    /// provider channel; Core consumes challenge/id durably before activation.
    /// Child assertion, signature, or this certificate never proves a workload.
    public static func verify(signedClaim: SignedChildRuntimeClaim, expectedHandle: EnvironmentHandle,
        expectedManifest: EnvironmentRuntimeManifest, expectedEnrollmentID: String, expectedChallenge: Data,
        trustedBootstrapPublicKey: Data, observation: EnvironmentObservation, now: Int64,
        maximumObservationAgeMilliseconds: Int64 = 30_000) throws -> VerifiedChildRuntimeEnrollment {
        guard (1...60_000).contains(maximumObservationAgeMilliseconds), expectedChallenge.count == 32,
              EnvironmentIdentity.isCanonicalID(expectedEnrollmentID), trustedBootstrapPublicKey.count == 32 else {
            throw ChildRuntimeEnrollmentError.malformed
        }
        let claim = try signedClaim.verify(trustedPublicKey: trustedBootstrapPublicKey)
        guard claim.enrollmentID == expectedEnrollmentID, claim.challenge == expectedChallenge else {
            throw ChildRuntimeEnrollmentError.wrongChallenge
        }
        guard claim.handle.lineage == expectedHandle.lineage else { throw ChildRuntimeEnrollmentError.wrongParent }
        guard claim.handle == expectedHandle else { throw ChildRuntimeEnrollmentError.wrongEnvironment }
        guard claim.manifest == expectedManifest else { throw ChildRuntimeEnrollmentError.wrongRuntime }
        guard now >= claim.issuedAtMilliseconds, now < claim.expiresAtMilliseconds,
              now < expectedHandle.expiresAtMilliseconds else { throw ChildRuntimeEnrollmentError.expired }
        guard observation.presence == .present, [.bootstrapping, .ready, .running].contains(observation.state),
              let runtime = observation.runtime else { throw ChildRuntimeEnrollmentError.missingObservation }
        guard observation.environmentID == expectedHandle.environmentID,
              observation.correlationID == expectedHandle.correlationID,
              observation.providerResourceID == expectedHandle.providerResourceID else { throw ChildRuntimeEnrollmentError.wrongEnvironment }
        guard runtime.publicKey == trustedBootstrapPublicKey, runtime.publicKey == claim.publicKey,
              runtime.runtimeID == claim.runtimeID, runtime.manifest == expectedManifest else { throw ChildRuntimeEnrollmentError.wrongRuntime }
        guard observation.observedAtMilliseconds >= expectedHandle.createdAtMilliseconds,
              runtime.observedAtMilliseconds >= expectedHandle.createdAtMilliseconds,
              observation.observedAtMilliseconds <= now, runtime.observedAtMilliseconds <= now,
              now - observation.observedAtMilliseconds <= maximumObservationAgeMilliseconds,
              now - runtime.observedAtMilliseconds <= maximumObservationAgeMilliseconds else {
            throw ChildRuntimeEnrollmentError.staleObservation
        }
        return try .init(claim: claim, observation: observation, now: now)
    }

    public static func verify(signedClaim: Data, expectedHandle: EnvironmentHandle,
        expectedManifest: EnvironmentRuntimeManifest, expectedEnrollmentID: String, expectedChallenge: Data,
        trustedBootstrapPublicKey: Data, observation: EnvironmentObservation, now: Int64,
        maximumObservationAgeMilliseconds: Int64 = 30_000) throws -> VerifiedChildRuntimeEnrollment {
        try verify(signedClaim: SignedChildRuntimeClaim.decode(signedClaim), expectedHandle: expectedHandle,
            expectedManifest: expectedManifest, expectedEnrollmentID: expectedEnrollmentID, expectedChallenge: expectedChallenge,
            trustedBootstrapPublicKey: trustedBootstrapPublicKey, observation: observation, now: now,
            maximumObservationAgeMilliseconds: maximumObservationAgeMilliseconds)
    }
}
