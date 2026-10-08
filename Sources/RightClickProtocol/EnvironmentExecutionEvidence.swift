import Foundation

/// A bounded, public-key-only audit view. Consumers must verify both signatures
/// with independently configured pins before using a certificate as authority.
public struct EnvironmentExecutionEvidence: Codable, Sendable {
    public let environmentID: String
    public let runtimeEnrollment: SignedChildRuntimeEnrollmentCertificate?
    public let signedProof: SignedExecutionProof?
    public let verificationCertificate: SignedExecutionVerificationCertificate?
    public init(environmentID: String, runtimeEnrollment: SignedChildRuntimeEnrollmentCertificate?,
                signedProof: SignedExecutionProof?, verificationCertificate: SignedExecutionVerificationCertificate?) throws {
        self.environmentID = environmentID; self.runtimeEnrollment = runtimeEnrollment
        self.signedProof = signedProof; self.verificationCertificate = verificationCertificate
        try validate()
    }
    /// Validation applies equally to host construction and untrusted decoding.
    /// It establishes shape/bounds only; signature pins belong to the consumer.
    public func validate() throws {
        guard EnvironmentIdentity.isCanonicalID(environmentID),
              runtimeEnrollment?.certificate.claim.handle.environmentID == nil || runtimeEnrollment?.certificate.claim.handle.environmentID == environmentID,
              signedProof?.proof.binding.environmentID == nil || signedProof?.proof.binding.environmentID == environmentID,
              verificationCertificate?.verification.binding.environmentID == nil || verificationCertificate?.verification.binding.environmentID == environmentID else {
            throw EnvironmentEvidenceError.bindingMismatch
        }
        _ = try runtimeEnrollment?.wireData()
        _ = try signedProof?.wireData()
        _ = try verificationCertificate?.wireData()
        guard try JSONEncoder().encode(self).count <= 32_768 else { throw EnvironmentEvidenceError.malformed }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case environmentID, runtimeEnrollment, signedProof, verificationCertificate
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(all).isSubset(of: Set(CodingKeys.allCases.map(\.stringValue))) else { throw EnvironmentEvidenceError.malformed }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(environmentID: c.decode(String.self, forKey: .environmentID),
            runtimeEnrollment: c.decodeIfPresent(SignedChildRuntimeEnrollmentCertificate.self, forKey: .runtimeEnrollment),
            signedProof: c.decodeIfPresent(SignedExecutionProof.self, forKey: .signedProof),
            verificationCertificate: c.decodeIfPresent(SignedExecutionVerificationCertificate.self, forKey: .verificationCertificate))
    }
}
